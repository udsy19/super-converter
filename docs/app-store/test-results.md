# Test results — Mac App Store edition (real runs, 2026-11-12, macOS 26.5.1, arm64)

Everything here ran on the ad-hoc-signed, sandboxed Store build (`DISTRIBUTION=appstore scripts/build-app.sh`,
release, arm64). Ad-hoc signing does enforce the App Sandbox (every run below logs `libsystem_secinit AppSandbox`).
Nothing here is Store-signed: real signing/upload is blocked on credentials (known-blockers.md).

## 1. Build and launch

- `DISTRIBUTION=appstore scripts/build-app.sh` → "Static launch checks passed" (sandbox on; no apple-events /
  disable-library-validation / temporary-exception / network.server; helpers `app-sandbox`+`inherit`; bundle id
  matches `SuperConverterPaths.bundleID`; no `NSAppleEventsUsageDescription`; no `api.github.com`, helper-pin file names
  in the binary — the same `strings` check finds 14 hits in the direct binary).
- `scripts/package-appstore.sh` without credentials → exits 1 with "error: missing APPSTORE_APP_IDENTITY
  APPSTORE_INSTALLER_IDENTITY APPSTORE_PROVISIONING_PROFILE." (as designed).
- The real app executable launched sandboxed (`build/appstore/Super Converter.app/Contents/MacOS/SuperConverter`):
  still running after 8 s, window shown, container `~/Library/Containers/com.udsy.superconverter.appstore` created
  with `Application Support/Super Converter`. Only sandbox denial during launch:
  `Sandbox: SuperConverter(45080) deny(1) iokit-open-user-client AppleNVMeEANUC` (harmless system probe).
- Direct edition: `scripts/build-app.sh` (no DISTRIBUTION) → "Static launch checks passed" after these changes (apple-events, disable-library-validation, not sandboxed — unchanged).
- Direct edition regression: `swift run SuperConverterSelfTest` for Core, HelperKit, UpdateKit, MenuBarKit,
  SettingsKit, App, ConvertKit, ArchiveKit, WindowKit — see §6.

## 2. Platform probes (sandboxed probe, `sandbox-tests/probe.c`)

```
sandbox-exec exit=71        sandbox-exec: sandbox_apply: Operation not permitted
access(W_OK,~/Desktop)=-1   (sandbox-aware: OutputRules' fall-back to Downloads works)
access(W_OK,~/Downloads)=0  (downloads.read-write)
pluginkit exit=1            match: unauthorized discovery flag (PKDiscoverAll)
hdiutil exit=1              hdiutil: attach failed - Device not configured
```
Sandbox log (`/usr/bin/log show --predicate 'sender == "Sandbox"' --last 10m`):
```
Sandbox: sandbox-exec(29993) deny(1) forbidden-sandbox-reinit
Sandbox: hdiutil(29995) deny(1) sysctl-write vfs.generic.noremotehang
Sandbox: hdiutil(29995) deny(1) mach-lookup com.apple.system.hdiejectd.xpc
```
Consequences implemented: no `sandbox-exec` in the Store build; DMG goes through 7-Zip; Quick Action switches only in
System Settings.

## 3. Grant inheritance experiment (ADDENDUM 2)

`sandbox-tests/grant.c`: an unsandboxed issuer creates a `com.apple.app-sandbox.read-write` extension for
`~/sc-grant-test/sample.mp3` (what powerbox does for an open panel); the sandboxed parent consumes it, opens the file,
and spawns `Contents/Helpers/ffprobe` (signed app-sandbox + inherit) on it.
```
consume=2 / parent open=ok / ffprobe printed [FORMAT]…[/FORMAT] / child exit=0     (granted file)
consume=-1 / parent open=DENIED                                                   (bogus token: control)
```
So on 26.5.1 a grant consumed **before** the spawn reached the inherit child. We nevertheless stage inputs (see
architecture.md "Deviation"), because this is undocumented and does not cover grants obtained after a child started.
Staging path exercised: inputs in `~/Downloads/sc-store-test/` (outside the container) → `sample.mkv → mp4` (FFmpeg)
and `tree.7z → zip` (7-Zip) both exit 0, results written next to the originals in Downloads.

Negative control (sandbox is real): sandboxed sconv on `~/sc-grant-test/checker-512.png` (never granted) fails, log:
`Sandbox: sconv(38543) deny(1) file-read-data /Users/udsy/sc-grant-test/checker-512.png`. (Its message says "permission
to save" — the read denial is mapped to the save wording; cosmetic, listed in known-blockers.md.)

## 4. Compatibility matrix (sandboxed conversion core)

Harness: `sandbox-tests/make-harness.sh` copies the Store app, makes the `APP_STORE` `sconv` its main executable
(same engines, planner, queue and output rules as the app) and signs it with the Store app's entitlements and bundle id,
so it runs in the **same container and sandbox profile**, with the same `Contents/Helpers` tools. `run-matrix.sh` stages
each fixture from `Tests/Corpus/generated` (made by `scripts/make-fixtures.swift` / `make-archive-fixtures.py`) inside
the container and converts it. PASS = exit 0 and a non-empty output file (type shown by `file`).

**Result: 83 PASS of 87 runs; the 4 "FAIL" are the expected Store behaviour** (3 helper-only conversions refused with
"Needs …", 1 decompression bomb refused pending confirmation).

| Family | Pass |
|---|---|
| image (ImageIO, LibRaw dylib, WebP, AVIF, PSB, XCF, icns, vectorize) | 12/12 |
| vector (SVG, SVGZ, PDF, EMF, WMF, AI, SK, XPS) | 8/8 |
| CAD (DXF → PDF/SVG) | 2/2 |
| document (DOCX, MD incl. MathJax, HTML via WebKit, RTF, ODT, TXT, PDF → DOCX/TXT/PNG) | 12/14 (TeX: needs Tectonic; RST: needs Pandoc — gated) |
| spreadsheet (CSV, XLSX) | 3/3 |
| e-book (EPUB, CBZ) | 2/3 (EPUB → MOBI: needs calibre — gated) |
| media via bundled FFmpeg (WebM, MKV, AVI, FLAC, OGG, WMA, RM, Opus, MP4 → WebM/GIF) | 11/11 |
| media via AVFoundation (MOV, MP4, WAV, AIFF) | 4/4 |
| media other (SF2 → SFZ, MOD → WAV) | 2/2 |
| archives (ZIP, TAR.GZ, 7Z, RAR, **DMG via 7-Zip**, ISO, UDF, CAB, LHA, ARJ, ACE, ALZ, ARC, DEB, RPM, XZ, LZO, FAT image, encrypted 7Z and AES ZIP with password, **writing an AES-256 7Z**, EML) | 22/22 |
| fonts (TTF → WOFF2/OTF/SVG) | 3/3 |
| unsafe archives | 3/3 protected (below) |

HTML → PDF/PNG needed `com.apple.security.network.client`: without it WebKit failed with "The page couldn’t be
loaded." (both cases FAIL); with it both PASS (PDF 1 page, PNG 2880×1600). The entitlement is in the Store set; pages
still reach no server (content-rule list) unless the person turns on "Load web resources".

Full per-case table:

| Family | Case | Exit | Result | Detail |
|---|---|---|---|---|
| image | checker-512.png → jpg | 0 | PASS | 1 file(s), 63641 B, JPEG image data, JFIF standard 1.01, resolution (DPI), densi |
| image | hdr-gainmap.heic → png | 0 | PASS | 1 file(s), 3641 B, PNG image data, 96 x 32, 8-bit/color RGB, non-interlaced |
| image | cmyk-chart.tiff → jpg | 0 | PASS | 1 file(s), 59274 B, JPEG image data, JFIF standard 1.01, aspect ratio, density 7 |
| image | exif-orient6.jpg → png | 0 | PASS | 1 file(s), 4475 B, PNG image data, 64 x 96, 8-bit colormap, non-interlaced |
| image | synthetic.dng → jpg | 0 | PASS | 1 file(s), 10636 B, JPEG image data, JFIF standard 1.01, resolution (DPI), densi |
| image | sample.psb → png | 0 | PASS | 1 file(s), 2957 B, PNG image data, 64 x 48, 8-bit/color RGBA, non-interlaced |
| image | sample.xcf → png | 0 | PASS | 1 file(s), 2923 B, PNG image data, 64 x 48, 8-bit colormap, non-interlaced |
| image | logo-alpha-128.png → webp | 0 | PASS | 1 file(s), 4722 B, RIFF (little-endian) data, Web/P image |
| image | gradient-256.png → avif | 0 | PASS | 1 file(s), 1592 B, ISO Media, AVIF Image |
| image | logo-alpha-128.png → icns | 0 | PASS | 1 file(s), 439263 B, Mac OS X icon, 439263 bytes, "icp4" type |
| image | red-text-240.png → svg | 0 | PASS | 1 file(s), 1102 B, SVG Scalable Vector Graphics image |
| image | animated-3.gif → png | 0 | PASS | 3 file(s), 8685 B, PNG image data, 32 x 32, 8-bit colormap, non-interlaced |
| vector | sample.svg → pdf | 0 | PASS | 1 file(s), 10442 B, PDF document, version 1.3, 1 pages |
| vector | sample.svgz → png | 0 | PASS | 1 file(s), 27347 B, PNG image data, 400 x 300, 8-bit/color RGB, non-interlaced |
| vector | sample-drawing.pdf → svg | 0 | PASS | 1 file(s), 12257 B, SVG Scalable Vector Graphics image |
| vector | sample.emf → pdf | 0 | PASS | 1 file(s), 9591 B, PDF document, version 1.3, 1 pages |
| vector | sample.wmf → svg | 0 | PASS | 1 file(s), 1221 B, SVG Scalable Vector Graphics image |
| vector | sample.ai → png | 0 | PASS | 1 file(s), 79681 B, PNG image data, 1250 x 938, 8-bit/color RGB, non-interlaced |
| vector | sample.sk → svg | 0 | PASS | 1 file(s), 1132 B, SVG Scalable Vector Graphics image |
| vector | sample.xps → pdf | 0 | PASS | 1 file(s), 4881 B, PDF document, version 1.3, 1 pages |
| cad | sample.dxf → pdf | 0 | PASS | 1 file(s), 9518 B, PDF document, version 1.3, 1 pages |
| cad | sample.dxf → svg | 0 | PASS | 1 file(s), 1568 B, SVG Scalable Vector Graphics image |
| document | sample.docx → pdf | 0 | PASS | 1 file(s), 79148 B, PDF document, version 1.3, 1 pages |
| document | sample.md → pdf | 0 | PASS | 1 file(s), 98819 B, PDF document, version 1.3, 1 pages |
| document | typeset-math-display.md → pdf | 0 | PASS | 1 file(s), 90613 B, PDF document, version 1.3, 1 pages |
| document | sample.html → pdf | 0 | PASS | 1 file(s), 34976 B, PDF document, version 1.3, 1 pages |
| document | sample.rtf → docx | 0 | PASS | 1 file(s), 4250 B, Microsoft Word 2007+ |
| document | sample.odt → pdf | 0 | PASS | 1 file(s), 35475 B, PDF document, version 1.3, 1 pages |
| document | sample.txt → pdf | 0 | PASS | 1 file(s), 33742 B, PDF document, version 1.3, 1 pages |
| document | sample.tex → pdf | 1 | FAIL | 0 file(s), 0 B,  / sample.tex: Needs Tectonic |
| document | sample.rst → html | 1 | FAIL | 0 file(s), 0 B,  / sample.rst: Needs Pandoc |
| document | sample.pdf → docx | 0 | PASS | 1 file(s), 4646 B, Microsoft Word 2007+ |
| document | sample.pdf → txt | 0 | PASS | 1 file(s), 385 B, ASCII text |
| document | sample.pdf → png | 0 | PASS | 2 file(s), 160698 B, PNG image data, 2550 x 3300, 8-bit colormap, non-interlaced |
| spreadsheet | sample.csv → xlsx | 0 | PASS | 1 file(s), 3309 B, Microsoft Excel 2007+ |
| spreadsheet | sample.xlsx → pdf | 0 | PASS | 1 file(s), 19349 B, PDF document, version 1.3, 1 pages |
| spreadsheet | sample.xlsx → csv | 0 | PASS | 1 file(s), 89 B, CSV text |
| ebook | sample.epub → pdf | 0 | PASS | 1 file(s), 78676 B, PDF document, version 1.3, 3 pages |
| ebook | sample.epub → mobi | 1 | FAIL | 0 file(s), 0 B,  / sample.epub: Needs calibre |
| ebook | sample.cbz → pdf | 0 | PASS | 1 file(s), 6028 B, PDF document, version 1.3, 3 pages |
| media-ffmpeg | sample.webm → mp4 | 0 | PASS | 1 file(s), 24113 B, ISO Media, MP4 Base Media v1 [ISO 14496-12:2003] |
| media-ffmpeg | sample.mkv → mp4 | 0 | PASS | 1 file(s), 64985 B, ISO Media, MP4 Base Media v1 [ISO 14496-12:2003] |
| media-ffmpeg | sample.avi → mp4 | 0 | PASS | 1 file(s), 79451 B, ISO Media, MP4 Base Media v1 [ISO 14496-12:2003] |
| media-ffmpeg | sample.flac → mp3 | 0 | PASS | 1 file(s), 14348 B, Audio file with ID3 version 2.4.0, contains: MPEG ADTS, laye |
| media-ffmpeg | sample.ogg → m4a | 0 | PASS | 1 file(s), 3365 B, ISO Media, Apple iTunes ALAC/AAC-LC (.M4A) Audio |
| media-ffmpeg | sample.wma → mp3 | 0 | PASS | 1 file(s), 7041 B, Audio file with ID3 version 2.4.0, contains: MPEG ADTS, laye |
| media-ffmpeg | sample.mp4 → webm | 0 | PASS | 1 file(s), 49789 B, WebM |
| media-ffmpeg | sample.mp4 → gif | 0 | PASS | 1 file(s), 101604 B, GIF image data, version 89a, 160 x 120 |
| media-ffmpeg | sample.rm → mp4 | 0 | PASS | 1 file(s), 47629 B, ISO Media, MP4 Base Media v1 [ISO 14496-12:2003] |
| media-avf | sample.mov → mp4 | 0 | PASS | 1 file(s), 74423 B, ISO Media, MP4 v2 [ISO 14496-14] |
| media-avf | sample.mp4 → mp3 | 0 | PASS | 1 file(s), 11231 B, Audio file with ID3 version 2.4.0, contains: MPEG ADTS, laye |
| media-avf | sample.wav → m4a | 0 | PASS | 1 file(s), 6147 B, ISO Media, Apple iTunes ALAC/AAC-LC (.M4A) Audio |
| media-avf | sample.aiff → wav | 0 | PASS | 1 file(s), 196096 B, RIFF (little-endian) data, WAVE audio |
| media-other | sample.sf2 → sfz | 0 | PASS | 3 file(s), 9370 B, Unicode text, UTF-8 text |
| media-other | sample.mod → wav | 0 | PASS | 1 file(s), 196722 B, RIFF (little-endian) data, WAVE audio |
| archive | tree.zip → 7z | 0 | PASS | 1 file(s), 33676 B, 7-zip archive data, version 0.3 |
| archive | tree.tar.gz → zip | 0 | PASS | 1 file(s), 34670 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tree.7z → zip | 0 | PASS | 1 file(s), 34670 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | stored.rar → zip | 0 | PASS | 1 file(s), 221 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tree.dmg → zip | 0 | PASS | 1 file(s), 38126 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tree.iso → zip | 0 | PASS | 1 file(s), 33668 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | udf.iso → zip | 0 | PASS | 1 file(s), 33668 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tree.cab → zip | 0 | PASS | 1 file(s), 33400 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tree.lha → zip | 0 | PASS | 1 file(s), 33400 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | stored.arj → zip | 0 | PASS | 1 file(s), 221 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tree.ace → zip | 0 | PASS | 1 file(s), 33668 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tree.alz → zip | 0 | PASS | 1 file(s), 33668 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tree.arc → zip | 0 | PASS | 1 file(s), 33380 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tool.deb → zip | 0 | PASS | 1 file(s), 34670 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | tool.rpm → zip | 0 | PASS | 1 file(s), 34670 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | floppy.img → zip | 0 | PASS | 1 file(s), 221 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | secret.7z → zip | 0 | PASS | 1 file(s), 33668 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | message.eml → zip | 0 | PASS | 1 file(s), 33181 B, Zip archive data, at least v2.0 to extract, compression meth |
| font | Arial.ttf → woff2 | 0 | PASS | 1 file(s), 122208 B, Web Open Font Format (Version 2), TrueType, length 122208, v |
| font | Arial.ttf → otf | 0 | PASS | 1 file(s), 1145876 B, OpenType font data |
| font | Arial.ttf → svg | 0 | PASS | 1 file(s), 1081762 B, SVG Scalable Vector Graphics image |
| safety | link-escape.tar → zip | 0 | PASS | 1 file(s), 359 B, Zip archive data, at least v2.0 to extract, compression meth |
| safety | bomb.tar.bz2 → zip | 2 | FAIL | 0 file(s), 0 B,  / bomb.tar.bz2: This archive unpacks to over 1,000 times its size — extract it anyway? To g |
| document | sample.md → docx | 0 | PASS | 1 file(s), 4883 B, Microsoft Word 2007+ |
| document | sample.md → odt | 0 | PASS | 1 file(s), 3880 B, OpenDocument Text |
| media-ffmpeg | sample.wav → wma | 0 | PASS | 1 file(s), 26142 B, Microsoft ASF |
| media-ffmpeg | sample.opus → mp3 | 0 | PASS | 1 file(s), 14204 B, Audio file with ID3 version 2.4.0, contains: MPEG ADTS, laye |
| archive | hello.txt.xz → zip | 0 | PASS | 1 file(s), 221 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | hello.txt.lzo → zip | 0 | PASS | 1 file(s), 221 B, Zip archive data, at least v2.0 to extract, compression meth |
| archive | aes.zip → 7z | 0 | PASS | 1 file(s), 33518 B, 7-zip archive data, version 0.3 |
| archive | tree.zip → 7z | 0 | PASS | 1 file(s), 33760 B, 7-zip archive data, version 0.4 |
| safety | zip-slip.zip → 7z | 0 | PASS | 1 file(s), 186 B, 7-zip archive data, version 0.3 |

### Unsafe archive extraction (in the sandbox)

- `zip-slip.zip` (`../evil.txt`, `/tmp/absolute.txt`, `a/../../evil2.txt`, `ok/fine.txt`) → 7Z containing only
  `ok/fine.txt` and `tmp/absolute.txt` (absolute path re-rooted inside); both traversal entries dropped.
- `link-escape.tar` (symlinks `outside -> ../../etc`, `absolute -> /etc/passwd`, then `outside/passwd`) → ZIP with
  `outside/passwd` as a plain file inside and `safe.txt`; both escaping symlinks dropped.
- `find <container> ~/sc-grant-test /private/tmp -name evil.txt -o -name evil2.txt -o -name absolute.txt` → nothing;
  `/tmp/absolute.txt` does not exist.
- `bomb.tar.bz2` → refused with exit 2: "This archive unpacks to over 1,000 times its size — extract it anyway?"
- The encrypted 7Z the app wrote: `7zz t -p` → "Cannot open encrypted archive. Wrong password?"; with the password →
  "Everything is Ok", method `LZMA2:48k 7zAES`.

## 5. Store availability of the whole registry (planner, not run)

`sconv --from <id> --list-targets` for all 212 input formats in the sandboxed Store build: **2252 pairs, 1792 built in,
460 need an outside helper** (calibre 168, LibreOffice 164, RAR 37, Ghostscript 34, iWork 19+8, ODA 14, Pandoc 9, sfArk
4, Tectonic 1, GPL FFmpeg 1, DjVuLibre 1). 40 input formats have **no** conversion in the Store edition: pps ppt snb lrf
pdb rb mobi rst cgm et eps sfark tcr vsd prc odg key odp dps dwg pages azw3 azw4 sda sdc azw pml tex wpd sdw djvu wps cdr
pub lit numbers ps pot lwp. The 1792 built-in pairs are the planner's claim; only the 83 cases above were executed.

## 6. Settings import and direct-edition self-tests

`SUPERCONVERTER_SELFTEST_ONLY=Core.directEditionImport swift run SuperConverterSelfTest` → `✓ Core.directEditionImport`
(fixture plist with the direct edition's real key layout: 6 keys copied; updater, helper paths, Quick Action election,
window frames left behind; source file unchanged).

Direct-edition regression (no `APP_STORE`): `SUPERCONVERTER_SELFTEST_ONLY=Core.,HelperKit.,UpdateKit.,MenuBarKit.,SettingsKit.,App.,ConvertKit.,ArchiveKit.,WindowKit. swift run SuperConverterSelfTest`
→ 191 cases passed, 1 failed (`App.launchSequence`: it reads AppDelegate's source text for `Services.updates.start()`,
now `Services.updates?.start()`); the test was updated and `SUPERCONVERTER_SELFTEST_ONLY=App.` → all 6 App cases pass.
The other engines' self-tests were not re-run (their code is untouched except `DiskImageReader`, covered by ArchiveKit).

## 7. Not run (needs a person)

No GUI automation was used (no synthetic keystrokes or clicks). The app window was only launched and quit (§1).
GUI paths left for a human run are listed in README.md "Human runs".
