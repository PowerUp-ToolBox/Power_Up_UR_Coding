#!/usr/bin/env bash
# Builds the S1 spike two ways (see s1-macos-light-bar.md):
#   build/s1-light-bar                      raw command-line binary (ad-hoc signed)
#   build/S1LightBar.app                    ad-hoc signed bundle, id com.powerup.spike.s1lightbar
# The bundle id is deliberately NOT com.powerup.claudepad, so the spike never
# collides with the real app's TCC grants.
#
# Optional: S1_SIGN_IDENTITY="PowerUp Local Signing" ./build.sh signs both with
# the stable local identity from scripts/setup-signing.sh instead of ad-hoc.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build"
APP="$OUT/S1LightBar.app"
BUNDLE_ID="com.powerup.spike.s1lightbar"
EXE="s1-light-bar"

rm -rf "$OUT"
mkdir -p "$OUT" "$APP/Contents/MacOS"

echo "==> swiftc $(swiftc --version 2>&1 | head -1)"
swiftc -O -swift-version 5 -o "$OUT/$EXE" "$HERE/main.swift"

cp "$OUT/$EXE" "$APP/Contents/MacOS/$EXE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>S1LightBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>GCSupportsControllerUserInteraction</key>
    <true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -n "${S1_SIGN_IDENTITY:-}" ]; then
    echo "==> signing with identity '$S1_SIGN_IDENTITY'"
    security unlock-keychain -p powerup-local powerup-signing.keychain 2>/dev/null || true
    codesign --force --sign "$S1_SIGN_IDENTITY" --keychain powerup-signing.keychain "$OUT/$EXE"
    codesign --force --deep --sign "$S1_SIGN_IDENTITY" --keychain powerup-signing.keychain "$APP"
else
    echo "==> ad-hoc signing"
    codesign --force --sign - --identifier "$BUNDLE_ID.raw" "$OUT/$EXE"
    codesign --force --deep --sign - "$APP"
fi

codesign -dv "$OUT/$EXE" 2>&1 | grep -E 'Identifier|Signature' || true
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true
codesign --verify --strict "$APP" && echo "==> bundle signature verifies"
echo "==> built:"
echo "    $OUT/$EXE"
echo "    $APP"
