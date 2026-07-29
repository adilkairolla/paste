#!/usr/bin/env bash
# Builds PasteDeck.app. No Xcode required — SwiftPM plus a hand-assembled bundle.
#
#   ./scripts/build_app.sh                 release build for this Mac
#   CONFIG=debug ./scripts/build_app.sh    debug build
#   UNIVERSAL=1 ./scripts/build_app.sh     arm64 + x86_64
#   SIGN_IDENTITY="Developer ID…" ./scripts/build_app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PasteDeck"
BUNDLE_ID="app.pastedeck"
VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" is ad-hoc
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building ($CONFIG)"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product "$APP_NAME"
    BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product "$APP_NAME" --show-bin-path)/$APP_NAME"
else
    swift build -c "$CONFIG" --product "$APP_NAME"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

if [[ ! -f "Resources/AppIcon.icns" ]]; then
    echo "==> Rendering app icon"
    mkdir -p Resources
    swift scripts/make_icon.swift Resources >/dev/null
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <!-- Menu bar agent: no Dock icon, no menu bar takeover. -->
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
    <key>NSHumanReadableCopyright</key>      <string>Local build</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing ($SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>/dev/null \
    || codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> Built $APP"
