# UX design

The contract for how Super Converter looks and behaves: the drop window, the file cards, the format picker, the
options sheet, progress and results, helpers on a card, the menu-bar drop target, Finder Quick Actions, Settings,
copy, colour, type, metrics and motion. The mockups in `../mockups/` render these screens (light and dark);
`formats.md` says what converts to what; `quality.md` how well; `../ARCHITECTURE.md` who builds it. Decisions are
marked **[D]**.

## 1. The idea

Drop anything on the window. Each file becomes a colourful card that already knows what it will most likely become
("HEIC → JPG", "MOV → MP4", "DOCX → PDF"). Click the target pill to pick something else from a short, searchable,
colour-coded list. Press the big **Convert** button. Each card fills with colour from what it was to what it becomes,
and turns into the new file: Quick Look it, share it, show it in Finder. Nothing is uploaded; nothing is overwritten.
Smallpdf's "drop, pick, done" — but a Mac app: native window, sheets, popovers, Quick Look, Finder Quick Actions and
a menu-bar drop target.

### 1.1 Rules every screen passes

| Rule | In practice |
|---|---|
| **Two clicks to convert** | Drop → **Convert**. The default target is right for most people (§6.1); changing it is one more click. |
| **Plain words** | "Photo details" (not EXIF), "Colours" (not ICC profile), "Smaller file ↔ Best quality" (not CRF/bitrate), "Needs calibre" (not "missing dependency"). Technical names stay in "More options" and in search synonyms, so experts find them. |
| **Formats are shown, not explained** | Every format appears as a pill in its category colour with its extension in capitals. The colour says the kind of file before the letters are read. Colour never works alone: pills always carry text. |
| **Say what will happen** | Buttons are verbs with counts: "Convert 8 files", "Install", "Enter Password…", "Show in Finder". Never "OK", "Process", "Submit". |
| **Nothing is lost** | Results are new files next to the originals with the same name and the new extension; collisions get " 2". Originals are never moved, renamed or deleted. What a conversion cannot carry over is said on the card (loss notes, quality §1). |
| **Say what happened** | "Done. 7 of 8 files converted — 1.7 GB → 356 MB" with Show in Finder · Share… · Convert more. Failures say why and offer the one fix. |
| **Big targets** | Cards 208 × 250 pt, target pills 26 pt tall, the Convert button 44 pt, the drop zone is the whole window. |
| **Apple's tone** | Sentence case, curly quotes around names, a real ellipsis on anything that opens something, no exclamation marks, no "Oops", errors don't apologise. |

## 2. Surfaces

| Surface | What it is | Mockup |
|---|---|---|
| Main window | One window: drop zone when empty, card grid (or list) with an action bar when not | `window-empty.png`, `window-drag.png`, `window-cards.png`, `target-picker.png`, `options-sheet.png`, `window-converting.png`, `window-done.png` (+ `-dark`) |
| Menu-bar drop target | Status item; drop files on it or click it for a small panel that converts without the main window | `menubar.png` |
| Finder Quick Actions | Right-click › Quick Actions › "Convert with Super Converter…", "Convert to JPG", "Convert to PDF", … | `quick-action.png` |
| Dock, Open With, Services | Drop on the Dock icon; Finder's Open With › Super Converter for all 212 formats; Services › "Convert with Super Converter" | — |
| Settings | General, Formats, Helpers, Quick Actions, About | `settings-helpers.png` |
| Command line | `sconv` (ARCHITECTURE): same engines, for scripts and tests | — |

## 3. Design tokens

### 3.1 Type [D]

| Role | Font | Size / line / weight | Used for |
|---|---|---|---|
| Display | SF Pro Rounded (`NSFont.systemFont(…).withDesign(.rounded)`) | 30/36 heavy (800), tracking −0.3 | Empty-state headline |
| Title | SF Pro Rounded | 17/22 bold | Sheet and popover titles, Settings headings |
| Summary | SF Pro Rounded | 15/20 bold | Action-bar summary, primary button label (15 bold) |
| Pill | SF Pro Rounded | 11/1 bold, uppercase, tracking +0.35 (target pill 12) | Format pills, chips, section heads (11 bold, tracking +0.6) |
| Body | SF Pro Text | 13/16 semibold (file names), 13/18 regular | Card names, rows, controls |
| Meta | SF Pro Text | 11/14 regular, tabular figures, secondary colour | Sizes, dimensions, durations, progress |

Rounded is the personality (cheerful, friendly, still Apple); everything people read at length is SF Pro Text.

### 3.2 Category colours [D]

Eleven hues around the wheel, one per category, so a glance tells photos from documents from video. Each hue has four
tokens: **base** (the vivid hue: progress fills, flows, dots), **ink** (text on tint), **tint** (pill and thumbnail
backgrounds), **deep** (fills under white text). Dark mode keeps base and deep and swaps ink and tint.

| Category | Base | Ink | Tint | Deep | Dark ink | Dark tint | Ink/tint contrast (light · dark) | Filled pill text |
|---|---|---|---|---|---|---|---|---|
| Documents | `#3D6CF2` | `#1E46B4` | `#E6ECFD` | `#2F5BD6` | `#94AEF8` | `#2B3659` | 6.9 · 5.4 | white on deep (5.9) |
| Images | `#EE4A8C` | `#AE1757` | `#FDE7F0` | `#D13374` | `#F69BC0` | `#522F43` | 5.8 · 5.6 | white on deep (4.7) |
| Video | `#7A5AF0` | `#5132C2` | `#EEEAFD` | `#6848DB` | `#B6A4F7` | `#383259` | 6.9 · 5.4 | white on deep (5.9) |
| Audio | `#FF8A1F` | `#A9500A` | `#FFF0E2` | `#D87016` | `#FFBF84` | `#563D2B` | 4.9 · 6.2 | `#16171C` on base (7.6) |
| Spreadsheets | `#1FB36B` | `#0C7642` | `#E2F5EC` | `#169859` | `#84D5AE` | `#24463B` | 5.0 · 6.0 | `#16171C` on base (6.6) |
| Slides | `#F2554B` | `#B02A21` | `#FDE9E8` | `#D44238` | `#F8A29C` | `#533134` | 5.6 · 5.7 | white on deep (4.5) |
| E-books | `#12ADA6` | `#06716C` | `#E0F4F3` | `#0D928C` | `#7DD2CE` | `#224448` | 5.1 · 6.0 | `#16171C` on base (6.4) |
| Archives | `#F2B705` | `#7F5C00` | `#FDF6DE` | `#BE8E03` | `#F8D776` | `#534725` | 5.7 · 6.5 | `#16171C` on base (9.8) |
| Vector | `#B04FE0` | `#7B20AB` | `#F5E8FB` | `#983AC8` | `#D49EEE` | `#443055` | 6.8 · 5.5 | white on deep (5.6) |
| CAD | `#1C9FE3` | `#0A6A9E` | `#E1F3FB` | `#1487C4` | `#82CAF0` | `#244156` | 5.2 · 5.9 | `#16171C` on base (6.1) |
| Fonts | `#7DBE22` | `#4A740C` | `#EEF7E2` | `#669D18` | `#B8DB85` | `#39482B` | 5.0 · 6.3 | `#16171C` on base (7.9) |

Tint = base mixed 13 % into white (light) or 22 % into the card colour (dark); deep = base mixed 45 % toward ink.
Every text-on-colour pair is ≥ 4.5 : 1 (WCAG AA for small text); the filled-pill rule (white on deep, or near-black
on base) was chosen per hue by contrast, which is why audio, sheets, e-books, archives, CAD and fonts have dark labels.
With **Increase Contrast** on, tints darken by 6 % and pills gain a 1 pt ink border.

### 3.3 Neutrals

| Token | Light | Dark |
|---|---|---|
| Window background | `#F4F5F9` | `#1B1C21` |
| Card / popover / sheet | `#FFFFFF` | `#26272E` |
| Hairline | `rgba(20,22,40,.09)` | `rgba(255,255,255,.08)` |
| Strong hairline (fields) | `rgba(20,22,40,.16)` | `rgba(255,255,255,.16)` |
| Text / secondary / tertiary | `#16171C` / `#636774` / `#9A9EAA` | `#F2F3F7` / `#A3A7B4` / `#6E7280` |
| Control fill / hover | `rgba(20,22,40,.06)` / `.10` | `rgba(255,255,255,.08)` / `.12` |
| Action bar | `rgba(255,255,255,.82)` + background blur 24 (an `NSVisualEffectView`, `.headerView` material) | `rgba(38,39,46,.84)` |
| Success / warning / failure | `#1FA855` / `#F2A100` / `#E5484D` | same |
| Focus and selection | system accent colour (`NSColor.controlAccentColor`) | same |

### 3.4 The signature: colour that flows from what a file was to what it becomes [D]

One idea carries the brand, and it encodes something true about every conversion:

1. **The flow arrow** between the source pill and the target pill is a 15 × 2 pt line with a gradient from the
   source's base colour to the target's, ending in the target-coloured arrowhead (HEIC → PDF reads pink → blue).
2. **Progress** inside the card's thumbnail is a 6 pt capsule filled with the same source → target gradient.
3. **On completion** the card's tint cross-fades from the source category to the target category (400 ms), the
   thumbnail becomes the new file's Quick Look thumbnail and a green "Done" badge pops in. A slide deck that became a
   PDF turns from coral to blue.
4. **The Convert button** is filled with the target colours of the batch: one category → that category's filled-pill
   colours; several → a left-to-right gradient through their deep colours in card order, label white 15 pt bold
   (≥ 3 : 1 large-text contrast on every deep stop; archives and fonts use their ink as the stop).
5. **The drop zone** border becomes a gradient through all eleven hues while files hover.

Everything else stays quiet: neutral window, white cards, system controls. No confetti, no mascots.

### 3.5 Metrics (points)

| Element | Metric |
|---|---|
| Main window | default 1080 × 700, minimum 640 × 480, remembers frame; unified toolbar 52 |
| Toolbar | traffic lights; title "Super Converter" 13 bold + subtitle 11 ("8 files · 1.7 GB", "Converting 2 of 8", "7 of 8 converted"); right: Add Files (+), Grid/List segmented (24 tall), Clear (trash) |
| Drop zone (empty) | inset 18 from the content edges, corner radius 22, 2 pt dashed strong hairline (dash 6, gap 5); hovering: 3 pt gradient border (§3.4) + radial tint glow |
| Grid | padding 20 × 22, gap 18, columns of 208 centred; list view below 640 wide or above 60 files [D] |
| Card | 208 × 250, radius 16, 8 inset, white, hairline + shadow (0 .5 1 / 6 %, 0 6 18 / 6 %); selected: 2.5 pt accent ring |
| Thumbnail well | 192 × 132, radius 11, category tint; Quick Look thumbnail fitted in 160 × 108 with a 2/5 pt shadow; remove (×) 20 pt circle at top-right on hover |
| Name / meta | 13 semibold, 2 lines max, 6 inset; meta 11, 1 line, 2 below |
| Card row | bottom 4 inset: source pill (22 tall, radius 11, 8 padding) · flow (15 × 2, 3 gap) · target pill (26 tall, radius 13, padding 11/9, chevron 10) · options button (26 circle) right-aligned |
| Badges | "Done"/"Didn't convert" 22 tall, 9 from the well's top-left, white on success/failure colour, 11 rounded bold |
| Card notice (helper) | inside the well, 8 inset, radius 9, white 94 %, 11 text; mini button 22 tall black capsule |
| Action bar | 76 tall, 20 side padding, blur material, top hairline; left: "Set all to" popup, "Save to" popup; right: primary button 44 tall capsule, 22/20 padding, 18 pt arrow |
| Format picker popover | 452 wide, radius 14, padding 14/16; search field 32 tall; "Best for …" chips 78 × 58 radius 12; format chips 28 tall, min 52 wide, radius 8, 6 gap; section heads 11 rounded bold uppercase with an 8 pt category dot |
| Options sheet | 600 wide, attached under the toolbar, padding 22/26; label column 132 right-aligned; rows 9 vertical padding; footer with checkbox + Cancel + Done (default) |
| Menu-bar panel | 360 wide, radius 14, `.popover` material, rows 56 with 40 pt thumbnails |
| Settings | 820 × 770, toolbar-style tab bar (General, Formats, Helpers, Quick Actions, About), rows 9/20 padding with 40 pt helper icons |

### 3.6 Motion [D]

| Moment | Animation | Reduce Motion |
|---|---|---|
| Files dropped | Cards appear with a spring (response 0.35 s, damping 0.8) from 92 % scale and 0 opacity, staggered 25 ms (max 12 staggered, the rest together) | fade 150 ms |
| Drop-zone hover | gradient border hue-rotates once every 3 s; the fan of five sample cards spreads 30 % | static gradient |
| Progress | fill eases linearly; indeterminate phases (probing, helper start) show a gentle shimmer | no shimmer |
| Done | tint cross-fade 400 ms (§3.4), "Done" badge springs from 60 % scale | cross-fade only |
| Batch done | action bar content slides up 12 pt and fades in; one soft system sound if the window is not frontmost and notifications are off | fade |
| Picker / sheet | system popover and sheet animations | system |

### 3.7 Icons

SF Symbols where macOS has them: `plus`, `square.grid.2x2`, `list.bullet`, `trash`, `arrow.right`,
`slider.horizontal.3`, `magnifyingglass`, `square.and.arrow.up`, `eye`, `folder`, `checkmark`, `exclamationmark`,
`arrow.down.circle`, `gearshape`, `xmark`, `stop.fill`, `lock`. The app's mark is a rounded square holding three
tilted cards (pink photo, blue page, violet frame) with a white circular double arrow; the menu-bar icon is the
double arrow alone as a template image (WP-R draws both, `scripts/make-icon.swift` as in the sister apps).

## 4. Window anatomy

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   Super Converter                                              [+]  [▦|☰]  [🗑]          │ 52 toolbar
│         8 files · 1.7 GB                                                                       │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                       │
│   │ ░░ thumb ░░░ │  │ ░░ thumb ░░░ │  │ ░░ thumb ░░░ │  │ ░░ thumb ░░░ │   cards 208 × 250     │
│   │ ░░ (tint) ░░ │  │              │  │              │  │              │   gap 18              │
│   │ Beach at…    │  │ Quarterly…   │  │ Interview…   │  │ Podcast…     │                       │
│   │ 4.2 MB · …   │  │ 86 KB · …    │  │ 1.4 GB · …   │  │ 212 MB · …   │                       │
│   │ HEIC ─▶ JPG▾ ⚙│  │ DOCX ─▶ PDF▾ ⚙│  │ MOV ─▶ MP4▾ ⚙ │  │ WAV ─▶ MP3▾ ⚙│                       │
│   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘                       │
│   …                                                                                            │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│ Set all to [Choose a format ⇕]   Save to [📁 Next to the originals ⇕]      ( Convert 8 files → ) │ 76 action bar
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 5. Screens

### 5.1 Empty window (`window-empty.png`)

The whole content is the drop zone. Centre: a fan of five sample cards (JPG photo, PDF page, MP4 frame, MP3 wave,
EPUB cover, rotated −22°…+22°), the headline **"Drop files to convert"**, the line "Photos, videos, documents,
e-books, fonts and archives — 212 formats. Everything happens on this Mac.", the button **Choose Files…** (black
capsule in light mode, white in dark — the only neutral-filled button, because the window has no target yet), and
a row of **Popular** pairs (HEIC → JPG, MOV → MP4, DOCX → PDF, PDF → WORD, WEBP → PNG, WAV → MP3, EPUB → PDF,
TTF → WOFF2). Clicking a pair opens the file chooser filtered to that source and presets the target. Bottom line:
"Also: drop files on Super Converter in the menu bar, or right-click files in Finder › Quick Actions › Convert with
Super Converter".

### 5.2 Dragging files in (`window-drag.png`)

Anywhere over the window: the drop zone's border turns into the eleven-hue gradient, the fan spreads, the headline
says what will happen: **"Drop 3 files to add them"** and "2 photos and a video. You'll pick what each becomes
next." (counted by category from the pasteboard's UTTypes). Folders are accepted and expanded (one level by default,
"Include subfolders" asked when they contain more than 200 files). Files that nothing can read are still added and
show "Super Converter can't read this kind of file yet" on their card. Drop over existing cards adds to the end.

### 5.3 Files ready (`window-cards.png`, `-dark`)

Each card: thumbnail (Quick Look, generated off the main thread), name, meta (size + the one or two facts that
matter for that kind: pixel size, pages, duration, sample rate, chapters, glyphs, files inside), and the conversion
row. Click a card to select (⌘/⇧ for many); the target pill opens the picker (§5.4); ⚙ opens options (§5.5).
Selecting several cards and picking a target changes all of them. **Set all to** offers the targets that every card
can become (intersection), else "Choose a format" with per-category groups ("Images to JPG, documents to PDF"). The
Convert button counts files; ⌘↩ presses it.

### 5.4 Choosing a format (`target-picker.png`)

A popover from the target pill. Search field first ("Search 16 formats for HEIC"; matches extensions, names and
synonyms such as "word", "kindle", "mp3 audio", "transparent"). Then **Best for …** — four or five big chips with a
two-word reason ("JPG · Any app", "HEIC · Smallest", "PNG · No loss", "WEBP · For the web", "PDF · Document"), then
every other target grouped by category with category dots, each group with a hint when the result is not obvious
("PDF — one page per photo", "SVG — traced into shapes"). Only targets that exist for this input appear (§6.2 of
`formats.md`); targets needing a helper show a small ⬇ and say so on hover ("Needs calibre — free, 160 MB"). Footer:
"Use JPG for HEIC files from now on" (on by default) and key hints (↩ choose · esc close). Arrow keys move, typing
filters, ↩ picks.

### 5.5 Options (`options-sheet.png`)

A sheet titled with the pair ("HEIC → JPG — JPG options", subtitle "Beach at golden hour.heic and 1 more photo" when
several cards share the pair). The first three or four controls of the option profile (`formats.md` §5) in plain
words; the rest under **More options** with the technical names in brackets. Live estimate under quality controls
("About 2.1 MB each — looks the same as the original"), computed by encoding a 512-px sample in the background.
Footer: "Use these settings for every JPG" (off), Cancel, **Done**. Cards whose options differ from the defaults
show a filled ⚙.

Per-profile first controls [D]: images — Quality, Size, Colours, Photo details; RAW — Look, White balance, Exposure,
Size; video — Quality, Size, Frame rate, Sound; audio — Quality, Channels, Sample rate, Loudness; documents → PDF —
Look (Original / As written / LaTeX), Paper, Base size, Contents page; spreadsheets → PDF — Look, Sheets, Fit;
slides — Slides or handouts, Speaker notes; e-books → PDF — Page size, Text size; archives — Compression, Password;
fonts — Subset; CAD — Layouts, Paper, Colours; trace — Preset, Colours, Smoothness.

### 5.6 Converting (`window-converting.png`)

Cards convert in the order shown, several at once (§6.4). A converting card dims its thumbnail, shows the flow
progress capsule (§3.4) and meta "62 % · about 40 s left" (or "Slide 7 of 18", "Page 3 of 12", "Chapter 4 of 31").
Waiting cards say "Waiting…". The action bar shows "Converting… 2 of 8 done", time left and an overall gradient bar;
the button becomes **Stop** (⌘.), which finishes nothing half-written (partial outputs are deleted). The Dock icon
shows a progress bar and a badge with the files left. Cards stay editable until they start.

**Helpers on the card.** A card whose route needs a helper that is missing shows a notice inside the thumbnail:
**"Needs calibre — Free · 160 MB"** and **Install** (or **Get…** for vendor apps). Install shows progress in the same
notice ("Installing calibre… 64 %"), verifies the download, and the card converts as soon as it is ready; other
cards keep going meanwhile. If an optional helper would do better ("Original layout needs LibreOffice"), the card
converts built in and the done card offers "Make it look like the original — Install LibreOffice".

### 5.7 Done (`window-done.png`, `-dark`)

Each finished card turns to its target colour, shows the new file's thumbnail, the new name, the new size ("1.9 MB ·
was 4.2 MB") and three icon buttons: Quick Look (or Space), Share, Show in Finder. Finished cards can be dragged out
(file promises) and double-clicked to open in the default app. Loss notes appear as an ⓘ line under the meta
("ⓘ Layers flattened"), with a popover listing everything. The action bar: green check, **"Done. 7 of 8 files
converted"**, "1.7 GB → 356 MB, saved next to the originals · 1 needs a password", Show in Finder (selects all
outputs), Share…, **Convert more** (clears finished cards). A failed card says why in one line and offers the fix
(§7.2). If the window is in the background when a batch of more than 10 s finishes, a notification says the same
summary with a Show action.

### 5.8 List view

Above 60 files (or by ⌘2): rows 56 pt — 40 pt thumbnail, name and meta, source pill → target pill, status (progress
capsule, "Done", reason), and the same actions. Sorting by name, kind, size, status. Same keyboard and drag rules.

### 5.9 Menu-bar drop target (`menubar.png`)

A status item (template icon) that accepts drops. Dropping files opens a 360 pt panel listing them with their
default targets (changeable with the same pills and picker), **Convert 2 files**, "Saved next to the originals ·
Change…", and **Recently converted** (last 10, each with Show in Finder). Clicking the icon opens the same panel
with a small dashed drop area when empty. Footer: Open Super Converter (⌘O), Settings. Settings › General: "Show in
menu bar" (on), "Convert as soon as files are dropped on the menu bar" (off).

### 5.10 Finder Quick Actions (`quick-action.png`)

Shipped as action extensions (the pattern of Super PDF's Quick Actions): **Convert with Super Converter…** (every
file type; opens the window with the files) and one-step actions that convert in the background with the saved
defaults and post a notification: **Convert to JPG** (images), **Convert to PNG** (images), **Convert to PDF**
(documents, images, slides, sheets, e-books), **Convert to MP4** (video), **Convert to MP3** (audio and video).
Each appears only for files it can take (`NSExtensionActivationRule` by UTType). The first three are enabled on
first launch; the rest are off until switched on in Settings › Quick Actions (which opens System Settings ›
Extensions). The same five are available as Services.

### 5.11 Settings (`settings-helpers.png`)

- **General**: Save to (next to the originals · Downloads · a folder…), When a file with that name exists (add a
  number · replace · ask), Remember my format choices (on), Show in menu bar (on), Notify when done (on), Play a
  sound (off), Keep originals (always; a fixed line, not a switch), Appearance follows the system.
- **Formats**: every target with its saved options (from the options sheet's "Use these settings for every …"),
  each resettable; default targets per source format (§6.1), editable.
- **Helpers**: every helper (`formats.md` §4) with its icon, what it unlocks as pills, status (Installed · version ·
  size / Not installed · download size / Installing… %), licence, and **Install**, **Remove**, **Get…** or
  **Get Numbers…**; intro: "Super Converter converts most files by itself. These free helpers add the rest. They
  install into your Library folder or Applications, never run on their own, and can be removed any time."
- **Quick Actions**: which one-step actions are offered and their targets.
- **About**: version, Check for Updates, automatic updates switch, the privacy statement (§6.6), licences
  (`THIRD_PARTY_NOTICES.md`), source code link.

## 6. Behaviour

### 6.1 Default targets [D]

The person's last choice for a source format wins ("Use … from now on"). Before that:

| Source | Becomes |
|---|---|
| HEIC, HEIF, camera RAW, JFIF | JPG |
| JPG, JPEG | PDF |
| PNG, BMP, TGA, PPM, ICO, ICNS, PSD, PSB, XCF, TIFF, AVIF, WEBP (with transparency) | PNG (WEBP and AVIF without transparency → JPG) |
| GIF (animated) | MP4 · GIF (still) → PNG |
| EPS, PS, AI, CDR, VSD, CGM, SK, SK1, XPS, ODG, ODD, PUB | PDF (AI → SVG) |
| SVG, SVGZ, EMF, WMF | PNG |
| DOC, DOCX, DOCM, DOT, DOTX, ODT, RTF, PAGES, WPD, WPS, LWP, ABW, ZABW, HWP, HWPX, SDW, MD, TXT, RST, TEX, HTML, DJVU, EML | PDF |
| PDF | DOCX ("Word") |
| XLS, XLSM, ODS, NUMBERS, ET, SDC, CSV | XLSX · XLSX → PDF |
| PPT, PPS, PPSX, POT, POTX, PPTM, ODP, KEY, DPS, SDA | PPTX · PPTX → PDF |
| EPUB, CBZ, CBR, CBC, CHM, AZW4 | PDF |
| MOBI, AZW, AZW3, PRC, PDB, LIT, LRF, FB2, HTMLZ, TXTZ, PML, RB, SNB, TCR, OEB, HTM | EPUB |
| MOV, MKV, AVI, WEBM, WMV, FLV, MPG/MPEG, M2TS/MTS/TS, VOB, 3GP/3G2, MXF, DV, OGV, RM/RMVB, SWF, WTV, DVR, MOD, CAVS, OGG (video) | MP4 |
| MP4, M4V | MP3 |
| WAV, AIFF, AIF, AIFC, FLAC, M4A, M4B, OGG/OGA, OPUS, WEBA, WMA, AMR, AC3, AU, CAF, VOC, DSS | MP3 · MP3 → WAV |
| SF2 | ZIP of WAV samples (+ SFZ) · SFARK → SF2 |
| RAR, 7Z, TAR (any compression), GZ, BZ2, XZ, LZ, LZMA, Z, LZO, RZ, CAB, ARJ, LHA, ACE, ALZ, ARC, CPIO, DEB, RPM, ISO, IMG, DMG, JAR, EML (as archive) | ZIP · ZIP → 7Z |
| DWG, DXF, DWF | PDF |
| TTF, OTF | WOFF2 · WOFF, WOFF2, EOT → TTF |

### 6.2 Recognising files

By content first, extension second: UTType from the file system, then magic bytes (a sniffer table in Core for every
format, e.g. `ftypheic`, `%PDF-`, `PK\3\4` + `[Content_Types].xml` part names to tell DOCX/XLSX/PPTX/EPUB/JAR/
ODF/HWPX/PAGES apart, `Rar!\x1A\x07`, `7z\xBC\xAF`, `\x1F\x8B`, `ID3`, `fLaC`, `RIFF…WAVE`/`AVI `/`WEBP`/`sfbk`,
`OggS`, `\x1A\x45\xDF\xA3` Matroska/WebM, `FWS/CWS/ZWS`, `AC10xx` DWG, `0\nSECTION` DXF). A file named `.jpg` that
is really a PNG is treated as PNG and its card says "This is a PNG file".

### 6.3 Output naming and place

Same name, new extension, in the chosen place (default next to the original; if that folder isn't writable, the
Downloads folder, said on the card). Collisions add " 2", " 3" (Finder's style); "Replace" in Settings never replaces
the source itself. Multi-file results (pages, slides, frames, archive contents, SF2 samples) go into a folder
"<name> (<FORMAT>)" with "<name> – page 1.png" style names (en dash, as in Super PDF). Creation and modification
dates are copied from the source (quality §2.6). Partial files are written into a hidden work folder and moved into
place only when complete.

### 6.4 Running jobs

Queue classes [D]: video encodes 1 at a time (2 on Macs with two media engines), audio 4, images and documents up to
the number of performance cores, archives 2, one job per helper (LibreOffice, calibre, Ghostscript, …). Small files
start alongside a long video. Sleep is prevented while converting (`ProcessInfo.beginActivity`), the app can be
hidden or its window closed (the menu-bar item shows progress); quitting asks "Stop converting 3 files?".

### 6.5 Keyboard

⌘O add files · ⌘↩ convert · ⌘. stop · Space Quick Look · ⌫ remove · ⌘A select all · T open the picker for the
selection · ⌥⌘O options · arrows move between cards · ⌘1 / ⌘2 grid / list · ⇧⌘R show results in Finder · ⌘,
Settings · ⌘W close window (conversions continue).

### 6.6 Privacy

Nothing leaves the Mac. The only network traffic: the update check (GitHub Releases, can be turned off), helper
downloads the person starts with Install, and — only when the person turns on "Load web resources" for one HTML file
— that page's own pictures and styles. No accounts, no analytics, no crash upload.

### 6.7 Accessibility

Every card is one accessibility element: "Beach at golden hour, HEIC photo, 4.2 megabytes. Becomes JPG." with
actions Change format, Options, Remove, Quick Look; progress announced at 25 % steps and on completion. All controls
reachable by keyboard with visible focus rings. Colour never stands alone (pills carry text, badges carry words).
Reduce Motion and Increase Contrast respected (§3.2, §3.6). Dynamic text sizes follow the system's sidebar/list
size setting for card text.

## 7. Copy

### 7.1 States

| Where | Text |
|---|---|
| Empty headline / line | "Drop files to convert" / "Photos, videos, documents, e-books, fonts and archives — 212 formats. Everything happens on this Mac." |
| Drag over | "Drop {n} files to add them" / "{summary by kind}. You'll pick what each becomes next." |
| Toolbar subtitle | "{n} files · {size}" · "Converting {done} of {n}" · "{done} of {n} converted" |
| Card meta while converting | "{p} % · about {t} left" · "Page {i} of {n}" · "Slide {i} of {n}" · "Waiting…" · "Waiting for {helper}" |
| Card meta when done | "{new size} · was {old size}" (or the most useful fact: pages, duration, chapters) |
| Action bar while converting | "Converting… {done} of {n} done" / "About {t} left" |
| Action bar when done | "Done. {ok} of {n} files converted" / "{old} → {new}, saved {place}" + " · {k} need attention" |
| Helper notice | "Needs {helper}" / "Free · {size}" · "Installing {helper}… {p} %" |
| Optional helper on done card | "Make it look like the original — Install LibreOffice" |

### 7.2 Problems (one line, one fix)

| Situation | Card says | Button |
|---|---|---|
| Password-protected source | "This PDF needs its password" | Enter Password… |
| Damaged or not what it claims | "This file looks damaged — it couldn't be read as DOCX" | Try with LibreOffice (when present) |
| DRM-protected e-book or video | "This book is locked by the store it came from (DRM) and can't be converted" | — |
| Helper missing | "Needs calibre" | Install / Get… |
| Helper took too long | "LibreOffice took longer than 2 minutes and was stopped" | Try Again |
| Not enough space | "There isn't enough space on “Macintosh HD” — 1.2 GB more is needed" | Show in Finder |
| Folder not writable | "Super Converter can't save into “Shared”" | Choose Another Folder… |
| Not readable yet | "Super Converter can't read this kind of file yet" | Show in Finder |
| Classic DWF | "This is a classic DWF drawing, which Super Converter can't read yet" | — |
| Impossible pair (searched) | "GIF pictures have no sound" | — |

## 8. Mockups

`../mockups/README.md` lists the eleven screens (thirteen PNGs with the dark variants) and how to render them with
headless Chrome (`sh docs/mockups/render.sh`). They use the system fonts (SF Pro and SF Pro Rounded), so they render
correctly only on a Mac. Thumbnails in the mockups are drawn stand-ins for Quick Look thumbnails.
