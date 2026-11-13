# Mac App Store edition — architecture

One codebase, two editions. `swift build -Xswiftc -DAPP_STORE` (via `DISTRIBUTION=appstore scripts/build-app.sh`, in its
own build folder `.build-appstore`) produces the Store edition; without the flag everything is the direct-download
edition, unchanged. `Distribution.isAppStore` (SuperConverterCore/Distribution.swift) is the runtime mirror of the flag
for UI branches; code that must not exist in the Store binary uses `#if APP_STORE` / `#if !APP_STORE`.

| | Direct download | Mac App Store |
|---|---|---|
| Bundle id | `com.udsy.superconverter` | `com.udsy.superconverter.appstore` (`APPSTORE_BUNDLE_ID` in scripts/build-app.sh, mirrored by `SuperConverterPaths.bundleID`; the build fails if they differ) |
| Quick Actions ids | `com.udsy.superconverter.quickactions.<Action>` | `com.udsy.superconverter.appstore.quickactions.<Action>` |
| Output bundle | `build/Super Converter.app` | `build/appstore/Super Converter.app`, `.pkg` from `scripts/package-appstore.sh` |
| Sandbox | no (Hardened Runtime) | yes, `Resources/SuperConverter-AppStore.entitlements` |
| Bundled `ffmpeg`/`ffprobe`/`7zz` | `Contents/Helpers`, hardened runtime | `Contents/Helpers`, signed `app-sandbox` + `inherit` (`Resources/SuperConverter-AppStore-Helper.entitlements`); main app never has `inherit` |
| Child-process confinement | `sandbox-exec` profile per run (`ProcessRunner`): no network, writes only to the work folder | the App Sandbox (inherited) only; `sandbox-exec` is not run (`Sandbox.isEnforced == false`) because a sandboxed process may not apply a second profile (`forbidden-sandbox-reinit`, test-results.md). **Consequence:** a bundled tool is no longer held to the work folder by its own profile; it may write anywhere the app itself may (the container, Downloads, folders the person granted). Tools are only ever given work-folder output paths, and inputs are staged copies, so in practice they write only in the work folder |
| Inputs to bundled tools | paths as given | `ToolStaging.stage` (Core): every input file outside the container and bundle becomes one copy per job and source in `Jobs/<id>/.staged/` (an APFS clone on the same volume, a real copy otherwise, counted in JobRunner's free-space check), shared by all of the job's tool runs; `BundledTools` stages every path argument, `MediaRun` stages the source and the subtitle file before FFmpeg's filter strings name them; a copy that can't be made fails the conversion; results are moved by the app (OutputRules) |
| Outside helpers (LibreOffice, calibre, Pandoc, Tectonic, Ghostscript, DjVuLibre, ODA, LibreDWG, GPL FFmpeg, RAR, sfArk) | detected / one-click installed / run | none: `HelperRuntime.refresh` reports every helper unusable with `Distribution.helpersUnavailable` (neutral wording); `HelperPins.all`, `HelperCatalog`'s install places and pages and `HelperDetector`'s Homebrew places are empty; `HelperInstaller` is a throwing stub; Settings › Helpers only explains (no link) |
| iWork / Microsoft Office via Apple Events | yes (`osascript`) | no: the AppleScript code is compiled out, `HelperService.automate` throws; no `apple-events` entitlement; no `NSAppleEventsUsageDescription`. The build fails if `/opt/homebrew`, `/usr/local/`, `brew install`, `osascript`, `tell application`, hdiutil's `-mountrandom`, helper download hosts or `api.github.com` appear in the app or extension binary |
| Updater (UpdateKit) | GitHub Releases, download + replace | compiled out (`#if !APP_STORE` around all UpdateKit sources; no "Check for Updates" menu or About rows); the build fails if `api.github.com` is in the binary |
| Disk images (DMG) | `hdiutil attach` | 7-Zip (`hdiutil` is denied by the sandbox; `DiskImageReader` falls back) |
| Quick Action switches in Settings | `pluginkit -e use/ignore` | System Settings only (pkd refuses sandboxed clients) |
| Results "next to the original" | yes | yes when the folder is granted (dropped/chosen folder, Save To folder, or the folder granted for a Quick Action); otherwise Downloads (the existing fall-back, now sandbox-aware because `access(W_OK)` honours the sandbox) |
| Save To folder | path in defaults | path + app-scoped security-scoped bookmark (`FolderAccess`), restored at launch |
| Quick Actions / Services handing over paths | read directly | only for links from the app's own extensions or Services (`LinkOrigin.thisApp`): if the app can't read them, an open panel at the files' own folder (never a parent; nothing when they span folders) asks ("Allow"); one panel at a time, ≥ 5 s apart (`AccessRequests`); the folder is remembered. A `superconverter://` link from anywhere else never shows a panel |
| Settings import | n/a | "Import Settings from Another Copy…" (app menu): open panel at `~/Library/Preferences/com.udsy.superconverter.plist`, copies format choices, saved options, Save To and switches into the Store edition's defaults; nothing of the direct edition changes |

## Data

The sandbox puts `~/Library/Application Support/Super Converter/` (Jobs work folders, recent.json) and the caches inside
`~/Library/Containers/com.udsy.superconverter.appstore/Data/`. Temporary files (`FileManager.temporaryDirectory`, the
tools' private TMPDIR) are the container's `tmp`. The direct edition's data is never moved or deleted; there is no
`container-migration.plist` (different bundle ids; settings come over only by the explicit import). TCC/automation grants
do not carry over between editions.

## Deviation from the shared brief (recorded as asked)

- **Child processes and user grants (ADDENDUM 2).** Implemented as the brief says: tools read staged copies in the
  container and write to the work folder; the parent moves results. (An early experiment with a token from the private
  `sandbox_extension_issue_file` call let an `inherit` child read the file, but that is not how a real open panel or
  drop grants access, so it proves nothing about real grants; see test-results.md §3.) Cost: one copy per job and
  source (free as an APFS clone on the container's volume).
- **FFmpeg "dynamically linked" (ADDENDUM 8).** Our FFmpeg is a separate executable (not linked into the app at all),
  now LGPL-2.1-or-later (no `--enable-version3`); its LGPL components are statically linked *inside that executable*,
  which is itself LGPL, with complete source and a written offer. It is not a shared-library build.
- **Hardened Runtime** is off for the Store edition (not required on the Mac App Store). With it on, an ad-hoc test
  build can't load `libraw_r.dylib` (no Team ID) without `disable-library-validation`, which the Store edition must not
  have. A Store-signed build has app and dylib under one Team ID either way.
