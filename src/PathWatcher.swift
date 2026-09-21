import Foundation
import Network

/// Event-driven default-route tunnel detection via NWPathMonitor (Network
/// framework, macOS 10.14+ — far below the plugin's target).
///
/// The monitor pushes every default-path change onto a private queue and the
/// plugin reads the mirrored result, replacing periodic `/sbin/route -n get`
/// spawns (one per NetworkExtension sanity check while connected, plus every
/// WireGuard fallback poll) with zero-spawn reads that are also fresher: the
/// mirror updates the instant the route table changes, not on the next timer
/// tick.
///
/// Safety: until the first push arrives, and whenever the mirror goes stale
/// (no update within `mirrorStalenessLimit`, e.g. a wedged monitor), readers
/// transparently fall back to the classic route spawn — parsed through the
/// same tested parser — so answers can never regress. Decisions that would
/// tear down the NetworkExtension event source additionally confirm a "no
/// tunnel" mirror against the real route table first (see
/// `verifiedTunnelInterface`), and a proven mirror/table contradiction
/// permanently degrades the mirror to spawn-only for the process lifetime.
public enum PathWatcher {

    private static let lock = NSLock()
    private static var monitor: NWPathMonitor?
    private static var mirrorResolved = false
    /// The utun interface owning the default path, or nil when the default
    /// route is not on a tunnel. Only meaningful once `mirrorResolved`.
    private static var mirroredTunnel: String?
    private static var lastUpdateAt = Date.distantPast
    /// Degrade latch: once a fresh mirror is contradicted by the route
    /// table, stop trusting pushes for the process lifetime (spawn-only).
    private static var degraded = false
    private static let mirrorStalenessLimit: TimeInterval = 300

    // MARK: - Lifecycle

    /// Starts the path monitor. Idempotent; the first push typically arrives
    /// within milliseconds, before the plugin loop's first read.
    public static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { path in
            let names = path.availableInterfaces.map(\.name)
            let tunnel = tunnelInterfaceName(interfaceNames: names, pathSatisfied: path.status == .satisfied)
            lock.lock()
            mirroredTunnel = tunnel
            mirrorResolved = true
            lastUpdateAt = Date()
            lock.unlock()
        }
        m.start(queue: DispatchQueue(label: "vpn-status.path-monitor", qos: .utility))
    }

    // MARK: - Pure mapping (unit-tested)

    /// The tunnel interface owning the default path: the first `utun*`
    /// interface available for a satisfied path. A VPN default route commonly
    /// coexists with the physical uplink (scoped traffic to the VPN server),
    /// so any utun in the list counts.
    public static func tunnelInterfaceName(interfaceNames: [String], pathSatisfied: Bool) -> String? {
        guard pathSatisfied else { return nil }
        return interfaceNames.first { $0.hasPrefix("utun") }
    }

    /// Parses the default-route interface name from `/sbin/route -n get
    /// <host>` output — the legacy spawn path shares this tested parser.
    public static func routedInterface(fromRouteOutput output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[0] == "interface:" else { continue }
            return String(fields[1])
        }
        return nil
    }

    /// Whether an interface name is a tunnel interface.
    public static func isTunnelInterface(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("utun")
    }

    /// Whether a push mirror answer may be trusted right now.
    public static func mirrorUsable(resolved: Bool, lastUpdateAt: Date, now: Date, degraded: Bool, stalenessLimit: TimeInterval) -> Bool {
        !degraded && resolved && now.timeIntervalSince(lastUpdateAt) < stalenessLimit
    }

    // MARK: - Readers

    /// The tunnel interface owning the default route: push mirror first,
    /// legacy route spawn as fallback (which also re-seeds the mirror).
    public static func routedTunnelInterface() -> String? {
        lock.lock()
        let usable = mirrorUsable(
            resolved: mirrorResolved,
            lastUpdateAt: lastUpdateAt,
            now: Date(),
            degraded: degraded,
            stalenessLimit: mirrorStalenessLimit
        )
        let cached = mirroredTunnel
        lock.unlock()
        if usable { return cached }
        return spawnRouteTunnel()
    }

    /// Force-verified answer for decisions that would tear down the
    /// NetworkExtension event source: always consults the real route table.
    /// A fresh mirror contradicted by the table is degraded permanently
    /// (logged by the caller).
    @discardableResult
    public static func verifiedTunnelInterface() -> String? {
        lock.lock()
        let wasResolved = mirrorResolved
        let wasFresh = mirrorUsable(
            resolved: mirrorResolved,
            lastUpdateAt: lastUpdateAt,
            now: Date(),
            degraded: degraded,
            stalenessLimit: mirrorStalenessLimit
        )
        let mirrorValue = mirroredTunnel
        lock.unlock()
        let spawn = spawnRouteTunnel()
        if wasResolved, wasFresh, spawn != mirrorValue {
            lock.lock()
            degraded = true
            lock.unlock()
        }
        return spawn
    }

    private static func spawnRouteTunnel() -> String? {
        let (data, status) = runProcess("/sbin/route", arguments: ["-n", "get", "1.1.1.1"], timeout: 1)
        guard status == 0,
              let output = String(data: data, encoding: .utf8),
              let iface = routedInterface(fromRouteOutput: output),
              isTunnelInterface(iface) else { return nil }
        lock.lock()
        if !degraded {
            mirroredTunnel = iface
            mirrorResolved = true
            lastUpdateAt = Date()
        }
        lock.unlock()
        return iface
    }
}
