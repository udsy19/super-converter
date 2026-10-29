#!/bin/bash
# Produces dist/SuperConverter-<version>.dmg: universal (Apple silicon + Intel) app, drag-to-Applications layout and
# install notes. With DEVELOPER_ID ("Developer ID Application: …") and NOTARY_PROFILE (a `xcrun notarytool
# store-credentials` profile) set, the app and the DMG are Developer ID signed, notarised and stapled (ARCHITECTURE §7),
# so Gatekeeper opens it directly; without them the app is self-signed and the notes explain "Open Anyway".
# Adapted from super-pdf scripts/make-dmg.sh (commit 2079863): names and the install notes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

NOTARISE=0
if [ -n "${DEVELOPER_ID:-}" ] || [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ] || { echo "error: set both DEVELOPER_ID and NOTARY_PROFILE to notarise" >&2; exit 1; }
  NOTARISE=1
fi
UNIVERSAL=1 ./scripts/build-app.sh

STAGE="$ROOT/build/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "build/Super Converter.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ "$NOTARISE" = 1 ]; then
cat > "$STAGE/Install Super Converter.txt" <<TXT
Installing Super Converter $VERSION
================================

1. Drag Super Converter into the Applications folder.
2. Open Super Converter from Applications.
3. Drop any file on the window, the Dock icon or the menu-bar icon. Everything happens on your Mac.

Finder's Quick Actions (Convert with Super Converter…, Convert to JPG, PNG, PDF, MP4 and MP3) appear
after the first launch; turn them on in System Settings → General → Login Items & Extensions if they don't.

Requirements: macOS 14 Sonoma or later, Apple silicon or Intel.
TXT
else
cat > "$STAGE/Install Super Converter.txt" <<TXT
Installing Super Converter $VERSION
================================

1. Drag Super Converter into the Applications folder.
2. Open Super Converter from Applications. macOS will say it "cannot be opened" because the app
   is not notarized by Apple. Click Done.
3. Open System Settings → Privacy & Security, scroll down and click "Open Anyway" next to
   the Super Converter message, then confirm with your password.
   (Alternatively, in Terminal: xattr -dr com.apple.quarantine "/Applications/Super Converter.app")
4. Drop any file on the window, the Dock icon or the menu-bar icon. Everything happens on your Mac.

Finder's Quick Actions (Convert with Super Converter…, Convert to JPG, PNG, PDF, MP4 and MP3) appear
after the first launch; turn them on in System Settings → General → Login Items & Extensions if they don't.

Requirements: macOS 14 Sonoma or later, Apple silicon or Intel.
TXT
fi

mkdir -p dist
DMG="dist/SuperConverter-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "Super Converter $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
if [ "$NOTARISE" = 1 ]; then
  codesign -f -s "$DEVELOPER_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
