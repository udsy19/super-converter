# Changelog

All notable changes to Super Converter are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org).
Each release's section becomes its GitHub release notes (`scripts/release.sh`), which end with the SHA-256 line the
updater checks.

## [Unreleased]

## [1.0.0] — 2026-10-30

The first release.

### Added
- Drop files on the window, the Dock icon or the menu-bar icon, or right-click them in Finder: each becomes a card that
  already knows what it will most likely become (HEIC → JPG, MOV → MP4, DOCX → PDF, PDF → Word), and **Convert** writes
  the new files next to the originals. Originals are never moved, renamed or deleted; taken names get " 2".
- 212 formats in 11 kinds — photos and camera RAW, video, audio, documents, spreadsheets, slides, e-books, archives,
  vector art, CAD drawings and fonts — and 2,252 conversions between them: 2,140 of the 2,156 pairs in CloudConvert's
  public format list and 112 more, converted on the Mac.
- The format picker: search by extension, name or plain words ("word", "kindle", "transparent"), "Best for …" picks,
  every target grouped by kind, and "Use JPG for HEIC files from now on".
- Options in plain words with a live size estimate, the rest under More options; "Use these settings for every …"
  saves them per format. Documents to PDF in three looks: Original (through LibreOffice, Word or Pages), As written,
  and LaTeX (Latin Modern, Knuth–Plass line breaking, TeX math, booktabs tables, tagged PDF and bookmarks).
- Conversions run several at once by kind, with progress in the colours of each conversion, Stop (⌘.) that leaves no
  partial files, Dock progress and a notification when a background batch is done. Results come with Quick Look,
  Share, Show in Finder, loss notes, and a one-line reason and fix for anything that didn't convert.
- A menu-bar drop target and panel with the last 10 conversions.
- Six Finder Quick Actions — Convert with Super Converter…, Convert to JPG, PNG, PDF, MP4 and MP3 — and the same in the
  Services menu; Open With › Super Converter for every format it reads, without becoming any file's default app.
- Free helpers (LibreOffice, calibre, Pandoc, Tectonic) install in one click when a conversion needs them, pinned and
  verified; Pages, Numbers, Keynote, Microsoft Office and Homebrew tools (Ghostscript, DjVuLibre, LibreDWG) are found
  where they are. FFmpeg (an LGPL build), 7-Zip and LibRaw come inside the app. Helpers run sandboxed, without network.
- Settings: General, Formats (default targets and saved options), Helpers, Quick Actions and About.
- `superconverter://open` and `superconverter://convert` links, and the `sconv` command line (built from source) with
  `--list-targets` and `--list-options`.
- Archive extraction with zip-slip, link and decompression-bomb protection.
- Updates from GitHub Releases, checked against the release's SHA-256 and the running copy's signature; can be turned
  off in Settings › About.
- Light and dark mode, Increase Contrast, Reduce Motion and VoiceOver labels.
- One-line installer and a universal DMG for macOS 14 and later, Apple silicon and Intel.
- Nothing leaves the Mac except what [PRIVACY.md](PRIVACY.md) lists.

