# Privacy and permissions — Store edition

**Data collected: none.** No accounts, analytics, crash upload, or network traffic of its own. The Store edition has
`network.client` only because WebKit needs it to render a local HTML file in the sandbox; a content-rule list blocks
every non-local load unless the person turns on "Load web resources" for one HTML file (then that page's own pictures
and styles load). No updater, no helper downloads; FFmpeg is built `--disable-network`. App Store privacy label:
"Data Not Collected".

No privacy manifest is needed on macOS for required-reason APIs; nothing is collected, so none is added.

## What the person grants, and how

| Access | Mechanism | Persisted |
|---|---|---|
| Files dropped on the window / menu-bar icon / Dock icon, opened with Open With | sandbox extension per file from the drop or Launch Services | for the session |
| Files and folders from Add Files… (⌘O) | open panel (powerbox) | folders: security-scoped bookmark (`FolderAccess`) |
| Save To folder (Settings › General, the window's action bar, the menu-bar panel) | open panel | security-scoped bookmark, restored at launch |
| Files from a Quick Action or Service | the app checks it can read them; if not, an open panel at their folder asks ("Allow") | folder bookmark |
| Downloads | `files.downloads.read-write` (fall-back place for results) | entitlement |
| Direct edition's settings | open panel at its preferences file, user confirms | copied once |

No TCC prompts are used by the Store edition (no Apple Events, camera, microphone, screen recording, accessibility).
Notifications ("conversion finished") use UserNotifications and ask the standard permission.

TCC grants (e.g. automation of Pages in the direct edition) do not carry over between editions; the Store edition does
not need any.
