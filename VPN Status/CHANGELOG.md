# Changelog

All notable changes to the VPN Status plugin. The latest release is also summarized in the [README](README.md).

## 1.4.0

No polling and no subprocesses. The plugin used to spawn `scutil --nc list` (plus `--nc status` while connected) on every tick — about 43,000 launches a day on an idle machine — and `route -n get` for every routing question, up to four spawns per Proton probe. Both are gone, and so is the loop that drove them: the plugin is now a main-queue state machine that renders when a status source fires, when DynamicLake sends a frame, or when one of its own one-shot deadlines comes due, and otherwise sleeps in the run loop.

Status comes from NetworkExtension's `NEVPNStatusDidChange` events, as before, but the fallback behind it is no longer `scutil`. The routing answer is read from the kernel in process: a UDP socket connected to a public address makes the kernel resolve the route and bind the source address it would use (`getsockname` + `getifaddrs`, ~30 µs), and for a tunnel that carries no address at all the default routes are read straight from the routing table with `sysctl(NET_RT_DUMP)`. Scoped per-interface defaults — macOS installs several for its own utuns — are filtered out, or a machine with no VPN would report one. The load-time enumeration of tunnels is asynchronous now; the first card is built from the routing table and repainted when NetworkExtension answers, because a blocking wait on the main thread never gets a callback at all (measured: `dispatchMain()` only runs submitted blocks, off the main thread, and never fires a main-queue dispatch source).

Consequences worth knowing:

- **No periodic timers.** Connect confirmation, peek, demote, notification dismissal, the country retry (bounded at six attempts) and the session timer's window roll are one-shot deadlines. There is no idle cadence to back off from.
- **No provider list from `scutil`.** A tunnel with an NE configuration is named by that configuration, including providers this plugin has no mapping for (Hotspot Shield, a vendor's own WireGuard build); a tunnel without one is still reported, as **VPN**. A disconnected card now names nothing unless a session was actually observed, instead of whichever tunnel happened to be configured.
- **Idle cost.** 0.02 s of CPU over a 10-second sample of a running plugin; the binary contains no path to `scutil`, `route`, `ifconfig`, `netstat` or `posix_spawn`.
- **One instance per socket.** A second plugin process on the same socket exits immediately (`flock`), instead of answering the same activity, clobbering the first one's assets and doubling every cost.
- **Both slices are signed.** `lipo` keeps whatever each half arrived with, and `ld` only ad-hoc-signs arm64, so the Intel slice used to ship unsigned; the build now signs the fat file and verifies both architectures.
- **Log hardening.** The file is created `0600` (it names providers, countries and errors), and host-supplied error text is flattened onto one line so a newline in it cannot forge a log entry.
- **Rejected responses finish their fallbacks.** A rejected `response` frame now triggers the timer fallback as well as the image-action one.
- **Proton verdict simplified.** The two cases no caller could produce (stale generation, disconnected) are gone; the caller already compares the result's generation and the route check already fails when the tunnel is gone.

Long exit-country names no longer run off the end of the state line. `Connected · United Arab Emirates` is half again as wide as the column a notification-sized card leaves between the logo and the timer's trailing column, and the glance's header row is narrower still, so the country was being clipped on both. The name is now capped — 14 characters on the lake, 10 in the glance — with the short form people actually write (`UAE`, `Dom. Rep.`, `Bosnia`) and the ISO code as the last resort. A text component has no width, `lineLimit` or truncation field in the plugin API, so the string is the only lever; the state word and every other part of both surfaces are unchanged.

## 1.3.6

The session timer is DynamicLake's own `timer` component instead of text the plugin rendered and patched once a second. The host ticks it, so it is no longer clipped as `Connected · Romania · 5:07` outgrew its line, and the card costs no per-second traffic at all. `timer` needs an `endDate` and stops counting there, so the card arms a 24-hour window and re-sends it hours before that ends: one lake command per window roll, never a poll.

The card is filled out around it. The timer sits above the exit-country flag in a trailing column, where no text can squeeze it; the logo and flag are larger (34 and 32 points); and the row's clearance is recentred for the taller row (14 points instead of 20). Text styles are unchanged — `compact`, `plain` and `large` are all DynamicLake offers, the name already used the largest, and `large` on the state line would truncate long country names at the card's width. The glance shows the lake's own state line, which now has no clock on either surface.

A host build whose validator does not know `timer` rejects the whole lake command, so the first such rejection drops the timer for the rest of the process and repaints the card without it.

## 1.3.5

The row sits in the card instead of on its top edge. With `hideHeader` the content starts at the top of a 390 × 80 notification card while the row is about 38 points, so it read top heavy with a dead band under it; a fixed 20-point spacer drops it into place, and a `spacer` with no `length` renders nothing, so the position is a real point value.

DynaGlance is redesigned as the header row DynamicLake already sizes for that area — logo in `leftSlot`, provider in `title`, the state line in `subtitle`, flag in `rightSlot` — instead of a hidden header with a hand-built row of 24-point artwork and `compact` text, which filled a fraction of the space. The glance's line drops the session clock, which `Connected · Romania · 5:07` is too long for: it was clipped there, so the clock stays on the lake.

## 1.3.4

VPNs that install their own tunnel (X-VPN, Hotspot Shield, the WireGuard app) are detected again — the fallback had been compiled out of release builds behind a debug flag, and it asked the NWPathMonitor mirror, which keeps reporting nil after a client-installed utun takes the default route. The interface carrying traffic is now resolved in-process: a UDP socket connected to 1.1.1.1 sends nothing, but the kernel resolves the route and binds a source address, which maps to its interface with `getifaddrs` — ~60 µs a call, no subprocess, no timer. Unnamed routed tunnels read as **VPN** (the old process-name guess labelled a Hotspot Shield tunnel as X-VPN), and the disconnected card names the provider that was actually connected rather than whichever configured tunnel exists.

Proxy-only VPNs are detected too: apps that install no tunnel route through a NetworkExtension **transparent proxy**, and `NETransparentProxyManager` is an `NEVPNManager` subclass, so their status arrives through the same `NEVPNStatusDidChange` events. A proxy belonging to a tunnel provider (Proton's split tunnelling) is suppressed rather than reported as a connection.

## 1.3.3

Hardening only. `size` is limited to image slots, settings are re-parsed only when they change, Proton's user agent follows the plugin's, the log path is overridable so tests stay out of `~/Library/Logs`, and a test pins the version string to the manifest.

## 1.3.2

Tapping the logo opens the provider app through an image `actionID`. Builds that reject the field (`Unknown field 'actionID'`) get the right-click menu instead, after one automatic repaint.

## 1.3.1

Notification-sized lake (390 × 80) with no button row, the session clock folded into the status line, a 30-point flag, and a 1-point spacer so the notch stops clipping the name. Reinstalling is required for the manifest size change.

## 1.3.0

Built for the new DynamicLake plugin API, with full backward compatibility. The lake is a hand-laid single card: provider logo, name over `Connected · <country>`, the exit-country flag with a session clock beneath it, and an **Open** button across the bottom. The clock is plugin-rendered (DynamicLake's `timer` cannot drop the leading hour), patched once a second only while the lake is visible, and omitted when no exact start date is known — the scutil path shows no estimate. Padding accepts only `leading`, `bottom` and `trailing`; a `top` inset rejects the whole lake command. The provider logo is registered once as an image asset (the flag stays inline), and every surface is feature-gated, so a build without `lake`, `lakeLayout` or `imageAssets` behaves exactly as 1.2.1.

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
