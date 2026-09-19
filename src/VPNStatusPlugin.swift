import Foundation

private let schemaVersion = 1
private let pluginName = "VPN Status"
private let activityID = "vpn-status"
private let logPath = NSHomeDirectory() + "/Library/Logs/vpn-status.log"

private func logEvent(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(message)\n"
    let dir = (logPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let h = FileHandle(forWritingAtPath: logPath) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}
private let socketEnvironmentKey = "DYNAMICLAKE_JSON_SOCKET"
private let settingsPathEnvironmentKey = "DYNAMICLAKE_PLUGIN_SETTINGS_PATH"
private let pollIntervalSec: TimeInterval = 0.75
private let notificationDurationSec: TimeInterval = 4
private let notificationPollIntervalSec: TimeInterval = 0.25
private let geoLookupTimeoutSec: TimeInterval = 2
private let countryLookupSettleSec: TimeInterval = 0.8
private let countryLookupRetrySec: TimeInterval = 2
private let reassertIntervalSec: TimeInterval = 30
/// While connected, the exit-country lookup re-runs on this cadence so a server
/// switch without a service change (or a missed probe) still refreshes the flag.
private let countryRefreshIntervalSec: TimeInterval = 15
private let sneakPeekPresentationSec: Double = 2
/// DynamicLake only honours `presentSneakPeek` on updates, and swallows one sent
/// in the same breath as the create — so the connect peek is presented via a
/// short-delayed update, once the capsule is established.
private let peekDelaySec: TimeInterval = 0.5
/// On connect, the peek waits for the exit-country lookup so it always shows
/// logo + country + flag in one presentation — it never peeks without the
/// country while connected. Disconnect peeks are unaffected (no country).
private let peekCountryRecheckSec: TimeInterval = 0.25
/// Once the country arrives while a peek is pending, the flag refresh is sent
/// first; the peek follows this much later as a pure presentation update.
private let peekCountryLeadSec: TimeInterval = 0.3
/// Keep in sync with the version in plugin.json.
private let pluginUserAgent = "VPNStatus-DynamicLake/1.1.7"

private let pluginFeatures: Set<String> = Set(
    (ProcessInfo.processInfo.environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "").split(separator: ",").map(String.init)
)
private let supportsPresentSneakPeek = pluginFeatures.contains("presentSneakPeek")

private struct VPNStatus {
    var connected: Bool
    var provider: String?
    var protocol_: String?
    var serviceName: String?
    var serverAddress: String?
    var routedInterface: String?
}

private struct ExitCountry {
    let code: String
    let name: String
    let generation: UInt64
}

private final class ExitCountryResolver {
    private let lock = NSLock()
    private let session = URLSession(configuration: .ephemeral)
    private var inFlight = false
    private var pending: ExitCountry?

    func request(generation: UInt64) -> Bool {
        lock.lock()
        guard !inFlight else {
            lock.unlock()
            return false
        }
        inFlight = true
        lock.unlock()

        requestEndpoint(at: 0, generation: generation)
        return true
    }

    func takeResult() -> ExitCountry? {
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending = nil
        return result
    }

    private func finish(_ result: ExitCountry?, generation: UInt64) {
        lock.lock()
        pending = result ?? ExitCountry(code: "", name: "", generation: generation)
        inFlight = false
        lock.unlock()
    }

    private func requestEndpoint(at index: Int, generation: UInt64) {
        let endpoints = [
            "https://ipinfo.io/country",
            "https://am.i.mullvad.net/json"
        ]
        guard index < endpoints.count, let url = URL(string: endpoints[index]) else {
            finish(nil, generation: generation)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = geoLookupTimeoutSec
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/plain, application/json", forHTTPHeaderField: "Accept")
        request.setValue(pluginUserAgent, forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, _ in
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let data,
               let code = self?.countryCode(from: data, url: url) {
                if code.count == 2,
                   code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }) {
                    let name = Locale.current.localizedString(forRegionCode: code) ?? code
                    self?.finish(ExitCountry(code: code, name: name, generation: generation), generation: generation)
                    return
                }
            }
            self?.requestEndpoint(at: index + 1, generation: generation)
        }.resume()
    }

    private func countryCode(from data: Data, url: URL) -> String? {
        if url.host == "am.i.mullvad.net",
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let countryName = object["country"] as? String {
            let english = Locale(identifier: "en_US")
            return Locale.Region.isoRegions.first(where: {
                english.localizedString(forRegionCode: $0.identifier)?.caseInsensitiveCompare(countryName) == .orderedSame
            })?.identifier
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
}

/// Extracts the service name from a `scutil --nc list` line. Services are named
/// "<Provider> <Protocol>" (e.g. "ProtonVPN IKEv2"); the name is the last quoted
/// segment of the line.
private func quotedServiceName(in line: String) -> String {
    var inQuote = false
    var serviceName = ""
    for char in line {
        if char == "\"" {
            if inQuote { break }
            inQuote = true
            continue
        }
        if inQuote { serviceName.append(char) }
    }
    return serviceName
}

/// True when an interface has a usable tunnel address. Private IPv4 addresses
/// are valid inside WireGuard/OpenVPN tunnels; the separate route check proves
/// whether that configured interface is actually carrying public traffic.
private func hasRoutableAddress(_ line: String) -> Bool {
    if line.contains("inet ") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count > 1 {
            let addr = String(parts[1])
            if !addr.hasPrefix("127.") && !addr.hasPrefix("169.254.") { return true }
        }
    }
    if line.contains("inet6 ") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count > 1 {
            let addr = parts[1].lowercased().split(separator: "%", maxSplits: 1)[0]
            let blocked = ["fe80:", "::1", "fc00:", "fd"]
            if !blocked.contains(where: addr.hasPrefix) { return true }
        }
    }
    return false
}

/// A configured utun interface is not proof of a live VPN on macOS. Proton keeps
/// one around while disconnected, so require real public traffic to route through
/// that interface before using the fallback detector.
private func routedTunnelInterface() -> String? {
    let (data, status) = runProcess("/sbin/route", arguments: ["-n", "get", "1.1.1.1"], timeout: 1)
    guard status == 0, let output = String(data: data, encoding: .utf8) else { return nil }
    for line in output.components(separatedBy: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, fields[0] == "interface:" else { continue }
        let name = String(fields[1])
        return name.hasPrefix("utun") ? name : nil
    }
    return nil
}

private func serverAddress(for serviceName: String) -> String? {
    let (out, _) = runProcess("/usr/sbin/scutil", arguments: ["--nc", "status", serviceName])
    guard let str = String(data: out, encoding: .utf8) else { return nil }
    for line in str.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("ServerAddress"), let colon = trimmed.firstIndex(of: ":") else { continue }
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { return value }
    }
    return nil
}

private func getVPNStatus() -> VPNStatus {
    let disconnected = VPNStatus(connected: false, provider: nil, protocol_: nil, serviceName: nil, serverAddress: nil, routedInterface: nil)
    var connectingProvider: String?
    let (out, _) = runProcess("/usr/sbin/scutil", arguments: ["--nc", "list"])
    if let str = String(data: out, encoding: .utf8) {
        for line in str.components(separatedBy: "\n") {
            if line.contains("(Connected)") {
                let serviceName = quotedServiceName(in: line)
                guard !serviceName.isEmpty else { continue }
                let parts = serviceName.split(separator: " ", maxSplits: 1)
                let provider = parts.count == 2 ? String(parts[0]) : serviceName
                let proto = parts.count == 2 ? String(parts[1]) : serviceName
                return VPNStatus(
                    connected: true,
                    provider: provider,
                    protocol_: proto,
                    serviceName: serviceName,
                    serverAddress: serverAddress(for: serviceName),
                    routedInterface: nil
                )
            }
            // A service mid-handshake names the provider that owns the tunnel
            // scutil has not claimed yet — the key attribution signal for the
            // routed-utun fallback below.
            if connectingProvider == nil, line.contains("(Connecting)"),
               let serviceName = quotedServiceName(in: line).split(separator: " ", maxSplits: 1).first {
                connectingProvider = String(serviceName)
            }
        }
    }

    guard let routedInterface = routedTunnelInterface() else { return disconnected }
    let (ifData, _) = runProcess("/sbin/ifconfig", arguments: ["-a"], timeout: 3)
    let ifStr = String(data: ifData, encoding: .utf8) ?? ""
    var onUtun = false
    for line in ifStr.components(separatedBy: "\n") {
        if line.first?.isLetter == true {
            onUtun = line.hasPrefix(routedInterface + ":")
        }
        if onUtun, hasRoutableAddress(line) {
            let provider = connectingProvider ?? detectProviderFast() ?? "VPN"
            return VPNStatus(
                connected: true,
                provider: provider,
                protocol_: "WireGuard",
                serviceName: nil,
                serverAddress: nil,
                routedInterface: routedInterface
            )
        }
    }

    return disconnected
}

/// Last-resort provider attribution for the routed-utun fallback. Both
/// provider apps keep GUI processes alive even while disconnected, so process
/// presence alone cannot attribute a tunnel — prefer the scutil "(Connecting)"
/// service (see getVPNStatus) whenever one exists. When neither app shows a
/// connection state at all, pick the provider with the highest PID: macOS
/// allocates PIDs monotonically, so a process freshly spawned for a connection
/// outranks a long-idle one.
private func detectProviderFast() -> String? {
    let candidates: [(pattern: String, provider: String)] = [
        ("[pP]roton|ch\\.protonvpn", "ProtonVPN"),
        ("[nN]ordvpn|NordWhisper", "NordVPN")
    ]
    var bestPid: Int32 = -1
    var bestProvider: String?
    for candidate in candidates {
        let (out, _) = runProcess("/usr/bin/pgrep", arguments: ["-f", candidate.pattern])
        guard let str = String(data: out, encoding: .utf8) else { continue }
        for token in str.split(whereSeparator: { $0.isNewline || $0.isWhitespace }) {
            guard let pid = Int32(token), pid > bestPid else { continue }
            bestPid = pid
            bestProvider = candidate.provider
        }
    }
    return bestProvider
}

private func disconnectedIcon() -> [String: Any] {
    [
        "type": "image",
        "id": "vpn-icon",
        "source": "sfSymbol",
        "systemImage": "network.slash",
        "tint": "red"
    ] as [String: Any]
}

private func flagSlot(_ countryCode: String) -> [String: Any]? {
    countryFlagImagePayload(countryCode: countryCode)
}

private func compactSurface(connected: Bool, provider: String?, countryCode: String) -> [String: Any] {
    var surface: [String: Any] = ["leftSlot": connected ? vpnIconPayload(for: provider) : disconnectedIcon()]
    if let slot = flagSlot(countryCode) {
        surface["rightSlot"] = slot
    }
    return surface
}

/// ELA capsule shown when another activity occupies the main notch.
/// Always the provider logo (never the country flag) so the minimized
/// state stays recognizable. Matches `compactSurface` leftSlot on purpose:
/// front = logo + flag, minimized = logo only.
private func extraLiveActivitySurface(connected: Bool, provider: String?) -> [String: Any] {
    ["leftSlot": connected ? vpnIconPayload(for: provider) : disconnectedIcon()]
}

/// Shared sneak-peek shape: provider logo + detail text + optional country flag.
/// Used by both persistent-mode and notify-mode peeks.
private func makeSneakPeek(connected: Bool, provider: String?, countryCode: String, detail: String) -> [String: Any] {
    var peek: [String: Any] = [
        "leftSlot": connected ? vpnIconPayload(for: provider) : disconnectedIcon(),
        "center": [
            "type": "text",
            "id": "vpn-detail",
            "text": detail,
            "style": "compact"
        ]
    ]
    if let slot = flagSlot(countryCode) {
        peek["rightSlot"] = slot
    }
    return peek
}

private func providerDisplayName(_ provider: String?) -> String {
    provider?.replacingOccurrences(of: "ProtonVPN", with: "Proton VPN") ?? "VPN"
}

private func statusSneakPeek(connected: Bool, provider: String?, countryCode: String, countryName: String) -> [String: Any] {
    let providerName = providerDisplayName(provider)
    var detail = connected ? "\(providerName) connected" : "VPN disconnected"
    if connected, !countryName.isEmpty { detail = "\(providerName) · \(countryName)" }
    return makeSneakPeek(connected: connected, provider: provider, countryCode: countryCode, detail: detail)
}

private func createPayload(connected: Bool, provider: String?, countryCode: String, countryName: String = "") -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "requestID": "create-vpn",
        "type": "create",
        "activityID": activityID,
        "title": pluginName,
        "priority": "low",
        "size": "small",
        "surfaces": [
            "compactLiveActivity": compactSurface(connected: connected, provider: provider, countryCode: countryCode),
            "sneakPeek": statusSneakPeek(connected: connected, provider: provider, countryCode: countryCode, countryName: countryName),
            "extraLiveActivity": extraLiveActivitySurface(connected: connected, provider: provider)
        ] as [String: Any]
    ]
}

private var updateSequence: UInt64 = 0

private func notifyComponents(connected: Bool, provider: String?, countryCode: String, countryName: String) -> [String: Any] {
    let providerName = providerDisplayName(provider)
    var detail = connected ? "\(providerName) connected" : "VPN disconnected"
    if connected, !countryName.isEmpty { detail = "Connected to \(countryName)" }
    let sneakPeek = makeSneakPeek(connected: connected, provider: provider, countryCode: countryCode, detail: detail)
    return [
        "compactLiveActivity": compactSurface(connected: connected, provider: provider, countryCode: countryCode),
        "sneakPeek": sneakPeek,
        "extraLiveActivity": extraLiveActivitySurface(connected: connected, provider: provider)
    ]
}

private func notifyPayload(connected: Bool, provider: String?, countryCode: String, countryName: String) -> [String: Any] {
    updateSequence += 1
    let surfaces = notifyComponents(connected: connected, provider: provider, countryCode: countryCode, countryName: countryName)
    var payload: [String: Any] = [
        "schemaVersion": schemaVersion,
        "requestID": "notify-\(updateSequence)",
        "type": "create",
        "activityID": activityID,
        "title": pluginName,
        "priority": "high",
        "size": "normal",
        "surfaces": surfaces
    ]
    // Note: presentSneakPeek is NOT put on the create — DynamicLake ignores it
    // there. The shared delayed peek update below the mode branch presents it,
    // exactly like persistent mode.
    return payload
}

private func peekUpdatePayload(connected: Bool, provider: String?, countryCode: String, countryName: String, presentPeek: Bool = true) -> [String: Any] {
    updateSequence += 1
    let surfaces = notifyComponents(connected: connected, provider: provider, countryCode: countryCode, countryName: countryName)
    var payload: [String: Any] = [
        "schemaVersion": schemaVersion,
        "requestID": "peek-\(updateSequence)",
        "type": "update",
        "activityID": activityID,
        "surfaces": surfaces
    ]
    if presentPeek, supportsPresentSneakPeek {
        payload["presentSneakPeek"] = sneakPeekPresentationSec
    }
    return payload
}

private func dismissPayload() -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "requestID": "dismiss-vpn",
        "type": "dismiss",
        "activityID": activityID
    ]
}

/// Reads a boolean setting. The settings file is the source of truth: DynamicLake
/// rewrites it when the user toggles a switch, while the environment variable is
/// only a snapshot from process launch and never updates for a running plugin.
private func readBoolSetting(_ id: String, envKey: String) -> Bool {
    if let settingsPath = ProcessInfo.processInfo.environment[settingsPathEnvironmentKey],
       let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)) {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let values = obj["values"] as? [String: Any] {
            return values[id] as? Bool ?? false
        }
        if !settingsParseFailureLogged {
            settingsParseFailureLogged = true
            logEvent("settings parse failed at \(settingsPath); falling back to env/defaults")
        }
    }
    if let env = ProcessInfo.processInfo.environment[envKey] {
        return env == "true" || env == "1"
    }
    return false
}

private var settingsParseFailureLogged = false

private func readNotifyOnChange() -> Bool {
    readBoolSetting("notifyOnChange", envKey: "DYNAMICLAKE_SETTING_NOTIFY_ON_CHANGE")
}

private func readPersistOnDisconnect() -> Bool {
    readBoolSetting("persistOnDisconnect", envKey: "DYNAMICLAKE_SETTING_PERSIST_ON_DISCONNECT")
}

@discardableResult
private func sendTracked(_ client: JSONSocketClient, _ payload: [String: Any], _ label: String) -> Bool {
    do {
        try client.send(payload)
        return true
    } catch {
        logEvent("send failed \(label): \(error)")
        return false
    }
}

private var running = true

private func handleSignal(_ sig: Int32) {
    running = false
}

@main
private enum Main {
    static func main() {
        signal(SIGINT, handleSignal)
        signal(SIGTERM, handleSignal)
        signal(SIGPIPE, SIG_IGN)

        guard let socketPath = ProcessInfo.processInfo.environment[socketEnvironmentKey],
              !socketPath.isEmpty else {
            fputs("VPN Status: \(DynamicLakeSocketError.socketPathMissing(socketEnvironmentKey))\n", stderr)
            exit(64)
        }

        let client = JSONSocketClient(socketPath: socketPath)
        do {
            try client.connect()
            sendTracked(client, dismissPayload(), "startup dismiss")
            logEvent("startup features=\(pluginFeatures.isEmpty ? "none" : pluginFeatures.sorted().joined(separator: ",")) presentSneakPeek=\(supportsPresentSneakPeek)")
        } catch {
            fputs("VPN Status: \(error)\n", stderr)
            exit(65)
        }

        var published = false
        var lastRawConnectionKey = ""
        var stateConnected = false
        var lastBaseSig = ""
        var lastFullSig = ""
        var pendingPeekAt: Date?
        var prevConnected: Bool?
        var lastMode: Bool?
        var dismissAt: Date?
        var currentCountryCode = ""
        var currentCountryName = ""
        /// Last stabilized Proton exit IP. A Proton server switch does not
        /// necessarily change the service name or utun interface, so the exit
        /// IP is part of the effective Proton connection identity. NordVPN
        /// never reads or writes this.
        var protonStableExitIP = ""
        var countryGeneration: UInt64 = 0
        var countryConnectionKey = ""
        var nextCountryProbeAt: Date?
        var lastReassertAt: Date?
        let countryResolver = ExitCountryResolver()
        // Proton-only stabilized exit resolver. NordVPN and every other
        // provider keep using `countryResolver` above with unchanged behavior.
        let protonResolver = ProtonExitResolver(logger: logEvent)

        func reconnect() {
            client.close()
            do {
                try client.connect()
                logEvent("reconnected socket")
            } catch {
                logEvent("reconnect failed: \(error)")
            }
        }

        func connectionKey(for vpn: VPNStatus) -> String {
            if let service = vpn.serviceName {
                return "service|\(service)|\(vpn.serverAddress ?? "")"
            }
            return "route|\(vpn.provider ?? "")|\(vpn.routedInterface ?? "")"
        }

        while running {
            for response in client.receiveAvailable() {
                let isRejectedResponse = response["type"] as? String == "response" && response["ok"] as? Bool == false
                if (response["type"] as? String == "error" || isRejectedResponse),
                   let message = response["error"] as? String {
                    logEvent("dynamiclake error: \(message)")
                }
            }

            let notifyOnChange = readNotifyOnChange()

            if published, lastMode != notifyOnChange {
                sendTracked(client, dismissPayload(), "dismiss mode-switch")
                published = false
                dismissAt = nil
                pendingPeekAt = nil
                // Reset the surfaces signatures too, or the fresh mode's first
                // capsule/notification could be skipped as "unchanged".
                lastBaseSig = ""
                lastFullSig = ""
            }
            if lastMode != notifyOnChange {
                logEvent("mode=" + (notifyOnChange ? "notify" : "persistent"))
            }

            let now = Date()
            let vpn = getVPNStatus()

            // macOS keeps the previous session marked Connected for a poll or two
            // while a new VPN (e.g. NordVPN) finishes its handshake, and during the
            // overlap `scutil --nc list` can report either service. Hold a fresh
            // connection until the same one is seen twice so the stale provider
            // never reaches the notch. Disconnects stay instant.
            let rawConnectionKey = vpn.connected ? connectionKey(for: vpn) : ""
            var state = vpn
            if vpn.connected && !stateConnected && rawConnectionKey != lastRawConnectionKey {
                state.connected = false
            }
            stateConnected = state.connected
            lastRawConnectionKey = rawConnectionKey

            var connectionChanged = false
            var countryChanged = false

            if state.connected {
                let key = connectionKey(for: state)
                if key != countryConnectionKey {
                    countryGeneration &+= 1
                    countryConnectionKey = key
                    currentCountryCode = ""
                    currentCountryName = ""
                    protonStableExitIP = ""
                    nextCountryProbeAt = now.addingTimeInterval(countryLookupSettleSec)
                    connectionChanged = true
                    countryChanged = true

                    // The selected location (including virtual ones) comes from
                    // NordVPN's own data, not from where the hardware sits:
                    // NordWhisper exposes only the station IP as ServerAddress
                    // (no hostname), so legacy configs resolve via the
                    // *.nordvpn.com hostname label and station IPs resolve via
                    // Nord's public server catalog. On a virtual server like
                    // Armenia the geo-IP lookup can only ever report the
                    // physical country (BG), so a confirmed Nord location
                    // always overrides it.
                    var nordLocation: (code: String, source: String)?
                    if let code = nordServerCountryCode(from: state.serverAddress) {
                        nordLocation = (code, "server host")
                    } else if state.provider?.lowercased().contains("nord") == true,
                              let code = nordVirtualLocationCountryCode(forIPv4: state.serverAddress) {
                        nordLocation = (code, "virtual location table")
                    } else if state.provider?.lowercased().contains("nord") == true,
                              let addr = state.serverAddress, !addr.isEmpty {
                        // Never log IPs: address literals are reduced to their
                        // shape so an unexpected NordWhisper format shows up in
                        // the log without exposing the address.
                        logEvent("nord server address unresolved (\(serverAddressShape(addr))); using geo lookup")
                    }
                    if let location = nordLocation {
                        currentCountryCode = location.code
                        currentCountryName = Locale.current.localizedString(forRegionCode: location.code) ?? location.code
                        // Skip the geo lookup for this connection: it would
                        // contradict the selected location on virtual servers.
                        nextCountryProbeAt = nil
                        logEvent("country=\(location.code) (from \(location.source))")
                    }
                }
            } else if !countryConnectionKey.isEmpty || !currentCountryCode.isEmpty || !protonStableExitIP.isEmpty {
                countryGeneration &+= 1
                countryConnectionKey = ""
                currentCountryCode = ""
                currentCountryName = ""
                protonStableExitIP = ""
                nextCountryProbeAt = nil
                countryChanged = true
            }

            // Provider-specific exit lookup. ProtonVPN uses the stabilized
            // two-probe exit-IP resolver; every other provider (notably
            // NordVPN) uses the original single-shot country resolver with
            // unchanged behavior. The inactive path is drained so a provider
            // switch cannot leak the other path's pending result.
            let protonActive = state.connected && usesProtonStabilizedExit(provider: state.provider)
            if protonActive {
                _ = countryResolver.takeResult()
                if let result = protonResolver.takeResult() {
                    if result.generation != countryGeneration {
                        logEvent("stale exit lookup discarded generation=\(result.generation)")
                    } else if result.countryCode.isEmpty {
                        nextCountryProbeAt = now.addingTimeInterval(countryLookupRetrySec)
                    } else {
                        if !protonStableExitIP.isEmpty, protonStableExitIP != result.ip {
                            // Never log the IP itself, only that the exit moved.
                            logEvent("proton exit changed country=\(result.countryCode)")
                        }
                        protonStableExitIP = result.ip
                        if result.countryCode != currentCountryCode {
                            currentCountryCode = result.countryCode
                            currentCountryName = result.countryName
                            countryChanged = true
                            logEvent("country=\(result.countryCode)")
                            if pendingPeekAt != nil {
                                // A connect peek is waiting for this country: let the
                                // flag refresh go first (this poll), then present the
                                // peek on the refreshed, unchanged surfaces.
                                pendingPeekAt = min(pendingPeekAt ?? now, now.addingTimeInterval(peekCountryLeadSec))
                            }
                        }
                        nextCountryProbeAt = now.addingTimeInterval(protonExitRefreshIntervalSec)
                    }
                }
            } else {
                _ = protonResolver.takeResult()
                if let result = countryResolver.takeResult() {
                    if result.generation != countryGeneration {
                        logEvent("stale exit lookup discarded generation=\(result.generation)")
                    } else if result.code.isEmpty {
                        nextCountryProbeAt = now.addingTimeInterval(countryLookupRetrySec)
                    } else {
                        if result.code != currentCountryCode {
                            currentCountryCode = result.code
                            currentCountryName = result.name
                            countryChanged = true
                            logEvent("country=\(result.code)")
                            if pendingPeekAt != nil {
                                // A connect peek is waiting for this country: let the
                                // flag refresh go first (this poll), then present the
                                // peek on the refreshed, unchanged surfaces.
                                pendingPeekAt = min(pendingPeekAt ?? now, now.addingTimeInterval(peekCountryLeadSec))
                            }
                        }
                        nextCountryProbeAt = now.addingTimeInterval(countryRefreshIntervalSec)
                    }
                }
            }

            // A geo-derived country can be wrong for a virtual location: the
            // geo lookup reports the physical host country (e.g. BG for
            // Armenia) and keeps refreshing it every 15s. When the picked
            // location is recoverable from the station address, override the
            // geo value unconditionally. Bumping the generation also discards
            // the geo lookup still in flight for this connection so it cannot
            // clobber the correction on arrival.
            if state.connected,
               state.provider?.lowercased().contains("nord") == true,
               let code = nordVirtualLocationCountryCode(forIPv4: state.serverAddress),
               code != currentCountryCode {
                countryGeneration &+= 1
                currentCountryCode = code
                currentCountryName = Locale.current.localizedString(forRegionCode: code) ?? code
                nextCountryProbeAt = nil
                countryChanged = true
                logEvent("country=\(code) (from virtual location table)")
                if pendingPeekAt != nil {
                    // Same ordering as the resolver path: the flag refresh goes
                    // first (this poll), then the peek presents on the
                    // refreshed, unchanged surfaces.
                    pendingPeekAt = min(pendingPeekAt ?? now, now.addingTimeInterval(peekCountryLeadSec))
                }
            }

            if state.connected, let probeAt = nextCountryProbeAt, now >= probeAt {
                if routedTunnelInterface() == nil {
                    nextCountryProbeAt = now.addingTimeInterval(0.5)
                } else if protonActive, protonResolver.request(generation: countryGeneration) {
                    nextCountryProbeAt = nil
                } else if !protonActive, countryResolver.request(generation: countryGeneration) {
                    nextCountryProbeAt = nil
                }
            }

            // baseSig covers connect/disconnect/provider/server changes (each one
            // deserves a presented peek); the country code only refreshes surfaces.
            let baseSig = [
                state.connected ? "1" : "0",
                state.provider ?? "",
                state.protocol_ ?? "",
                state.serverAddress ?? "",
                state.routedInterface ?? ""
            ].joined(separator: "|")
            let sig = baseSig + "|" + currentCountryCode

            // Shared by both modes: present a scheduled peek via a delayed update
            // on unchanged surfaces (the only shape DynamicLake reliably honours).
            if let peekAt = pendingPeekAt, now >= peekAt {
                if shouldHoldPeekForCountry(connected: state.connected, countryCode: currentCountryCode) {
                    // Hold the peek until the country lookup resolves so the
                    // presentation always includes the flag. No timeout: while
                    // connected with an unknown country there is nothing
                    // correct to present yet. Disconnects are never held.
                    pendingPeekAt = now.addingTimeInterval(peekCountryRecheckSec)
                } else {
                    pendingPeekAt = nil
                }
                if pendingPeekAt == nil, published {
                    // The capsule/notification from the create is now established,
                    // so the peek update is honoured (same path as the disconnect
                    // peek and the v1.1.4 connect peek).
                    if !sendTracked(
                        client,
                        peekUpdatePayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName),
                        "post-create peek"
                    ) {
                        published = false
                        lastBaseSig = ""
                        lastFullSig = ""
                        reconnect()
                    } else {
                        logEvent("sneak peek presented")
                        // Sync the signatures so nothing re-sends these surfaces
                        // while the peek is on screen.
                        lastBaseSig = baseSig
                        lastFullSig = sig
                        // Notify mode (and the persistent disconnect capsule) dismiss
                        // on a timer set at create time; make sure the peek gets its
                        // full duration before that dismissal.
                        if let deadline = dismissAt {
                            dismissAt = max(deadline, now.addingTimeInterval(sneakPeekPresentationSec + 0.25))
                        }
                    }
                }
            }

            if notifyOnChange {
                if let prev = prevConnected {
                    var transition: (connected: Bool, provider: String?, countryCode: String, countryName: String)?
                    if state.connected && !prev {
                        transition = (true, state.provider, currentCountryCode, currentCountryName)
                        logEvent("notify-create connected=true provider=\(state.provider ?? "nil")")
                    } else if state.connected && prev && connectionChanged {
                        transition = (true, state.provider, currentCountryCode, currentCountryName)
                        logEvent("notify-create connection-changed provider=\(state.provider ?? "nil")")
                    } else if !state.connected && prev {
                        transition = (false, nil, "", "")
                        logEvent("notify-create connected=false")
                    }
                    if let n = transition {
                        if sendTracked(client, notifyPayload(connected: n.connected, provider: n.provider, countryCode: n.countryCode, countryName: n.countryName), "notify create") {
                            published = true
                            dismissAt = now.addingTimeInterval(notificationDurationSec)
                            // Same delayed peek as persistent mode: the shared peek
                            // block above presents it once the notification capsule
                            // is established (DynamicLake ignores peeks on creates).
                            pendingPeekAt = now.addingTimeInterval(peekDelaySec)
                        } else {
                            reconnect()
                        }
                    }
                }
                prevConnected = state.connected

                if published, state.connected, countryChanged, !currentCountryCode.isEmpty {
                    // The notification is still on screen: refresh it in place
                    // (add the flag) instead of re-presenting the sneak peek.
                    // When a peek is pending it is held for this country, so this
                    // refresh lands first and the shared peek block presents the
                    // peek on the refreshed surfaces next cycle.
                    sendTracked(
                        client,
                        peekUpdatePayload(connected: true, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName, presentPeek: false),
                        "country update"
                    )
                }

                if published, let deadline = dismissAt, now >= deadline {
                    if !sendTracked(client, dismissPayload(), "notify dismiss") {
                        logEvent("notify dismiss failed; dropping state")
                    }
                    published = false
                    dismissAt = nil
                    logEvent("dismiss (notification expired)")
                }
            } else {
                prevConnected = nil
                let persistDisconnected = readPersistOnDisconnect()

                if !state.connected && !persistDisconnected {
                    if published, dismissAt == nil {
                        if !sendTracked(
                            client,
                            peekUpdatePayload(connected: false, provider: nil, countryCode: "", countryName: ""),
                            "disconnect peek"
                        ) {
                            // The socket died mid-disconnect: drop the published
                            // state so the next poll rebuilds a fresh capsule for
                            // the peek instead of leaving a stale one stuck.
                            published = false
                            lastBaseSig = ""
                            lastFullSig = ""
                            reconnect()
                        } else {
                            dismissAt = now.addingTimeInterval(notificationDurationSec)
                            lastBaseSig = baseSig
                            lastFullSig = sig
                            logEvent("peek connected=false")
                        }
                    }
                    if published, let deadline = dismissAt, now >= deadline {
                        if !sendTracked(client, dismissPayload(), "dismiss disconnected") {
                            logEvent("dismiss failed; dropping published state")
                        }
                        published = false
                        dismissAt = nil
                    }
                } else {
                    dismissAt = nil
                    if baseSig != lastBaseSig {
                        pendingPeekAt = nil
                        if published {
                            // Surface change only — the peek is scheduled separately,
                            // since presentSneakPeek on a surface-changing update is
                            // ignored by DynamicLake.
                            if !sendTracked(
                                client,
                                peekUpdatePayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName, presentPeek: false),
                                "surface update"
                            ) {
                                published = false
                                lastBaseSig = ""
                                lastFullSig = ""
                                reconnect()
                            } else {
                                pendingPeekAt = now.addingTimeInterval(peekDelaySec)
                            }
                        } else if sendTracked(client, createPayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName), "create") {
                            published = true
                            lastReassertAt = now
                            // Present the peek shortly after the capsule appears:
                            // DynamicLake ignores presentSneakPeek on creates and
                            // on updates racing the create. While connected, the
                            // peek then also waits for the country (see above).
                            pendingPeekAt = now.addingTimeInterval(peekDelaySec)
                        }
                        lastBaseSig = baseSig
                        lastFullSig = sig
                    } else if published, sig != lastFullSig {
                        // Only the country flag changed: refresh the live activity
                        // in place instead of re-presenting the sneak peek. While a
                        // connect peek is pending this must go FIRST: DynamicLake
                        // ignores presentSneakPeek on an update that also changes
                        // surfaces, so the shared peek block presents the peek
                        // afterwards as a pure presentation update on the refreshed
                        // (unchanged) surfaces.
                        if sendTracked(
                            client,
                            peekUpdatePayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName, presentPeek: false),
                            "country update"
                        ) {
                            lastFullSig = sig
                        } else {
                            published = false
                            lastBaseSig = ""
                            lastFullSig = ""
                            reconnect()
                        }
                    } else if published, let last = lastReassertAt,
                              now.timeIntervalSince(last) >= reassertIntervalSec {
                        if sendTracked(client, createPayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName), "reassert create") {
                            lastReassertAt = now
                            lastFullSig = sig
                        } else {
                            published = false
                            lastBaseSig = ""
                            lastFullSig = ""
                            reconnect()
                        }
                    }
                }
            }

            lastMode = notifyOnChange
            let active = published && notifyOnChange
            Thread.sleep(forTimeInterval: active ? notificationPollIntervalSec : pollIntervalSec)
        }

        if published {
            try? client.send(dismissPayload())
        }
    }
}
