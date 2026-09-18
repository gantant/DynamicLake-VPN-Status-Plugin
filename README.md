# VPN Status Plugin for DynamicLake

## Overview
A DynamicLake JSON plugin that displays VPN connection status in the MacBook notch. Minimal, with no buttons - optionally shows a connect/disconnect notification or a lingering status with the server's country flag. 

## Features
- Detects provider and uses matching logo (NordVPN and ProtonVPN only for now, more to come later)
- Auto-detects VPN state via scutil and utun interface detection
- Status indicator
- Optional notify-on-change mode (see Settings below)
- Server country flag in the notification/status, resolved from the actual VPN exit IP via ip-api.com (probed on connect, on server change, and re-checked every 30s, so switching country without disconnecting refreshes the flag automatically; works for providers that don't expose a server address, e.g. ProtonVPN)
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
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 -o /tmp/vpn-arm64 Shared/DynamicLakeSocket.swift VPNStatusIcons.swift VPNStatusPlugin.swift
swiftc -parse-as-library -O -target x86_64-apple-macosx14.0 -o /tmp/vpn-x86_64 Shared/DynamicLakeSocket.swift VPNStatusIcons.swift VPNStatusPlugin.swift
lipo -create -output ../VPNStatus.dynamiclakeplugin/vpn-status /tmp/vpn-arm64 /tmp/vpn-x86_64
rm /tmp/vpn-arm64 /tmp/vpn-x86_64
```

### Package for Submission
```bash
ditto -c -k --keepParent VPNStatus.dynamiclakeplugin VPNStatus.dynamiclakeplugin.zip
```

## Settings
- `notifyOnChange` (switch, default off): **OFF (default):** a persistent small live activity stays in the notch at all times, and a brief peek notification also appears on connect/disconnect transitions. **ON:** no persistent activity; only a brief "VPN Connected"/"VPN Disconnected" notification appears (with the peek) for about 4 seconds on transitions, then fully dismisses. To test: enable it, then connect or disconnect your VPN.
- `persistOnDisconnect` (switch, default off, persistent mode only): when enabled, the live activity stays in the notch even while the VPN is off (shows a red disconnected icon). When disabled, turning the VPN off dismisses the activity.
- The automatic peek (`presentSneakPeek`) only fires when DynamicLake advertises the `presentSneakPeek` protocol feature (see `DYNAMICLAKE_PLUGIN_FEATURES` in the startup log); otherwise the same update is sent without the field and the peek simply shows on hover instead.
- Debug events (mode switches, notification creates/dismisses, send errors) are written to `~/Library/Logs/vpn-status.log`.

## Identifier
`com.nebulark.vpn-status`

## Version
1.1.0

## Changelog
- **1.1.0** — Flag now reflects the actual VPN exit country (self-lookup via ip-api), so ProtonVPN gets a flag and switching NordVPN country while connected refreshes it within ~30s without a reconnect. Mode switches (Notify on Change / Show Disconnected Status) now apply live without restarting DynamicLake.
- **1.0.9** — Fixed false-positive "VPN Connected" status: macOS's always-on utun interfaces (link-local `fe80::`, loopback, `169.254.*`, ULA addresses) are no longer mistaken for an active VPN tunnel. A running NordVPN/ProtonVPN process alone no longer implies a connected VPN. Notify mode now recovers the socket connection after send failures, and DynamicLake error responses are logged to `vpn-status.log`.
- **1.0.8** — Initial public release.

## Notes
- No buttons. Status lives in the live activity; a sneak peek shows status text / server flag
- Universal binary supports both Apple Silicon (arm64) and Intel (x86_64) Macs, macOS 14.0+
- Package size is well under the 7MB/20MB limits
- Icon is 512x512 PNG (within 1.5MB limit)
- Only bounded event logging (events, not per-poll output) to `~/Library/Logs/vpn-status.log`
- No sudo/Python code required
- No networksetup commands
