import Foundation

// Regression tests for the PathWatcher pure mapping layer. The NWPathMonitor
// runtime path cannot run deterministically in unit tests; the mapping logic
// exercised here is what keeps tunnel detection correct for both the push
// mirror and the legacy route-spawn fallback.
//
// Build & run via tests/run.sh (no network access).

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("PASS \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}

@main
struct PathWatcherTests {

    static func main() {
        testTunnelInterfaceMapping()
        testRouteOutputParsing()
        testMirrorUsability()
        finish()
    }

    // MARK: - NWPath interface list -> tunnel detection

    static func testTunnelInterfaceMapping() {
        expect(PathWatcher.tunnelInterfaceName(interfaceNames: ["utun5", "en0"], pathSatisfied: true) == "utun5", "utun on a satisfied path is the tunnel")
        expect(PathWatcher.tunnelInterfaceName(interfaceNames: ["en0", "utun3"], pathSatisfied: true) == "utun3", "utun is found regardless of list order")
        expect(PathWatcher.tunnelInterfaceName(interfaceNames: ["utun3", "utun9"], pathSatisfied: true) == "utun3", "first utun wins when several exist")
        expect(PathWatcher.tunnelInterfaceName(interfaceNames: ["en0"], pathSatisfied: true) == nil, "no utun -> no tunnel")
        expect(PathWatcher.tunnelInterfaceName(interfaceNames: [], pathSatisfied: true) == nil, "empty interface list -> no tunnel")
        expect(PathWatcher.tunnelInterfaceName(interfaceNames: ["utun5"], pathSatisfied: false) == nil, "unsatisfied path is never a tunnel")
        expect(PathWatcher.tunnelInterfaceName(interfaceNames: ["en0", "llw0", "awdl0"], pathSatisfied: true) == nil, "physical/awdl interfaces do not count")
    }

    // MARK: - route -n get output parsing (shared by mirror re-seed)

    static func testRouteOutputParsing() {
        let utunOutput = """
           route to: 1.1.1.1
        destination: default
               mask: 0.0.0.0
            gateway: 10.8.0.1
          interface: utun5
              flags: <UP,GATEWAY,HOST,DONE,STATIC>
        """
        expect(PathWatcher.routedInterface(fromRouteOutput: utunOutput) == "utun5", "route output parses the interface line")
        expect(PathWatcher.routedInterface(fromRouteOutput: "interface: en0") == "en0", "bare interface line parses")
        expect(PathWatcher.routedInterface(fromRouteOutput: "destination: default") == nil, "output without an interface line is nil")
        expect(PathWatcher.routedInterface(fromRouteOutput: "") == nil, "empty output is nil")
        expect(PathWatcher.routedInterface(fromRouteOutput: "interface:") == nil, "malformed interface line is nil")

        expect(PathWatcher.isTunnelInterface("utun5"), "utun5 is a tunnel interface")
        expect(PathWatcher.isTunnelInterface("en0") == false, "en0 is not a tunnel interface")
        expect(PathWatcher.isTunnelInterface(nil) == false, "nil is not a tunnel interface")
    }

    // MARK: - Mirror usability contract

    // The mirror answer is trusted only when the monitor resolved, the push
    // is fresh, and the watcher is not degraded; everything else must fall
    // back to the route spawn.
    static func testMirrorUsability() {
        let now = Date()
        let fresh = now.addingTimeInterval(-10)
        let stale = now.addingTimeInterval(-600)
        expect(PathWatcher.mirrorUsable(resolved: true, lastUpdateAt: fresh, now: now, degraded: false, stalenessLimit: 300), "fresh resolved mirror is usable")
        expect(PathWatcher.mirrorUsable(resolved: false, lastUpdateAt: fresh, now: now, degraded: false, stalenessLimit: 300) == false, "unresolved mirror is not usable")
        expect(PathWatcher.mirrorUsable(resolved: true, lastUpdateAt: stale, now: now, degraded: false, stalenessLimit: 300) == false, "stale mirror is not usable")
        expect(PathWatcher.mirrorUsable(resolved: true, lastUpdateAt: fresh, now: now, degraded: true, stalenessLimit: 300) == false, "degraded mirror is never usable")
        // Exactly at the staleness boundary counts as stale (strict less-than).
        let boundary = now.addingTimeInterval(-300)
        expect(PathWatcher.mirrorUsable(resolved: true, lastUpdateAt: boundary, now: now, degraded: false, stalenessLimit: 300) == false, "mirror at the staleness boundary is not usable")
    }

    static func finish() {
        if failures == 0 {
            print("path watcher tests passed (\(checks) checks)")
            exit(0)
        } else {
            print("path watcher tests FAILED (\(failures)/\(checks))")
            exit(1)
        }
    }
}
