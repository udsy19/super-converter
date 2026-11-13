# Known blockers and owner decisions

## Credential / tooling blockers (cannot be done in this session)

1. **No signing identities or provisioning profile** on this Mac. Needed: Apple Distribution (or 3rd Party Mac
   Developer Application), Mac Installer Distribution (3rd Party Mac Developer Installer), a Mac App Store profile for
   `com.udsy.superconverter.appstore`, and **one profile per Quick Action extension**
   (`com.udsy.superconverter.appstore.quickactions.{ConvertWithSuperConverter,ConvertToJPG,ConvertToPNG,ConvertToPDF,ConvertToMP3,ConvertToMP4}`)
   — `scripts/package-appstore.sh` currently embeds only the app's profile; extension profiles must be added to each
   `.appex/Contents/embedded.provisionprofile` before upload. Register all seven ids in App Store Connect.
2. **No Xcode** → no `actool`, so **no asset catalog (`Assets.car`)**. App Store Connect has required the app icon in
   an asset catalog for macOS uploads; the bundle has only `AppIcon.icns` (512 and 512@2x present via iconutil).
   Expect an upload validation error until the icon is compiled with Xcode's actool.
3. **No `altool`/Transporter validation run**; upload untested. Universal (arm64 + x86_64) Store build not produced in
   this session (`UNIVERSAL=1` is the package script's default; tested build was arm64-only).

## Material product changes needing owner approval (Store edition only; direct edition unchanged)

4. **All outside helpers are gone**: LibreOffice, calibre, Pandoc, Tectonic, Ghostscript, DjVuLibre, ODA, LibreDWG, GPL
   FFmpeg, RAR writing, sfArk, iWork and Microsoft Office automation. 460 of 2252 conversion pairs and **40 of 212 input
   formats** (incl. PPT, PPS, POT, Keynote/Pages/Numbers, MOBI/AZW/AZW3, EPS/PS, DWG, DjVu, TeX, RST, Visio, Publisher,
   CorelDRAW, WordPerfect) have no conversion in the Store edition. Settings › Helpers says so in neutral words, with no
   link to the direct download (removed after review).
5. **Quick Action switches** move to System Settings (pkd refuses sandboxed clients).
6. **Quick Actions / Services in a folder the app was never granted** show one open panel ("Allow") at the files' own
   folder before converting — only for links from the app's own extensions/Services, one at a time, ≥ 5 s apart
   (self-test `MenuBarKit.accessRequests`). The panel itself is **not run** (needs Finder + a person).
7. **Results "next to the original"** only when the folder was granted; otherwise Downloads (existing fall-back).
8. **Disk images** are read by 7-Zip instead of hdiutil (tested: tree.dmg → zip PASS; APFS/encrypted DMG coverage of
   7-Zip is narrower than hdiutil's — encrypted DMGs untested).

## Licence / compliance decisions

9. **FFmpeg rebuilt LGPL-2.1-or-later** (no `--enable-version3`; see test-results.md §8). It is statically linked
   inside its own executable, not a shared-library build as ADDENDUM 8 words it. The new binaries are local
   (`Vendor/Tools`); `Tools.lock` still pins the published LGPL-3.0 `tools-2026-10-29` assets until the owner publishes
   a new `tools-*` release with `scripts/tools.sh release` (credential: GitHub release rights). Until then a fresh
   checkout's `scripts/tools.sh fetch` gets the v3 build.
10. **unRAR restriction** (7-Zip): fine while the app is free; revisit if priced.
11. **Export compliance (ADDENDUM 7)**: the app *implements* encryption beyond the OS: AES-256 7Z/ZIP creation and
    decryption through the bundled 7-Zip, ZipCrypto/AES via libarchive, password-protected PDFs via PDFKit. Do **not**
    set `ITSAppUsesNonExemptEncryption = NO` blindly. Likely answer: uses encryption, qualifies for the mass-market /
    ECCN 5D992.c exemption (file encryption for the user's own data, publicly available algorithms); owner must confirm
    and may need the annual self-classification report. The key is intentionally not set in Info.plist.

## Known issues found during testing

12. (Fixed) A file the sandbox doesn't let the app read now fails with "Super Converter can't open “…”. Add it again
    from Finder or with Add Files…" instead of a "permission to save" message.
13. `FolderAccess` bookmarks and the "Allow" panel need a GUI run with a real open panel (not automatable here).
