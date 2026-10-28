#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer a real interpreter over Apple's /usr/bin/python3 shim. That shim asks
# the user to install the command line tools whenever it cannot read its
# developer_dir, which is exactly what happens in a sandboxed shell — every run
# then pops an "install command line developer tools" dialog. Override with
# PYTHON=/path/to/python3 if needed.
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
    for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [ -x "$candidate" ]; then
            PYTHON="$candidate"
            break
        fi
    done
fi
PYTHON="${PYTHON:-/usr/bin/python3}"
echo "==> Using $PYTHON ($("$PYTHON" -V 2>&1))"

./src/build.sh
"$PYTHON" tests/test_runtime.py

TEST_BINARY=$(mktemp -t vpn-flag-smoke)
PROTON_TEST_BINARY=$(mktemp -t vpn-proton-exit-tests)
NORD_TEST_BINARY=$(mktemp -t vpn-nord-location-tests)
NE_TEST_BINARY=$(mktemp -t vpn-ne-watcher-tests)
PATH_TEST_BINARY=$(mktemp -t vpn-path-watcher-tests)
LABEL_TEST_BINARY=$(mktemp -t vpn-country-label-tests)
trap 'rm -f "$TEST_BINARY" "$PROTON_TEST_BINARY" "$NORD_TEST_BINARY" "$NE_TEST_BINARY" "$PATH_TEST_BINARY" "$LABEL_TEST_BINARY"' EXIT
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$TEST_BINARY" src/CountryFlagAsset.swift tests/FlagBadgeSmoke.swift
DYNAMICLAKE_PLUGIN_PACKAGE_PATH="$PWD/src" "$TEST_BINARY"

swiftc -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$PROTON_TEST_BINARY" src/Shared/DynamicLakeSocket.swift src/RouteTable.swift src/ProtonExit.swift tests/ProtonExitTests.swift
"$PROTON_TEST_BINARY"

swiftc -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$NORD_TEST_BINARY" src/NordServerLocation.swift tests/NordServerLocationTests.swift
"$NORD_TEST_BINARY"

swiftc -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$NE_TEST_BINARY" src/NEVPNWatcher.swift tests/NEVPNWatcherTests.swift
"$NE_TEST_BINARY"

swiftc -O -framework Network -target "$(uname -m)-apple-macosx14.0" \
    -o "$PATH_TEST_BINARY" src/Shared/DynamicLakeSocket.swift src/RouteTable.swift src/PathWatcher.swift tests/PathWatcherTests.swift
"$PATH_TEST_BINARY"

swiftc -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$LABEL_TEST_BINARY" src/CountryLabel.swift tests/CountryLabelTests.swift
"$LABEL_TEST_BINARY"
