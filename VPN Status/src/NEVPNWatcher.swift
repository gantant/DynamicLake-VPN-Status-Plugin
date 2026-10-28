import Foundation
import NetworkExtension

/// Event-driven VPN status via the NetworkExtension framework (macOS 10.11+
/// APIs; the plugin's deployment target is far above the floor).
///
/// On macOS these APIs are formally for VPN management, but reading tunnel
/// configuration state and receiving `NEVPNStatusDidChange` works for an
/// unentitled, unsandboxed process (verified empirically: loadAllFromPreferences
/// enumerates the NordVPN/ProtonVPN tunnels and status events are delivered
/// without any entitlement). The plugin uses NE as its primary status source;
/// `RouteTable` answers what NE cannot (a tunnel no configuration describes).
///
/// Thread-safety: all mutable state is lock-protected. Notifications are
/// delivered on arbitrary XPC threads; the plugin's work runs on the main
/// queue, so nothing here may require a specific queue.
public enum NEVPNWatcher {

    public enum Target: Equatable {
        case nord
        case proton
    }

    public struct Status: Equatable {
        /// Canonical provider name ("NordVPN" / "ProtonVPN").
        public let provider: String
        public let connected: Bool
        /// Mid-handshake. Treated as "not connected" by the plugin so the
        /// connect Sneak Peek waits for the real connected event.
        public let connecting: Bool
        public let serverAddress: String?
        /// The tunnel's user-facing description (e.g. "NordVPN - NordWhisper").
        public let serviceName: String?
        /// Start of the current connection session (nil while disconnected).
        /// Server switches start a new session, so this is the stable identity
        /// for detecting switches on providers whose config-level server
        /// address does not change (e.g. ProtonVPN's profile servers).
        public let startDate: Date?
        /// True for a transparent-proxy configuration rather than a tunnel.
        /// A proxy installs no route, so the routing table says nothing about
        /// it and its own NEVPNConnection is the only evidence.
        public let isProxy: Bool

        public init(provider: String, connected: Bool, connecting: Bool,
                    serverAddress: String?, serviceName: String?, startDate: Date? = nil,
                    isProxy: Bool = false) {
            self.provider = provider
            self.connected = connected
            self.connecting = connecting
            self.serverAddress = serverAddress
            self.serviceName = serviceName
            self.startDate = startDate
            self.isProxy = isProxy
        }
    }

    /// Called on an arbitrary queue whenever any NE tunnel reports a status
    /// change. Set before `load` so early events are not missed; the plugin
    /// uses it to wake its wait loop immediately.
    public static var onStatusChange: (() -> Void)?

    /// Called when the set of transparent-proxy configurations changes (name
    /// list, sorted and comma-joined). The plugin logs it, which is what makes
    /// "no proxy VPN was detected" distinguishable from "one was seen and
    /// suppressed". Kept as a closure so this file stays testable on its own.
    public static var onProxyConfigsChanged: ((String) -> Void)?

    private static var lastProxySignature = ""

    private static let lock = NSLock()
    private static var managers: [NETunnelProviderManager] = []
    /// Transparent-proxy configurations (macOS 10.15+). Proxy-only VPN apps —
    /// X-VPN and friends — route traffic through an NEAppProxyProvider and
    /// install no tunnel at all, so they never owe a route and are invisible to
    /// the routing table. They still publish an NEVPNConnection, so their
    /// status arrives through the same `NEVPNStatusDidChange` notification as a
    /// tunnel: event-driven, never polled.
    private static var proxyManagers: [NETransparentProxyManager] = []
    private static var loaded = false
    private static var observersRegistered = false
    private static var notificationQueue: OperationQueue?
    private static var lastRefreshAt = Date.distantPast
    /// Epoch until which bestStatus refuses to report (set after a load
    /// failure or a cross-check contradiction); expired state self-heals.
    private static var unhealthyUntil = Date.distantPast
    /// Environment overrides for the pure mapping (tests inject; production
    /// always uses the defaults). Kept private(set) so tests can verify both.
    private static let nordMarkers = ["nordvpn", "nordwhisper"]
    private static let protonMarkers = ["protonvpn", "proton"]

    // MARK: - Pure mapping (unit-tested)

    /// Maps a tunnel's user-facing description to the plugin's canonical
    /// provider name. Returns nil for anything unrecognized, which lets the
    /// caller fall back to the configuration's own name (`anyStatus`) or to the
    /// route table.
    public static func providerName(forDisplayName displayName: String?) -> String? {
        guard let name = displayName?.lowercased() else { return nil }
        if nordMarkers.contains(where: name.contains) { return "NordVPN" }
        if protonMarkers.contains(where: name.contains) { return "ProtonVPN" }
        return nil
    }

    /// Provider name for a transparent-proxy configuration, or nil when the
    /// configuration must not be reported as its own connection.
    ///
    /// A proxy belonging to a tunnel provider is that provider's auxiliary
    /// path — Proton's "Split tunnelling" proxy can be enabled while the tunnel
    /// is down, and reporting it as a ProtonVPN connection would be a lie. An
    /// app with no tunnel at all (X-VPN) has only its proxy, so there the proxy
    /// *is* the VPN and its own name is the provider. Vendor suffixes are
    /// dropped so "X-VPN - System Proxy" reads as "X-VPN".
    public static func proxyProviderName(forDisplayName displayName: String?) -> String? {
        guard let raw = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              providerName(forDisplayName: raw) == nil else { return nil }
        let head = raw.components(separatedBy: " - ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        return head.isEmpty ? nil : head
    }

    // MARK: - Status extraction

    /// Converts a tunnel manager into a plugin-facing status, or nil when the
    /// tunnel does not belong to a recognized provider.
    ///
    /// `namingUnrecognized` keeps the configuration's own description as the
    /// provider instead of dropping it, which is how a tunnel this plugin has no
    /// mapping for (Hotspot Shield, a vendor's own WireGuard build) is still
    /// reported by its real name rather than as an anonymous "VPN".
    public static func status(from manager: NETunnelProviderManager, namingUnrecognized: Bool = false) -> Status? {
        let description = manager.localizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        var provider = providerName(forDisplayName: description)
        if provider == nil, namingUnrecognized, let description, !description.isEmpty {
            provider = description
        }
        guard let provider else { return nil }
        let st = manager.connection.status
        // Read the address off the base protocol configuration: casting to
        // NETunnelProviderProtocol would drop it for IKEv2-style system
        // configs (the form system-extension providers can use).
        let server = manager.protocolConfiguration?.serverAddress
        return Status(
            provider: provider,
            connected: st == .connected,
            connecting: st == .connecting,
            serverAddress: server,
            serviceName: description,
            startDate: manager.connection.connectedDate
        )
    }

    // MARK: - Loading and events

    /// Loads tunnel and proxy configurations and registers the status observer.
    ///
    /// Asynchronous on purpose. NetworkExtension answers on the main queue, and
    /// a caller that blocks the main thread without servicing that queue never
    /// gets an answer at all (measured: a semaphore wait on the main thread
    /// times out even though the framework is healthy). The plugin therefore
    /// renders its first card from the routing table and lets this completion
    /// wake it when the tunnels are known.
    public static func load(completion: ((Bool) -> Void)? = nil) {
        registerObserversIfNeeded()
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            lock.lock()
            if error == nil {
                self.managers = managers ?? []
                loaded = true
                lastRefreshAt = Date()
            }
            lock.unlock()
            if error != nil { markUnhealthy() }
            completion?(error == nil)
        }
        // Proxies load alongside, not in series: a host with no proxy VPN has
        // nothing to wait for, and a slow proxy lookup must not delay the
        // tunnel path (which is what decides this source's health).
        loadProxyManagers()
    }

    /// Re-enumerates tunnels (new configs can appear after first load).
    /// Throttled unless `force` is set (used after sleep/wake gaps).
    public static func refresh(force: Bool = false) {
        lock.lock()
        let now = Date()
        if !force, now.timeIntervalSince(lastRefreshAt) < 60 {
            lock.unlock()
            return
        }
        lastRefreshAt = now
        lock.unlock()
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            guard error == nil else { markUnhealthy(); return }
            lock.lock()
            self.managers = managers ?? []
            loaded = true
            lock.unlock()
            // A configuration that appeared or changed is a reason to
            // re-render, and it is an event, so nothing has to poll for it.
            onStatusChange?()
        }
        loadProxyManagers()
    }

    /// Re-enumerates transparent-proxy configurations. Best effort: a host that
    /// has none (or an API that fails) simply keeps the previous list, and the
    /// failure never marks the tunnel source unhealthy.
    private static func loadProxyManagers() {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            guard error == nil else { return }
            let names = (managers ?? [])
                .map { $0.localizedDescription ?? "?" }
                .sorted()
            let signature = names.joined(separator: ", ")
            lock.lock()
            proxyManagers = managers ?? []
            let changed = signature != lastProxySignature
            lastProxySignature = signature
            lock.unlock()
            // Logged only when the set changes: one line at startup, then a
            // line per proxy VPN that appears or goes away.
            if changed { onProxyConfigsChanged?(signature) }
        }
    }

    /// Snapshot for the plugin loop: the best matching tunnel for the target
    /// (connected preferred over connecting), or nil when NE is unhealthy,
    /// not loaded, or no recognized tunnel exists.
    public static func bestStatus(target: Target) -> Status? {
        lock.lock()
        defer { lock.unlock() }
        guard loaded, Date() >= unhealthyUntil else { return nil }
        let canonical = canonicalName(for: target)
        return pickBest(managers.compactMap { manager in
            guard let s = status(from: manager), s.provider == canonical else { return nil }
            return s
        })
    }

    /// The best connected (or connecting) tunnel of *any* provider, named by
    /// its own configuration when this plugin has no mapping for it.
    ///
    /// A VPN the plugin does not recognize used to be invisible to this source
    /// and visible only as an anonymous routed tunnel, which is how an X-VPN
    /// session ended up attributed to whichever brand was installed. Its
    /// configuration name is accurate and arrives with the same event as any
    /// other tunnel's status.
    public static func anyStatus() -> Status? {
        lock.lock()
        defer { lock.unlock() }
        guard loaded, Date() >= unhealthyUntil else { return nil }
        return pickBest(managers.compactMap { status(from: $0, namingUnrecognized: true) })
    }

    /// A connected tunnel outranks a connecting one; otherwise the first entry
    /// wins, so the caller always sees the most advanced state available.
    private static func pickBest(_ statuses: [Status]) -> Status? {
        statuses.first(where: { $0.connected })
            ?? statuses.first(where: { $0.connecting })
            ?? statuses.first
    }

    /// The best connected (or connecting) transparent-proxy VPN, or nil when
    /// every proxy belongs to a tunnel provider or none is up. The manager
    /// objects stay live, so `connection.status` reads the pushed state without
    /// re-enumerating anything.
    public static func proxyStatus() -> Status? {
        lock.lock()
        defer { lock.unlock() }
        guard loaded, Date() >= unhealthyUntil else { return nil }
        var best: Status?
        for manager in proxyManagers {
            guard let provider = proxyProviderName(forDisplayName: manager.localizedDescription) else { continue }
            let connection = manager.connection
            let status = Status(
                provider: provider,
                connected: connection.status == .connected,
                connecting: connection.status == .connecting,
                serverAddress: nil,
                serviceName: manager.localizedDescription,
                startDate: connection.connectedDate,
                isProxy: true
            )
            if best == nil || (status.connected && !best!.connected) {
                best = status
            }
        }
        return best
    }

    // MARK: - Health (fallback heuristic)

    /// Suspends NE answers for `seconds` (a load failure or a wedged framework);
    /// the caller then reports what the routing table says. The watcher
    /// self-heals when the epoch expires, and the next event re-reads it.
    public static func markUnhealthy(seconds: TimeInterval = 60) {
        lock.lock()
        unhealthyUntil = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    // MARK: - Private

    private static func canonicalName(for target: Target) -> String {
        switch target {
        case .nord: return "NordVPN"
        case .proton: return "ProtonVPN"
        }
    }

    private static func registerObserversIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !observersRegistered else { return }
        observersRegistered = true
        // An explicit private queue decouples delivery from the posting
        // thread: even if NE marshals status changes onto the main queue, the
        // block runs here (the plugin's main thread is the blocked loop
        // thread, so main-queue delivery would otherwise never fire).
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // Retained for the observer's lifetime: NotificationCenter does not
        // keep the queue alive, and a deallocated queue silently stops
        // delivering (this is why the property is written and never read).
        notificationQueue = queue
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NEVPNStatusDidChange,
            object: nil,
            queue: queue
        ) { _ in
            // New tunnels can appear after the first load; re-enumerate
            // (throttled internally) so the mirror never goes stale, and wake
            // the plugin loop so transitions apply immediately.
            refresh()
            onStatusChange?()
        }
    }
}
