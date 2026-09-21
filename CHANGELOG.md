# Changelog

All notable changes to the VPN Status plugin. The latest release is also summarized in the [README](README.md).

## 1.2.1

Event-driven checks on top of 1.2.0's event-driven core: the routing-table verification (which guards NetworkExtension's answers and drives the WireGuard fallback) now rides `NWPathMonitor` — zero subprocess spawns and instant reaction to route changes, with the classic `route -n get` lookup retained as an automatic fallback whenever the pushed view is missing or stale, and as the always-verified final word before any decision that would tear down the event source (a fresh mirror contradicted by the real route table is permanently degraded to spawn-only). The plugin now observes macOS sleep/wake via `NSWorkspace`: after waking it re-verifies the tunnel and resets the self-defense cadences immediately, so a VPN that died during sleep cannot linger on the notch; the wake signal also interrupts the wait loop for an instant re-check.

## 1.2.0

Event-driven status: the plugin now watches VPN tunnels through macOS's NetworkExtension framework instead of spawning `scutil` on every tick. Connect/disconnect transitions reach the notch in milliseconds (pushed by the system, not polled), and an idle-disconnected machine spawns essentially nothing. The proven `scutil` path remains as an automatic fallback: if NetworkExtension is unavailable, wedged, or ever disagrees with the routing table / scutil itself (checked on a slow 30–60s cadence), the plugin seamlessly returns to polling — including full support for non-NetworkExtension VPNs like the WireGuard app. Connect, disconnect, and server-switch presentations now announce at notification priority — the activity is created or promoted high-priority so the Sneak Peek presents like a banner — and an update drops it to the persistent profile once the peek finishes, so it settles into the extra live activity row as before. Server switches while connected always present a Sneak Peek announcing the new location. No settings changes otherwise.

## 1.1.9

Resource hygiene for shipping: a failed subprocess spawn no longer leaks its pipe file descriptors (all pipe closes now live in a `defer` in the shared process runner), and the poll loop backs off to 2s while disconnected (~230k → ~86k subprocess spawns/day idle), with the expensive `ifconfig -a` dump now only running when a utun interface actually owns the default route. Reconnect detection stays capped at ~2s — well under the connect peek's settle delay — so there is no visible behavior change.

## 1.1.8

Log hygiene for shipping: the log can no longer grow unbounded. `vpn-status.log` now rotates at 256KB (keeping the most recent 64KB), and consecutive identical events collapse into one line with a repeat count instead of appending per occurrence. The ProtonVPN exit resolver's routine per-probe lines (`probe started`, `exit stable country=…`) no longer log in production — they fired on every 5s re-probe while connected (~34k lines/day); anomalous diagnostics (route mismatch, unstable probe pair, stale discards) still log, and tests opt back in to the routine lines. No behavior change to status detection, peeks, or flags.

## 1.1.7

NordVPN flags now reflect the location you picked, not the physical server rack. NordVPN's virtual locations (e.g. Armenia) host their hardware in another country (e.g. Bulgaria), so the exit-IP geo lookup can only ever report the physical country there. The selected location now comes from the server identity itself: `*.nordvpn.com` server hostnames parse directly, and because NordWhisper exposes only the bare station IP as the macOS ServerAddress, Nord's virtual locations (Andorra, Armenia, Azerbaijan, Bahamas, Morocco, Vietnam) are matched against a hardcoded table of their known station-IP pools (captured from NordVPN's public catalog; extend the table as locations change). A confirmed Nord location always overrides geo and skips the geo lookup, so virtual locations show the picked flag immediately; unmatched stations keep the unchanged geo-IP fallback, and unresolved NordVPN addresses are logged only as a masked shape (never the IP). Also fixed the provider attribution behind the stale Proton flash: both provider apps keep GUI processes running while disconnected, so the routed-tunnel fallback now prefers the service scutil reports as Connecting during a handshake (the provider that actually owns the forming tunnel) instead of the first process-name match. ProtonVPN behavior untouched. Added hostname-parser, address-shape, and virtual-pool regression tests.

## 1.1.6

Fixed unreliable ProtonVPN exit-country detection without touching NordVPN behavior (frozen as the regression baseline). ProtonVPN now resolves both the public exit IP and the country via a dedicated `ProtonExitResolver` that probes twice (~0.4s apart) and only publishes the country when the same exit IP is observed in both probes under a stable `utun` route; mismatched probes (Quick Connect / server change mid-transition) are discarded and retried instead of briefly showing the old country's flag. The observed exit IP is part of the effective Proton connection identity, so server switches that keep the same service name and `utun` interface are still detected (re-probed every 5s; NordVPN keeps its 15s cadence). Exit-IP route validation is IPv4/IPv6-consistent (`-inet6` for IPv6 literals), results stay generation-tagged so stale async responses are discarded, and the public IP is never logged. The connect Sneak Peek no longer has a timeout: while connected it waits until the country resolves so it always presents logo + country + flag together (disconnect peeks stay instant). Added 60+ regression tests covering NordVPN exclusion, stable/switching/stale/route-change/disconnect cases, and IP-in-logs prevention.

## 1.1.5

Hardened the socket layer (bounded send retries, kill-escalation for hung subprocesses, socket-blip recovery on disconnect peeks) and reset surfaces signatures on mode switches so a notify→persistent toggle always rebuilds the capsule. The connect Sneak Peek now waits for the country lookup (bounded at 2.5s): the flag refresh goes first, then the peek follows as a pure presentation update on unchanged surfaces — DynamicLake ignores `presentSneakPeek` on an update that also changes surfaces, and notify mode now presents the same Sneak Peek as persistent mode (on the create itself it is ignored), with the notification held until the peek finishes. Sneak-peek surface construction deduplicated; settings-file parse failures are now logged (once).

## 1.1.4

Provider handshakes no longer flash the wrong logo (macOS can briefly report the old session as Connected while a new VPN connects); a fresh connection is only reported once it is seen twice in a row. Country/flag resolution now refreshes the notch in place instead of re-presenting the Sneak Peek a second time. Connect Sneak Peeks in persistent mode are now presented via a short-delayed update, since DynamicLake honours `presentSneakPeek` on updates only and swallows one racing the create.

## 1.1.3

Minimized side capsule (`extraLiveActivity`) now always shows the provider logo instead of the country flag; front compact view unchanged (logo + flag).

## 1.1.2

Fixed stale/wrong ProtonVPN flags after Quick Connect and reconnects; rejects Proton's idle utun interface unless public traffic is actually routed through it; detects transitions in under a second; resolves country asynchronously with a Proton-compatible HTTPS fallback; removes public IPs from logs; replaces the emoji with smaller 4:3 flag artwork centered on transparent canvases so rectangular flags are not stretched into square badges; and directly presents the same Sneak Peek on every connect, country/server, and disconnect change.

## 1.1.0

Flag now reflects the actual VPN exit country (self-lookup via ip-api), so ProtonVPN gets a flag and switching NordVPN country while connected refreshes it within ~30s without a reconnect. Mode switches (Notify on Change / Show Disconnected Status) now apply live without restarting DynamicLake.

## 1.0.9

Fixed false-positive "VPN Connected" status: macOS's always-on utun interfaces (link-local `fe80::`, loopback, `169.254.*`, ULA addresses) are no longer mistaken for an active VPN tunnel. A running NordVPN/ProtonVPN process alone no longer implies a connected VPN. Notify mode now recovers the socket connection after send failures, and DynamicLake error responses are logged to `vpn-status.log`.

## 1.0.8

Initial public release.
