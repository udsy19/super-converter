# Security Policy

## Supported versions

| Version | Security fixes |
|---|---|
| 1.0.x (the latest release) | Yes |
| Anything older, and builds from source of older commits | No: update |

Only the latest release receives security fixes. Running copies update themselves from GitHub Releases (see Updates
below), and the one-line installer always installs the latest release.

## Reporting a vulnerability

Please **do not** open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/udsy19/super-converter/security/advisories/new) for this
repository. Include the version, your macOS version, and a file or link that reproduces the problem if there is one
(attach it to the advisory, not to a public issue). You'll get a response within a few days, a fix is released as
soon as practical, and you'll be credited in the advisory if you want to be.

## What Super Converter is

A file converter that runs entirely on your Mac: no accounts, no analytics, no servers operated by the project. Its
job is to open files that came from anywhere (mail attachments, downloads, archives from strangers) and write new ones,
so the design treats every input file as hostile, keeps helpers on a short leash, and keeps the network out of
conversions.

## In scope

- **Document and media parsers** in the app's own process: the readers in ImageKit, VectorKit, XPSKit, CADKit, DocKit,
  OfficeKit, EbookKit, ArchiveKit, MediaKit and FontKit (DOCX, ODT, RTF, HTML, Markdown, EML, HWP, XLS, PPTX, EPUB,
  FB2, CHM, SVG, EMF/WMF, PDF, XPS, DXF, DWF, PSD/PSB, XCF, SFNT/CFF/WOFF/WOFF2/EOT, SoundFont and the archive
  formats). A crash, hang, unbounded allocation, or a read or write outside what the file should reach is a bug.
- **Archive extraction**: anything that writes outside the job's work folder, follows a link out of it, or gets past
  the decompression-bomb checks.
- **The sandboxed helpers**: the bundled FFmpeg, ffprobe and 7-Zip, and installed helpers (LibreOffice, calibre,
  Pandoc, Tectonic, Ghostscript, …) reaching the network or writing outside their work folder while converting, or a
  file escaping the sandbox through them.
- **`superconverter://` links**: a link from a web page, mail or another app that converts, writes or reads anything
  without the person pressing Convert.
- **The Quick Action extensions and Services**: handing the app files the person didn't select.
- **Helper installs and updates**: anything that gets a download that doesn't match its pin, signature or the running
  copy's identity installed or run.
- **The HTML reader**: anything that makes Super Converter fetch a resource while "Load web resources" is off.

Out of scope: what a helper you installed does outside a conversion (it's that project's software); the behaviour of
Apple's frameworks themselves (report those to Apple, though we're glad to hear about them); denial of service by
converting a file that is simply very large.

## Security design

### Files you convert

- Every reader runs on bytes it doesn't trust. The self-tests' `<Kit>.damagedInputNeverCrashes` cases feed every
  in-process reader hundreds of seeded, damaged copies of its own fixtures and require a clean error or a best-effort
  result, never a trap, a hang or an unbounded allocation.
- Files are recognised by content (magic bytes) before their extension, so a renamed file is read by the reader for
  what it really is.
- Outputs are written into a per-job work folder under `~/Library/Application Support/Super Converter/Jobs/` and moved
  into place only when complete; a stopped or failed job's partial files are deleted. Originals are never modified.
  Even "Replace" never replaces the source.
- The HTML reader is Super Converter's own tolerant parser: no web process, nothing fetched. A page's pictures, fonts
  and styles load only when the person turns on "Load web resources" for that one file.

### Archive extraction

All archive readers write through one `SafeExtractor`:

- **Zip-slip**: entry names are normalised; names with `..` components, NUL bytes or drive letters are refused, and
  absolute names are made relative.
- **Links**: a symbolic link is kept only if its target is relative and never climbs above the archive's root. A hard
  link becomes a copy of a file already extracted from the same archive, or nothing. Devices, sockets and FIFOs are
  never created; what a tool such as 7-Zip or `hdiutil` extracted is checked by the same rules afterwards.
- **Permissions**: only the `rwx` bits are kept (no setuid, setgid or sticky bits), and files stay readable by their
  owner.
- **Bombs**: an archive that expands more than 1,000 times its size and past 10 GB stops and asks first (from the
  command line, `--option extractAnyway=yes`). Hard limits stop it either way: 64 GB written, a million entries,
  archives nested three deep, and a free-space check with a reserve.

### Helpers and bundled tools

- Every helper process starts through HelperKit's runner, nowhere else: with a scrubbed environment (system `PATH`, a
  private `HOME` and `TMPDIR` inside the job's work folder; nothing of the person's environment, tokens, proxies or
  `DYLD_*` variables), `nice`, standard input closed unless a password is passed, a per-file time limit
  (LibreOffice 120 s, calibre 300 s, Ghostscript 120 s, Tectonic 300 s), and a stop that ends the exact process and
  its descendants by id, never by name.
- Each runs inside a `sandbox-exec` profile that denies IP networking and DNS lookups, denies writing anywhere but its
  work folder (and its private home), and, for command-line tools, denies LaunchServices so nothing it runs can open a
  URL or an app outside the sandbox. The runner checks at launch that the sandbox actually enforces this on the
  running macOS.
- The one exception to "no network" is Tectonic's warm-up right after it is installed, which fetches its TeX
  packages; every conversion afterwards runs it `--only-cached`.
- Automation of Pages, Numbers, Keynote and Microsoft Office goes through Apple Events (`osascript`), which macOS gates
  behind the Automation permission the person grants per app.
- The bundled `ffmpeg`, `ffprobe` and `7zz` are signed with the app's identity, live in `Contents/Helpers/` and run
  through the same runner.
- **Installs**: one-click helpers are upstream's own releases, pinned to a version and SHA-256 in the app. Apps must
  also pass a strict Developer ID check against the publisher's team and Apple's notarisation assessment before they
  are moved into `~/Applications`. Helpers never run except for a conversion the person started. GPL and AGPL tools
  without official macOS builds are not distributed by the project; they're found where Homebrew installs them.

### `superconverter://` links, Quick Actions and Services

- A link can only name files and a target format (`open` and `convert`). It can't choose where results go, pass
  options, or reach anything but the window.
- The app reads the sender of the Apple Event that carried the link (its audit token, else its process id) and asks
  Security for that running code: only a validly signed process whose executable is inside the app's own
  `Contents/PlugIns` (its Quick Action extensions) converts in the background. Services entries, which run in the app
  itself, count as the app's. A link from anywhere else only adds existing files (never folders) to the window and
  waits for the person to press Convert.
- The Quick Action extensions are sandboxed, hand only the files the person selected in Finder to the app, and appear
  only for the types they can take.

### Network

- The app makes no requests except those PRIVACY.md lists: the update check, helper downloads the person starts,
  Tectonic's one-time warm-up, and one HTML file's own resources when the person allows it. No analytics, no crash
  upload, no remote flags.
- Engines have no network code; HelperKit's installer and UpdateKit are the only places that use `URLSession`.

### Updates (on by default)

- A request to the GitHub API for this repository's latest release a minute after launch and then every six hours.
  A newer DMG is installed only if its SHA-256 matches the one in the release notes, the app inside passes a strict
  code-signature check and satisfies the running copy's designated requirement (the same signing identity), and its
  bundle id and version are what the release advertises. The verified copy is swapped in when the app quits or is
  idle; anything that fails is logged and retried later.
- Releases are Developer ID signed and notarised when the maintainer's Apple credentials are set for
  `scripts/release.sh`; otherwise they're signed with the project's own identity. The one-line installer, like any
  `curl | bash`, trusts GitHub Pages and GitHub Releases over HTTPS; read `scripts/install.sh` first if that matters to
  you.

### The app itself

- Hardened Runtime. Not sandboxed, because helpers, app automation and `hdiutil` need it; the helpers are sandboxed
  instead. Entitlements: Apple Events (automating Pages, Numbers, Keynote and Office) and
  `disable-library-validation`, so the hardened runtime loads the bundled LibRaw dylib (`Contents/Frameworks`, signed
  without an Apple Team ID); nothing else.
- No GPL or AGPL code is linked or loaded; the build's licence check fails on a vendored artifact outside the
  allow-list.

## Areas where a report is especially valuable

The archive extractor and the archive readers (ZIP, 7Z, RAR via 7-Zip, TAR, CAB, ACE, ARC, LZO, DMG, ISO), the
document parsers that run in the app (DOCX, ODT, RTF, HTML, EML, HWP, XLS, PPTX, EPUB, SVG, EMF/WMF, DXF, PSD, fonts),
the helper sandbox profile and the process runner, the link sender check, and helper install and update verification.
