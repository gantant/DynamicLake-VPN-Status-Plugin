import Foundation

// Regression tests for the NordVPN server-hostname location detection.
// The parser is the authoritative flag source for NordVPN connections with a
// `*.nordvpn.com` ServerAddress, so these tests pin the exact label grammar
// (two letters + optional digits), the host allowlist, and the rejections
// (IP literals, foreign hosts, malformed labels) that must fall back to the
// geo-IP resolver.
//
// Build & run via tests/run.sh (no network access).

private var failures = 0

private func check(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

private func checkNil(_ host: String?, _ label: String) {
    check(nordServerCountryCode(from: host) == nil, label)
}

private func checkCode(_ host: String?, _ expected: String, _ label: String) {
    check(nordServerCountryCode(from: host) == expected, label)
}

private func testParsing() {
    checkCode("am69.nordvpn.com", "AM", "armenia virtual location label")
    checkCode("us1234.nordvpn.com:443", "US", "host with port suffix")
    checkCode("am69.nordvpn.com:8443", "AM", "host with custom port")
    checkCode("us1234.nordvpn.com", "US", "us multi-digit label")
    checkCode("de1.nordvpn.com", "DE", "de single-digit label")
    checkCode("us1234.nordvpn.com.", "US", "fqdn trailing dot")
    checkCode("AM69.NORDVPN.COM", "AM", "uppercase input")
    checkCode("  us1234.nordvpn.com  ", "US", "whitespace trimmed")

    checkNil("vpn88.nordvpn.com", "three-letter label rejected")
    checkNil("a1.nordvpn.com", "one-letter label rejected")
    checkNil("123.nordvpn.com", "all-digit label rejected")
    checkNil("am-69.nordvpn.com", "hyphenated label rejected")
    checkNil("amb69.nordvpn.com", "three-letter prefix rejected")
    checkNil("am69.nordvpn.com.evil.com", "suffixed foreign host rejected")
    checkNil("am69.example.com", "foreign host rejected")
    checkNil("nordvpn.com", "bare domain rejected")
    checkNil("95.214.11.22", "ipv4 literal rejected")
    checkNil("95.214.11.22:443", "ipv4 literal with port rejected")
    checkNil("2001:db8::1", "ipv6 literal rejected")
    checkNil("[2001:db8::1]:443", "ipv6 literal with port rejected")
    checkNil("nl-xx.protonvpn.net", "proton host rejected")
    checkNil("", "empty string rejected")
    checkNil("   ", "whitespace-only rejected")
    checkNil(nil, "nil server address rejected")

    // The ISO-region cross-check: syntactically valid but non-ISO codes must
    // be rejected so the flag pipeline never receives an unusable code.
    checkNil("zz99.nordvpn.com", "non-iso code rejected")
}

private func testAddressShape() {
    // Diagnostics must never expose an address literal in the log.
    check(serverAddressShape("95.214.11.22") == "ipv4[:port]", "ipv4 masked")
    check(serverAddressShape("95.214.11.22:443") == "ipv4[:port]", "ipv4 with port masked")
    check(serverAddressShape("2001:db8::1") == "ipv6[:port]", "ipv6 masked")
    check(serverAddressShape("[2001:db8::1]:443") == "ipv6[:port]", "ipv6 with port masked")
    check(serverAddressShape("am69.nordvpn.com") == "host:am69.nordvpn.com", "hostname logged verbatim")
    check(serverAddressShape("  am69.nordvpn.com ") == "host:am69.nordvpn.com", "hostname trimmed")
}

private func testVirtualPools() {
    // NordWhisper exposes only the bare station IP as ServerAddress, so the
    // hardcoded virtual-location pools are the selected-location source on
    // current macOS clients. Pools captured from NordVPN's public catalog.
    check(nordVirtualLocationCountryCode(forIPv4: "187.15.167.1") == "AM", "armenia pool")
    check(nordVirtualLocationCountryCode(forIPv4: "187.15.167.67") == "AM", "armenia pool high host")
    check(nordVirtualLocationCountryCode(forIPv4: "187.15.167.1:894") == "AM", "pool ip with port")
    check(nordVirtualLocationCountryCode(forIPv4: " 187.15.167.3 ") == "AM", "pool ip whitespace trimmed")
    check(nordVirtualLocationCountryCode(forIPv4: "186.247.169.44") == "AD", "andorra pool")
    check(nordVirtualLocationCountryCode(forIPv4: "186.247.187.3") == "AZ", "azerbaijan pool")
    check(nordVirtualLocationCountryCode(forIPv4: "187.13.254.90") == "BS", "bahamas pool")
    check(nordVirtualLocationCountryCode(forIPv4: "187.14.80.45") == "MA", "morocco pool")
    check(nordVirtualLocationCountryCode(forIPv4: "187.40.224.1") == "VN", "vietnam pool one")
    check(nordVirtualLocationCountryCode(forIPv4: "187.40.60.45") == "VN", "vietnam pool two")

    // Non-virtual servers must keep the geo-IP fallback.
    check(nordVirtualLocationCountryCode(forIPv4: "89.35.28.131") == nil, "non-virtual station misses")
    check(nordVirtualLocationCountryCode(forIPv4: "1.2.3.4") == nil, "unknown ipv4 misses")
    check(nordVirtualLocationCountryCode(forIPv4: "187.15.166.1") == nil, "adjacent /24 misses (prefix boundary)")
    check(nordVirtualLocationCountryCode(forIPv4: "187.15.167") == nil, "incomplete ipv4 misses")
    check(nordVirtualLocationCountryCode(forIPv4: "am69.nordvpn.com") == nil, "hostname is not a station ip")
    check(nordVirtualLocationCountryCode(forIPv4: "2001:db8::1") == nil, "ipv6 misses")
    check(nordVirtualLocationCountryCode(forIPv4: "[2001:db8::1]:443") == nil, "ipv6 with port misses")
    check(nordVirtualLocationCountryCode(forIPv4: "") == nil, "empty misses")
    check(nordVirtualLocationCountryCode(forIPv4: nil) == nil, "nil misses")
}

@main
private struct NordServerLocationTests {
    static func main() {
        testParsing()
        testAddressShape()
        testVirtualPools()

        if failures == 0 {
            print("nord server location tests passed")
        } else {
            print("nord server location tests FAILED (\(failures))")
            exit(1)
        }
    }
}
