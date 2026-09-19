import Foundation

// MARK: - ProtonVPN stabilized exit-IP detection
//
// NordVPN behavior is intentionally untouched: only providers whose name
// contains "proton" (case-insensitive) take this path. Everything else keeps
// using the single-shot country resolver in VPNStatusPlugin.swift.
//
// Background: during a ProtonVPN reconnect / Quick Connect / server change,
// `scutil` can already report Connected and a utun route can already exist
// while the OLD Proton exit route is still carrying traffic. A single
// country-only lookup run in that window returns the OLD exit country and the
// main loop accepts it, because only the country code is tracked. The fix is
// to resolve BOTH the public exit IP and the country, twice, and only accept
// the country when the same exit IP is observed in both probes with a stable
// utun route around them.

/// Gap between the two Proton exit probes. Short on purpose: stability comes
/// from comparing two observations, not from waiting longer.
let protonExitProbeGapSec: TimeInterval = 0.4
/// Proton re-probes while connected on this cadence (NordVPN keeps using
/// `countryRefreshIntervalSec`). Shorter because a Proton server switch does
/// not necessarily change the service name, server address, or utun
/// interface, so the public exit IP is part of the effective connection
/// identity and must be re-checked to notice the switch.
let protonExitRefreshIntervalSec: TimeInterval = 5
/// Keep in sync with `pluginUserAgent` in VPNStatusPlugin.swift.
let protonExitUserAgent = "VPNStatus-DynamicLake/1.1.6"

/// True only for ProtonVPN. NordVPN (and every other provider, including nil)
/// must keep the existing single-shot country behavior.
func usesProtonStabilizedExit(provider: String?) -> Bool {
    guard let provider, !provider.isEmpty else { return false }
    return provider.lowercased().contains("proton")
}

/// One exit observation: the public IP as seen by the lookup server plus the
/// country that IP currently exits through.
struct ProtonExitProbe {
    let ip: String
    let countryCode: String
    let countryName: String
}

/// A stabilized Proton exit result. Only published when two consecutive
/// probes observed the same exit IP under the same generation with a stable
/// utun route. An empty `countryCode` means "not stable, retry".
struct ProtonExitIdentity {
    let ip: String
    let countryCode: String
    let countryName: String
    let generation: UInt64
}

/// Pure, synchronously testable verdict for a pair of Proton exit probes.
enum ProtonExitDisposition: Equatable {
    /// Both probes agree; safe to publish.
    case accept
    /// Probes disagree (server transition in flight); probe again, publish nothing.
    case unstableRetry
    /// The utun route vanished or moved mid-probes; wait for it to stabilize.
    case routeRetry
    /// A newer generation started (reconnect / disconnect / server change was
    /// detected elsewhere); this pair belongs to the past.
    case staleDiscard
    /// VPN is no longer connected; clear state, publish nothing.
    case disconnectedDiscard
}

/// Decides what to do with two Proton exit probes. No networking, no logging,
// no public-IP handling beyond string comparison (callers must never log IPs).
func evaluateProtonExit(
    first: ProtonExitProbe?,
    second: ProtonExitProbe?,
    routeBefore: String?,
    routeBetween: String?,
    routeAfter: String?,
    generation: UInt64,
    currentGeneration: UInt64,
    connected: Bool
) -> ProtonExitDisposition {
    guard connected else { return .disconnectedDiscard }
    guard generation == currentGeneration else { return .staleDiscard }
    guard let before = routeBefore, !before.isEmpty,
          let between = routeBetween, !between.isEmpty,
          let after = routeAfter, !after.isEmpty,
          before == between, between == after
    else { return .routeRetry }
    guard let first, !first.ip.isEmpty, !first.countryCode.isEmpty,
          let second, !second.ip.isEmpty, !second.countryCode.isEmpty,
          first.ip == second.ip,
          first.countryCode == second.countryCode
    else { return .unstableRetry }
    return .accept
}

// MARK: - Exit-IP route helpers (IPv4/IPv6 correctness)
//
// The main loop validates `route -n get 1.1.1.1` (IPv4). URLSession, however,
// may reach the lookup server over IPv6 while only IPv4 was validated. The
// Proton path therefore additionally checks the route for the *observed exit
// IP itself*, using `-inet6` for IPv6 literals, so a lookup that escaped over
// another path is discarded instead of published.

/// `route` arguments that reveal which interface carries traffic to `host`.
/// Uses `-inet6` for IPv6 literals so the checked family matches the address.
func routeArguments(forHost host: String) -> [String] {
    if host.contains(":") {
        return ["-n", "get", "-inet6", host]
    }
    return ["-n", "get", host]
}

/// Extracts the interface name from `route -n get` output, or nil when the
/// output carries no interface line.
func parseRouteInterface(from output: String) -> String? {
    for line in output.components(separatedBy: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, fields[0] == "interface:" else { continue }
        return String(fields[1])
    }
    return nil
}

func routeInterfaceForHost(_ host: String, timeout: TimeInterval = 1) -> String? {
    let (data, status) = runProcess("/sbin/route", arguments: routeArguments(forHost: host), timeout: timeout)
    guard status == 0, let output = String(data: data, encoding: .utf8) else { return nil }
    return parseRouteInterface(from: output)
}

func isTunnelInterface(_ name: String?) -> Bool {
    guard let name else { return false }
    return name.hasPrefix("utun")
}

// MARK: - Exit-identity parsing (both IP and country, never just country)

private func validatedCountryCode(_ raw: String?) -> String? {
    guard let code = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
          code.count == 2,
          code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) })
    else { return nil }
    return code
}

private func validatedExitIP(_ raw: String?) -> String? {
    guard let ip = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty else { return nil }
    return ip
}

private func countryName(for code: String) -> String {
    Locale.current.localizedString(forRegionCode: code) ?? code
}

/// Parses `https://am.i.mullvad.net/json` (`{"ip": ..., "country": "<name>", ...}`).
/// The country arrives as a full English name ("Germany"), mapped to an ISO
/// code exactly like the existing resolver does.
func protonProbeFromMullvadJSON(_ data: Data) -> ProtonExitProbe? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ip = validatedExitIP(object["ip"] as? String),
          let countryNameRaw = object["country"] as? String
    else { return nil }
    let english = Locale(identifier: "en_US")
    guard let code = Locale.Region.isoRegions.first(where: {
        english.localizedString(forRegionCode: $0.identifier)?.caseInsensitiveCompare(countryNameRaw) == .orderedSame
    })?.identifier,
          let validCode = validatedCountryCode(code)
    else { return nil }
    return ProtonExitProbe(ip: ip, countryCode: validCode, countryName: countryName(for: validCode))
}

/// Parses `https://ipinfo.io/json` (`{"ip": ..., "country": "<code>", ...}`).
func protonProbeFromIPInfoJSON(_ data: Data) -> ProtonExitProbe? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ip = validatedExitIP(object["ip"] as? String),
          let code = validatedCountryCode(object["country"] as? String)
    else { return nil }
    return ProtonExitProbe(ip: ip, countryCode: code, countryName: countryName(for: code))
}

/// Parses a lookup body based on which endpoint produced it. Returns nil
/// unless BOTH a usable exit IP and a valid country code are present.
func protonProbe(from data: Data, url: URL) -> ProtonExitProbe? {
    if url.host == "am.i.mullvad.net" {
        return protonProbeFromMullvadJSON(data)
    }
    return protonProbeFromIPInfoJSON(data)
}

// MARK: - Sneak-peek gating
//
// While connected, a scheduled sneak peek must wait until the exit country
// resolved so the presentation always includes provider logo + country +
// flag together. Disconnected states have no country and are never held, so
// disconnect peeks stay instant. Pure and unit-tested.

/// True while a scheduled peek must keep waiting for the exit country.
func shouldHoldPeekForCountry(connected: Bool, countryCode: String) -> Bool {
    connected && countryCode.isEmpty
}

// MARK: - ProtonExitResolver
//
// Dedicated Proton-only resolver. The main loop drives it with the same
// request/takeResult shape as the NordVPN resolver, but internally each
// request performs TWO exit-identity fetches separated by
// `protonExitProbeGapSec`, with a utun route check before, between, and
// after. Only a stable pair is published; anything else completes as an
// empty-country result so the main loop retries on its normal cadence.
// Results are tagged with the requesting generation; the main loop additionally
// requires `result.generation == currentGeneration` before accepting.

final class ProtonExitResolver {
    private let lock = NSLock()
    private let session: URLSession
    private var inFlight = false
    private var pending: ProtonExitIdentity?

    private let probeGap: TimeInterval
    private let ipv4RouteCheck: () -> String?
    private let hostRouteCheck: (String) -> String?
    private let logger: (String) -> Void

    init(
        probeGap: TimeInterval = protonExitProbeGapSec,
        session: URLSession = URLSession(configuration: .ephemeral),
        ipv4RouteCheck: @escaping () -> String? = ProtonExitResolver.defaultIPv4Route,
        hostRouteCheck: @escaping (String) -> String? = { routeInterfaceForHost($0) },
        logger: @escaping (String) -> Void = { _ in }
    ) {
        self.probeGap = probeGap
        self.session = session
        self.ipv4RouteCheck = ipv4RouteCheck
        self.hostRouteCheck = hostRouteCheck
        self.logger = logger
    }

    static func defaultIPv4Route() -> String? {
        let (data, status) = runProcess("/sbin/route", arguments: ["-n", "get", "1.1.1.1"], timeout: 1)
        guard status == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        let name = parseRouteInterface(from: output)
        return isTunnelInterface(name) ? name : nil
    }

    /// Starts a stabilized two-probe lookup. Returns false when one is already
    /// in flight (the main loop then simply waits for its result).
    @discardableResult
    func request(
        generation: UInt64,
        fetchIdentity: ((@escaping (ProtonExitProbe?) -> Void) -> Void)? = nil
    ) -> Bool {
        lock.lock()
        guard !inFlight else {
            lock.unlock()
            return false
        }
        inFlight = true
        lock.unlock()

        // NOTE: the public exit IP is intentionally never logged.
        logger("proton exit probe started generation=\(generation)")
        let fetch = fetchIdentity ?? self.fetchExitIdentity
        let routeBefore = ipv4RouteCheck()
        guard routeBefore != nil else {
            logger("proton route unavailable at probe start; retrying")
            finish(nil, generation: generation)
            return true
        }
        fetch { [weak self] first in
            guard let self else { return }
            let gap = self.probeGap
            DispatchQueue.global().asyncAfter(deadline: .now() + gap) { [weak self] in
                guard let self else { return }
                let routeBetween = self.ipv4RouteCheck()
                fetch { [weak self] second in
                    guard let self else { return }
                    let routeAfter = self.ipv4RouteCheck()
                    self.complete(
                        first: first,
                        second: second,
                        routeBefore: routeBefore,
                        routeBetween: routeBetween,
                        routeAfter: routeAfter,
                        generation: generation
                    )
                }
            }
        }
        return true
    }

    func takeResult() -> ProtonExitIdentity? {
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending = nil
        return result
    }

    private func complete(
        first: ProtonExitProbe?,
        second: ProtonExitProbe?,
        routeBefore: String?,
        routeBetween: String?,
        routeAfter: String?,
        generation: UInt64
    ) {
        // Generation authority stays with the main loop: every result is tagged
        // with its requesting generation and only accepted when
        // `result.generation == currentGeneration` on take (stale pairs are
        // logged and discarded there). Here, filter route stability and
        // probe agreement only. Route checks already fail when the tunnel is
        // gone, so a disconnect mid-flight ends in `routeRetry` and its
        // tagged result is then discarded as stale.
        let verdict = evaluateProtonExit(
            first: first,
            second: second,
            routeBefore: routeBefore,
            routeBetween: routeBetween,
            routeAfter: routeAfter,
            generation: generation,
            currentGeneration: generation,
            connected: true
        )
        switch verdict {
        case .accept:
            let probe = second!
            // Consistency with the validated route: the observed exit IP must
            // itself route through a utun interface, guarding against a lookup
            // that escaped over another path (e.g. IPv6 vs IPv4 mismatch).
            // NOTE: never log the IP itself.
            if !isTunnelInterface(hostRouteCheck(probe.ip)) {
                logger("proton exit route mismatch; discarded")
                finish(nil, generation: generation)
                return
            }
            logger("proton exit stable country=\(probe.countryCode)")
            finish(
                ProtonExitIdentity(
                    ip: probe.ip,
                    countryCode: probe.countryCode,
                    countryName: probe.countryName,
                    generation: generation
                ),
                generation: generation
            )
        case .unstableRetry:
            logger("proton exit unstable; retrying")
            finish(nil, generation: generation)
        case .routeRetry:
            logger("proton route changed during lookup; discarded")
            finish(nil, generation: generation)
        case .staleDiscard:
            logger("stale exit lookup discarded generation=\(generation)")
            finish(nil, generation: generation)
        case .disconnectedDiscard:
            finish(nil, generation: generation)
        }
    }

    private func finish(_ result: ProtonExitIdentity?, generation: UInt64) {
        lock.lock()
        pending = result ?? ProtonExitIdentity(ip: "", countryCode: "", countryName: "", generation: generation)
        inFlight = false
        lock.unlock()
    }

    /// Fetches one (IP + country) exit observation, preferring the Mullvad
    /// connection check (which reports both) with an ipinfo JSON fallback.
    private func fetchExitIdentity(completion: @escaping (ProtonExitProbe?) -> Void) {
        fetchEndpoint(at: 0, completion: completion)
    }

    private func fetchEndpoint(at index: Int, completion: @escaping (ProtonExitProbe?) -> Void) {
        let endpoints = [
            "https://am.i.mullvad.net/json",
            "https://ipinfo.io/json"
        ]
        guard index < endpoints.count, let url = URL(string: endpoints[index]) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(protonExitUserAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, _ in
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let data,
               let probe = protonProbe(from: data, url: url) {
                completion(probe)
                return
            }
            self?.fetchEndpoint(at: index + 1, completion: completion)
        }.resume()
    }
}
