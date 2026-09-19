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

## Authors
- **gantant** ([@gantant](https://github.com/gantant)) — original plugin and ongoing development
- **Rafael Reverberi** ([@rafaelreverberi](https://github.com/rafaelreverberi)) — ProtonVPN exit-country stabilization (1.1.6) and bundled flag artwork

## Version
1.1.8

## Changelog
Only the latest release is listed here; the full version history lives in [CHANGELOG.md](CHANGELOG.md).
- **1.1.8** — Log hygiene for shipping: the log can no longer grow unbounded. `vpn-status.log` now rotates at 256KB (keeping the most recent 64KB), and consecutive identical events collapse into one line with a repeat count instead of appending per occurrence. The ProtonVPN exit resolver's routine per-probe lines (`probe started`, `exit stable country=…`) no longer log in production — they fired on every 5s re-probe while connected (~34k lines/day); anomalous diagnostics (route mismatch, unstable probe pair, stale discards) still log, and tests opt back in to the routine lines. No behavior change to status detection, peeks, or flags.

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
