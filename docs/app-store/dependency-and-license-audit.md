# Dependency and licence audit — Mac App Store edition

Audited 2026-11-12 on branch `release/macos-app-store` against the files in the repo (`Tools.lock`, `Vendor.lock`,
`scripts/build-ffmpeg.sh`, `scripts/build-7zz.sh`, `THIRD_PARTY_NOTICES.md`) and the bundled binaries themselves
(`Vendor/Tools/ffmpeg -buildconf`, `Vendor/Tools/7zz i`). SwiftPM package dependencies: **none**.

This is an engineering record, not legal advice. The owner should get a licensing opinion on the two items marked
**OWNER DECISION** before submitting.

## How each engine reaches the app

| Engine | How it is invoked | Where it lives | Store edition |
|---|---|---|---|
| FFmpeg `ffmpeg`, `ffprobe` 7.1.5 | `Process` via HelperKit `BundledTools` → `ProcessRunner` (`/usr/bin/nice` → tool) | `Contents/Helpers/` (built by `scripts/build-ffmpeg.sh`, fetched by `scripts/tools.sh fetch` at **build** time, SHA-256 pinned in `Tools.lock`) | embedded, signed `app-sandbox` + `inherit` |
| 7-Zip `7zz` 25.01 | same runner | `Contents/Helpers/` (`scripts/build-7zz.sh`) | embedded, signed `app-sandbox` + `inherit` |
| LibRaw 0.21.5 | dynamic library linked by the app | `Contents/Frameworks/libraw_r.dylib` | embedded; same Team ID as app, so no `disable-library-validation` |
| libwebp, libavif (+SVT-AV1, libaom, dav1d), libarchive (+xz, zstd, lz4), libxls, woff2 (+brotli), unalz (+bzip2) | static xcframeworks linked into the app (`Vendor.lock`, `scripts/fetch-vendor.sh`) | in the app executable | in-process, no change |
| Apple frameworks (ImageIO, Core Image, AVFoundation, VideoToolbox, PDFKit, WebKit, JavaScriptCore, Vision, …) | in-process | system | in-process, sandbox-compatible (see test-results.md) |
| `/usr/bin/hdiutil` | runner, for DMG | system | sandbox denies the attach; ArchiveKit falls back to 7zz (see test-results.md) |
| `/usr/bin/pluginkit` | runner, Quick Action switches | system | see test-results.md |
| `/usr/bin/sandbox-exec` | ProcessRunner's per-tool profile | system | **not used** in the Store build (`Sandbox.isEnforced == false` under `APP_STORE`): the App Sandbox already confines children |
| LibreOffice, calibre, Pandoc, Tectonic, Ghostscript, DjVuLibre, ODA File Converter, LibreDWG, GPL FFmpeg, RAR, sfArk | `Process` on an executable found in `/Applications`, `~/Applications`, Homebrew (`/opt/homebrew`, `/usr/local`) or installed by the one-click installer (`HelperInstaller`: downloads pinned upstream builds at **run** time into `~/Library/Application Support/Super Converter/Helpers` or `~/Applications`) | outside the bundle | **compiled out / gated**: `HelperRuntime.refresh()` finds none, `HelperPins.all` is empty, `HelperInstaller` is a stub that throws, `HelperService.install` answers "not available" |
| Pages, Numbers, Keynote, Microsoft Office | Apple Events through `/usr/bin/osascript` | other apps | **gated**: `HelperService.automate` throws; no `apple-events` entitlement, no `NSAppleEventsUsageDescription` |
| UpdateKit (GitHub Releases updater, download-and-replace) | URLSession + replace on quit | app | **compiled out** (`#if !APP_STORE` around every UpdateKit source); the build fails if `api.github.com` appears in the Store binary |

There are no runtime tool downloads in the Store edition. `scripts/tools.sh` / `Tools.lock` and
`scripts/fetch-vendor.sh` / `Vendor.lock` are **build-time** fetches of pinned, checksummed artifacts that end up inside
the signed bundle; they are fine for the Store.

## FFmpeg build configuration (recorded exactly)

From `Vendor/Tools/ffmpeg -hide_banner -buildconf` (the binary that is bundled):

```
--enable-version3 --disable-gpl --disable-nonfree --disable-autodetect
--enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay
--disable-network --disable-indevs --enable-indev=lavfi --disable-outdevs
--enable-zlib --enable-bzlib --enable-iconv --enable-audiotoolbox --enable-videotoolbox
--enable-libvpx --enable-libsvtav1 --enable-libdav1d --enable-libopus --enable-libvorbis --enable-libtheora
--enable-libmp3lame --enable-libwebp --enable-libsoxr --enable-libzimg --enable-libass --enable-libfreetype
--enable-libharfbuzz --enable-libfribidi
```

- **No GPL code**: `--disable-gpl`, no x264/x265/xvid/rubberband/etc. `scripts/build-app.sh` fails the build if
  `--enable-gpl` or `--enable-nonfree` ever shows up (both editions).
- **No network**: `--disable-network` (matches the Store edition having no network entitlement).
- **Licence of the bundled executable: LGPL-3.0-or-later as a whole** because of `--enable-version3`. Static
  components: LAME (LGPL-2.0+), soxr (LGPL-2.1+), FriBidi (LGPL-2.1+), the rest BSD/MIT/ISC/FTL/WTFPL.
- The tool is a separate executable launched with `Process`, not linked into the app, so the app's own code is not a
  "combined work" with FFmpeg. Source for every component is published as `tools-sources.tar.gz` on the
  `tools-2026-10-29` release (pinned in `Tools.lock`), with a written offer in `THIRD_PARTY_NOTICES.md`.

### OWNER DECISION 1 — (L)GPLv3 FFmpeg in a Mac App Store app

The known GPL/App Store conflict is that Apple's Usage Rules impose restrictions on recipients that (L)GPL forbid
adding ("no further restrictions", GPLv3 §10/§12; LGPLv3 incorporates GPLv3). It is most acute for GPL; LGPL-licensed
FFmpeg builds do ship in Store apps, but **v3** adds the Installation Information clause and is the stricter variant.
Options, in order of increasing effort:
1. Ship as is (LGPL-3.0+ executable, source + offer published). Lowest effort; some legal risk.
2. Rebuild FFmpeg **without `--enable-version3`** (LGPL-2.1+ as a whole). Nothing in the current recipe needs v3
   (no opencore-amr/vo-amrwbenc/gmp), so this is a one-flag change in `scripts/build-ffmpeg.sh`; then republish the
   `tools-*` release and update `Tools.lock`. Recommended before submission. Not done here because it changes the
   direct edition's published artifacts too (owner's call).
3. Drop FFmpeg from the Store edition and route media only through AVFoundation (loses WebM/MKV/OGG/FLAC-encode/AV1
   and many legacy containers; see the matrix in test-results.md for what FFmpeg carries).

### OWNER DECISION 2 — unRAR licence restriction in 7-Zip

`7zz` keeps the unRAR decoder (`7zz i` lists Rar1–Rar5 codecs). The unRAR licence allows free use for extraction but
**clause 3 is tied to the software staying free of charge** (see `scripts/build-7zz.sh` comment). If the Store edition
is ever paid (or has paid IAP that unlocks RAR), rebuild 7zz with `DISABLE_RAR=1` (RAR reading then is lost in the
Store edition) or obtain a licence. Free listing: no change needed. 7-Zip itself is LGPL-2.1+ (same Usage Rules
question as above, weaker form).

## Full component table

| Component | Version | Licence | Kind | Bundled | Sandbox OK |
|---|---|---|---|---|---|
| FFmpeg (ffmpeg, ffprobe) | 7.1.5 | LGPL-3.0-or-later (as built) | executable | yes, Contents/Helpers | yes (tested) |
| libvpx | 1.15.2 | BSD-3-Clause + patent grant | static in ffmpeg | yes | yes |
| SVT-AV1 | 3.1.2 (ffmpeg) / 4.2.0 (AVIF) | BSD-3-Clause-Clear + AOM patent licence | static | yes | yes |
| dav1d | 1.5.1 / 1.5.4 | BSD-2-Clause | static | yes | yes |
| Opus, libogg, libvorbis, libtheora | 1.5.2 / 1.3.6 / 1.3.7 / 1.2.0 | BSD-3-Clause | static in ffmpeg | yes | yes |
| LAME | 3.100 | LGPL-2.0-or-later | static in ffmpeg | yes | yes |
| soxr | 0.1.3 | LGPL-2.1-or-later | static in ffmpeg | yes | yes |
| FriBidi | 1.0.16 | LGPL-2.1-or-later | static in ffmpeg | yes | yes |
| FreeType | 2.13.3 | FTL (FTL/GPLv2 dual, FTL taken) | static in ffmpeg | yes | yes |
| HarfBuzz, libass, zimg, libwebp | 10.4.0, 0.17.3, 3.0.5, 1.5.0 | MIT, ISC, WTFPL, BSD-3 | static in ffmpeg | yes | yes |
| 7-Zip (7zz) | 25.01 | LGPL-2.1-or-later + BSD-3 parts + unRAR restriction | executable | yes, Contents/Helpers | yes (tested) |
| LibRaw | 0.21.5 | LGPL-2.1 (upstream also offers CDDL-1.0) | dylib | yes, Contents/Frameworks | yes (tested via DNG) |
| libwebp / libavif / libaom | 1.6.0 / 1.4.2 / 3.14.1 | BSD-3 / BSD-2 / BSD-2 | static in app | yes | yes |
| libarchive, xz, zstd, lz4 | 3.8.10, 5.8.4, 1.5.7, 1.10.0 | BSD-2, 0BSD, BSD-3, BSD-2 | static in app | yes | yes |
| libxls | 1.6.4 | BSD-2-Clause | static in app | yes | yes |
| woff2, brotli | 1.0.2, 1.2.1 | MIT | static in app | yes | yes |
| unalz, bzip2 | 0.65, 1.0.8 | zlib, bzip2-1.0.6 | static in app | yes | yes |
| MathJax (+ mhchemParser) | 3.2.2 (4.2.1) | Apache-2.0 | JS resource run in JavaScriptCore | yes, Resources/MathJax | yes (no JIT entitlement needed) |
| Latin Modern fonts | — | GUST Font License | resource | yes | yes |
| TeX hyphenation patterns (hyph-utf8) | 5684c0f | MIT / permissive per file | resource | yes | yes |
| Ported code: fontTools cu2qu, lzokay, acefile, vtracer | — | MIT / MIT / BSD-2 / MIT | source | in app | yes |
| LibreOffice, calibre, Pandoc, Tectonic, Ghostscript (AGPL), DjVuLibre (GPL), LibreDWG (GPL), GPL FFmpeg, RAR (proprietary), sfArk, ODA (proprietary), iWork, MS Office | various | various | outside programs | **no** | **not used in Store** |

Ghostscript (AGPL), LibreDWG/DjVuLibre (GPL) and a GPL FFmpeg are never bundled in either edition; in the direct edition
they are only run if the person already installed them.
