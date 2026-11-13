# Notes for App Review (draft)

Super Converter converts files between 200+ formats entirely on the Mac. No account, no data collection. The network entitlement exists only because WebKit needs it to render local HTML in the sandbox; pages load nothing remote unless the person turns on "Load web resources" for that file.

**How to test**
1. Drag any image, PDF, Word/Excel/PowerPoint (.docx/.xlsx/.pptx), e-book, audio, video or archive file onto the window
   (or File › Add Files…). Pick a target format on the card and click Convert.
2. Results are saved next to the original when that folder was chosen in the open panel; otherwise in Downloads. Choose
   a different place with "Save to" in the window's bottom bar (an open panel; the app remembers that folder).
3. Finder Quick Actions: right-click a file › Quick Actions › "Convert to JPG" (etc.). The first time for a folder the app
   asks permission to open files there (an open panel pointed at that folder; click Allow).

**Bundled tools.** The app contains FFmpeg/FFprobe (LGPL build, no GPL code, no network) and 7-Zip in
`Contents/Helpers`. They are launched with `Process`, are signed with `app-sandbox` + `inherit`, and only read copies
of the person's files staged in the app container. Nothing is downloaded or installed after install.

**Not in this edition.** Conversions that need other programs (LibreOffice, calibre, Pandoc, Pages/Numbers/Keynote via
automation, etc.) are not offered; Settings › Helpers says so and links to the developer's website.

**Encryption.** The app can create password-protected ZIP/7Z archives (AES-256 via the bundled 7-Zip) and
password-protected PDFs (Apple PDFKit), and opens encrypted archives/PDFs the person supplies the password for.
See known-blockers.md for the export-compliance answer the owner must confirm.
