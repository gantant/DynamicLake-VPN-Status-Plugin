import Foundation

// Regression tests for the spawn-free routing answer. The plugin used to read
// the route table with `/sbin/route -n get`; `RouteTable` reads it from the
// kernel instead. What is pinned here is that the replacement agrees with the
// kernel's own view — including the scoped IPv6 defaults that must not be
// mistaken for a VPN.
//
// Build & run via tests/run.sh.

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
        testInterfaceLiveness()
        testTunnelNaming()
        testAddressProbe()
        testDefaultRouteTable()
        testScopedDefaultsExcluded()
        finish()
    }

    // MARK: - Interface liveness

    // A tunnel with no address still passes traffic (X-VPN's idle utun showed
    // no `inet` line), so liveness may not require one.
    static func testInterfaceLiveness() {
        expect(PathWatcher.routedInterfaceExists("lo0"), "loopback exists")
        expect(PathWatcher.routedInterfaceExists("en0") || PathWatcher.routedInterfaceExists("en1"), "a physical interface exists")
        expect(!PathWatcher.routedInterfaceExists("utun9999"), "absent interface does not exist")
        expect(!PathWatcher.routedInterfaceExists(""), "empty name does not exist")
    }

    static func testTunnelNaming() {
        expect(PathWatcher.isTunnelInterface("utun5"), "utun5 is a tunnel interface")
        expect(PathWatcher.isTunnelInterface("en0") == false, "en0 is not a tunnel interface")
        expect(PathWatcher.isTunnelInterface(nil) == false, "nil is not a tunnel interface")
        expect(PathWatcher.isTunnelInterface("") == false, "empty name is not a tunnel interface")
        expect(PathWatcher.isTunnelInterface("utun") , "the bare utun name is still the utun family")
    }

    // MARK: - Source-address probe

    // A UDP socket connected to a public address is never sent from: the kernel
    // resolves the route and binds the address it would use, which maps to the
    // interface traffic leaves by. The route itself depends on the machine, so
    // what is pinned here is the mapping and the contract.
    static func testAddressProbe() {
        expect(RouteTable.interfaceName(for: "example.com") == nil, "a hostname is not an address literal")
        expect(RouteTable.interfaceName(for: "") == nil, "an empty host has no interface")
        expect(RouteTable.interfaceName(for: "not an ip") == nil, "garbage has no interface")
        expect(RouteTable.interfaceName(matching: [127, 0, 0, 1], family: AF_INET) == "lo0", "127.0.0.1 maps to lo0")
        expect(RouteTable.interfaceName(matching: [0, 0, 0, 0], family: AF_INET) == nil, "the unspecified address maps to no interface")
        expect(RouteTable.interfaceName(matching: [10, 255, 255, 255], family: AF_INET) == nil, "an unassigned address maps to no interface")
        let ipv6Loopback: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        expect(RouteTable.interfaceName(matching: ipv6Loopback, family: AF_INET6) == "lo0", "::1 maps to lo0")
        expect(RouteTable.interfaceName(matching: [UInt8](repeating: 0, count: 16), family: AF_INET6) == nil, ":: maps to no interface")

        if let probed = RouteTable.interfaceName(for: RouteTable.ipv4ProbeHost) {
            expect(PathWatcher.routedInterfaceExists(probed), "the probe answer names a live interface")
        }
        if let probed = RouteTable.interfaceName(for: RouteTable.ipv6ProbeHost) {
            expect(PathWatcher.routedInterfaceExists(probed), "the IPv6 probe answer names a live interface")
        }
        // A nil probe is legitimate (no default route at all) and is handled by
        // the routing-table read, so it is not a failure here.
    }

    // MARK: - Routing table

    static func testDefaultRouteTable() {
        for name in RouteTable.defaultRouteInterfaces() {
            expect(PathWatcher.routedInterfaceExists(name), "default-route interface \(name) is live")
        }
        if let tunnel = PathWatcher.tunnelInterface() {
            expect(tunnel.hasPrefix("utun"), "a tunnel answer is a utun interface")
            expect(PathWatcher.routedInterfaceExists(tunnel), "the tunnel answer names a live interface")
        }
    }

    // A scoped default (`RTF_IFSCOPE`) belongs to one interface only — macOS
    // installs several on its own utun0/utun1/utun2 for Private Relay. Counting
    // those would report a VPN on a machine that has none, which is exactly the
    // bug this filter exists to prevent.
    static func testScopedDefaultsExcluded() {
        let defaults = netstatDefaults(family: "inet") + netstatDefaults(family: "inet6")
        guard !defaults.isEmpty else { return }   // offline machine: nothing to compare
        let unscoped = Set(defaults.filter { !$0.scoped }.map(\.name))
        expect(Set(RouteTable.defaultRouteInterfaces()) == unscoped,
               "routing-table defaults match netstat's unscoped defaults (\(RouteTable.defaultRouteInterfaces()) vs \(Array(unscoped)))")
        let scopedOnly = Set(defaults.filter { $0.scoped }.map(\.name)).subtracting(unscoped)
        for name in scopedOnly {
            expect(!RouteTable.defaultRouteInterfaces().contains(name),
                   "scoped default on \(name) is not a default-route candidate")
        }
    }

    /// Default-route entries as `netstat` reports them, so the test asserts
    /// against the same table the plugin reads rather than against itself.
    private static func netstatDefaults(family: String) -> [(name: String, scoped: Bool)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-rn", "-f", family]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var entries: [(name: String, scoped: Bool)] = []
        for line in text.components(separatedBy: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 4, fields[0] == "default" else { continue }
            // Flags are the third column; `I` marks a per-interface (scoped)
            // copy of the route.
            entries.append((String(fields[fields.count - 1]), fields[2].contains("I")))
        }
        return entries
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
