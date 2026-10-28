import Darwin
import Foundation

/// Answers "which interface carries this traffic?" from the kernel, in process.
///
/// Every answer here used to be a `/sbin/route -n get` spawn: three per Proton
/// probe, one per NetworkExtension sanity check, and one per routed-tunnel
/// lookup. A spawn costs about 3 ms of process launch on the loop's own thread
/// and shows up as a subprocess of the plugin, which is a lot of machinery for
/// a question the kernel already answers in two cheaper ways.
///
/// 1. **Source-address probe.** A UDP socket connected to a public address sends
///    nothing; the kernel merely resolves the route and binds the address it
///    would use. Reading that back with `getsockname` and mapping it through
///    `getifaddrs` names the interface traffic to that host actually leaves by —
///    the same choice `route -n get <host>` reports. It is family-correct
///    (IPv4 and IPv6) and costs a socket plus one interface enumeration, about
///    30 µs.
///
/// 2. **Default-route table scan.** A client-installed tunnel can own the
///    default route with no address assigned (X-VPN's idle utun shows no `inet`
///    line), so the probe cannot name an interface for it — there is no source
///    address to map. For that case the kernel's routing table is read directly
///    with `sysctl(NET_RT_DUMP)` and searched for a default destination.
///
/// Both are read-only and unprivileged. Neither spawns anything.
enum RouteTable {

    /// Addresses used only to make the kernel resolve a route; no packet is
    /// sent. Public resolvers, so the answer is "the ordinary internet path".
    static let ipv4ProbeHost = "1.1.1.1"
    static let ipv6ProbeHost = "2606:4700:4700::1111"

    // MARK: - Public answers

    /// The interface carrying traffic to `host`, an IPv4 or IPv6 literal.
    /// nil when the host cannot be parsed, when there is no route at all, or
    /// when the chosen route has no source address (see `defaultRouteInterfaces`).
    static func interfaceName(for host: String) -> String? {
        guard let target = ProbeTarget(host: host) else { return nil }
        return sourceInterface(family: target.family, address: target.address)
    }

    /// The tunnel interface on the default path, if traffic leaves through one.
    ///
    /// Prefers the kernel's own routing answer for a public address. When that
    /// answer belongs to a physical interface the table is consulted too: a
    /// client tunnel can own the default route without carrying an address, and
    /// then the probe names the physical interface while the tunnel is the one
    /// actually forwarding the traffic.
    static func tunnelInterfaceName() -> String? {
        if let probed = interfaceName(for: ipv4ProbeHost), isTunnel(probed) { return probed }
        if let routed = defaultRouteInterfaces().first(where: isTunnel) { return routed }
        if let probed = interfaceName(for: ipv6ProbeHost), isTunnel(probed) { return probed }
        return nil
    }

    /// Whether an interface name looks like a tunnel. Same rule the plugin has
    /// always used: the utun family, which is what every macOS VPN and every
    /// NetworkExtension provider installs.
    static func isTunnel(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("utun")
    }

    // MARK: - Routing table (sysctl)

    /// Every interface holding a default route — 0.0.0.0/0 or ::/0 — from the
    /// kernel's own table. A record counts when its destination address is
    /// unspecified and the kernel reports it up, which is what makes it a
    /// candidate for `route -n get 1.1.1.1`.
    static func defaultRouteInterfaces() -> [String] {
        var names: [String] = []
        for family in [AF_INET, AF_INET6] {
            for name in defaultRouteInterfaces(family: family) where !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    private static func defaultRouteInterfaces(family: Int32) -> [String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_DUMP, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 0 else { return [] }

        var names: [String] = []
        var offset = 0
        while offset + MemoryLayout<rt_msghdr>.size <= size {
            let header = buffer.withUnsafeBytes { $0.load(fromByteOffset: offset, as: rt_msghdr.self) }
            let length = Int(header.rtm_msglen)
            guard length > 0, offset + length <= size else { break }
            defer { offset += length }

            // Only real, usable routes: no reject/blackhole entries (a VPN app
            // that is not running leaves those behind) and no per-interface
            // scoped copies, which duplicate the same destination.
            guard Int32(header.rtm_type) == RTM_GET,
                  header.rtm_flags & RTF_UP != 0,
                  header.rtm_flags & RTF_REJECT == 0,
                  header.rtm_flags & RTF_BLACKHOLE == 0,
                  header.rtm_flags & RTF_IFSCOPE == 0,
                  header.rtm_index != 0,
                  header.rtm_addrs & Int32(1 << RTAX_DST) != 0 else { continue }

            // The first address of a record is always its destination (RTAX_DST
            // is bit 0). Reading only that one keeps this clear of the netmask
            // layout, which differs between the two families.
            let destinationOffset = offset + MemoryLayout<rt_msghdr>.size
            guard destinationOffset + 8 <= offset + length else { continue }
            let addressLength = Int(buffer[destinationOffset])
            guard addressLength >= 8, Int32(buffer[destinationOffset + 1]) == family else { continue }
            let addressOffset = destinationOffset + (family == AF_INET ? 4 : 8)
            let addressSize = family == AF_INET ? 4 : 16
            guard addressOffset + addressSize <= offset + length,
                  buffer[addressOffset..<(addressOffset + addressSize)].allSatisfy({ $0 == 0 })
            else { continue }

            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if if_indextoname(UInt32(header.rtm_index), &name) != nil {
                let resolved = String(cString: name)
                if !resolved.isEmpty, !names.contains(resolved) { names.append(resolved) }
            }
        }
        return names
    }

    // MARK: - Source-address probe

    private struct ProbeTarget {
        let family: Int32
        let address: [UInt8]

        init?(host: String) {
            var v4 = in_addr()
            if inet_pton(AF_INET, host, &v4) == 1 {
                family = AF_INET
                address = withUnsafeBytes(of: v4) { Array($0) }
                return
            }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, host, &v6) == 1 {
                family = AF_INET6
                address = withUnsafeBytes(of: v6) { Array($0) }
                return
            }
            return nil
        }
    }

    /// The interface owning the source address the kernel picks for
    /// `address`. A datagram socket connected to a public address is never
    /// sent from, so this is a route lookup, not traffic.
    private static func sourceInterface(family: Int32, address: [UInt8]) -> String? {
        let descriptor = socket(family, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var target = sockaddr_storage()
        var targetLength: socklen_t
        if family == AF_INET {
            guard address.count == 4 else { return nil }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(53).bigEndian
            withUnsafeMutableBytes(of: &addr.sin_addr) { $0.copyBytes(from: address) }
            targetLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeBytes(of: addr) { raw in
                withUnsafeMutableBytes(of: &target) { $0.copyBytes(from: raw) }
            }
        } else {
            guard address.count == 16 else { return nil }
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(53).bigEndian
            withUnsafeMutableBytes(of: &addr.sin6_addr) { $0.copyBytes(from: address) }
            targetLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeBytes(of: addr) { raw in
                withUnsafeMutableBytes(of: &target) { $0.copyBytes(from: raw) }
            }
        }

        let routed = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, targetLength)
            }
        }
        guard routed == 0 else { return nil }

        var local = sockaddr_storage()
        var localLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &localLength)
            }
        }
        guard named == 0 else { return nil }

        // Both layouts put the address after the family and port: 4 bytes into
        // `sockaddr_in`, 8 into `sockaddr_in6` (port plus flow info). Slicing
        // the bytes avoids an alignment-sensitive load entirely.
        let addressOffset = family == AF_INET ? 4 : 8
        let addressSize = family == AF_INET ? 4 : 16
        let bytes = withUnsafeBytes(of: local) { raw in
            Array(raw[addressOffset..<(addressOffset + addressSize)])
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return interfaceName(matching: bytes, family: family)
    }

    /// Which interface holds this address, from `getifaddrs`.
    static func interfaceName(matching address: [UInt8], family: Int32) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sockaddr = entry.pointee.ifa_addr,
                  Int32(sockaddr.pointee.sa_family) == family else { continue }
            let candidate: [UInt8]
            if family == AF_INET {
                candidate = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                }
            } else {
                candidate = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
            }
            if candidate == address {
                return String(cString: entry.pointee.ifa_name)
            }
        }
        return nil
    }
}
