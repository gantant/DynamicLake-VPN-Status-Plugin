# VPN Status Plugin for DynamicLake

## Overview
A DynamicLake JSON plugin that displays ProtonVPN or NordVPN connection status in the MacBook notch. It is optimized for ProtonVPN transitions and Quick Connect, with a compact provider icon and a consistently rendered country-flag badge.

## Features
- Detects provider and uses matching logo (NordVPN and ProtonVPN only for now, more to come later)
- Prioritizes ProtonVPN's NetworkExtension service and detects changes in under a second
- Uses routed-traffic validation for the utun fallback, avoiding false "connected" states from Proton's idle tunnel interface
- Status indicator
- Optional notify-on-change mode (see Settings below)
- Country is resolved asynchronously from the actual VPN exit through two HTTPS-only, no-key fallbacks (`ipinfo.io` and Mullvad's connection check). A route guard prevents lookups during tunnel transitions, and no public IP address is stored or logged. NordVPN's selected location comes from the server identity first — hostname label, or station-IP match against a hardcoded table of virtual-location pools — which is what keeps virtual locations (e.g. Armenia) showing the picked flag instead of the physical host country; the geo lookup is the fallback.
- Smaller 4:3 flag artwork is centered inside a transparent square canvas before being sent through DynamicLake's inline PNG image path. DynamicLake can keep its square image slot while rectangular flags retain their natural visible shape and spacing. It uses no emoji glyph and makes no network request for artwork; an emoji is used only as a last-resort fallback if the local asset cannot be read.
- Self-healing persistent activity: re-asserts the live activity every 30s and recovers the socket connection, so the status returns on its own after sleep/wake even if DynamicLake dropped it

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
cd src
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 -o /tmp/vpn-arm64 Shared/DynamicLakeSocket.swift VPNStatusIcons.swift CountryFlagAsset.swift VPNStatusPlugin.swift
swiftc -parse-as-library -O -target x86_64-apple-macosx14.0 -o /tmp/vpn-x86_64 Shared/DynamicLakeSocket.swift VPNStatusIcons.swift CountryFlagAsset.swift VPNStatusPlugin.swift
lipo -create -output ../VPNStatus.dynamiclakeplugin/vpn-status /tmp/vpn-arm64 /tmp/vpn-x86_64
rm /tmp/vpn-arm64 /tmp/vpn-x86_64
```

### Package for Submission
```bash
ditto -c -k --keepParent VPNStatus.dynamiclakeplugin VPNStatus.dynamiclakeplugin.zip
```

### Tests

```bash
./tests/run.sh
```

The test suite builds both architectures, checks the framed socket payload in the current ProtonVPN state, guards against the idle-utun false positive when disconnected, and verifies that the bundled country flag is a valid PNG delivered through DynamicLake's inline-image payload when connected.

## Settings
- `notifyOnChange` (switch, default off): **OFF (default):** a persistent small live activity stays in the notch while connected. A brief Sneak Peek is actively presented on every connection, country/server, and disconnection change; after disconnect the capsule remains visible for about four seconds before dismissal. **ON:** no persistent activity; the same brief notifications appear on changes and dismiss themselves after about four seconds. To test: enable it, then connect or disconnect your VPN.
- `persistOnDisconnect` (switch, default off, persistent mode only): when enabled, the live activity stays in the notch even while the VPN is off (shows a red disconnected icon). When disabled, turning the VPN off dismisses the activity.
- The automatic peek (`presentSneakPeek`) only fires when DynamicLake advertises the `presentSneakPeek` protocol feature (see `DYNAMICLAKE_PLUGIN_FEATURES` in the startup log); otherwise the same update is sent without the field and the peek simply shows on hover instead.
- Debug events (mode switches, notification creates/dismisses, send errors) are written to `~/Library/Logs/vpn-status.log`.

## Identifier
`com.nebulark.vpn-status`

## Version
1.1.8

## Changelog
- **1.1.8** — Log hygiene for shipping: the log can no longer grow unbounded. `vpn-status.log` now rotates at 256KB (keeping the most recent 64KB), and consecutive identical events collapse into one line with a repeat count instead of appending per occurrence. The ProtonVPN exit resolver's routine per-probe lines (`probe started`, `exit stable country=…`) no longer log in production — they fired on every 5s re-probe while connected (~17k lines/day); anomalous diagnostics (route mismatch, unstable probe pair, stale discards) still log, and tests opt back in to the routine lines. No behavior change to status detection, peeks, or flags.
- **1.1.7** — NordVPN flags now reflect the location you picked, not the physical server rack. NordVPN's virtual locations (e.g. Armenia) host their hardware in another country (e.g. Bulgaria), so the exit-IP geo lookup can only ever report the physical country there. The selected location now comes from the server identity itself: `*.nordvpn.com` server hostnames parse directly, and because NordWhisper exposes only the bare station IP as the macOS ServerAddress, Nord's virtual locations (Andorra, Armenia, Azerbaijan, Bahamas, Morocco, Vietnam) are matched against a hardcoded table of their known station-IP pools (captured from NordVPN's public catalog; extend the table as locations change). A confirmed Nord location always overrides geo and skips the geo lookup, so virtual locations show the picked flag immediately; unmatched stations keep the unchanged geo-IP fallback, and unresolved NordVPN addresses are logged only as a masked shape (never the IP). Also fixed the provider attribution behind the stale Proton flash: both provider apps keep GUI processes running while disconnected, so the routed-tunnel fallback now prefers the service scutil reports as Connecting during a handshake (the provider that actually owns the forming tunnel) instead of the first process-name match. ProtonVPN behavior untouched. Added hostname-parser, address-shape, and virtual-pool regression tests.
- **1.1.6** — Fixed unreliable ProtonVPN exit-country detection without touching NordVPN behavior (frozen as the regression baseline). ProtonVPN now resolves both the public exit IP and the country via a dedicated `ProtonExitResolver` that probes twice (~0.4s apart) and only publishes the country when the same exit IP is observed in both probes under a stable `utun` route; mismatched probes (Quick Connect / server change mid-transition) are discarded and retried instead of briefly showing the old country's flag. The observed exit IP is part of the effective Proton connection identity, so server switches that keep the same service name and `utun` interface are still detected (re-probed every 5s; NordVPN keeps its 15s cadence). Exit-IP route validation is IPv4/IPv6-consistent (`-inet6` for IPv6 literals), results stay generation-tagged so stale async responses are discarded, and the public IP is never logged. The connect Sneak Peek no longer has a timeout: while connected it waits until the country resolves so it always presents logo + country + flag together (disconnect peeks stay instant). Added 60+ regression tests covering NordVPN exclusion, stable/switching/stale/route-change/disconnect cases, and IP-in-logs prevention.
- **1.1.5** — Hardened the socket layer (bounded send retries, kill-escalation for hung subprocesses, socket-blip recovery on disconnect peeks) and reset surfaces signatures on mode switches so a notify→persistent toggle always rebuilds the capsule. The connect Sneak Peek now waits for the country lookup (bounded at 2.5s): the flag refresh goes first, then the peek follows as a pure presentation update on unchanged surfaces — DynamicLake ignores `presentSneakPeek` on an update that also changes surfaces, and notify mode now presents the same Sneak Peek as persistent mode (on the create itself it is ignored), with the notification held until the peek finishes. Sneak-peek surface construction deduplicated; settings-file parse failures are now logged (once).
- **1.1.4** — Provider handshakes no longer flash the wrong logo (macOS can briefly report the old session as Connected while a new VPN connects); a fresh connection is only reported once it is seen twice in a row. Country/flag resolution now refreshes the notch in place instead of re-presenting the Sneak Peek a second time. Connect Sneak Peeks in persistent mode are now presented via a short-delayed update, since DynamicLake honours `presentSneakPeek` on updates only and swallows one racing the create.
- **1.1.3** — Minimized side capsule (`extraLiveActivity`) now always shows the provider logo instead of the country flag; front compact view unchanged (logo + flag).
- **1.1.2** — Fixed stale/wrong ProtonVPN flags after Quick Connect and reconnects; rejects Proton's idle utun interface unless public traffic is actually routed through it; detects transitions in under a second; resolves country asynchronously with a Proton-compatible HTTPS fallback; removes public IPs from logs; replaces the emoji with smaller 4:3 flag artwork centered on transparent canvases so rectangular flags are not stretched into square badges; and directly presents the same Sneak Peek on every connect, country/server, and disconnect change.
- **1.1.0** — Flag now reflects the actual VPN exit country (self-lookup via ip-api), so ProtonVPN gets a flag and switching NordVPN country while connected refreshes it within ~30s without a reconnect. Mode switches (Notify on Change / Show Disconnected Status) now apply live without restarting DynamicLake.
- **1.0.9** — Fixed false-positive "VPN Connected" status: macOS's always-on utun interfaces (link-local `fe80::`, loopback, `169.254.*`, ULA addresses) are no longer mistaken for an active VPN tunnel. A running NordVPN/ProtonVPN process alone no longer implies a connected VPN. Notify mode now recovers the socket connection after send failures, and DynamicLake error responses are logged to `vpn-status.log`.
- **1.0.8** — Initial public release.

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
