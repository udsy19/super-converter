#!/bin/bash
# Packages the Mac App Store edition (docs/app-store/README.md):
#   scripts/build-app.sh with DISTRIBUTION=appstore (SwiftPM -DAPP_STORE build → .app → nested code signed inside out with
#   the Store entitlements) → productbuild --component → build/appstore/SuperConverter-<version>.pkg, signed for upload.
#
#   ADHOC=1 scripts/package-appstore.sh     ad-hoc-signed, sandboxed build/appstore/Super Converter.app for local testing
#                                           (no .pkg: an unsigned installer can't be uploaded)
#   scripts/package-appstore.sh             the uploadable .pkg; needs, from the environment:
#       APPSTORE_APP_IDENTITY        "Apple Distribution: <name> (<TEAMID>)" (or "3rd Party Mac Developer Application: …")
#       APPSTORE_INSTALLER_IDENTITY  "3rd Party Mac Developer Installer: <name> (<TEAMID>)" (or "Mac Installer Distribution: …")
#       APPSTORE_PROVISIONING_PROFILE  path to the Mac App Store provisioning profile for the Store bundle id
#   UNIVERSAL=1 (default here) builds arm64 + x86_64; UNIVERSAL=0 builds this Mac's architecture only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
export DISTRIBUTION=appstore UNIVERSAL="${UNIVERSAL:-1}"
APP="$ROOT/build/appstore/Super Converter.app"

if [ "${ADHOC:-0}" = 1 ]; then
  unset APPSTORE_APP_IDENTITY APPSTORE_PROVISIONING_PROFILE
  "$ROOT/scripts/build-app.sh"
  echo "Ad-hoc sandboxed Store edition: $APP (for local testing only; not uploadable)"
  exit 0
fi

missing=()
for var in APPSTORE_APP_IDENTITY APPSTORE_INSTALLER_IDENTITY APPSTORE_PROVISIONING_PROFILE; do
  [ -n "${!var:-}" ] || missing+=("$var")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "error: missing ${missing[*]}." >&2
  echo "  The Store package needs an Apple Distribution (or 3rd Party Mac Developer Application) identity, a Mac Installer" >&2
  echo "  Distribution (or 3rd Party Mac Developer Installer) identity in your keychain, and a Mac App Store provisioning" >&2
  echo "  profile for com.udsy.superconverter.appstore. Use ADHOC=1 for a local sandboxed test build." >&2
  exit 1
fi
[ -f "$APPSTORE_PROVISIONING_PROFILE" ] || { echo "error: no provisioning profile at $APPSTORE_PROVISIONING_PROFILE" >&2; exit 1; }
grep -qF "$APPSTORE_INSTALLER_IDENTITY" <<< "$(security find-identity -v)" || { echo "error: APPSTORE_INSTALLER_IDENTITY \"$APPSTORE_INSTALLER_IDENTITY\" is not in your keychains" >&2; exit 1; }

# The Store entitlements plus the application and team identifiers the profile grants (App Store Connect checks that the
# signature's entitlements match the profile).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sc-appstore.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
security cms -D -i "$APPSTORE_PROVISIONING_PROFILE" > "$WORK/profile.plist"
TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")"
BUNDLE_ID="$(awk -F= '/^APPSTORE_BUNDLE_ID=/ { print $2; exit }' "$ROOT/scripts/build-app.sh")"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$WORK/profile.plist")"
[ "$PROFILE_APP_ID" = "$TEAM.$BUNDLE_ID" ] || { echo "error: the profile is for $PROFILE_APP_ID, not $TEAM.$BUNDLE_ID" >&2; exit 1; }
for kind in app ext; do
  src="$ROOT/Resources/SuperConverter-AppStore.entitlements"; id="$BUNDLE_ID"
  [ $kind = ext ] && src="$ROOT/Resources/QuickActions.entitlements" && id="$BUNDLE_ID.quickactions.*"
  cp "$src" "$WORK/$kind.entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$id" \
                          -c "Add :com.apple.developer.team-identifier string $TEAM" "$WORK/$kind.entitlements"
done
# Each Quick Action gets its own exact application identifier.
export APPSTORE_ENTITLEMENTS="$WORK/app.entitlements" APPSTORE_EXT_ENTITLEMENTS="$WORK/ext.entitlements"
"$ROOT/scripts/build-app.sh"
for ext in "$APP"/Contents/PlugIns/*.appex; do
  id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$ext/Contents/Info.plist")"
  cp "$ROOT/Resources/QuickActions.entitlements" "$WORK/one.entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$id" \
                          -c "Add :com.apple.developer.team-identifier string $TEAM" "$WORK/one.entitlements"
  codesign -f -s "$APPSTORE_APP_IDENTITY" --entitlements "$WORK/one.entitlements" "$ext"
done
codesign -f -s "$APPSTORE_APP_IDENTITY" --entitlements "$WORK/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PKG="$ROOT/build/appstore/SuperConverter-$VERSION.pkg"
productbuild --component "$APP" /Applications --sign "$APPSTORE_INSTALLER_IDENTITY" "$PKG"
pkgutil --check-signature "$PKG"
echo "Built $PKG. Upload with Transporter or: xcrun altool --upload-app -f \"$PKG\" -t macos (needs Xcode)."
