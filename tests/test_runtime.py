#!/usr/bin/env python3
"""Black-box checks for the built DynamicLake plugin."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "src" / "vpn-status"


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


def main() -> None:
    if not BINARY.exists():
        raise SystemExit("build the plugin first with src/build.sh")

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
        server.settimeout(5)

        environment = os.environ.copy()
        environment.update(
            {
                "DYNAMICLAKE_JSON_SOCKET": str(socket_path),
                "DYNAMICLAKE_PLUGIN_SETTINGS_PATH": str(settings_path),
                "DYNAMICLAKE_PLUGIN_PACKAGE_PATH": str(ROOT / "VPNStatus.dynamiclakeplugin"),
                "DYNAMICLAKE_PLUGIN_FEATURES": "presentSneakPeek,numericText",
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
            connection.settimeout(1)
            frames = []
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    frames.append(receive_frame(connection))
                except TimeoutError:
                    continue
                if any(
                    frame.get("surfaces", {})
                    .get("compactLiveActivity", {})
                    .get("rightSlot", {})
                    .get("source")
                    == "inlineData"
                    for frame in frames
                ):
                    break

            assert frames[0]["type"] == "dismiss"
            assert any(frame.get("presentSneakPeek") == 2 for frame in frames)
            create = next(frame for frame in frames if frame["type"] == "create")
            assert create["size"] == "small"
            assert set(create["surfaces"]) == {"compactLiveActivity", "sneakPeek", "extraLiveActivity"}
            compact = create["surfaces"]["compactLiveActivity"]
            extra = create["surfaces"]["extraLiveActivity"]
            # Minimized (ELA) capsule must always be the provider logo, never the flag.
            assert "rightSlot" not in extra
            assert extra["leftSlot"] == compact["leftSlot"]
            vpn_state = subprocess.run(
                ["/usr/sbin/scutil", "--nc", "status", "ProtonVPN"],
                check=False,
                capture_output=True,
                text=True,
            ).stdout.splitlines()[0]
            if vpn_state == "Connected":
                assert compact["leftSlot"]["source"] == "inlineData"
                flagged = next(
                    frame
                    for frame in frames
                    if frame.get("surfaces", {})
                    .get("compactLiveActivity", {})
                    .get("rightSlot", {})
                    .get("source")
                    == "inlineData"
                )
                flag = flagged["surfaces"]["compactLiveActivity"]["rightSlot"]
                assert flag["mimeType"] == "image/png"
                assert len(flag["base64Data"]) > 100
            else:
                assert compact["leftSlot"]["systemImage"] == "network.slash"
                assert "rightSlot" not in compact

            # A disconnected Proton app leaves a private utun interface behind;
            # connected runs additionally prove the HTTPS fallback and flag asset.
            print("runtime socket test passed")
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
            server.close()


if __name__ == "__main__":
    main()
