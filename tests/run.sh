#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./src/build.sh
python3 tests/test_runtime.py

TEST_BINARY=$(mktemp -t vpn-flag-smoke)
PROTON_TEST_BINARY=$(mktemp -t vpn-proton-exit-tests)
NORD_TEST_BINARY=$(mktemp -t vpn-nord-location-tests)
NE_TEST_BINARY=$(mktemp -t vpn-ne-watcher-tests)
trap 'rm -f "$TEST_BINARY" "$PROTON_TEST_BINARY" "$NORD_TEST_BINARY" "$NE_TEST_BINARY"' EXIT
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$TEST_BINARY" src/CountryFlagAsset.swift tests/FlagBadgeSmoke.swift
DYNAMICLAKE_PLUGIN_PACKAGE_PATH="$PWD/src" "$TEST_BINARY"

swiftc -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$PROTON_TEST_BINARY" src/Shared/DynamicLakeSocket.swift src/ProtonExit.swift tests/ProtonExitTests.swift
"$PROTON_TEST_BINARY"

swiftc -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$NORD_TEST_BINARY" src/NordServerLocation.swift tests/NordServerLocationTests.swift
"$NORD_TEST_BINARY"

swiftc -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$NE_TEST_BINARY" src/NEVPNWatcher.swift tests/NEVPNWatcherTests.swift
"$NE_TEST_BINARY"
