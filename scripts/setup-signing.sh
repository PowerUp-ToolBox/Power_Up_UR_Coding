#!/bin/bash
# Creates a STABLE self-signed code-signing identity for PowerUp, so macOS
# Accessibility / TCC grants survive rebuilds.
#
# WHY: ad-hoc signing (codesign -s -) gives every rebuild a new cdhash, and
# macOS binds Accessibility permission to that exact hash — so the grant is lost
# on the next build and you must re-grant every time. A stable self-signed
# certificate makes the codesign "designated requirement" constant
# (identifier + certificate), so you grant access ONCE and it sticks forever.
#
# NOTE: cmux remote targets do NOT need Accessibility at all. Run this only if
# you want to drive a Frontmost/Specific *app* via keystroke injection, or to
# make the Accessibility indicator behave.
#
# This is idempotent and uses a DEDICATED keychain (never your login keychain).
# It asks for your macOS password ONCE — at the "trust this certificate" step,
# because marking a certificate as trusted for code signing is a protected
# action. Run it from a real Terminal / cmux shell so that dialog can appear.
set -euo pipefail

IDENTITY_NAME="PowerUp Local Signing"
KEYCHAIN="powerup-signing.keychain"
KEYCHAIN_DB="$HOME/Library/Keychains/${KEYCHAIN}-db"
KEYCHAIN_PW="powerup-local"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "✓ Stable signing identity already set up. Nothing to do."
    echo "  Rebuild with ./scripts/build.sh and it will use it automatically."
    exit 0
fi

echo "→ Generating self-signed code-signing certificate…"
cat > "$WORK/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = PowerUp Local Signing
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/cert.cnf" >/dev/null 2>&1

# Legacy PBE algorithms — required so macOS `security` can import the .p12.
openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -name "$IDENTITY_NAME" -passout pass:powerup \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "→ Creating dedicated keychain and importing the identity…"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P powerup -T /usr/bin/codesign -A >/dev/null 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null 2>&1

# Keep our keychain in the user search list without dropping the login keychain.
CURRENT_KCS="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
if ! printf '%s\n' "$CURRENT_KCS" | grep -q "$KEYCHAIN"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $CURRENT_KCS "$KEYCHAIN_DB" >/dev/null 2>&1
fi

echo
echo "→ Trusting the certificate for code signing."
echo "  macOS will now ask for your login password (once). Enter it to continue."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN_DB" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$IDENTITY_NAME"; then
    echo "✓ Done — stable signing identity is ready:"
    security find-identity -v -p codesigning "$KEYCHAIN" | grep "$IDENTITY_NAME"
    echo
    echo "Next:"
    echo "  1) ./scripts/build.sh          # rebuilds, now stably signed"
    echo "  2) tccutil reset Accessibility com.powerup.claudepad   # clear stale grant"
    echo "  3) open build/PowerUp.app, grant Accessibility once — it will persist."
else
    echo "✗ Something went wrong — the identity is not valid yet."
    echo "  Re-run this script, and make sure you approved the password dialog."
    exit 1
fi
