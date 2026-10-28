#!/usr/bin/env python3
"""Black-box checks for the built DynamicLake plugin."""

from __future__ import annotations

from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "src" / "vpn-status"

# Features advertised by the DynamicLake the plugin is built for. The legacy
# run advertises only what 1.2.x-era builds did, to prove the plugin still
# speaks exactly the old protocol when nothing newer is available.
FEATURES_CURRENT = "presentSneakPeek,numericText,lake,lakeLayout,imageAssets"
FEATURES_LEGACY = "presentSneakPeek"


def receive_frame(connection: socket.socket) -> dict:
    header = connection.recv(4)
    if len(header) != 4:
        raise AssertionError("plugin closed before sending a complete frame")
    length = struct.unpack(">I", header)[0]
    body = bytearray()
    while len(body) < length:
        chunk = connection.recv(length - len(body))
        if not chunk:
            raise AssertionError("plugin closed during a frame")
        body.extend(chunk)
    return json.loads(body)


def send_frame(connection: socket.socket, payload: dict) -> None:
    body = json.dumps(payload).encode("utf-8")
    connection.sendall(struct.pack(">I", len(body)) + body)


def find_components(value, predicate) -> list[dict]:
    """Every component in a frame payload that matches `predicate`."""
    found: list[dict] = []
    if isinstance(value, dict):
        if predicate(value):
            found.append(value)
        for child in value.values():
            found.extend(find_components(child, predicate))
    elif isinstance(value, list):
        for child in value:
            found.extend(find_components(child, predicate))
    return found


def asset_references(value) -> list[str]:
    """Every assetID referenced by an `image` component in a frame."""
    found: list[str] = []
    if isinstance(value, dict):
        if value.get("type") == "image" and value.get("source") == "asset":
            found.append(value.get("assetID", ""))
        for child in value.values():
            found.extend(asset_references(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(asset_references(child))
    return found


def collect_frames(connection: socket.socket, wants_lake: bool, timeout: float = 8.0) -> list[dict]:
    frames: list[dict] = []
    seen_demote = False
    seen_lake = False
    connection.settimeout(1)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            frame = receive_frame(connection)
        except (socket.timeout, TimeoutError):
            continue
        frames.append(frame)
        if frame.get("requestID", "").startswith("demote-"):
            seen_demote = True
        if frame.get("type") == "lake":
            seen_lake = True
        if seen_demote and (seen_lake or not wants_lake):
            break
    return frames


def await_frame(connection: socket.socket, predicate, timeout: float = 3.0) -> dict | None:
    connection.settimeout(0.5)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            frame = receive_frame(connection)
        except (socket.timeout, TimeoutError):
            continue
        if predicate(frame):
            return frame
    return None


def vpn_is_connected() -> bool:
    """Whether this machine has a VPN up, by the same rules the plugin uses.

    A tunnel that NetworkExtension manages shows up in `scutil --nc list`. One
    that installs its own utun (X-VPN, the WireGuard app) registers nothing and
    is only visible as the interface owning the default route — if this helper
    ignored that, the suite would assert the disconnected card on a machine that
    is plainly connected.
    """
    output = subprocess.run(
        ["/usr/sbin/scutil", "--nc", "list"],
        check=False,
        capture_output=True,
        text=True,
    ).stdout
    if any(
        line.lstrip("* ").startswith("(Connected)") and ("NordVPN" in line or "ProtonVPN" in line)
        for line in output.splitlines()
    ):
        return True
    route = subprocess.run(
        ["/sbin/route", "-n", "get", "1.1.1.1"],
        check=False,
        capture_output=True,
        text=True,
    ).stdout
    for line in route.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == "interface:":
            return fields[1].startswith("utun")
    return False


def run_scenario(features: str, *, expect_lake: bool) -> dict:
    if not BINARY.exists():
        raise SystemExit("build the plugin first with src/build.sh")

    connected = vpn_is_connected()
    with tempfile.TemporaryDirectory(prefix="vpn-status-test-") as temp:
        temp_path = Path(temp)
        socket_path = temp_path / "dynamiclake.sock"
        settings_path = temp_path / "settings.json"
        settings_path.write_text(
            json.dumps({"values": {"notifyOnChange": False, "persistOnDisconnect": True}}),
            encoding="utf-8",
        )

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(socket_path))
        server.listen(1)
        # First exec of a freshly built binary can stall in Gatekeeper's scan;
        # give the plugin generous time to attach.
        server.settimeout(15)

        environment = os.environ.copy()
        environment.update(
            {
                "DYNAMICLAKE_JSON_SOCKET": str(socket_path),
                "DYNAMICLAKE_PLUGIN_SETTINGS_PATH": str(settings_path),
                "DYNAMICLAKE_PLUGIN_PACKAGE_PATH": str(ROOT / "VPNStatus.dynamiclakeplugin"),
                "DYNAMICLAKE_PLUGIN_FEATURES": features,
                # The binary logs to ~/Library/Logs by default; never let a test
                # run write into the user's real log (and never let an injected
                # rejection look like a real one).
                "DYNAMICLAKE_PLUGIN_LOG_PATH": str(temp_path / "vpn-status.log"),
            }
        )
        process = subprocess.Popen(
            [str(BINARY)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        try:
            connection, _ = server.accept()
            frames = collect_frames(connection, wants_lake=expect_lake)

            assert frames[0]["type"] == "dismiss"
            create = next(frame for frame in frames if frame["type"] == "create")
            # Two-phase presentation: announces at notification priority, then a
            # demote update returns the activity to the persistent profile.
            # Size must NOT differ between phases: a size change re-lays-out the
            # compact surface and visibly shifts the logo/flag a few pixels.
            assert create["priority"] == "high"
            assert create["size"] == "small"

            flag_seen = any(
                frame.get("surfaces", {}).get("compactLiveActivity", {}).get("rightSlot") is not None
                for frame in frames
            )
            peek_frames = [frame for frame in frames if frame.get("presentSneakPeek") == 2]
            demotes = [frame for frame in frames if frame.get("requestID", "").startswith("demote-")]
            # While connected with an unresolved exit country the peek is held
            # on purpose (it must present logo + country + flag together), so
            # only assert the presentation contract when a peek is due: always
            # disconnected, and connected once the flag has arrived.
            if not connected or flag_seen:
                assert peek_frames, "no presented sneak peek"
                assert demotes, "presented peek was never demoted"
                demote = demotes[0]
                assert demote["type"] == "update"
                assert demote["priority"] == "low"
                assert "size" not in demote
            assert set(create["surfaces"]) == {"compactLiveActivity", "sneakPeek", "extraLiveActivity"}
            compact = create["surfaces"]["compactLiveActivity"]
            extra = create["surfaces"]["extraLiveActivity"]
            # Minimized (ELA) capsule must always be the provider logo, never the flag.
            assert "rightSlot" not in extra
            assert extra["leftSlot"] == compact["leftSlot"]

            # The first create can carry the disconnected card while a fresh
            # connection waits for its confirming second sighting, so scan every
            # compact surface before deciding what the connected state looks like.
            compact_slots = [
                frame["surfaces"]["compactLiveActivity"]["leftSlot"]
                for frame in frames
                if frame.get("surfaces", {}).get("compactLiveActivity", {}).get("leftSlot")
            ]
            if connected:
                # A known provider ships artwork; a VPN the plugin only knows by
                # its tunnel (X-VPN) gets the generic SF Symbol instead, which is
                # still a logo. What must never happen is a connected surface
                # with no left slot at all.
                assert compact_slots, "connected compact surface never showed a logo"
                for slot in compact_slots:
                    assert slot.get("source") in {"inlineData", "asset", "sfSymbol"}, f"unexpected logo {slot}"
                    if slot.get("source") == "inlineData":
                        assert len(slot["base64Data"]) > 100, "provider logo payload is empty"
            else:
                assert compact["leftSlot"]["systemImage"] == "network.slash"
                assert "rightSlot" not in compact

            lake_frames = [frame for frame in frames if frame.get("type") == "lake"]
            if expect_lake:
                assert lake_frames, "no lake command was sent"
                lake = lake_frames[-1]["lake"]
                # The header row is hidden and the card laid out by hand as the
                # single row a notification-sized lake holds. No header slots or
                # title/subtitle are sent with it.
                assert lake["hideHeader"] is True
                assert "leftSlot" not in lake and "rightSlot" not in lake
                assert "title" not in lake and "subtitle" not in lake
                assert isinstance(lake.get("content"), list) and lake["content"]
                body = lake["content"][0]
                assert body["type"] == "vstack" and body["id"] == "lake-body"
                # DynaGlance gets its own design: the header row DynamicLake
                # already sizes for that area (artwork, title, gray subtitle,
                # trailing slot), rather than a hand-built row. A glance has no
                # bottom section, and neither surface is built from a hidden
                # header plus a content stack any more.
                glance = lake["glance"]
                assert "hideHeader" not in glance, "glance still hides its header"
                assert "content" not in glance, "glance is hand-built instead of a header row"
                assert "bottom" not in lake
                assert glance["leftSlot"]["type"] == "image", "glance has no artwork"
                assert glance["title"]["type"] == "text" and glance["title"]["text"]
                assert glance["subtitle"]["type"] == "text"
                assert glance["subtitle"]["text"], "glance has no state line"
                # Nothing on the glance ticks: its line carries no clock, so
                # there is no component for the per-second patch to replace.
                assert "id" not in glance["subtitle"], "glance line is patched per second"
                if connected:
                    assert glance.get("rightSlot", {}).get("type") == "image", \
                        "connected glance does not close on the flag"
                else:
                    assert "rightSlot" not in glance
                    assert glance["leftSlot"]["systemImage"] == "network.slash"
                # The row is about 51 points tall (the trailing column of timer
                # over flag is the tallest thing in it) on a notification-sized
                # card, so it is dropped into the card with a fixed spacer. A
                # `spacer` without a `length` renders nothing (measured), which
                # is why the row's position is a real point value and not left
                # to flexible space; `padding` is not sent at all, since its
                # `top` edge is rejected outright by older builds.
                assert "padding" not in body, "card body still leans on a padding inset"
                children = body["children"]
                assert len(children) == 2, f"card is not clearance plus one row: {children}"
                gaps = children[0]
                assert gaps["type"] == "spacer" and gaps["length"] > 0, "row has no top clearance"
                top = children[1]
                assert top["type"] == "hstack" and top["id"] == "lake-top"
                # The logo leads the card as plain artwork: a button can never be
                # transparent (a `plain` one draws an opaque disc), so the app
                # action is the image's own `actionID` instead.
                logo = top["children"][0]
                assert logo["type"] == "image", "card does not start with the logo"
                assert logo["size"] == 34
                assert top["children"][1]["type"] == "vstack", "name is not over the state"
                labels = find_components(top["children"][1], lambda c: c.get("type") == "text")
                assert [label["style"] for label in labels] == ["large", "plain"]
                # The state line is one text component of state and country,
                # separated by a middot — `Connected · Romania`. The session
                # clock is not part of it any more: that is the host's `timer`
                # component in the trailing column, and no text here may read
                # like a clock, since a plugin-rendered one was what the card
                # clipped as the session grew.
                status_line = labels[1]
                assert "id" not in status_line, "state line is still patched by id"
                parts = [part.strip() for part in status_line["text"].split("·")]
                if not connected:
                    assert parts == ["Not connected"], f"unexpected disconnected line {parts}"
                else:
                    assert parts[0] == "Connected", f"unexpected connected line {parts}"
                    assert len(parts) <= 2, f"state line still carries the clock: {parts}"
                for text in find_components(lake, lambda c: c.get("type") == "text"):
                    assert not re.fullmatch(r"\d+:[0-5]\d(:[0-5]\d)?", text.get("text", "")), \
                        f"plugin-rendered clock in the card: {text}"
                # The glance carries the lake's own state and country, narrowed
                # for its much smaller header row: the same state word, and a
                # country label no longer than the glance's budget. The country
                # is the part that used to be clipped (`Connected · United Arab
                # Emirates` is wider than that row), so it is never longer than
                # the lake's and never over the budget.
                glance_parts = [part.strip() for part in glance["subtitle"]["text"].split("·")]
                assert glance_parts[0] == parts[0], \
                    f"glance state {glance_parts[0]!r} is not the lake's {parts[0]!r}"
                if not connected:
                    assert glance_parts == ["Not connected"], f"unexpected glance line {glance_parts}"
                else:
                    assert len(glance_parts) <= 2, f"glance line still carries the clock: {glance_parts}"
                    lake_country = parts[1] if len(parts) == 2 else ""
                    glance_country = glance_parts[1] if len(glance_parts) == 2 else ""
                    assert len(lake_country) <= 14, f"lake country over its budget: {lake_country!r}"
                    assert len(glance_country) <= 10, f"glance country over its budget: {glance_country!r}"
                    assert len(glance_country) <= len(lake_country), (
                        f"glance country {glance_country!r} is wider than the lake's {lake_country!r}"
                    )
                if connected:
                    # Known providers are named; a routed tunnel is attributed to
                    # whatever owns it, falling back to the generic "VPN".
                    assert labels[0]["text"], "connected card has no provider name"
                # One column of text, then the trailing column: the session timer
                # the host renders, stacked over the exit-country flag that closes
                # the row. The timer has that line to itself, so no text beside it
                # can squeeze it.
                columns = [child for child in top["children"] if child.get("type") == "vstack"]
                assert len(columns) <= 2, "unexpected extra column in the card"
                if connected:
                    assert len(columns) == 2, "connected card has no trailing column"
                    trailing = columns[1]
                    assert trailing["alignment"] == "trailing", "trailing column is not trailing-aligned"
                    flag = trailing["children"][-1]
                    assert flag["type"] == "image", "connected card does not close on the flag"
                    assert flag["size"] == 32, "flag is no longer the enlarged trailing badge"
                    timers = [child for child in trailing["children"] if child.get("type") == "timer"]
                    assert len(timers) == len(trailing["children"]) - 1, \
                        "the trailing column is not the session timer over the flag"
                    for timer in timers:
                        # DynamicLake's own component, counting up from the
                        # session's start date. An `endDate` is required and the
                        # count stops there, so the card arms it well ahead of
                        # where the session could have reached.
                        assert timer["countsDown"] is False, "session timer counts down"
                        assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", timer["startDate"])
                        assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", timer["endDate"])
                        start = datetime.fromisoformat(timer["startDate"].replace("Z", "+00:00"))
                        end = datetime.fromisoformat(timer["endDate"].replace("Z", "+00:00"))
                        assert start < end, "session timer window is not ordered"
                        assert end - start >= timedelta(hours=22), \
                            f"session timer window is too short to stay live: {end - start}"
                else:
                    assert len(columns) == 1, "disconnected card has a trailing column"
                    assert not find_components(lake, lambda c: c.get("type") == "timer"), \
                        "disconnected card carries a session timer"
                # The card is a notification-sized single row with nothing drawn
                # on it: no button at all, so nothing competes with the status
                # row for height and no disc covers the artwork.
                assert not find_components(body, lambda c: c.get("type") == "button"), \
                    "lake still draws a button"
                # The logo is the control: an image with an `actionID` is tappable
                # and draws nothing, and its `title` is only the tooltip. It is
                # absent when the provider app cannot be found, so the card never
                # offers a dead press; when present it names that provider.
                if "actionID" in logo:
                    assert logo["actionID"] == "open-app"
                    assert logo["title"].startswith("Open "), "logo tooltip does not name the app"
                assert "contextMenu" not in logo, "logo fell back to a menu entry"
                # `size` is an image/button field. DynamicLake validates the whole
                # message, so a size on a text component (e.g. the emoji flag
                # fallback) rejects the entire lake command and leaves the
                # fallback card, so no component may carry one without being the
                # kind that accepts it.
                for sized in find_components(lake, lambda c: "size" in c):
                    assert sized.get("type") in {"image", "button"}, \
                        f"size on a {sized.get('type')} component rejects the lake"
                assert not any(frame.get("type") == "lakePatch" for frame in frames), \
                    "lakePatch sent although nothing on the card ticks"
                # The flag is inline everywhere: a header-slot asset reference
                # rendered nothing in the lake, so it is never registered or
                # referenced by asset id.
                assert not any(
                    frame.get("type") == "asset" and frame["asset"]["id"] == "vpn-flag"
                    for frame in frames
                ), "flag asset registered"
                assert "vpn-flag" not in [
                    asset_id for frame in frames for asset_id in asset_references(frame)
                ], "flag referenced as an asset"
                # An asset reference may only appear after its registration frame.
                registered: set[str] = set()
                for frame in frames:
                    if frame.get("type") == "asset":
                        registered.add(frame["asset"]["id"])
                    for asset_id in asset_references(frame):
                        assert asset_id in registered, f"unregistered asset {asset_id} referenced"

                # The lake must refresh on the opening event, not only on state
                # changes: DynamicLake reports when the lake becomes visible.
                opened_at = time.monotonic()
                send_frame(connection, {"schemaVersion": 1, "type": "lakeOpened", "trigger": "click", "size": "small"})
                refreshed = await_frame(connection, lambda f: f.get("type") == "lake")
                assert refreshed is not None, "lakeOpened did not refresh the lake"
                # The opening frame is drained from inside the wait, so the card
                # refreshes immediately instead of on the next status poll.
                assert time.monotonic() - opened_at < 1.0, "lake refresh waited for a poll"
                # Nothing ticks any more, connected or not: the timer is the
                # host's component, so an open lake produces no timed traffic at
                # all — not one frame per second, not one per minute.
                assert await_frame(connection, lambda f: f.get("type") == "lakePatch", timeout=1.5) is None

                # Actions are dispatched without tearing the socket down. An
                # unknown action is used so the test never launches a VPN app.
                send_frame(
                    connection,
                    {
                        "schemaVersion": 1,
                        "type": "action",
                        "activityID": "lake",
                        "actionID": "test-noop",
                        "componentID": "lake-top",
                        "surface": "lake",
                    },
                )
                time.sleep(0.3)
                assert process.poll() is None, "plugin exited after an action frame"

                # A build that predates the image action rejects the whole lake
                # command, which leaves DynamicLake on its fallback card. The
                # plugin must notice and repaint with the right-click menu
                # instead of staying broken.
                if "actionID" in logo:
                    send_frame(
                        connection,
                        {
                            "schemaVersion": 1,
                            "type": "error",
                            "error": "Unknown field 'actionID' at $.lake.content[0].children[1].children[0].",
                        },
                    )
                    degraded = await_frame(
                        connection,
                        lambda f: f.get("type") == "lake"
                        and any(
                            "contextMenu" in image
                            for image in find_components(f, lambda c: c.get("type") == "image")
                        ),
                        timeout=3,
                    )
                    assert degraded is not None, "rejected image action did not fall back to the menu"
                    fallback_row = [
                        child for child in degraded["lake"]["content"][0]["children"]
                        if child.get("id") == "lake-top"
                    ][0]
                    fallback_logo = fallback_row["children"][0]
                    assert "actionID" not in fallback_logo, "rejected actionID was sent again"
                    assert "title" not in fallback_logo, "rejected image title was sent again"
                    entry = fallback_logo["contextMenu"][0]
                    assert entry["actionID"] == "open-app" and entry["title"].startswith("Open ")

                # The same strict validator turns down a `timer` it does not
                # know, and that costs the whole card. The plugin must drop the
                # timer and repaint rather than leave the fallback card up.
                if find_components(lake, lambda c: c.get("type") == "timer"):
                    send_frame(
                        connection,
                        {
                            "schemaVersion": 1,
                            "type": "error",
                            "error": "Unknown field 'countsDown' at $.lake.content[0].children[1].children[3].children[0].",
                        },
                    )
                    timerless = await_frame(
                        connection,
                        lambda f: f.get("type") == "lake"
                        and not find_components(f, lambda c: c.get("type") == "timer"),
                        timeout=3,
                    )
                    assert timerless is not None, "rejected session timer was sent again"
                    kept_row = [
                        child for child in timerless["lake"]["content"][0]["children"]
                        if child.get("id") == "lake-top"
                    ][0]
                    kept_trailing = [
                        child for child in kept_row["children"] if child.get("type") == "vstack"
                    ][-1]
                    kept_flag = kept_trailing["children"][-1]
                    assert kept_flag["type"] == "image", \
                        "dropping the timer also dropped the flag"
            else:
                # Legacy DynamicLake: no lake frames, no assets, inline images.
                assert not lake_frames, "lake command sent without the lake feature"
                assert not any(frame.get("type") == "asset" for frame in frames)
                for frame in frames:
                    assert not asset_references(frame), "asset image sent without the imageAssets feature"

            # The watcher logs the transparent-proxy configurations it can see
            # whenever that set changes. It is the only way to tell "no proxy
            # VPN installed" from "one installed and suppressed", so pin it —
            # and prove it goes to the log this run was told to use.
            log_file = temp_path / "vpn-status.log"
            log_text = log_file.read_text(encoding="utf-8", errors="replace") if log_file.exists() else ""
            proxy_lines = [line for line in log_text.splitlines() if "transparent proxy configs=" in line]
            assert log_text, "the plugin wrote no log at DYNAMICLAKE_PLUGIN_LOG_PATH"
            if expect_lake:
                assert proxy_lines, "watcher never logged its transparent-proxy configuration set"

            return {
                "frames": len(frames),
                "connected": connected,
                "lakes": len(lake_frames),
                "proxies": proxy_lines[-1].split("configs=")[-1] if proxy_lines else "unknown",
            }
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
            server.close()


def main() -> None:
    current = run_scenario(FEATURES_CURRENT, expect_lake=True)
    print(
        f"current DynamicLake: {current['frames']} frames, {current['lakes']} lake command(s), "
        f"connected={current['connected']}, proxy configs={current['proxies']}"
    )
    legacy = run_scenario(FEATURES_LEGACY, expect_lake=False)
    print(f"legacy DynamicLake: {legacy['frames']} frames, no lake/asset frames, connected={legacy['connected']}")
    check_version_pin()
    print("runtime socket test passed")


def check_version_pin() -> None:
    """The user agent is a second copy of the version. It must not drift."""
    agent = re.search(
        r'pluginUserAgent\s*=\s*"VPNStatus-DynamicLake/([^"]+)"',
        (ROOT / "src" / "Shared" / "DynamicLakeSocket.swift").read_text(encoding="utf-8"),
    )
    assert agent, "pluginUserAgent is missing or was renamed"
    manifest = json.loads((ROOT / "src" / "plugin.json").read_text(encoding="utf-8"))
    assert agent.group(1) == manifest["version"], (
        f"pluginUserAgent says {agent.group(1)} but plugin.json says {manifest['version']}"
    )


if __name__ == "__main__":
    main()
