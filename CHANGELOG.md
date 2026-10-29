# Changelog

All notable changes to Super Converter. Each release's section becomes its GitHub release notes (`scripts/release.sh`),
which end with the SHA-256 line the updater checks.

## [Unreleased]

The first version, built to the specification in `docs/`.

- Drop files on the window, the Dock icon or the menu-bar icon, or right-click them in Finder: each becomes a card that
  already knows what it will most likely become; **Convert** writes the new files next to the originals.
- 212 formats in 11 kinds — photos and camera RAW, video, audio, documents, spreadsheets, slides, e-books, archives,
  vector art, CAD drawings and fonts — with 2,141 of CloudConvert's 2,156 pairs and 112 more, converted on the Mac.
- Finder Quick Actions: Convert with Super Converter…, Convert to JPG, PNG, PDF, MP4 and MP3, and the same in the
  Services menu; `superconverter://convert?file=…&to=jpg` links for scripts; `sconv` on the command line.
- Open With › Super Converter for every format it reads, without becoming any file's default app.
- Free helpers (LibreOffice, calibre, Pandoc, Tectonic) install in one click when a conversion needs them; FFmpeg (LGPL
  build), 7-Zip and LibRaw come inside the app.
- Updates from GitHub Releases, checked against the release's SHA-256 and the app's own signature; can be turned off.
- Nothing leaves the Mac except what [PRIVACY.md](PRIVACY.md) lists.
