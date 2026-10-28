import Foundation

// MARK: - NordVPN selected-location detection

/// NordVPN operates virtual locations: the physical hardware for a virtual
/// country (e.g. Armenia) sits in another country (e.g. Bulgaria), so the
/// exit IP and every IP-geolocation source report the physical country. The
/// *selected* location must therefore come from the server identity itself.
///
/// Two sources, in priority order:
/// 1. Legacy configs expose a `*.nordvpn.com` hostname whose first label
///    encodes the location (`am69.nordvpn.com` -> AM).
/// 2. NordWhisper exposes only the bare station IP as the macOS
///    ServerAddress, so virtual locations are matched against a hardcoded
///    table of observed station pools (see below).
/// A nil result falls back to the geo-IP resolver, which stays correct for
/// every non-virtual server.
///
/// Only the first label is trusted and only for hosts on `nordvpn.com`:
/// - `am69.nordvpn.com`     -> "AM"
/// - `us1234.nordvpn.com`   -> "US"
/// - `am69.nordvpn.com.`    -> "AM"   (FQDN with trailing dot)
/// - `am69.nordvpn.com:443` -> "AM"   (host:port form)
/// - `vpn88.nordvpn.com`    -> nil    (3-letter label, not a country code)
/// - `95.214.11.22`         -> nil    (IP literal — see the pool table)
/// - `am69.example.com`     -> nil    (foreign host, never trusted)
func nordServerCountryCode(from serverAddress: String?) -> String? {
    guard var host = serverAddress?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty else { return nil }
    if host.hasSuffix("]") { return nil }          // [v6]:port form — a literal
    if host.hasSuffix(".") { host.removeLast() }   // FQDN trailing dot
    if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) } // host:port
    guard host.hasSuffix(".nordvpn.com") else { return nil }
    let labels = host.split(separator: ".")
    guard labels.count >= 3, let first = labels.first else { return nil }
    // Country label is exactly two letters optionally followed by digits
    // ("am69"). Anything else (3+ letters, hyphenated names, pure digits)
    // is not trusted.
    guard first.count >= 2,
          let letterEnd = first.firstIndex(where: { !$0.isLetter }),
          first.distance(from: first.startIndex, to: letterEnd) == 2,
          first.unicodeScalars.prefix(2).allSatisfy({ (97...122).contains(Int($0.value)) }),
          first[letterEnd...].allSatisfy({ $0.isNumber }) else { return nil }
    let code = String(first.prefix(2)).uppercased()
    // Only genuine ISO-style two-letter codes; the grammar above already
    // guarantees the shape, this is belt-and-suspenders for flag assets.
    guard Locale.Region.isoRegions.contains(Locale.Region(code)) else { return nil }
    return code
}

/// Observed station-IP pools for NordVPN's virtual locations (captured from
/// NordVPN's public server catalog, 2026-09). The physical hardware for each
/// of these locations sits in another country, so geo-IP can only ever report
/// the host country there; the picked location is recovered from the station
/// address itself. Every observed station for a location shares its /24, so
/// prefix matching on the first three octets is sufficient granularity.
/// Locations and pools do change — extend this table as Nord adds or moves
/// virtual locations; unmatched addresses keep the geo-IP fallback.
private let nordVirtualLocationPools: [(prefix: String, code: String)] = [
    ("186.247.169.", "AD"),   // Andorra (virtual)
    ("187.15.167.", "AM"),    // Armenia (virtual, hosted in Bulgaria)
    ("186.247.187.", "AZ"),   // Azerbaijan (virtual)
    ("187.13.254.", "BS"),    // Bahamas (virtual)
    ("187.14.80.", "MA"),     // Morocco (virtual)
    ("187.40.224.", "VN"),    // Vietnam (virtual)
    ("187.40.60.", "VN")      // Vietnam, second pool
]

/// Maps a station address (`ServerAddress` from NordWhisper, optionally with
/// a `:port` suffix) to the selected virtual location, or nil when the
/// address is not IPv4 or belongs to no known virtual pool.
func nordVirtualLocationCountryCode(forIPv4 address: String?) -> String? {
    guard var t = address?.trimmingCharacters(in: .whitespacesAndNewlines),
          !t.isEmpty else { return nil }
    if t.hasSuffix("]") { return nil }             // [v6]:port form
    if let colon = t.firstIndex(of: ":") { t = String(t[..<colon]) } // host:port
    guard t.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil else { return nil }
    for pool in nordVirtualLocationPools where t.hasPrefix(pool.prefix) {
        return pool.code
    }
    return nil
}

/// Describes a ServerAddress for diagnostics without ever exposing an IP:
/// address literals are reduced to their shape (the plugin never logs IPs),
/// while infrastructure hostnames are logged as-is to diagnose unexpected
/// NordWhisper formats.
func serverAddressShape(_ address: String) -> String {
    let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
    // IPv4 first: its all-decimal form is also valid hex text, so an
    // address-with-port like 95.214.11.22:443 would otherwise be eaten by
    // the looser IPv6 character class below (which accepts digits and dots).
    if t.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?$"#, options: .regularExpression) != nil {
        return "ipv4[:port]"
    }
    if t.contains(":"),
       t.range(of: #"^\[?[0-9a-fA-F:.]+\]?(:\d+)?$"#, options: .regularExpression) != nil {
        return "ipv6[:port]"
    }
    return "host:\(t)"
}
