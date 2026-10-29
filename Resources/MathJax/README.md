# MathJax for MathKit

MathKit sets TeX math with MathJax (TeX input, SVG output, lite DOM adaptor) evaluated in JavaScriptCore (quality §3.4).
`mathjax-tex-svg.js` is one self-contained script built from the pinned npm release; `entry.js` is MathKit's entry
point, which also flattens MathJax's SVG into absolute path segments so the Swift side needs no SVG parser. The app
copies this folder to `Contents/Resources/MathJax`; `MathJax.bundled()` finds it there, or here when running from a
SwiftPM build.

| Package | Version | Licence | Source |
|---|---|---|---|
| `mathjax-full` | 3.2.2 (npm tarball SHA-256 `d8f080d2e4bdfb75284aac34d5eff155002eca47798b1d4e4bde31453e653f87`) | Apache-2.0, `LICENSE` | https://github.com/mathjax/MathJax-src/releases/tag/3.2.2 |
| `mhchemparser` (MathJax's dependency, for `\ce`) | 4.2.1 | Apache-2.0 (notice kept in the bundle) | https://github.com/mhchem/mhchemParser |

Rebuild (Node and npm on the dev machine; nothing is downloaded at run time):

```
npm install --ignore-scripts mathjax-full@3.2.2 esbuild@0.24.2
npx esbuild entry.js --bundle --minify --format=iife --target=es2020 --legal-comments=eof --outfile=mathjax-tex-svg.js
```

## SHA-256

```
97995a3d2addf5fd3280a1e25fa7017874b56cec394c2f21279a2029f999b875  mathjax-tex-svg.js
```
