#!/usr/bin/env python3
"""Black-box checks for the built DynamicLake plugin."""

from __future__ import annotations

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
    output = subprocess.run(
        ["/usr/sbin/scutil", "--nc", "list"],
        check=False,
        capture_output=True,
        text=True,
    ).stdout
    return any(
        line.lstrip("* ").startswith("(Connected)") and ("NordVPN" in line or "ProtonVPN" in line)
        for line in output.splitlines()
    )


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
                provider_slots = [slot for slot in compact_slots if slot.get("source") in {"inlineData", "asset"}]
                assert provider_slots, "connected compact surface never showed the provider logo"
                assert all(
                    len(slot["base64Data"]) > 100 for slot in provider_slots if slot["source"] == "inlineData"
                )
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
                # The body is lifted off the card's bottom edge with a bottom
                # inset. The padding validator accepts only these three fields;
                # anything else (a `top` inset, for one) rejects the whole lake
                # command and leaves the user with DynamicLake's fallback card.
                body_padding = body.get("padding")
                assert body_padding, "card body has no padding"
                assert set(body_padding) == {"leading", "bottom", "trailing"}
                # The connected card is lifted off the bottom edge; the
                # disconnected card sits flush, so its text is not pushed up
                # into the notch (it clips there when lifted).
                if connected:
                    assert body_padding["bottom"] > 0, "connected body is not lifted"
                else:
                    assert body_padding["bottom"] == 0, "disconnected body is lifted into the notch"
                # DynaGlance gets its own compact design and never a bottom section.
                assert lake["glance"]["hideHeader"] is True
                assert isinstance(lake["glance"].get("content"), list)
                assert "bottom" not in lake
                # A fixed spacer sits above the row: the only downward control
                # a lake has, since padding takes no top edge. Both cards use
                # it, so the connected and disconnected layouts stay identical.
                gaps = body["children"][0]
                assert gaps["type"] == "spacer" and gaps["length"] > 0, "row has no top clearance"
                top = body["children"][1]
                assert top["type"] == "hstack" and top["id"] == "lake-top"
                # The logo leads the card as plain artwork: a button can never be
                # transparent (a `plain` one draws an opaque disc), so the app
                # action lives on the logo's right-click menu instead.
                logo = top["children"][0]
                assert logo["type"] == "image", "card does not start with the logo"
                assert logo["size"] == 30
                assert top["children"][1]["type"] == "vstack", "name is not over the state"
                labels = find_components(top["children"][1], lambda c: c.get("type") == "text")
                assert [label["style"] for label in labels] == ["large", "plain"]
                # The state line is one text component: state, country and the
                # plugin-rendered clock, separated by middots. The clock reads
                # m:ss below an hour and h:mm:ss once the session has an hour,
                # and is only sent when an exact session start is known
                # (NetworkExtension); the scutil fallback omits it entirely.
                status_line = labels[1]
                assert status_line["id"] == "session-line"
                parts = [part.strip() for part in status_line["text"].split("·")]
                if not connected:
                    assert parts == ["Not connected"], f"unexpected disconnected line {parts}"
                else:
                    assert parts[0] == "Connected", f"unexpected connected line {parts}"
                    if len(parts) == 3:
                        assert re.fullmatch(r"\d+:[0-5]\d(:[0-5]\d)?", parts[2]), \
                            f"clock is not in the state line: {parts}"
                if connected:
                    assert labels[0]["text"] in {"NordVPN", "Proton VPN", "VPN Status"}
                # One column of text, and the flag closes the row on its own —
                # nothing stacks under it any more.
                columns = [child for child in top["children"] if child.get("type") == "vstack"]
                assert len(columns) == 1, "unexpected extra column in the card"
                if connected:
                    flag = top["children"][-1]
                    assert flag["type"] == "image", "connected card does not close on the flag"
                    assert flag["size"] == 30, "flag is no longer the enlarged trailing badge"
                # The card is a notification-sized single row with nothing drawn
                # on it: no button at all, so nothing competes with the status
                # row for height and no disc covers the artwork.
                assert len(body["children"]) == 2, "card is no longer a spacer plus one row"
                assert not find_components(body, lambda c: c.get("type") == "button"), \
                    "lake still draws a button"
                menu = logo.get("contextMenu") or []
                assert len(menu) <= 1, "logo has more than one menu entry"
                for item in menu:
                    assert item["actionID"] == "open-app"
                    assert item["title"].startswith("Open ")
                # `size` is an image/button field. DynamicLake validates the whole
                # message, so a size on a text component (e.g. the emoji flag
                # fallback) rejects the entire lake command and leaves the
                # fallback card, so no component may carry one without being the
                # kind that accepts it.
                for sized in find_components(lake, lambda c: "size" in c):
                    assert sized.get("type") in {"image", "button"}, \
                        f"size on a {sized.get('type')} component rejects the lake"
                assert not any(frame.get("type") == "lakePatch" for frame in frames), "clock patched before the lake opened"
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
                if not connected:
                    # With no session clock there is nothing to tick: the lake
                    # being open must not produce per-second traffic.
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
            else:
                # Legacy DynamicLake: no lake frames, no assets, inline images.
                assert not lake_frames, "lake command sent without the lake feature"
                assert not any(frame.get("type") == "asset" for frame in frames)
                for frame in frames:
                    assert not asset_references(frame), "asset image sent without the imageAssets feature"

            return {"frames": len(frames), "connected": connected, "lakes": len(lake_frames)}
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
        f"connected={current['connected']}"
    )
    legacy = run_scenario(FEATURES_LEGACY, expect_lake=False)
    print(f"legacy DynamicLake: {legacy['frames']} frames, no lake/asset frames, connected={legacy['connected']}")
    print("runtime socket test passed")


if __name__ == "__main__":
    main()
