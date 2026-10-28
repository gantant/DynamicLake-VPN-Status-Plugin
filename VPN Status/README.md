# VPN Status Plugin for DynamicLake

## Overview
A DynamicLake JSON plugin that displays VPN connection status in the MacBook notch. Status is fully event-driven: every transition arrives as a notification from macOS, a frame from DynamicLake, or a deadline the plugin scheduled itself, and it sits in the run loop in between. It does not poll for anything and does not spawn a single subprocess — VPN state comes from NetworkExtension, routing from the kernel's own routing table, both read in process.

## Features
- Detects the provider and shows the matching logo for NordVPN and ProtonVPN; other VPNs (including proxy-only apps like X-VPN) are still reported, with a generic shield and their own name
- Event-driven status: watches tunnels through macOS's NetworkExtension framework, so connect, disconnect, and server-switch transitions reach the notch in milliseconds. Between events the plugin is parked in the main run loop: measured idle CPU is 0.02 s over 10 seconds, and a 10-second sample of a running plugin adds 10 ms.
- No subprocesses at all. The plugin used to spawn `scutil --nc list`, `scutil --nc status` and `route -n get` on a timer (about 43,000 launches a day on an idle machine); all three are gone, and the built binary contains no path to any of them.
- VPNs that install their own tunnel are detected too: the WireGuard app and root-helper clients such as X-VPN create a `utun`, take the default route and register nothing with NetworkExtension, so the routing table is the only place they show up. The answer comes from the kernel in process, two ways: a UDP socket connected to a public address sends no packet, but the kernel resolves the route and binds the source address it would use, which maps to the interface actually carrying traffic (about 30 µs); and for a tunnel that carries no address at all (`X-VPN`'s idle utun reports no `inet` line) the default routes are read straight from the kernel's table with `sysctl(NET_RT_DUMP)`. Scoped per-interface defaults — the ones macOS installs for its own `utun0`/`utun1`/`utun2` — are filtered out, or a machine with no VPN would report one. A tunnel with an NE configuration is named by that configuration; one without is shown as **VPN**, because a process scan cannot tell which app owns a `utun` — clients keep their helpers running while disconnected, so that approach named whichever brand happened to be installed (X-VPN's idle helper once named a Hotspot Shield connection).
- Proxy-only VPNs are detected too. Some apps (X-VPN, for one) ship no tunnel at all and instead route traffic through a NetworkExtension **transparent proxy**, so they never own a route. `NETransparentProxyManager` is an `NEVPNManager` subclass, so those configurations are enumerated at startup and their status arrives through the same `NEVPNStatusDidChange` event as a tunnel — still event-driven, still no polling. A proxy that belongs to a tunnel provider (Proton's split tunnelling) is deliberately *not* reported as a connection, because it can be enabled while the tunnel is down; only an app whose proxy is its whole VPN is shown, under its own name with the generic logo.
- Banner announcements: connect, disconnect, and server switches present at notification priority so the Sneak Peek pops, then settle back into the extra live activity row
- Status indicator in the notch (persistent mode) or brief self-dismissing notifications (notify mode)
- A **lake**: open the plugin's full view from the live activity, the notch click menus, or DynaGlance for provider, connection state, exit country and a session timer (DynamicLake's own `timer` component, so the host keeps it running), laid out on a notification-sized card whose logo opens the provider app
- A **DynaGlance button**, shown only while the plugin has a live activity, so the status is reachable while another activity owns the notch
- Provider logos and the country flag register once as image assets instead of being re-sent inline on every update
- Country is resolved asynchronously from the actual VPN exit through two HTTPS-only, no-key fallbacks (`ipinfo.io` and Mullvad's connection check). A route guard prevents lookups during tunnel transitions; a transparent proxy is exempt from it, because it installs no route at all and its own connection is the evidence that it is up. No public IP address is stored or logged. ProtonVPN goes through the stricter stabilized lookup (two agreeing probes under a route that holds still), which is what keeps its flags right across server switches. NordVPN's selected location comes from the server identity first — hostname label, or station-IP match against a hardcoded table of virtual-location pools — which is what keeps virtual locations (e.g. Armenia) showing the picked flag instead of the physical host country; the geo lookup is the fallback.
- Smaller 4:3 flag artwork is centered inside a transparent square canvas before being sent through DynamicLake's inline PNG image path. DynamicLake can keep its square image slot while rectangular flags retain their natural visible shape and spacing. It uses no emoji glyph and makes no network request for artwork; an emoji is used only as a last-resort fallback if the local asset cannot be read.
- Self-healing connection: if DynamicLake's socket closes, the plugin reconnects (once a second, short and bounded) and repaints the card and artwork when it succeeds; if the host has really gone it exits within ten seconds so DynamicLake can relaunch it. Only one instance can serve a socket — a second one exits immediately instead of fighting the first over the same activity.
- Sleep-aware: the plugin watches macOS sleep/wake directly, re-enumerates the tunnels and re-verifies the route the moment the Mac wakes, so a VPN that died during sleep leaves the notch right away

## Requirements
- macOS with DynamicLake or DynamicLake Playground
- macOS 14.0 or later (Apple Silicon or Intel)
- The lake and DynaGlance need a DynamicLake build that advertises the `lake`, `lakeLayout` and `imageAssets` features; older builds keep the unchanged live activity and sneak peek behavior

## Installation
### 1. Install via DynamicLake
Download the zip and open in DynamicLake Pro

### 2. Manual Installation
1. Ensure the executable is runnable:
```bash
chmod +x VPNStatus.dynamiclakeplugin/vpn-status
```
2. Open DynamicLake Playground Settings > Plugins > Install Local
3. Select the `VPNStatus.dynamiclakeplugin` folder

## Plugin Structure
```
VPNStatus.dynamiclakeplugin/
├── plugin.json           # Plugin manifest
├── vpn-status            # Universal binary (arm64 + x86_64, macOS 14.0+)
└── icon.png              # Plugin icon (512x512 PNG)
```

## Development
### Build from Source
```bash
./src/build.sh
```
Compiles both architectures (frameworks included), merges the universal binary with `lipo`, ad-hoc signs the result so **both** slices carry a signature (lipo alone left the Intel half unsigned), verifies each slice, and repackages `VPNStatus.dynamiclakeplugin.zip`.

### Tests

```bash
./tests/run.sh
```

Seven suites, no network access required: a runtime test that drives the real binary over the framed socket and pins the announcement contract (high-priority create, low-priority demote), the lake command and `lakeOpened` refresh, asset registration ordering, and the no-lake failover for older DynamicLake builds; a flag-badge smoke test against the bundled artwork; ProtonVPN exit-country stabilization; NordVPN server/virtual-location resolution; NetworkExtension status mapping; the routing answer (the in-process probe and the kernel table are checked against `netstat`, including that scoped IPv6 defaults are never counted); and the country labels both surfaces can show.

## Lake And DynaGlance

The lake is a single notification-sized card (`"size": "notification"` — 390 × 80 at the base size DynamicLake documents, growing a little on wider notches and higher-resolution displays), opened from the plugin's live activity, from DynamicLake's Left Click Lake / Right Click Lake / On Hover Behavior menus, or from the DynaGlance button:

- Layout: DynamicLake's built-in header row is hidden and the card is laid out by hand as a single row, which is what the notification size is sized for — the provider logo (34 points), the provider name in the card's larger text style over one line of state, then a trailing column with the session timer above the exit-country flag (32 points). The state line is `Connected · <country>`, and the country is capped at 14 characters: the full CLDR name ("United Arab Emirates" is 20) overruns the column the logo and timer leave, so long names are shown in their short form (`UAE`, `Dom. Rep.`, `Bosnia`) or, failing that, as the ISO code — a text component has no width or truncation control in the API, so the only lever is the string itself. The flag is sent inline (a 64×64 PNG of about 2 KB) rather than as a registered asset: header-slot asset references rendered nothing. There is no button row and nothing drawn on the card at all: the logo carries the open action itself (an `actionID` on the image), so nothing competes with the status row for the card's height.
- Vertical placement: the card is 80 points tall while the row is about 51 — the trailing column, not the two text lines, is the tallest thing in it — so the row is dropped into the card with a fixed 14-point spacer above it (`(80 − 51) / 2 ≈ 15`, a point under that so slightly more air stays below the row than above). With `hideHeader`, content starts at the top of the card, so without that spacer the row sat on the top edge with a dead band under it. It is a fixed spacer rather than a bare one: a `spacer` with no `length` renders nothing (measured on the built plugin — the row did not move), and `padding` is not sent at all, because its `top` edge is newer than the builds whose validator rejects the field outright, which would cost the whole lake command and leave DynamicLake's fallback card. The body stack keeps `spacing: 0`, or its own gap is added to the spacer. Text sizes are the host's and cannot grow: `compact`, `plain` and `large` are all DynamicLake offers, the name already uses `large`, and `large` on the state line would truncate long country names at the card's width — so what fills the card is the artwork and the trailing column.
- **Tapping the logo** opens the ProtonVPN or NordVPN app the card is describing. An image accepts an `actionID`, which makes the artwork itself tappable — the one way to get a left click with nothing drawn, since a `button` always comes with chrome: `plain` draws an opaque disc when it has no symbol (a zero-width title does not suppress it), draws whatever symbol it is given, and behind the artwork it does not reliably receive the press. The image's `title` is only the tooltip. The action is absent unless LaunchServices resolves that provider's bundle identifier, so a relocated, renamed (e.g. `NordVPN 2.app`) or App Store install works and a provider whose app is missing gets no dead control. Not every host build knows the field — DynamicLake Playground 1.2 rejects it with `Unknown field 'actionID'`, which would leave the fallback card up — so the first such rejection is caught: the plugin repaints once with the action moved to the logo's right-click menu (`contextMenu`) and stays there for the rest of the process. The press resolves against the provider the visible card was built for, not the last status read, so a disconnect racing the click cannot open the wrong app.
- The session timer is **DynamicLake's own `timer` component**, in the trailing column above the flag, counting up from the connection's start date — so the host ticks it and the plugin never patches the card to keep it moving. It is the host's format, which is the price of a live timer, and it only appears when NetworkExtension reports an exact connection start date; a tunnel with no such session (a routed tunnel) shows none rather than an estimate. `timer` requires an `endDate` and stops counting there, so the card arms a 24-hour window and re-sends it hours before that window ends — one lake command per window roll, never a poll. The state line beside it is secondary text (`plain` + `tint: "gray"`; DynamicLake has no dedicated secondary style) and no longer carries the clock at all, which is what keeps a long session from clipping it. Not every host build knows the component, and its validator rejects anything it does not know — the same way it turns down the image action — which would cost the whole card; so the first rejection drops the timer for the rest of the process and repaints, leaving state and country with no clock rather than DynamicLake's fallback card.
- DynaGlance gets its own design, and it is the header row DynamicLake already lays out for that area rather than a hand-built one: the provider logo in `leftSlot` (shown large, like an app icon), the provider name in `title` (bold), the state line in `subtitle` (gray) and the exit-country flag in `rightSlot`. The glance's line is the lake's state line with a tighter country budget — 10 characters, so `Connected · CH` where the lake reads `Connected · Switzerland` — because its header row is a fraction of the card's width and that is where the country was clipping. The state word is identical on both surfaces. Those fields exist for exactly this and DynamicLake sizes and insets them for the space the glance has, which a hidden header plus a content stack of 24-point artwork and `compact` text did not — it rendered a fraction of the area. The artwork is inline even when the `asset` command is available, since a header slot is the one place an asset reference has rendered nothing. It carried the session clock for a while and was clipped there, which is what settled the clock into the lake's trailing column instead, and it carried a long country name until that clipped too. Nothing on the glance is patched. Its pill button is still temporary: it appears only while the plugin has a live activity.

**Timer cost:** nothing per second. The timer is DynamicLake's own component, so the plugin sends no `lakePatch` at all — the card is only re-sent when something actually changes, plus one resend per 24-hour window roll to keep it armed. There is no status poll to speak of: the card is rebuilt when a status source fires, when DynamicLake sends a frame, or when a scheduled deadline comes due, and the plugin is asleep in the run loop otherwise. DynamicLake's frames are read the instant they arrive, and the last card is resent the moment `lakeOpened` is read, so opening the lake redraws it in milliseconds even if an exit-country lookup is still in flight.

Everything lake-related is feature-gated. On a DynamicLake build that does not advertise `lake`, `lakeLayout`, or `imageAssets`, the plugin sends no lake or asset frames and behaves exactly as 1.2.1 did — including inline artwork. The `lake` and `glance` keys stay in `plugin.json` because a manifest cannot be conditional. The lake size lives in the manifest too, so changing it requires reinstalling the plugin rather than restarting it.

## Settings
- `notifyOnChange` (switch, default off): **OFF (default):** a persistent small live activity stays in the notch while connected. A Sneak Peek is actively presented at notification priority on every connection, disconnection, and server/country change, then the capsule settles back into the extra live activity row; after disconnect the capsule remains visible for about four seconds before dismissal. **ON:** no persistent activity; the same banner-style notifications appear on changes and dismiss themselves after about four seconds. To test: enable it, then connect or disconnect your VPN.
- `persistOnDisconnect` (switch, default off, persistent mode only): when enabled, the live activity stays in the notch even while the VPN is off (shows a red disconnected icon). When disabled, turning the VPN off dismisses the activity.
- The automatic peek (`presentSneakPeek`) only fires when DynamicLake advertises the `presentSneakPeek` protocol feature (see `DYNAMICLAKE_PLUGIN_FEATURES` in the startup log); otherwise the same update is sent without the field and the peek simply shows on hover instead.
- Debug events (startup, transitions, announcements, send errors, fallback contradictions, and the transparent-proxy configuration set whenever it changes) are written to `~/Library/Logs/vpn-status.log`. Set `DYNAMICLAKE_PLUGIN_LOG_PATH` to send them somewhere else; the test suite does exactly that so its own traffic never lands in your log.

## Identifier
`com.nebulark.vpn-status`

## Authors
- **gantant** ([@gantant](https://github.com/gantant)) — original plugin and ongoing development
- **Rafael Reverberi** ([@rafaelreverberi](https://github.com/rafaelreverberi)) — ProtonVPN exit-country stabilization (1.1.6) and bundled flag artwork

## Version
1.4.0

## Changelog
Only the latest release is listed in full; the complete history lives in [CHANGELOG.md](CHANGELOG.md).
- **1.4.0** — No polling and no subprocesses left anywhere in the plugin. `scutil --nc list`/`--nc status` and every `route -n get` are gone: VPN state comes from NetworkExtension events, the routing answer from the kernel's table read in process with `sysctl`, and the plugin itself is a main-queue state machine that sleeps in the run loop between events. Idle CPU measured at 0.02 s over 10 seconds; the built binary contains no path to `scutil`, `route`, `ifconfig`, `netstat` or `posix_spawn`. Alongside it: a second instance of the plugin now exits instead of fighting the first for the same activity, both binary slices are ad-hoc signed after `lipo` (the Intel half used to ship unsigned), the log is created `0600` and cannot be forged with newlines from host error text, a rejected `response` frame now also triggers the timer fallback, the disconnected card never names a configured tunnel that carried no session, and the Proton verdict lost two cases that no caller could reach.
- **1.3.7** — Long exit-country names no longer clip: the state line's country is capped (14 characters on the lake, 10 in the glance, which is far narrower), with short forms for the names that need them — `Connected · UAE` instead of `Connected · United Arab Emirates` — and the ISO code as the last resort. A text component has no width or truncation control in the API, so the string is the only lever.
- **1.3.6** — The session timer is DynamicLake's own `timer` component instead of plugin-rendered text: the host ticks it, so it is no longer clipped as it grows and the card is never patched once a second. `timer` needs an `endDate` and stops there, so the card arms a 24-hour window and re-sends it hours before it ends — one lake command per window roll. The timer sits above the flag in a trailing column, the logo and flag are larger, and the row's clearance is recentred for that (14 points).
- **1.3.5** — The row sits in the card instead of on its top edge: a fixed 20-point spacer above it (`hideHeader` starts content at the top, and a `spacer` with no `length` renders nothing). DynaGlance is redesigned as the header row DynamicLake sizes for it — logo, bold name, the same gray status line, and the flag in the trailing slot — since the hand-built compact row filled a fraction of the area.
- **1.3.4** — VPNs that install their own tunnel are detected again — including root-helper clients such as X-VPN and Hotspot Shield, and proxy-only VPNs through `NETransparentProxyManager` and the same status events as a tunnel. The interface carrying traffic is resolved in-process (a UDP socket plus `getifaddrs`, ~60 µs, no subprocess and no timer), so detection and disconnect both land within a second or two. Unnamed routed tunnels read as **VPN** rather than borrowing a running app's name, and the disconnected card names the provider that was actually connected.
- **1.3.3** — Hardening: the flag's size is only set on image slots (an unreadable flag could otherwise reject the whole lake command), the settings file is parsed only when it changes, the Proton user agent follows the plugin's own, the log path is overridable so tests never write into your log, and a test pins the version string to the manifest.
- **1.3.2** — Tapping the logo opens the provider app (an image `actionID`, no drawn control), with a one-time fallback to the logo's right-click menu on DynamicLake builds that reject that field.
- **1.3.1** — The lake is notification sized (390 × 80, declared with `"size": "notification"` in `plugin.json`) and the Open provider app button is gone; right-clicking the logo opens the app instead. The card is one row — provider logo, provider name over a secondary state line that now carries the session clock (`Connected · Romania · 5:07`), and a bigger 30-point flag — with a 1-point clearance spacer so the notch no longer clips it. Reinstalling the plugin is required for the manifest size change.
- **1.3.0** — Built for the new DynamicLake plugin API. The plugin now has a lake: a small status card with the provider, connection state, exit country, a live session timer and an Open provider app button, plus a compact design for DynaGlance and a temporary DynaGlance button that appears only while a VPN is active. Provider logos and flags are registered as image assets once per connection instead of being re-sent inline, and the protocol now handles `lakeOpened` and button `action` frames. Everything is feature-gated: older DynamicLake builds get the unchanged 1.2.1 behavior. See [CHANGELOG.md](CHANGELOG.md) for the full history.

## Notes
- One action, on the lake's logo: tap it to open the provider app. Status itself lives in the live activity; a sneak peek shows status text / server flag
- Universal binary supports both Apple Silicon (arm64) and Intel (x86_64) Macs, macOS 14.0+
- Package size is well under the 7MB/20MB limits
- Icon is 512x512 PNG (within 1.5MB limit)
- Bounded, size-capped event logging to `~/Library/Logs/vpn-status.log`: consecutive identical events collapse into one line with a repeat count, and the file rotates (keeping the most recent 64KB) at 256KB, so it can never grow unbounded
- No sudo/Python code required
- No subprocesses at all: no `scutil`, `route`, `netstat`, `ifconfig` or `networksetup`. The only outbound requests are the HTTPS exit-country lookups described above. The log is created `0600`, and host-supplied error text is flattened onto one line so it cannot forge log entries
- No polling: status sources are notifications, the socket and event pipe are read sources on the main queue, and the only timers are one-shot deadlines for the peek, the demote, the notification's self-dismissal, a bounded country retry and the session timer's window roll

## Flag Artwork

Country flag artwork is derived from [flag-icons](https://github.com/lipis/flag-icons) and included under its MIT license in `src/flags/LICENSE-flag-icons.txt`.
