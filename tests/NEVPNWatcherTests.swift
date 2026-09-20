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
    }

    // MARK: - Health gating contract

    // Healthy by default, and markUnhealthy() must suppress answers until the
    // epoch expires (the plugin relies on this to hand control to scutil).
    static func testHealthGating() {
        expect(NEVPNWatcher.isHealthy(), "watcher starts healthy")
        NEVPNWatcher.markUnhealthy(seconds: 60)
        expect(!NEVPNWatcher.isHealthy(), "markUnhealthy suppresses answers")
        expect(NEVPNWatcher.bestStatus(target: .nord) == nil, "bestStatus returns nil while unhealthy")
        NEVPNWatcher.markUnhealthy(seconds: 0)
        expect(NEVPNWatcher.isHealthy(), "expired epoch heals")

        // bestStatus with no tunnels loaded must be nil even when healthy
        // (never fabricate a state that would bypass the scutil fallback).
        expect(NEVPNWatcher.bestStatus(target: .nord) == nil, "no tunnels loaded -> nil, never fabricated state")
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
