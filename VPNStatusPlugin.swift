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
private let pollIntervalSec: TimeInterval = 5
private let notificationDurationSec: TimeInterval = 4
private let notificationPollIntervalSec: TimeInterval = 0.5
private let geoLookupTimeoutSec: TimeInterval = 3
private let reassertIntervalSec: TimeInterval = 30
private let flagRepollIntervalSec: TimeInterval = 30
private let sneakPeekPresentationSec: Double = 2

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
}

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

/// True only when the ifconfig line carries a global (routed) IP address.
/// Link-local (fe80::/10), loopback, link-local IPv4, and ULA (fc00::/7)
/// addresses are present on macOS's always-on utun interfaces and must not
/// be mistaken for an active VPN tunnel.
private func hasGlobalIP(_ line: String) -> Bool {
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

private var cachedProvider: String?

private func getVPNStatus() -> VPNStatus {
    let disconnected = VPNStatus(connected: false, provider: nil, protocol_: nil, serviceName: nil, serverAddress: nil)
    let (out, _) = runProcess("/usr/sbin/scutil", arguments: ["--nc", "list"])
    if let str = String(data: out, encoding: .utf8) {
        for line in str.components(separatedBy: "\n") where line.contains("(Connected)") {
            let serviceName = quotedServiceName(in: line)
            guard !serviceName.isEmpty else { continue }
            let parts = serviceName.split(separator: " ", maxSplits: 1)
            let provider = parts.count == 2 ? String(parts[0]) : serviceName
            let proto = parts.count == 2 ? String(parts[1]) : serviceName
            return VPNStatus(connected: true, provider: provider, protocol_: proto, serviceName: serviceName, serverAddress: serverAddress(for: serviceName))
        }
    }

    let (ifData, _) = runProcess("/sbin/ifconfig", arguments: ["-a"], timeout: 3)
    let ifStr = String(data: ifData, encoding: .utf8) ?? ""
    var onUtun = false
    for line in ifStr.components(separatedBy: "\n") {
        if line.first?.isLetter == true {
            onUtun = line.hasPrefix("utun")
        }
        if onUtun, hasGlobalIP(line) {
            let provider = detectProviderFast() ?? "VPN"
            return VPNStatus(connected: true, provider: provider, protocol_: "WireGuard", serviceName: nil, serverAddress: nil)
        }
    }

    return disconnected
}

private func detectProviderFast() -> String? {
    if let cached = cachedProvider { return cached }
    let (out, _) = runProcess("/usr/bin/pgrep", arguments: ["-f", "com.nordvpn.macos.helper"])
    if let str = String(data: out, encoding: .utf8), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        cachedProvider = "NordVPN"
        return "NordVPN"
    }
    let (out2, _) = runProcess("/usr/bin/pgrep", arguments: ["-f", "com.protonvpn"])
    if let str = String(data: out2, encoding: .utf8), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        cachedProvider = "ProtonVPN"
        return "ProtonVPN"
    }
    return nil
}

/// Resolves the country the traffic actually exits through by asking ip-api for
/// the caller's own public IP (while connected, that is the VPN exit node).
/// This is ground truth regardless of whether the VPN client exposes a server
/// address via scutil — ProtonVPN does not — and it self-corrects when the user
/// switches country without disconnecting. ip-api's free tier is HTTP-only,
/// so HTTP is tried first.
private func resolveExitCountry() -> (code: String, name: String, exitIP: String)? {
    for scheme in ["http", "https"] {
        guard let url = URL(string: "\(scheme)://ip-api.com/json/?fields=status,countryCode,country,query") else { continue }
        var result: (String, String, String)?
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = geoLookupTimeoutSec
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["status"] as? String == "success",
                  let code = obj["countryCode"] as? String, code.count == 2,
                  let ip = obj["query"] as? String, !ip.isEmpty else { return }
            let name = obj["country"] as? String ?? ""
            result = (code, name, ip)
        }.resume()
        if semaphore.wait(timeout: .now() + geoLookupTimeoutSec) == .success, let r = result {
            return r
        }
    }
    return nil
}

private func flagEmoji(countryCode: String) -> String {
    guard countryCode.count == 2 else { return "" }
    let base: UInt32 = 0x1F1E6
    var scalars = String.UnicodeScalarView()
    for scalar in countryCode.uppercased().unicodeScalars {
        guard scalar.value >= 65, scalar.value <= 90 else { return "" }
        scalars.append(UnicodeScalar(base + scalar.value - 65)!)
    }
    return String(scalars)
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

private func flagSlot(_ flag: String) -> [String: Any]? {
    guard !flag.isEmpty else { return nil }
    return ["type": "text", "id": "vpn-flag", "text": flag]
}

private func compactSurface(connected: Bool, provider: String?, flag: String = "") -> [String: Any] {
    var surface: [String: Any] = ["leftSlot": connected ? vpnIconPayload(for: provider) : disconnectedIcon()]
    if let slot = flagSlot(flag) {
        surface["rightSlot"] = slot
    }
    return surface
}

private func statusSneakPeek(connected: Bool, provider: String?, flag: String, countryName: String) -> [String: Any] {
    var detail = connected ? "Connected" : "VPN Disconnected"
    if connected, !countryName.isEmpty { detail += " — \(countryName)" }
    var surface: [String: Any] = [
        "leftSlot": connected ? vpnIconPayload(for: provider) : disconnectedIcon(),
        "center": [
            "type": "text",
            "id": "vpn-detail",
            "text": detail,
            "style": "compact"
        ]
    ] as [String: Any]
    if let slot = flagSlot(flag) {
        surface["rightSlot"] = slot
    }
    return surface
}

private func createPayload(connected: Bool, provider: String?, flag: String, countryName: String = "") -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "requestID": "create-vpn",
        "type": "create",
        "activityID": activityID,
        "title": pluginName,
        "priority": "low",
        "size": "small",
        "surfaces": [
            "compactLiveActivity": compactSurface(connected: connected, provider: provider, flag: flag),
            "extraLiveActivity": compactSurface(connected: connected, provider: provider, flag: flag),
            "sneakPeek": statusSneakPeek(connected: connected, provider: provider, flag: flag, countryName: countryName)
        ] as [String: Any]
    ]
}

private var updateSequence: UInt64 = 0

private func updatePayload(_ vpn: VPNStatus, flag: String, countryName: String) -> [String: Any] {
    updateSequence += 1
    return [
        "schemaVersion": schemaVersion,
        "requestID": "update-\(updateSequence)",
        "type": "update",
        "activityID": activityID,
        "surfaces": [
            "compactLiveActivity": compactSurface(connected: vpn.connected, provider: vpn.provider, flag: flag),
            "extraLiveActivity": compactSurface(connected: vpn.connected, provider: vpn.provider, flag: flag),
            "sneakPeek": statusSneakPeek(connected: vpn.connected, provider: vpn.provider, flag: flag, countryName: countryName)
        ] as [String: Any]
    ]
}

private func notifyComponents(connected: Bool, provider: String?, flag: String, countryName: String) -> (icon: [String: Any], surfaces: [String: Any]) {
    let icon: [String: Any] = connected
        ? vpnIconPayload(for: provider)
        : disconnectedIcon()
    var detail = connected ? "VPN Connected" : "VPN Disconnected"
    if connected, !countryName.isEmpty { detail += " — \(countryName)" }
    var sneakPeek: [String: Any] = [
        "leftSlot": icon,
        "center": [
            "type": "text",
            "id": "vpn-detail",
            "text": detail,
            "style": "compact"
        ]
    ]
    if let slot = flagSlot(flag) {
        sneakPeek["rightSlot"] = slot
    }
    let surfaces: [String: Any] = [
        "compactLiveActivity": compactSurface(connected: connected, provider: provider, flag: flag),
        "extraLiveActivity": compactSurface(connected: connected, provider: provider, flag: flag),
        "sneakPeek": sneakPeek
    ]
    return (icon, surfaces)
}

private func notifyPayload(connected: Bool, provider: String?, flag: String, countryName: String) -> [String: Any] {
    updateSequence += 1
    let (_, surfaces) = notifyComponents(connected: connected, provider: provider, flag: flag, countryName: countryName)
    return [
        "schemaVersion": schemaVersion,
        "requestID": "notify-\(updateSequence)",
        "type": "create",
        "activityID": activityID,
        "title": pluginName,
        "priority": "high",
        "size": "normal",
        "surfaces": surfaces
    ]
}

private func peekUpdatePayload(connected: Bool, provider: String?, flag: String, countryName: String) -> [String: Any] {
    updateSequence += 1
    let (_, surfaces) = notifyComponents(connected: connected, provider: provider, flag: flag, countryName: countryName)
    var payload: [String: Any] = [
        "schemaVersion": schemaVersion,
        "requestID": "peek-\(updateSequence)",
        "type": "update",
        "activityID": activityID,
        "surfaces": surfaces
    ]
    if supportsPresentSneakPeek {
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
       let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let values = obj["values"] as? [String: Any] {
        return values[id] as? Bool ?? false
    }
    if let env = ProcessInfo.processInfo.environment[envKey] {
        return env == "true" || env == "1"
    }
    return false
}

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
        var lastSig = ""
        var prevConnected: Bool?
        var lastMode: Bool?
        var dismissAt: Date?
        var currentFlag = ""
        var currentCountryName = ""
        var lastFlagProbeAt: Date?
        var lastServerKey = ""
        var lastReassertAt: Date?

        func reconnect() {
            client.close()
            do {
                try client.connect()
                logEvent("reconnected socket")
            } catch {
                logEvent("reconnect failed: \(error)")
            }
        }

        /// Probes the exit country when the server key changes or at most once
        /// per flagRepollIntervalSec, so a country switch (even one that keeps
        /// the same scutil ServerAddress) refreshes the flag without a
        /// disconnect/reconnect. Failed lookups retry on the next cycle.
        func flagFor(_ vpn: VPNStatus) -> String {
            guard vpn.connected else {
                currentFlag = ""
                lastServerKey = ""
                lastFlagProbeAt = nil
                return ""
            }
            let serverKey = vpn.serverAddress ?? ""
            let serverChanged = serverKey != lastServerKey
            let due = lastFlagProbeAt.map { Date().timeIntervalSince($0) >= flagRepollIntervalSec } ?? true
            guard serverChanged || due else { return currentFlag }
            lastServerKey = serverKey
            lastFlagProbeAt = Date()
            if let r = resolveExitCountry() {
                let newFlag = flagEmoji(countryCode: r.code)
                if newFlag != currentFlag || r.name != currentCountryName {
                    currentFlag = newFlag
                    currentCountryName = r.name
                    logEvent("flag=\(newFlag) country=\(r.name) exit=\(r.exitIP)")
                }
            }
            return currentFlag
        }

        while running {
            for response in client.receiveAvailable() {
                if response["type"] as? String == "error", let message = response["error"] as? String {
                    logEvent("dynamiclake error: \(message)")
                }
            }

            let notifyOnChange = readNotifyOnChange()

            if published, lastMode != notifyOnChange {
                sendTracked(client, dismissPayload(), "dismiss mode-switch")
                published = false
                dismissAt = nil
            }
            if lastMode != notifyOnChange {
                logEvent("mode=" + (notifyOnChange ? "notify" : "persistent"))
            }

            let vpn = getVPNStatus()
            let sig = "\(vpn.connected)|\(vpn.provider ?? "")|\(vpn.protocol_ ?? "")|\(vpn.serverAddress ?? "")"
            let flag = vpn.connected ? flagFor(vpn) : ""

            if notifyOnChange {
                if let prev = prevConnected {
                    var transition: (connected: Bool, provider: String?, flag: String)?
                    if vpn.connected && !prev {
                        transition = (true, vpn.provider, flag)
                        logEvent("notify-create connected=true provider=\(vpn.provider ?? "nil") ip=\(vpn.serverAddress ?? "nil") flag=\(flag)")
                    } else if !vpn.connected && prev {
                        transition = (false, nil, "")
                        logEvent("notify-create connected=false")
                    }
                    if let n = transition {
                        if sendTracked(client, notifyPayload(connected: n.connected, provider: n.provider, flag: n.flag), "notify create") {
                            sendTracked(client, peekUpdatePayload(connected: n.connected, provider: n.provider, flag: n.flag), "peek present")
                            published = true
                            dismissAt = Date().addingTimeInterval(notificationDurationSec)
                        } else {
                            reconnect()
                        }
                    }
                }
                prevConnected = vpn.connected

                if published, let deadline = dismissAt, Date() >= deadline {
                    if !sendTracked(client, dismissPayload(), "notify dismiss") {
                        logEvent("notify dismiss failed; dropping state")
                    }
                    published = false
                    dismissAt = nil
                    logEvent("dismiss (notification expired)")
                }
            } else {
                prevConnected = nil
                dismissAt = nil
                let persistDisconnected = readPersistOnDisconnect()
                if !vpn.connected && !persistDisconnected {
                    if published {
                        if !sendTracked(client, dismissPayload(), "dismiss disconnected") {
                            logEvent("dismiss failed; dropping published state")
                        }
                        published = false
                        lastSig = sig
                    }
                } else if sig != lastSig {
                    if published {
                        if !sendTracked(client, updatePayload(vpn, flag: flag), "update") {
                            published = false
                            lastSig = ""
                            reconnect()
                        }
                    } else {
                        if sendTracked(client, createPayload(connected: vpn.connected, provider: vpn.provider, flag: flag), "create") {
                            published = true
                            lastReassertAt = Date()
                        }
                    }
                    if published {
                        sendTracked(client, peekUpdatePayload(connected: vpn.connected, provider: vpn.provider, flag: flag), "peek transition")
                    }
                    lastSig = sig
                } else if published, let last = lastReassertAt,
                          Date().timeIntervalSince(last) >= reassertIntervalSec {
                    if sendTracked(client, createPayload(connected: vpn.connected, provider: vpn.provider, flag: flag), "reassert create") {
                        lastReassertAt = Date()
                    } else {
                        published = false
                        lastSig = ""
                        reconnect()
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
