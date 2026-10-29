#!/bin/bash
# Builds the universal DMG and publishes it as a GitHub release.
#   ./scripts/release.sh 1.0.1
# The asset is uploaded twice: "SuperConverter-<version>.dmg" and a stable "SuperConverter.dmg", which UpdateKit downloads
# from (https://github.com/udsy19/super-converter/releases/latest/download/SuperConverter.dmg). The notes end with the
# line UpdateKit verifies the download against: SHA-256 (SuperConverter.dmg): `<hex>`.
# Signing (ARCHITECTURE §7): with DEVELOPER_ID and NOTARY_PROFILE set, Developer ID signed, notarised and stapled
# (make-dmg.sh); otherwise the project-local identity (scripts/signing-setup.sh). The updater only installs updates
# signed by the same identity as the running copy, so whichever the first public release uses must never change.
# Adapted from super-pdf scripts/release.sh (commit 2079863): names, the vendor libraries and bundled executables fetched
# when missing, and no one-line installer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION="${1:?usage: release.sh <version>}"
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }
if [ -n "${DEVELOPER_ID:-}" ]; then
  [ -n "${NOTARY_PROFILE:-}" ] || { echo "DEVELOPER_ID is set but NOTARY_PROFILE isn't: a Developer ID release is notarised (xcrun notarytool store-credentials)" >&2; exit 1; }
else
  [ -f "$ROOT/.signing/super-converter.keychain-db" ] || { echo "No signing identity: set DEVELOPER_ID and NOTARY_PROFILE, or run scripts/signing-setup.sh (once, and keep .signing/)" >&2; exit 1; }
  echo "warning: releasing self-signed (not notarised): Gatekeeper will ask people to Open Anyway" >&2
fi
scripts/fetch-vendor.sh
[ -x "$ROOT/Vendor/Tools/ffmpeg" ] || scripts/tools.sh fetch
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD=$(( $(git rev-list --count HEAD) + 1 )); /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
git add Resources/Info.plist
git diff --cached --quiet || git commit -q -m "Release $VERSION"
git push -q origin HEAD
./scripts/make-dmg.sh
cp "dist/SuperConverter-$VERSION.dmg" dist/SuperConverter.dmg
SHA=$(shasum -a 256 dist/SuperConverter.dmg | cut -d' ' -f1)
NOTES=$(awk -v v="$VERSION" '$0 ~ "^## \\["v"\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md)
git tag -s "v$VERSION" -m "Super Converter $VERSION" 2>/dev/null || git tag "v$VERSION" -m "Super Converter $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "dist/SuperConverter-$VERSION.dmg" dist/SuperConverter.dmg --title "Super Converter $VERSION" \
  --notes "$NOTES

SHA-256 (SuperConverter.dmg): \`$SHA\`"
