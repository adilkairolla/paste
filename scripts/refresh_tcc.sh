#!/usr/bin/env bash
# Clears a stale Accessibility grant after an ad-hoc build replaces the app.
#
# An ad-hoc signature has no identity of its own, so the requirement macOS
# stores alongside the permission is the code hash itself:
#
#     designated => cdhash H"13dd4f8cc712ee6364084db62e08ee1265e0e8d7"
#
# Every rebuild produces a new hash. The old grant then matches nothing, but
# the row stays in System Settings with its switch still on — so the app looks
# authorised and silently can't press ⌘V. Resetting puts the switch back to off
# where it belongs, and the app can ask again.
#
# Skipped when the app is signed with a real certificate (see signing_cert.sh),
# because that requirement survives rebuilds and the grant is still good.
set -euo pipefail

APP="${1:-/Applications/PasteDeck.app}"
BUNDLE_ID="app.pastedeck"

if [[ ! -d "$APP" ]]; then
    exit 0
fi

requirement="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^# designated => //p')"

if [[ "$requirement" != *cdhash* ]]; then
    echo "==> Signed with a stable identity; Accessibility grant left alone"
    exit 0
fi

tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

cat <<'NOTE'
==> Ad-hoc build: Accessibility reset (the old grant was bound to the previous
    code hash and would have failed silently).

    Turn it back on to let Enter paste for you:
      System Settings ▸ Privacy & Security ▸ Accessibility ▸ + ▸ PasteDeck

    To stop re-granting after every build:  make signing-cert
NOTE
