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
| Child-process confinement | `sandbox-exec` profile per run (`ProcessRunner`) | the App Sandbox (inherited); `sandbox-exec` is not run (`Sandbox.isEnforced == false`) because a sandboxed process may not apply a second profile (`forbidden-sandbox-reinit`, test-results.md) |
| Inputs to bundled tools | paths as given | `BundledTools.staged`: every input file outside the container and bundle is cloned (APFS clone) into the job's work folder first; tools read and write only container files, the app moves results (OutputRules) |
| Outside helpers (LibreOffice, calibre, Pandoc, Tectonic, Ghostscript, DjVuLibre, ODA, LibreDWG, GPL FFmpeg, RAR, sfArk) | detected / one-click installed / run | none: `HelperRuntime.refresh` reports every helper unusable with `Distribution.helpersUnavailable`; `HelperPins.all` is empty; `HelperInstaller` is a throwing stub; Settings › Helpers explains and links to the direct download |
| iWork / Microsoft Office via Apple Events | yes (`osascript`) | no: `HelperService.automate` throws; no `apple-events` entitlement; no `NSAppleEventsUsageDescription` |
| Updater (UpdateKit) | GitHub Releases, download + replace | compiled out (`#if !APP_STORE` around all UpdateKit sources; no "Check for Updates" menu or About rows); the build fails if `api.github.com` is in the binary |
| Disk images (DMG) | `hdiutil attach` | 7-Zip (`hdiutil` is denied by the sandbox; `DiskImageReader` falls back) |
| Quick Action switches in Settings | `pluginkit -e use/ignore` | System Settings only (pkd refuses sandboxed clients) |
| Results "next to the original" | yes | yes when the folder is granted (dropped/chosen folder, Save To folder, or the folder granted for a Quick Action); otherwise Downloads (the existing fall-back, now sandbox-aware because `access(W_OK)` honours the sandbox) |
| Save To folder | path in defaults | path + app-scoped security-scoped bookmark (`FolderAccess`), restored at launch |
| Quick Actions / Services handing over paths | read directly | if the app can't read them, an open panel at their folder asks once ("Allow"), and the folder is remembered |
| Settings import | n/a | "Import Settings from the Direct Download…" (app menu): open panel at `~/Library/Preferences/com.udsy.superconverter.plist`, copies format choices, saved options, Save To and switches into the Store edition's defaults; nothing of the direct edition changes |

## Data

The sandbox puts `~/Library/Application Support/Super Converter/` (Jobs work folders, recent.json) and the caches inside
`~/Library/Containers/com.udsy.superconverter.appstore/Data/`. Temporary files (`FileManager.temporaryDirectory`, the
tools' private TMPDIR) are the container's `tmp`. The direct edition's data is never moved or deleted; there is no
`container-migration.plist` (different bundle ids; settings come over only by the explicit import). TCC/automation grants
do not carry over between editions.

## Deviation from the shared brief (recorded as asked)

- **Child processes and user grants (ADDENDUM 2).** The brief states a child does not inherit the parent's dynamic
  grants. Our experiment on macOS 26.5.1 (test-results.md, "Grant inheritance") found that an `inherit`-signed
  `ffprobe` *did* read a file whose sandbox extension the parent had consumed before spawning it. We still implement
  the brief's model (stage input copies in the container, tools write only to the work folder, the parent moves
  results) because the observed behaviour is undocumented and would not cover grants obtained after a child started.
  Cost: an APFS clone per input (free on the same volume; a real copy across volumes).
- **FFmpeg "dynamically linked" (ADDENDUM 8).** Our FFmpeg is a separate executable (not linked into the app at all);
  its LGPL components are statically linked *inside that executable*, which is itself LGPL and replaceable (source and
  build script published). It is not a shared-library build. See dependency-and-license-audit.md, owner decisions.
- **Hardened Runtime** is off for the Store edition (not required on the Mac App Store). With it on, an ad-hoc test
  build can't load `libraw_r.dylib` (no Team ID) without `disable-library-validation`, which the Store edition must not
  have. A Store-signed build has app and dylib under one Team ID either way.
