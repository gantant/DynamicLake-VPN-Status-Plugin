import Foundation
import NetworkExtension

/// Event-driven VPN status via the NetworkExtension framework (macOS 10.11+
/// APIs; the plugin's deployment target is far above the floor).
///
/// On macOS these APIs are formally for VPN management, but reading tunnel
/// configuration state and receiving `NEVPNStatusDidChange` works for an
/// unentitled, unsandboxed process (verified empirically: loadAllFromPreferences
/// enumerates the NordVPN/ProtonVPN tunnels and status events are delivered
/// without any entitlement). The plugin uses NE as its primary status source
/// and falls back to scutil polling whenever NE is unavailable, wedged, or
/// contradicted by the routing table (see VPNStatusPlugin's cross-checks).
///
/// Thread-safety: all mutable state is lock-protected. Notifications are
/// delivered on arbitrary XPC threads and the plugin's loop thread blocks in
/// a semaphore wait — nothing here may require a specific queue.
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

        public init(provider: String, connected: Bool, connecting: Bool,
                    serverAddress: String?, serviceName: String?, startDate: Date? = nil) {
            self.provider = provider
            self.connected = connected
            self.connecting = connecting
            self.serverAddress = serverAddress
            self.serviceName = serviceName
            self.startDate = startDate
        }
    }

    /// Called on an arbitrary queue whenever any NE tunnel reports a status
    /// change. Set before `load` so early events are not missed; the plugin
    /// uses it to wake its wait loop immediately.
    public static var onStatusChange: (() -> Void)?

    private static let lock = NSLock()
    private static var managers: [NETunnelProviderManager] = []
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
    /// provider name. Returns nil for anything unrecognized so the caller
    /// falls back to the scutil path (which also handles non-NE providers).
    public static func providerName(forDisplayName displayName: String?) -> String? {
        guard let name = displayName?.lowercased() else { return nil }
        if nordMarkers.contains(where: name.contains) { return "NordVPN" }
        if protonMarkers.contains(where: name.contains) { return "ProtonVPN" }
        return nil
    }

    // MARK: - Status extraction

    /// Converts a tunnel manager into a plugin-facing status, or nil when the
    /// tunnel does not belong to a recognized provider.
    public static func status(from manager: NETunnelProviderManager) -> Status? {
        guard let provider = providerName(forDisplayName: manager.localizedDescription) else { return nil }
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
            serviceName: manager.localizedDescription,
            startDate: manager.connection.connectedDate
        )
    }

    // MARK: - Loading and events

    /// Loads tunnel configurations and registers the status observer.
    /// `completion(false)` when the framework fails or exceeds `timeout`
    /// (neagent can hang when a system-extension service is wedged) — the
    /// caller then stays on the scutil path. Blocking for at most `timeout`.
    ///
    /// The completion may be delivered on the main queue — which never drains
    /// while the caller blocks — so this waits in slices and pumps the main
    /// RunLoop between slices. That same pump services NE notifications
    /// dispatched onto the main queue during normal operation.
    public static func load(timeout: TimeInterval = 5, completion: @escaping (Bool) -> Void) {
        registerObserversIfNeeded()
        let done = DispatchSemaphore(value: 0)
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            lock.lock()
            if error == nil {
                self.managers = managers ?? []
                loaded = true
                lastRefreshAt = Date()
            }
            lock.unlock()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var ok = false
        while true {
            if done.wait(timeout: .now() + 0.05) == .success {
                lock.lock()
                ok = loaded
                lock.unlock()
                break
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if Date() >= deadline { break }
        }
        if !ok { markUnhealthy() }
        completion(ok)
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
        }
    }

    /// Snapshot for the plugin loop: the best matching tunnel for the target
    /// (connected preferred over connecting), or nil when NE is unhealthy,
    /// not loaded, or no recognized tunnel exists.
    public static func bestStatus(target: Target) -> Status? {
        lock.lock()
        defer { lock.unlock() }
        guard loaded, Date() >= unhealthyUntil else { return nil }
        var best: Status?
        for manager in managers {
            guard let s = status(from: manager), s.provider == canonicalName(for: target) else { continue }
            if best == nil || (s.connected && !best!.connected) {
                best = s
            }
        }
        return best
    }

    // MARK: - Health (fallback heuristic)

    /// Suspends NE answers for `seconds` so the caller's scutil fallback can
    /// take over; the watcher self-heals when the epoch expires.
    public static func markUnhealthy(seconds: TimeInterval = 60) {
        lock.lock()
        unhealthyUntil = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    public static func isHealthy() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date() >= unhealthyUntil
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
