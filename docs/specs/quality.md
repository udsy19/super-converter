# Quality

"The results should be good" made concrete: what each category does to get the best output, the numbers it must hit,
and how every number is checked automatically. `formats.md` says which engine runs each pair and which options exist;
this file says how well it must run. Decisions are marked **[D]**.

## 1. Principles

1. **The source is the truth.** Nothing is changed that the person did not ask to change: pixels, colours, sample
   values, text, vector geometry, metadata, timestamps. A conversion that cannot carry something over says so on the
   result card ("Layers were flattened", "Transparency filled with white", "3 fonts were replaced", "HDR converted to
   standard range") — a **loss note** [D]. Every engine adapter reports loss notes; no silent degradation.
2. **Lossless when the target allows it, visually lossless by default when it doesn't.** Defaults aim at "you cannot
   tell" first and size second; the options sheet has a "Smaller file" end for people who want it.
3. **One conversion, one decode, one encode.** Routes through an intermediate model (DocModel, vector model, image
   pipeline) never re-encode lossy data twice. JPEG pictures inside documents, comics and PDFs pass through untouched.
4. **Colour is managed end to end** with ColorSync: every pixel has a known colour space at every step.
5. **Measured, not eyeballed.** Each category below lists metrics and thresholds; the quality bench (§9) runs them on
   a fixed corpus on every change and blocks regressions.

## 2. Images and colour

### 2.1 Pipeline [D]

```
ImageIO / CIRAWFilter / ImageCodecs decode
   → float16 RGBA in the source's own colour space (ICC kept attached), un-premultiplied
   → orientation (EXIF) → crop
   → linear light (the source primaries with a linear transfer) for resampling and compositing maths
   → ColorSync conversion to the target space (once) → bit-depth reduction with dither (once)
   → encode (ImageIO / libwebp / libavif / own writers) with metadata copied
```

Core Image does the heavy lifting with `CIContext(options: [.workingColorSpace: extendedLinear<source primaries>,
.workingFormat: .RGBAh])`; vImage does Lanczos and dithering; ColorSync (`CGColorConversionInfo`) does every space
change. 8-bit sources that need no resampling and no colour change skip the float path entirely and are copied with
`CGImageDestinationAddImageFromSource`, so pixels are bit-exact.

### 2.2 Colour profiles [D]

| Situation | What happens |
|---|---|
| Target supports ICC (JPEG APP2, PNG `iCCP`, TIFF tag 34675, WebP `ICCP`, HEIC/AVIF `colr`, PSD resource 1039, PDF `ICCBased`, EPS/PS `ICCBased`, BMP v5, ICNS PNG entries) and "Colour profile: Keep" | The source profile is embedded **byte for byte**; pixels are not converted. For AVIF/HEIC, exact sRGB, Display P3, BT.2020 and BT.2100 profiles are written as `nclx` code points (smaller, universally understood); anything else as the full ICC. |
| Target has no ICC (GIF, ICO, PPM, TGA, CUR) | Converted to sRGB (relative colorimetric + black-point compensation) so every viewer shows the colours the source showed. Loss note when the source was wide-gamut and pixels were out of sRGB. |
| Untagged source | RGB = sRGB IEC 61966-2.1; gray = Gray Gamma 2.2; CMYK = macOS Generic CMYK (`CGColorSpace.genericCMYK`); the output is tagged with that assumption so it stays stable. |
| CMYK source → RGB target | Through the embedded CMYK profile to the target RGB, relative colorimetric + BPC (Photoshop's default). CMYK is kept when the target holds CMYK (JPEG, TIFF, PSD, PDF, EPS) and the profile option is "Keep". |
| RGB → CMYK (person asks) | Perceptual intent into the chosen CMYK profile (Generic CMYK or a dropped `.icc`); black generation from the profile. |
| Camera RAW | Developed by `CIRAWFilter` straight into the target space: Display P3 for HEIC, AVIF, 16-bit PNG/TIFF/PSD; sRGB for JPEG, WebP, GIF, BMP; ProPhoto RGB when the person picks "Edit master (16-bit TIFF)". |
| HDR sources (gain-map HEIC/JPEG/AVIF, PQ/HLG AVIF/HEIC, OpenEXR, 16-bit float TIFF) | HDR kept when the target carries it (HEIC and AVIF with gain map or PQ/HLG; JPEG with gain map on macOS 15+ via ImageIO's ISO 21496-1 support); otherwise tone-mapped to SDR with `CIToneMapHeadroom` (target headroom 1.0) and a loss note. Detected at run time through ImageIO's auxiliary data APIs, never assumed. |
| Alpha | Un-premultiplied before any colour conversion (no dark fringes); flattening onto the background composites in the encoded (gamma) space, because that is what browsers and Finder showed the person. |

Rendering intent default: relative colorimetric + BPC; perceptual is one click away and is used automatically for
RGB → CMYK and for RAW development into small gamuts.

### 2.3 Encoders and defaults

| Target | Encoder | Default | Why |
|---|---|---|---|
| JPEG | ImageIO | quality 90, progressive, ICC + EXIF kept | Visually lossless on the corpus (SSIM ≥ 0.985). WP-I measures ImageIO's chroma subsampling at q ≥ 90; if red-on-white text fails §2.8's edge test (4:2:0 smearing), JPEG moves to a bundled libjpeg-turbo (BSD/IJG/zlib) with 4:4:4 at q ≥ 90 — decision by measurement |
| PNG | ImageIO | lossless; 16-bit kept; palette PNG when the image has ≤ 256 colours and no partial alpha (exactly lossless) | Smaller with zero loss |
| WebP | libwebp | photos: lossy q 90, `-sharp_yuv`, method 6; graphics (PNG/GIF/BMP/ICO/TGA/PPM sources): lossless, `-exact` off, method 6 | `sharp_yuv` fixes chroma bleed on edges |
| AVIF | ImageIO when available, else libavif + SVT-AV1 | quality 80, 10-bit when the source has more than 8 bits or HDR, 4:4:4 at quality ≥ 90, speed 6 | AVIF's 80 matches JPEG 90 visually at about 40 % of the size |
| HEIC | ImageIO | quality 85, 10-bit for > 8-bit sources | Apple Photos' own default range |
| TIFF | ImageIO | LZW + horizontal predictor, 16-bit kept, multi-page kept | Lossless and universally readable |
| GIF | own quantiser → ImageIO | 256 colours, Floyd–Steinberg (serpentine), global palette when it costs < 0.5 dB PSNR, else per-frame | §2.7 |
| ICO / ICNS | ImageIO | all sizes, PNG-compressed 256/512/1024 entries | §2.4 |
| PSD | ImageIO | one flattened layer, 8 or 16-bit, ICC | Layers in the source are composited (loss note) |
| BMP | ImageIO | 24-bit, 32-bit with alpha (BMP v5 + ICC) | |
| EPS / PS | PSWriter | Level 3, Flate (lossless), ICCBased, BoundingBox from pixel size and DPI (72 when absent) | |
| PDF | Core Graphics | JPEG/JPEG 2000 sources passed through; others Flate; page = image size at its DPI | No recompression |

### 2.4 Resampling [D]

- **Downscaling** in linear light with a separable **Lanczos-3** kernel (a = 3). For reductions beyond 2× a box
  pre-filter brings the image to 2× the target first, then Lanczos-3 finishes — no aliasing, no moiré, no darkening.
  Results are clamped to [0, 1] after the kernel to remove ringing overshoot.
- **Upscaling** with Lanczos-3 in linear light, clamped; no sharpening.
- **Icons** (≤ 64 px targets): after downscaling, an unsharp mask (radius 0.5 px, amount 40 %) in gamma space, the way
  icon designers' tools do it; 16 and 32 px entries snap to whole-pixel edges when the source is a vector.
- **Never** nearest-neighbour except "pixel art" sources (≤ 256 px with ≤ 64 colours and hard edges), which scale by
  integer factors with nearest-neighbour and then Lanczos only for the fractional remainder [D].

### 2.5 Camera RAW

`CIRAWFilter` with Apple's defaults (the look of Photos), lens correction on, highlight recovery on, as-shot white
balance, `boostAmount` 1 for "Apple" and 0 for "Neutral" look, noise reduction auto. 16-bit output for TIFF/PNG/PSD.
DNG with embedded previews never uses the preview. Orientation from the RAW's own EXIF. Metadata (camera, lens,
exposure, GPS, ratings) copied to every target that holds EXIF/XMP.

### 2.6 Metadata

EXIF, IPTC and XMP are copied with `CGImageDestinationAddImageFromSource`/`CopyImageSource` (so JPEG → JPEG metadata
edits are lossless). Orientation is applied to pixels and reset to 1. DPI is written. The output file's creation and
modification dates are copied from the source [D] (Photos and Finder sort by them). "All but location" removes GPS
and the location parts of XMP/IPTC.

### 2.7 GIF and palette images

Own quantiser: median cut in **Oklab** with variance-weighted splits, then k-means refinement (3 iterations),
Floyd–Steinberg error diffusion with serpentine scanning in linear light, alpha thresholded at 50 % against the
background (GIF has 1-bit transparency). Animations: shared palette when it costs < 0.5 dB, frame differencing with
transparent unchanged pixels, original delays kept (rounded to 10 ms, GIF's unit, with error carried to the next
frame so total duration is exact). No GPL quantiser (libimagequant is GPL-3) is used.

### 2.8 Image tests (in the quality bench)

| Test | Input | Metric | Threshold |
|---|---|---|---|
| Lossless round trips | 8/16-bit RGB, RGBA, gray, CMYK fixtures; PNG ↔ TIFF ↔ PSD ↔ BMP ↔ WebP-lossless ↔ AVIF-lossless (8-bit 4:4:4) | decoded pixels | bit-exact |
| Profile kept | Display P3, Adobe RGB, ProPhoto, CMYK-tagged sources → every ICC-capable target with "Keep" | embedded profile bytes; pixel ΔE | identical bytes; JPEG/WebP/AVIF/HEIC lossy: mean ΔE00 ≤ 1.0, p95 ≤ 2.5 |
| Profile converted | 24 ColorChecker patches + 1,000 random in-gamut colours, P3/AdobeRGB/CMYK → sRGB | ΔE00 vs a ColorSync reference transform computed in the test | max ≤ 0.5 (8-bit quantisation) |
| No-ICC targets | P3 source → GIF/ICO/TGA | ΔE00 vs the source as displayed | mean ≤ 1.0 (in-gamut) |
| Gamma-correct scaling | 1-px black/white checkerboard 512² → 256², 128², 64² | output value | uniform sRGB 187–188 (50 % linear), never 127/128 |
| Ringing | step edge, Lanczos down/up | overshoot | clamp holds: values within [0, 255] and no halo > 2 levels beyond 3 px |
| Edge chroma | red 12 px text on white → JPEG q90 | ΔE00 at glyph edges | p95 ≤ 6 (fails with 4:2:0 → libjpeg-turbo switch, §2.3) |
| Photo lossy defaults | 24 corpus photos → JPEG 90, WebP 90, AVIF 80, HEIC 85 | SSIM (luma, Gaussian 11×11, σ 1.5); ΔE00 | SSIM ≥ 0.985; mean ΔE00 ≤ 1.5 |
| Alpha edges | anti-aliased logo with alpha → JPG on white | min luminance across edge | ≥ min(fg, bg) − 1 (no dark fringe) |
| RAW | 30 RAW files from raw.pixls.us (CC0), 12 makers | our pipeline vs bare `CIRAWFilter` output | mean ΔE00 ≤ 0.3 (the pipeline adds nothing) |
| HDR | gain-map HEIC → HEIC, AVIF, JPEG (macOS 15+), PNG | gain map present / tone-map | present where supported; SDR highlights not clipped beyond the reference tone map ± 2 % |
| GIF | 10 photos and 10 graphics | ΔE00 mean; banding (gradient step count) | photos ≤ 3.0; graphics ≤ 0.5 with ≤ 256 colours exact |
| Metadata | EXIF-rich JPEG/HEIC/RAW | tag set after conversion | DateTimeOriginal, Make, Model, Lens, GPS (unless stripped) present; Orientation = 1 and pixels rotated |
| Trace (SVG) | 20 logos, 10 line drawings | SSIM of the SVG rendered at source size | logos ≥ 0.95 (poster), drawings ≥ 0.97 (bw) |

## 3. Text and documents: the LaTeX look

When a text-like file (TXT, MD, RST, HTML-as-document, EPUB/FB2/… → PDF, EML, CSV tables, or an office file with
"Look: LaTeX") becomes a PDF, it must look like it came out of `pdflatex` with `\documentclass{article}`,
`\usepackage{lmodern}` and `\usepackage{microtype}`: the same fonts, sizes, spacing, line breaks and page layout. That
is TypesetKit's job. The one place a real TeX runs is `.tex` input (Tectonic helper); everywhere else TypesetKit
reproduces LaTeX's rules natively so no TeX installation is needed.

### 3.1 What "looks like LaTeX" means (the checklist)

1. **Latin Modern** (the OpenType Computer Modern, GUST Font License) at **optical sizes**: body in LM Roman 10,
   headings 12/17 cut, footnotes LM Roman 8, scripts 7/6/5 — as LaTeX picks `lmr10`, `lmr12`, `lmr17`, `lmr8`, … by size.
   Greek and Cyrillic from CMU Serif (OFL) of the same design; math from MathJax's TeX fonts (Computer Modern shapes)
   and Latin Modern Math; monospace LM Mono 10.
2. A **centred text block 345 pt wide** with LaTeX's margins (§3.2), **ragged bottom**, page number centred in the
   footer.
3. **Justified** paragraphs broken with **Knuth–Plass** (whole-paragraph optimisation) and **hyphenation**; first-line
   indent 15 pt and no space between paragraphs; no indent after a heading.
4. LaTeX's **sizes and leading** (10/12 pt body) and **heading styles** (bold, numbered when "Numbered sections" is on).
5. TeX punctuation: curly quotes from straight ones, en dash for ranges (`--`, `1–3`), em dash (`---`), ellipsis,
   **ligatures** fi fl ff ffi ffl, **extra space after sentences** (`\nonfrenchspacing`, not after "e.g." or initials).
6. **Footnotes** at the page bottom with a 0.4 pt rule, **booktabs tables**, captions "Figure 1:" / "Table 1:",
   **TeX math**, lists with LaTeX bullets and spacing, `quote` indents, verbatim code.
7. **microtype-style protrusion**: hyphens and punctuation hang slightly into the margin for optically straight edges
   (factors from microtype's Computer Modern configuration). No font expansion (XeTeX/LuaTeX output has none either).

### 3.2 Exact metrics (TeX points; 1 pt = 1/72.27 in = 0.99626 PDF units — every value below is converted, not rounded)

`article` class, 10 pt option, one-sided, `plain` page style. Margins follow `article.cls`/`size10.clo`:
`\textwidth` = min(paper width − 2 in, 345 pt), `\textheight` = ⌊(paper height − 3.5 in) / 12 pt⌋ × 12 pt + 10 pt,
side margins equal, `\topmargin` = ½ (paper height − 2 in − `\headheight` − `\headsep` − `\textheight` − `\footskip`).

| Quantity | Letter (614.295 × 794.97 pt) | A4 (597.508 × 845.047 pt) |
|---|---|---|
| `\textwidth` | 345 pt | 345 pt |
| `\textheight` | 550 pt (45 lines) | 598 pt (49 lines) |
| Left = right margin | 134.65 pt | 126.25 pt |
| Top of text block (from paper top, incl. `\headheight` 12 pt + `\headsep` 25 pt) | 125.99 pt | 127.02 pt |
| Page number baseline | `\footskip` 30 pt below the last text baseline | same |

A5 (e-books, book style) and other papers use the same formulas; 11 pt and 12 pt options use `size11.clo`/`size12.clo`
values (`\textwidth` 360/390 pt, `\baselineskip` 13.6/14.5 pt, `\parindent` 17/18 pt).

| Size command | Size / leading (10 pt class) | Used for |
|---|---|---|
| `\tiny` / `\scriptsize` / `\footnotesize` / `\small` | 5/6, 7/8, 8/9.5, 9/11 pt | sub-scripts, footnotes, captions in tables, abstract |
| `\normalsize` | 10/12 pt | body |
| `\large` / `\Large` / `\LARGE` / `\huge` / `\Huge` | 12/14, 14.4/18, 17.28/22, 20.74/25, 24.88/30 pt | subsection, section, title, chapter |

| Element | LaTeX definition reproduced |
|---|---|
| `\section` | `\Large\bfseries`, before 3.5 ex (+1 −0.2 ex), after 2.3 ex (+0.2 ex); ex = 4.3055 pt (LM Roman 10) |
| `\subsection` | `\large\bfseries`, before 3.25 ex (+1 −0.2), after 1.5 ex (+0.2) |
| `\subsubsection` | `\normalsize\bfseries`, same spacing as subsection |
| `\paragraph` | run-in `\bfseries`, before 3.25 ex (+1 −0.2), 1 em after the title on the same line |
| Title block | 2 em skip, title `\LARGE` centred, 1.5 em, author `\large`, 1 em, date `\large`, 1.5 em |
| Paragraph | `\parindent` 15 pt, `\parskip` 0 pt + 1 pt, `\parfillskip` 0 pt + 1 fil |
| Lists | `\leftmargini` 25 pt, `\leftmarginii` 22 pt, `\labelsep` 5 pt; `\topsep` 8 pt (+2 −4), `\itemsep` 4 pt (+2 −1), `\parsep` 4 pt (+2 −1); labels •, bold –, ∗, · and 1., (a), i., A. |
| Quote | 25 pt indent both sides |
| Verbatim / code | LM Mono 10/12, unjustified, `\topsep` around |
| Footnotes | `\footnotesize` (8/9.5), rule 0.4 pt × 0.4 `\textwidth`, `\skip\footins` 9 pt (+4 −2), `\footnotesep` 6.65 pt, superscript marks |
| Floats | figures and tables `[tbp]`: top of this page if it fits, else top of the next; `\abovecaptionskip` 10 pt; caption centred when one line |
| Tables (booktabs) | `\heavyrulewidth` 0.08 em, `\lightrulewidth` 0.05 em, `\aboverulesep` 0.4 ex, `\belowrulesep` 0.65 ex, `\tabcolsep` 6 pt; no vertical rules; numbers right- or decimal-aligned; a table wider than the text block steps down to `\small`, then `\footnotesize`; a table of figures and short labels then gets its own landscape page (split with the header repeated), while a table with sentences in its cells (six words or more) wraps its columns as a `p{}` column would |
| Display math | centred, `\abovedisplayskip` 10 pt (+2 −5), `\belowdisplayskip` 10 pt (+2 −5); short-skip variants when the line before is short |
| Links | clickable with no visible box (hyperref `hidelinks`) |
| Page breaking | `\clubpenalty` 150, `\widowpenalty` 150, `\brokenpenalty` 100, headings keep with the next two lines, `\raggedbottom` |

### 3.3 Line breaking: Knuth–Plass in TypesetKit [D]

- **Model.** A paragraph is a list of boxes (word fragments measured with Core Text: `CTTypesetter`, kerning and
  ligatures applied across fragments), glue (inter-word space from the font: LM Roman 10 space 3.33 pt, stretch 1.67,
  shrink 1.11; extra space 1.11 pt after a sentence) and penalties (hyphens, explicit breaks, forbidden breaks before
  `~` ties and inside URLs).
- **Space factors** as plain TeX: 3000 after `.?!`, 2000 after `:`, 1500 after `;`, 1250 after `,`; 999 after an
  upper-case letter so "U.S. Army" and initials get normal spaces.
- **Parameters** as LaTeX: `\pretolerance` 100 (a first pass without hyphenation), `\tolerance` 200,
  `\hyphenpenalty` 50, `\exhyphenpenalty` 50, `\linepenalty` 10, `\adjdemerits` 10000, `\doublehyphendemerits` 10000,
  `\finalhyphendemerits` 5000, `\lefthyphenmin` 2, `\righthyphenmin` 3, looseness 0, four fitness classes.
- **Emergency pass** [D]: where TeX would leave an overfull box, TypesetKit reruns with `\emergencystretch` 3 em (what
  careful LaTeX users set). Overfull lines are never produced.
- **Hyphenation** with TeX's own Liang patterns (hyph-utf8) for the languages whose pattern files are permissively
  licensed — English (US, UK), German, French, Spanish, Dutch, Polish, Portuguese, Ukrainian, Danish, Greek
  (`Resources/Hyphenation/README.md`) — so breaks match `pdflatex`; other languages use
  `CFStringGetHyphenationLocationBeforeIndex` (Apple's dictionaries). Language from `NLLanguageRecognizer` per
  paragraph, overridable; no hyphenation in words with digits, all capitals, URLs, code, or
  words shorter than 5 letters.
- **Drawing**: each line's glue is set to its computed ratio and every box is drawn at its exact x with Core Text, so
  the PDF has real text (selectable, searchable, tagged) with subset-embedded fonts.
- **Protrusion**: margin kerning applied after breaking, with microtype's Computer Modern factors (e.g. hyphen,
  period, comma and quotes protrude up to 70 % of their width; line-final letters do not).
- **Other scripts**: for scripts without spaces or with complex shaping (CJK, Thai, Arabic, Indic) the paragraph
  uses Core Text's line breaker (`CTTypesetterSuggestLineBreak`) and justification inside the same page layout, with
  the system's best font for the script; right-to-left paragraphs keep Core Text's bidi order.

### 3.4 Math [D]

`$…$`, `\(…\)`, `$$…$$`, `\[…\]` and Markdown math blocks go through **MathJax** (Apache-2.0) in JavaScriptCore with
the TeX input and SVG output jax (no DOM, `liteAdaptor`). MathJax's SVG glyphs are Computer Modern outlines, so math
matches TeX's. The SVG paths become vector paths in the PDF (with the TeX source as `/ActualText` so copy and screen
readers get `x^2`). Inline math aligns on MathJax's baseline; display math follows §3.2. MathML and OMML in DOCX/ODT
are converted to TeX first (own converters). Unsupported macros render in red as TeX does in MathJax, and a loss note
lists them.

### 3.5 The other two looks

- **As written** (built-in route for office files): TypesetKit honours the DocModel's fonts, sizes, colours,
  alignment, spacing, page size and margins (DOCX `w:sectPr`, ODT page layouts), still with Knuth–Plass. Microsoft's
  Calibri and Cambria are replaced by their metric-compatible OFL twins **Carlito** and **Caladea** (bundled), so line
  lengths match Word; Arial, Times New Roman, Courier New, Georgia, Verdana and Trebuchet come with macOS. Other
  missing fonts fall back by classification (serif/sans/mono, weight, width) and are listed in a loss note.
- **Original layout** (helper): LibreOffice renders with its own layout engine (its bundle already carries Carlito,
  Caladea and Liberation fonts), export filter options: embed fonts, tagged PDF, bookmarks from headings, PDF/A when
  asked, `ReduceImageResolution` false for "print". Pages/Numbers/Keynote export through their own PDF export.

### 3.6 PDF → editable documents

LayoutKit (from Super PDF) rebuilds paragraphs, columns, headings, lists, tables, figures and reading order, joins
hyphenated line ends when asked, and runs Vision OCR on pages without text. DOCX output uses real paragraphs, styles
(Heading 1–6, List Bullet/Number, Caption, Table Grid), section page size and margins, headers and footers detected as
repeated page furniture, pictures at their native resolution, and the closest installed font for each PDF font.

### 3.7 Document tests

| Test | How | Threshold |
|---|---|---|
| **LaTeX parity** | 40 Markdown/text fixtures (prose in 8 languages, long words, lists, footnotes, tables, math, code, quotes, links). Our `LaTeXWriter` emits `.tex`; Tectonic (dev machine) compiles the golden PDFs, which are committed. TypesetKit renders the same fixture. | Same page count; ≥ 90 % of paragraphs with identical line-ending words (differences come from languages hyphenated with Apple's dictionaries rather than TeX's patterns); first-line baselines within 0.5 pt; page images SSIM ≥ 0.90 at 100 dpi |
| **Typographic lint** (every TypesetKit PDF) | Own checker over TypesetKit's layout log and the PDF | No overfull line (> 0.1 pt past the margin); no line with badness > 200 except emergency-pass lines (logged); ≤ 2 consecutive hyphenated lines; no widow/orphan unless the paragraph is ≤ 2 lines; no heading as last line of a page; all fonts embedded; text extraction equals the source text (hyphens rejoined); bookmarks = headings; tagged structure present |
| **Math** | 120 expressions from the MathJax test suite | SVG renders; widths within 0.5 pt of the TeX golden; no red error boxes |
| **As-written fidelity** | 20 DOCX fixtures written by Word with Calibri/Cambria/Times | Line count per paragraph within ±1 of Word's PDF (golden made on a Mac with Word); page count equal |
| **Original layout** | 30 DOCX/XLSX/PPTX/ODT/PAGES fixtures | Page count equal to the golden; SSIM per page ≥ 0.85 vs Word/Keynote goldens (LibreOffice is not pixel-identical) |
| **PDF → DOCX** | 25 born-digital PDFs (letters, papers, invoices, forms) + 10 scans | Character error rate 0 (born-digital), ≤ 2 % (clean scans); paragraph F1 ≥ 0.95; reading-order Kendall τ ≥ 0.95; table-cell accuracy ≥ 0.90; DOCX opens in TextKit and LibreOffice without repair |
| **Round trips** | DOCX → ODT → DOCX, MD → HTML → MD, MD → DOCX → MD | Text and structure (headings, lists, tables, emphasis, links, images) identical |

## 4. Spreadsheets, presentations and e-books

- **Spreadsheets → PDF (LaTeX look)**: booktabs table, header row detected (bold-free, rule below), numbers
  decimal-aligned and formatted with the cell's number format, wide sheets split into page-width column bands with
  the header repeated, long sheets with the header repeated on every page, landscape when the table is wider than
  tall. CSV quoting per RFC 4180; encodings detected (UTF-8, UTF-16 with BOM, Windows-1252, MacRoman, Shift-JIS).
  Tests: values round-trip XLSX → CSV → XLSX identical as displayed; dates and decimals survive locale changes.
- **Presentations**: slides render at their own size; fonts embedded; pictures at native resolution. Own PPTX renderer
  vs Keynote's export: SSIM ≥ 0.90 per slide on 20 decks (text-and-picture decks); decks with SmartArt or charts
  prefer the helper (planner rule).
- **E-books → PDF**: book style (§3 with `book` metrics scaled to the trim), chapters from the spine, running heads,
  the EPUB's own pictures untouched. EPUB output passes **EPUBCheck** (BSD-3, run in the bench on the dev machine) with
  0 errors and 0 warnings for every EPUB we write; calibre outputs open in calibre's `ebook-meta`.
- **Comics → PDF**: one page per picture, never recompressed (SHA-256 of each JPEG stream equals the source's).

## 5. Video and audio

### 5.1 Video [D]

- **Encoder choice.** H.264/HEVC/ProRes with Apple's VideoToolbox (hardware, licensed with macOS); VP8/VP9 with
  libvpx; AV1 with SVT-AV1; legacy codecs with FFmpeg's native encoders.
- **Quality, not bitrate.** Every encoder runs in constant-quality mode. CloudConvert's `crf` (x264 scale) maps to
  VideoToolbox's `kVTCompressionPropertyKey_Quality` through a **calibration table** measured in WP-M: for 12 test
  clips (talking head, sport, animation, film grain, screen recording, 4K drone, low light…) the VideoToolbox quality
  that gives the same VMAF as x264 `-crf N -preset medium` (dev-only GPL build) for N = 14…35. Default crf 20 ⇒ mean
  VMAF ≥ 95.
- **Colour.** Primaries, transfer, matrix and range are read with `ffprobe` and written to the output; never untagged.
  Scaling across SD/HD converts BT.601 ↔ BT.709 matrices; limited range stays limited. HDR (PQ/HLG) is kept with
  mastering-display and content-light metadata when the target codec carries 10-bit (HEVC Main10, AV1, ProRes, VP9
  profile 2); otherwise tone-mapped (`zscale` + `tonemap=mobius` with peak from metadata) and a loss note.
- **Scaling** with zimg (`zscale`, Lanczos) or VideoToolbox's scaler in hardware paths; **deinterlacing** with `bwdif`
  when `idet` finds interlaced fields (DV, VOB, MTS/M2TS 1080i, MOD); **rotation** metadata applied or kept.
- **Timing.** Variable frame rate kept in MOV/MP4/MKV; containers that need constant rate get exact duplicate/drop
  with audio untouched; A/V offset preserved; timecode tracks copied for MOV/MXF.
- **Copy first.** When the target container can hold the source streams and no option changes them, streams are
  copied (zero loss, seconds instead of minutes); the card says "No re-encoding needed".

### 5.2 Audio [D]

- Decoding to 32-bit float; **lossless chains are bit-exact** (WAV ↔ AIFF ↔ FLAC ↔ ALAC ↔ CAF-PCM, same bit depth).
- Sample-rate conversion with **soxr** (very high quality) in FFmpeg and AudioConverter's `Mastering` complexity in
  AVFoundation paths; bit-depth reduction with TPDF dither; no clipping: a true-peak limiter at −1 dBTP engages only
  when a gain change or resampling would clip (loss note).
- Encoders at transparent defaults: AAC-LC 192 kb/s (AudioToolbox, the best AAC encoder on macOS), MP3 LAME V0, Opus
  160 kb/s, Vorbis q6, AC-3 448 kb/s 5.1 / 192 kb/s stereo, WMA v2 192 kb/s.
- Tags (ID3v2.4, iTunes atoms, Vorbis comments), cover art, chapters (M4B, MKA, Ogg chapter comments) and ReplayGain
  carried over.

### 5.3 Media tests

| Test | Input | Metric | Threshold |
|---|---|---|---|
| Video defaults | 12 clips (1080p/4K, SDR) → MP4 H.264, MP4 HEVC, WebM VP9, MKV AV1 | VMAF (vmaf_v0.6.1; libvmaf BSD-2-Clause-Patent, dev-only FFmpeg) mean / 1 % low | H.264/HEVC ≥ 95 / ≥ 90; VP9/AV1 ≥ 93 / ≥ 88 |
| Size sanity | same | file size vs x264 crf 20 medium at equal VMAF | ≤ 1.3× |
| Colour tags | SMPTE bars in BT.601 SD, BT.709 HD, BT.2020 PQ | decoded bars ΔE00 vs reference | mean ≤ 2.0; black/white levels ±1 code value; tags present |
| HDR kept | PQ and HLG clips → HEVC Main10 MOV, AV1 MKV | metadata + MaxCLL | identical |
| Tone map | PQ → H.264 SDR | mean luminance vs reference tone map; clipped pixels | within 10 %; ≤ reference + 1 % |
| A/V sync | flash-and-beep clip through every video container pair | offset | ≤ 1 frame |
| Duration | all video and audio pairs | duration | ±1 frame (video), ±10 ms (audio) |
| Deinterlace | 1080i and DV fixtures | `idet` interlaced-frame ratio after | < 1 % |
| Lossless audio | 16/24-bit, 44.1/48/96 kHz test tones and music | MD5 of decoded PCM | identical |
| Resampling | 1 kHz sine and sweep 44.1 ↔ 48 ↔ 96 kHz | THD+N; pass-band ripple | ≤ −100 dB; ≤ 0.1 dB to 20 kHz |
| Lossy audio | 10 music excerpts → AAC 192, MP3 V0, Opus 160, Vorbis q6 | ViSQOL v3 MOS (Apache-2.0, dev-only); bandwidth; true peak | MOS ≥ 4.3; ≥ 18 kHz (Opus 20 kHz); ≤ 0 dBTP |
| Loudness option | −16 LUFS normalisation | EBU R128 integrated | ±0.5 LU |
| Metadata | tagged MP3/M4A/FLAC/M4B | tags, cover hash, chapter list | identical |

## 6. Vector

- One vector model; every reader and writer is tested against every other through it. **Nothing is rasterised**
  unless the target cannot express an effect (mesh gradients → WMF, soft masks → EMF); then only that object is
  rasterised at the render density, with a loss note naming it.
- Text stays text by default (fonts embedded/subset per target), outlines on request or for DXF/CGM.
- Stroke geometry exact (widths, joins, caps, miter limits, dashes); colours carried with their ICC/space (SVG gets
  sRGB values converted with ColorSync, plus `color-profile` when the source was wide-gamut).

| Test | Metric | Threshold |
|---|---|---|
| SVG 1.1 W3C test suite subset (200 static tests) → PDF, EPS, EMF | render at 300 dpi vs WebKit's render of the SVG | SSIM ≥ 0.98 (≥ 0.95 for EMF/WMF) |
| PDF ↔ SVG ↔ EPS round trips (50 drawings) | path count, fill colours ΔE00, stroke widths | equal; ≤ 0.5; ±0.01 pt |
| EMF/WMF corpus (40 files from LibreOffice's public test data) | render vs LibreOffice golden (dev) | SSIM ≥ 0.95 |
| Text kept | drawings with text, text-to-path off | extracted text | equals source |
| DXF corpus (30 drawings: architectural, mechanical, GIS) | plot vs ezdxf drawing-add-on golden (dev); entity counts; text insertion points | SSIM ≥ 0.95; equal; ±0.1 drawing unit |
| DXF writer | every DXF we write re-read by our reader and by ezdxf's auditor (dev) | 0 errors |

## 7. Fonts

| Test | Metric | Threshold |
|---|---|---|
| TTF → OTF (quadratic → cubic is exact) | every glyph rasterised at 1000 upem | pixel-identical |
| OTF → TTF (cu2qu) | max outline deviation; IoU at 64 px | ≤ 1 unit per 1000 em; ≥ 0.995 |
| Metrics | advance widths, LSB, `kern`/GPOS, OS/2, hhea, post, name, cmap | identical (except table-specific fields the format requires to change) |
| WOFF/WOFF2 round trip | decompiled tables | semantically identical |
| Loadable | Core Text `CTFontManagerCreateFontDescriptorsFromData` + OTS (OpenType Sanitiser, BSD-3, dev) | loads; 0 OTS errors |
| Rendering | 200-character sample before/after at 12, 24, 72 px | SSIM 1.0 when outlines are untouched; ≥ 0.995 after cu2qu |

## 8. Archives

Archive conversions must not lose a byte or a name.

| Test | Metric | Threshold |
|---|---|---|
| Content manifest | path, size, SHA-256, symlink targets, empty folders, permissions (when both formats hold them), mtime | identical (ZIP's 2-second DOS time tolerated unless the extended timestamp field is present, which we write) |
| Names | Unicode names (NFD from macOS stored as NFC with the UTF-8 flag), CP437/Shift-JIS legacy ZIPs | names render correctly; round trip identical |
| Encryption | password ZIP (AES-256), 7Z with encrypted headers | opens with the password in 7zz, libarchive, Finder's Archive Utility (ZipCrypto variant) |
| Safety | zip-slip (`../`, absolute paths), symlink escapes, zip bombs (ratio > 1000:1 and > 10 GB asks first) | nothing written outside the output folder |
| Every reader | one fixture per archive format (39) | listing and extraction match the reference manifest |

## 9. The quality bench (automated)

- **Target.** `SuperConverterQualityBench`, an executable (the Command Line Tools have no XCTest), runs conversions
  through the same planner and engines as the app (no UI) and measures them. `swift run SuperConverterQualityBench
  [--tier fast|full] [--only <case>]`. Metric code is our own Swift (ΔE2000 via ColorSync to CIE Lab D50; SSIM and
  MS-SSIM with the standard Gaussian window; PSNR; THD+N; manifest hashing), each validated against published
  reference values in its own unit test. VMAF, ViSQOL, EPUBCheck, OTS, Tectonic and ezdxf run only on the developer
  machine or CI image (they are test tools, never shipped) and their results are cached as goldens.
- **Corpus.** `Tests/Corpus/` holds small committed fixtures, most generated by `scripts/make-fixtures.swift`
  (synthetic images with known colours and profiles, test tones and sweeps, SMPTE bars, typeset fixtures) — under
  40 MB total. `scripts/fetch-corpus.sh` downloads the larger external corpus, pinned by SHA-256, only from sources
  whose licence permits it: raw.pixls.us (CC0) for RAW, Xiph's media test collection (clips marked CC/public domain),
  the W3C SVG 1.1 test suite, Google Fonts (OFL), IDPF EPUB 3 samples (CC BY-SA), LibreOffice's public test documents
  (MPL), Wikimedia Commons public-domain images.
- **Goldens.** `Tests/Golden/<case>/` stores expected outputs where exactness matters (hashes, manifests, TeX PDFs)
  and `metrics.json` with the thresholds of this file. `--bless <case>` rewrites a golden; a PR that blesses must say
  why.
- **Regressions.** The bench keeps the last accepted metrics per case; a metric that gets worse by more than its noise
  band (SSIM 0.002, ΔE 0.1, VMAF 0.5, MOS 0.05) fails even when it is still above the threshold.
- **Tiers.** *fast* (≈ 400 cases, < 10 min on an M1): every engine adapter, lossless round trips, colour, LaTeX lint,
  archives, fonts — on every push (CI on a GitHub macOS runner) and before every commit that touches an engine. *full*
  (≈ 3,000 cases, < 2 h): every offered pair in `format-matrix.json` at least once with default options, plus the
  metric suites above — nightly and before every release. A pair with no passing case cannot be marked shipped in the
  catalog (WP1's catalog test reads the bench results).
- **Report.** JSON for CI and an HTML gallery (`.build/quality/index.html`) with side-by-side images, difference
  heat maps, ΔE histograms and TypesetKit vs LaTeX page overlays, for human review of anything visual.
