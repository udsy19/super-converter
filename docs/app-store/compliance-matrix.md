# Compliance matrix — Super Converter, Mac App Store edition

| Feature | Classification | Store status | Evidence |
|---|---|---|---|
| Built-in conversions (images, vector, CAD, documents, spreadsheets, e-books, fonts) | compatible | on | test-results §4: 42/42 non-gated cases PASS sandboxed |
| Media via bundled FFmpeg (LGPL, Contents/Helpers, sandbox+inherit) | compatible-with-config | on | §4: 11/11 PASS; licence decision pending (known-blockers 9) |
| Media via AVFoundation | compatible | on | §4: 4/4 |
| Archives via libarchive / own decoders / bundled 7-Zip | compatible-with-config | on | §4: 22/22 incl. RAR read, AES 7Z write |
| Disk images (DMG) | compatible-after-architecture-change | on (7-Zip instead of hdiutil) | §2 hdiutil denied; §4 tree.dmg → zip PASS |
| Unsafe archive protections (traversal, symlink escape, bomb) | compatible | on | §4 "Unsafe archive extraction" |
| HTML → PDF/PNG (WebKit) | compatible-with-config | on (needs network.client) | §4: FAIL without, PASS with |
| Input staging for bundled tools | compatible-after-architecture-change | on | §3 experiment + Downloads cases |
| Outside helpers (LibreOffice, calibre, Pandoc, Tectonic, Ghostscript, DjVuLibre, ODA, LibreDWG, GPL FFmpeg, RAR write, sfArk) | incompatible-confirmed | gated, explained in Settings › Helpers | §4 "Needs Tectonic/Pandoc/calibre"; §5 460 pairs gated |
| One-click helper installer (runtime download of executables) | incompatible-confirmed | compiled out | HelperPins empty, HelperInstaller stub; binary check §1 |
| iWork / Office via Apple Events | incompatible-confirmed | gated, no entitlement | §5 "needs Pages / Numbers / Keynote" |
| Self-updater (UpdateKit) | incompatible-confirmed | compiled out | §1 `strings` check |
| Per-tool `sandbox-exec` profile | incompatible-confirmed | replaced by App Sandbox inheritance | §2 forbidden-sandbox-reinit |
| Quick Action extensions | unverified-needs-experiment | on; app asks folder access when needed | builds and signs sandboxed; Finder run not done |
| Quick Action on/off switches in Settings (pluginkit) | incompatible-confirmed | moved to System Settings | §2 pkd "unauthorized discovery flag" |
| Services menu entries | unverified-needs-experiment | on | not run (needs Finder) |
| Drag & drop / Open With / Add Files | unverified-needs-experiment | on | standard powerbox grants; GUI not driven |
| Save next to original / Downloads fall-back | compatible-with-config | on | §2 access(W_OK) sandbox-aware; §3 Downloads writes |
| Save To folder bookmarks (FolderAccess) | unverified-needs-experiment | on | needs real open panel |
| Batch / background conversion (menu bar) | compatible | on | same queue as sconv (§4 ran 87 jobs) |
| Import settings from direct edition | compatible | on (app menu) | §6 Core.directEditionImport |
| App launch sandboxed | compatible | — | §1 runs, 1 benign denial |
