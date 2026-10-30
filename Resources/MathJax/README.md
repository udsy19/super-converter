# MathJax for MathKit

MathKit sets TeX math with MathJax (TeX input, SVG output, lite DOM adaptor) evaluated in JavaScriptCore (quality §3.4).
`mathjax-tex-svg.js` is one self-contained script built from the pinned npm release; `entry.js` is MathKit's entry
point, which also flattens MathJax's SVG into absolute path segments so the Swift side needs no SVG parser, and gives
MathJax TeX's metrics (quality §3.7): script sizes, Computer Modern's widths and italic corrections at 10, 7 and 5 pt
from `tex-metrics.js`, fraction and null-delimiter spacing, TeX's struts and interline glue in arrays and alignments,
`\text` as text, and the outer list's glue for the paragraph builder. `tex-metrics.js` is made by
`python3 -I scripts/make-tex-metrics.py` (Tectonic measures the TFM files). The app copies this folder to
`Contents/Resources/MathJax`; `MathJax.bundled()` finds it there, or here when running from a SwiftPM build.

| Package | Version | Licence | Source |
|---|---|---|---|
| `mathjax-full` | 3.2.2 (npm tarball SHA-256 `d8f080d2e4bdfb75284aac34d5eff155002eca47798b1d4e4bde31453e653f87`) | Apache-2.0, `LICENSE` | https://github.com/mathjax/MathJax-src/releases/tag/3.2.2 |
| `mhchemparser` (MathJax's dependency, for `\ce`) | 4.2.1 | Apache-2.0 (notice kept in the bundle) | https://github.com/mhchem/mhchemParser |

Rebuild in a folder holding copies of `entry.js` and `tex-metrics.js` (Node and npm on the dev machine; nothing is
downloaded at run time):

```
npm install --ignore-scripts mathjax-full@3.2.2 esbuild@0.24.2
npx esbuild entry.js --bundle --minify --format=iife --target=es2020 --legal-comments=eof --outfile=mathjax-tex-svg.js
```

## SHA-256

```
9fbfc860c4cc1d4bce611b3996d314e561e978ccc49499db2d54824643a439b9  mathjax-tex-svg.js
```
