# VPN Status Plugin for DynamicLake

## Overview
A DynamicLake JSON plugin that displays VPN connection status in the MacBook notch. Status is event-driven — the plugin hears about tunnel changes from macOS directly instead of polling — with automatic fallbacks to the classic polling path, a compact provider icon, a consistently rendered country-flag badge, and banner-style Sneak Peek announcements for every connection change.

## Features
- Detects the provider and shows the matching logo (NordVPN and ProtonVPN for now, more to come later)
- Event-driven status: watches tunnels through macOS's NetworkExtension framework, so connect, disconnect, and server-switch transitions reach the notch in milliseconds, and an idle-disconnected machine costs essentially nothing
- Self-defending: while the event source is active, slow cross-checks verify it against the routing table and the system's own connection list; any contradiction hands control back to polling until it proves healthy again
- The polling fallback is complete: VPNs that don't use NetworkExtension (like the WireGuard app) keep working, and routed-traffic validation avoids false "connected" states from idle tunnel interfaces
- Banner announcements: connect, disconnect, and server switches present at notification priority so the Sneak Peek pops, then settle back into the extra live activity row
- Status indicator in the notch (persistent mode) or brief self-dismissing notifications (notify mode)
- A **lake**: open the plugin's full view from the live activity, the notch click menus, or DynaGlance for provider, connection state, exit country and a session timer, laid out as one notification-sized row whose logo opens the provider app
- A **DynaGlance button**, shown only while the plugin has a live activity, so the status is reachable while another activity owns the notch
- Provider logos and the country flag register once as image assets instead of being re-sent inline on every update
- Country is resolved asynchronously from the actual VPN exit through two HTTPS-only, no-key fallbacks (`ipinfo.io` and Mullvad's connection check). A route guard prevents lookups during tunnel transitions, and no public IP address is stored or logged. ProtonVPN goes through the stricter stabilized lookup (two agreeing probes under a route that holds still), and it now gives up after three consecutive discarded pairs and falls back to the plain lookup for the rest of that connection — on a network where the route table keeps moving or the lookup endpoint answers only some of the time, the strict path could otherwise never publish, which left ProtonVPN with no country and no flag at all. NordVPN's selected location comes from the server identity first — hostname label, or station-IP match against a hardcoded table of virtual-location pools — which is what keeps virtual locations (e.g. Armenia) showing the picked flag instead of the physical host country; the geo lookup is the fallback.
- Smaller 4:3 flag artwork is centered inside a transparent square canvas before being sent through DynamicLake's inline PNG image path. DynamicLake can keep its square image slot while rectangular flags retain their natural visible shape and spacing. It uses no emoji glyph and makes no network request for artwork; an emoji is used only as a last-resort fallback if the local asset cannot be read.
- Self-healing persistent activity: re-asserts the live activity every 30s and recovers the socket connection, so the status returns on its own after sleep/wake even if DynamicLake dropped it
- Sleep-aware: the plugin watches macOS sleep/wake directly and re-verifies everything the moment the Mac wakes, so a VPN that died during sleep leaves the notch right away

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
Compiles both architectures (frameworks included), merges the universal binary with `lipo`, and repackages `VPNStatus.dynamiclakeplugin.zip`.

### Tests

```bash
./tests/run.sh
```

Six suites, no network access required: a runtime test that drives the real binary over the framed socket and pins the announcement contract (high-priority create, low-priority demote), the lake command and `lakeOpened` refresh, asset registration ordering, and the no-lake failover for older DynamicLake builds; a flag-badge smoke test against the bundled artwork; ProtonVPN exit-country stabilization (including the bounded fallback when it never publishes); NordVPN server/virtual-location resolution; NetworkExtension status mapping; and default-route tunnel detection mapping.

## Lake And DynaGlance

The lake is a single notification-sized (`"size": "notification"`, 390 × 80) card, opened from the plugin's live activity, from DynamicLake's Left Click Lake / Right Click Lake / On Hover Behavior menus, or from the DynaGlance button:

- Layout: DynamicLake's built-in header row is hidden and the card is laid out by hand as one row, which is what the notification size is sized for — the provider logo, the provider name in the card's larger text style over one line of state, and the exit-country flag at the trailing edge. The flag is sent inline (a 64×64 PNG of about 2 KB) rather than as a registered asset: header-slot asset references rendered nothing. There is no button row and nothing drawn on the card at all: right-clicking the logo offers **Open <provider>**, so nothing competes with the status row for the card's height.
- The body is lifted off the card's bottom edge with a bottom inset (none while disconnected). Component padding accepts only `leading`, `bottom` and `trailing` — any other field (a `top` inset, for one) rejects the entire lake command, and DynamicLake then shows its fallback card with just the plugin icon and title. Because there is no top inset, clearance under the notch is a fixed spacer above the row, in both states (1 point today; without it the notch clipped the top of the provider name). `length` is documented from 0 to 200, so 0 is legal — it just means no clearance — but the body stack must keep `spacing: 0`: a stack spacing is added to the spacer, and with the old 10-point spacing a 1-point spacer landed as roughly 11.
- **Right-clicking the logo** offers `Open <provider>` and opens the ProtonVPN or NordVPN app the card is describing. This is a right-click menu rather than a left-click target because DynamicLake cannot draw an invisible button: actions only come from `button` components, and a `plain` button draws an opaque disc when it has no symbol (a zero-width title does not suppress it) and draws whatever symbol it is given. A disc behind the artwork is drawn under it and, sitting behind a hit-testable image, does not reliably receive the press. Every component can carry a `contextMenu`, though, and that draws nothing until it is opened. The menu entry only exists when LaunchServices resolves that provider's bundle identifier, so a relocated, renamed (e.g. `NordVPN 2.app`) or App Store install works and a provider whose app is missing gets no dead control. The press resolves against the provider the visible card was built for, not the latest poll, so a disconnect racing the click cannot open the wrong app.
- The session clock rides the status line — `Connected · Romania · 5:07` — formatted by the plugin (`5:07` under an hour, `1:02:03` once the session has an hour), and only appears when NetworkExtension reports an exact connection start date; the scutil fallback omits it rather than showing an estimate. The line is secondary text (`plain` + `tint: "gray"`; DynamicLake has no dedicated secondary style), and the per-second `lakePatch` resends both fields, because a patch replaces the whole component and a bare text patch turned the line primary white after one second. Because the clock left the trailing column, the flag is a single 30-point badge (it used to be a 22-point image stacked over the clock).
- DynaGlance gets its own compact layout (logo, provider, state, flag), and its pill button is temporary: it appears only while the plugin has a live activity.

**Clock cost:** the plugin renders the clock itself because DynamicLake's `timer` component cannot drop the leading hour. While the lake is open it sends one small `lakePatch` per second updating that single text component — a few dozen bytes — and sends nothing for the clock while the lake is closed. Status polling, activity updates and the socket cadence are unchanged. DynamicLake's frames are also read during the idle wait, and the last card is resent the moment `lakeOpened` is read, so opening the lake redraws it in milliseconds even if a status resolution (DNS or exit-country lookup) is in flight.

Everything lake-related is feature-gated. On a DynamicLake build that does not advertise `lake`, `lakeLayout`, or `imageAssets`, the plugin sends no lake or asset frames and behaves exactly as 1.2.1 did — including inline artwork. The `lake` and `glance` keys stay in `plugin.json` because a manifest cannot be conditional. The lake size lives in the manifest too, so changing it requires reinstalling the plugin rather than restarting it.

## Settings
- `notifyOnChange` (switch, default off): **OFF (default):** a persistent small live activity stays in the notch while connected. A Sneak Peek is actively presented at notification priority on every connection, disconnection, and server/country change, then the capsule settles back into the extra live activity row; after disconnect the capsule remains visible for about four seconds before dismissal. **ON:** no persistent activity; the same banner-style notifications appear on changes and dismiss themselves after about four seconds. To test: enable it, then connect or disconnect your VPN.
- `persistOnDisconnect` (switch, default off, persistent mode only): when enabled, the live activity stays in the notch even while the VPN is off (shows a red disconnected icon). When disabled, turning the VPN off dismisses the activity.
- The automatic peek (`presentSneakPeek`) only fires when DynamicLake advertises the `presentSneakPeek` protocol feature (see `DYNAMICLAKE_PLUGIN_FEATURES` in the startup log); otherwise the same update is sent without the field and the peek simply shows on hover instead.
- Debug events (startup, transitions, announcements, send errors, fallback contradictions) are written to `~/Library/Logs/vpn-status.log`.

## Identifier
`com.nebulark.vpn-status`

## Authors
- **gantant** ([@gantant](https://github.com/gantant)) — original plugin and ongoing development
- **Rafael Reverberi** ([@rafaelreverberi](https://github.com/rafaelreverberi)) — ProtonVPN exit-country stabilization (1.1.6) and bundled flag artwork

## Version
1.3.1

## Changelog
Only the latest release is listed here; the full version history lives in [CHANGELOG.md](CHANGELOG.md).
- **1.3.1** — The lake is now notification sized (390 × 80, declared with `"size": "notification"` in `plugin.json`) and the Open provider app button is gone; right-clicking the logo opens the app instead. The card is one row — provider logo, provider name over a secondary state line that now carries the session clock (`Connected · Romania · 5:07`), and a bigger 30-point flag — with a 1-point clearance spacer so the notch no longer clips it. Reinstalling the plugin is required for the manifest size change.
- **1.3.0** — Built for the new DynamicLake plugin API. The plugin now has a lake: a small status card with the provider, connection state, exit country, a live session timer and an Open provider app button, plus a compact design for DynaGlance and a temporary DynaGlance button that appears only while a VPN is active. Provider logos and flags are registered as image assets once per connection instead of being re-sent inline, and the protocol now handles `lakeOpened` and button `action` frames. Everything is feature-gated: older DynamicLake builds get the unchanged 1.2.1 behavior. See [CHANGELOG.md](CHANGELOG.md) for the full history.

## Notes
- One action, on the lake's logo: right-click it to open the provider app. Status itself lives in the live activity; a sneak peek shows status text / server flag
- Universal binary supports both Apple Silicon (arm64) and Intel (x86_64) Macs, macOS 14.0+
- Package size is well under the 7MB/20MB limits
- Icon is 512x512 PNG (within 1.5MB limit)
- Bounded, size-capped event logging to `~/Library/Logs/vpn-status.log`: consecutive identical events collapse into one line with a repeat count, and the file rotates (keeping the most recent 64KB) at 256KB, so it can never grow unbounded
- No sudo/Python code required
- No `networksetup` commands; the only outbound request is the HTTPS country lookup described above

## Flag Artwork

Country flag artwork is derived from [flag-icons](https://github.com/lipis/flag-icons) and included under its MIT license in `src/flags/LICENSE-flag-icons.txt`.
