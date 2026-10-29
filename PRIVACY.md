# Privacy

Super Converter converts everything on your Mac. Your files are never uploaded, there is no account, and there are no
analytics, no crash reports sent anywhere and no remote switches. The app is open source, so all of this can be checked
in the code.

## The only network traffic

Super Converter connects to the internet in exactly these cases (ux §6.6), and nothing else in the app makes a request.

| When | What is sent | Where | How to turn it off |
|---|---|---|---|
| **The update check** — a minute after launch, then every few hours, and when you choose Check for Updates… | A request for the latest release (no identifier, no file names; the user agent carries the app's version); if there is a newer version, the download of its disk image | `api.github.com` (this repository's Releases) and GitHub's download servers | Settings › General › Check for updates. Check for Updates… still checks when you ask. |
| **A helper you install** — only when you click Install in Settings › Helpers or on a card | The download of that helper's pinned release, checked against its SHA-256 and code signature before it is used | LibreOffice: `download.documentfoundation.org`; calibre, Pandoc and Tectonic: their GitHub releases | Don't click Install. Remove takes a helper away again. |
| **Tectonic's first run** — once, right after you install Tectonic | Tectonic fetches the TeX packages its warm-up document needs into the app's cache; every later run is offline (`--only-cached`) | Tectonic's package server | Don't install Tectonic. |
| **Web resources of one HTML file** — only when you turn on "Load web resources" in that file's options | The requests that page itself makes for its pictures, fonts and styles | Wherever that page points | It's off unless you turn it on, for that file only. |

"Get…" buttons (for helpers that can't be installed in one click), the Help menu and the source-code link open a web
page in your browser; the app itself sends nothing.

Helpers never get the network: command-line helpers (Pandoc, Tectonic, Ghostscript, …) and the bundled FFmpeg and 7-Zip
run with a scrubbed environment in a sandbox that denies network access, and only for a conversion you started.

## What stays on your Mac

- Your converted files, next to the originals (or where Settings › General says), never replacing them.
- `~/Library/Application Support/Super Converter/`: installed command-line helpers and their record, the work folders of
  running conversions (removed when a job ends and swept at launch), the menu bar's list of the last 10 conversions,
  the updater's bookkeeping, LibreOffice's private profile and Tectonic's package cache.
- `~/Library/Caches/Super Converter/thumbnails/`: Quick Look thumbnails of the files you added.
- Your settings (formats you chose, saved options, window size) in the app's preferences.

Deleting those folders and the app removes everything Super Converter keeps.

## Permissions macOS may ask for

- **Automation** of Pages, Numbers, Keynote, Word, Excel or PowerPoint: only when a conversion uses that app to export
  a file you dropped.
- **Desktop, Documents, Downloads, removable and network drives**: to read the files you convert from there and save
  the results next to them.
- **Notifications**: to say when a conversion started from Finder, the menu bar or a link has finished.
