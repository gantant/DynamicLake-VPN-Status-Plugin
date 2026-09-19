import Foundation

// Regression tests for the ProtonVPN stabilized exit-IP detection.
// NordVPN behavior must remain the single-shot country path: these tests pin
// that only Proton providers take the stabilization path, and that the
// stabilizer only accepts a country when the same exit IP is observed twice
// under a stable utun route and current generation.
//
// Build & run via tests/run.sh (no network access; all I/O is stubbed).

private var failures = 0

private func check(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

private func probe(_ ip: String, _ code: String, _ name: String) -> ProtonExitProbe {
    ProtonExitProbe(ip: ip, countryCode: code, countryName: name)
}

private func waitForResult(
    _ resolver: ProtonExitResolver,
    timeout: TimeInterval = 5
) -> ProtonExitIdentity? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let result = resolver.takeResult() { return result }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return nil
}

@main
private enum ProtonExitTests {
    static func main() {
        testProviderRouting()
        testPeekWaitsForCountry()
        testStableConnectionAccepted()
        testServerChangeRequiresRetry()
        testStaleGenerationDiscarded()
        testRouteTransitionDiscarded()
        testDisconnectDiscarded()
        testParsing()
        testRouteHelpers()
        testResolverStablePublishes()
        testResolverUnstableRetries()
        testResolverRouteChangeRetries()
        testResolverNeverLogsIP()
        testResolverRejectsOverlappingRequest()

        if failures == 0 {
            print("proton exit tests passed")
        } else {
            print("proton exit tests FAILED (\(failures))")
            exit(1)
        }
    }

    // MARK: - NordVPN regression protection

    static func testProviderRouting() {
        // The stabilization algorithm must apply to ProtonVPN only.
        check(usesProtonStabilizedExit(provider: "ProtonVPN"), "proton provider uses stabilization")
        check(usesProtonStabilizedExit(provider: "protonvpn"), "proton match is case-insensitive")
        check(!usesProtonStabilizedExit(provider: "NordVPN"), "nordvpn skips stabilization")
        check(!usesProtonStabilizedExit(provider: "NORDVPN"), "nordvpn skip is case-insensitive")
        check(!usesProtonStabilizedExit(provider: nil), "nil provider skips stabilization")
        check(!usesProtonStabilizedExit(provider: ""), "empty provider skips stabilization")
        check(!usesProtonStabilizedExit(provider: "VPN"), "generic provider skips stabilization")
    }

    // MARK: - Sneak-peek gating (peek only with resolved country)

    static func testPeekWaitsForCountry() {
        // Connected without a country: hold the peek, nothing correct to show yet.
        check(shouldHoldPeekForCountry(connected: true, countryCode: ""), "connect peek held until country resolves")
        // Connected with a country: present immediately with logo + flag.
        check(!shouldHoldPeekForCountry(connected: true, countryCode: "DE"), "connect peek fires with country")
        check(!shouldHoldPeekForCountry(connected: true, countryCode: "CH"), "connect peek fires with country CH")
        // Disconnects have no country and must stay instant in both modes.
        check(!shouldHoldPeekForCountry(connected: false, countryCode: ""), "disconnect peek never held")
        check(!shouldHoldPeekForCountry(connected: false, countryCode: "DE"), "disconnect peek never held with stale country")
    }

    // MARK: - Pure stabilizer verdicts

    static func testStableConnectionAccepted() {
        // IP A / CH observed twice under a stable route: accept.
        let verdict = evaluateProtonExit(
            first: probe("185.1.2.3", "CH", "Switzerland"),
            second: probe("185.1.2.3", "CH", "Switzerland"),
            routeBefore: "utun7", routeBetween: "utun7", routeAfter: "utun7",
            generation: 12, currentGeneration: 12, connected: true
        )
        check(verdict == .accept, "stable proton exit accepted")
    }

    static func testServerChangeRequiresRetry() {
        // IP A / CH then IP B / DE: transition in flight, publish nothing.
        let changing = evaluateProtonExit(
            first: probe("185.1.2.3", "CH", "Switzerland"),
            second: probe("146.4.5.6", "DE", "Germany"),
            routeBefore: "utun7", routeBetween: "utun7", routeAfter: "utun7",
            generation: 12, currentGeneration: 12, connected: true
        )
        check(changing == .unstableRetry, "changing proton exit not accepted yet")
        check(changing != .accept, "changing proton exit is not accept")

        // Same IP, disagreeing country: also unstable, never publish either.
        let splitCountry = evaluateProtonExit(
            first: probe("146.4.5.6", "CH", "Switzerland"),
            second: probe("146.4.5.6", "DE", "Germany"),
            routeBefore: "utun7", routeBetween: "utun7", routeAfter: "utun7",
            generation: 12, currentGeneration: 12, connected: true
        )
        check(splitCountry == .unstableRetry, "same ip with split country retries")

        // Once the new exit is observed twice, it is accepted.
        let settled = evaluateProtonExit(
            first: probe("146.4.5.6", "DE", "Germany"),
            second: probe("146.4.5.6", "DE", "Germany"),
            routeBefore: "utun7", routeBetween: "utun7", routeAfter: "utun7",
            generation: 12, currentGeneration: 12, connected: true
        )
        check(settled == .accept, "settled new proton exit accepted")
    }

    static func testStaleGenerationDiscarded() {
        // Generation N lookup completes after generation N+1 started.
        let verdict = evaluateProtonExit(
            first: probe("185.1.2.3", "CH", "Switzerland"),
            second: probe("185.1.2.3", "CH", "Switzerland"),
            routeBefore: "utun7", routeBetween: "utun7", routeAfter: "utun7",
            generation: 11, currentGeneration: 12, connected: true
        )
        check(verdict == .staleDiscard, "stale generation discarded")
        check(verdict != .accept, "stale generation never accepted")
    }

    static func testRouteTransitionDiscarded() {
        let gone = evaluateProtonExit(
            first: probe("185.1.2.3", "CH", "Switzerland"),
            second: probe("185.1.2.3", "CH", "Switzerland"),
            routeBefore: "utun7", routeBetween: nil, routeAfter: "utun7",
            generation: 12, currentGeneration: 12, connected: true
        )
        check(gone == .routeRetry, "vanished route discarded")

        let moved = evaluateProtonExit(
            first: probe("185.1.2.3", "CH", "Switzerland"),
            second: probe("185.1.2.3", "CH", "Switzerland"),
            routeBefore: "utun7", routeBetween: "utun8", routeAfter: "utun8",
            generation: 12, currentGeneration: 12, connected: true
        )
        check(moved == .routeRetry, "moved route discarded")

        let nonTunnel = evaluateProtonExit(
            first: probe("185.1.2.3", "CH", "Switzerland"),
            second: probe("185.1.2.3", "CH", "Switzerland"),
            routeBefore: "en0", routeBetween: "en0", routeAfter: "en0",
            generation: 12, currentGeneration: 12, connected: true
        )
        // en0 is stable across probes, so the pure route check passes; the
        // resolver additionally requires a utun interface and drops this.
        // Document the layered contract: pure verdict is accept, resolver
        // must still refuse (covered by testResolverRouteChangeRetries-style
        // host-route check with a non-tunnel stub).
        check(nonTunnel == .accept, "pure verdict ignores interface kind (resolver enforces utun)")

        let missingProbe = evaluateProtonExit(
            first: nil,
            second: probe("185.1.2.3", "CH", "Switzerland"),
            routeBefore: "utun7", routeBetween: "utun7", routeAfter: "utun7",
            generation: 12, currentGeneration: 12, connected: true
        )
        check(missingProbe == .unstableRetry, "failed probe retries")
    }

    static func testDisconnectDiscarded() {
        let verdict = evaluateProtonExit(
            first: probe("185.1.2.3", "CH", "Switzerland"),
            second: probe("185.1.2.3", "CH", "Switzerland"),
            routeBefore: "utun7", routeBetween: "utun7", routeAfter: "utun7",
            generation: 12, currentGeneration: 12, connected: false
        )
        check(verdict == .disconnectedDiscard, "disconnect discards exit probes")
        check(verdict != .accept, "disconnect never accepted")
    }

    // MARK: - Parsing (IP + country together, never country-only)

    static func testParsing() {
        let mullvad = """
        {"ip":"146.4.5.6","country":"Germany","city":"Frankfurt","mullvad_exit_ip":false}
        """.data(using: .utf8)!
        if let p = protonProbeFromMullvadJSON(mullvad) {
            check(p.ip == "146.4.5.6", "mullvad exit ip parsed")
            check(p.countryCode == "DE", "mullvad country name mapped to code")
        } else {
            check(false, "mullvad json parsed")
        }

        let ipinfo = """
        {"ip":"185.1.2.3","country":"CH","city":"Zurich"}
        """.data(using: .utf8)!
        if let p = protonProbeFromIPInfoJSON(ipinfo) {
            check(p.ip == "185.1.2.3", "ipinfo exit ip parsed")
            check(p.countryCode == "CH", "ipinfo country code parsed")
        } else {
            check(false, "ipinfo json parsed")
        }

        // Country-only bodies must NOT yield a probe: without an IP there is
        // nothing to stabilize on.
        check(protonProbeFromIPInfoJSON(Data("DE".utf8)) == nil, "country-only body rejected")
        let noIP = """
        {"country":"DE"}
        """.data(using: .utf8)!
        check(protonProbeFromIPInfoJSON(noIP) == nil, "missing ip rejected")
        let noCountry = """
        {"ip":"185.1.2.3"}
        """.data(using: .utf8)!
        check(protonProbeFromIPInfoJSON(noCountry) == nil, "missing country rejected")

        // Dispatcher picks the parser by endpoint host.
        let mullvadURL = URL(string: "https://am.i.mullvad.net/json")!
        let ipinfoURL = URL(string: "https://ipinfo.io/json")!
        check(protonProbe(from: mullvad, url: mullvadURL)?.countryCode == "DE", "mullvad endpoint dispatched")
        check(protonProbe(from: ipinfo, url: ipinfoURL)?.countryCode == "CH", "ipinfo endpoint dispatched")
    }

    // MARK: - Route helpers (IPv4/IPv6 correctness)

    static func testRouteHelpers() {
        let sample = """
        route to: 1.1.1.1
        destination: default
        interface: utun7
        flags: <UP,GATEWAY,DONE,GLOBAL>
        """
        check(parseRouteInterface(from: sample) == "utun7", "route interface parsed")
        check(parseRouteInterface(from: "no interface here\n") == nil, "missing interface is nil")
        check(isTunnelInterface("utun7"), "utun is tunnel")
        check(!isTunnelInterface("en0"), "en0 is not tunnel")
        check(!isTunnelInterface(nil), "nil is not tunnel")
        // The checked family must match the observed exit IP family.
        check(routeArguments(forHost: "146.4.5.6") == ["-n", "get", "146.4.5.6"], "ipv4 route args")
        check(routeArguments(forHost: "2a00:1::1") == ["-n", "get", "-inet6", "2a00:1::1"], "ipv6 route args")
    }

    // MARK: - Resolver integration (stubbed I/O)

    private final class LogSink {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _lines
        }
        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            _lines.append(line)
        }
    }

    private static func makeResolver(
        routes: [String?] = ["utun7"],
        hostRoute: String? = "utun7"
    ) -> (ProtonExitResolver, LogSink) {
        let sink = LogSink()
        var routeCalls = 0
        let resolver = ProtonExitResolver(
            probeGap: 0.02,
            ipv4RouteCheck: {
                defer { routeCalls += 1 }
                return routeCalls < routes.count ? routes[routeCalls] : routes.last ?? nil
            },
            hostRouteCheck: { _ in hostRoute },
            logger: { sink.append($0) }
        )
        return (resolver, sink)
    }

    static func testResolverStablePublishes() {
        let (resolver, sink) = makeResolver()
        let probes = [
            probe("146.4.5.6", "DE", "Germany"),
            probe("146.4.5.6", "DE", "Germany")
        ]
        var remaining = probes
        check(resolver.request(generation: 7) { done in done(remaining.isEmpty ? nil : remaining.removeFirst()) }, "stable request started")
        if let result = waitForResult(resolver) {
            check(result.countryCode == "DE", "stable resolver publishes country")
            check(result.countryName == "Germany", "stable resolver publishes name")
            check(result.generation == 7, "stable resolver tags generation")
            check(result.ip == "146.4.5.6", "stable resolver carries exit ip")
            check(sink.lines.contains(where: { $0.contains("proton exit stable country=DE") }), "stable resolver logs country")
        } else {
            check(false, "stable resolver produced a result")
        }
    }

    static func testResolverUnstableRetries() {
        let (resolver, sink) = makeResolver()
        var remaining = [
            probe("185.1.2.3", "CH", "Switzerland"),
            probe("146.4.5.6", "DE", "Germany")
        ]
        check(resolver.request(generation: 12) { done in done(remaining.isEmpty ? nil : remaining.removeFirst()) }, "unstable request started")
        if let result = waitForResult(resolver) {
            check(result.countryCode.isEmpty, "unstable pair publishes no country")
            check(result.generation == 12, "unstable retry keeps generation tag")
            check(sink.lines.contains(where: { $0.contains("proton exit unstable; retrying") }), "unstable resolver logs retry")
        } else {
            check(false, "unstable resolver completed")
        }
    }

    static func testResolverRouteChangeRetries() {
        // Route moves between the two probes.
        let (resolver, sink) = makeResolver(routes: ["utun7", "utun8", "utun8"])
        var remaining = [
            probe("146.4.5.6", "DE", "Germany"),
            probe("146.4.5.6", "DE", "Germany")
        ]
        check(resolver.request(generation: 3) { done in done(remaining.isEmpty ? nil : remaining.removeFirst()) }, "route-change request started")
        if let result = waitForResult(resolver) {
            check(result.countryCode.isEmpty, "route change publishes no country")
            check(sink.lines.contains(where: { $0.contains("proton route changed during lookup; discarded") }), "route change logged")
        } else {
            check(false, "route-change resolver completed")
        }

        // Exit IP whose own route is not a tunnel: lookup escaped, discard.
        let (offTunnel, sink2) = makeResolver(hostRoute: "en0")
        var remaining2 = [
            probe("146.4.5.6", "DE", "Germany"),
            probe("146.4.5.6", "DE", "Germany")
        ]
        check(offTunnel.request(generation: 4) { done in done(remaining2.isEmpty ? nil : remaining2.removeFirst()) }, "off-tunnel request started")
        if let result = waitForResult(offTunnel) {
            check(result.countryCode.isEmpty, "off-tunnel exit publishes no country")
            check(sink2.lines.contains(where: { $0.contains("proton exit route mismatch; discarded") }), "off-tunnel exit logged")
        } else {
            check(false, "off-tunnel resolver completed")
        }
    }

    static func testResolverNeverLogsIP() {
        let (resolver, sink) = makeResolver()
        var remaining = [
            probe("185.1.2.3", "CH", "Switzerland"),
            probe("146.4.5.6", "DE", "Germany")
        ]
        check(resolver.request(generation: 9) { done in done(remaining.isEmpty ? nil : remaining.removeFirst()) }, "no-ip-log request started")
        _ = waitForResult(resolver)
        let leaked = sink.lines.filter { $0.contains("185.1.2.3") || $0.contains("146.4.5.6") }
        check(leaked.isEmpty, "public exit ip never logged")
    }

    static func testResolverRejectsOverlappingRequest() {
        var held: [(ProtonExitProbe?) -> Void] = []
        let (resolver, _) = makeResolver()
        check(resolver.request(generation: 1) { done in held.append(done) }, "first request started")
        check(!resolver.request(generation: 1) { done in done(nil) }, "overlapping request refused")
        held.removeFirst()(probe("146.4.5.6", "DE", "Germany"))
        // The second probe fetch is issued after the inter-probe gap.
        let deadline = Date().addingTimeInterval(2)
        while held.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        check(!held.isEmpty, "second probe fetch issued")
        held.removeFirst()(probe("146.4.5.6", "DE", "Germany"))
        if let result = waitForResult(resolver) {
            check(result.generation == 1, "held request completes after overlap refused")
            check(result.countryCode == "DE", "held request still stabilizes")
        } else {
            check(false, "held request completed")
        }
    }
}
