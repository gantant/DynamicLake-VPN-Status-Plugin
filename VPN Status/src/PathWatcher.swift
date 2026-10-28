import Foundation
import Network

/// Wake-up source for default-path changes, plus the tunnel question answered
/// from the kernel's routing table.
///
/// There used to be two mechanisms here: an `NWPathMonitor` mirror that was
/// trusted for answers, and a `/sbin/route -n get` spawn as its fallback and
/// verifier. The mirror's answer was wrong for client-installed tunnels (it
/// keeps reporting nil after such a utun takes the default route), which is why
/// the spawn had to stay — and why a "degraded to spawn-only" latch existed to
/// stop trusting it. Both are gone: the monitor is now only a doorbell, and the
/// answer comes from `RouteTable`, which reads the same table `route` does,
/// in process, in about 30 µs.
///
/// That leaves one job for the monitor: waking the plugin when the default path
/// changes, so a transition applies the instant it happens instead of on the
/// next poll. The plugin no longer polls at all.
public enum PathWatcher {

    /// Called on the monitor's private queue after every pushed path update.
    /// Set before `start` so early pushes are not missed.
    public static var onPathChange: (() -> Void)?

    private static let lock = NSLock()
    private static var monitor: NWPathMonitor?

    /// Starts the path monitor. Idempotent: it only ever wakes the plugin, so
    /// a missed push costs a later wake-up, never a wrong answer.
    public static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { _ in onPathChange?() }
        m.start(queue: DispatchQueue(label: "vpn-status.path-monitor", qos: .utility))
    }

    /// The interface traffic leaves through, when it is a tunnel — the same
    /// answer `route -n get 1.1.1.1` gives, in process.
    public static func tunnelInterface() -> String? {
        RouteTable.tunnelInterfaceName()
    }

    /// Whether an interface name is a tunnel interface.
    public static func isTunnelInterface(_ name: String?) -> Bool {
        RouteTable.isTunnel(name)
    }

    /// Whether an interface that owns the default route still exists. An
    /// address is deliberately not required: a client's tunnel can report no
    /// `inet` line (X-VPN's idle utun showed none), and owning the default
    /// route is what proves traffic is on it. `if_nametoindex` answers for any
    /// interface the kernel knows about, without a subprocess.
    public static func routedInterfaceExists(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return if_nametoindex(name) != 0
    }
}
