# Models and assets — Store edition

Nothing is downloaded after install. Every asset ships inside the signed bundle:

- `Contents/Helpers/{ffmpeg,ffprobe,7zz}` — LGPL executables (build-time pinned in `Tools.lock`).
- `Contents/Frameworks/libraw_r.dylib` — LibRaw.
- `Contents/Resources/{Fonts,Hyphenation,MathJax}` — TypesetKit fonts, hyphenation patterns, MathJax (run in JavaScriptCore, no JIT entitlement).
- Text recognition (PDF → editable formats) uses Apple's Vision framework; no model files of our own.

The direct edition's post-install downloads (one-click helpers: LibreOffice, calibre, Pandoc, Tectonic; Tectonic's
package cache) are executable code and are compiled out of the Store edition (App Review 2.5.2 / 2.4.5(iv)).
