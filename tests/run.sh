#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./src/build.sh
python3 tests/test_runtime.py

TEST_BINARY=$(mktemp -t vpn-flag-smoke)
trap 'rm -f "$TEST_BINARY"' EXIT
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$TEST_BINARY" src/CountryFlagAsset.swift tests/FlagBadgeSmoke.swift
DYNAMICLAKE_PLUGIN_PACKAGE_PATH="$PWD/src" "$TEST_BINARY"
