#!/usr/bin/env bash
# Builds the Rust core bridge for the macOS app (stage 2.1, ADR 0012):
#   rust/build/PowerUpCoreFFI.xcframework   static library + C header/modulemap
#   rust/build/swift/PowerUpCore.swift       generated Swift bindings
# Package.swift always links them, so `swift build` and `swift test` need this
# script to have run first, and again after any change under rust/
# (scripts/build.sh runs it). Needs Rust (rustup) and a full Xcode (xcodebuild).
# Usage: ./scripts/build-core.sh [debug|release]   (default release)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust"
OUT_DIR="$RUST_DIR/build"
PROFILE="${1:-release}"
TARGET="aarch64-apple-darwin"
CRATE_LIB="libpowerup_core_ffi"

if ! command -v cargo >/dev/null 2>&1 && [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || {
    echo "error: cargo not found — install Rust from https://rustup.rs" >&2
    exit 1
}

case "$PROFILE" in
    release) CARGO_PROFILE_FLAG="--release" ;;
    debug) CARGO_PROFILE_FLAG="" ;;
    *) echo "error: profile must be debug or release, got '$PROFILE'" >&2; exit 1 ;;
esac

cd "$RUST_DIR"
# The app's deployment target, so the linker never warns about a newer one.
export MACOSX_DEPLOYMENT_TARGET=14.0

echo "==> Building powerup-core-ffi ($PROFILE, $TARGET)"
rustup target add "$TARGET" >/dev/null 2>&1 || true
# shellcheck disable=SC2086
cargo build -p powerup-core-ffi --target "$TARGET" $CARGO_PROFILE_FLAG
LIB_DIR="$RUST_DIR/target/$TARGET/$PROFILE"

echo "==> Generating Swift bindings"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/generated" "$OUT_DIR/swift" "$OUT_DIR/headers"
cargo run -q -p uniffi-bindgen -- generate \
    --library "$LIB_DIR/$CRATE_LIB.dylib" \
    --language swift \
    --out-dir "$OUT_DIR/generated"

cp "$OUT_DIR/generated/PowerUpCore.swift" "$OUT_DIR/swift/PowerUpCore.swift"
cp "$OUT_DIR/generated/PowerUpCoreFFI.h" "$OUT_DIR/headers/PowerUpCoreFFI.h"
# A framework-less library needs its modulemap named module.modulemap.
cp "$OUT_DIR/generated/PowerUpCoreFFI.modulemap" "$OUT_DIR/headers/module.modulemap"

echo "==> Assembling PowerUpCoreFFI.xcframework"
xcodebuild -create-xcframework \
    -library "$LIB_DIR/$CRATE_LIB.a" \
    -headers "$OUT_DIR/headers" \
    -output "$OUT_DIR/PowerUpCoreFFI.xcframework" >/dev/null 2>"$OUT_DIR/xcodebuild.log" \
    || { cat "$OUT_DIR/xcodebuild.log" >&2; exit 1; }

echo "==> Core bridge ready in $OUT_DIR"
