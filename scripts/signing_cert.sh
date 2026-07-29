#!/usr/bin/env bash
# Creates a self-signed code-signing certificate, once, so PasteDeck keeps its
# Accessibility permission across rebuilds.
#
# The problem it solves: `codesign -s -` (ad-hoc) gives the app no identity, so
# the requirement macOS records with the Accessibility grant is the code hash.
# Rebuild and the hash changes, the grant stops matching, and ⌘V quietly stops
# working while System Settings still shows the switch on.
#
# With a certificate the requirement becomes
#     identifier "app.pastedeck" and certificate leaf[subject.CN] = "…"
# which is the same before and after every build.
#
# This writes to your login keychain and marks the certificate as trusted for
# code signing, so macOS will ask for your login password. To undo it, delete
# "PasteDeck Local Signing" in Keychain Access.
set -euo pipefail

NAME="PasteDeck Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "==> “$NAME” already exists"
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    echo "==> Generating a code-signing certificate"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
        -subj "/CN=$NAME" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

    openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/identity.p12" -passout pass:

    echo "==> Importing into the login keychain (codesign gets access)"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" \
        -T /usr/bin/codesign -T /usr/bin/security

    echo "==> Trusting it for code signing — macOS will ask for your password"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

    # Without this codesign gets an "unknown error -1" the first time it wants
    # the private key from a non-interactive shell.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" >/dev/null 2>&1 || true
fi

cat <<NOTE

==> Done. Build and install with it from now on:

      SIGN_IDENTITY="$NAME" make install

    Grant Accessibility once after the next install and it will stick:
      System Settings ▸ Privacy & Security ▸ Accessibility
NOTE
