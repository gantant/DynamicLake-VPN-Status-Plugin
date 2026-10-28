# VPN Status for DynamicLake

A DynamicLake plugin that shows VPN status in the MacBook notch: provider, connection state, exit country and session time, plus a lake card and a DynaGlance view.

Status is fully event-driven. Every transition arrives as a macOS NetworkExtension notification, a frame from DynamicLake, or a deadline the plugin scheduled itself; between events it sleeps in the run loop. It does not poll, and it does not spawn a subprocess — the routing answer is read from the kernel in process.

## What it detects

- **NordVPN and ProtonVPN** with their logos, and any other provider by its own configuration name (Hotspot Shield, a vendor's WireGuard build) under a generic shield.
- **Tunnels with no NetworkExtension configuration** — the WireGuard app, root-helper clients such as X-VPN — through the interface that carries the default route. A tunnel nothing can name is shown as **VPN**: without root there is no way to learn which app owns a `utun`, and a process scan names whichever brand happens to be installed.
- **Proxy-only VPNs** (X-VPN, for one) through `NETransparentProxyManager`, on the same status events. A proxy belonging to a tunnel provider — Proton's split tunnelling — is deliberately not reported on its own, since it can be enabled while the tunnel is down.

## Features

- Connect, disconnect and server switches announce at notification priority, then settle into the live activity.
- A persistent live activity (default), or self-dismissing notifications per change.
- A **lake**: a notification-sized card with the provider logo, provider name, `Connected · <country>`, the session timer and the exit-country flag. The logo is the only control — tap it to open the provider app.
- A **DynaGlance** view built from DynamicLake's own header row, carrying the same state line and flag.
- The exit country is the actual VPN exit (`ipinfo.io`, then Mullvad's connection check). ProtonVPN uses a stabilized two-probe lookup; NordVPN takes the selected location from the server identity first, so a virtual location shows the country you picked rather than the physical host.
- Sleep/wake aware, reconnects itself if DynamicLake's socket drops, and runs one instance per socket.

## Requirements

- macOS 14.0 or later, Apple Silicon or Intel.
- DynamicLake or DynamicLake Playground. The lake and glance need a build advertising `lake`, `lakeLayout` and `imageAssets`; older builds keep the live activity and sneak peek unchanged.

## Install

Open `VPNStatus.dynamiclakeplugin.zip` with DynamicLake, or install locally: DynamicLake Playground → Settings → Plugins → Install Local → `VPNStatus.dynamiclakeplugin`.

```
VPNStatus.dynamiclakeplugin/
├── plugin.json   # manifest, id com.nebulark.vpn-status
├── vpn-status    # universal binary, arm64 + x86_64
├── icon.png
└── flags/        # exit-country artwork
```

## Lake and glance

The lake is a notification-sized card (`"size": "notification"`) with the built-in header hidden and the body laid out as one row.

- **Layout:** a 34-point logo, the provider name in `large` over the state line, and a trailing column with the host's `timer` above a 32-point flag, dropped into the card with a 14-point top spacer. Disconnected, the logo becomes a red `network.slash`.
- **State line:** `Connected · <country>`. The country is capped at 14 characters on the lake and 10 in the glance (`UAE`, `Dom. Rep.`, `Bosnia`, then the ISO code), because a text component has no width or truncation control in the API, so the string is the only lever.
- **Tapping the logo** opens the provider app: the action rides the image (`actionID`, with `title` as the tooltip), because a `button` always draws chrome. A build that rejects the field falls back to the logo's right-click menu, and a provider whose app isn't installed gets no control at all.
- **The timer** is DynamicLake's own `timer` component, so the host ticks it — nothing is patched per second. It only appears when NetworkExtension reports an exact session start; the card is re-sent once per 24-hour window roll to keep it armed, and dropped entirely on a host that rejects the component.
- Everything lake-related is feature-gated: without `lake` and `lakeLayout` no lake frame is sent, and without `imageAssets` the artwork goes inline instead of through the asset registry. On a build without them the plugin behaves as 1.2.1 did.

## Settings

- **Notify on Change** (default off). Off: a live activity stays in the notch while connected, with a sneak peek on every connect, disconnect and server change; after a disconnect it remains visible for about four seconds. On: no persistent activity, just the same banners, self-dismissing.
- **Show Disconnected Status** (default off, persistent mode only). Keeps a red disconnected icon in the notch while the VPN is off.

The automatic peek needs DynamicLake's `presentSneakPeek` feature; without it the same update is sent and the peek simply shows on hover.

## Build and test

```bash
./src/build.sh    # both slices, lipo, ad-hoc sign both, repackage the zip
./tests/run.sh    # seven suites, no network access required
```

The suites cover the announcement contract and lake frames (driving the real binary over the framed socket), the flag artwork, ProtonVPN exit stabilization, NordVPN server locations, NetworkExtension mapping, the routing answer (checked against `netstat`, including that scoped IPv6 defaults are never counted), and the country labels both surfaces can show.

## Privacy and reliability

- No subprocesses, no polling, no telemetry. The only outbound requests are the HTTPS exit-country lookups; no public IP is stored or logged.
- The log at `~/Library/Logs/vpn-status.log` is created `0600`, rotates at 256 KB keeping the most recent 64 KB, collapses repeated events, and flattens host-supplied error text so it cannot forge a line. Set `DYNAMICLAKE_PLUGIN_LOG_PATH` to send it elsewhere.
- If DynamicLake's socket closes the plugin retries briefly, repaints when it reconnects, and exits within ten seconds if the host has really gone so it can be relaunched.

## Credits

- **gantant** ([@gantant](https://github.com/gantant)) — original plugin and ongoing development
- **Rafael Reverberi** ([@rafaelreverberi](https://github.com/rafaelreverberi)) — ProtonVPN exit-country stabilization (1.1.6) and bundled flag artwork

Flag artwork is derived from [flag-icons](https://github.com/lipis/flag-icons), MIT licensed, see `src/flags/LICENSE-flag-icons.txt`.

## Changelog

Current version: **1.4.1** — see [CHANGELOG.md](CHANGELOG.md) for the full history.
