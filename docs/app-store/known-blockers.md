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
   CorelDRAW, WordPerfect) have no conversion in the Store edition. Settings › Helpers explains and links to the direct
   download. App Review may object to a link to an outside download of the same app (guideline 3.1.1 is about payment,
   but some reviewers flag "go elsewhere for features"); owner may prefer plain text without the link.
5. **Quick Action switches** move to System Settings (pkd refuses sandboxed clients).
6. **Quick Actions / Services in a folder the app was never granted** show one open panel ("Allow") before converting.
   Implemented, **not run** (needs Finder + a person; script in README "Human runs").
7. **Results "next to the original"** only when the folder was granted; otherwise Downloads (existing fall-back).
8. **Disk images** are read by 7-Zip instead of hdiutil (tested: tree.dmg → zip PASS; APFS/encrypted DMG coverage of
   7-Zip is narrower than hdiutil's — encrypted DMGs untested).

## Licence / compliance decisions

9. **FFmpeg is LGPL-3.0-or-later** (`--enable-version3`), statically linked inside its own executable (not a shared
   library build as ADDENDUM 8 words it). Recommend rebuilding without `--enable-version3` (LGPL-2.1+, nothing needs v3)
   before submission, or getting a legal opinion. See dependency-and-license-audit.md.
10. **unRAR restriction** (7-Zip): fine while the app is free; revisit if priced.
11. **Export compliance (ADDENDUM 7)**: the app *implements* encryption beyond the OS: AES-256 7Z/ZIP creation and
    decryption through the bundled 7-Zip, ZipCrypto/AES via libarchive, password-protected PDFs via PDFKit. Do **not**
    set `ITSAppUsesNonExemptEncryption = NO` blindly. Likely answer: uses encryption, qualifies for the mass-market /
    ECCN 5D992.c exemption (file encryption for the user's own data, publicly available algorithms); owner must confirm
    and may need the annual self-classification report. The key is intentionally not set in Info.plist.

## Known issues found during testing

12. A read denied by the sandbox (file never granted) is reported as "You don't have permission to save the file … in
    the folder …" (error mapping in OutputRules/JobRunner treats any EPERM as a write problem). Cosmetic; only reachable
    when a link hands over an ungranted path and the person cancels the access panel.
13. `FolderAccess` bookmarks and the "Allow" panel need a GUI run with a real open panel (not automatable here).
