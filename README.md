# VPN Status Plugin for DynamicLake

## Overview
A DynamicLake JSON plugin that displays ProtonVPN or NordVPN connection status in the MacBook notch. Status is event-driven — the plugin hears about tunnel changes from macOS directly instead of polling — with automatic fallbacks to the classic polling path, a compact provider icon, a consistently rendered country-flag badge, and banner-style Sneak Peek announcements for every connection change.

## Features
- Detects the provider and shows the matching logo (NordVPN and ProtonVPN for now, more to come later)
- Event-driven status: watches tunnels through macOS's NetworkExtension framework, so connect, disconnect, and server-switch transitions reach the notch in milliseconds, and an idle-disconnected machine costs essentially nothing
- Self-defending: while the event source is active, slow cross-checks verify it against the routing table and the system's own connection list; any contradiction hands control back to polling until it proves healthy again
- The polling fallback is complete: VPNs that don't use NetworkExtension (like the WireGuard app) keep working, and routed-traffic validation avoids false "connected" states from idle tunnel interfaces
- Banner announcements: connect, disconnect, and server switches present at notification priority so the Sneak Peek pops, then settle back into the extra live activity row
- Status indicator in the notch (persistent mode) or brief self-dismissing notifications (notify mode)
- Country is resolved asynchronously from the actual VPN exit through two HTTPS-only, no-key fallbacks (`ipinfo.io` and Mullvad's connection check). A route guard prevents lookups during tunnel transitions, and no public IP address is stored or logged. NordVPN's selected location comes from the server identity first — hostname label, or station-IP match against a hardcoded table of virtual-location pools — which is what keeps virtual locations (e.g. Armenia) showing the picked flag instead of the physical host country; the geo lookup is the fallback.
- Smaller 4:3 flag artwork is centered inside a transparent square canvas before being sent through DynamicLake's inline PNG image path. DynamicLake can keep its square image slot while rectangular flags retain their natural visible shape and spacing. It uses no emoji glyph and makes no network request for artwork; an emoji is used only as a last-resort fallback if the local asset cannot be read.
- Self-healing persistent activity: re-asserts the live activity every 30s and recovers the socket connection, so the status returns on its own after sleep/wake even if DynamicLake dropped it
- Sleep-aware: the plugin watches macOS sleep/wake directly and re-verifies everything the moment the Mac wakes, so a VPN that died during sleep leaves the notch right away

## Requirements
- macOS with DynamicLake or DynamicLake Playground
- macOS 14.0 or later (Apple Silicon or Intel)

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

Six suites, no network access required: a runtime test that drives the real binary over the framed socket and pins the announcement contract (high-priority create, low-priority demote), a flag-badge smoke test against the bundled artwork, ProtonVPN exit-country stabilization, NordVPN server/virtual-location resolution, NetworkExtension status mapping, and default-route tunnel detection mapping.

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
1.2.1

## Changelog
Only the latest release is listed here; the full version history lives in [CHANGELOG.md](CHANGELOG.md).
- **1.2.1** — Event-driven checks: the periodic routing-table verification now rides `NWPathMonitor`, Apple's push-based network monitor — the route check costs zero subprocess spawns and reacts to route changes instantly, with the proven `route` lookup kept as an automatic fallback whenever the pushed view is missing or stale (and as the always-verified final word before any decision that would switch status sources). The plugin also watches macOS sleep/wake directly: after waking it re-verifies the tunnel and re-runs its cross-checks immediately, so a VPN that died during sleep leaves the notch right away. See [CHANGELOG.md](CHANGELOG.md) for the full history.

## Notes
- No buttons. Status lives in the live activity; a sneak peek shows status text / server flag
- Universal binary supports both Apple Silicon (arm64) and Intel (x86_64) Macs, macOS 14.0+
- Package size is well under the 7MB/20MB limits
- Icon is 512x512 PNG (within 1.5MB limit)
- Bounded, size-capped event logging to `~/Library/Logs/vpn-status.log`: consecutive identical events collapse into one line with a repeat count, and the file rotates (keeping the most recent 64KB) at 256KB, so it can never grow unbounded
- No sudo/Python code required
- No `networksetup` commands; the only outbound request is the HTTPS country lookup described above

## Flag Artwork

Country flag artwork is derived from [flag-icons](https://github.com/lipis/flag-icons) and included under its MIT license in `src/flags/LICENSE-flag-icons.txt`.
