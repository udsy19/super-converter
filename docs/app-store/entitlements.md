# Entitlements

## Store edition — app (`Resources/SuperConverter-AppStore.entitlements`)

| Entitlement | Why |
|---|---|
| `com.apple.security.app-sandbox` | required |
| `com.apple.security.files.user-selected.read-write` | files and folders the person drops, opens or picks (Save To) are read and results written |
| `com.apple.security.files.downloads.read-write` | results fall back to Downloads when the original's folder isn't granted (existing ux §6.3 behaviour) |
| `com.apple.security.files.bookmarks.app-scope` | Save To folder and folders granted for Quick Actions survive relaunch |
| `com.apple.security.network.client` | WebKit (HTML → PDF/PNG) loads nothing, not even the local page, without it in a sandboxed app — measured (test-results.md §4). Pages reach no server unless the person turns on "Load web resources" for that file; nothing else opens a connection (no updater, no helper downloads, FFmpeg `--disable-network`) |

Not present, on purpose: `network.server`, `automation.apple-events`, `cs.disable-library-validation`, `cs.allow-unsigned-executable-memory`, any
`temporary-exception`, `inherit`. `scripts/build-app.sh` fails the Store build if any of these appear.

`scripts/package-appstore.sh` adds `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the
provisioning profile at signing time.

## Store edition — bundled executables (`Resources/SuperConverter-AppStore-Helper.entitlements`)

`Contents/Helpers/ffmpeg`, `ffprobe`, `7zz`: exactly `com.apple.security.app-sandbox` + `com.apple.security.inherit`.
The build checks each one.

## Store edition — Quick Action extensions (`Resources/QuickActions.entitlements`)

`com.apple.security.app-sandbox` only (unchanged from the direct edition; they read nothing and open a
`superconverter://` link).

## Direct edition (`Resources/SuperConverter.entitlements`) — unchanged

`automation.apple-events`, `cs.disable-library-validation`, Hardened Runtime, not sandboxed.

## Info.plist differences (applied by the build script)

Store: `CFBundleIdentifier` = `com.udsy.superconverter.appstore`; removed `NSAppleEventsUsageDescription` and the
Desktop/Documents/Downloads/removable/network-volume usage strings (meaningless inside the sandbox). Everything else
(document types, `superconverter://`, NSServices, UTType declarations, `LSApplicationCategoryType`) is shared.
