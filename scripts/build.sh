#!/usr/bin/env bash
# Builds PowerUp.app from the SwiftPM package and ad-hoc signs it.
# Run from the repository root: ./scripts/build.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="PowerUp"
BUNDLE_ID="com.powerup.claudepad"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building $APP_NAME (release, arm64)…"
swift build -c release --arch arm64

ICON_PATH="$BUILD_DIR/AppIcon.icns"
mkdir -p "$BUILD_DIR"
if [ ! -f "$ICON_PATH" ] || [ "${REGEN_ICON:-0}" = "1" ]; then
    echo "==> Generating app icon"
    ICONGEN_TMP="$(mktemp -d)"
    trap 'rm -rf "$ICONGEN_TMP"' EXIT
    swiftc "$ROOT_DIR/scripts/IconGen.swift" -o "$ICONGEN_TMP/icongen"
    "$ICONGEN_TMP/icongen" "$ICON_PATH"
fi

echo "==> Assembling app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

BIN_PATH=".build/arm64-apple-macosx/release/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "==> Copying app icon"
cp "$ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

echo "==> Writing Info.plist"
cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>GCSupportsControllerUserInteraction</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>PowerUp uses the microphone so you can speak instructions to Claude Code using push-to-talk.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>PowerUp uses speech recognition to turn what you say into text sent to Claude Code.</string>
</dict>
</plist>
PLIST

# Prefer a STABLE self-signed identity (scripts/setup-signing.sh) so macOS
# Accessibility/TCC grants survive rebuilds; fall back to ad-hoc otherwise.
SIGN_KEYCHAIN="powerup-signing.keychain"
SIGN_IDENTITY="PowerUp Local Signing"
if security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> Signing $APP_BUNDLE with stable identity '$SIGN_IDENTITY'"
    security unlock-keychain -p powerup-local "$SIGN_KEYCHAIN" 2>/dev/null || true
    codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP_BUNDLE"
else
    echo "==> Ad-hoc signing $APP_BUNDLE  (run ./scripts/setup-signing.sh once for a stable identity so Accessibility grants persist)"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Done."
echo "Launch the app as a bundle (never run the raw binary — this can misattribute TCC permissions):"
echo "    open \"$APP_BUNDLE\""
