# Super Converter — Mac App Store edition

**Status: CODE COMPLETE / CREDENTIALS REQUIRED** (2026-11-12, branch `release/macos-app-store`). The sandboxed Store
edition builds, launches, and converts 83 of 87 representative files under the real App Sandbox (the other 4 are
correct refusals). Not signed for the Store, not uploaded: no identities or profiles, no Xcode (asset catalog). Owner
decisions are listed in known-blockers.md.

## Commands

```bash
# Local sandboxed test build (ad hoc): build/appstore/Super Converter.app (arm64; UNIVERSAL=1 for both slices)
DISTRIBUTION=appstore scripts/build-app.sh
ADHOC=1 UNIVERSAL=0 scripts/package-appstore.sh        # same, via the package script

# Uploadable package (needs credentials): build/appstore/SuperConverter-<version>.pkg
APPSTORE_APP_IDENTITY="Apple Distribution: … (TEAMID)" \
APPSTORE_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: … (TEAMID)" \
APPSTORE_PROVISIONING_PROFILE=~/profiles/SuperConverter_AppStore.provisionprofile \
scripts/package-appstore.sh

# Direct edition: unchanged
scripts/build-app.sh
```

## Sandbox tests (docs/app-store/sandbox-tests)

```bash
DISTRIBUTION=appstore scripts/build-app.sh
swift build -c release -Xswiftc -DAPP_STORE --scratch-path .build-appstore --product sconv
docs/app-store/sandbox-tests/make-harness.sh /tmp/sc-harness          # sandboxed sconv in a copy of the Store app
docs/app-store/sandbox-tests/run-matrix.sh "/tmp/sc-harness/Super Converter.app" docs/app-store/sandbox-tests/cases.txt
/usr/bin/log show --predicate 'sender == "Sandbox"' --last 10m | grep -E 'sconv|SuperConverter'
```
Results: test-results.md.

## Human runs (GUI; not automated here)

1. Open `build/appstore/Super Converter.app`. Drop a JPG from Desktop on the window, convert to PNG → result lands in
   Downloads (Desktop not granted) with the "saved in Downloads" notice.
2. File › Add Files…, choose a **folder** on Desktop, convert a file in it → result next to the original. Quit, relaunch,
   convert again from that folder → still next to the original (bookmark restored).
3. Settings › General › Save To › choose a folder; quit/relaunch; convert → result in that folder.
4. Finder › right-click a HEIC in a never-granted folder › Quick Actions › Convert to JPG → "Allow" panel at that folder →
   Allow → JPG next to the HEIC, notification shown. Repeat in the same folder → no panel.
5. App menu › Import Settings from Another Copy… → panel opens at `~/Library/Preferences`, pick
   `com.udsy.superconverter.plist` → "Imported N settings".
6. Settings › Helpers shows the neutral explanation (no link); Settings › Quick Actions points to System Settings; About has no
   update rows; the app menu has no "Check for Updates…".
Check `log show --predicate 'sender == "Sandbox"' --last 10m` after each for `SuperConverter` denials.

## Documents

compliance-matrix.md · architecture.md · dependency-and-license-audit.md · entitlements.md · model-and-asset-strategy.md ·
privacy-and-permissions.md · test-results.md · app-store-connect.md · review-notes.md · known-blockers.md · inventory.json

## Size

Store app (arm64, ad hoc): **231 MB** on disk (Helpers 147 MB — universal ffmpeg/ffprobe/7zz; MacOS 31 MB; PlugIns 36 MB
— six copies of the Quick Action executable; Resources 15 MB; Frameworks 2.3 MB); 96 MB zipped. A universal build adds
~65 MB (app and extension executables); the direct universal app is 310 MB.
