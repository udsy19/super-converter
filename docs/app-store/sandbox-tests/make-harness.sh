#!/bin/bash
# Builds the sandboxed test harness: a copy of the ad-hoc Store app with the APP_STORE sconv in Contents/MacOS, signed with
# the Store app's entitlements and bundle id, so conversions run under the same App Sandbox profile and container.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
H="$1"   # harness folder
rm -rf "$H/Super Converter.app"; mkdir -p "$H"
cp -R "$ROOT/build/appstore/Super Converter.app" "$H/"
APP="$H/Super Converter.app"
BIN="$(cd "$ROOT" && swift build -c release -Xswiftc -DAPP_STORE --scratch-path "$ROOT/.build-appstore" --show-bin-path)"
cp "$BIN/sconv" "$APP/Contents/MacOS/sconv"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/sconv" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable sconv" "$APP/Contents/Info.plist"; rm -rf "$APP/Contents/PlugIns"
codesign -f -s - -i com.udsy.superconverter.appstore --entitlements "$ROOT/Resources/SuperConverter-AppStore.entitlements" "$APP/Contents/MacOS/sconv"
codesign -f -s - --entitlements "$ROOT/Resources/SuperConverter-AppStore.entitlements" "$APP"
codesign --verify --strict "$APP/Contents/MacOS/sconv"
codesign -d --entitlements :- "$APP/Contents/MacOS/sconv" 2>/dev/null | grep -c app-sandbox
