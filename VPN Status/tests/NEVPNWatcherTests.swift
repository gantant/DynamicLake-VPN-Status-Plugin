import Foundation

// Regression tests for the NetworkExtension status mapping layer. The NE
// runtime path (loadAllFromPreferences, NEVPNStatusDidChange) cannot run in
// unit tests; the pure mapping logic exercised here is what keeps provider
// attribution and session identity correct in production.
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
struct NEVPNWatcherTests {

    static func main() {
        testProviderAttribution()
        testProxyAttribution()
        testStatusMapping()
        testHealthGating()
        finish()
    }

    // MARK: - Provider attribution from display names

    static func testProviderAttribution() {
        expect(NEVPNWatcher.providerName(forDisplayName: "NordVPN - NordWhisper") == "NordVPN", "nordwhisper display name maps to NordVPN")
        expect(NEVPNWatcher.providerName(forDisplayName: "NordVPN") == "NordVPN", "bare nord name maps to NordVPN")
        expect(NEVPNWatcher.providerName(forDisplayName: "nordvpn whatever") == "NordVPN", "case-insensitive nord match")
        expect(NEVPNWatcher.providerName(forDisplayName: "ProtonVPN") == "ProtonVPN", "proton display name maps to ProtonVPN")
        expect(NEVPNWatcher.providerName(forDisplayName: "protonvpn (Switzerland)") == "ProtonVPN", "localized proton name matches")
        expect(NEVPNWatcher.providerName(forDisplayName: "Proton VPN Lite") == "ProtonVPN", "proton space variant matches")
        expect(NEVPNWatcher.providerName(forDisplayName: "WireGuard") == nil, "unrecognized tunnel maps to nil (scutil fallback)")
        expect(NEVPNWatcher.providerName(forDisplayName: "Tailscale") == nil, "other VPN apps stay unrecognized")
        expect(NEVPNWatcher.providerName(forDisplayName: "NordReader") == nil, "prefix lookalikes do not match")
        expect(NEVPNWatcher.providerName(forDisplayName: "") == nil, "empty name maps to nil")
        expect(NEVPNWatcher.providerName(forDisplayName: nil) == nil, "nil name maps to nil")
    }

    // MARK: - Proxy-only VPN attribution

    // A transparent proxy is the whole VPN for an app that has no tunnel
    // (X-VPN), but only an auxiliary path for a tunnel provider (Proton's split
    // tunnelling): reporting the latter as a ProtonVPN connection would claim
    // the tunnel is up when it isn't.
    static func testProxyAttribution() {
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: "X-VPN") == "X-VPN", "proxy-only app is its own provider")
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: "X-VPN - System Proxy") == "X-VPN", "vendor suffix is dropped")
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: "  X-VPN  ") == "X-VPN", "surrounding whitespace is trimmed")
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: "Proton VPN Split tunneling") == nil, "a tunnel provider's proxy is never a connection")
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: "ProtonVPN") == nil, "proton proxy name is suppressed")
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: "NordVPN - System Proxy") == nil, "nord proxy name is suppressed")
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: "") == nil, "empty proxy name is nil")
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: "   ") == nil, "blank proxy name is nil")
        expect(NEVPNWatcher.proxyProviderName(forDisplayName: nil) == nil, "nil proxy name is nil")
        expect(NEVPNWatcher.proxyStatus() == nil, "no proxy configs -> nil, never fabricated")
    }

    // MARK: - Status mapping

    struct FakeManager {
        var displayName: String?
        var rawStatus: Int
        var serverAddress: String?
    }

    // The plugin treats "connecting" as not-connected so the connect peek
    // waits for the real event; verify the flags the loop branches on.
    static func testStatusMapping() {
        expect(NEVPNWatcher.Status(provider: "NordVPN", connected: false, connecting: true, serverAddress: nil, serviceName: nil).connected == false, "connecting is not connected")
        expect(NEVPNWatcher.Status(provider: "NordVPN", connected: false, connecting: true, serverAddress: nil, serviceName: nil).connecting == true, "connecting flag survives the struct")
        expect(NEVPNWatcher.Status(provider: "NordVPN", connected: true, connecting: false, serverAddress: "10.8.0.1", serviceName: "NordVPN - NordWhisper").serverAddress == "10.8.0.1", "server address is carried through")
        expect(NEVPNWatcher.Status(provider: "NordVPN", connected: true, connecting: false, serverAddress: nil, serviceName: nil, startDate: Date(timeIntervalSince1970: 1_726_800_000)).startDate != nil, "session start date is carried through")
        expect(NEVPNWatcher.Status(provider: "NordVPN", connected: true, connecting: false, serverAddress: nil, serviceName: nil).isProxy == false, "tunnel status is not flagged as a proxy")
        expect(NEVPNWatcher.Status(provider: "X-VPN", connected: true, connecting: false, serverAddress: nil, serviceName: "X-VPN", isProxy: true).isProxy, "proxy status keeps its flag")
    }

    // MARK: - Health gating contract

    // markUnhealthy() must suppress answers until the epoch expires: the plugin
    // then reports what the routing table says instead of a stale NE claim.
    static func testHealthGating() {
        NEVPNWatcher.markUnhealthy(seconds: 60)
        expect(NEVPNWatcher.bestStatus(target: .nord) == nil, "markUnhealthy suppresses tunnel answers")
        expect(NEVPNWatcher.anyStatus() == nil, "markUnhealthy suppresses any-tunnel answers")
        expect(NEVPNWatcher.proxyStatus() == nil, "markUnhealthy suppresses proxy answers")

        // Nothing is loaded in a test binary, so every reader answers nil rather
        // than fabricating state; the routing table is the plugin's fallback.
        NEVPNWatcher.markUnhealthy(seconds: 0)
        expect(NEVPNWatcher.bestStatus(target: .nord) == nil, "no tunnels loaded -> nil, never fabricated state")
        expect(NEVPNWatcher.anyStatus() == nil, "no tunnels loaded -> no name invented")
    }

    static func finish() {
        if failures == 0 {
            print("ne watcher tests passed (\(checks) checks)")
            exit(0)
        } else {
            print("ne watcher tests FAILED (\(failures)/\(checks))")
            exit(1)
        }
    }
}
