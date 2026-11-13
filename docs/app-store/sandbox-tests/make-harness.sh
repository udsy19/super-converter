#!/bin/bash
# Builds the sandboxed test harness in $1: a copy of the Store app (build/appstore, from DISTRIBUTION=appstore
# scripts/build-app.sh) whose main executable is the APP_STORE `sconv`, signed with the Store app's entitlements and
# bundle id, so conversions run under the same App Sandbox profile, container and Contents/Helpers tools as the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
H="$1"
[ -d "$ROOT/build/appstore/Super Converter.app" ] || { echo "error: run DISTRIBUTION=appstore scripts/build-app.sh first" >&2; exit 1; }
(cd "$ROOT" && swift build -c release -Xswiftc -DAPP_STORE --scratch-path "$ROOT/.build-appstore" --product sconv >&2)
BIN="$(cd "$ROOT" && swift build -c release -Xswiftc -DAPP_STORE --scratch-path "$ROOT/.build-appstore" --show-bin-path)"
rm -rf "$H/Super Converter.app"; mkdir -p "$H"
cp -R "$ROOT/build/appstore/Super Converter.app" "$H/"
APP="$H/Super Converter.app"
# sconv replaces the app executable (a second Mach-O in Contents/MacOS would fail codesign --strict), and the
# extensions are left out: the harness must not register Quick Actions.
rm -rf "$APP/Contents/MacOS/SuperConverter" "$APP/Contents/PlugIns"
cp "$BIN/sconv" "$APP/Contents/MacOS/sconv"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/sconv" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable sconv" "$APP/Contents/Info.plist"
codesign -f -s - --entitlements "$ROOT/Resources/SuperConverter-AppStore.entitlements" "$APP"
codesign --verify --strict "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q com.apple.security.app-sandbox
echo "$APP"
