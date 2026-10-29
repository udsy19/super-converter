# Formats, engines and licences

What Super Converter converts, how each conversion runs on the Mac, which engine does it, under which licence, and
which options a person can set. `quality.md` says how good each result must be and how that is tested; `ux.md` says
how it looks; `../ARCHITECTURE.md` says who builds what.

**Sources.** The format list is CloudConvert's Format Catalog as shown on cloudconvert.com on 2026-10-22 (eleven
screenshots of the catalog tabs, one per category: "CloudConvert handles 212 formats across 11 categories"). The
conversion pairs, the engine CloudConvert uses for each pair and every option it exposes come from its public API,
`GET https://api.cloudconvert.com/v2/convert/formats?include=options` (no account needed), fetched the same day:
**2,156 input → output pairs**, all `convert` operations. The snapshot is committed as
`data/cloudconvert-2026-10-22.json` (pairs, CloudConvert engine, option names; option definitions with types, defaults
and allowed values). Eight catalog formats have no pair in the API (EML, HWPX, OEB as input, SDA, SDC, SDW, SF2,
SFARK); their converter pages answer 404. We define their pairs ourselves (§6, marked ⁺).

**The matrix is generated.** `scripts/gen-format-matrix.py` reads the snapshot, applies the routing rules (one Python
function per category) and writes `data/format-matrix.json` (the data SuperConverterCore's catalog is built from, WP1)
and §6 of this file. Change a rule there, run `python3 -I scripts/gen-format-matrix.py`, commit both.

Decisions are marked **[D]**. "Built in" means it works with nothing installed: Apple's frameworks plus code shipped
inside the app. "Helper⬇" means an optional program the person installs with one click (§4).

## 1. The 212 formats

| Category | # | Formats | Colour (ux §3.2) |
|---|---:|---|---|
| Documents | 23 | ABW DJVU DOC DOCM DOCX DOT DOTX HTML HWP HWPX LWP MD ODT PAGES PDF RST RTF SDW TEX TXT WPD WPS ZABW | blue |
| Images | 42 | 3FR ARW AVIF BMP CR2 CR3 CRW DCR DNG EPS ERF GIF HEIC HEIF ICNS ICO JFIF JPEG JPG MOS MRW NEF ODD ODG ORF PEF PNG PPM PS PSB PSD PUB RAF RAW RW2 TGA TIF TIFF WEBP X3F XCF XPS | pink |
| Video | 28 | 3G2 3GP 3GPP AVI CAVS DV DVR FLV M2TS M4V MKV MOD MOV MP4 MPEG MPG MTS MXF OGG OGV RM RMVB SWF TS VOB WEBM WMV WTV | violet |
| Audio | 21 | AAC AC3 AIF AIFC AIFF AMR AU CAF DSS FLAC M4A M4B MP3 OGA OPUS SF2 SFARK VOC WAV WEBA WMA | orange |
| Spreadsheets | 8 | CSV ET NUMBERS ODS SDC XLS XLSM XLSX | green |
| Slides | 11 | DPS KEY ODP POT POTX PPS PPSX PPT PPTM PPTX SDA | coral |
| E-books | 22 | AZW AZW3 AZW4 CBC CBR CBZ CHM EPUB FB2 HTM HTMLZ LIT LRF MOBI OEB PDB PML PRC RB SNB TCR TXTZ | teal |
| Archives | 39 | 7Z ACE ALZ ARC ARJ BZ BZ2 CAB CPIO DEB DMG EML GZ IMG ISO JAR LHA LZ LZMA LZO RAR RPM RZ TAR TAR.7Z TAR.BZ TAR.BZ2 TAR.GZ TAR.LZO TAR.XZ TAR.Z TBZ TBZ2 TGZ TZ TZO XZ Z ZIP | amber |
| Vector | 10 | AI CDR CGM EMF SK SK1 SVG SVGZ VSD WMF | purple |
| CAD | 3 | DWF DWG DXF | sky |
| Fonts | 5 | EOT OTF TTF WOFF WOFF2 | lime |

CloudConvert's API files some formats under a second group (GIF and WebP also act as video inputs; PDF, PS, EPS, SVG
appear under vector and CAD outputs). We keep the catalog's category for colour and grouping and let any format be
an output wherever a pair exists. Extensions that are the same format (JPG/JPEG/JFIF, TIF/TIFF, AIF/AIFF, MPG/MPEG,
3GP/3GPP, TGZ/TAR.GZ, HTM/HTML) share one reader and writer; the output keeps the extension the person picked.

## 2. Licence policy (the app is MIT) [D]

1. **Inside the app** goes only code under permissive licences: MIT, BSD-2/3-Clause, Apache-2.0, ISC, zlib, 0BSD, and
   for fonts the SIL OFL 1.1 and the GUST Font License. It may be linked statically.
2. **LGPL code** ships only as a **separate executable** in `Contents/Helpers/` (FFmpeg's `ffmpeg`/`ffprobe`, 7-Zip's
   `7zz`) or as a **dynamic library** in `Contents/Frameworks/` (LibRaw), never statically linked, built from unmodified
   upstream source by our scripts, with the source location and licence in `THIRD_PARTY_NOTICES.md`; a person can swap
   the file. No LGPL code is compiled into our modules.
3. **MPL/CDDL** (file-level copyleft): nothing bundled in v1. LibreOffice (MPL-2.0) is a helper because of its size.
4. **GPL and AGPL code is never bundled, linked or loaded into our process.** It runs only as a separate program that
   the person chose to install (a helper, §4), driven through files and a command line. That is "mere aggregation" at
   arm's length; the MIT licence of Super Converter is unaffected. Ghostscript (AGPL), Pandoc, calibre, DjVuLibre,
   LibreDWG, x264/x265 builds of FFmpeg and sfArkLib are in this group. Their code is never copied or ported into ours.
5. **Proprietary helpers** (ODA File Converter, RARLAB's `rar`, Microsoft Office) are never redistributed: "Get…"
   opens the vendor's page, the app detects the installed program. Apple's free iWork apps come from the App Store.
6. **Ports of permissive code** (acefile → ACEKit, lzokay → LZOKit, vtracer → VectorizeKit, fontTools' cu2qu →
   FontKit, ezdxf ideas → CADKit) keep the original copyright notice in the file header, as in
   `// Adapted from <project> <path> (<licence>, <version/commit>)`.
7. **Codecs and patents.** H.264, HEVC, ProRes and AAC are encoded by Apple's VideoToolbox and AudioToolbox, licensed
   with macOS. Our FFmpeg build has no software H.264/HEVC encoder (x264/x265 are GPL anyway); AV1, VP8/VP9, Opus,
   Vorbis, Theora and FLAC are royalty-free; MP3 and AC-3 patents have expired. **AMR encoding is not offered [D]**
   (checked in WP-M, 2026-10): AMR-NB (3GPP, 1999) and AMR-WB (2001) are licensed through VoiceAge's patent pool, which
   claims about 150 essential patents; the core filings look expired, but no statement from the pool or 3GPP confirms
   that every family has lapsed (public sources disagree on the last AMR-WB families), so the bundled FFmpeg is built
   without any AMR encoder (no opencore-amr / vo-amrwbenc) and AMR → AMR is "not offered" (§7). Decoding AMR to other formats stays:
   the pool has licensed PC playback free of charge. Revisit with a patent attorney's opinion or a pool statement.
8. **Every bundled component** is listed with version, SHA-256, licence text and source URL in
   `THIRD_PARTY_NOTICES.md`, which the app shows in Settings › About.
9. **Where helpers come from [D].** (a) Upstream's own signed release when there is one (LibreOffice, calibre, Pandoc,
   Tectonic): one click installs it, pinned version + SHA-256, Apple code signature and notarisation checked before first
   run. (b) Vendor pages for proprietary tools (ODA File Converter, RARLAB's `rar`) and the App Store for iWork: "Get…"
   opens the page. (c) GPL/AGPL tools with no official macOS build (Ghostscript, DjVuLibre, LibreDWG, the sfArk tool,
   FFmpeg with GPL encoders) are **only detected** where people already have them (Homebrew's `/opt/homebrew/bin` and
   `/usr/local/bin`, the known install paths, or a path set in Settings › Helpers); "Get…" explains how to install them
   (`brew install ghostscript`). There is no public helpers repository: we do not build or publish those binaries.

## 3. Built-in engines

### 3.1 Apple frameworks (always present, macOS 14+)

| Engine id (in §6) | Framework | Does |
|---|---|---|
| `ImageIO` | ImageIO | Decode AVIF, BMP, GIF (animated), HEIC/HEIF, ICNS, ICO, JPEG, PNG, PBM/PGM/PPM, PSD (composite), TGA, TIFF, WebP (animated), JPEG 2000, JPEG XL, OpenEXR, DNG; encode BMP, GIF, HEIC, ICNS, ICO, JPEG, JPEG 2000, PNG, PSD, TGA, TIFF, PDF, and AVIF where `CGImageDestinationCopyTypeIdentifiers()` lists `public.avif` (it does on macOS 26.5; checked at run time, never assumed) |
| `CIRAWFilter` | Core Image | Develops camera RAW: 3FR, ARW, CR2, CR3, CRW, DCR, DNG, ERF, MOS, MRW, NEF, ORF, PEF, RAF, RAW, RW2 (934 camera models on macOS 26.5, `CIRAWFilter.supportedCameraModels`). Not Sigma X3F. |
| `ImagePipeline` | Core Image + vImage + ColorSync | Every pixel operation between decode and encode: orientation, linear-light Lanczos resampling, fit/crop/pad, ICC conversion with intent and black-point compensation, bit depth with dithering, alpha flattening, quantisation for GIF (quality §2) |
| `CGPDF` / `RenderKit` | Core Graphics + PDFKit | Write PDF (tagged, fonts embedded and subset, PDF/A-2b via `kCGPDFContextOutputIntents`), render PDF pages at any DPI through ColorSync |
| `VectorKit` input `CGPDFScanner` | Core Graphics | Read PDF content streams (paths, text, images, shadings, clips, transparency groups) into the vector model |
| `TextKitImport` / `TextKitExport` | AppKit (`NSAttributedString` document types) | Read and write RTF, RTFD, `.doc` (Word 97), `.docx`, `.odt`, HTML, plain text — the same importers as `textutil` |
| `WebKit print` / `WebKit snapshot` | WebKit (`WKWebView` offscreen, never shown) | HTML as a web page → PDF (`printOperation` with @page CSS) or PNG/JPG (`takeSnapshot`); SVG with CSS, filters or `foreignObject` → PDF |
| `MathKit` host | JavaScriptCore | Runs MathJax (bundled JS) without a DOM to turn TeX math into SVG paths |
| `AVFoundation + VideoToolbox / AudioToolbox` | AVFoundation, VideoToolbox, AudioToolbox | Read/write MOV, MP4, M4V, 3GP/3G2, M4A, M4B, CAF, AIFF, WAV, ADTS AAC, FLAC; encoders on this Mac: H.264, HEVC (also with alpha), ProRes 422 Proxy/LT/422/HQ, 4444, 4444 XQ, MJPEG; AAC-LC, HE-AAC v1/v2, AAC-LD/ELD, ALAC, FLAC, Opus, A-law, µ-law, iLBC, IMA4, LPCM (`kAudioFormatProperty_EncodeFormatIDs`, `VTCopyVideoEncoderList`, checked 2026-10-22) |
| `Vision` | Vision | Text recognition for scanned PDF pages and comic/DjVu pages when "Recognise text" is on |
| `hdiutil` | macOS command | Attach a DMG read-only and unmounted from Finder (`-readonly -nobrowse -mountrandom`), detach after copying |
| `QuickLookThumbnailing` | Quick Look | Card thumbnails (ux) — not a conversion engine |
| `Pages / Numbers / Keynote app` | Apple Events | Listed under helpers (§4): free Apple apps, driven only after the person allows automation |

### 3.2 Our own modules (MIT, in this repository)

| Engine id | Module | Does |
|---|---|---|
| `ImageCodecs` | ImageKit | Own decoders for PSB (Photoshop "big" composite), XCF (GIMP: visible layers composited, Normal/Multiply/Screen/Overlay modes, RLE/zlib tiles; spec `devel-docs/xcf.txt`), PPM/PGM/PBM/PAM when ImageIO lacks a variant; own writers for PPM |
| `PSWriter` | VectorKit | PostScript Level 3 and EPS 3.0: vector pages from the vector model (paths, gradients as shading dictionaries, fonts embedded as Type 42 or converted to outlines) and raster pages (Flate or DCT, ICCBased colour) |
| `ODFReader` / `ODFWriter` | OfficeKit | OpenDocument Drawing with one embedded picture (what converters call `.odd`); anything richer goes to LibreOffice |
| `AVIFEncoder` | ImageKit | ImageIO when it lists AVIF, else libavif (§3.3) |
| `VectorizeKit` | VectorizeKit | Raster → SVG tracing; Swift port of vtracer (MIT): colour clustering, spline/polygon/pixel fitting, speckle filter, presets bw/poster/photo |
| `SVGReader` / `SVGWriter` | VectorKit | SVG 1.1 + common SVG 2 (paths, shapes, transforms, gradients, patterns, clip, mask, text with font fallback, images, `use`/`symbol`, CSS cascade subset); WebKit renders what the reader flags as unsupported (filters, `foreignObject`) |
| `EMFReader` / `EMFWriter` / `WMFReader` / `WMFWriter` | VectorKit | Windows metafiles: the ~70 records real files use (paths, poly-Béziers, pens/brushes, gradients, DIB/StretchDIBits, ExtTextOutW, clipping, world transform, EMF+ dual records read for anti-aliased content) |
| `DXFWriter` / `DXFReader` / `CADKit` | CADKit | ASCII + binary DXF R12–2018: LINE, LWPOLYLINE, POLYLINE (2D/3D/mesh), CIRCLE, ARC, ELLIPSE, SPLINE (NURBS), TEXT, MTEXT (with formatting codes), INSERT (blocks, attributes, arrays), HATCH (pattern + solid + gradient), DIMENSION (via its anonymous block), LEADER/MLEADER, SOLID, 3DFACE, POINT, IMAGE, VIEWPORT, layouts/paper space, layers, linetypes, lineweights, ACI/true colour, SHX/TTF text styles mapped to bundled fonts; plotting to the vector model; written with ezdxf (MIT) as the behavioural reference |
| `DWFReader` | CADKit + XPSKit | DWFx (an XPS package) through XPSKit; DWF 6 W2D opcode streams with an own decoder from Autodesk's published W2D format description (P3, see §7) |
| `CGMWriter` | VectorKit | Binary CGM (ISO 8632) version 1 profile: polylines, polygons, ellipses, text, colour table |
| `XPSKit` / `XPSWriter` | XPSKit | XPS / OpenXPS: FixedDocumentSequence, FixedPage Path/Glyphs/Canvas, Solid/Linear/Radial/Image/Visual brushes, obfuscated fonts (GUID XOR), resources; written from the vector model |
| `DocModel` + readers/writers | DocKit | The semantic document hub (headings, paragraphs with inline styles, lists, tables, figures, footnotes, math, code, quotes, page breaks, metadata). Readers: `DOCXReader` (own OOXML), `ODTReader` (own ODF), `MarkdownReader` (own CommonMark + GFM parser with `$…$` math, footnotes and front matter), `HTMLReader` (own tolerant HTML parser: no web process, scripts ignored, nothing fetched), `PlainTextReader` (encoding detection, prose vs. code), `AbiWordReader`, `HWPReader` (HWP 5 OLE records, Hancom's published spec), `HWPXReader` (from Super PDF), `MailReader` (MIME, from Super PDF). Writers: `DOCXWriter` (from Super PDF's WordWriter), `ODTWriter`, `HTMLWriter`, `MarkdownWriter` (CommonMark/GFM/Pandoc/MultiMarkdown), `RSTWriter`, `LaTeXWriter` (article/report/book with `lmodern` + `microtype`), `TextWriter` |
| `TypesetKit` | TypesetKit | DocModel → PDF with the LaTeX look (quality §3): Knuth–Plass paragraphs, Latin Modern at optical sizes, LaTeX article/book metrics, floats, footnotes, booktabs tables, MathKit math, tagged PDF and bookmarks. Also "as written" (the document's own fonts and sizes) |
| `LayoutKit` | LayoutKit (copied from Super PDF) | PDF → words, lines, paragraphs, columns, headings, lists, tables, figures, reading order (with Vision OCR on scans) → DocModel / Workbook / slides |
| `SlideReader` / `SlideRenderer` / `PPTXWriter` | OfficeKit (from Super PDF ConvertKit) | Own PPTX reader and renderer (text, pictures, shapes, themes, backgrounds; no animations, SmartArt drawn from its fallback picture) and PPTX writer |
| `XLSXReader` / `XLSXWriter` / `ODSReader` / `ODSWriter` / `CSVReader` / `CSVWriter` / `Workbook` | OfficeKit | Spreadsheets as a workbook model (sheets, cells, number formats, merged cells, widths, styles, formulas kept as text + cached values) |
| `EbookKit` + `EPUBReader`, `OEBReader`, `FB2Reader`, `HTMLZReader`, `TXTZReader`, `ComicReader`, `CHMReader` | EbookKit | The publication hub (spine, TOC, metadata, cover, resources) and EPUB 2/3 + OEB 1.2 writers; comics as fixed layout |
| `ArchiveKit`, `LZOKit`, `ACEKit`, `ARCKit`, `RZipKit` | ArchiveKit | Archive model over libarchive and 7zz; own decoders: LZO1X (port of lzokay, MIT) with lzop framing, ACE 1.0/2.0 (port of acefile, BSD-2), ARC (stored/packed/squeezed/crunched/squashed, clean-room from the format description), rzip (bzip2 blocks + long-distance match stream, clean-room) |
| `MediaKit` | MediaKit | Plans an audio/video job: probes with `ffprobe`/AVFoundation, picks AVFoundation or FFmpeg, maps options to settings/arguments, parses progress, verifies the output |
| `SoundFontReader` | MediaKit | SF2 (RIFF sfbk): presets, instruments, sample headers → WAV per sample + SFZ mapping |
| `FontKit` + `SFNTReader`, `WOFFReader`/`Writer`, `WOFF2Reader`/`Writer`, `EOTReader`/`Writer`, `CFFBuilder`, `GlyfBuilder`, `SVGFontReader`/`Writer` | FontKit | SFNT tables in and out; TrueType ↔ CFF outline conversion (quadratic → cubic exact; cubic → quadratic with cu2qu, ported from fontTools, MIT, max error 1/1000 em); WOFF 1 (zlib) and WOFF 2 (google/woff2); EOT (uncompressed and XOR-obfuscated; MicroType Express compressed EOT decoded from the W3C MTX submission, P3) |
| `PDFOps` | ConvertKit | PDF → PDF: page selection, split, encrypt/decrypt (PDFKit write options, AES-256), permissions, image watermark above/below, PDF/A-2b through RenderKit |

### 3.3 Bundled third-party code

| Component | Licence | Ships as | Used by |
|---|---|---|---|
| libwebp 1.5 | BSD-3-Clause | static, xcframework | WebP encode (still and animated) |
| libavif 1.x + SVT-AV1 (lossy encode) + libaom (lossless 4:4:4 encode) + dav1d (decode) | BSD-2-Clause; BSD-3-Clause-Clear with AOM patent licence; BSD-2-Clause with AOM patent licence; BSD-2-Clause | static, xcframework | AVIF when ImageIO cannot write it; lossless AVIF always |
| libarchive 3.8 (+ liblzma 0BSD, zstd BSD-3, lz4 BSD-2; system zlib, bzip2, iconv) | BSD-2-Clause | static, xcframework | Most archive reading and all ZIP/TAR/7Z writing, CBR/CBZ |
| libxls | BSD-2-Clause | static (C target) | XLS (BIFF5/8) reading |
| google/woff2 + Brotli | MIT | static (C++ target) | WOFF2 read/write |
| unalz | zlib | static (C++ target) | ALZ reading |
| MathJax 4 (SVG output, TeX input) | Apache-2.0 | JS resource | Math in TypesetKit and HTML output |
| Latin Modern Roman/Sans/Mono (optical sizes 5–17) + Latin Modern Math | GUST Font License | OTF resources | The LaTeX look |
| CMU Serif/Sans/Typewriter (Computer Modern Unicode) | SIL OFL 1.1 | OTF resources | Greek and Cyrillic in the LaTeX look |
| STIX Two Math | SIL OFL 1.1 | OTF resource | Math glyphs Latin Modern Math lacks |
| Carlito, Caladea | SIL OFL 1.1 | TTF resources | Metric-compatible stand-ins for Calibri and Cambria in the "As written" look (quality §3.5) |
| **FFmpeg 7.1 LGPL build** (`--enable-version3`, no `--enable-gpl`, no `--enable-nonfree`) with libvpx (BSD-3), SVT-AV1, dav1d, libopus (BSD-3), libvorbis/libogg (BSD-3), libtheora (BSD-3), LAME (LGPL-2.0), libwebp, soxr (LGPL-2.1), zimg (WTFPL), libass (ISC) with HarfBuzz (MIT), FreeType (FTL) and FriBidi (LGPL-2.1); VideoToolbox and AudioToolbox enabled | LGPL-3.0-or-later as a whole | **separate executables** `ffmpeg`, `ffprobe` in `Contents/Helpers/` | Every audio/video pair AVFoundation cannot do alone |
| **7-Zip 25 `7zz`** | LGPL-2.1 + BSD-3 parts + unRAR licence restriction (may not be used to re-create RAR compression) | **separate executable** | Encrypted 7z/ZIP/RAR, ARJ, IMG (FAT/NTFS/MBR/GPT), UDF ISO, Quantum CAB, CHM extraction |
| **LibRaw 0.21** built with `USE_X3FTOOLS` | LGPL-2.1 or CDDL-1.0 (we take LGPL-2.1); X3F tools code BSD-style | **dynamic library** `libraw_r.dylib` | Sigma X3F only (WP-I verifies the X3F tools licence before shipping; without it X3F becomes a P3 gap) |

## 4. Helpers (optional, one click)

A helper is a program the person installs when a conversion needs it. The card says why and how big it is
("Needs LibreOffice — free, 360 MB download") with one **Install** button (or **Get…** for apps that must come from
their vendor); the conversion resumes by itself when the helper is ready (ux §6). Helpers live in
`~/Library/Application Support/Super Converter/Helpers/<id>/<version>/` unless they are apps, which go to
`~/Applications` (no administrator password, visible like any app). Every helper is also detected where people
already have it. A helper process runs with a scrubbed environment, a private temporary folder, a time limit per
file, `nice` priority and no network (`sandbox-exec` profile denying network for command-line helpers; LibreOffice
with `--norestore --nologo --headless` and a private profile).

| Helper id | Unlocks | Licence | One-click source (pinned + SHA-256) | Download | Detected at | Run as |
|---|---|---|---|---|---|---|
| `libreoffice` | LWP, SDW, WPD, WPS, ET, SDC, DPS, SDA, PPT/PPS/POT, ODP, ODG, PUB, CDR, VSD, CGM input; DOC/XLS/PPT/ODP output; original office layout | MPL-2.0 | Official signed DMG from download.documentfoundation.org → `~/Applications/LibreOffice.app` | ~360 MB (1 GB installed) | `/Applications`, `~/Applications`, Homebrew cask, Settings override | `soffice --headless --convert-to … -env:UserInstallation=…` (code from Super PDF's helper) |
| `iwork` | PAGES, NUMBERS, KEY input and output; best PPT/PPTX/XLS → PDF when present | Apple licence (free) | **Get…** opens the App Store page | — | `/Applications/{Pages,Numbers,Keynote}.app` | Apple Events (`NSAppleEventsUsageDescription`); "Pages will open briefly" notice; quits the app only if we launched it |
| `msoffice` | Best DOC/DOCX/XLS/XLSX/PPT/PPTX → PDF when Microsoft Office is installed | Proprietary | none (detect only) | — | `/Applications/Microsoft *.app` | Apple Events |
| `calibre` | AZW, AZW3, AZW4, LIT, LRF, MOBI, PDB, PML, PRC, RB, SNB, TCR input; AZW3, MOBI, LRF, PDB output | GPL-3.0 | Official signed DMG from download.calibre-ebook.com → `~/Applications/calibre.app` | ~160 MB | `/Applications`, `~/Applications` | `calibre.app/Contents/MacOS/ebook-convert in.x out.epub` |
| `pandoc` | RST input; TEX → anything but PDF | GPL-2.0+ | Official `pandoc-<v>-arm64-macOS.zip` / `x86_64` from GitHub releases | ~35 MB | Homebrew, `/usr/local/bin` | `pandoc -t json` → our DocModel (we read Pandoc's AST, never its writers) |
| `tectonic` | TEX → PDF (a real LaTeX run) | MIT | Official release tarball from GitHub; the install compiles a warm-up document that caches the common packages, after which runs use `--only-cached` (offline). An installed MacTeX (`/Library/TeX/texbin/latexmk`) is used instead when present | ~25 MB + ~120 MB cache | MacTeX, Homebrew | `tectonic -X compile --only-cached --outdir …` |
| `ghostscript` | EPS, PS input; legacy (non-PDF) AI | AGPL-3.0 | **Get…** explains `brew install ghostscript` (§2.9c) | — | Homebrew | `gs -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pdfwrite …` |
| `djvulibre` | DJVU input | GPL-2.0+ | **Get…** explains `brew install djvulibre` | — | Homebrew | `ddjvu -format=pdf` |
| `oda` | DWG input and output (all AutoCAD versions) | Proprietary freeware (ODA EULA) | **Get…** opens opendesign.com's ODA File Converter page | — | `/Applications/ODAFileConverter.app` | `ODAFileConverter <in> <out> ACAD2018 DXF 0 1 *.DWG` |
| `libredwg` | DWG input and output when ODA is absent (DWG R13–2018 read; write experimental) | GPL-3.0 | **Get…** explains `brew install libredwg` | — | Homebrew | `dwg2dxf`, `dxf2dwg` |
| `ffmpeg-gpl` | CAVS output (libxavs); optional x264/x265 software encoders for people who want them | GPL-2.0+ | **Get…** explains `brew install ffmpeg` (a build with `--enable-gpl`) | — | Homebrew `ffmpeg` built with `--enable-gpl` | separate `ffmpeg` executable |
| `rar` | RAR output | Proprietary (RARLAB, shareware) | **Get…** opens rarlab.com | — | `rar` on `PATH`, Homebrew | `rar a -ma5 -m3 …` |
| `sfark` | SFARK input | GPL-3.0 (sfArkLib) | **Get…** explains building `sfarkxtc` from source | — | `/opt/homebrew/bin`, `/usr/local/bin` | `sfarkxtc in.sfark out.sf2` |

Helpers never run automatically on download; the first run of each is the conversion the person asked for. Settings ›
Helpers lists every helper with status, version, size on disk, licence, **Remove**, and **Look again**.

## 5. Option profiles

Every pair in §6 names one option profile. A profile is a base plus modifiers (`O-IMG+Q+DPI` = O-IMG, the quality
module and the render-density module). For each option: the CloudConvert option it matches (so people moving over find
the same control), its type and range, our default, and notes. ⁺ marks options CloudConvert does not offer. The options
sheet (ux §5) shows the first three or four as plain controls and the rest under "More options". Defaults are chosen
for the best result first, size second (quality.md says why and how each is tested).

### O-IMG — raster image output

| Option | CloudConvert | Type / range | Default | Notes |
|---|---|---|---|---|
| Size | `width`, `height` | px, either or both | original | Shown as "Original · 50% · 25% · Custom…" and a lock |
| Fit | `fit` = max / crop / scale | max · crop · scale · pad⁺ | max | max never enlarges; pad adds background to reach the exact box |
| Background⁺ | — | colour / transparent | white for JPG/BMP, keep alpha elsewhere | Used when flattening alpha or padding |
| Colour profile⁺ | — | Keep · sRGB · Display P3 · Adobe RGB (1998) · ProPhoto RGB · Gray Gamma 2.2 · Generic CMYK · Choose ICC… | Keep (quality §2.2 has the per-format exceptions) | Converted with ColorSync, relative colorimetric + black-point compensation |
| Rendering intent⁺ | — | relative colorimetric · perceptual | relative colorimetric | |
| Bit depth⁺ | — | Keep · 8 · 16 | Keep where the format allows | Ordered → error-diffusion dither when reducing |
| Metadata | `strip` (bool) | All · All but location⁺ · None | All | EXIF, IPTC, XMP, GPS; ICC is colour, never stripped |
| Auto-rotate | `auto_orient` | bool | on | Applies EXIF orientation and resets the tag |
| Pages / frames | `pages` | range "1-3,5" | all (multi-page and animated sources write one file per page/frame, except GIF/WebP/TIFF/ICNS/ICO which hold several) | |
| **+Q** Quality | `quality` | 1–100 | JPG 90, HEIC 85, WebP 90 (lossless for graphic sources), AVIF 80 | quality §2.3 |
| **+Q** Lossless⁺ | — | bool (WebP, AVIF, HEIC) | auto: on for PNG/GIF/BMP/ICO/TGA/PPM sources | |
| **+Q** Chroma⁺ | — | 4:2:0 · 4:4:4 | 4:4:4 at quality ≥ 90, else 4:2:0 (AVIF, WebP) | |
| **+Q** Progressive⁺ | — | bool (JPG) | on | |
| **+GIF** Colours⁺, Dither⁺, Loop⁺ | — | 2–256; Floyd–Steinberg · ordered · none; forever · once · n | 256, Floyd–Steinberg, forever | Own Lab median-cut quantiser |
| **+ICON** Sizes⁺ | — | ICO: 16 24 32 48 64 128 256; ICNS: 16–1024 @1x/@2x | ICO all seven; ICNS all ten | Small sizes sharpened after downscale (quality §2.4) |
| **+TIFF** Compression⁺, Multi-page⁺ | — | LZW · ZIP · none · JPEG; bool | LZW with predictor; multi-page on | |
| **+PS** PostScript level⁺, Encoding⁺, Preview⁺ | — | 2 · 3; Flate · JPEG; none · TIFF | 3, Flate, none | Raster EPS/PS |
| **+DPI** Render density | `pixel_density` | 36–2400 dpi, or Scale⁺ 1×–8× | vector/drawing sources: 96 dpi (1×); documents: 300 dpi | Used when the source has no pixels (EPS, PS, XPS, SVG, ODG, PUB, CAD) |
| RAW only⁺: White balance, Exposure, Highlights, Noise reduction, Lens correction, Look | — | As shot · Auto · Kelvin; −4…+4 EV; 0–1; auto/off; on/off; Apple · Neutral | As shot, 0, auto, auto, on, Apple | `CIRAWFilter` properties; X3F via LibRaw uses camera WB |

### O-IMG-PDF — image → PDF

O-IMG's colour and metadata options, plus: Page size⁺ (Fit image · A4 · Letter · …, default Fit image), Margin⁺
(0 / 10 / 20 mm, default 0 when fitting), Orientation⁺ (auto), **Combine into one PDF⁺** (default on when several
images go to PDF at once), JPEG/JPEG 2000 pass through without re-encoding⁺ (always), `width`/`height`/`fit` as in O-IMG.

### O-TRACE — raster → SVG (vectorise)

| Option | CloudConvert (`vtracer`) | Range | Default |
|---|---|---|---|
| Preset | `preset` | bw · poster · photo | chosen from the image: ≤ 2 colours → bw, ≤ 16 → poster, else photo |
| Curve fitting | `mode` | spline · polygon · pixel | spline |
| Remove specks | `filter_speckle` | 0–128 px | 4 |
| Colour precision | `color_precision` | 1–8 bits | 6 |
| Simplify | `simplify` | 0–10 px | off |
| Colours⁺ | — | auto · 2–64 | auto |

### O-VEC — vector output (SVG, EPS, PS, EMF, WMF, DXF, CGM, PDF, XPS)

| Option | CloudConvert | Type | Default | Notes |
|---|---|---|---|---|
| Text as outlines | `text_to_path` | bool | off (on for DXF and CGM) | Off keeps text selectable and embeds fonts (Type 42 in PS, WOFF2 subset in SVG) |
| Pages / artboards | — (implicit) | range | all (one file per page for single-page formats) | |
| Render density | `pixel_density` | dpi | 96 | Only for effects that must be rasterised (soft masks to EMF, mesh shadings to WMF) |
| Size | `width`, `height` | px | natural | PNG/raster only |
| DXF units⁺, DXF version⁺ | — | mm · cm · m · in · ft; R12–2018 | mm, 2018 | |
| PDF/A⁺ | — | bool | off | PDF output |
| EPS preview⁺ | — | none · TIFF | none | |

### O-RENDER — documents and pages → images

| Option | CloudConvert | Type | Default |
|---|---|---|---|
| Resolution | `pixel_density` | 36–1200 dpi | 300 (150 for "screen" preset⁺) |
| Size | `width`, `height` | px | from resolution |
| Pages | `pages` | range | all; one file per page, named "Report – page 1.png" |
| Transparent background | `alpha` | bool (PNG) | off |
| Quality | `quality` | 1–100 (JPG) | 90 |
| Colour⁺ | — | sRGB · Display P3 · keep | sRGB, rendered through ColorSync from the page's own spaces |
| **+SHEET** | `sheet`, `pages_fit_wide`, `pages_fit_tall`, `use_print_areas` | see O-SHEET-PDF | |

### O-DOC-PDF — documents → PDF

| Option | CloudConvert | Type | Default | Notes |
|---|---|---|---|---|
| Look⁺ | — | Original layout · As written · LaTeX | Office files: Original when a helper can render it, else As written. Markdown, text, reStructuredText, e-mail, HTML-as-document, e-books: LaTeX | Original = LibreOffice / Word / Pages render; As written = TypesetKit with the document's fonts and sizes; LaTeX = TypesetKit with Latin Modern and LaTeX metrics (quality §3) |
| Paper⁺ | — | A4 · Letter · Legal · A5 · B5 · A3 · Custom | from the Mac's region (Letter in US/CA/MX/PH/CL/CO/VE, else A4); Original keeps the document's | |
| Margins⁺ | — | LaTeX default · narrow · wide · custom mm | LaTeX default (quality §3.2) | |
| Base size⁺ | — | 10 · 11 · 12 pt | 10 pt | LaTeX `article` default |
| Font⁺ | — | Latin Modern · Latin Modern Sans · document's own | Latin Modern | LaTeX look only |
| Columns⁺ | — | 1 · 2 | 1 | |
| Numbered sections⁺ | — | auto · on · off | auto: on when ≥ 3 top-level headings and none already numbered | |
| Contents page⁺ | — | bool | off (on for ≥ 12 headings in e-books) | |
| Hyphenation⁺, Language⁺ | — | bool; auto (NaturalLanguage) or chosen | on; auto | |
| Pages | `pages` | range | all | Original route |
| PDF/A | `pdf_a` | off · PDF/A-1b · PDF/A-2b⁺ | off | CloudConvert writes PDF/A-1 |
| Bookmarks from headings | `bookmarks` | bool | on (CloudConvert: off) | |
| Tracked changes and comments | `include_markup` | bool | off (final text) | |
| Optimise for | `optimize_print` | print · screen | print | screen downsamples pictures to 150 dpi |
| Password | `password` | string | — | To open a protected source |
| **+TXT** Treat as⁺, Encoding⁺, Tab width⁺ | — | auto · prose · code; auto · UTF-8 · … ; 2–8 | auto, auto, 8 | Code keeps line breaks in Latin Modern Mono |

### O-WEB — HTML as a web page → PDF (`WebKit print`; CloudConvert's `chrome` options, all kept)

`pages`, `zoom` (1), `page_width`/`page_height` (cm), `page_format` (letter · legal · tabloid · ledger · A0–A6; default
from region), `page_orientation` (portrait), `margin_top/bottom/left/right` (mm; default 10), `print_background` (on),
`display_header_footer` (off), `header_template`/`footer_template` (classes `date`, `title`, `url`, `pageNumber`,
`totalPages`), `wait_until` (load · domcontentloaded · networkidle0 · networkidle2), `wait_for_element`, `wait_time`
(ms), `css_media_type` (print · screen). ⁺ **Load web resources** (off): a local HTML file's remote pictures, fonts
and styles are fetched only if the person turns this on for the file — nothing leaves the Mac by default.

### O-WEB-SHOT — HTML → PNG/JPG

`screen_width` (1440), `screen_height` (full page), `device_scale_factor` (2), `wait_until`, `wait_for_element`,
`wait_time`, `quality` (JPG, 90; CloudConvert 80), ⁺ Load web resources (off).

### O-DOC / O-DOC+MD — documents → DOC, DOCX, ODT, RTF, HTML, MD, RST, TEX, TXT, PAGES

| Option | CloudConvert | Default | Notes |
|---|---|---|---|
| Password | `password` | — | Source password |
| Embed pictures (HTML) | `embed_images` | on (CloudConvert: off) | Off writes a "<name> files" folder |
| Markdown flavour (output) | `output_markdown_syntax` = strict · mmd · pandoc · github | github | strict = CommonMark |
| Markdown flavour (input) | `input_markdown_syntax` | auto | |
| Tracked changes⁺ | — | accept | accept · reject · keep as markup (DOCX/ODT) |
| Text encoding⁺, Line endings⁺, Wrap⁺ | — | UTF-8 without BOM, LF, none | TXT/MD/RST/TEX |
| LaTeX class⁺ | — | article (report/book when the source has chapters) | TEX output uses `lmodern`, `microtype`, `booktabs`, `hyperref` |
| Math⁺ | — | MathML in HTML/EPUB, OMML in DOCX, `$…$` in MD | |

### O-PDF-OFFICE, O-PDF-SHEET, O-PDF-HTML, O-PDF-TXT — PDF → editable

| Option | CloudConvert | Default | Profiles |
|---|---|---|---|
| Pages | `pages` | all | all |
| Password | `password` | — | all |
| Join hyphenated words | `connect_hyphens` | on (CloudConvert: off) | OFFICE |
| Look over editability | `prioritize_visual_appearance` | off (reflowable text) | OFFICE |
| Recognise text in scans | `images_ocr` | on (Vision; languages auto) | OFFICE, SHEET, TXT |
| Text outside tables | `non_table_content` | off | SHEET |
| All tables on one sheet | `single_sheet` | off | SHEET |
| Mode⁺ | — (pdf2htmlEX is always positioned) | Reflow | HTML: Reflow (readable HTML) · Positioned (looks like the PDF: one SVG page with selectable text) |
| `outline`, `zoom`, `width`, `height`, `embed_css`, `embed_javascript`, `embed_images`, `embed_fonts`, `split_pages`, `bg_format` (png · jpg · svg) | pdf2htmlEX's | off, 1.5, —, on, on, on, on (WOFF2 subsets), off, svg | HTML, positioned mode |
| Layout⁺ | — | reading order | TXT: reading order · as on the page (columns kept with spaces) |

### O-PDF-PDF — PDF → PDF (CloudConvert's `qpdf` options, all kept)

`pages`, `split_pages` (off), `password`, `encryption` (unchanged · remove · encrypt), `set_password`,
`set_owner_password`, `allow_accessibility`, `allow_extract`, `allow_modify` (all · annotate · form · assembly · none),
`allow_print` (full · low · none), `watermark_image` (a PDF), `watermark_pages`, `watermark_layer` (above · below).
⁺ PDF/A-2b, ⁺ Make smaller (picture downsampling 150/300 dpi), ⁺ Remove metadata.

### O-TEX — LaTeX → PDF (helper)

Engine⁺ (XeTeX via Tectonic; pdfLaTeX/LuaLaTeX via `latexmk` when MacTeX is installed), Reruns⁺ (automatic until
cross-references settle, max 5), Bibliography⁺ (biber/bibtex when the project has `.bib` files — the person drops the
folder or a ZIP of the project), Shell escape⁺ (always off).

### O-SHEET-PDF, O-SHEET-OUT, O-CSV — spreadsheets

| Option | CloudConvert | Default | Profiles |
|---|---|---|---|
| Sheet | `sheet` (index or name) | all sheets | all |
| Password | `password` | — | all |
| Fit to pages wide / tall | `pages_fit_wide`, `pages_fit_tall` | from the file; else 1 wide | PDF |
| Print areas | `use_print_areas` | off | PDF |
| Decimal / thousands separator | `decimal_separator`, `thousands_separator` | from the file's locale | PDF, CSV |
| Look⁺ | — | Original (helper) / grid as laid out / LaTeX (booktabs) | PDF; CSV always LaTeX |
| Gridlines⁺, Orientation⁺, Paper⁺ | — | as set in the file; auto landscape when wider than tall | PDF |
| Delimiter⁺, Quote⁺, Encoding⁺, Values⁺ | — | comma, `"`, UTF-8 (⁺ "for Excel": UTF-8 with BOM), as displayed | CSV |
| One CSV per sheet⁺ | — | on when several sheets (zipped) | CSV |
| Formulas⁺ | — | keep (helper) / values (built in) | XLSX/ODS/XLS output |

### O-DECK, O-DECK+IMG, O-DECK-VIDEO — presentations

`hidden_slides` (off), `output_type` (slides · handout), `slides_per_handout_page` (6), `first_slide_number`, `pages`,
`password`; ⁺ speaker notes (off · notes pages); +IMG: `width`, `height`, `pixel_density` (300), `quality` (90);
+VIDEO⁺: seconds per slide (5), size (1920×1080), frame rate (30).

### O-EBOOK, O-EBOOK-PDF, O-COMIC — e-books (CloudConvert exposes no e-book options; all ours)

| Option | Default | Notes |
|---|---|---|
| EPUB version | 3 | 2 for old readers |
| Cover | keep (generate a typeset cover from title/author when missing) | |
| Table of contents | keep, else from headings | |
| Embed fonts | subset | EPUB |
| Metadata | from the source; editable title, author, language | |
| Device profile (calibre outputs) | Kindle for AZW3/MOBI, generic e-ink for LRF/PDB | `--output-profile` |
| MOBI type | both (old + KF8) | `--mobi-file-type` |
| **PDF**: trim size | A5 (148 × 210 mm) · 6 × 9 in · A4 · Letter | LaTeX `book` metrics scaled to the trim |
| **PDF**: base size | 10 pt (11 for A4/Letter) | |
| **PDF**: running heads, chapter openings | chapter title in the head; chapters start on a new page (right-hand only when two-sided⁺ is on) | |
| **COMIC**: page size, reading direction | each page the picture's size; left-to-right (right-to-left sets PDF `/Direction /R2L`) | Pictures are never recompressed |

### O-ARCHIVE — archives

| Option | CloudConvert | Default | Notes |
|---|---|---|---|
| Password to open | `password` | — | Asked on the card when an archive turns out to be encrypted |
| Compression⁺ | — | normal | fast · normal · smallest |
| Password for the new archive⁺ | — | none | ZIP: AES-256 (⁺ "compatible ZipCrypto"); 7Z: AES-256 with encrypted file names |
| Split into parts⁺ | — | off | 100 MB · 700 MB · 4 GB · custom |
| Keep Mac extras⁺ | — | off | off drops `__MACOSX`, `._*`, `.DS_Store`; on stores extended attributes in TAR (PAX) |
| Unpack package payload⁺ | — | on | DEB `data.tar.*`, RPM cpio |
| File-name encoding⁺ | — | auto | CP437, Shift-JIS, GBK, EUC-KR detected for old ZIPs |

Single-file compressors (GZ, BZ2, XZ, LZ, LZMA, Z, LZO, RZ) hold one file: converting to an archive puts that file in
it under its own name; converting `.gz` → `.tar.gz` is not a re-wrap of the tar unless the content is a tar.

### O-VIDEO — video

| Option | CloudConvert | Type | Default | Notes |
|---|---|---|---|---|
| Video codec | `video_codec` | per container, below | per container, below | "copy" keeps the stream when the container allows |
| Quality | `crf` | 0–51 (x264 scale; lower = better) | 20 (CloudConvert 23; VP9/AV1 31 → ours 30) | Mapped to VideoToolbox constant quality by a measured table (quality §5) |
| Speed | `preset` | ultrafast…veryslow | medium → VideoToolbox "quality" mode; SVT-AV1 preset 6; libvpx `-cpu-used 2` | |
| Tune | `tune` | film · animation · grain · stillimage · fastdecode · zerolatency · psnr · ssim | none | Applies to the GPL x264 helper; VideoToolbox ignores it (shown disabled with a reason) |
| Profile / level | `profile`, `level` | H.264 baseline…high444, ProRes proxy…4444xq; levels 1–5.2 | auto (high / level from size and frame rate) | |
| Size / fit | `width`, `height`, `fit` = max · crop · scale · pad | | original, scale | Lanczos, correct BT.601/709 matrix (quality §5) |
| Frame rate | `fps` | number | source | |
| Keyframe interval | `keyframe_interval` | frames | 2 s worth | |
| Aspect ratio | `aspect_ratio` | "16:9" | source | |
| Audio codec, bitrate, volume, channels, sample rate | `audio_codec`, `audio_bitrate`, `volume`, `channels`, `sample_rate` | | AAC-LC 192 kb/s (CloudConvert 128); MP4/MOV copy when already AAC | as O-AUDIO |
| All audio tracks | `all_audio_streams` | bool | off (on when converting MKV ↔ MOV/MP4⁺) | |
| Trim | `trim_start`, `trim_end` | HH:MM:SS(.mmm) | — | |
| Subtitles | `subtitles_mode` = none · copy · soft · hard; `subtitles` (SRT/ASS) | | copy when the container can hold them | hard burns in with libass |
| Watermark | `watermark_image` (PNG) | | — | Position⁺ (corner, margin 3 %), opacity⁺ |
| Old-codec quality | `qscale` | 1–31 | 3 for MPEG-4 Part 2/WMV (CloudConvert 5) | |
| HDR⁺ | — | keep · convert to SDR | keep when the target codec/container carries it (HEVC Main10, AV1 10-bit, ProRes); otherwise tone-mapped | |
| Deinterlace⁺ | — | auto · off | auto (detected with `idet`, bwdif) | |
| Web-ready⁺ | — | bool | on for MP4/MOV/M4V (moov first) | |
| Hardware encoding⁺ | — | bool | on | |

Codecs per output container (CloudConvert's lists, with what actually encodes):

| Container | Codec choices (CloudConvert name → our encoder) | Default |
|---|---|---|
| MP4, M4V | copy · x264 → H.264 VideoToolbox · x265 → HEVC VideoToolbox (`hvc1` tag) · av1 → SVT-AV1 | H.264 |
| MOV | copy · x264 · x265 · av1 · prores → ProRes VideoToolbox (profiles proxy…4444xq) | H.264 |
| MKV | copy · x264 · x265 · vp8 → libvpx · vp9 → libvpx-vp9 · av1 | H.264 |
| WEBM | copy · vp8 · vp9 · av1; audio opus · vorbis | VP9 + Opus |
| AVI | copy · x264 · x265 · xvid → FFmpeg MPEG-4 Part 2 (FourCC XVID) | H.264 |
| FLV | copy · x264 · sorenson → FFmpeg FLV1 | H.264 |
| WMV | copy · msmpeg4 · wmv2; audio wmav2 | MS-MPEG4v3 |
| 3GP, 3G2, 3GPP | copy; we encode H.264 baseline + AAC | H.264 |
| MPEG, MPG, VOB, MOD, DVR, WTV | copy; we encode MPEG-2 + MP2/AC-3 (VOB: DVD constraints) | MPEG-2 |
| TS, M2TS, MTS | copy; we encode H.264 + AAC (M2TS: 192-byte packets) | H.264 |
| MXF | copy; we encode MPEG-2 422 or DNxHD/DNxHR | DNxHR HQ |
| DV | copy; we encode DV25/DV50 (PAL/NTSC sizes enforced) | DV25 |
| OGV | copy; we encode Theora + Vorbis | Theora |
| RM, RMVB | copy; we encode RealVideo 2 + AC-3 (FFmpeg's only Real encoders) | RV20 |
| SWF | copy; we encode FLV1 + MP3 | FLV1 |
| CAVS | needs the GPL helper (libxavs) | — |

### O-ANIM — video ↔ GIF/WebP animations

`width`, `height`, `fit`, `fps`, `keyframe_interval`, `aspect_ratio`, `trim_start`, `trim_end`, `watermark_image`.
Ours: default size keeps the source up to 800 px wide and frame rate up to 15 fps⁺ (a full-HD GIF is hundreds of MB);
Colours⁺ 256, Dither⁺ (sierra2_4a · Bayer · none), Loop⁺ (forever), Lossy⁺ (WebP quality 80). Animated GIF/WebP →
video: frame delays kept exactly (variable frame rate in MP4/MOV), transparency composited on the chosen background.

### O-AUDIO — audio

| Option | CloudConvert | Default | Notes |
|---|---|---|---|
| Codec | `audio_codec` | per container, below | |
| Bitrate | `audio_bitrate` (kb/s) | AAC 192 · Opus 160 · Vorbis q6 · AC-3 448 (5.1) / 192 (stereo) · WMA 192 | CloudConvert 128 for all |
| MP3 VBR quality | `audio_qscale` 0–9 | 0 (V0) | Same as CloudConvert; CBR when a bitrate is set |
| Volume | `volume` (factor) | 1.0 | Peak-safe: a limiter stops clipping above 0 dBTP⁺ |
| Channels | `channels` | source | Down-mix uses ITU-R BS.775 coefficients |
| Sample rate | `sample_rate` | source (44.1/48 kHz kept) | soxr / AudioConverter mastering quality |
| Trim | `trim_start`, `trim_end` | — | |
| Loudness⁺ | — | off | −14 / −16 / −23 LUFS (EBU R128, two-pass) |
| Bit depth⁺ | — | source | 16 · 24 · 32-bit float for WAV/AIFF/FLAC/ALAC; TPDF dither when reducing |
| FLAC level⁺ | — | 8 | lossless either way |
| Metadata, artwork, chapters⁺ | — | keep | ID3v2.4, MP4 atoms, Vorbis comments; M4B chapters |

Codecs per container: AAC/M4A → copy · AAC-LC · HE-AAC v1 (`aac_he_1`) · HE-AAC v2 (`aac_he_2`) · ALAC⁺ (M4A);
WAV, AIFF, AIF, AIFC → PCM 16 · 24 · 32 (`pcm_s16le/s24le/s32le`; big-endian in AIFF) · 32-bit float⁺; FLAC → FLAC;
MP3 → LAME; OGG/OGA → Vorbis · Opus · FLAC⁺; OPUS → Opus; WEBA → Opus · Vorbis; WMA → WMA v2; AC3 → AC-3; AMR →
not written (§2.7); AU → PCM 16 BE · µ-law · A-law; VOC → PCM 8/16; CAF → AAC · ALAC · PCM · Opus;
M4B → AAC with chapters. CloudConvert offers AAC/Opus/Vorbis codecs for containers that cannot hold them (AC3, AIFF,
AU, AMR, CAF, VOC, DSS); we show only codecs the container can carry.

### O-CAD, O-CAD+IMG, O-CAD-DWG — CAD

| Option | CloudConvert | Default | Notes |
|---|---|---|---|
| All layouts | `all_layouts` | off (model space) | on: one page per paper-space layout |
| Size | `width`, `height` (px) | 3000 px long side | raster outputs |
| Zoom to extents | `auto_zoom` | on (CloudConvert: off) | ignores stray far-away entities when on (extents from the 0.1–99.9 percentile of geometry) |
| AutoCAD version | `autocad_version` = 9 · 10 · 11 · 12 · 13 · 14 · 2000 · 2004 · 2007 · 2010 · 25 · 26 | 2018 | DXF/DWG output; R12 for old software |
| Background⁺ | — | white | black for "screen look" |
| Colours⁺ | — | as drawn (ACI 7 prints black on white) | monochrome |
| Line weights⁺ | — | as drawn | |
| Paper⁺ | — | fit drawing | A4–A0, Letter–E, scale 1:n |

### O-FONT — fonts (CloudConvert exposes none)

Subset⁺ (off · Latin · custom text), Hinting⁺ (keep TrueType instructions when outlines are untouched; dropped with a
note when outlines are converted), Curve tolerance⁺ (1/1000 em), WOFF2 compression⁺ (Brotli 11), EOT compression⁺
(none), Name⁺ (keep), Vertical metrics fix⁺ (off).

### O-SF2 — SoundFonts

Sample format⁺ (as stored: 16/24-bit WAV; FLAC for the FLAC target), SFZ map⁺ (on), Folders per preset⁺ (on).

## 6. The matrix

Every pair, by input. "Built in" and "With a helper" are the two routes; when both exist the one marked *preferred
when present* runs if its helper is installed, the other runs otherwise. Engine names are §3's, helpers §4's, option
profiles §5's. ⁺ marks a target CloudConvert does not offer for that input. Rank: P1 ships in 1.0, P2 in 1.x, P3 last
(§7).

<!-- BEGIN GENERATED MATRIX (scripts/gen-format-matrix.py) -->

### 6.0 Totals

| Category | Formats | Pairs (CloudConvert) | Pairs added ⁺ | Not offered | Built in | Built in · helper better | Needs helper | P1 | P2 | P3 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Documents | 23 | 245 | 20 | 0 | 120 | 58 | 87 | 127 | 130 | 8 |
| Images | 42 | 563 | 48 | 14 | 542 | 13 | 42 | 352 | 232 | 13 |
| Video | 28 | 460 | 0 | 0 | 459 | 0 | 1 | 265 | 183 | 12 |
| Audio | 21 | 145 | 8 | 2 | 147 | 0 | 4 | 65 | 74 | 12 |
| Spreadsheets | 8 | 56 | 8 | 0 | 20 | 15 | 29 | 43 | 16 | 5 |
| Slides | 11 | 104 | 10 | 0 | 9 | 27 | 78 | 63 | 37 | 14 |
| E-books | 22 | 189 | 8 | 0 | 53 | 0 | 144 | 36 | 160 | 1 |
| Archives | 39 | 222 | 10 | 0 | 195 | 0 | 37 | 90 | 124 | 18 |
| Vector | 10 | 112 | 0 | 0 | 80 | 8 | 24 | 80 | 16 | 16 |
| CAD | 3 | 35 | 0 | 0 | 21 | 0 | 14 | 9 | 14 | 12 |
| Fonts | 5 | 25 | 0 | 0 | 25 | 0 | 0 | 16 | 9 | 0 |
| **All** | **212** | **2156** | **112** | **16** | **1671** | **121** | **460** | **1146** | **995** | **111** |

*Built in* runs with nothing installed. *Built in · helper better* runs built in and switches to the helper when it is present (original office layout). *Needs helper* shows the one-click helper on the card. P1/P2/P3 order the work (§7); they do not limit what ships.

### 6.1 Documents

#### ABW — AbiWord document · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | AbiWordReader → DocModel → TextKitExport(.doc) | — | O-DOC | P2 |
| DOCX | AbiWordReader → DocModel → DOCXWriter | — | O-DOC | P2 |
| HTML | AbiWordReader → DocModel → HTMLWriter | — | O-DOC+MD | P2 |
| JPG PNG | AbiWordReader → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P2 |
| MD | AbiWordReader → DocModel → MarkdownWriter | — | O-DOC+MD | P2 |
| ODT | AbiWordReader → DocModel → ODTWriter | — | O-DOC | P2 |
| PDF | AbiWordReader → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P2 |
| RTF | AbiWordReader → DocModel → TextKitExport(.rtf) | — | O-DOC | P2 |
| TXT | AbiWordReader → DocModel → TextWriter | — | O-DOC+MD | P2 |

#### DJVU — DjVu document · 1 target

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| PDF | — | **DjVuLibre**: DjVuLibre⬇ (ddjvu -format=pdf; text layer kept) | O-PDF-PDF | P2 |

#### DOC — Word 97–2003 document · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOCX | TextKitImport(.doc) → DocModel → DOCXWriter | **LibreOffice**: LibreOffice⬇ (convert-to docx; layout kept) *(preferred when present)* | O-DOC | P1 |
| HTML | TextKitImport(.doc) → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| JPG PNG | TextKitImport(.doc) → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P1 |
| MD | TextKitImport(.doc) → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| ODT | TextKitImport(.doc) → DocModel → ODTWriter | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) *(preferred when present)* | O-DOC | P1 |
| PDF | TextKitImport(.doc) → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P1 |
| RTF | TextKitImport(.doc) → DocModel → TextKitExport(.rtf) | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) *(preferred when present)* | O-DOC | P1 |
| TXT | TextKitImport(.doc) → DocModel → TextWriter | — | O-DOC+MD | P1 |
| XPS | TextKitImport(.doc) → DocModel → TypesetKit (as written, or LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-DOC-PDF | P3 |

#### DOCM — Word macro-enabled document · 11 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | DOCXReader → DocModel → TextKitExport(.doc) | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) *(preferred when present)* | O-DOC | P1 |
| DOCX | OOXML repackage (template/macros → document; content untouched) | — | O-DOC | P1 |
| HTML | DOCXReader → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| JPG PNG | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P1 |
| MD | DOCXReader → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| ODT | DOCXReader → DocModel → ODTWriter | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) *(preferred when present)* | O-DOC | P1 |
| PDF | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P1 |
| RTF | DOCXReader → DocModel → TextKitExport(.rtf) | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) *(preferred when present)* | O-DOC | P1 |
| TXT | DOCXReader → DocModel → TextWriter | — | O-DOC+MD | P1 |
| XPS | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-DOC-PDF | P3 |

#### DOCX — Word document · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: DOCXReader → DocModel → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| DOC | DOCXReader → DocModel → TextKitExport(.doc) | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) *(preferred when present)* | O-DOC | P1 |
| EPUB | DOCXReader → DocModel → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| HTML | DOCXReader → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| JPG PNG | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P1 |
| MD | DOCXReader → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| ODT | DOCXReader → DocModel → ODTWriter | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) *(preferred when present)* | O-DOC | P1 |
| OEB | DOCXReader → DocModel → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PAGES | — | **Pages / Numbers / Keynote**: DOCX → Pages app⬇ (open + save as Pages) | O-DOC | P1 |
| PDF | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P1 |
| RTF | DOCXReader → DocModel → TextKitExport(.rtf) | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) *(preferred when present)* | O-DOC | P1 |
| TXT | DOCXReader → DocModel → TextWriter | — | O-DOC+MD | P1 |
| XPS | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-DOC-PDF | P3 |

#### DOT — Word 97–2003 template · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | TextKitImport(.doc) → DocModel → TextKitExport(.doc) | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) *(preferred when present)* | O-DOC | P2 |
| DOCX | TextKitImport(.doc) → DocModel → DOCXWriter | **LibreOffice**: LibreOffice⬇ (convert-to docx; layout kept) *(preferred when present)* | O-DOC | P2 |
| HTML | TextKitImport(.doc) → DocModel → HTMLWriter | — | O-DOC+MD | P2 |
| JPG PNG | TextKitImport(.doc) → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P2 |
| ODT | TextKitImport(.doc) → DocModel → ODTWriter | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) *(preferred when present)* | O-DOC | P2 |
| PDF | TextKitImport(.doc) → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P2 |
| RTF | TextKitImport(.doc) → DocModel → TextKitExport(.rtf) | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) *(preferred when present)* | O-DOC | P2 |
| TXT | TextKitImport(.doc) → DocModel → TextWriter | — | O-DOC+MD | P2 |
| XPS | TextKitImport(.doc) → DocModel → TypesetKit (as written, or LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-DOC-PDF | P3 |

#### DOTX — Word template · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | DOCXReader → DocModel → TextKitExport(.doc) | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) *(preferred when present)* | O-DOC | P1 |
| DOCX | OOXML repackage (template/macros → document; content untouched) | — | O-DOC | P1 |
| HTML | DOCXReader → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| JPG PNG | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P1 |
| ODT | DOCXReader → DocModel → ODTWriter | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) *(preferred when present)* | O-DOC | P1 |
| PDF | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P1 |
| RTF | DOCXReader → DocModel → TextKitExport(.rtf) | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) *(preferred when present)* | O-DOC | P1 |
| TXT | DOCXReader → DocModel → TextWriter | — | O-DOC+MD | P1 |
| XPS | DOCXReader → DocModel → TypesetKit (as written, or LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-DOC-PDF | P3 |

#### HTML — Web page (HTML) · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: HTMLReader → DocModel → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| DOC | HTMLReader → DocModel → TextKitExport(.doc) | — | O-DOC | P1 |
| DOCX | HTMLReader → DocModel → DOCXWriter | — | O-DOC | P1 |
| EPUB | HTMLReader → DocModel → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| JPG PNG | WebKit snapshot (as a web page) | — | O-WEB-SHOT | P1 |
| MD | HTMLReader → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| ODT | HTMLReader → DocModel → ODTWriter | — | O-DOC | P1 |
| OEB | HTMLReader → DocModel → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | WebKit print (as a web page) · LaTeX look: HTMLReader → DocModel → TypesetKit | — | O-WEB+O-DOC-PDF | P1 |
| RTF | HTMLReader → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TEX | HTMLReader → DocModel → LaTeXWriter | — | O-DOC+MD | P1 |
| TXT | HTMLReader → DocModel → TextWriter | — | O-DOC+MD | P1 |

#### HWP — Hangul (HWP) document · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | HWPReader → DocModel → TextKitExport(.doc) | — | O-DOC | P2 |
| DOCX | HWPReader → DocModel → DOCXWriter | — | O-DOC | P2 |
| HTML | HWPReader → DocModel → HTMLWriter | — | O-DOC+MD | P2 |
| JPG PNG | HWPReader → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout, HWP ≤ 3.0 only) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P2 |
| ODT | HWPReader → DocModel → ODTWriter | — | O-DOC | P2 |
| PDF | HWPReader → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout, HWP ≤ 3.0 only) *(preferred when present)* | O-DOC-PDF | P2 |
| RTF | HWPReader → DocModel → TextKitExport(.rtf) | — | O-DOC | P2 |
| TXT | HWPReader → DocModel → TextWriter | — | O-DOC+MD | P2 |
| XPS | HWPReader → DocModel → TypesetKit (as written, or LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout, HWP ≤ 3.0 only) → VectorKit → XPSWriter *(preferred when present)* | O-DOC-PDF | P3 |

#### HWPX — Hangul OWPML document (HWPX) · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC⁺ | HWPXReader → DocModel → TextKitExport(.doc) | — | O-DOC | P2 |
| DOCX⁺ | HWPXReader → DocModel → DOCXWriter | — | O-DOC | P2 |
| HTML⁺ | HWPXReader → DocModel → HTMLWriter | — | O-DOC+MD | P2 |
| JPG⁺ PNG⁺ | HWPXReader → DocModel → TypesetKit (LaTeX look; MathKit for math) → RenderKit → ImageIO (one image per page) | — | O-RENDER | P2 |
| MD⁺ | HWPXReader → DocModel → MarkdownWriter | — | O-DOC+MD | P2 |
| ODT⁺ | HWPXReader → DocModel → ODTWriter | — | O-DOC | P2 |
| PDF⁺ | HWPXReader → DocModel → TypesetKit (LaTeX look; MathKit for math) | — | O-DOC-PDF | P2 |
| RTF⁺ | HWPXReader → DocModel → TextKitExport(.rtf) | — | O-DOC | P2 |
| TXT⁺ | HWPXReader → DocModel → TextWriter | — | O-DOC+MD | P2 |

#### LWP — Lotus Word Pro document · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | — | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) | O-DOC | P2 |
| DOCX | — | **LibreOffice**: LibreOffice⬇ (convert-to docx; layout kept) | O-DOC | P2 |
| HTML | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → HTMLWriter | O-DOC+MD | P2 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit → RenderKit → ImageIO (one image per page) | O-RENDER | P2 |
| MD | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → MarkdownWriter | O-DOC+MD | P2 |
| ODT | — | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) | O-DOC | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit | O-DOC-PDF | P2 |
| RTF | — | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) | O-DOC | P2 |
| TXT | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → TextWriter | O-DOC+MD | P2 |

#### MD — Markdown · 12 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | MarkdownReader → DocModel → TextKitExport(.doc) | — | O-DOC | P1 |
| DOCX | MarkdownReader → DocModel → DOCXWriter | — | O-DOC | P1 |
| HTML | MarkdownReader → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| JPG PNG | MarkdownReader → DocModel → TypesetKit (LaTeX look; MathKit for math) → RenderKit → ImageIO (one image per page) | — | O-RENDER | P1 |
| MD | MarkdownReader → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| ODT | MarkdownReader → DocModel → ODTWriter | — | O-DOC | P1 |
| PDF | MarkdownReader → DocModel → TypesetKit (LaTeX look; MathKit for math) | — | O-DOC-PDF | P1 |
| RST | MarkdownReader → DocModel → RSTWriter | — | O-DOC+MD | P1 |
| RTF | MarkdownReader → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TEX | MarkdownReader → DocModel → LaTeXWriter | — | O-DOC+MD | P1 |
| TXT | MarkdownReader → DocModel → TextWriter | — | O-DOC+MD | P1 |

#### ODT — OpenDocument text · 15 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: ODTReader → DocModel → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| DOC | ODTReader → DocModel → TextKitExport(.doc) | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) *(preferred when present)* | O-DOC | P1 |
| DOCX | ODTReader → DocModel → DOCXWriter | **LibreOffice**: LibreOffice⬇ (convert-to docx; layout kept) *(preferred when present)* | O-DOC | P1 |
| EPUB | ODTReader → DocModel → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| HTML | ODTReader → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| JPG PNG | ODTReader → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P1 |
| MD | ODTReader → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| OEB | ODTReader → DocModel → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | ODTReader → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P1 |
| RTF | ODTReader → DocModel → TextKitExport(.rtf) | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) *(preferred when present)* | O-DOC | P1 |
| TXT | ODTReader → DocModel → TextWriter | — | O-DOC+MD | P1 |

#### PAGES — Apple Pages document · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | — | **Pages / Numbers / Keynote**: Pages app⬇ → DOCX → DOCXReader → DocModel → TextKitExport(.doc) | O-DOC | P1 |
| DOCX | — | **Pages / Numbers / Keynote**: Pages app⬇ export DOCX | O-DOC | P1 |
| EPUB | — | **Pages / Numbers / Keynote**: Pages app⬇ export EPUB | O-DOC | P1 |
| JPG PNG | — | **Pages / Numbers / Keynote**: Pages app⬇ → PDF → RenderKit → ImageIO | O-RENDER | P1 |
| PDF | — | **Pages / Numbers / Keynote**: Pages app⬇ export PDF (exact) | O-DOC-PDF | P1 |
| PPT | — | **Pages / Numbers / Keynote, LibreOffice**: Pages app⬇ → PDF → LayoutKit → PPTXWriter → LibreOffice⬇ (.ppt) | O-DECK | P3 |
| TXT | — | **Pages / Numbers / Keynote**: Pages app⬇ export TXT | O-DOC | P1 |
| XLS | — | **Pages / Numbers / Keynote, LibreOffice**: Pages app⬇ → PDF → LayoutKit tables → XLSXWriter → LibreOffice⬇ (.xls) | O-SHEET-OUT | P3 |

#### PDF — PDF · 33 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | RenderKit (CGPDF + ColorSync) → ImagePipeline → AVIFEncoder | — | O-RENDER | P1 |
| AZW3 LRF MOBI PDB | — | **calibre**: PDFKit → LayoutKit → EbookKit EPUB → calibre⬇ | O-EBOOK | P2 |
| BMP GIF ICO JPG PNG PSD TIFF | RenderKit (CGPDF + ColorSync) → ImagePipeline → ImageIO | — | O-RENDER | P1 |
| DOC | PDFKit → LayoutKit (+ Vision OCR) → DocModel → TextKitExport(.doc) | — | O-PDF-OFFICE | P1 |
| DOCX | PDFKit → LayoutKit (+ Vision OCR) → DocModel → DOCXWriter | — | O-PDF-OFFICE | P1 |
| DXF | VectorKit (CGPDFScanner) → DXFWriter | — | O-VEC | P1 |
| EMF | VectorKit (CGPDFScanner) → EMFWriter | — | O-VEC | P1 |
| EPS PS | VectorKit (CGPDFScanner) → PSWriter | — | O-VEC | P1 |
| EPUB | PDFKit → LayoutKit → DocModel → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| HTML | PDFKit → LayoutKit → HTMLWriter (reflowed, or positioned pages) | — | O-PDF-HTML | P1 |
| MD | PDFKit → LayoutKit → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| ODD | RenderKit (CGPDF + ColorSync) → ImagePipeline → ODFWriter | — | O-RENDER | P2 |
| OEB | PDFKit → LayoutKit → DocModel → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | PDFKit + PDFOps (pages, split, passwords, permissions, watermark; PDF/A via RenderKit) | — | O-PDF-PDF | P1 |
| PPT | — | **LibreOffice**: PDFKit → LayoutKit → PPTXWriter → LibreOffice⬇ (.ppt) | O-PDF-OFFICE | P1 |
| PPTX | PDFKit → LayoutKit → PPTXWriter (text editable, art as vectors) | — | O-PDF-OFFICE | P1 |
| RTF | PDFKit → LayoutKit (+ Vision OCR) → DocModel → TextKitExport(.rtf) | — | O-PDF-OFFICE | P1 |
| SVG | VectorKit (CGPDFScanner) → SVGWriter | — | O-VEC | P1 |
| TXT | PDFKit text in LayoutKit reading order | — | O-PDF-TXT | P1 |
| WEBP | RenderKit (CGPDF + ColorSync) → ImagePipeline → libwebp | — | O-RENDER | P1 |
| WMF | VectorKit (CGPDFScanner) → WMFWriter | — | O-VEC | P1 |
| XLS | — | **LibreOffice**: PDFKit → LayoutKit tables → XLSXWriter → LibreOffice⬇ (.xls) | O-PDF-SHEET | P1 |
| XLSX | PDFKit → LayoutKit tables → XLSXWriter | — | O-PDF-SHEET | P1 |

#### RST — reStructuredText · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOCX | — | **Pandoc**: Pandoc⬇ (→ JSON AST) → DocModel → DOCXWriter | O-DOC | P2 |
| HTML | — | **Pandoc**: Pandoc⬇ (→ JSON AST) → DocModel → HTMLWriter | O-DOC+MD | P2 |
| MD | — | **Pandoc**: Pandoc⬇ (→ JSON AST) → DocModel → MarkdownWriter | O-DOC+MD | P2 |
| ODT | — | **Pandoc**: Pandoc⬇ (→ JSON AST) → DocModel → ODTWriter | O-DOC | P2 |
| PDF | — | **Pandoc**: Pandoc⬇ (→ JSON AST) → DocModel → TypesetKit (LaTeX look; MathKit for math) | O-DOC-PDF | P2 |
| RTF | — | **Pandoc**: Pandoc⬇ (→ JSON AST) → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **Pandoc**: Pandoc⬇ (→ JSON AST) → DocModel → TextWriter | O-DOC+MD | P2 |

#### RTF — Rich Text Format · 15 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: TextKitImport(.rtf) → DocModel → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| DOC | TextKitImport(.rtf) → DocModel → TextKitExport(.doc) | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) *(preferred when present)* | O-DOC | P1 |
| DOCX | TextKitImport(.rtf) → DocModel → DOCXWriter | **LibreOffice**: LibreOffice⬇ (convert-to docx; layout kept) *(preferred when present)* | O-DOC | P1 |
| EPUB | TextKitImport(.rtf) → DocModel → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| HTML | TextKitImport(.rtf) → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| JPG PNG | TextKitImport(.rtf) → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P1 |
| MD | TextKitImport(.rtf) → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| ODT | TextKitImport(.rtf) → DocModel → ODTWriter | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) *(preferred when present)* | O-DOC | P1 |
| OEB | TextKitImport(.rtf) → DocModel → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | TextKitImport(.rtf) → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P1 |
| TXT | TextKitImport(.rtf) → DocModel → TextWriter | — | O-DOC+MD | P1 |

#### SDW — StarOffice Writer document · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC⁺ | — | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) | O-DOC | P2 |
| DOCX⁺ | — | **LibreOffice**: LibreOffice⬇ (convert-to docx; layout kept) | O-DOC | P2 |
| HTML⁺ | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → HTMLWriter | O-DOC+MD | P2 |
| JPG⁺ PNG⁺ | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit → RenderKit → ImageIO (one image per page) | O-RENDER | P2 |
| MD⁺ | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → MarkdownWriter | O-DOC+MD | P2 |
| ODT⁺ | — | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) | O-DOC | P2 |
| PDF⁺ | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit | O-DOC-PDF | P2 |
| RTF⁺ | — | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) | O-DOC | P2 |
| TXT⁺ | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → TextWriter | O-DOC+MD | P2 |

#### TEX — LaTeX source · 3 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| MD | — | **Pandoc**: Pandoc⬇ (LaTeX reader → JSON AST) → DocModel → MarkdownWriter | O-DOC+MD | P2 |
| PDF | — | **Tectonic**: Tectonic⬇ (XeTeX, real LaTeX run, offline bundle) | O-TEX | P2 |
| TXT | — | **Pandoc**: Pandoc⬇ (LaTeX reader → JSON AST) → DocModel → TextWriter | O-DOC+MD | P2 |

#### TXT — Plain text · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: PlainTextReader → DocModel → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| DOC | PlainTextReader → DocModel → TextKitExport(.doc) | — | O-DOC | P1 |
| DOCX | PlainTextReader → DocModel → DOCXWriter | — | O-DOC | P1 |
| EPUB | PlainTextReader → DocModel → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| HTML | PlainTextReader → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| JPG PNG | PlainTextReader → DocModel → TypesetKit (LaTeX look; MathKit for math) → RenderKit → ImageIO (one image per page) | — | O-RENDER | P1 |
| MD | PlainTextReader → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| ODT | PlainTextReader → DocModel → ODTWriter | — | O-DOC | P1 |
| OEB | PlainTextReader → DocModel → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | PlainTextReader → DocModel → TypesetKit (LaTeX look; MathKit for math) | — | O-DOC-PDF+TXT | P1 |
| RTF | PlainTextReader → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TEX | PlainTextReader → DocModel → LaTeXWriter | — | O-DOC+MD | P1 |

#### WPD — WordPerfect document · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | — | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) | O-DOC | P2 |
| DOCX | — | **LibreOffice**: LibreOffice⬇ (convert-to docx; layout kept) | O-DOC | P2 |
| HTML | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → HTMLWriter | O-DOC+MD | P2 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit → RenderKit → ImageIO (one image per page) | O-RENDER | P2 |
| MD | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → MarkdownWriter | O-DOC+MD | P2 |
| ODT | — | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) | O-DOC | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit | O-DOC-PDF | P2 |
| RTF | — | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) | O-DOC | P2 |
| TXT | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → TextWriter | O-DOC+MD | P2 |

#### WPS — Works / WPS Writer document · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | — | **LibreOffice**: LibreOffice⬇ (convert-to doc; layout kept) | O-DOC | P2 |
| DOCX | — | **LibreOffice**: LibreOffice⬇ (convert-to docx; layout kept) | O-DOC | P2 |
| HTML | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → HTMLWriter | O-DOC+MD | P2 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit → RenderKit → ImageIO (one image per page) | O-RENDER | P2 |
| MD | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → MarkdownWriter | O-DOC+MD | P2 |
| ODT | — | **LibreOffice**: LibreOffice⬇ (convert-to odt; layout kept) | O-DOC | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit | O-DOC-PDF | P2 |
| RTF | — | **LibreOffice**: LibreOffice⬇ (convert-to rtf; layout kept) | O-DOC | P2 |
| TXT | — | **LibreOffice**: LibreOffice⬇ (→ ODT) → ODTReader → TextWriter | O-DOC+MD | P2 |

#### ZABW — Compressed AbiWord document · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | AbiWordReader (gzip) → DocModel → TextKitExport(.doc) | — | O-DOC | P2 |
| DOCX | AbiWordReader (gzip) → DocModel → DOCXWriter | — | O-DOC | P2 |
| HTML | AbiWordReader (gzip) → DocModel → HTMLWriter | — | O-DOC+MD | P2 |
| JPG PNG | AbiWordReader (gzip) → DocModel → TypesetKit (as written, or LaTeX look) → RenderKit → ImageIO (one image per page) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) → RenderKit → ImageIO (one image per page) *(preferred when present)* | O-RENDER | P2 |
| MD | AbiWordReader (gzip) → DocModel → MarkdownWriter | — | O-DOC+MD | P2 |
| ODT | AbiWordReader (gzip) → DocModel → ODTWriter | — | O-DOC | P2 |
| PDF | AbiWordReader (gzip) → DocModel → TypesetKit (as written, or LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Word app when installed) *(preferred when present)* | O-DOC-PDF | P2 |
| RTF | AbiWordReader (gzip) → DocModel → TextKitExport(.rtf) | — | O-DOC | P2 |
| TXT | AbiWordReader (gzip) → DocModel → TextWriter | — | O-DOC+MD | P2 |

### 6.2 Images

#### 3FR — Hasselblad RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### ARW — Sony RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### AVIF — AVIF (AV1 image) · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### BMP — Windows bitmap · 15 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| SVG | ImageIO → ImagePipeline → VectorizeKit (trace) | — | O-TRACE | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### CR2 — Canon RAW 2 · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### CR3 — Canon RAW 3 · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### CRW — Canon RAW (CIFF) · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### DCR — Kodak RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### DNG — Adobe Digital Negative · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### EPS — Encapsulated PostScript · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → AVIFEncoder *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+Q+DPI | P2 |
| BMP PNG PSD | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+DPI | P2 |
| DXF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → DXFWriter | O-VEC | P2 |
| EMF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → EMFWriter | O-VEC | P2 |
| EPS | — | **Ghostscript**: Ghostscript⬇ (eps2write, normalise) | O-VEC | P2 |
| GIF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+GIF+DPI | P2 |
| ICO | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+ICON+DPI | P2 |
| JPG | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+Q+DPI | P2 |
| ODD | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ODFWriter *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+DPI | P2 |
| PDF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) | O-VEC | P2 |
| PS | — | **Ghostscript**: Ghostscript⬇ (ps2write) | O-VEC | P2 |
| SVG | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → SVGWriter | O-VEC | P2 |
| TIFF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+TIFF+DPI | P2 |
| WEBP | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → libwebp *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+Q+DPI | P2 |
| WMF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → WMFWriter | O-VEC | P2 |

#### ERF — Epson RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### GIF — GIF · 22 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | *not offered: an image has no sound; CloudConvert's GIF/WebP → audio pairs produce an empty file* | | | — |
| AVI FLV MKV MOV MP4 WEBM WMV | ImageIO frames (with their delays) → MediaKit encoder | — | O-ANIM | P1 |
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| SVG | ImageIO → ImagePipeline → VectorizeKit (trace) | — | O-TRACE | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### HEIC — HEIC · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### HEIF — HEIF · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### ICNS — Apple icon · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| PNG BMP⁺ PSD⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| AVIF⁺ | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| EPS⁺ PS⁺ | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG⁺ HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD⁺ | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF⁺ | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP⁺ | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### ICO — Windows icon · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### JFIF — JPEG (JFIF) · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### JPEG — JPEG · 15 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| SVG | ImageIO → ImagePipeline → VectorizeKit (trace) | — | O-TRACE | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### JPG — JPEG · 15 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| SVG | ImageIO → ImagePipeline → VectorizeKit (trace) | — | O-TRACE | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### MOS — Leaf RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### MRW — Minolta RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### NEF — Nikon RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### ODD — OpenDocument drawing (legacy .odd) · 13 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ODFReader (single embedded picture) → ImagePipeline → AVIFEncoder | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → AVIFEncoder *(preferred when present)* | O-IMG+Q+DPI | P2 |
| BMP PNG PSD | ODFReader (single embedded picture) → ImagePipeline → ImageIO | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO *(preferred when present)* | O-IMG+DPI | P2 |
| EPS PS | ODFReader (single embedded picture) → PSWriter (raster, Level 3) | **LibreOffice**: LibreOffice⬇ → PDF → VectorKit → PSWriter *(preferred when present)* | O-VEC | P2 |
| GIF | ODFReader (single embedded picture) → ImagePipeline → ImageIO | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO *(preferred when present)* | O-IMG+GIF+DPI | P2 |
| ICO | ODFReader (single embedded picture) → ImagePipeline → ImageIO | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO *(preferred when present)* | O-IMG+ICON+DPI | P2 |
| JPG | ODFReader (single embedded picture) → ImagePipeline → ImageIO | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO *(preferred when present)* | O-IMG+Q+DPI | P2 |
| ODD | ODFReader (single embedded picture) → ImagePipeline → ODFWriter | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ODFWriter *(preferred when present)* | O-IMG+DPI | P3 |
| PDF | ODFReader (single embedded picture) → CGPDF | **LibreOffice**: LibreOffice⬇ → PDF *(preferred when present)* | O-VEC | P2 |
| TIFF | ODFReader (single embedded picture) → ImagePipeline → ImageIO | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO *(preferred when present)* | O-IMG+TIFF+DPI | P2 |
| WEBP | ODFReader (single embedded picture) → ImagePipeline → libwebp | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → libwebp *(preferred when present)* | O-IMG+Q+DPI | P2 |

#### ODG — OpenDocument drawing · 4 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| BMP PNG | — | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO | O-IMG+DPI | P1 |
| JPG | — | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO | O-IMG+Q+DPI | P1 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF | O-VEC | P1 |

#### ORF — Olympus RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### PEF — Pentax RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### PNG — PNG · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICNS ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| SVG | ImageIO → ImagePipeline → VectorizeKit (trace) | — | O-TRACE | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### PPM — Portable pixmap (Netpbm) · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### PS — PostScript · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → AVIFEncoder *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+Q+DPI | P2 |
| BMP PNG PSD | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+DPI | P2 |
| DXF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → DXFWriter | O-VEC | P2 |
| EMF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → EMFWriter | O-VEC | P2 |
| EPS | — | **Ghostscript**: Ghostscript⬇ (eps2write) | O-VEC | P2 |
| GIF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+GIF+DPI | P2 |
| ICO | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+ICON+DPI | P2 |
| JPG | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+Q+DPI | P2 |
| ODD | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ODFWriter *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+DPI | P2 |
| PDF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) | O-VEC | P2 |
| PS | — | **Ghostscript**: Ghostscript⬇ (ps2write, normalise) | O-VEC | P2 |
| SVG | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → SVGWriter | O-VEC | P2 |
| TIFF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → ImageIO *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+TIFF+DPI | P2 |
| WEBP | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → RenderKit → ImagePipeline → libwebp *(EPS files with a TIFF preview show it built in, marked as a preview)* | O-IMG+Q+DPI | P2 |
| WMF | — | **Ghostscript**: Ghostscript⬇ (pdfwrite) → VectorKit → WMFWriter | O-VEC | P2 |

#### PSB — Photoshop large document · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageCodecs → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | ImageCodecs → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | ImageCodecs → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | ImageCodecs → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | ImageCodecs → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### PSD — Photoshop document · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### PUB — Microsoft Publisher · 4 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| BMP PNG | — | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO | O-IMG+DPI | P2 |
| JPG | — | **LibreOffice**: LibreOffice⬇ → PDF → RenderKit → ImagePipeline → ImageIO | O-IMG+Q+DPI | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF | O-VEC | P2 |

#### RAF — Fujifilm RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### RAW — Panasonic / Leica RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### RW2 — Panasonic RAW 2 · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | CIRAWFilter → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | CIRAWFilter → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | CIRAWFilter → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | CIRAWFilter → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| TIFF | CIRAWFilter → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | CIRAWFilter → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### TGA — Truevision TGA · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### TIF — TIFF · 15 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| SVG | ImageIO → ImagePipeline → VectorizeKit (trace) | — | O-TRACE | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### TIFF — TIFF · 15 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| SVG | ImageIO → ImagePipeline → VectorizeKit (trace) | — | O-TRACE | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### WEBP — WebP · 22 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | *not offered: an image has no sound; CloudConvert's GIF/WebP → audio pairs produce an empty file* | | | — |
| AVI FLV MKV MOV MP4 WEBM WMV | ImageIO frames (with their delays) → MediaKit encoder | — | O-ANIM | P1 |
| AVIF | ImageIO → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P1 |
| BMP PNG PSD | ImageIO → ImagePipeline → ImageIO | — | O-IMG | P1 |
| EPS PS | ImageIO → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P1 |
| GIF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+GIF | P1 |
| ICO | ImageIO → ImagePipeline → ImageIO | — | O-IMG+ICON | P1 |
| JPG HEIC⁺ | ImageIO → ImagePipeline → ImageIO | — | O-IMG+Q | P1 |
| ODD | ImageIO → ImagePipeline → ODFWriter | — | O-IMG | P2 |
| PDF | ImageIO → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P1 |
| SVG | ImageIO → ImagePipeline → VectorizeKit (trace) | — | O-TRACE | P1 |
| TIFF | ImageIO → ImagePipeline → ImageIO | — | O-IMG+TIFF | P1 |
| WEBP | ImageIO → ImagePipeline → libwebp | — | O-IMG+Q | P1 |

#### X3F — Sigma Foveon RAW · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | LibRaw (X3F tools) → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | LibRaw (X3F tools) → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | LibRaw (X3F tools) → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | LibRaw (X3F tools) → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | LibRaw (X3F tools) → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | LibRaw (X3F tools) → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | LibRaw (X3F tools) → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | LibRaw (X3F tools) → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | LibRaw (X3F tools) → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | LibRaw (X3F tools) → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### XCF — GIMP image · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | ImageCodecs → ImagePipeline → AVIFEncoder | — | O-IMG+Q | P2 |
| BMP PNG PSD | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG | P2 |
| EPS PS | ImageCodecs → ImagePipeline → PSWriter (raster, Level 3) | — | O-IMG+PS | P2 |
| GIF | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG+GIF | P2 |
| ICO | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG+ICON | P2 |
| JPG HEIC⁺ | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG+Q | P2 |
| ODD | ImageCodecs → ImagePipeline → ODFWriter | — | O-IMG | P3 |
| PDF | ImageCodecs → ImagePipeline → CGPDF (image page, ICC kept) | — | O-IMG-PDF | P2 |
| TIFF | ImageCodecs → ImagePipeline → ImageIO | — | O-IMG+TIFF | P2 |
| WEBP | ImageCodecs → ImagePipeline → libwebp | — | O-IMG+Q | P2 |

#### XPS — XML Paper Specification · 15 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | XPSKit → VectorKit → RenderKit → ImagePipeline → AVIFEncoder | — | O-IMG+Q+DPI | P2 |
| BMP PNG PSD | XPSKit → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+DPI | P2 |
| EPS PS | XPSKit → VectorKit → PSWriter | — | O-VEC | P2 |
| GIF | XPSKit → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+GIF+DPI | P2 |
| HTML | XPSKit → VectorKit → HTMLWriter (one inline SVG per page) | — | O-RENDER | P2 |
| ICO | XPSKit → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+ICON+DPI | P2 |
| JPG | XPSKit → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+Q+DPI | P2 |
| ODD | XPSKit → VectorKit → RenderKit → ImagePipeline → ODFWriter | — | O-IMG+DPI | P3 |
| PDF | XPSKit → VectorKit → CGPDF | — | O-VEC | P2 |
| SVG | XPSKit → VectorKit → SVGWriter | — | O-VEC | P2 |
| TIFF | XPSKit → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+TIFF+DPI | P2 |
| WEBP | XPSKit → VectorKit → RenderKit → ImagePipeline → libwebp | — | O-IMG+Q+DPI | P2 |

### 6.3 Video

#### 3G2 — 3GPP2 video · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 3G2 | AVFoundation + VideoToolbox (FFmpeg when a stream is outside Apple's codecs) | — | O-VIDEO | P3 |
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P2 |
| AVI FLV MKV WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| MOV MP4 | AVFoundation + VideoToolbox (FFmpeg when a stream is outside Apple's codecs) | — | O-VIDEO | P2 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### 3GP — 3GPP video · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 3GP MOV MP4 | AVFoundation + VideoToolbox (FFmpeg when a stream is outside Apple's codecs) | — | O-VIDEO | P1 |
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| AVI FLV MKV WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### 3GPP — 3GPP video · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 3GPP MOV MP4 | AVFoundation + VideoToolbox (FFmpeg when a stream is outside Apple's codecs) | — | O-VIDEO | P1 |
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| AVI FLV MKV WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### AVI — AVI · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### CAVS — Chinese AVS video · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| CAVS | — | **FFmpeg GPL encoders**: FFmpeg-GPL⬇ (libxavs encoder) | O-VIDEO | P3 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### DV — DV video · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| DV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### DVR — DVR-MS recording · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| DVR | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### FLV — Flash video · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### M2TS — Blu-ray transport stream · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV M2TS MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### M4V — MPEG-4 video (iTunes) · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| AVI FLV MKV WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| M4V MOV MP4 | AVFoundation + VideoToolbox (FFmpeg when a stream is outside Apple's codecs) | — | O-VIDEO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### MKV — Matroska video · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### MOD — Camcorder MPEG-2 (MOD) · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| MOD | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### MOV — QuickTime movie · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| AVI FLV MKV WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| MOV MP4 | AVFoundation + VideoToolbox (FFmpeg when a stream is outside Apple's codecs) | — | O-VIDEO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### MP4 — MPEG-4 video · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| AVI FLV MKV WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| MOV MP4 | AVFoundation + VideoToolbox (FFmpeg when a stream is outside Apple's codecs) | — | O-VIDEO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### MPEG — MPEG program stream · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 MPEG WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### MPG — MPEG program stream · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 MPG WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### MTS — AVCHD transport stream · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 MTS WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### MXF — Material Exchange Format · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| MXF | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### OGG — Ogg · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| OGG | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P3 |

#### OGV — Ogg video · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 OGV WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### RM — RealMedia · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| RM | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### RMVB — RealMedia VBR · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| RMVB | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### SWF — Flash (SWF) · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| SWF | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### TS — MPEG transport stream · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 TS WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### VOB — DVD video object · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| VOB | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |

#### WEBM — WebM · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### WMV — Windows Media video · 16 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P1 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P1 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P1 |

#### WTV — Windows recorded TV · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AVI FLV MKV MOV MP4 WEBM WMV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P2 |
| GIF | FFmpeg (palettegen + paletteuse, sierra2_4a dither) | — | O-ANIM | P2 |
| WEBP | FFmpeg (libwebp animated) | — | O-ANIM | P2 |
| WTV | FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1) | — | O-VIDEO | P3 |

### 6.4 Audio

#### AAC — AAC (ADTS) · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

#### AC3 — Dolby Digital (AC-3) · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P2 |
| AC3 | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P3 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |

#### AIF — AIFF · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIF AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

#### AIFC — AIFF-C · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P2 |
| AIFC | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P3 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |

#### AIFF — AIFF · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

#### AMR — Adaptive Multi-Rate · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AMR | *not offered: the AMR encoder’s patent status couldn’t be confirmed, so AMR files aren’t written (AMR still converts to other formats)* | | | — |

#### AU — Sun / NeXT audio · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| AU | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P3 |

#### CAF — Core Audio Format · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P2 |
| CAF | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P3 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |

#### DSS — Olympus Digital Speech Standard · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| DSS | *not offered: no DSS encoder or muxer exists outside Olympus' own software; CloudConvert can only copy the file* | | | — |

#### FLAC — FLAC · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

#### M4A — MPEG-4 audio · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

#### M4B — MPEG-4 audiobook · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P2 |
| M4B | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P3 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |

#### MP3 — MP3 · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

#### OGA — Ogg audio · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| OGA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P3 |

#### OPUS — Opus · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 OPUS WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

#### SF2 — SoundFont 2 · 4 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| ZIP⁺ | SoundFontReader → WAV samples + SFZ map → ArchiveKit | — | O-SF2 | P2 |
| SFZ⁺ | SoundFontReader → SFZ + WAV samples (zipped) | — | O-SF2 | P2 |
| WAV⁺ | SoundFontReader → one WAV per sample (zipped) | — | O-SF2 | P2 |
| FLAC⁺ | SoundFontReader → one FLAC per sample (zipped) | — | O-SF2 | P2 |

#### SFARK — sfArk compressed SoundFont · 4 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| SF2⁺ | — | **sfArk tool**: sfArk tool⬇ (sfArkLib) | O-SF2 | P3 |
| ZIP⁺ | — | **sfArk tool**: sfArk tool⬇ → SF2 → SoundFontReader → WAV samples + SFZ map → ArchiveKit | O-SF2 | P3 |
| SFZ⁺ | — | **sfArk tool**: sfArk tool⬇ → SF2 → SoundFontReader → SFZ + WAV samples (zipped) | O-SF2 | P3 |
| WAV⁺ | — | **sfArk tool**: sfArk tool⬇ → SF2 → SoundFontReader → one WAV per sample (zipped) | O-SF2 | P3 |

#### VOC — Creative Voice · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| VOC | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P3 |

#### WAV — WAVE · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A WAV | AVFoundation + AudioToolbox (FFmpeg fallback) | — | O-AUDIO | P1 |
| MP3 WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

#### WEBA — WebM audio · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P2 |
| WEBA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P3 |

#### WMA — Windows Media audio · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AAC AIFF FLAC M4A MP3 WAV WMA | FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis) | — | O-AUDIO | P1 |

### 6.5 Spreadsheets

#### CSV — Comma-separated values · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| HTML | CSVReader → Workbook → HTMLWriter (one table per sheet) | — | O-SHEET-OUT | P1 |
| JPG PNG | CSVReader → Workbook → TypesetKit (booktabs table) → RenderKit → ImageIO | — | O-RENDER+SHEET | P1 |
| ODS | CSVReader → Workbook → ODSWriter | — | O-SHEET-OUT | P1 |
| PDF | CSVReader → Workbook → TypesetKit (booktabs table) | — | O-SHEET-PDF | P1 |
| XLS | — | **LibreOffice**: CSVReader → Workbook → XLSXWriter → LibreOffice⬇ (.xls) (Numbers / Excel app when installed) | O-SHEET-OUT | P1 |
| XLSX | CSVReader → Workbook → XLSXWriter | — | O-SHEET-OUT | P1 |

#### ET — WPS Spreadsheets · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| CSV | — | **LibreOffice**: LibreOffice⬇ (→ XLSX) → XLSXReader → Workbook → CSVWriter | O-CSV | P2 |
| HTML | — | **LibreOffice**: LibreOffice⬇ (→ XLSX) → XLSXReader → Workbook → HTMLWriter (one table per sheet) | O-SHEET-OUT | P2 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → Workbook → TypesetKit → RenderKit → ImageIO | O-RENDER+SHEET | P2 |
| ODS | — | **LibreOffice**: LibreOffice⬇ (→ XLSX) → XLSXReader → Workbook → ODSWriter | O-SHEET-OUT | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → Workbook → TypesetKit | O-SHEET-PDF | P2 |
| XLS | — | **LibreOffice**: LibreOffice⬇ (convert-to xls) | O-SHEET-OUT | P2 |
| XLSX | — | **LibreOffice**: LibreOffice⬇ (→ XLSX) → XLSXReader → Workbook → XLSXWriter | O-SHEET-OUT | P2 |

#### NUMBERS — Apple Numbers · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| CSV | — | **Pages / Numbers / Keynote**: Numbers app⬇ (export XLSX) → XLSXReader → Workbook → CSVWriter | O-CSV | P1 |
| DOC | — | **Pages / Numbers / Keynote, LibreOffice**: Numbers app⬇ → PDF → LayoutKit → DOCXWriter → LibreOffice⬇ | O-SHEET-OUT | P3 |
| JPG PNG | — | **Pages / Numbers / Keynote**: Numbers app⬇ export PDF (exact) → RenderKit → ImageIO | O-RENDER+SHEET | P1 |
| PDF | — | **Pages / Numbers / Keynote**: Numbers app⬇ export PDF (exact) | O-SHEET-PDF | P1 |
| PPT | — | **Pages / Numbers / Keynote, LibreOffice**: Numbers app⬇ → PDF → LayoutKit → PPTXWriter → LibreOffice⬇ | O-SHEET-OUT | P3 |
| XLS | — | **Pages / Numbers / Keynote, LibreOffice**: Numbers app⬇ (export XLSX) → XLSXReader → Workbook → XLSXWriter → LibreOffice⬇ (.xls) (Numbers / Excel app when installed) | O-SHEET-OUT | P1 |
| XLSX | — | **Pages / Numbers / Keynote**: Numbers app⬇ (export XLSX) → XLSXReader → Workbook → XLSXWriter | O-SHEET-OUT | P1 |

#### ODS — OpenDocument spreadsheet · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| CSV | ODSReader → Workbook → CSVWriter | — | O-CSV | P1 |
| HTML | ODSReader → Workbook → HTMLWriter (one table per sheet) | — | O-SHEET-OUT | P1 |
| JPG PNG | ODSReader → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) → RenderKit → ImageIO | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) → RenderKit → ImageIO *(preferred when present)* | O-RENDER+SHEET | P1 |
| PDF | ODSReader → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) *(preferred when present)* | O-SHEET-PDF | P1 |
| XLS | — | **LibreOffice**: ODSReader → Workbook → XLSXWriter → LibreOffice⬇ (.xls) (Numbers / Excel app when installed) | O-SHEET-OUT | P1 |
| XLSX | ODSReader → Workbook → XLSXWriter | — | O-SHEET-OUT | P1 |

#### SDC — StarOffice Calc spreadsheet · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| CSV⁺ | — | **LibreOffice**: LibreOffice⬇ (→ XLSX) → XLSXReader → Workbook → CSVWriter | O-CSV | P2 |
| HTML⁺ | — | **LibreOffice**: LibreOffice⬇ (→ XLSX) → XLSXReader → Workbook → HTMLWriter (one table per sheet) | O-SHEET-OUT | P2 |
| JPG⁺ PNG⁺ | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → Workbook → TypesetKit → RenderKit → ImageIO | O-RENDER+SHEET | P2 |
| ODS⁺ | — | **LibreOffice**: LibreOffice⬇ (→ XLSX) → XLSXReader → Workbook → ODSWriter | O-SHEET-OUT | P2 |
| PDF⁺ | — | **LibreOffice**: LibreOffice⬇ → PDF (original layout) · LaTeX look: → Workbook → TypesetKit | O-SHEET-PDF | P2 |
| XLS⁺ | — | **LibreOffice**: LibreOffice⬇ (convert-to xls) | O-SHEET-OUT | P2 |
| XLSX⁺ | — | **LibreOffice**: LibreOffice⬇ (→ XLSX) → XLSXReader → Workbook → XLSXWriter | O-SHEET-OUT | P2 |

#### XLS — Excel 97–2003 workbook · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| CSV | XLSReader (libxls) → Workbook → CSVWriter | — | O-CSV | P1 |
| HTML | XLSReader (libxls) → Workbook → HTMLWriter (one table per sheet) | — | O-SHEET-OUT | P1 |
| JPG PNG | XLSReader (libxls) → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) → RenderKit → ImageIO | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) → RenderKit → ImageIO *(preferred when present)* | O-RENDER+SHEET | P1 |
| ODS | XLSReader (libxls) → Workbook → ODSWriter | — | O-SHEET-OUT | P1 |
| PDF | XLSReader (libxls) → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) *(preferred when present)* | O-SHEET-PDF | P1 |
| XLSX | XLSReader (libxls) → Workbook → XLSXWriter | — | O-SHEET-OUT | P1 |
| XPS | XLSReader (libxls) → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-SHEET-PDF | P3 |

#### XLSM — Excel macro-enabled workbook · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| CSV | XLSXReader → Workbook → CSVWriter | — | O-CSV | P1 |
| HTML | XLSXReader → Workbook → HTMLWriter (one table per sheet) | — | O-SHEET-OUT | P1 |
| JPG PNG | XLSXReader → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) → RenderKit → ImageIO | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) → RenderKit → ImageIO *(preferred when present)* | O-RENDER+SHEET | P1 |
| ODS | XLSXReader → Workbook → ODSWriter | — | O-SHEET-OUT | P1 |
| PDF | XLSXReader → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) *(preferred when present)* | O-SHEET-PDF | P1 |
| XLS | — | **LibreOffice**: XLSXReader → Workbook → XLSXWriter → LibreOffice⬇ (.xls) (Numbers / Excel app when installed) | O-SHEET-OUT | P1 |
| XLSX | OOXML repackage (macros dropped; content untouched) | — | O-SHEET-OUT | P1 |
| XPS | XLSXReader → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-SHEET-PDF | P3 |

#### XLSX — Excel workbook · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| CSV | XLSXReader → Workbook → CSVWriter | — | O-CSV | P1 |
| HTML | XLSXReader → Workbook → HTMLWriter (one table per sheet) | — | O-SHEET-OUT | P1 |
| JPG PNG | XLSXReader → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) → RenderKit → ImageIO | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) → RenderKit → ImageIO *(preferred when present)* | O-RENDER+SHEET | P1 |
| NUMBERS | — | **Pages / Numbers / Keynote**: XLSX → Numbers app⬇ (open + save) | O-SHEET-OUT | P1 |
| ODS | XLSXReader → Workbook → ODSWriter | — | O-SHEET-OUT | P1 |
| PDF | XLSXReader → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) *(preferred when present)* | O-SHEET-PDF | P1 |
| XLS | — | **LibreOffice**: XLSXReader → Workbook → XLSXWriter → LibreOffice⬇ (.xls) (Numbers / Excel app when installed) | O-SHEET-OUT | P1 |
| XPS | XLSXReader → Workbook → TypesetKit (grid as laid out, or booktabs LaTeX look) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ (original layout; Numbers / Excel app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-SHEET-PDF | P3 |

### 6.6 Slides

#### DPS — WPS Presentation · 11 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EPS | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → PSWriter (one per slide) | O-VEC | P2 |
| HTML | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → HTMLWriter (slide SVGs + speaker notes) | O-DECK | P2 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → RenderKit → ImageIO (one per slide) | O-DECK+IMG | P2 |
| MD | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → MarkdownWriter | O-DOC+MD | P2 |
| ODP | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) | O-DECK | P2 |
| PPT | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P2 |
| PPTX | — | **LibreOffice**: LibreOffice⬇ (convert-to pptx; Keynote app when installed) | O-DECK | P2 |
| SWF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → slide images → FFmpeg (SWF slideshow) *(Flash is obsolete; offered for parity only)* | O-DECK-VIDEO | P3 |
| TXT | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → TextWriter | O-DOC+MD | P2 |

#### KEY — Apple Keynote · 7 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DOC | — | **Pages / Numbers / Keynote, LibreOffice**: Keynote app⬇ → PDF → LayoutKit → DOCXWriter → LibreOffice⬇ | O-DOC | P3 |
| JPG PNG | — | **Pages / Numbers / Keynote**: Keynote app⬇ export images (one per slide) | O-DECK+IMG | P1 |
| PDF | — | **Pages / Numbers / Keynote**: Keynote app⬇ export PDF (exact) | O-DECK | P1 |
| PPT | — | **Pages / Numbers / Keynote, LibreOffice**: Keynote app⬇ → PPTX → LibreOffice⬇ (.ppt) | O-DECK | P1 |
| PPTX | — | **Pages / Numbers / Keynote**: Keynote app⬇ export PPTX | O-DECK | P1 |
| XLS | — | **Pages / Numbers / Keynote, LibreOffice**: Keynote app⬇ → PDF → LayoutKit → XLSXWriter → LibreOffice⬇ | O-DOC | P3 |

#### ODP — OpenDocument presentation · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EPS | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → PSWriter (one per slide) | O-VEC | P1 |
| HTML | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → HTMLWriter (slide SVGs + speaker notes) | O-DECK | P1 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → RenderKit → ImageIO (one per slide) | O-DECK+IMG | P1 |
| MD | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → MarkdownWriter | O-DOC+MD | P1 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) | O-DECK | P1 |
| PPT | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P1 |
| PPTX | — | **LibreOffice**: LibreOffice⬇ (convert-to pptx; Keynote app when installed) | O-DECK | P1 |
| SWF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → slide images → FFmpeg (SWF slideshow) *(Flash is obsolete; offered for parity only)* | O-DECK-VIDEO | P3 |
| TXT | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → TextWriter | O-DOC+MD | P1 |

#### POT — PowerPoint 97–2003 template · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EMF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → EMFWriter (one per slide) | O-VEC | P2 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → RenderKit → ImageIO (one per slide) | O-DECK+IMG | P2 |
| ODP | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) | O-DECK | P2 |
| PPT | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P2 |
| PPTX | — | **LibreOffice**: LibreOffice⬇ (convert-to pptx; Keynote app when installed) | O-DECK | P2 |
| XPS | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → XPSWriter | O-DECK | P3 |

#### POTX — PowerPoint template · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EMF | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → EMFWriter (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → EMFWriter (one per slide) *(preferred when present)* | O-VEC | P1 |
| JPG PNG | SlideRenderer (own PPTX: text, pictures, shapes, themes) → RenderKit → ImageIO (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → RenderKit → ImageIO (one per slide) *(preferred when present)* | O-DECK+IMG | P1 |
| ODP | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P1 |
| PDF | SlideRenderer (own PPTX: text, pictures, shapes, themes) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) *(preferred when present)* | O-DECK | P1 |
| PPT | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P1 |
| PPTX | OOXML repackage (show/template/macros → presentation; content untouched) | — | O-DECK | P1 |
| XPS | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-DECK | P3 |

#### PPS — PowerPoint 97–2003 show · 11 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EPS | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → PSWriter (one per slide) | O-VEC | P2 |
| HTML | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → HTMLWriter (slide SVGs + speaker notes) | O-DECK | P2 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → RenderKit → ImageIO (one per slide) | O-DECK+IMG | P2 |
| MD | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → MarkdownWriter | O-DOC+MD | P2 |
| ODP | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) | O-DECK | P2 |
| PPT | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P2 |
| PPTX | — | **LibreOffice**: LibreOffice⬇ (convert-to pptx; Keynote app when installed) | O-DECK | P2 |
| SWF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → slide images → FFmpeg (SWF slideshow) *(Flash is obsolete; offered for parity only)* | O-DECK-VIDEO | P3 |
| TXT | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → TextWriter | O-DOC+MD | P2 |

#### PPSX — PowerPoint show · 11 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EPS | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → PSWriter (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → PSWriter (one per slide) *(preferred when present)* | O-VEC | P1 |
| HTML | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → HTMLWriter (slide SVGs + speaker notes) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → HTMLWriter (slide SVGs + speaker notes) *(preferred when present)* | O-DECK | P1 |
| JPG PNG | SlideRenderer (own PPTX: text, pictures, shapes, themes) → RenderKit → ImageIO (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → RenderKit → ImageIO (one per slide) *(preferred when present)* | O-DECK+IMG | P1 |
| MD | SlideReader (own PPTX) → titles, bullets, notes → MarkdownWriter | — | O-DOC+MD | P1 |
| ODP | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P1 |
| PDF | SlideRenderer (own PPTX: text, pictures, shapes, themes) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) *(preferred when present)* | O-DECK | P1 |
| PPT | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P1 |
| PPTX | OOXML repackage (show/template/macros → presentation; content untouched) | — | O-DECK | P1 |
| SWF | SlideRenderer (own PPTX: text, pictures, shapes, themes) → slide images → FFmpeg (SWF slideshow) *(Flash is obsolete; offered for parity only)* | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → slide images → FFmpeg (SWF slideshow) *(preferred when present)* | O-DECK-VIDEO | P3 |
| TXT | SlideReader (own PPTX) → titles, bullets, notes → TextWriter | — | O-DOC+MD | P1 |

#### PPT — PowerPoint 97–2003 · 12 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EMF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → EMFWriter (one per slide) | O-VEC | P1 |
| EPS | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → PSWriter (one per slide) | O-VEC | P1 |
| HTML | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → HTMLWriter (slide SVGs + speaker notes) | O-DECK | P1 |
| JPG PNG | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → RenderKit → ImageIO (one per slide) | O-DECK+IMG | P1 |
| MD | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → MarkdownWriter | O-DOC+MD | P1 |
| ODP | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P1 |
| PDF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) | O-DECK | P1 |
| PPTX | — | **LibreOffice**: LibreOffice⬇ (convert-to pptx; Keynote app when installed) | O-DECK | P1 |
| SWF | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → slide images → FFmpeg (SWF slideshow) *(Flash is obsolete; offered for parity only)* | O-DECK-VIDEO | P3 |
| TXT | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → TextWriter | O-DOC+MD | P1 |
| XPS | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → XPSWriter | O-DECK | P3 |

#### PPTM — PowerPoint macro-enabled · 13 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EMF | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → EMFWriter (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → EMFWriter (one per slide) *(preferred when present)* | O-VEC | P1 |
| EPS | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → PSWriter (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → PSWriter (one per slide) *(preferred when present)* | O-VEC | P1 |
| HTML | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → HTMLWriter (slide SVGs + speaker notes) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → HTMLWriter (slide SVGs + speaker notes) *(preferred when present)* | O-DECK | P1 |
| JPG PNG | SlideRenderer (own PPTX: text, pictures, shapes, themes) → RenderKit → ImageIO (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → RenderKit → ImageIO (one per slide) *(preferred when present)* | O-DECK+IMG | P1 |
| MD | SlideReader (own PPTX) → titles, bullets, notes → MarkdownWriter | — | O-DOC+MD | P1 |
| ODP | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P1 |
| PDF | SlideRenderer (own PPTX: text, pictures, shapes, themes) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) *(preferred when present)* | O-DECK | P1 |
| PPT | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P1 |
| PPTX | OOXML repackage (show/template/macros → presentation; content untouched) | — | O-DECK | P1 |
| SWF | SlideRenderer (own PPTX: text, pictures, shapes, themes) → slide images → FFmpeg (SWF slideshow) *(Flash is obsolete; offered for parity only)* | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → slide images → FFmpeg (SWF slideshow) *(preferred when present)* | O-DECK-VIDEO | P3 |
| TXT | SlideReader (own PPTX) → titles, bullets, notes → TextWriter | — | O-DOC+MD | P1 |
| XPS | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-DECK | P3 |

#### PPTX — PowerPoint · 13 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EMF | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → EMFWriter (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → EMFWriter (one per slide) *(preferred when present)* | O-VEC | P1 |
| EPS | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → PSWriter (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → PSWriter (one per slide) *(preferred when present)* | O-VEC | P1 |
| HTML | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → HTMLWriter (slide SVGs + speaker notes) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → HTMLWriter (slide SVGs + speaker notes) *(preferred when present)* | O-DECK | P1 |
| JPG PNG | SlideRenderer (own PPTX: text, pictures, shapes, themes) → RenderKit → ImageIO (one per slide) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → RenderKit → ImageIO (one per slide) *(preferred when present)* | O-DECK+IMG | P1 |
| KEY | — | **Pages / Numbers / Keynote**: Keynote app⬇ (open + save as Keynote) | O-DECK | P1 |
| MD | SlideReader (own PPTX) → titles, bullets, notes → MarkdownWriter | — | O-DOC+MD | P1 |
| ODP | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P1 |
| PDF | SlideRenderer (own PPTX: text, pictures, shapes, themes) | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) *(preferred when present)* | O-DECK | P1 |
| PPT | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P1 |
| SWF | SlideRenderer (own PPTX: text, pictures, shapes, themes) → slide images → FFmpeg (SWF slideshow) *(Flash is obsolete; offered for parity only)* | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → slide images → FFmpeg (SWF slideshow) *(preferred when present)* | O-DECK-VIDEO | P3 |
| TXT | SlideReader (own PPTX) → titles, bullets, notes → TextWriter | — | O-DOC+MD | P1 |
| XPS | SlideRenderer (own PPTX: text, pictures, shapes, themes) → VectorKit → XPSWriter | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app when installed) → VectorKit → XPSWriter *(preferred when present)* | O-DECK | P3 |

#### SDA — StarOffice Draw / Impress · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EPS⁺ | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → PSWriter (one per slide) | O-VEC | P2 |
| HTML⁺ | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → VectorKit → HTMLWriter (slide SVGs + speaker notes) | O-DECK | P2 |
| JPG⁺ PNG⁺ | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) → RenderKit → ImageIO (one per slide) | O-DECK+IMG | P2 |
| MD⁺ | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → MarkdownWriter | O-DOC+MD | P2 |
| ODP⁺ | — | **LibreOffice**: LibreOffice⬇ (convert-to odp) | O-DECK | P2 |
| PDF⁺ | — | **LibreOffice**: LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed) | O-DECK | P2 |
| PPT⁺ | — | **LibreOffice**: LibreOffice⬇ (convert-to ppt) | O-DECK | P2 |
| PPTX⁺ | — | **LibreOffice**: LibreOffice⬇ (convert-to pptx; Keynote app when installed) | O-DECK | P2 |
| TXT⁺ | — | **LibreOffice**: LibreOffice⬇ (→ PPTX) → SlideReader → TextWriter | O-DOC+MD | P2 |

### 6.7 E-books

#### AZW — Kindle (AZW) · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### AZW3 — Kindle KF8 (AZW3) · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### AZW4 — Kindle Print Replica · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (Print Replica → its PDF) → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (Print Replica → its PDF) → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ → the embedded PDF, as published | O-PDF-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (Print Replica → its PDF) → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (Print Replica → its PDF) → DocModel → TextWriter | O-DOC | P2 |

#### CBC — Comic book collection · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: ComicReader (collection) → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| EPUB | ComicReader (collection) → fixed-layout EPUB | — | O-EBOOK | P2 |
| OEB | ComicReader (collection) → fixed-layout OEB | — | O-EBOOK | P3 |
| PDF | ComicReader (collection) → one page per picture (no recompression, ICC kept) → CGPDF | — | O-COMIC | P2 |
| RTF | ComicReader (collection) → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P2 |
| TXT | ComicReader (collection) → Publication → DocModel → TextWriter | — | O-DOC | P2 |

#### CBR — Comic book (RAR) · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: ComicReader (libarchive RAR) → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| EPUB | ComicReader (libarchive RAR) → fixed-layout EPUB | — | O-EBOOK | P1 |
| OEB | ComicReader (libarchive RAR) → fixed-layout OEB | — | O-EBOOK | P2 |
| PDF | ComicReader (libarchive RAR) → one page per picture (no recompression, ICC kept) → CGPDF | — | O-COMIC | P1 |
| RTF | ComicReader (libarchive RAR) → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TXT | ComicReader (libarchive RAR) → Publication → DocModel → TextWriter | — | O-DOC | P1 |

#### CBZ — Comic book (ZIP) · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: ComicReader (ZIP) → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| EPUB | ComicReader (ZIP) → fixed-layout EPUB | — | O-EBOOK | P1 |
| OEB | ComicReader (ZIP) → fixed-layout OEB | — | O-EBOOK | P2 |
| PDF | ComicReader (ZIP) → one page per picture (no recompression, ICC kept) → CGPDF | — | O-COMIC | P1 |
| RTF | ComicReader (ZIP) → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TXT | ComicReader (ZIP) → Publication → DocModel → TextWriter | — | O-DOC | P1 |

#### CHM — Compiled HTML Help · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: CHMReader (7zz extract + .hhc contents) → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| EPUB | CHMReader (7zz extract + .hhc contents) → Publication → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| OEB | CHMReader (7zz extract + .hhc contents) → Publication → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | CHMReader (7zz extract + .hhc contents) → Publication → TypesetKit (book style, LaTeX look) | — | O-EBOOK-PDF | P1 |
| RTF | CHMReader (7zz extract + .hhc contents) → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TXT | CHMReader (7zz extract + .hhc contents) → Publication → DocModel → TextWriter | — | O-DOC | P1 |

#### EPUB — EPUB · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: EPUBReader → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| OEB | EPUBReader → Publication → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | EPUBReader → Publication → TypesetKit (book style, LaTeX look) | — | O-EBOOK-PDF | P1 |
| RTF | EPUBReader → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TXT | EPUBReader → Publication → DocModel → TextWriter | — | O-DOC | P1 |

#### FB2 — FictionBook 2 · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: FB2Reader → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| EPUB | FB2Reader → Publication → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| OEB | FB2Reader → Publication → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | FB2Reader → Publication → TypesetKit (book style, LaTeX look) | — | O-EBOOK-PDF | P1 |
| RTF | FB2Reader → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TXT | FB2Reader → Publication → DocModel → TextWriter | — | O-DOC | P1 |

#### HTM — HTML e-book · 14 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: HTMLReader → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| DOC | HTMLReader → DocModel → TextKitExport(.doc) | — | O-DOC | P1 |
| DOCX | HTMLReader → DocModel → DOCXWriter | — | O-DOC | P1 |
| EPUB | HTMLReader → Publication → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| JPG PNG | WebKit snapshot (as a web page) | — | O-WEB-SHOT | P1 |
| ODT | HTMLReader → DocModel → ODTWriter | — | O-DOC | P1 |
| OEB | HTMLReader → Publication → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | WebKit print (as a web page) · LaTeX look: HTMLReader → TypesetKit (book) | — | O-WEB+O-DOC-PDF | P1 |
| RTF | HTMLReader → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TXT | HTMLReader → DocModel → TextWriter | — | O-DOC+MD | P1 |

#### HTMLZ — Zipped HTML e-book · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: HTMLZReader → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| EPUB | HTMLZReader → Publication → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| OEB | HTMLZReader → Publication → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | HTMLZReader → Publication → TypesetKit (book style, LaTeX look) | — | O-EBOOK-PDF | P1 |
| RTF | HTMLZReader → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TXT | HTMLZReader → Publication → DocModel → TextWriter | — | O-DOC | P1 |

#### LIT — Microsoft Reader · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### LRF — Sony BBeB · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### MOBI — Mobipocket · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### OEB — Open eBook · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3⁺ LRF⁺ MOBI⁺ PDB⁺ | — | **calibre**: OEBReader → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| EPUB⁺ | OEBReader → Publication → EbookKit (EPUB writer) | — | O-EBOOK | P2 |
| PDF⁺ | OEBReader → Publication → TypesetKit (book style, LaTeX look) | — | O-EBOOK-PDF | P2 |
| RTF⁺ | OEBReader → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P2 |
| TXT⁺ | OEBReader → Publication → DocModel → TextWriter | — | O-DOC | P2 |

#### PDB — Palm database e-book · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### PML — Palm Markup Language · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### PRC — Mobipocket (PRC) · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### RB — Rocket eBook · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### SNB — Shanda Bambook · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### TCR — Psion TCR · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: calibre⬇ (ebook-convert, direct) | O-EBOOK | P2 |
| EPUB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (EPUB writer) | O-EBOOK | P2 |
| OEB | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → EbookKit (OEB writer) | O-EBOOK | P2 |
| PDF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → TypesetKit (book style, LaTeX look) | O-EBOOK-PDF | P2 |
| RTF | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextKitExport(.rtf) | O-DOC | P2 |
| TXT | — | **calibre**: calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication → DocModel → TextWriter | O-DOC | P2 |

#### TXTZ — Zipped text e-book · 9 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AZW3 LRF MOBI PDB | — | **calibre**: TXTZReader → Publication → EbookKit EPUB → calibre⬇ (ebook-convert) | O-EBOOK | P2 |
| EPUB | TXTZReader → Publication → EbookKit (EPUB writer) | — | O-EBOOK | P1 |
| OEB | TXTZReader → Publication → EbookKit (OEB writer) | — | O-EBOOK | P2 |
| PDF | TXTZReader → Publication → TypesetKit (book style, LaTeX look) | — | O-EBOOK-PDF | P1 |
| RTF | TXTZReader → Publication → DocModel → TextKitExport(.rtf) | — | O-DOC | P1 |
| TXT | TXTZReader → Publication → DocModel → TextWriter | — | O-DOC | P1 |

### 6.8 Archives

#### 7Z — 7-Zip · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| RAR | — | **RAR (RARLAB)**: libarchive (7zz for AES-encrypted) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive (7zz for AES-encrypted) → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive (7zz for AES-encrypted) → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive (7zz for AES-encrypted) → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive (7zz for AES-encrypted) → libarchive zip writer | — | O-ARCHIVE | P1 |

#### ACE — ACE · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | ACEKit (acefile port, BSD-2) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P3 |
| RAR | — | **RAR (RARLAB)**: ACEKit (acefile port, BSD-2) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P3 |
| TAR | ACEKit (acefile port, BSD-2) → libarchive tar writer | — | O-ARCHIVE | P3 |
| TAR.BZ2 | ACEKit (acefile port, BSD-2) → libarchive tar.bz2 writer | — | O-ARCHIVE | P3 |
| TAR.GZ | ACEKit (acefile port, BSD-2) → libarchive tar.gz writer | — | O-ARCHIVE | P3 |
| ZIP | ACEKit (acefile port, BSD-2) → libarchive zip writer | — | O-ARCHIVE | P3 |

#### ALZ — ALZip · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | unalz (zlib licence, bundled) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: unalz (zlib licence, bundled) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | unalz (zlib licence, bundled) → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | unalz (zlib licence, bundled) → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | unalz (zlib licence, bundled) → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | unalz (zlib licence, bundled) → libarchive zip writer | — | O-ARCHIVE | P2 |

#### ARC — ARC (SEA) · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | ARCKit (own: stored, packed, squeezed, crunched, squashed) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P3 |
| RAR | — | **RAR (RARLAB)**: ARCKit (own: stored, packed, squeezed, crunched, squashed) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P3 |
| TAR | ARCKit (own: stored, packed, squeezed, crunched, squashed) → libarchive tar writer | — | O-ARCHIVE | P3 |
| TAR.BZ2 | ARCKit (own: stored, packed, squeezed, crunched, squashed) → libarchive tar.bz2 writer | — | O-ARCHIVE | P3 |
| TAR.GZ | ARCKit (own: stored, packed, squeezed, crunched, squashed) → libarchive tar.gz writer | — | O-ARCHIVE | P3 |
| ZIP | ARCKit (own: stored, packed, squeezed, crunched, squashed) → libarchive zip writer | — | O-ARCHIVE | P3 |

#### ARJ — ARJ · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | 7zz (bundled LGPL executable) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: 7zz (bundled LGPL executable) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | 7zz (bundled LGPL executable) → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | 7zz (bundled LGPL executable) → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | 7zz (bundled LGPL executable) → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | 7zz (bundled LGPL executable) → libarchive zip writer | — | O-ARCHIVE | P2 |

#### BZ — bzip2 · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### BZ2 — bzip2 · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### CAB — Windows cabinet · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive MSZIP/LZX (7zz for Quantum) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive MSZIP/LZX (7zz for Quantum) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive MSZIP/LZX (7zz for Quantum) → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive MSZIP/LZX (7zz for Quantum) → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive MSZIP/LZX (7zz for Quantum) → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive MSZIP/LZX (7zz for Quantum) → libarchive zip writer | — | O-ARCHIVE | P1 |

#### CPIO — cpio · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### DEB — Debian package · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive ar + data.tar.* unpacked → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive ar + data.tar.* unpacked → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive ar + data.tar.* unpacked → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive ar + data.tar.* unpacked → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive ar + data.tar.* unpacked → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive ar + data.tar.* unpacked → libarchive zip writer | — | O-ARCHIVE | P2 |

#### DMG — Apple disk image · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | hdiutil attach -readonly (7zz fallback) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: hdiutil attach -readonly (7zz fallback) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | hdiutil attach -readonly (7zz fallback) → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | hdiutil attach -readonly (7zz fallback) → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | hdiutil attach -readonly (7zz fallback) → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | hdiutil attach -readonly (7zz fallback) → libarchive zip writer | — | O-ARCHIVE | P1 |

#### EML — Email message · 10 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| PDF⁺ | MailReader → DocModel → TypesetKit (LaTeX look; MathKit for math) | — | O-DOC-PDF | P1 |
| HTML⁺ | MailReader → DocModel → HTMLWriter | — | O-DOC+MD | P1 |
| TXT⁺ | MailReader → DocModel → TextWriter | — | O-DOC+MD | P1 |
| MD⁺ | MailReader → DocModel → MarkdownWriter | — | O-DOC+MD | P1 |
| DOCX⁺ | MailReader → DocModel → DOCXWriter | — | O-DOC | P1 |
| ZIP⁺ | MailReader (attachments + message.html) → libarchive zip writer | — | O-ARCHIVE | P1 |
| 7Z⁺ | MailReader (attachments + message.html) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| TAR⁺ | MailReader (attachments + message.html) → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.GZ⁺ | MailReader (attachments + message.html) → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| TAR.BZ2⁺ | MailReader (attachments + message.html) → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |

#### GZ — gzip · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### IMG — Disk image · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | 7zz (FAT/NTFS/MBR/GPT; hdiutil for Mac images) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: 7zz (FAT/NTFS/MBR/GPT; hdiutil for Mac images) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | 7zz (FAT/NTFS/MBR/GPT; hdiutil for Mac images) → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | 7zz (FAT/NTFS/MBR/GPT; hdiutil for Mac images) → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | 7zz (FAT/NTFS/MBR/GPT; hdiutil for Mac images) → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | 7zz (FAT/NTFS/MBR/GPT; hdiutil for Mac images) → libarchive zip writer | — | O-ARCHIVE | P2 |

#### ISO — ISO / UDF disc image · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive ISO 9660 (7zz for UDF) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive ISO 9660 (7zz for UDF) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive ISO 9660 (7zz for UDF) → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive ISO 9660 (7zz for UDF) → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive ISO 9660 (7zz for UDF) → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive ISO 9660 (7zz for UDF) → libarchive zip writer | — | O-ARCHIVE | P1 |

#### JAR — Java archive · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### LHA — LHA / LZH · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### LZ — lzip · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### LZMA — LZMA · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### LZO — lzop · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | LZOKit (lzokay, MIT) + lzop container → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: LZOKit (lzokay, MIT) + lzop container → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | LZOKit (lzokay, MIT) + lzop container → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | LZOKit (lzokay, MIT) + lzop container → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | LZOKit (lzokay, MIT) + lzop container → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | LZOKit (lzokay, MIT) + lzop container → libarchive zip writer | — | O-ARCHIVE | P2 |

#### RAR — RAR · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive RAR 4/5 (7zz for encrypted) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| TAR | libarchive RAR 4/5 (7zz for encrypted) → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive RAR 4/5 (7zz for encrypted) → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive RAR 4/5 (7zz for encrypted) → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive RAR 4/5 (7zz for encrypted) → libarchive zip writer | — | O-ARCHIVE | P1 |

#### RPM — RPM package · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive RPM (cpio payload unpacked) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive RPM (cpio payload unpacked) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive RPM (cpio payload unpacked) → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive RPM (cpio payload unpacked) → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive RPM (cpio payload unpacked) → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive RPM (cpio payload unpacked) → libarchive zip writer | — | O-ARCHIVE | P2 |

#### RZ — rzip · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | RZipKit (own rzip decoder over bzip2) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P3 |
| RAR | — | **RAR (RARLAB)**: RZipKit (own rzip decoder over bzip2) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P3 |
| TAR | RZipKit (own rzip decoder over bzip2) → libarchive tar writer | — | O-ARCHIVE | P3 |
| TAR.BZ2 | RZipKit (own rzip decoder over bzip2) → libarchive tar.bz2 writer | — | O-ARCHIVE | P3 |
| TAR.GZ | RZipKit (own rzip decoder over bzip2) → libarchive tar.gz writer | — | O-ARCHIVE | P3 |
| ZIP | RZipKit (own rzip decoder over bzip2) → libarchive zip writer | — | O-ARCHIVE | P3 |

#### TAR — tar · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### TAR.7Z — tar + 7z · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive (7zz for AES-encrypted) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive (7zz for AES-encrypted) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive (7zz for AES-encrypted) → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive (7zz for AES-encrypted) → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive (7zz for AES-encrypted) → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive (7zz for AES-encrypted) → libarchive zip writer | — | O-ARCHIVE | P2 |

#### TAR.BZ — tar + bzip2 · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### TAR.BZ2 — tar + bzip2 · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### TAR.GZ — tar + gzip · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### TAR.LZO — tar + lzop · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | LZOKit + libarchive tar → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: LZOKit + libarchive tar → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | LZOKit + libarchive tar → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | LZOKit + libarchive tar → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | LZOKit + libarchive tar → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | LZOKit + libarchive tar → libarchive zip writer | — | O-ARCHIVE | P2 |

#### TAR.XZ — tar + xz · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### TAR.Z — tar + compress · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### TBZ — tar + bzip2 · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### TBZ2 — tar + bzip2 · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### TGZ — tar + gzip · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### TZ — tar + compress · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### TZO — tar + lzop · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | LZOKit + libarchive tar → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: LZOKit + libarchive tar → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | LZOKit + libarchive tar → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | LZOKit + libarchive tar → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | LZOKit + libarchive tar → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | LZOKit + libarchive tar → libarchive zip writer | — | O-ARCHIVE | P2 |

#### XZ — xz · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P1 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P1 |

#### Z — Unix compress · 6 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P2 |
| RAR | — | **RAR (RARLAB)**: libarchive → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive → libarchive tar writer | — | O-ARCHIVE | P2 |
| TAR.BZ2 | libarchive → libarchive tar.bz2 writer | — | O-ARCHIVE | P2 |
| TAR.GZ | libarchive → libarchive tar.gz writer | — | O-ARCHIVE | P2 |
| ZIP | libarchive → libarchive zip writer | — | O-ARCHIVE | P2 |

#### ZIP — ZIP · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| 7Z | libarchive (7zz for AES) → libarchive 7z writer (7zz when a password is set) | — | O-ARCHIVE | P1 |
| RAR | — | **RAR (RARLAB)**: libarchive (7zz for AES) → RAR⬇ (rar a -ma5) *(RAR creation is proprietary; needs RARLAB's rar)* | O-ARCHIVE | P2 |
| TAR | libarchive (7zz for AES) → libarchive tar writer | — | O-ARCHIVE | P1 |
| TAR.BZ2 | libarchive (7zz for AES) → libarchive tar.bz2 writer | — | O-ARCHIVE | P1 |
| TAR.GZ | libarchive (7zz for AES) → libarchive tar.gz writer | — | O-ARCHIVE | P1 |

### 6.9 Vector

#### AI — Adobe Illustrator · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DXF | AIReader (PDF-compatible AI via CGPDF) → VectorKit → DXFWriter | **Ghostscript**: Ghostscript⬇ (pre-CS PostScript AI) → VectorKit → DXFWriter | O-VEC | P1 |
| EMF | AIReader (PDF-compatible AI via CGPDF) → VectorKit → EMFWriter | **Ghostscript**: Ghostscript⬇ (pre-CS PostScript AI) → VectorKit → EMFWriter | O-VEC | P1 |
| EPS PS | AIReader (PDF-compatible AI via CGPDF) → VectorKit → PSWriter | **Ghostscript**: Ghostscript⬇ (pre-CS PostScript AI) → VectorKit → PSWriter | O-VEC | P1 |
| PDF | AIReader (PDF-compatible AI via CGPDF) → VectorKit → CGPDF | **Ghostscript**: Ghostscript⬇ (pre-CS PostScript AI) → VectorKit → CGPDF | O-VEC | P1 |
| PNG | AIReader (PDF-compatible AI via CGPDF) → VectorKit → RenderKit → ImagePipeline → ImageIO | **Ghostscript**: Ghostscript⬇ (pre-CS PostScript AI) → VectorKit → RenderKit → ImagePipeline → ImageIO | O-IMG+DPI | P1 |
| SVG | AIReader (PDF-compatible AI via CGPDF) → VectorKit → SVGWriter | **Ghostscript**: Ghostscript⬇ (pre-CS PostScript AI) → VectorKit → SVGWriter | O-VEC | P1 |
| WMF | AIReader (PDF-compatible AI via CGPDF) → VectorKit → WMFWriter | **Ghostscript**: Ghostscript⬇ (pre-CS PostScript AI) → VectorKit → WMFWriter | O-VEC | P1 |

#### CDR — CorelDRAW · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DXF | — | **LibreOffice**: LibreOffice⬇ (libcdr) → PDF → VectorKit → DXFWriter | O-VEC | P1 |
| EMF | — | **LibreOffice**: LibreOffice⬇ (libcdr) → PDF → VectorKit → EMFWriter | O-VEC | P1 |
| EPS PS | — | **LibreOffice**: LibreOffice⬇ (libcdr) → PDF → VectorKit → PSWriter | O-VEC | P1 |
| PDF | — | **LibreOffice**: LibreOffice⬇ (libcdr) → PDF → VectorKit → CGPDF | O-VEC | P1 |
| PNG | — | **LibreOffice**: LibreOffice⬇ (libcdr) → PDF → VectorKit → RenderKit → ImagePipeline → ImageIO | O-IMG+DPI | P1 |
| SVG | — | **LibreOffice**: LibreOffice⬇ (libcdr) → PDF → VectorKit → SVGWriter | O-VEC | P1 |
| WMF | — | **LibreOffice**: LibreOffice⬇ (libcdr) → PDF → VectorKit → WMFWriter | O-VEC | P1 |

#### CGM — Computer Graphics Metafile · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DXF | — | **LibreOffice**: LibreOffice⬇ (CGM import) → PDF → VectorKit → DXFWriter | O-VEC | P2 |
| EMF | — | **LibreOffice**: LibreOffice⬇ (CGM import) → PDF → VectorKit → EMFWriter | O-VEC | P2 |
| EPS PS | — | **LibreOffice**: LibreOffice⬇ (CGM import) → PDF → VectorKit → PSWriter | O-VEC | P2 |
| PDF | — | **LibreOffice**: LibreOffice⬇ (CGM import) → PDF → VectorKit → CGPDF | O-VEC | P2 |
| PNG | — | **LibreOffice**: LibreOffice⬇ (CGM import) → PDF → VectorKit → RenderKit → ImagePipeline → ImageIO | O-IMG+DPI | P2 |
| SVG | — | **LibreOffice**: LibreOffice⬇ (CGM import) → PDF → VectorKit → SVGWriter | O-VEC | P2 |
| WMF | — | **LibreOffice**: LibreOffice⬇ (CGM import) → PDF → VectorKit → WMFWriter | O-VEC | P2 |

#### EMF — Enhanced Metafile · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | EMFReader → VectorKit → RenderKit → ImagePipeline → AVIFEncoder | — | O-IMG+Q+DPI | P1 |
| BMP PNG PSD | EMFReader → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+DPI | P1 |
| DXF | EMFReader → VectorKit → DXFWriter | — | O-VEC | P1 |
| EMF | EMFReader → VectorKit → EMFWriter | — | O-VEC | P1 |
| EPS PS | EMFReader → VectorKit → PSWriter | — | O-VEC | P1 |
| GIF | EMFReader → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+GIF+DPI | P1 |
| ICO | EMFReader → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+ICON+DPI | P1 |
| JPG | EMFReader → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+Q+DPI | P1 |
| ODD | EMFReader → VectorKit → RenderKit → ImagePipeline → ODFWriter | — | O-IMG+DPI | P2 |
| PDF | EMFReader → VectorKit → CGPDF | — | O-VEC | P1 |
| SVG | EMFReader → VectorKit → SVGWriter | — | O-VEC | P1 |
| TIFF | EMFReader → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+TIFF+DPI | P1 |
| WEBP | EMFReader → VectorKit → RenderKit → ImagePipeline → libwebp | — | O-IMG+Q+DPI | P1 |
| WMF | EMFReader → VectorKit → WMFWriter | — | O-VEC | P1 |

#### SK — Skencil / Sketch · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DXF | SkencilReader → VectorKit → DXFWriter | — | O-VEC | P3 |
| EMF | SkencilReader → VectorKit → EMFWriter | — | O-VEC | P3 |
| EPS PS | SkencilReader → VectorKit → PSWriter | — | O-VEC | P3 |
| PDF | SkencilReader → VectorKit → CGPDF | — | O-VEC | P3 |
| PNG | SkencilReader → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+DPI | P3 |
| SVG | SkencilReader → VectorKit → SVGWriter | — | O-VEC | P3 |
| WMF | SkencilReader → VectorKit → WMFWriter | — | O-VEC | P3 |

#### SK1 — sK1 drawing · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DXF | SK1Reader → VectorKit → DXFWriter | — | O-VEC | P3 |
| EMF | SK1Reader → VectorKit → EMFWriter | — | O-VEC | P3 |
| EPS PS | SK1Reader → VectorKit → PSWriter | — | O-VEC | P3 |
| PDF | SK1Reader → VectorKit → CGPDF | — | O-VEC | P3 |
| PNG | SK1Reader → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+DPI | P3 |
| SVG | SK1Reader → VectorKit → SVGWriter | — | O-VEC | P3 |
| WMF | SK1Reader → VectorKit → WMFWriter | — | O-VEC | P3 |

#### SVG — SVG · 22 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → AVIFEncoder | — | O-IMG+Q+DPI | P1 |
| BMP PNG PSD | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+DPI | P1 |
| DXF | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → DXFWriter | — | O-VEC | P1 |
| EMF | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → EMFWriter | — | O-VEC | P1 |
| EOT | SVGFontReader (<font>/<glyph>) → FontKit → EOT writer *(needs an SVG font; a plain drawing gets a clear message)* | — | O-FONT | P2 |
| EPS PS | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → PSWriter | — | O-VEC | P1 |
| GIF | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+GIF+DPI | P1 |
| ICO | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+ICON+DPI | P1 |
| JPG | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+Q+DPI | P1 |
| ODD | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ODFWriter | — | O-IMG+DPI | P2 |
| OTF | SVGFontReader (<font>/<glyph>) → FontKit → OTF writer *(needs an SVG font; a plain drawing gets a clear message)* | — | O-FONT | P2 |
| PDF | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → CGPDF | — | O-VEC | P1 |
| SVG | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → SVGWriter | — | O-VEC | P1 |
| TIFF | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+TIFF+DPI | P1 |
| TTF | SVGFontReader (<font>/<glyph>) → FontKit → TTF writer *(needs an SVG font; a plain drawing gets a clear message)* | — | O-FONT | P2 |
| WEBP | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → libwebp | — | O-IMG+Q+DPI | P1 |
| WMF | SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → WMFWriter | — | O-VEC | P1 |
| WOFF | SVGFontReader (<font>/<glyph>) → FontKit → WOFF writer *(needs an SVG font; a plain drawing gets a clear message)* | — | O-FONT | P2 |
| WOFF2 | SVGFontReader (<font>/<glyph>) → FontKit → WOFF2 writer *(needs an SVG font; a plain drawing gets a clear message)* | — | O-FONT | P2 |

#### SVGZ — Compressed SVG · 17 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| AVIF | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → AVIFEncoder | — | O-IMG+Q+DPI | P1 |
| BMP PNG PSD | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+DPI | P1 |
| DXF | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → DXFWriter | — | O-VEC | P1 |
| EMF | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → EMFWriter | — | O-VEC | P1 |
| EPS PS | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → PSWriter | — | O-VEC | P1 |
| GIF | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+GIF+DPI | P1 |
| ICO | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+ICON+DPI | P1 |
| JPG | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+Q+DPI | P1 |
| ODD | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ODFWriter | — | O-IMG+DPI | P2 |
| PDF | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → CGPDF | — | O-VEC | P1 |
| SVG | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → SVGWriter | — | O-VEC | P1 |
| TIFF | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → ImageIO | — | O-IMG+TIFF+DPI | P1 |
| WEBP | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → RenderKit → ImagePipeline → libwebp | — | O-IMG+Q+DPI | P1 |
| WMF | gunzip → SVGReader → VectorKit (WebKit for CSS, filters, foreignObject) → WMFWriter | — | O-VEC | P1 |

#### VSD — Visio drawing · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DXF | — | **LibreOffice**: LibreOffice⬇ (libvisio) → PDF → VectorKit → DXFWriter | O-VEC | P1 |
| EMF | — | **LibreOffice**: LibreOffice⬇ (libvisio) → PDF → VectorKit → EMFWriter | O-VEC | P1 |
| EPS PS | — | **LibreOffice**: LibreOffice⬇ (libvisio) → PDF → VectorKit → PSWriter | O-VEC | P1 |
| PDF | — | **LibreOffice**: LibreOffice⬇ (libvisio) → PDF → VectorKit → CGPDF | O-VEC | P1 |
| PNG | — | **LibreOffice**: LibreOffice⬇ (libvisio) → PDF → VectorKit → RenderKit → ImagePipeline → ImageIO | O-IMG+DPI | P1 |
| SVG | — | **LibreOffice**: LibreOffice⬇ (libvisio) → PDF → VectorKit → SVGWriter | O-VEC | P1 |
| WMF | — | **LibreOffice**: LibreOffice⬇ (libvisio) → PDF → VectorKit → WMFWriter | O-VEC | P1 |

#### WMF — Windows Metafile · 8 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| DXF | WMFReader → VectorKit → DXFWriter | — | O-VEC | P1 |
| EMF | WMFReader → VectorKit → EMFWriter | — | O-VEC | P1 |
| EPS PS | WMFReader → VectorKit → PSWriter | — | O-VEC | P1 |
| PDF | WMFReader → VectorKit → CGPDF | — | O-VEC | P1 |
| PNG | WMFReader → VectorKit → RenderKit → ImagePipeline → ImageIO | — | O-IMG+DPI | P1 |
| SVG | WMFReader → VectorKit → SVGWriter | — | O-VEC | P1 |
| WMF | WMFReader → VectorKit → WMFWriter | — | O-VEC | P1 |

### 6.10 CAD

#### DWF — Design Web Format · 12 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| BMP GIF JPG PNG TIFF | DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit → plot → RenderKit → ImageIO | — | O-CAD+IMG | P3 |
| CGM | DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit → plot → VectorKit → CGMWriter | — | O-CAD | P3 |
| DWG | — | **ODA File Converter, LibreDWG**: DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit → DXFWriter → ODA File Converter⬇ / LibreDWG⬇ (dxf2dwg) | O-CAD-DWG | P3 |
| DXF | DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit → DXFWriter (chosen AutoCAD version) | — | O-CAD-DWG | P3 |
| EPS | DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit → plot → VectorKit → PSWriter | — | O-CAD | P3 |
| PDF | DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit → plot → VectorKit → CGPDF | — | O-CAD | P3 |
| SVG | DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit → plot → VectorKit → SVGWriter | — | O-CAD | P3 |
| WMF | DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit → plot → VectorKit → WMFWriter | — | O-CAD | P3 |

#### DWG — AutoCAD drawing · 12 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| BMP GIF JPG PNG TIFF | — | **ODA File Converter, LibreDWG**: ODA File Converter⬇ / LibreDWG⬇ → DXF → DXFReader → CADKit → plot → RenderKit → ImageIO | O-CAD+IMG | P2 |
| CGM | — | **ODA File Converter, LibreDWG**: ODA File Converter⬇ / LibreDWG⬇ → DXF → DXFReader → CADKit → plot → VectorKit → CGMWriter | O-CAD | P2 |
| DWG | — | **ODA File Converter, LibreDWG**: ODA File Converter⬇ (version change) · LibreDWG⬇ | O-CAD-DWG | P2 |
| DXF | — | **ODA File Converter, LibreDWG**: ODA File Converter⬇ (chosen AutoCAD version) · LibreDWG⬇ dwg2dxf | O-CAD-DWG | P2 |
| EPS | — | **ODA File Converter, LibreDWG**: ODA File Converter⬇ / LibreDWG⬇ → DXF → DXFReader → CADKit → plot → VectorKit → PSWriter | O-CAD | P2 |
| PDF | — | **ODA File Converter, LibreDWG**: ODA File Converter⬇ / LibreDWG⬇ → DXF → DXFReader → CADKit → plot → VectorKit → CGPDF | O-CAD | P2 |
| SVG | — | **ODA File Converter, LibreDWG**: ODA File Converter⬇ / LibreDWG⬇ → DXF → DXFReader → CADKit → plot → VectorKit → SVGWriter | O-CAD | P2 |
| WMF | — | **ODA File Converter, LibreDWG**: ODA File Converter⬇ / LibreDWG⬇ → DXF → DXFReader → CADKit → plot → VectorKit → WMFWriter | O-CAD | P2 |

#### DXF — Drawing Exchange Format · 11 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| BMP GIF JPG PNG TIFF | DXFReader → CADKit → plot → RenderKit → ImageIO | — | O-CAD+IMG | P1 |
| CGM | DXFReader → CADKit → plot → VectorKit → CGMWriter | — | O-CAD | P2 |
| DWG | — | **ODA File Converter, LibreDWG**: DXFReader → CADKit → DXFWriter → ODA File Converter⬇ / LibreDWG⬇ (dxf2dwg) | O-CAD-DWG | P2 |
| EPS | DXFReader → CADKit → plot → VectorKit → PSWriter | — | O-CAD | P1 |
| PDF | DXFReader → CADKit → plot → VectorKit → CGPDF | — | O-CAD | P1 |
| SVG | DXFReader → CADKit → plot → VectorKit → SVGWriter | — | O-CAD | P1 |
| WMF | DXFReader → CADKit → plot → VectorKit → WMFWriter | — | O-CAD | P1 |

### 6.11 Fonts

#### EOT — Embedded OpenType · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| OTF | EOTReader (MTX via libeot) → FontKit → CFFBuilder (quadratic → cubic, exact) | — | O-FONT | P2 |
| SVG | EOTReader (MTX via libeot) → FontKit → SVGFontWriter | — | O-FONT | P2 |
| TTF | EOTReader (MTX via libeot) → FontKit → GlyfBuilder (cubic → quadratic, cu2qu ≤ 1/1000 em) | — | O-FONT | P2 |
| WOFF | EOTReader (MTX via libeot) → FontKit → WOFFWriter | — | O-FONT | P2 |
| WOFF2 | EOTReader (MTX via libeot) → FontKit → WOFF2Writer (google/woff2 + Brotli 11) | — | O-FONT | P2 |

#### OTF — OpenType (CFF) · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EOT | SFNTReader → FontKit → EOTWriter | — | O-FONT | P2 |
| SVG | SFNTReader → FontKit → SVGFontWriter | — | O-FONT | P1 |
| TTF | SFNTReader → FontKit → GlyfBuilder (cubic → quadratic, cu2qu ≤ 1/1000 em) | — | O-FONT | P1 |
| WOFF | SFNTReader → FontKit → WOFFWriter | — | O-FONT | P1 |
| WOFF2 | SFNTReader → FontKit → WOFF2Writer (google/woff2 + Brotli 11) | — | O-FONT | P1 |

#### TTF — TrueType · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EOT | SFNTReader → FontKit → EOTWriter | — | O-FONT | P2 |
| OTF | SFNTReader → FontKit → CFFBuilder (quadratic → cubic, exact) | — | O-FONT | P1 |
| SVG | SFNTReader → FontKit → SVGFontWriter | — | O-FONT | P1 |
| WOFF | SFNTReader → FontKit → WOFFWriter | — | O-FONT | P1 |
| WOFF2 | SFNTReader → FontKit → WOFF2Writer (google/woff2 + Brotli 11) | — | O-FONT | P1 |

#### WOFF — WOFF · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EOT | WOFFReader → FontKit → EOTWriter | — | O-FONT | P2 |
| OTF | WOFFReader → FontKit → CFFBuilder (quadratic → cubic, exact) | — | O-FONT | P1 |
| SVG | WOFFReader → FontKit → SVGFontWriter | — | O-FONT | P1 |
| TTF | WOFFReader → FontKit → GlyfBuilder (cubic → quadratic, cu2qu ≤ 1/1000 em) | — | O-FONT | P1 |
| WOFF2 | WOFFReader → FontKit → WOFF2Writer (google/woff2 + Brotli 11) | — | O-FONT | P1 |

#### WOFF2 — WOFF 2 · 5 targets

| To | Built in | With a helper | Options | Rank |
|---|---|---|---|---|
| EOT | WOFF2Reader (google/woff2) → FontKit → EOTWriter | — | O-FONT | P2 |
| OTF | WOFF2Reader (google/woff2) → FontKit → CFFBuilder (quadratic → cubic, exact) | — | O-FONT | P1 |
| SVG | WOFF2Reader (google/woff2) → FontKit → SVGFontWriter | — | O-FONT | P1 |
| TTF | WOFF2Reader (google/woff2) → FontKit → GlyfBuilder (cubic → quadratic, cu2qu ≤ 1/1000 em) | — | O-FONT | P1 |
| WOFF | WOFF2Reader (google/woff2) → FontKit → WOFFWriter | — | O-FONT | P1 |

<!-- END GENERATED MATRIX -->

## 7. Ranking, gaps and differences

**Ranks.** P1: both ends common and the route is built in (or needs only LibreOffice/iWork for original layout).
P2: one end niche, or a helper other than LibreOffice/iWork is required. P3: both ends niche, or a route marked
experimental. Ranks order the work packages (ARCHITECTURE); everything in §6 except "not offered" is in scope.

**Not offered (16 pairs).** GIF and WebP → AAC, AIFF, FLAC, M4A, MP3, WAV, WMA: an image has no sound; CloudConvert
returns an empty or silent file. DSS → DSS: nothing outside Olympus' own software writes DSS. AMR → AMR: the AMR
encoders' patent status could not be confirmed (§2.7); AMR files still convert to every other audio target. The picker leaves these
targets out; searching for one says why ("GIF pictures have no sound").

**Known gaps and risks.**

| Gap | Why | What the app does | Revisit |
|---|---|---|---|
| Classic DWF (W2D streams) | No permissive or free engine; ODA's DWF support is commercial | DWFx works (XPSKit); DWF 6 through an own W2D decoder (P3); until then "This DWF can't be read yet" with a link to Autodesk's free viewer | WP-C |
| CAVS output | Only encoder (libxavs) is GPL | FFmpeg-GPL helper | — |
| RAR output | RAR compression is proprietary | RARLAB helper; picker suggests 7Z or ZIP first | — |
| MTX-compressed EOT | Rare (WEFT-era web fonts) | Own decoder from the W3C MicroType Express submission (P3) | WP-F |
| X3F | Apple doesn't decode Sigma Foveon; LibRaw needs the optional X3F tools | LibRaw dylib if the X3F tools licence checks out, else gap | WP-I |
| SK / SK1 | Format of dead apps (Skencil, sK1 0.9) | Own text-format readers (P3) | WP-V |
| PAGES/NUMBERS/KEY without the apps | iWork's IWA format is undocumented protobuf | The package's own preview (`preview.jpg` / `QuickLook/Preview.pdf` when present) with a notice, plus "Get Pages" | — |
| HWP 5 fidelity | Hancom's spec covers text, paragraph and character shapes, tables; not every drawing object | Own reader; LibreOffice for HWP ≤ 3.0 | WP-D |
| SWF, RM, DVR-MS, WTV output | Obsolete targets | Kept for parity (P3); the picker lists them under "Older formats" | — |

**Where we deliberately differ from CloudConvert** (all for quality or privacy): higher default audio bitrates
(AAC 192 vs 128), CRF 20 instead of 23, bookmarks on in PDFs, embedded pictures in HTML, joined hyphens in PDF → Word,
zoom-to-extents on in CAD, codec lists limited to what the container can carry, colour profile handling everywhere,
web resources off by default when rendering local HTML, and the LaTeX look for text-like documents.
