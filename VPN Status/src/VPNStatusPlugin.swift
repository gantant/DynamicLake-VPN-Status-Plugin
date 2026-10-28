import AppKit
import Foundation

private let schemaVersion = 1
private let pluginName = "VPN Status"
private let activityID = "vpn-status"
/// Where debug events go. The override exists so the test suite can drive the
/// real binary without writing its traffic into the user's log (a fabricated
/// rejection line sitting in a real log is indistinguishable from a live
/// failure when someone is debugging).
private let logPath = {
    if let override = ProcessInfo.processInfo.environment["DYNAMICLAKE_PLUGIN_LOG_PATH"], !override.isEmpty {
        return override
    }
    return NSHomeDirectory() + "/Library/Logs/vpn-status.log"
}()

private let logMaxBytes: UInt64 = 256 * 1024
private let logKeepBytes: UInt64 = 64 * 1024
/// The same event repeated within this window is suppressed, so a hot retry
/// loop adds at most one line per minute instead of one per pass.
private let logRepeatWindowSec: TimeInterval = 60

private let logLock = NSLock()
private let logTimestampFormatter = ISO8601DateFormatter()
private var lastLogMessage: String?
private var lastLogAt: Date?
private var suppressedLogRepeats = 0

/// Appends a timestamped event to ~/Library/Logs/vpn-status.log. Deliberately
/// bounded so it can never bloat the user's disk:
/// - Consecutive identical events within `logRepeatWindowSec` collapse into
///   one line with a repeat count.
/// - The file rotates at `logMaxBytes`, keeping the most recent
///   `logKeepBytes`.
/// Called from the main queue and from resolver completion queues, so the lock
/// keeps the suppression state and the writes consistent across threads.
/// Public IP addresses are never logged.
///
/// The message is flattened onto one line: host-supplied error text reaches
/// this function verbatim, and a newline in it would fabricate log entries
/// (the log is the only diagnostic anyone has when something goes wrong).
func logEvent(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }

    let now = Date()
    let withinWindow: Bool
    if message == lastLogMessage, let last = lastLogAt {
        withinWindow = now.timeIntervalSince(last) < logRepeatWindowSec
    } else {
        withinWindow = false
    }

    // A repeat run of the previous message ends here — a different message
    // arrived, or the same one after the window expired. Emit its suppressed
    // count as its own line so the count is never misattributed.
    if suppressedLogRepeats > 0, !withinWindow, let lastMsg = lastLogMessage {
        writeLogLine("\(logTimestampFormatter.string(from: lastLogAt ?? now)) \(lastMsg) (suppressed \(suppressedLogRepeats) repeats)")
        suppressedLogRepeats = 0
    }

    if withinWindow {
        suppressedLogRepeats += 1
        return
    }

    lastLogMessage = message
    lastLogAt = now
    writeLogLine("\(logTimestampFormatter.string(from: now)) \(flattened(message))")
}

/// One line, always: control characters are replaced so a message can never
/// inject a fabricated entry into the log.
private func flattened(_ message: String) -> String {
    let sanitized = message.unicodeScalars.map { scalar -> Character in
        CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            ? " " : Character(scalar)
    }
    return String(sanitized).trimmingCharacters(in: .whitespaces)
}

/// Appends one formatted line. Callers hold the log lock.
///
/// The file is created 0600: it names providers, countries and errors, and a
/// world-readable log in ~/Library/Logs is readable by every process on the
/// machine. An existing file keeps its mode, so the fix applies to new logs.
private func writeLogLine(_ line: String) {
    let dir = (logPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let text = line + "\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
    } else {
        try? Data(text.utf8).write(to: URL(fileURLWithPath: logPath), options: .withoutOverwriting)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
    }
    trimLogIfNeeded()
}

/// Rewrites the log with only its most recent `logKeepBytes` (starting at a
/// line boundary) once it exceeds `logMaxBytes`. Called with the log lock held.
private func trimLogIfNeeded() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
          let size = (attrs[.size] as? NSNumber)?.uint64Value,
          size > logMaxBytes else { return }
    guard let h = FileHandle(forReadingAtPath: logPath) else { return }
    defer { try? h.close() }
    h.seek(toFileOffset: size - logKeepBytes)
    var data = h.readData(ofLength: Int(logKeepBytes) + 1)
    if let nl = data.firstIndex(of: UInt8(ascii: "\n")) {
        data = data.subdata(in: (nl + 1)..<data.count)
    }
    try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
}
private let socketEnvironmentKey = "DYNAMICLAKE_JSON_SOCKET"
private let settingsPathEnvironmentKey = "DYNAMICLAKE_PLUGIN_SETTINGS_PATH"
/// Timings below are one-shot deadlines, not a cadence. The plugin has no poll
/// loop: it renders when a status source fires, when DynamicLake sends a frame,
/// or when one of these deadlines comes due, and it sleeps in the run loop in
/// between. Nothing here re-arms itself except the country retry, which is
/// bounded (`countryProbeMaxAttempts`) and stops as soon as it has an answer.
private let notificationDurationSec: TimeInterval = 4
private let geoLookupTimeoutSec: TimeInterval = 2
private let countryLookupSettleSec: TimeInterval = 0.8
private let countryLookupRetrySec: TimeInterval = 2
/// How many times a failed exit-country lookup is retried before the plugin
/// waits for the next real event instead. Six attempts over ~10s covers a slow
/// DHCP/tunnel handshake without leaving a timer running for the session.
private let countryProbeMaxAttempts = 6
/// A connection seen for the first time is held back one beat, so the provider
/// that is still tearing down cannot flash its name on the card. The wait is a
/// single deadline: the confirm pass runs as soon as it comes due.
private let connectionConfirmDelaySec: TimeInterval = 0.15
private let sneakPeekPresentationSec: Double = 2
/// DynamicLake only honours `presentSneakPeek` on updates, and swallows one sent
/// in the same breath as the create — so the connect peek is presented via a
/// short-delayed update, once the capsule is established. The delay only needs
/// to exceed DynamicLake's create materialization time (single-digit ms); 150ms
/// keeps a wide safety margin while making the peek feel instant.
private let peekDelaySec: TimeInterval = 0.15
/// Peeks scheduled after a *surface-changing* update (server switch while
/// connected) need a slightly longer settle: DynamicLake is still applying
/// the changed surfaces and swallows a peek frame arriving too soon after
/// one — 0.15s works after a create but not here.
private let peekAfterSurfaceUpdateSec: TimeInterval = 0.4
/// On connect, the peek waits for the exit-country lookup so it always shows
/// logo + country + flag in one presentation — it never peeks without the
/// country while connected. Disconnect peeks are unaffected (no country).
/// Once the country arrives while a peek is pending, the flag refresh is sent
/// first; the peek follows this much later as a pure presentation update.
/// Ordering on the socket is already FIFO, so this only needs to cover
/// DynamicLake's per-frame apply latency.
private let peekCountryLeadSec: TimeInterval = 0.1

private let pluginFeatures: Set<String> = Set(
    (ProcessInfo.processInfo.environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "").split(separator: ",").map(String.init)
)
private let supportsPresentSneakPeek = pluginFeatures.contains("presentSneakPeek")
/// A lake needs both features: `lake` enables the manifest key, the command
/// and the lakeOpened/lakeClosed events, while `lakeLayout` enables everything
/// this card is built from (stacks, spacer, buttons, timer). Older DynamicLake
/// builds advertise neither, so the plugin simply never sends a lake frame.
private let supportsLake = pluginFeatures.contains("lake") && pluginFeatures.contains("lakeLayout")
/// imageAssets raises the frame limit to 256 KB and lets a picture be
/// registered once and referenced by id. Without it the plugin keeps sending
/// the same artwork inline, exactly as 1.2.1 did.
private let supportsImageAssets = pluginFeatures.contains("imageAssets")

/// Provider logos are registered as assets for the current connection. The
/// registration is cleared by DynamicLake when the socket drops, so the main
/// loop re-registers after every reconnect. Empty means "nothing registered
/// for the current provider" (the generic SF Symbol logo); the loop compares
/// this against the live provider so the logo is sent once per connection.
private var registeredLogoProvider: String = ""

private struct VPNStatus {
    var connected: Bool
    var provider: String?
    var protocol_: String?
    var serviceName: String?
    var serverAddress: String?
    var routedInterface: String?
    /// Identifies the tunnel session itself (the NetworkExtension connection's
    /// start date). Server switches start a new session, so including it in the
    /// connection key keeps switch detection working even when the config-level
    /// server address never changes. A routed tunnel (no configuration at all)
    /// has no session to identify and leaves this nil.
    var sessionID: String?
    /// Exact start of the current session when the source reports one. A routed
    /// tunnel has none, so the lake's session timer is only shown when this is
    /// present — never as an estimate.
    var sessionStart: Date?
    /// True when this status came from a transparent-proxy configuration
    /// rather than a tunnel. A proxy installs no route, so nothing on the
    /// routing-table side applies to it and its NE connection is the only
    /// evidence there is.
    var isProxy: Bool = false
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
    /// Fires on the URLSession queue when a lookup finishes, so the plugin can
    /// apply the result without polling `takeResult`.
    var onResult: (() -> Void)?

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
        onResult?()
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

/// The answer when nothing is up. No provider, no session: the card names the
/// last provider that was actually connected, not a configured one.
private let disconnectedStatus = VPNStatus(
    connected: false,
    provider: nil,
    protocol_: nil,
    serviceName: nil,
    serverAddress: nil,
    routedInterface: nil,
    sessionID: nil,
    sessionStart: nil
)

/// Status resolution for the main queue: the NetworkExtension event mirror
/// first, then the routing table.
///
/// Both answers are read in process, so this runs on every event with no
/// subprocess and no timer:
///
/// - `NEVPNWatcher` holds every tunnel the system has a configuration for and
///   updates it from `NEVPNStatusDidChange`;
/// - `RouteTable` names the interface the default path leaves through, which is
///   the only evidence available for a tunnel that no configuration describes
///   (a client's own root-helper utun).
///
/// The scutil fallback that used to sit behind both is gone. It spawned
/// `scutil --nc list` (plus `--nc status` while connected) on every tick —
/// roughly 43,000 launches a day while disconnected, and two more spawns per
/// tick on the sanity checks that verified NE against it. The routing table
/// answers the same question without a process, and NE answers it exactly.
private func resolveStatus() -> VPNStatus {
    if let status = neStatusSnapshot() { return status }
    return routedTunnelStatus() ?? disconnectedStatus
}

/// What a routed tunnel is called when nothing in the system names it.
///
/// A process scan used to fill this in, and it lied: VPN clients keep their
/// helpers running while disconnected, so whichever brand happened to be
/// installed got blamed for someone else's tunnel — X-VPN's idle helper named a
/// Hotspot Shield connection. Without root there is no way to learn which
/// process owns a `utun`, so the honest label is the generic one. A tunnel with
/// an NE configuration is named by that configuration (`anyStatus`), which is
/// how a provider this plugin has no mapping for still shows its real name.
private let unnamedRoutedProvider = "VPN"

/// What the last routed check answered, only so a transition is logged once.
private var lastRoutedProbe: VPNStatus?

/// A connected VPN that installed its own tunnel. It owns the default route
/// while every NetworkExtension configuration knows nothing about it, which is
/// how a root-helper client (X-VPN) connects.
///
/// There is no timer and no subprocess here: the kernel answers "which
/// interface carries the default route" in process, so this is read on the
/// event that woke the plugin like any other lookup.
private func routedTunnelStatus() -> VPNStatus? {
    let routedInterface = PathWatcher.tunnelInterface()
    var status: VPNStatus?
    if let iface = routedInterface,
       PathWatcher.isTunnelInterface(iface),
       PathWatcher.routedInterfaceExists(iface) {
        if lastRoutedProbe == nil {
            logEvent("routed tunnel \(iface) connected; owner not identifiable without privilege")
        }
        status = VPNStatus(
            connected: true,
            provider: unnamedRoutedProvider,
            protocol_: "WireGuard",
            serviceName: nil,
            serverAddress: nil,
            routedInterface: iface,
            sessionID: nil,
            sessionStart: nil
        )
    }
    if lastRoutedProbe != nil, status == nil,
       let iface = lastRoutedProbe?.routedInterface {
        logEvent("routed tunnel \(iface) disconnected")
    }
    lastRoutedProbe = status
    return status
}

/// Snapshot of the tunnels: a connected tunnel wins over a connecting one, and
/// nothing known at all returns nil (the caller then reports what the routing
/// table says).
private func neStatusSnapshot() -> VPNStatus? {
    let nord = NEVPNWatcher.bestStatus(target: .nord)
    let proton = NEVPNWatcher.bestStatus(target: .proton)
    for s in [nord, proton].compactMap({ $0 }) where s.connected {
        return neStatusToVPNStatus(s)
    }
    // A proxy-only VPN (X-VPN-style apps) has no tunnel at all, so it is its
    // own status source. Tunnels win when one is up: a connected tunnel is the
    // path traffic actually takes, while a tunnel provider's proxy is only an
    // auxiliary route and is never reported on its own.
    let proxy = NEVPNWatcher.proxyStatus()
    if let proxy, proxy.connected {
        return neStatusToVPNStatus(proxy)
    }
    // A tunnel from a provider this plugin has no name mapping for (Hotspot
    // Shield, a vendor's own WireGuard build) is still a VPN, and its own
    // configuration names it. Read here rather than from the route table so the
    // card shows the real brand instead of the generic label.
    let other = NEVPNWatcher.anyStatus()
    if let other, other.connected {
        return neStatusToVPNStatus(other)
    }
    // A VPN that installed its own tunnel (no NE configuration at all) is the
    // next best answer: it owns the default route, so traffic is on it now.
    if let routed = routedTunnelStatus() {
        return routed
    }
    if let connecting = [nord, proton].compactMap({ $0 }).first(where: { $0.connecting }) {
        // Mid-handshake: report the provider as connecting-but-not-connected
        // and let the connection hold gate the peek until it is really up.
        var s = neStatusToVPNStatus(connecting)
        s.connected = false
        return s
    }
    if let proxy, proxy.connecting {
        var s = neStatusToVPNStatus(proxy)
        s.connected = false
        return s
    }
    if let other, other.connecting {
        var s = neStatusToVPNStatus(other)
        s.connected = false
        return s
    }
    if nord != nil || proton != nil || proxy != nil || other != nil {
        // Configurations exist but none is up: authoritative disconnected,
        // straight from the event mirror. No provider is named here — the
        // card names the provider that was last *connected* (the caller
        // remembers it), so a disconnected card can never claim a session that
        // belonged to a different VPN, or invent one that never happened.
        return disconnectedStatus
    }
    return nil
}

private func neStatusToVPNStatus(_ s: NEVPNWatcher.Status) -> VPNStatus {
    VPNStatus(
        connected: s.connected,
        provider: s.provider,
        // A transparent proxy is not a tunnel protocol: naming one here would
        // be a guess about how the vendor moves the traffic.
        protocol_: s.isProxy ? "Proxy" : nil,
        serviceName: s.serviceName,
        serverAddress: s.serverAddress,
        routedInterface: nil,
        sessionID: s.startDate.map { String(Int64($0.timeIntervalSince1970 * 1000)) },
        sessionStart: s.startDate,
        isProxy: s.isProxy
    )
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

/// Image slots prefer the registered asset (imageAssets feature) and fall back
/// to the inline payload every older DynamicLake build understands. The asset
/// forms are only used once the matching data has actually been registered for
/// the current provider/country, so a reference can never show a placeholder.
private func providerIconSlot(_ provider: String?) -> [String: Any] {
    let key = provider ?? ""
    if supportsImageAssets, !key.isEmpty, registeredLogoProvider == key, providerIconBase64(for: provider) != nil {
        return ["type": "image", "id": "vpn-icon", "source": "asset", "assetID": "vpn-logo"]
    }
    return vpnIconPayload(for: provider)
}

/// The flag is always sent inline. An `asset` reference resolves fine in the
/// compact activity but rendered nothing in the lake's header slot, and the
/// artwork is a 64×64 PNG of about 2 KB, so registering it buys nothing worth
/// the blank slot the user sees when a reference fails to resolve.
private func flagSlot(_ countryCode: String) -> [String: Any]? {
    countryFlagImagePayload(countryCode: countryCode)
}

/// The flag slot at a point size. `size` is an image/button field: the emoji
/// fallback `flagSlot` returns when the packaged artwork cannot be read is a
/// TEXT component, and an unknown field on a component rejects the entire lake
/// command (the same strictness that rejects a `top` padding inset), which would
/// leave the user with DynamicLake's fallback card. So the size is only set on
/// an image, and the emoji keeps its own font size.
private func sizedFlagSlot(_ countryCode: String, size: Double) -> [String: Any]? {
    guard var slot = flagSlot(countryCode) else { return nil }
    if slot["type"] as? String == "image" {
        slot["size"] = size
    }
    return slot
}

/// Registers the provider logo for the live provider once per connection or
/// change. Assets are dropped by DynamicLake when the socket closes, so the
/// reconnect path clears the marker and the next pass re-registers.
private func ensureAssets(_ client: JSONSocketClient, provider: String?) {
    guard supportsImageAssets else { return }
    let providerKey = provider ?? ""
    if providerKey != registeredLogoProvider {
        if let base64 = providerIconBase64(for: provider) {
            // Mark only after a successful frame: a failed asset send must
            // leave the surfaces on their inline fallback until it retries.
            if sendTracked(client, assetPayload(id: "vpn-logo", requestID: "asset-logo", base64: base64), "asset logo") {
                registeredLogoProvider = providerKey
            }
        } else {
            registeredLogoProvider = providerKey
        }
    }
}

private func assetPayload(id: String, requestID: String, base64: String) -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "requestID": requestID,
        "type": "asset",
        "asset": [
            "id": id,
            "mimeType": "image/png",
            "base64Data": base64
        ]
    ] as [String: Any]
}

private func compactSurface(connected: Bool, provider: String?, countryCode: String) -> [String: Any] {
    var surface: [String: Any] = ["leftSlot": connected ? providerIconSlot(provider) : disconnectedIcon()]
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
    ["leftSlot": connected ? providerIconSlot(provider) : disconnectedIcon()]
}

/// Shared sneak-peek shape: provider logo + detail text + optional country flag.
/// Used by both persistent-mode and notify-mode peeks.
private func makeSneakPeek(connected: Bool, provider: String?, countryCode: String, detail: String) -> [String: Any] {
    var peek: [String: Any] = [
        "leftSlot": connected ? providerIconSlot(provider) : disconnectedIcon(),
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

/// Connect creates go out at notification priority so the connect Sneak Peek
/// presents like a banner; after the peek's presentation window an update
/// (see demotePayload) returns the activity to the persistent profile.
/// Deliberately the SAME size as the resting capsule: changing size between
/// the two phases re-lays-out the compact surface and visibly shifts the
/// logo/flag by a few pixels — only the priority may differ.
private func connectCreatePayload(connected: Bool, provider: String?, countryCode: String, countryName: String) -> [String: Any] {
    makeCreatePayload(connected: connected, provider: provider, countryCode: countryCode, countryName: countryName, priority: "high", size: "small")
}

private func makeCreatePayload(connected: Bool, provider: String?, countryCode: String, countryName: String, priority: String, size: String) -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "requestID": "create-vpn",
        "type": "create",
        "activityID": activityID,
        "title": pluginName,
        "priority": priority,
        "size": size,
        "surfaces": [
            "compactLiveActivity": compactSurface(connected: connected, provider: provider, countryCode: countryCode),
            "sneakPeek": statusSneakPeek(connected: connected, provider: provider, countryCode: countryCode, countryName: countryName),
            "extraLiveActivity": extraLiveActivitySurface(connected: connected, provider: provider)
        ] as [String: Any]
    ]
}

/// Drops the activity back to the persistent profile after the connect peek.
/// Only the priority changes (size stays untouched) so the capsule geometry
/// never shifts. Whether DynamicLake re-evaluates priority on updates is
/// undocumented; when it ignores the field this frame is a harmless refresh.
private func demotePayload(connected: Bool, provider: String?, countryCode: String, countryName: String) -> [String: Any] {
    updateSequence += 1
    var payload = peekUpdatePayload(connected: connected, provider: provider, countryCode: countryCode, countryName: countryName, presentPeek: false)
    payload["priority"] = "low"
    payload["requestID"] = "demote-\(updateSequence)"
    return payload
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
    let payload: [String: Any] = [
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

/// Launch the installed provider app. Bundle identifiers rather than URL
/// schemes: both apps expose several schemes, and LaunchServices resolves the
/// bundle id wherever the app actually lives — /Applications, ~/Applications,
/// a renamed copy like "NordVPN 2.app", or an App Store install. The same
/// resolver decides whether the lake's logo is pressable, so a provider whose
/// app is not installed never gets a dead control.
private let providerBundleIdentifiers: [String: String] = [
    "ProtonVPN": "ch.protonvpn.mac",
    "NordVPN": "com.nordvpn.NordVPN"
]

/// Successful lookups only; a miss is retried when the lake is next built, so
/// installing the app while the plugin runs is picked up without a restart.
private var resolvedProviderApps: [String: URL] = [:]

private func providerAppURL(_ provider: String?) -> URL? {
    guard let provider = provider, let bundleID = providerBundleIdentifiers[provider] else { return nil }
    if let cached = resolvedProviderApps[provider] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return nil
    }
    resolvedProviderApps[provider] = url
    return url
}

private func openProviderApp(provider: String?) {
    guard let url = providerAppURL(provider) else {
        logEvent("open app: no installed app for \(provider ?? "unknown provider")")
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error = error {
            logEvent("open app failed: \(error.localizedDescription)")
        } else {
            logEvent("open app: \(url.lastPathComponent)")
        }
    }
}

/// The session timer is DynamicLake's own `timer` component, not text this
/// plugin renders. The host ticks it, so the card is no longer patched once a
/// second, and the timer has a slot of its own instead of sharing the state
/// line — which is where it used to be clipped once it grew past `5:07`.
///
/// `timer` takes ISO-8601 dates (`2026-10-25T18:00:00Z` in the docs) and counts
/// down to `endDate` unless `countsDown` is false, when it counts up from
/// `startDate`. Its format is the host's, so the price of a live timer is that
/// the host decides how it reads.
private let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// How long a count-up session timer is armed for, and how close to the end of
/// that window the card is re-sent with a fresh one.
///
/// `timer` requires an `endDate` and stops counting there, so a session longer
/// than the window would freeze the clock. Re-arming before the end costs one
/// lake command per window roll — never a poll, and never a stopped timer.
private let sessionTimerWindow: TimeInterval = 24 * 3600
private let sessionTimerRearmMargin: TimeInterval = 2 * 3600

/// The armed window, so an unchanged session keeps the same card (and the same
/// `LakeCardInputs` signature) until the re-arm margin is reached.
private var armedSessionTimer: (start: Date, end: Date)?

private func sessionTimerEnd(start: Date, now: Date) -> Date {
    if let armed = armedSessionTimer,
       armed.start == start,
       armed.end.timeIntervalSince(now) > sessionTimerRearmMargin {
        return armed.end
    }
    let end = now.addingTimeInterval(sessionTimerWindow)
    armedSessionTimer = (start, end)
    return end
}

/// The session timer as the host renders it. The count-up starts at the
/// connection's own start date, so it is never an estimate.
private func lakeTimerSlot(start: Date, end: Date) -> [String: Any] {
    [
        "type": "timer",
        "id": "session-timer",
        "startDate": iso8601.string(from: start),
        "endDate": iso8601.string(from: end),
        "countsDown": false,
        "tint": "gray"
    ]
}

/// How much of the exit country's name each surface's line can hold before the
/// host clips it, in characters (`compactCountryLabel` explains the arithmetic).
///
/// The lake has a notification-sized card to lay one line out in; the glance's
/// header row is a fraction of that width, so it gets the shorter form —
/// `Connected · Switzerland` in the lake, `Connected · CH` in the glance. Both
/// are the same state, so the two surfaces still cannot disagree.
private let lakeCountryLimit = 14
private let glanceCountryLimit = 10

/// One line of state: connection state and exit country — `Connected · Romania`.
/// The session timer is not part of it: it is the host's component, in its own
/// slot beside the flag (`lakeTimerSlot`).
private func statusLine(connected: Bool, countryName: String, countryCode: String, countryLimit: Int) -> String {
    if !connected { return "Not connected" }
    var parts = ["Connected"]
    let label = compactCountryLabel(countryName, countryCode: countryCode, limit: countryLimit)
    if !label.isEmpty { parts.append(label) }
    return parts.joined(separator: " · ")
}

/// The inputs a card is built from, kept so `lakeOpened` can be answered from
/// the last card instead of waiting for the next status resolution (which can
/// be mid DNS/geo lookup and take a second).
private struct LakeCardInputs {
    var connected: Bool
    var provider: String?
    var countryCode: String
    var countryName: String
    var sessionStart: Date?
    /// The window the session timer is armed with. It is part of the signature
    /// so a re-arm resends the card, and only then.
    var timerEnd: Date?

    /// The same fields the main loop compares to decide the card changed.
    var signature: String {
        [
            connected ? "1" : "0",
            provider ?? "",
            countryCode,
            countryName,
            sessionStart.map { String($0.timeIntervalSince1970) } ?? "",
            timerEnd.map { String($0.timeIntervalSince1970) } ?? ""
        ].joined(separator: "|")
    }
}

/// Clearance above the card's row, in points.
///
/// The card is a notification — 390 × 80 at the base size DynamicLake
/// documents, growing a little on wider notches and higher-resolution displays
/// — and with `hideHeader` the content starts at the top of it. Centring is
/// arithmetic on the tallest thing in the row, which is the trailing column (the
/// session timer stacked over the flag, about 51 points), against the card:
/// (80 − 51) / 2 ≈ 15, a point under that so the card keeps a little more room
/// below the row than above it.
///
/// It is a fixed spacer, not a bare one and not `padding`: a `spacer` with no
/// `length` collapses to nothing (measured on the built plugin — the row did
/// not move at all), and `padding`'s `top` edge is newer than the builds that
/// reject the field outright, which would leave the user with DynamicLake's
/// fallback card. `length` is documented from 0 to 200, so 0 is legal — it is
/// just no clearance — and the body stack must keep spacing 0, or the stack's
/// own gap is added to this.
private let lakeTopGap: Double = 14

/// The card's artwork, and the gap inside the trailing column.
///
/// Text sizes are the host's (`compact`, `plain` and `large` are all the styles
/// there are, and the name already uses the largest), so what fills the card is
/// artwork — both images are legal anywhere in the documented 12 to 80 range.
private let lakeLogoSize: Double = 34
private let lakeFlagSize: Double = 32
private let lakeTrailingSpacing: Double = 4

/// Whether the connected DynamicLake build rejects `actionID`/`title` on an
/// image. The documented image action is newer than some shipping builds:
/// DynamicLake Playground 1.2 answers `Unknown field 'actionID'` (and then
/// `'title'`) for the logo, and a rejected lake command leaves the host showing
/// its fallback card. So the first rejection downgrades the logo to its
/// `contextMenu` for the rest of the process; the loop then resends the card.
private var lakeImageActionsUnsupported = false

/// Whether the connected build rejects `timer`. The same strict validator that
/// turns down the image action turns down anything it does not know, and a
/// rejected lake command costs the whole card — so the first rejection drops
/// the timer for the rest of the process and the card shows state and country
/// with no clock at all, which beats no card.
private var lakeTimerUnsupported = false

/// The logo, carrying the app-launching action.
///
/// An image that accepts an `actionID` makes the artwork itself the control
/// (its optional `title` is the tooltip) — the one way to get a left-click
/// target with no drawn chrome, since a button cannot be transparent: `plain`
/// draws an opaque disc for the missing symbol (a zero-width title does not
/// suppress it), any symbol it is given is drawn, and behind the artwork it
/// never receives the press. Builds that do not know the field reject it, so
/// after such a rejection the action moves to the right-click menu, which every
/// component can carry and which draws nothing until opened. Without an
/// installed provider app (or for a generic routed tunnel) the logo stays inert.
private func lakeLogoSlot(connected: Bool, provider: String?) -> [String: Any] {
    var logo = connected ? providerIconSlot(provider) : disconnectedIcon()
    logo["size"] = lakeLogoSize
    guard providerAppURL(provider) != nil else { return logo }
    let label = "Open \(providerDisplayName(provider))"
    if lakeImageActionsUnsupported {
        logo["contextMenu"] = [
            [
                "title": label,
                "systemImage": "arrow.up.forward.app",
                "actionID": "open-app"
            ] as [String: Any]
        ]
    } else {
        logo["actionID"] = "open-app"
        logo["title"] = label
    }
    return logo
}

/// The lake card. It is a notification-sized card (declared through `lake.size`
/// in plugin.json; DynamicLake owns its exact geometry, and the current build
/// gives it more vertical room than the launch one did), which holds one row:
/// the built-in header row
/// is hidden (its slots are fixed, so they cannot carry a real layout) and the
/// body is laid out by hand as a single row of facts — the provider logo, the
/// provider name over one line of state (country and session clock included),
/// and the exit-country flag at the trailing edge. There is no button row and no
/// drawn control: the app-launching action rides the logo (an image `actionID`,
/// or the logo's right-click menu on a host that rejects that field).
/// The clock is still NetworkExtension-only, so it is never an estimate.
private func lakePayload(connected: Bool, provider: String?, countryCode: String, countryName: String, sessionStart: Date?, timerEnd: Date?) -> [String: Any] {
    let providerName = provider == nil ? pluginName : providerDisplayName(provider)
    let lakeLine = statusLine(
        connected: connected,
        countryName: countryName,
        countryCode: countryCode,
        countryLimit: lakeCountryLimit
    )
    let glanceLine = statusLine(
        connected: connected,
        countryName: countryName,
        countryCode: countryCode,
        countryLimit: glanceCountryLimit
    )

    var topRow: [[String: Any]] = [
        lakeLogoSlot(connected: connected, provider: provider),
        [
            "type": "vstack",
            "spacing": 1,
            "alignment": "leading",
            "children": [
                // The freed-up header space goes into the name, which is the line
                // the card is actually read for.
                ["type": "text", "text": providerName, "style": "large", "weight": "semibold"] as [String: Any],
                // The state line is secondary text: DynamicLake has no dedicated
                // secondary style, so plain + gray is it. Nothing patches it any
                // more — the clock is the host's timer, in its own slot.
                ["type": "text", "text": lakeLine, "style": "plain", "tint": "gray"] as [String: Any]
            ]
        ],
        ["type": "spacer"]
    ]

    // The trailing slot stacks the session timer over the exit-country flag: it
    // gives the timer a line of its own, where no text can squeeze it, and it
    // uses the card's height instead of leaving a band of air below the row.
    // Either half can be missing — no flag while disconnected, and no timer
    // without an exact session start (a routed tunnel has none) — so the
    // column only exists when it has something in it.
    var trailing: [[String: Any]] = []
    if connected, !lakeTimerUnsupported, let start = sessionStart, let end = timerEnd {
        trailing.append(lakeTimerSlot(start: start, end: end))
    }
    if connected, let flag = sizedFlagSlot(countryCode, size: lakeFlagSize) {
        trailing.append(flag)
    }
    if !trailing.isEmpty {
        topRow.append([
            "type": "vstack",
            "spacing": lakeTrailingSpacing,
            "alignment": "trailing",
            "children": trailing
        ] as [String: Any])
    }

    // The row drops into the card instead of sitting on its top edge. Both
    // states get the same clearance, so the connected and disconnected cards
    // stay identical.
    var body: [[String: Any]] = []
    if lakeTopGap > 0 {
        body.append(["type": "spacer", "length": lakeTopGap] as [String: Any])
    }
    body.append(["type": "hstack", "id": "lake-top", "spacing": 10, "children": topRow] as [String: Any])

    return [
        "schemaVersion": schemaVersion,
        "requestID": "lake",
        "type": "lake",
        "lake": [
            "hideHeader": true,
            "content": [
                [
                    "type": "vstack",
                    "id": "lake-body",
                    // Zero so the clearance spacer above the row is the exact
                    // gap it says it is; a stack spacing would be added to it.
                    "spacing": 0,
                    "children": body
                ] as [String: Any]
            ],
            "glance": glanceSurface(
                connected: connected,
                provider: provider,
                providerName: providerName,
                line: glanceLine,
                countryCode: countryCode
            )
        ]
    ] as [String: Any]
}

/// DynaGlance's right side is much smaller than a lake, but DynamicLake lays it
/// out as the same header row a notification lake is built from — artwork,
/// title, gray subtitle, trailing slot — and it is DynamicLake that sizes and
/// insets that row for the area the glance actually has. So the glance is
/// described with those fields rather than a hand-built row: hiding the header
/// and stacking a 24-point logo, `compact` text and a 20-point flag in a
/// content stack rendered a fraction of the space it was given.
///
/// Artwork is inline here even when the `asset` command is available: a header
/// slot is the one place an asset reference has been seen to render nothing
/// (the same reason the lake's flag is inline). No `size` is set on either slot
/// — the host's own row decides how large its artwork is, which is the point of
/// using it.
///
/// The line is the lake's own state line — `Connected · Romania` — so the two
/// surfaces can never disagree about what the connection is. It carried the
/// session clock for a while and was clamped there (`Connected · Romania ·
/// 5:07` does not fit that width, and a clipped timer reads as broken); the
/// clock is the host's `timer` component on the lake now, and the glance does
/// not try to show it at all.
///
/// What the glance cannot carry either is a long country name, so its copy of
/// the line is built with the glance's own budget: `Connected · CH` where the
/// lake reads `Connected · Switzerland`. The state words are the same on both.
private func glanceSurface(connected: Bool, provider: String?, providerName: String, line: String, countryCode: String) -> [String: Any] {
    var glance: [String: Any] = [
        "leftSlot": connected ? vpnIconPayload(for: provider) : disconnectedIcon(),
        // Title is bold and subtitle is gray by default, so neither needs saying.
        "title": ["type": "text", "text": providerName] as [String: Any],
        "subtitle": ["type": "text", "text": line] as [String: Any]
    ]
    if connected, let flag = flagSlot(countryCode) {
        glance["rightSlot"] = flag
    }
    return glance
}

// MARK: - Settings

/// The two switches DynamicLake exposes, read as a pair.
private struct PluginSettings {
    let notifyOnChange: Bool
    let persistOnDisconnect: Bool
}

/// The last parsed settings file, keyed by the file's identity so a rewrite is
/// picked up immediately and an unchanged file is never parsed again.
private struct SettingsCache {
    let path: String
    let modified: Date?
    let size: UInt64
    let values: [String: Any]
}

private var settingsCache: SettingsCache?
private var settingsParseFailureLogged = false

/// Both switches from one stat and at most one parse.
///
/// The file is the source of truth: DynamicLake rewrites it when the user
/// toggles a switch, while an environment variable is only a snapshot from
/// process launch and never updates for a running plugin.
private func readSettings() -> PluginSettings {
    let environment = ProcessInfo.processInfo.environment
    var values: [String: Any] = [:]
    if let path = environment[settingsPathEnvironmentKey] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if attributes != nil,
           let cached = settingsCache,
           cached.path == path,
           cached.modified == modified,
           cached.size == size {
            values = cached.values
        } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parsed = object["values"] as? [String: Any] {
            settingsCache = SettingsCache(path: path, modified: modified, size: size, values: parsed)
            values = parsed
        } else if attributes != nil, !settingsParseFailureLogged {
            settingsParseFailureLogged = true
            logEvent("settings parse failed at \(path); falling back to env/defaults")
        }
    }
    func flag(_ id: String, envKey: String) -> Bool {
        if let value = values[id] as? Bool { return value }
        return environment[envKey] == "true" || environment[envKey] == "1"
    }
    return PluginSettings(
        notifyOnChange: flag("notifyOnChange", envKey: "DYNAMICLAKE_SETTING_NOTIFY_ON_CHANGE"),
        persistOnDisconnect: flag("persistOnDisconnect", envKey: "DYNAMICLAKE_SETTING_PERSIST_ON_DISCONNECT")
    )
}

// MARK: - Sending

/// How long the plugin keeps trying when every write fails. A closed socket
/// usually means DynamicLake is done with this process (app quit, plugin
/// restart, reinstall); without a bound the process loops forever.
private let socketGiveUpAfterSec: TimeInterval = 60
/// The host closing its end is a different case from a wedged send: it means
/// the session is over, so the plugin leaves promptly rather than spending a
/// minute retrying a socket nobody is listening on.
private let hostGoneExitAfterSec: TimeInterval = 10
private var lastSuccessfulSendAt = Date()
private var consecutiveSendFailures = 0

@discardableResult
private func sendTracked(_ client: JSONSocketClient, _ payload: [String: Any], _ label: String) -> Bool {
    // Reconnecting owns a closed socket. Sending into one would just log a
    // failure per pass, and a reconnect in progress is already scheduled.
    guard client.descriptor >= 0 else { return false }
    do {
        try client.send(payload)
        lastSuccessfulSendAt = Date()
        consecutiveSendFailures = 0
        return true
    } catch {
        consecutiveSendFailures += 1
        logEvent("send failed \(label): \(error)")
        let silentFor = Date().timeIntervalSince(lastSuccessfulSendAt)
        if silentFor > socketGiveUpAfterSec, consecutiveSendFailures > 10 {
            logEvent("socket unusable for \(Int(silentFor))s; exiting so DynamicLake can relaunch the plugin")
            exit(0)
        }
        return false
    }
}

// MARK: - Shutdown

private var shutdownRequested = false

/// Kept so the signal handler can wake the main queue: with no poll loop, a
/// signal would otherwise wait for the next event to be noticed.
private var eventDoorbell: EventSignal?

private func handleSignal(_ sig: Int32) {
    shutdownRequested = true
    eventDoorbell?.signal()
}

// MARK: - Plugin

/// The plugin is a main-queue state machine. Every status frame, socket
/// message, notification and deadline arrives as an event, and each one runs
/// `reconcile()` to send whatever changed. Nothing polls, and nothing spawns.
///
/// The main queue is not a style choice here: NetworkExtension answers on it,
/// so a loop that blocked the main thread would never see a tunnel at all
/// (measured — a semaphore wait on the main thread times out even though the
/// framework is healthy). Everything the plugin owns lives on this queue, which
/// is why none of it needs a lock.
private final class VPNStatusPlugin {
    private let client: JSONSocketClient
    private let signal: EventSignal
    private let countryResolver = ExitCountryResolver()
    private let protonResolver = ProtonExitResolver(logger: logEvent)

    private var socketSource: DispatchSourceRead?
    private var signalSource: DispatchSourceRead?
    private var deadlineWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    /// When the host closed its end. A plugin whose host has gone away exits
    /// after a short grace period instead of retrying for a minute: a new
    /// DynamicLake session starts a new plugin.
    private var closedAt: Date?
    private var reconciling = false
    private var reconcileQueued = false

    /// Presentation state, in the order it is decided.
    private var published = false
    private var lastRawConnectionKey = ""
    private var stateConnected = false
    /// Which provider was last actually connected. The disconnected card names
    /// it, because the alternative is naming a *configured* tunnel that had
    /// nothing to do with the session that just ended.
    private var lastConnectedProvider: String?
    private var lastBaseSig = ""
    private var lastFullSig = ""
    private var pendingPeekAt: Date?
    /// A peek that arrived before its exit country is known. It is released by
    /// the country, not by a re-check: the flag is the only thing the
    /// presentation is waiting for.
    private var peekHeld = false
    private var activityDemoted = true
    private var demoteAt: Date?
    private var prevConnected: Bool?
    private var lastMode: Bool?
    private var dismissAt: Date?
    /// When a fresh connection's second sighting is due.
    private var confirmAt: Date?
    private var currentCountryCode = ""
    private var currentCountryName = ""
    /// Last stabilized Proton exit IP. A Proton server switch does not
    /// necessarily change the service name or utun interface, so the exit IP is
    /// part of the effective Proton connection identity. NordVPN never reads or
    /// writes this.
    private var protonStableExitIP = ""
    private var countryGeneration: UInt64 = 0
    private var countryConnectionKey = ""
    private var nextCountryProbeAt: Date?
    private var countryProbeAttempts = 0
    /// Lake bookkeeping: the signature of the state the card currently shows,
    /// plus a flag set when DynamicLake reports the lake opening so visible
    /// content is always refreshed even if nothing else changed.
    private var lastLakeSig = ""
    private var lakeRefreshRequested = false
    /// Last card sent, so a lakeOpened can be answered without a status read.
    private var lastLakeInputs: LakeCardInputs?
    /// Provider the visible card was built for, so a press on the logo opens the
    /// app it belongs to even if the tunnel state changed in between.
    private var lakeProvider: String?
    /// Set from the sleep/wake notifications, which arrive on arbitrary
    /// threads; read and cleared on the main queue.
    private let wakeLock = NSLock()
    private var wokeAt: Date?

    init(client: JSONSocketClient, signal: EventSignal) {
        self.client = client
        self.signal = signal
    }

    // MARK: Lifecycle

    func start() {
        eventDoorbell = signal

        // Every status source is a doorbell: they fire on their own queues and
        // only ever ask the main queue to render again.
        countryResolver.onResult = { [weak self] in self?.signal.signal() }
        protonResolver.onResult = { [weak self] in self?.signal.signal() }
        NEVPNWatcher.onStatusChange = { [weak self] in self?.signal.signal() }
        NEVPNWatcher.onProxyConfigsChanged = { signature in
            logEvent("transparent proxy configs=" + (signature.isEmpty ? "none" : "[\(signature)]"))
        }
        PathWatcher.onPathChange = { [weak self] in self?.signal.signal() }
        PathWatcher.start()

        let wakeCenter = NSWorkspace.shared.notificationCenter
        wakeCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.wakeLock.lock()
            self.wokeAt = nil
            self.wakeLock.unlock()
            self.signal.signal()
        }
        wakeCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.wakeLock.lock()
            self.wokeAt = Date()
            self.wakeLock.unlock()
            // A tunnel that died during sleep would otherwise keep its cached
            // configuration until something else changed.
            NEVPNWatcher.refresh(force: true)
            self.signal.signal()
        }

        // The tunnels are enumerated asynchronously; the first card is built
        // from the routing table and this wakes the plugin when they are known.
        NEVPNWatcher.load { [weak self] ok in
            logEvent(ok ? "network extension status source active" : "network extension load failed; using the routing table")
            self?.signal.signal()
        }

        installSocketSource()
        installSignalSource()

        sendTracked(client, dismissPayload(), "startup dismiss")
        logEvent("startup features=\(pluginFeatures.isEmpty ? "none" : pluginFeatures.sorted().joined(separator: ",")) presentSneakPeek=\(supportsPresentSneakPeek)")
        requestReconcile()
    }

    private func installSocketSource() {
        socketSource?.cancel()
        socketSource = nil
        guard client.descriptor >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: client.descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.requestReconcile()
            if self.client.isClosed {
                if self.closedAt == nil { self.closedAt = Date() }
                self.reconnect()
            }
        }
        source.resume()
        socketSource = source
    }

    private func installSignalSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: signal.descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.signal.drain()
            self.requestReconcile()
        }
        source.resume()
        signalSource = source
    }

    // MARK: Event entry points

    /// Runs one pass of the state machine, and repeats if an event arrived
    /// while it was running. Bounded: a source that keeps firing during a pass
    /// gets a limited number of tries, then waits for the next event.
    func requestReconcile() {
        guard !reconciling else {
            reconcileQueued = true
            return
        }
        reconciling = true
        var rounds = 0
        repeat {
            reconcileQueued = false
            reconcile()
            rounds += 1
        } while reconcileQueued && rounds < 8 && !shutdownRequested
        reconciling = false
    }

    private func reconnect() {
        guard !shutdownRequested else { return }
        // A retry already queued must not fire after this one succeeds: it would
        // tear down the socket that just came back.
        reconnectWork?.cancel()
        reconnectWork = nil
        socketSource?.cancel()
        socketSource = nil
        client.close()
        do {
            try client.connect()
            closedAt = nil
            logEvent("reconnected socket")
            installSocketSource()
        } catch {
            logEvent("reconnect failed: \(error)")
            if closedAt == nil { closedAt = Date() }
            scheduleReconnect()
        }
        // Assets live and die with the socket session, so nothing may reference
        // them until they are re-registered, and the activity that session
        // carried may be gone with it — so the plugin no longer claims a card is
        // on screen. The next pass re-registers and re-presents from scratch.
        registeredLogoProvider = ""
        lastLakeSig = ""
        published = false
        lastBaseSig = ""
        lastFullSig = ""
        lakeRefreshRequested = true
    }

    /// One retry a second while the host may still be there; a host that has
    /// gone away for good lets the give-up check in `sendTracked` end the
    /// process. This only runs after a failure, never in steady state.
    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !shutdownRequested else { return }
            if let closedAt = self.closedAt, Date().timeIntervalSince(closedAt) > hostGoneExitAfterSec {
                logEvent("DynamicLake closed the socket; exiting so it can relaunch the plugin")
                exit(0)
            }
            if Date().timeIntervalSince(lastSuccessfulSendAt) > socketGiveUpAfterSec {
                logEvent("socket unavailable for \(Int(socketGiveUpAfterSec))s; exiting so DynamicLake can relaunch the plugin")
                exit(0)
            }
            self.reconnect()
            if self.client.descriptor < 0 { self.scheduleReconnect() }
        }
        reconnectWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    /// Sleeps until the next thing is due. Nothing is armed in the idle case,
    /// which is the point: with no deadlines the plugin wakes only for a frame
    /// or a status event.
    private func armNextDeadline(connected: Bool) {
        deadlineWork?.cancel()
        deadlineWork = nil
        var dates: [Date] = []
        if let pendingPeekAt { dates.append(pendingPeekAt) }
        if let demoteAt { dates.append(demoteAt) }
        if let dismissAt { dates.append(dismissAt) }
        if let nextCountryProbeAt { dates.append(nextCountryProbeAt) }
        if let confirmAt { dates.append(confirmAt) }
        // DynamicLake's timer stops counting at its armed end, so the card is
        // re-sent before that to start a fresh window. Once per window roll.
        // Nothing to re-arm when the host rejected the timer: that card carries
        // no clock, so a window roll would only resend identical content.
        if connected, published, !lakeTimerUnsupported, lastLakeInputs?.sessionStart != nil, let armed = armedSessionTimer {
            dates.append(armed.end.addingTimeInterval(-sessionTimerRearmMargin))
        }
        guard let next = dates.min() else { return }
        let item = DispatchWorkItem { [weak self] in self?.requestReconcile() }
        deadlineWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.005, next.timeIntervalSinceNow), execute: item)
    }

    // MARK: Frames

    /// Drains DynamicLake's frames. Called at the start of every pass, so a
    /// lakeOpened is answered on the opening frame itself.
    private func pumpEvents() {
        for response in client.receiveAvailable() {
            let type = response["type"] as? String ?? ""
            let isRejectedResponse = type == "response" && response["ok"] as? Bool == false
            switch type {
            case "lakeOpened":
                // Only while the lake is visible: refresh its content (and the
                // artwork it may need) on the opening frame itself.
                let trigger = response["trigger"] as? String ?? "unknown"
                let size = response["size"] as? String ?? "unknown"
                logEvent("lake opened trigger=\(trigger) size=\(size)")
                lakeRefreshRequested = true
                // Repaint from the last card we built: the pass may be mid
                // status resolution (DNS/geo lookups) and the card the user just
                // opened must not wait for that.
                if let inputs = lastLakeInputs {
                    sendLake(inputs, "lake open")
                }
            case "lakeClosed":
                logEvent("lake closed")
            case "action":
                let surface = response["surface"] as? String ?? ""
                let actionID = response["actionID"] as? String ?? ""
                logEvent("action=\(actionID) surface=\(surface)")
                if actionID == "open-app" {
                    openProviderApp(provider: lakeProvider)
                }
            case "error":
                if let message = response["error"] as? String {
                    logEvent("dynamiclake error: \(message)")
                    noteLakeRejection(message)
                    noteTimerRejection(message)
                }
            default:
                // A rejected `response` is where a strict host reports an
                // unknown field, and it used to be handled for the image action
                // only — the timer's fallback never ran on this path.
                if isRejectedResponse, let message = response["error"] as? String {
                    logEvent("dynamiclake error: \(message)")
                    noteLakeRejection(message)
                    noteTimerRejection(message)
                }
            }
        }
    }

    /// Sends the lake card for `inputs` and updates the bookkeeping that keeps
    /// an unchanged card from being resent. The host ticks the session timer
    /// itself, so there is no clock text to seed here.
    @discardableResult
    private func sendLake(_ inputs: LakeCardInputs, _ reason: String) -> Bool {
        guard sendTracked(
            client,
            lakePayload(
                connected: inputs.connected,
                provider: inputs.provider,
                countryCode: inputs.countryCode,
                countryName: inputs.countryName,
                sessionStart: inputs.sessionStart,
                timerEnd: inputs.timerEnd
            ),
            reason
        ) else { return false }
        lastLakeSig = inputs.signature
        lastLakeInputs = inputs
        lakeRefreshRequested = false
        lakeProvider = inputs.provider
        return true
    }

    /// The image action is rejected by builds that predate it, and a rejected
    /// lake command leaves the host showing its fallback card. The first such
    /// rejection downgrades the logo to its menu and repaints at once. The
    /// one-way flag stops a build that rejects both shapes from retrying
    /// forever, and the `$.lake` check keeps an unrelated `title` rejection (a
    /// notification, say) from flipping it.
    private func noteLakeRejection(_ message: String) {
        guard !lakeImageActionsUnsupported,
              message.contains("Unknown field"),
              message.contains("'actionID'") || (message.contains("'title'") && message.contains("$.lake"))
        else { return }
        lakeImageActionsUnsupported = true
        logEvent("host rejects image actionID; using the logo menu")
        lakeRefreshRequested = true
        if let inputs = lastLakeInputs {
            sendLake(inputs, "lake action fallback")
        }
    }

    /// The same strict validator rejects a component it does not know, and a
    /// rejected lake command costs the whole card — so the first rejection drops
    /// the timer for the rest of the process and the card shows state and
    /// country with no clock, which beats no card.
    private func noteTimerRejection(_ message: String) {
        guard !lakeTimerUnsupported,
              message.contains("Unknown"),
              ["timer", "startDate", "endDate", "countsDown"].contains(where: { message.contains($0) })
        else { return }
        lakeTimerUnsupported = true
        logEvent("host rejects the timer component; card sent without it")
        lakeRefreshRequested = true
        if let inputs = lastLakeInputs {
            sendLake(inputs, "lake timer fallback")
        }
    }

    // MARK: State

    private func connectionKey(for vpn: VPNStatus) -> String {
        if let service = vpn.serviceName {
            return "service|\(service)|\(vpn.serverAddress ?? "")|\(vpn.sessionID ?? "")"
        }
        return "route|\(vpn.provider ?? "")|\(vpn.routedInterface ?? "")"
    }

    /// Arms the drop back to the resting profile, once, for a card that was
    /// created at notification priority and whose peek has been presented, held
    /// back or dropped. Without it a peek that never presents — no exit country
    /// for the session — would leave the card announced as a notification for as
    /// long as the connection lasts.
    private func armDemoteIfOwed(_ now: Date) {
        guard !activityDemoted, demoteAt == nil else { return }
        demoteAt = now.addingTimeInterval(sneakPeekPresentationSec + 0.25)
    }

    private func releaseHeldPeek(_ now: Date) {
        guard peekHeld else { return }
        peekHeld = false
        // The flag refresh goes first (this pass), then the peek presents on
        // the refreshed, unchanged surfaces.
        pendingPeekAt = now.addingTimeInterval(peekCountryLeadSec)
    }

    private func reconcile() {
        if shutdownRequested {
            if published { try? client.send(dismissPayload()) }
            exit(0)
        }
        pumpEvents()
        // Nothing can be presented while the host's end is gone; the reconnect
        // chain owns that, and it re-renders when it succeeds.
        guard client.descriptor >= 0 else { return }

        let settings = readSettings()

        if published, lastMode != settings.notifyOnChange {
            sendTracked(client, dismissPayload(), "dismiss mode-switch")
            published = false
            dismissAt = nil
            pendingPeekAt = nil
            peekHeld = false
            demoteAt = nil
            activityDemoted = true
            // Reset the surfaces signatures too, or the fresh mode's first
            // capsule/notification could be skipped as "unchanged".
            lastBaseSig = ""
            lastFullSig = ""
        }
        if lastMode != settings.notifyOnChange {
            logEvent("mode=" + (settings.notifyOnChange ? "notify" : "persistent"))
            lastMode = settings.notifyOnChange
        }

        let now = Date()
        // Right after a wake (the grace window covers signals that arrive while
        // system state settles) nothing cached about the session is trusted: a
        // lookup in flight when the machine slept belongs to the past, and the
        // exit itself may have moved. The country is dropped and asked for again
        // once the connection is known.
        let resumedFromSleep: Bool
        if let woke = wakeLock.withLock({ wokeAt }), now.timeIntervalSince(woke) < 10 {
            wakeLock.withLock { wokeAt = nil }
            resumedFromSleep = true
            logEvent("resumed from sleep; re-verifying status and exit country")
        } else {
            resumedFromSleep = false
        }

        let vpn = resolveStatus()

        // macOS keeps the previous session marked connected for a beat while a
        // new VPN finishes its handshake, and during the overlap either service
        // can be reported. Hold a fresh connection until it is seen twice, so
        // the provider on its way out never reaches the notch. Disconnects stay
        // instant. The second sighting is one deadline, not a faster cadence.
        let rawConnectionKey = vpn.connected ? connectionKey(for: vpn) : ""
        var state = vpn
        if vpn.connected, !stateConnected, rawConnectionKey != lastRawConnectionKey {
            state.connected = false
            confirmAt = now.addingTimeInterval(connectionConfirmDelaySec)
        } else {
            confirmAt = nil
        }
        stateConnected = state.connected
        lastRawConnectionKey = rawConnectionKey

        // A configured tunnel being present is enough for a snapshot to answer
        // "disconnected" in that provider's name, so a session that ended was
        // reported as "NordVPN disconnected" even when the VPN that had been up
        // was somebody else's. The card keeps the provider that was connected; a
        // live connection always wins, so this never renames a real one.
        if vpn.connected {
            if let provider = vpn.provider { lastConnectedProvider = provider }
        } else if let last = lastConnectedProvider {
            state.provider = last
        }

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
                countryProbeAttempts = 0
                nextCountryProbeAt = now.addingTimeInterval(countryLookupSettleSec)
                connectionChanged = true
                countryChanged = true

                // The selected location (including virtual ones) comes from
                // NordVPN's own data, not from where the hardware sits:
                // NordWhisper exposes only the station IP as ServerAddress (no
                // hostname), so legacy configs resolve via the *.nordvpn.com
                // hostname label and station IPs resolve via the virtual-location
                // table. On a virtual server like Armenia the geo lookup can only
                // ever report the physical country (BG), so a confirmed Nord
                // location always overrides it.
                var nordLocation: (code: String, source: String)?
                if let code = nordServerCountryCode(from: state.serverAddress) {
                    nordLocation = (code, "server host")
                } else if state.provider?.lowercased().contains("nord") == true,
                          let code = nordVirtualLocationCountryCode(forIPv4: state.serverAddress) {
                    nordLocation = (code, "virtual location table")
                } else if state.provider?.lowercased().contains("nord") == true,
                          let addr = state.serverAddress, !addr.isEmpty {
                    // Never log IPs: address literals are reduced to their shape
                    // so an unexpected NordWhisper format shows up in the log
                    // without exposing the address.
                    logEvent("nord server address unresolved (\(serverAddressShape(addr))); using geo lookup")
                }
                if let location = nordLocation {
                    currentCountryCode = location.code
                    currentCountryName = Locale.current.localizedString(forRegionCode: location.code) ?? location.code
                    // Skip the geo lookup for this connection: it would
                    // contradict the selected location on virtual servers.
                    nextCountryProbeAt = nil
                    logEvent("country=\(location.code) (from \(location.source))")
                    releaseHeldPeek(now)
                }
            }
        } else if !countryConnectionKey.isEmpty || !currentCountryCode.isEmpty || !protonStableExitIP.isEmpty {
            countryGeneration &+= 1
            countryConnectionKey = ""
            currentCountryCode = ""
            currentCountryName = ""
            protonStableExitIP = ""
            countryProbeAttempts = 0
            nextCountryProbeAt = nil
            countryChanged = true
        }

        // The exit is resolved again after a sleep: the lookup that was in flight
        // belongs to the past, and the country may have changed while suspended.
        // The answer already on screen stays there until a different one arrives,
        // so the flag does not blink for a second after every wake.
        if resumedFromSleep, state.connected {
            countryGeneration &+= 1
            countryProbeAttempts = 0
            nextCountryProbeAt = now.addingTimeInterval(countryLookupSettleSec)
        }

        // Provider-specific exit lookup. ProtonVPN uses the stabilized two-probe
        // exit-IP resolver; every other provider uses the single-shot country
        // resolver. The inactive path is drained so a provider switch cannot leak
        // the other path's pending result.
        let protonActive = state.connected && usesProtonStabilizedExit(provider: state.provider)
        if protonActive {
            _ = countryResolver.takeResult()
            if let result = protonResolver.takeResult() {
                if result.generation != countryGeneration {
                    logEvent("stale exit lookup discarded generation=\(result.generation)")
                } else if result.countryCode.isEmpty {
                    countryProbeAttempts += 1
                    nextCountryProbeAt = countryProbeAttempts < countryProbeMaxAttempts
                        ? now.addingTimeInterval(countryLookupRetrySec) : nil
                } else {
                    if !protonStableExitIP.isEmpty, protonStableExitIP != result.ip {
                        // Never log the IP itself, only that the exit moved.
                        logEvent("proton exit changed country=\(result.countryCode)")
                    }
                    protonStableExitIP = result.ip
                    countryProbeAttempts = 0
                    if result.countryCode != currentCountryCode {
                        currentCountryCode = result.countryCode
                        currentCountryName = result.countryName
                        countryChanged = true
                        logEvent("country=\(result.countryCode)")
                        releaseHeldPeek(now)
                    }
                    // No periodic re-probe: a Proton server switch restarts the
                    // tunnel, so its status event (and the new session start)
                    // is the trigger, and a bounded retry covers a failed probe.
                    nextCountryProbeAt = nil
                }
            }
        } else {
            _ = protonResolver.takeResult()
            if let result = countryResolver.takeResult() {
                if result.generation != countryGeneration {
                    logEvent("stale exit lookup discarded generation=\(result.generation)")
                } else if result.code.isEmpty {
                    countryProbeAttempts += 1
                    nextCountryProbeAt = countryProbeAttempts < countryProbeMaxAttempts
                        ? now.addingTimeInterval(countryLookupRetrySec) : nil
                } else {
                    countryProbeAttempts = 0
                    if result.code != currentCountryCode {
                        currentCountryCode = result.code
                        currentCountryName = result.name
                        countryChanged = true
                        logEvent("country=\(result.code)")
                        releaseHeldPeek(now)
                    }
                    nextCountryProbeAt = nil
                }
            }
        }

        // A geo-derived country can be wrong for a virtual location: the geo
        // lookup reports the physical host country (e.g. BG for Armenia). When
        // the picked location is recoverable from the station address, override
        // the geo value unconditionally. Bumping the generation also discards the
        // geo lookup still in flight for this connection so it cannot clobber the
        // correction on arrival.
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
            releaseHeldPeek(now)
        }

        if state.connected, let probeAt = nextCountryProbeAt, now >= probeAt {
            // A routed status was read from the routing table, so the tunnel is
            // already proven to be carrying traffic; it must not be asked to
            // disprove itself. A transparent proxy is the exception: it installs
            // no route at all, so the table can never speak for it and its own
            // connection is the only evidence there is.
            if !state.isProxy, state.routedInterface == nil, PathWatcher.tunnelInterface() == nil {
                countryProbeAttempts += 1
                nextCountryProbeAt = countryProbeAttempts < countryProbeMaxAttempts
                    ? now.addingTimeInterval(countryLookupRetrySec) : nil
            } else {
                // A request refused because a lookup is still in flight belongs
                // to the previous connection, so its result is discarded as
                // stale. The deadline is re-armed rather than consumed: dropping
                // it would leave this session with no country (and no flag) until
                // the next connection change.
                let started = protonActive
                    ? protonResolver.request(generation: countryGeneration)
                    : countryResolver.request(generation: countryGeneration)
                if started {
                    nextCountryProbeAt = nil
                } else {
                    countryProbeAttempts += 1
                    nextCountryProbeAt = countryProbeAttempts < countryProbeMaxAttempts
                        ? now.addingTimeInterval(countryLookupRetrySec) : nil
                }
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

        // Register the artwork this frame's surfaces reference (no-op when the
        // imageAssets feature is absent or nothing changed).
        ensureAssets(client, provider: state.provider)

        if supportsLake {
            // The session timer's window, armed once per window rather than per
            // pass: it only enters the card's signature when the window is
            // re-armed, so the card is not resent (and the timer does not jump)
            // for the rest of the window.
            let timerEnd = state.connected
                ? state.sessionStart.map { sessionTimerEnd(start: $0, now: now) }
                : nil
            let inputs = LakeCardInputs(
                connected: state.connected,
                provider: state.provider,
                countryCode: currentCountryCode,
                countryName: currentCountryName,
                sessionStart: state.sessionStart,
                timerEnd: timerEnd
            )
            if lakeRefreshRequested || inputs.signature != lastLakeSig {
                if !sendLake(inputs, "lake") { reconnect() }
            }
        }

        // Present a scheduled peek via a delayed update on unchanged surfaces
        // (the only shape DynamicLake reliably honours).
        if let peekAt = pendingPeekAt, now >= peekAt {
            pendingPeekAt = nil
            if shouldHoldPeekForCountry(connected: state.connected, countryCode: currentCountryCode) {
                // Nothing correct to present yet. The country's arrival releases
                // this (releaseHeldPeek); there is no re-check to arm. The demote
                // is still owed, though: the card was created at notification
                // priority for a peek that may now never present.
                peekHeld = true
                armDemoteIfOwed(now)
            } else if published {
                // The capsule/notification from the create is established by
                // now, so the peek update is honoured.
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
                    // Two-phase presentation: if the activity was created at
                    // notification priority for this connect, schedule the drop
                    // back to the persistent profile for when the peek's
                    // presentation window has fully closed.
                    armDemoteIfOwed(now)
                    // Sync the signatures so nothing re-sends these surfaces
                    // while the peek is on screen.
                    lastBaseSig = baseSig
                    lastFullSig = sig
                    if let deadline = dismissAt {
                        dismissAt = max(deadline, now.addingTimeInterval(sneakPeekPresentationSec + 0.25))
                    }
                }
            }
        }

        // Two-phase presentation, phase 2: after the peek's window has played
        // out, drop the activity back to the persistent profile. Runs before the
        // mode branches so notify-mode dismissal cannot outrun it.
        if let demoteDeadline = demoteAt, now >= demoteDeadline {
            // Consumed even when nothing is published: leaving it set would
            // re-arm the deadline in the past on every pass.
            demoteAt = nil
            if published {
                if sendTracked(
                    client,
                    demotePayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName),
                    "demote"
                ) {
                    activityDemoted = true
                } else {
                    published = false
                    lastBaseSig = ""
                    lastFullSig = ""
                    reconnect()
                }
            }
        }

        if settings.notifyOnChange {
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
                        // The notification dismisses itself; no demote owed.
                        activityDemoted = true
                        dismissAt = now.addingTimeInterval(notificationDurationSec)
                        // The shared peek block presents it once the notification
                        // capsule is established (DynamicLake ignores peeks on
                        // creates).
                        pendingPeekAt = now.addingTimeInterval(peekDelaySec)
                    } else {
                        reconnect()
                    }
                }
            }
            prevConnected = state.connected

            if published, state.connected, countryChanged, !currentCountryCode.isEmpty {
                // The notification is still on screen: refresh it in place (add
                // the flag) instead of re-presenting the sneak peek.
                sendTracked(
                    client,
                    peekUpdatePayload(connected: true, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName, presentPeek: false),
                    "country update"
                )
            }

            if let deadline = dismissAt, now >= deadline {
                // Consumed whether or not the notification is still up.
                dismissAt = nil
                if published {
                    if demoteAt != nil || !activityDemoted {
                        // The priority announcement is still owed: demote first,
                        // then dismiss on the next pass rather than tearing the
                        // activity down mid-transition.
                        if sendTracked(
                            client,
                            demotePayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName),
                            "demote before dismiss"
                        ) {
                            activityDemoted = true
                            demoteAt = nil
                            dismissAt = now.addingTimeInterval(0.3)
                        } else {
                            published = false
                            lastBaseSig = ""
                            lastFullSig = ""
                            reconnect()
                        }
                    } else if sendTracked(client, dismissPayload(), "notify dismiss") {
                        published = false
                        logEvent("dismiss (notification expired)")
                    } else {
                        published = false
                        lastBaseSig = ""
                        lastFullSig = ""
                        reconnect()
                    }
                }
            }
        } else {
            prevConnected = nil

            if !state.connected, !settings.persistOnDisconnect {
                if published, dismissAt == nil {
                    // Two-phase presentation for disconnects too: promote the
                    // capsule to notification priority so the peek presents like
                    // a banner, then demote before it dismisses.
                    var payload = peekUpdatePayload(connected: false, provider: nil, countryCode: "", countryName: "")
                    if activityDemoted {
                        payload["priority"] = "high"
                        payload["requestID"] = "promote-\(updateSequence)"
                        activityDemoted = false
                    }
                    if !sendTracked(client, payload, "disconnect peek") {
                        published = false
                        lastBaseSig = ""
                        lastFullSig = ""
                        reconnect()
                    } else {
                        demoteAt = now.addingTimeInterval(sneakPeekPresentationSec + 0.25)
                        dismissAt = now.addingTimeInterval(notificationDurationSec)
                        lastBaseSig = baseSig
                        lastFullSig = sig
                        logEvent("peek connected=false")
                    }
                }
                if let deadline = dismissAt, now >= deadline {
                    dismissAt = nil
                    if published, !sendTracked(client, dismissPayload(), "dismiss disconnected") {
                        logEvent("dismiss failed; dropping published state")
                    }
                    published = false
                }
            } else {
                dismissAt = nil
                if baseSig != lastBaseSig {
                    pendingPeekAt = nil
                    peekHeld = false
                    if published {
                        // Surface change only — the peek is scheduled separately,
                        // since presentSneakPeek on a surface-changing update is
                        // ignored by DynamicLake.
                        var payload = peekUpdatePayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName, presentPeek: false)
                        // A server/location switch while connected announces like
                        // a connect: promote to notification priority, refresh the
                        // surfaces, then present the peek as a pure presentation
                        // update and demote once its window closes.
                        if state.connected {
                            payload["priority"] = "high"
                            payload["requestID"] = "promote-\(updateSequence)"
                            activityDemoted = false
                        }
                        if sendTracked(client, payload, "surface update") {
                            pendingPeekAt = now.addingTimeInterval(peekAfterSurfaceUpdateSec)
                            lastBaseSig = baseSig
                            lastFullSig = sig
                        } else {
                            // Nothing was presented, so nothing may be remembered
                            // as presented: the signatures suppress the retry.
                            published = false
                            lastBaseSig = ""
                            lastFullSig = ""
                            reconnect()
                        }
                    } else if sendTracked(client, connectCreatePayload(connected: state.connected, provider: state.provider, countryCode: currentCountryCode, countryName: currentCountryName), "create") {
                        published = true
                        // Connect and disconnect announcements both present at
                        // notification priority and demote after their peek.
                        activityDemoted = false
                        // Present the peek shortly after the capsule appears:
                        // DynamicLake ignores presentSneakPeek on creates and on
                        // updates racing the create.
                        pendingPeekAt = now.addingTimeInterval(peekDelaySec)
                        lastBaseSig = baseSig
                        lastFullSig = sig
                    } else {
                        // A create that never arrived is not published. Stamping
                        // the signature here used to suppress every retry, so one
                        // failed frame could leave the notch empty for the whole
                        // session.
                        published = false
                        lastBaseSig = ""
                        lastFullSig = ""
                        reconnect()
                    }
                } else if published, sig != lastFullSig {
                    // Only the country flag changed: refresh the live activity in
                    // place instead of re-presenting the sneak peek.
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
                }
            }
        }

        armNextDeadline(connected: state.connected)
    }
}

/// One plugin per socket.
///
/// Two instances are not hypothetical: an install over a running plugin, or a
/// relaunch racing the exit, leaves a second process that answers the same
/// `activityID`, clobbers the first one's assets and holds its own status source
/// open. They also log duplicate events with their own generation counters,
/// which makes the log untrustworthy. `flock` is released by the kernel when the
/// process dies, so a crash never leaves a stale lock behind.
private final class InstanceLock {
    private let descriptor: Int32

    init?(socketPath: String) {
        let name = String(Self.stableHash(socketPath), radix: 16)
        let path = NSTemporaryDirectory() + "vpn-status-\(name).lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    /// FNV-1a: `hashValue` is seeded per process, so two instances would derive
    /// two different lock files from the same socket and both would win.
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
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

        // Held for the process lifetime; a second instance exits quietly rather
        // than fighting the first for the same activity.
        guard let instanceLock = InstanceLock(socketPath: socketPath) else {
            fputs("VPN Status: another instance already serves \(socketPath)\n", stderr)
            exit(0)
        }
        _ = instanceLock

        guard let signal = EventSignal() else {
            fputs("VPN Status: could not create the event pipe\n", stderr)
            exit(66)
        }

        let client = JSONSocketClient(socketPath: socketPath)
        do {
            try client.connect()
        } catch {
            fputs("VPN Status: \(error)\n", stderr)
            exit(65)
        }

        let plugin = VPNStatusPlugin(client: client, signal: signal)
        plugin.start()

        // Park the main thread in the main run loop, which is what services the
        // main queue: the socket and doorbell read sources, NetworkExtension's
        // callbacks and the peek/demote deadlines all run on the main thread,
        // and the plugin exits from there.
        //
        // `dispatchMain()` is not an option: measured, it runs submitted blocks
        // off the main thread and never fires a main-queue dispatch source at
        // all — the plugin would sit idle while frames piled up in its socket.
        // There is no polling loop left to run: the run loop sleeps until a
        // descriptor is readable or a deadline is due.
        while !shutdownRequested {
            RunLoop.main.run()
        }
        exit(0)
    }
}
