#!/bin/bash
# Build the VPN Status DynamicLake plugin:
#   arm64 + x86_64 slices -> lipo universal binary -> assemble package -> zip
# Run from anywhere:  src/build.sh
set -euo pipefail
cd "$(dirname "$0")"

PKG="../VPNStatus.dynamiclakeplugin"
ZIP="../VPNStatus.dynamiclakeplugin.zip"
SLICE_DIR=$(mktemp -d)
trap 'rm -rf "$SLICE_DIR"' EXIT

SOURCES=(Shared/DynamicLakeSocket.swift VPNStatusIcons.swift CountryFlagAsset.swift CountryLabel.swift RouteTable.swift ProtonExit.swift NordServerLocation.swift NEVPNWatcher.swift PathWatcher.swift VPNStatusPlugin.swift)
NE_FLAGS=(-framework NetworkExtension -framework Network -framework AppKit)

echo "==> Compiling arm64 slice"
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 "${NE_FLAGS[@]}" \
    -o "$SLICE_DIR/vpn-arm64" "${SOURCES[@]}"

echo "==> Compiling x86_64 (Intel) slice"
swiftc -parse-as-library -O -target x86_64-apple-macosx14.0 "${NE_FLAGS[@]}" \
    -o "$SLICE_DIR/vpn-x86_64" "${SOURCES[@]}"

echo "==> Merging universal binary (lipo)"
lipo -create -output "$SLICE_DIR/vpn-status" \
    "$SLICE_DIR/vpn-arm64" "$SLICE_DIR/vpn-x86_64"
lipo -info "$SLICE_DIR/vpn-status"

# lipo keeps whatever signature each slice arrived with, and `ld` only
# ad-hoc-signs the arm64 slice — the Intel half went into the package unsigned,
# which fails validation on an Intel Mac or a quarantined download. Sign the fat
# file ad hoc (one identity for both halves) and prove both slices verify.
echo "==> Signing the universal binary (ad-hoc, both slices)"
codesign --force --sign - --identifier com.nebulark.vpn-status "$SLICE_DIR/vpn-status"
codesign --verify --strict --arch arm64 "$SLICE_DIR/vpn-status"
codesign --verify --strict --arch x86_64 "$SLICE_DIR/vpn-status"
echo "    both slices verify"

echo "==> Assembling $PKG (fresh folder, current timestamp)"
rm -rf "$PKG.old"
[ -e "$PKG" ] && mv "$PKG" "$PKG.old"
mkdir -p "$PKG"
cp "$SLICE_DIR/vpn-status" "$PKG/vpn-status"
cp plugin.json "$PKG/plugin.json"
cp icon.png "$PKG/icon.png"
cp -R flags "$PKG/flags"
chmod +x "$PKG/vpn-status"
cp "$SLICE_DIR/vpn-status" vpn-status   # keep the src copy of the build in sync
rm -rf "$PKG.old"
touch "$PKG"   # stamp the package folder itself with the build time

echo "==> Packaging $ZIP"
# --norsrc/--noextattr keep AppleDouble (._*) entries out of the archive:
# macOS tags downloaded files with com.apple.provenance, and ditto would
# otherwise add one ~4 KB resource entry per flag inside the package.
ditto -c -k --keepParent --norsrc --noextattr "$PKG" "$ZIP"
touch "$ZIP"

echo "==> Done. Install via DynamicLake Playground > Settings > Plugins > Install Local"
