# Hyphenation patterns

TypesetKit hyphenates with TeX's own Liang patterns where a permissively licensed set exists, so line breaks match
`pdflatex` (quality §3.3, §3.7 LaTeX parity); other languages use Apple's hyphenation dictionaries. The files are
copied unmodified from hyph-utf8 (each keeps its copyright and licence header, as its licence requires). The app
copies this folder to `Contents/Resources/Hyphenation`; `Hyphenator` finds it there, or here when running from a
SwiftPM build.

Source: https://github.com/hyphenation/tex-hyphen, commit `5684c0f51c0b81133db2efbe60a408b4155a3ff5` (2026-02-24),
`hyph-utf8/tex/generic/hyph-utf8/patterns/tex/`.

| File | Language | Licence |
|---|---|---|
| `hyph-en-us.tex` | English (US; Liang's `hyphen.tex`, what plain TeX and LaTeX load) | permissive notice ("Copying and distribution of this file, with or without modification, are permitted…") |
| `hyph-en-gb.tex` | English (UK) | MIT |
| `hyph-de-1996.tex` | German (reformed spelling) | MIT |
| `hyph-es.tex` | Spanish | MIT |
| `hyph-fr.tex` | French | MIT |
| `hyph-nl.tex` | Dutch | MIT |
| `hyph-pl.tex` | Polish | MIT (chosen of its dual licence) |
| `hyph-pt.tex` | Portuguese | BSD 3-clause |
| `hyph-uk.tex` | Ukrainian | MIT (chosen of its licence options) |
| `hyph-da.tex` | Danish | MIT (chosen of LPPL/MIT) |
| `hyph-el-monoton.tex` | Greek (monotonic) | MIT (chosen of LPPL/MIT) |

Left out because they are LPPL- or GPL-only, or have no clear licence: Catalan, Czech, Finnish, Hungarian, Italian,
Norwegian, Russian, Swedish, Turkish and others; those languages hyphenate with Apple's dictionaries.

## SHA-256

```
23e0a50f0c20d632be06f973e700323463961eac737bb14f6c3787675a4f5575  hyph-da.tex
374ad1ce3263f8a2791ec070ef9b516c532dae64456f3fb656e617e8ae53a9d3  hyph-de-1996.tex
a3aa9ecba9c00dd958a2b1d1d3b3aa851701f6d0027ef9cc9d7365e432c5acb0  hyph-el-monoton.tex
e95bb4ab350f620c41c231c4785d7bdb4f91949d3e631b30e08b3ead3c340a52  hyph-en-gb.tex
f4ffcd96c5cbc886bdad23f95dcae8edc3cd3620eae62f7946eceda97c4e68f8  hyph-en-us.tex
6a2e5f39a991a23d1cd8a23dbd0f6fe96a9f07561a6695f4f3320f47030e236c  hyph-es.tex
526cad6fe8f52fcd3caa3fcaf667cb1740cfc14bca198680e00dc343a84594de  hyph-fr.tex
d21499bfbee53e4d50e867ef92a41fd28b65725d7c91c980e4f8f02889bf6b2a  hyph-nl.tex
83ddbbd21bc06a44bc4f4a4c49c38782e809cff5f026b764c044daa29e818843  hyph-pl.tex
c110a39e501db372d1d755e1c64464321a2efa7d8e9617f66001000389b941f2  hyph-pt.tex
9f57d9593f4b8a93e033f7f9649aaf3abb49d17117cbd987692b626e13374c55  hyph-uk.tex
```
