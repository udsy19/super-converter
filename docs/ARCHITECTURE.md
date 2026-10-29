# Architecture

Super Converter is a native macOS app in Swift (Swift 5 language mode on the Swift 6 toolchain), built with SwiftPM
and the Command Line Tools only (no Xcode project), deployment target macOS 14. One main window, a menu-bar extra, a
Settings window, Finder Quick Action extensions and a command-line tool (`sconv`) share one conversion core. Every
conversion runs on the Mac; the only network traffic is listed in ux §6.6.

What converts to what, through which engine and under which licence: `docs/specs/formats.md` (and its generated data,
`docs/specs/data/format-matrix.json`). How good it must be and how that is measured: `docs/specs/quality.md`. How it
looks and behaves: `docs/specs/ux.md` and `docs/mockups/`. Section references in code comments point into those
files (`formats §4`, `quality §3.3`, `ux §5.6`). Decisions are marked **[D]**.

## 1. Shape of the system

```
 files ──▶ FormatSniffer ──▶ Card (source format, default target, options)
                                   │
                                   ▼
                     Planner ── format-matrix.json + engine availability + helper status
                                   │  ConversionPlan = [Step(engine, from, to)], built-in or helper route
                                   ▼
                     JobQueue (concurrency classes) ── work folder per job ── progress, cancellation
                                   │
          ┌───────────┬────────────┼─────────────┬──────────────┬─────────────┬────────────┐
       ImageKit   VectorKit    DocKit/Typeset  OfficeKit/EbookKit  MediaKit   ArchiveKit   FontKit …   (engines)
          │           │            │             │                  │            │            │
          └─── intermediate models from Core: ImageAsset · VectorDocument · DocModel · Workbook · Deck ·
               Publication · ArchiveTree · MediaPlan · FontModel ───┘
                                   │
                                   ▼
                     OutputPolicy (naming, place, dates) ──▶ Result (files, loss notes) ──▶ card / panel / CLI
```

Hub-and-spoke [D]: each category has one intermediate model; readers turn formats into it, writers turn it into
formats. That is how 2,253 offered pairs come from about 150 readers and writers, and why a new format is one reader
or one writer, never N new pairs. Audio/video is the exception: AVFoundation and FFmpeg are pipelines, so MediaKit's
"model" is a plan of streams and settings.

## 2. Engines copied from the sister apps (decision)

As in Super PDF, code from sister apps is **copied into this repository** with provenance comments; there is no
shared package and no path dependency on a sibling checkout. A copy is a fork; fixes are ported by hand.

| Module (here) | Copied from | Commit | What changes |
|---|---|---|---|
| `UpdateKit` | Super Flow `Sources/UpdateKit/{Updater,UpdateLogic,UpdateInstaller}.swift` | `c1edfc4` | Repository `udsy19/super-converter`, asset `SuperConverter`; value types move to `SuperConverterCore/Contracts/Engines.swift` |
| `LayoutKit` | Super PDF `Sources/LayoutKit/**` | `058469b` | Depends on Core's `LayoutDocument` model only; no PDFModelKit (PDFKit + CGPDF text positions) |
| `RenderKit` | Super PDF `Sources/RenderKit/**` (Rasterizer, PDFOutput, PDFPages, ColorUsage, PageImageCache) | `058469b` | Imposer and Separations not copied (no use here) |
| `OfficeKit` parts | Super PDF `ConvertKit/Support/{Zip,XML,SheetTable}.swift`, `Export/{OOXML,WordWriter,SpreadsheetWriter,PresentationWriter}.swift`, `Import/{SpreadsheetImporter,PresentationImporter,SlideCanvas,SlideGeometry,SlideText,SlideTheme}.swift` | `058469b` | Writers take Core models (`DocModel`, `Workbook`, `Deck`) instead of LayoutKit output directly |
| `DocKit` parts | Super PDF `Import/{HWPXImporter,MailImporter,MarkdownImporter,AttributedTextImporter,DelimitedTextImporter,EPUBImporter}.swift` | `058469b` | Produce `DocModel` / `Publication` instead of PDFs |
| `HelperKit` parts | Super PDF `ConvertKit/Helpers/{LibreOffice,AppAutomation,HelperService}.swift` | `058469b` | One-click install added (formats §4); detection and the headless runner kept |
| `PDFAVerifier` | Super PDF `ConvertKit/Export/PDFAVerifier.swift` | `058469b` | Moves into RenderKit |

Rules for copies: every copied file starts with `// Adapted from <repo> <path> (commit <sha>)` and what changed;
engines carry no app policy (no `Services`, no `Defaults`, no UI strings); configuration comes through initialisers;
each engine has a self-test file. Ports of third-party permissive code follow formats §2.6.

## 3. Modules

```
Sources/
  SuperConverterCore/   contracts and shared data, no conversion logic:
                          Catalog/      FormatID, FormatCategory, Format (extensions, UTTypes, MIME, names, synonyms),
                                        the magic-byte table, the matrix and engine list (generated Swift data from
                                        format-matrix.json, typed steps), the helper catalog, OptionProfile definitions
                                        (formats §5 as data), default targets (ux §6.1)
                          Models/       the intermediate models (data only): ImageAsset, VectorDocument, DocModel,
                                        LayoutDocument, Workbook, Deck, Publication, ArchiveTree, MediaPlan, FontModel,
                                        LossNote
                          Contracts/    Converter, ConverterRegistry, Planning, JobQueueing, HelperManaging,
                                        Thumbnailing, OutputPolicy, UpdateChecking, WindowPresenting, Engines (value
                                        types shared with engines)
                          Design/       SCColor (ux §3.2–3.3, light/dark/high contrast), SCFont, SCMetrics, SCMotion
                          Strings, Defaults (typed keys), Services (registry), SuperConverterPaths, Logging
  ImageKit/             engine: ImagePipeline (Core Image, vImage, ColorSync), CIRAW development, ImageCodecs (PSB,
                          XCF, PPM), encoders (ImageIO, libwebp, AVIF, GIF quantiser, ICO/ICNS sets),
                          metadata; LibRaw adapter for X3F
  VectorKit/            engine: VectorDocument readers (CGPDFScanner, SVG, EMF/WMF, SK/SK1) and writers (CGPDF, SVG,
                          PostScript/EPS, EMF, WMF, CGM)
  XPSKit/               engine: XPS/OpenXPS/DWFx reader → VectorDocument, XPS writer
  VectorizeKit/         engine: raster → SVG tracing (vtracer port)
  CADKit/               engine: DXF reader/writer, CAD model, plotting to VectorDocument, DWF readers
  DocKit/               engine: DocModel readers (DOCX, ODT, Markdown, HTML, text, RTF/DOC via TextKit, AbiWord, HWP,
                          HWPX, mail, Pandoc JSON) and writers (DOCX, ODT, RTF/DOC, HTML, Markdown, RST, LaTeX, text)
  TypesetKit/           engine: DocModel/Workbook/Publication → PDF with the LaTeX look (Knuth–Plass, LaTeX metrics,
                          floats, footnotes, booktabs, tagged PDF); bundles Latin Modern, CMU, STIX Two, Carlito,
                          Caladea
  MathKit/              engine: MathJax in JavaScriptCore → SVG paths → VectorDocument fragments
  LayoutKit/            engine (from Super PDF): PDF → LayoutDocument
  RenderKit/            engine (from Super PDF): rasterise PDF pages, PDF/A contexts and verifier, ColorSync output
  OfficeKit/            engine: Workbook (CSV, XLSX, ODS, XLS via libxls), Deck (PPTX reader/renderer/writer), ODF
                          drawing picture reader/writer, Zip/XML/OOXML support
  EbookKit/             engine: Publication (EPUB 2/3, OEB, FB2, HTMLZ, TXTZ, comics, CHM) readers and writers
  ArchiveKit/           engine: ArchiveTree over libarchive; 7zz, hdiutil adapters; LZOKit, ACEKit, ARCKit, RZipKit,
                          unalz; extraction safety
  MediaKit/             engine: probing, AVFoundation pipelines, FFmpeg process adapter, option mapping, progress,
                          animation (GIF/WebP), SoundFont reader
  FontKit/              engine: SFNT/CFF/WOFF/WOFF2/EOT/SVG-font readers and writers, cu2qu
  HelperKit/            engine: helper catalog runtime, detection, one-click installer (download, SHA-256, code
                          signature, unpack), process runner (time limit, no network), app automation (iWork, Office),
                          adapters for every helper in formats §4
  UpdateKit/            engine (from Super Flow)
  ConvertKit/           feature: ConverterRegistry (every engine's Converters), Planner, JobQueue, work folders,
                          OutputPolicy, loss-note aggregation, FormatSniffer, ThumbnailService (Quick Look)
  WindowKit/            feature: the main window (drop zone, cards grid/list, format picker, options sheet generated
                          from option profiles, progress, results, helper notices) — ux §4–§5.8
  MenuBarKit/           feature: status item, drop target, panel — ux §5.9
  SettingsKit/          feature: Settings window panes — ux §5.11
  SuperConverter/       app target: launch sequence, module wiring, menus, Dock tile and badge, Open With, Services,
                          notifications, URL routes (`superconverter://convert?file=…&to=jpg`), Services.updates
  SuperConverterQuickActions/  Finder Quick Actions: one executable entered through NSExtensionMain, packaged by
                          build-app.sh as six action extensions (ux §5.10), handing files to the app or converting
                          through the app's background service
  sconv/                command-line tool: `sconv <files…> --to jpg [--option quality=90] [--out DIR] [--list-targets]`
  SuperConverterSelfTest/       headless checks per module (`swift run SuperConverterSelfTest`)
  SuperConverterQualityBench/   the quality bench (quality §9)
Vendor/                 xcframeworks and executables fetched by scripts/fetch-vendor.sh (git-ignored)
Tests/Corpus, Tests/Golden      quality bench fixtures and goldens
```

## 4. Rules

- **Engines** (`*Kit` under "engine") depend only on `SuperConverterCore` and their vendor libraries; they never
  import each other except the documented engine-to-engine edges: TypesetKit → MathKit, VectorKit; DocKit → LayoutKit
  (PDF input); EbookKit → DocKit, TypesetKit; CADKit → VectorKit; XPSKit → VectorKit; ImageKit → RenderKit;
  RenderKit → VectorKit (VectorKit's `VectorDrawing` draws a VectorDocument into any CGContext); OfficeKit → TypesetKit (tables), RenderKit. No cycles (the self-test checks the import graph).
- **Feature modules** (ConvertKit, WindowKit, MenuBarKit, SettingsKit) depend on Core and talk through the `Services`
  registry; only ConvertKit imports engines (it registers their converters).
- **Intermediate models live in Core** as plain data (`Sendable` structs), so any engine can read what another
  writes without importing it. A change to a model updates every reader, writer and fake in the same change.
- **One owner per protocol**; `<Module>Module.install()` registers it in `Services`. The app target owns
  `Services.updates`.
- **Converters are data-driven.** A `Converter` declares `id` (the engine id used in `format-matrix.json`), the
  (from, to) kinds it handles and `availability()` (built in; needs helper X; unavailable on this macOS). The planner
  only follows routes the matrix lists; a self-test fails if the matrix names an engine id no converter registers, or
  a converter is registered that no route uses (no dead code).
  Which module registers an engine id's converter is `EngineID.info.module` (the table `ENGINES` in
  `scripts/gen-format-matrix.py`): helper-run engines belong to HelperKit, `PDFOps` to ConvertKit (WP-L), `WebKitPrint`
  and `WebKitSnapshot` to DocKit.
- **Helpers run only through HelperKit**: never `Process` elsewhere. No GPL/AGPL code is linked or loaded (formats §2);
  the build script's licence check fails the build if a vendored artifact's licence is not on the allow-list.
- **Main actor** for UI and `Services`; engines are `Sendable` and run on a cooperative pool or their own processes;
  progress is reported through `AsyncStream<JobProgress>`; cancellation is cooperative and deletes partial output.
- **Local-first**: no network except ux §6.6. No telemetry, no remote flags.
- **No dead code**: superseded code, placeholders and unused helpers go in the same change.
- **Copy** comes from ux §7; sentence case, curly quotes, real ellipsis.

## 5. Core contracts (`SuperConverterCore`)

| Type / protocol | Owner (registers in `Services`) | Spec |
|---|---|---|
| `FormatID`, `Format`, `FormatCategory`, `FormatCatalog` (212 + output-only), `FormatMatrix` (pairs, routes, steps, helpers, options profile, rank), `DefaultTargets` | Core data | formats §1, §6; ux §6.1 |
| `OptionProfile`, `OptionDefinition` (type, range, default, CloudConvert name, plain label, "more" flag), `OptionValues` (Codable) | Core data | formats §5 |
| `Converter`, `ConverterRegistry` (`converters`), `StepInput`/`StepOutput` (a model value or files in the work folder) | ConvertKit: `converters` | §6 below |
| `Planning`: `plan(for: ConversionRequest) -> ConversionPlan` with `RouteChoice` (built-in / helper / unavailable + reason) | ConvertKit: `planner` | formats §6 |
| `JobQueueing`: enqueue, cancel, `AsyncStream<JobEvent>`, concurrency classes | ConvertKit: `queue` | ux §6.4 |
| `FormatSniffing` | ConvertKit: `sniffer` | ux §6.2 |
| `OutputPolicy` (place, naming, collisions, dates) | ConvertKit: `output` | ux §6.3 |
| `Thumbnailing` (Quick Look, cached) | ConvertKit: `thumbnails` | ux §5.3 |
| `HelperManaging`: `status(of:)`, `install(_:) -> AsyncStream<InstallProgress>`, `remove`, `run(_ invocation:)`, `automate(app:script:)` | HelperKit: `helpers` | formats §4 |
| `WindowPresenting`, `MenuBarPresenting`, `SettingsPresenting` | WindowKit, MenuBarKit, SettingsKit | ux §5 |
| `UpdateChecking` | app target (UpdateKit) | — |
| `SCColor`, `SCFont`, `SCMetrics`, `SCMotion`, `Strings`, `Defaults` | Core | ux §3, §7 |

## 6. Engine adapters and the planner

- `format-matrix.json` holds each route as a readable chain and, since WP1, as `steps: [{engine, from, to}]` (engine ids
  are formats §3's names; `from`/`to` are formats, or `@Model` kinds). `scripts/gen-format-matrix.py` also writes the
  same data as Swift into `Sources/SuperConverterCore/Catalog/Generated/` (the engine list, the format list, every
  route): Core carries the catalog as compiled data, with no resource bundle to find at run time, and a self-test
  fails when the Swift and the JSON disagree. A route is a built-in chain, a helper chain, or both, plus alternates
  (the LaTeX look). The planner never parses prose.
- **Choosing a route**: offered pairs have a built-in route, a helper route, or both. With both, the matrix's
  `prefer` decides when the helper is present (original-layout office rendering prefers the helper); the person can
  switch on the card ("Look: Original / As written / LaTeX" is the visible form of that switch for documents).
- **Steps exchange values or files.** A step returns a model value (`DocModel`, `VectorDocument`, …) when the next
  step is in-process, or files in the job's work folder when the next step is a process (FFmpeg, LibreOffice,
  calibre). Large intermediates (decoded video, archive contents) are always files.
- **Engines report** progress (fraction + a unit such as "Page 3 of 12"), loss notes and warnings. A step either
  produces complete output or throws a `ConversionError` with the ux §7.2 case it maps to.
- **Availability** is computed once at launch and on helper changes: ImageIO's writable types, AVFoundation's
  encoders, Vendor executables present and runnable, helper status. Pairs whose every route is unavailable show the
  helper's Install/Get in the picker rather than disappearing.

## 7. Helpers, processes and packaging

- **One-click install** (formats §4): HelperKit downloads from the pinned URL with `URLSession` (the only network
  code besides UpdateKit), verifies SHA-256, then for apps verifies the Developer ID signature and notarisation
  (`SecStaticCodeCheckValidity` + `SecAssessment`), copies apps to `~/Applications`, unpacks CLI helpers to
  `~/Library/Application Support/Super Converter/Helpers/<id>/<version>/`, records them in `helpers.json`, and never
  launches them except for a conversion. "Get…" helpers open the vendor's page or the App Store.
- **Running a helper**: `Process` with a scrubbed environment, a private `TMPDIR`, the job's work folder as the only
  writable place, a per-file time limit (LibreOffice 120 s, calibre 300 s, Ghostscript 120 s, Tectonic 300 s), `nice`,
  and for command-line helpers a `sandbox-exec` profile that denies network and writes outside the work folder (WP-H
  verifies `sandbox-exec` still works on macOS 14–26; if not, the environment and arguments are the only guard).
- **Bundled executables** (`ffmpeg`, `ffprobe`, `7zz`) live in `Contents/Helpers/`, are code-signed with the app's
  identity and run through the same runner (no sandbox profile needed for network: they get no network arguments).
- **Bundled libraries**: static xcframeworks for permissive C/C++ libraries; `libraw_r.dylib` in
  `Contents/Frameworks/`. `scripts/build-vendor.sh build <lib>` builds universal (arm64 + x86_64) artifacts with CMake/
  autotools from pinned upstream source, `scripts/fetch-vendor.sh` downloads the published artifacts (this
  repository's Releases, pinned by SHA-256 in `Vendor.lock`), as Super PDF does for QPDF.
- **App**: not sandboxed (helpers, automation and `hdiutil` need it), Hardened Runtime, Developer ID signed and
  notarised by `scripts/release.sh` (copied from Super PDF; the signing identity never changes), DMG by
  `scripts/make-dmg.sh`, updates through UpdateKit. Entitlements: Apple Events (automation of Pages, Numbers,
  Keynote, Microsoft Office). MathJax runs in JavaScriptCore without the JIT entitlement (interpreter is fast enough
  for formulas; WP-T measures).

## 8. Data

- `~/Library/Application Support/Super Converter/`: `Helpers/` (CLI helpers), `helpers.json`, `Jobs/<uuid>/` (work
  folders, removed when a job ends and swept at launch), `recent.json` (menu-bar list, last 10), `update.json`,
  `lo-profile/` (LibreOffice's private profile), `tectonic-cache/`.
- `~/Library/Caches/Super Converter/thumbnails/` (Quick Look thumbnails by file identity + modification date).
- Defaults: per-format targets, per-target options, window frame, view mode, Settings switches.

## 9. Launch sequence

1. Core bootstrap: paths, Defaults migration, logging; `SUPERCONVERTER_DATA_DIR` / `SUPERCONVERTER_DEFAULTS_SUITE`
   for tests (throwaway places, no updater).
2. `<Module>Module.install()` in order: HelperKit, every engine module (registering converters through ConvertKit's
   registry API), ConvertKit (verifies matrix ↔ registry coverage; computes availability), WindowKit, MenuBarKit,
   SettingsKit.
3. App target: `Services.updates`, main menu, Services provider, `NSUpdateDynamicServices`, LaunchServices
   registration (Quick Actions, Open With for every input UTType), Dock tile.
4. Open files and URLs passed in (Finder, Dock, Services, Quick Actions, `superconverter://`), else the empty window;
   sweep stale work folders; `Services.updates.start()`.

## 10. Native dependencies

Apple frameworks: AppKit, SwiftUI (sheets, popovers, Settings), ImageIO, Core Image, Accelerate (vImage),
ColorSync, Core Graphics, PDFKit, Core Text, WebKit, JavaScriptCore, AVFoundation, VideoToolbox, AudioToolbox,
Vision, NaturalLanguage, QuickLookThumbnailing, UniformTypeIdentifiers, UserNotifications, Security, CryptoKit,
Compression, os. SwiftPM packages: none (DocKit reads Markdown with its own CommonMark + GFM parser, so the build needs no
network). Vendor artifacts: formats §3.3. Licences in `THIRD_PARTY_NOTICES.md`, shown in Settings › About.

## 11. Work packages

One worker per package; each owns only the paths listed, implements the services named, follows the cited spec
sections, and adds its `<Module>Tests.swift` to `SuperConverterSelfTest` and its cases to the quality bench. "Done"
always includes: `swift build` clean, `swift run SuperConverterSelfTest` green, the package's bench cases green, no
edits outside the owned paths (contract changes go through WP1's owner or are made in Core with every caller updated
in the same change), every route the package owns in `format-matrix.json` passing at least one bench case.

### Waves

| Wave | Packages | Starts when |
|---|---|---|
| A | WP0a, WP0b, WP0c, WP1 | now (WP0a–c are independent of WP1) |
| A2 | WP-Q | WP1 merged |
| B | WP-I, WP-V, WP-C, WP-T, WP-D, WP-L, WP-O, WP-E, WP-A, WP-M, WP-F, WP-H | WP1 merged (+ WP0b/WP0c artifacts for the engines that link them); all twelve run in parallel |
| C | WP-P, WP-U, WP-B, WP-S | WP1 merged; they build against Core fakes and pick up real engines as wave B lands |
| D | WP-R | waves B and C merged |

### Wave A — foundation

**WP0a — UpdateKit from Super Flow** (heavy). `Sources/UpdateKit/**`, `UpdateKitTests.swift`. Copy and adapt with
provenance (Super Flow `c1edfc4`); configuration through initialisers; shared value types in
`SuperConverterCore/Contracts/Engines.swift`. Acceptance: self-tests for version comparison, asset selection,
SHA-256 + signature verification with fixtures; no network in tests.

**WP0b — Vendor libraries** (careful). `scripts/build-vendor.sh`, `scripts/fetch-vendor.sh`, `Vendor.lock`,
`.github/workflows/vendor.yml`, `THIRD_PARTY_NOTICES.md` (vendor section), `Package.swift` binary targets. Universal
static xcframeworks with module maps for libwebp, libavif + SVT-AV1 + dav1d, libarchive (+ liblzma, zstd, lz4; system
zlib/bzip2/iconv), libxls, google/woff2 + Brotli, unalz; `libraw_r.dylib` (LGPL, dynamic, with X3F tools after the
licence check, formats §3.3). Published on this repository's Releases, pinned by SHA-256; a licence allow-list check
(MIT, BSD, Apache-2.0, ISC, zlib, 0BSD, LGPL-as-dylib) fails the build otherwise. Acceptance: a scratch executable
links every library on both slices and round-trips one file through each.

**WP0c — Bundled executables** (careful). `scripts/build-ffmpeg.sh`, `scripts/build-7zz.sh`, workflow, notices.
FFmpeg 7.1 LGPL build (`--enable-version3 --disable-gpl --disable-nonfree`, VideoToolbox, AudioToolbox, libvpx,
SVT-AV1, dav1d, libopus, libvorbis, libtheora, LAME, opencore-amr, vo-amrwbenc, libwebp, soxr, zimg, libass +
HarfBuzz + FreeType + FriBidi), `ffmpeg` + `ffprobe` universal; 7-Zip `7zz` universal from source. `ffmpeg
-buildconf` checked by a script that fails on `--enable-gpl`/`nonfree`; source tarballs and build scripts published
next to the binaries (LGPL). Acceptance: smoke conversions (H.264 VideoToolbox, VP9, AV1, Opus, MP3, AMR, GIF palette)
on both slices; `7zz` extracts AES-7z, RAR5, ARJ, FAT image fixtures.

**WP1 — Core contracts and scaffold** (heavy, single owner, first). `Package.swift`, `Sources/SuperConverterCore/**`,
placeholder `<Module>Module.swift` for every module, the app/extension/CLI/self-test/bench target skeletons,
`scripts/gen-format-matrix.py` (adds typed `steps` per route and writes Core's resource), `Sources/SuperConverterSelfTest/
{main,CoreTests,Fakes}.swift`. Everything in §5: formats and matrix as data, option profiles (formats §5) as data,
default targets (ux §6.1), magic-byte table for the sniffer (ux §6.2), intermediate models, contracts with fakes,
`Services`, paths, `Defaults`, design tokens (ux §3), strings (ux §7). Acceptance: `swift build` clean; Core self-tests
(212 formats, every offered pair has ≥ 1 route with typed steps, every option profile referenced exists, every
engine id named appears in the engine list, token contrast ratios ≥ the ux §3.2 table, Defaults round-trip).

**WP-Q — Quality bench harness** (careful; wave A2). `Sources/SuperConverterQualityBench/**`,
`scripts/make-fixtures.swift`, `scripts/fetch-corpus.sh`, `Tests/Corpus/**`, `Tests/Golden/**` (layout, not cases).
Metric implementations (ΔE2000 via ColorSync Lab, SSIM/MS-SSIM, PSNR, THD+N, loudness via `ffmpeg ebur128`, manifest
hashing), each validated against published reference values; case runner over the planner; tiers fast/full;
regression memory; JSON + HTML report (quality §9). Acceptance: metric self-validation green; a sample case per
category runs against fakes.

### Wave B — engines (parallel)

**WP-I — ImageKit** (fable). `Sources/ImageKit/**`. quality §2 in full: pipeline, ColorSync rules (§2.2), encoders
and defaults (§2.3, including the ImageIO-JPEG subsampling measurement and the libjpeg-turbo decision), Lanczos
resampling (§2.4), RAW (§2.5), metadata (§2.6), GIF quantiser (§2.7), PSB/XCF/PPM codecs, ICO/ICNS sets, X3F via
LibRaw (raster PS/EPS pages are VectorKit's `PSWriter`, the ODD picture writer is OfficeKit's `ODFWriter`; both take an
`ImageAsset`). Converters for every image route in formats §6.2. Bench: all of
quality §2.8.

**WP-V — VectorKit, XPSKit, VectorizeKit** (fable). `Sources/{VectorKit,XPSKit,VectorizeKit}/**`. VectorDocument
model ops; PDF reader on `CGPDFScanner` (fonts → outlines or embedded programs, shadings, transparency groups, soft
masks flagged), SVG reader/writer, PostScript/EPS writer (Type 42 fonts), EMF/WMF reader/writer, CGM writer, XPS
reader/writer (obfuscated fonts), SK/SK1 readers (P3), vtracer port with presets. Bench: quality §6.

**WP-C — CADKit** (heavy). `Sources/CADKit/**`. DXF ASCII/binary reader for the entity set in formats §3.2, blocks,
layouts, linetypes, text styles mapped to bundled fonts, plotting to VectorDocument with zoom-to-extents (percentile
extents), DXF writer R12–2018, DWG via HelperKit's ODA/LibreDWG adapters, DWFx through XPSKit, DWF 6 W2D decoder
(P3, timeboxed). Bench: quality §6 DXF rows.

**WP-T — TypesetKit + MathKit** (fable). `Sources/{TypesetKit,MathKit}/**`, `Resources/Fonts/**`. quality §3 in full:
LaTeX article/book metrics in TeX points (§3.2), Knuth–Plass with space factors, emergency pass and protrusion
(§3.3), hyphenation, page builder (floats, footnotes, widows/clubs, ragged bottom), headings and numbering, lists,
quotes, code, booktabs tables (with splitting and landscape), title block, contents page, running heads (book),
"As written" look with Carlito/Caladea (§3.5), MathJax in JavaScriptCore → paths with `/ActualText` (§3.4), tagged
PDF and bookmarks. Bench: LaTeX parity against Tectonic goldens and the typographic lint (quality §3.7).

**WP-D — DocKit** (heavy). `Sources/DocKit/**`. DocModel readers: DOCX (own), ODT (own), Markdown (own CommonMark + GFM
parser, math, footnotes), HTML (own tolerant parser: no web process, nothing fetched), plain text (encoding detection, prose/code), RTF/DOC (TextKit), AbiWord/ZABW, HWP 5
(OLE + records), HWPX and EML (from Super PDF), Pandoc JSON AST; writers: DOCX (from Super PDF), ODT, RTF/DOC
(TextKit), HTML, Markdown flavours, RST, LaTeX, text; OMML/MathML ↔ TeX converters. Bench: round trips (quality
§3.7).

**WP-L — LayoutKit, RenderKit, PDF routes** (heavy). `Sources/{LayoutKit,RenderKit}/**`, PDF converters in
`Sources/ConvertKit/PDF/**`. Copy from Super PDF with provenance; PDF → DocModel/Workbook/Deck/Publication/HTML
(reflow and positioned)/text; PDFOps (pages, split, encryption, permissions, watermark, PDF/A-2b + verifier). Bench:
PDF → DOCX metrics (quality §3.7).

**WP-O — OfficeKit** (heavy). `Sources/OfficeKit/**`. Workbook: CSV (RFC 4180, encodings), XLSX/XLSM reader/writer
(from Super PDF), ODS reader/writer, XLS via libxls; Deck: PPTX reader/renderer/writer (from Super PDF), OOXML
repackaging (show/template/macro variants); ODF drawing picture reader/writer; booktabs handoff to TypesetKit; slide
text extraction for MD/TXT. Bench: quality §4 spreadsheet and slide rows.

**WP-E — EbookKit** (medium/heavy). `Sources/EbookKit/**`. Publication model; EPUB 2/3, OEB, FB2, HTMLZ, TXTZ readers;
comics (CBZ/CBR/CBC) fixed layout; CHM via 7zz + `.hhc`; EPUB/OEB writers (EPUBCheck-clean); book-style PDF through
TypesetKit; calibre adapter contract use (through HelperKit). Bench: EPUBCheck, comics hash checks.

**WP-A — ArchiveKit** (heavy). `Sources/ArchiveKit/**`. ArchiveTree over libarchive (read every format, write ZIP
with AES, TAR family, 7Z), 7zz adapter (encrypted, ARJ, IMG, UDF, Quantum CAB), hdiutil DMG adapter, LZOKit (lzokay
port + lzop framing), ACEKit (acefile port), ARCKit, RZipKit, unalz, EML attachments, DEB/RPM payload unpacking,
safety (zip-slip, symlinks, bombs), name encodings, RAR helper use. Bench: quality §8.

**WP-M — MediaKit** (fable). `Sources/MediaKit/**`. Probing (ffprobe + AVFoundation), route choice (copy → AVFoundation
→ FFmpeg), option mapping for every container/codec row of formats §5 (O-VIDEO, O-AUDIO, O-ANIM), the VideoToolbox
quality calibration table (quality §5.1, measured with the dev-only GPL FFmpeg; the table ships, the tool doesn't),
colour tagging and HDR handling, deinterlace detection, subtitles, watermark, GIF/WebP animation both ways,
SoundFont reader/SFZ writer, progress parsing, cancellation. Bench: quality §5.3.

**WP-F — FontKit** (heavy). `Sources/FontKit/**`. SFNT read/write, CFF/CFF2 builder, cu2qu port, TrueType glyf
builder, WOFF, WOFF2 (google/woff2), EOT (plain/XOR; MTX P3), SVG fonts both ways, subsetting. Bench: quality §7.

**WP-H — HelperKit** (careful). `Sources/HelperKit/**`, the helper catalog data in Core (with WP1). Detection,
one-click install (download, SHA-256, signature/notarisation checks, unpack, `~/Applications` copy), remove, the
process runner (§7), app automation with the "will open briefly" notice (from Super PDF), adapters for LibreOffice,
iWork, Office, calibre, Pandoc, Tectonic (warm-up cache, `--only-cached`), Ghostscript, DjVuLibre, ODA, LibreDWG,
FFmpeg-GPL, RAR, sfArk. Tests use fake helpers (scripts that behave like each tool); no network, no real installs.

### Wave C — app

**WP-P — ConvertKit** (heavy). `Sources/ConvertKit/**` (except `PDF/`), `Sources/sconv/**`. ConverterRegistry,
Planner (routes, prefer, availability, reasons), JobQueue (ux §6.4 classes), work folders, OutputPolicy (ux §6.3),
FormatSniffer (ux §6.2), thumbnails, loss notes, the `sconv` CLI (used by the bench and by people's scripts).
Acceptance: planner fixtures for every category; queue concurrency and cancellation tests; naming collisions; the CLI
converts one fixture per category.

**WP-U — WindowKit** (heavy). `Sources/WindowKit/**`. The main window to ux §3–§5.8 and the mockups: drop zone and
drag feedback, cards (grid and list), the colour flow (§3.4), format picker with search/synonyms, options sheet
generated from option profiles (first controls per ux §5.5), progress and results, helper notices with install
progress, failures with their fixes, keyboard (ux §6.5), accessibility (ux §6.7), notifications and Dock progress.
Acceptance: offscreen renders compared with the mockups' metrics; keyboard and VoiceOver checks; picker search
fixtures ("word" → DOCX, "kindle" → AZW3/MOBI, "transparent" → PNG/WebP).

**WP-B — Menu bar, Quick Actions, Services** (medium). `Sources/MenuBarKit/**`, `Sources/SuperConverterQuickActions/**`.
ux §5.9–§5.10: status item drop target and panel, recent list, six Quick Action extensions with activation rules,
Services entries, background conversions with notifications. Acceptance: activation rules per UTType table; panel
renders; quick actions hand files to the app (fake opener in tests).

**WP-S — SettingsKit** (medium). `Sources/SettingsKit/**`. ux §5.11 panes; Formats pane edits saved targets/options;
Helpers pane over HelperManaging; About with licences and updates. Acceptance: Defaults round-trips; pane renders.

### Wave D — ship

**WP-R — App target, packaging, release** (careful). `Sources/SuperConverter/**`, `scripts/**` (except vendor and
mockup scripts), `Resources/**`, `.github/workflows/**` (except `udsy.yml`, which stays identical to Super Flow's),
`README.md`, `PRIVACY.md`, `CHANGELOG.md`, `THIRD_PARTY_NOTICES.md` (app section). Launch sequence (§9), menus,
Info.plist (document types and UTTypes for all 212 formats as Viewer/Alternate, usage strings for automation),
icons (`make-icon.swift`), `build-app.sh` (embeds `ffmpeg`, `ffprobe`, `7zz`, `libraw_r.dylib`, extensions; signs
inside-out), `release.sh` and `make-dmg.sh` copied from Super PDF (stable DMG + SHA line for the updater; signing
identity unchanged), CI (build, self-test, fast bench), end-to-end run (drop fixtures of every category → convert →
outputs verified by the bench's checks).

## 12. Open questions (decided provisionally; revisit with evidence)

1. **No public helpers repository [D].** GPL/AGPL helpers without official macOS builds (Ghostscript, DjVuLibre, LibreDWG,
   sfArk tool, FFmpeg with GPL encoders) are not built or published by us. They are detected from Homebrew
   (`/opt/homebrew/bin`, `/usr/local/bin`) and the known install paths, or a path set in Settings › Helpers, and "Get…"
   explains how to install them (formats §2.9). One-click install stays for upstream's own signed releases (LibreOffice,
   calibre, Pandoc, Tectonic). A pair that needs one of these helpers shows its Get… notice until the helper is found.
2. **ImageIO on macOS 14.** AVIF writing is confirmed on macOS 26.5 only; the app checks at run time and falls back to
   libavif. JPEG chroma subsampling at quality ≥ 90 decides libjpeg-turbo (quality §2.3). WP-I measures both on 14.
3. **`sandbox-exec`** is deprecated; WP-H confirms it still enforces the no-network profile on 14 through 26.
4. **X3F tools licence** (formats §3.3) and **AMR encoding patents** (formats §2.7): checked by WP0b/WP-M before
   release; either can drop to "not offered" without touching the rest.
5. **Classic DWF** (W2D) decoder is timeboxed in WP-C; if it misses, DWF stays DWFx-only (formats §7).
6. **JavaScriptCore without JIT** for MathJax: WP-T measures typesetting time for formula-heavy documents (target
   < 2 s for 200 formulas); if too slow, MathJax runs in an offscreen WKWebView instead.
