#!/usr/bin/env python3
"""Write Resources/MathJax/tex-metrics.js: Computer Modern's metrics at 10, 7 and 5 pt, read from TeX's own TFM files.

MathJax's TeX fonts are cmr10/cmmi10/cmsy10 scaled for every size and carry few italic corrections, so its formulas
come out narrower than TeX's: scripts are set in cmr7/cmmi7/cmsy7 and cmr5/… whose designs are wider, and TeX adds each
letter's italic correction (β, f, y). MathKit's entry.js gives MathJax these widths, heights, depths and italic
corrections instead (quality §3.4, §3.7). Tectonic (a developer tool, quality §9) measures every character with
e-TeX's \\fontcharwd/ht/dp/ic and \\fontdimen2 (the interword space); nothing here runs at build or run time.

Usage:  python3 -I scripts/make-tex-metrics.py      (from the repository root; Tectonic on PATH)
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources/MathJax/tex-metrics.js")
SIZES = (10, 7, 5)

# MathJax variant → {Unicode code point: (TeX font family, slot)}. "space" is the font's interword space (\fontdimen2),
# which TeX puts between the words of \text{…}.
GREEK_CAPS = [0x393, 0x394, 0x398, 0x39B, 0x39E, 0x3A0, 0x3A3, 0x3A5, 0x3A6, 0x3A8, 0x3A9]   # slots 0–10
GREEK_LOWER = {   # cmmi (OML) slots 11–39
    0x3B1: 11, 0x3B2: 12, 0x3B3: 13, 0x3B4: 14, 0x3F5: 15, 0x3B6: 16, 0x3B7: 17, 0x3B8: 18, 0x3B9: 19, 0x3BA: 20,
    0x3BB: 21, 0x3BC: 22, 0x3BD: 23, 0x3BE: 24, 0x3C0: 25, 0x3C1: 26, 0x3C3: 27, 0x3C4: 28, 0x3C5: 29, 0x3D5: 30,
    0x3C7: 31, 0x3C8: 32, 0x3C9: 33, 0x3B5: 34, 0x3D1: 35, 0x3D6: 36, 0x3F1: 37, 0x3C2: 38, 0x3C6: 39,
}
CMR = {   # cmr (OT1)
    **{c: s for s, c in enumerate(GREEK_CAPS)},
    0x21: 33, 0x23: 35, 0x24: 36, 0x25: 37, 0x26: 38, 0x27: 39, 0x28: 40, 0x29: 41, 0x2B: 43, 0x2C: 44, 0x2D: 45,
    0x2E: 46, 0x2F: 47, **{0x30 + i: 48 + i for i in range(10)}, 0x3A: 58, 0x3B: 59, 0x3D: 61, 0x3F: 63, 0x40: 64,
    **{0x41 + i: 65 + i for i in range(26)}, 0x5B: 91, 0x5D: 93, **{0x61 + i: 97 + i for i in range(26)},
    0x131: 16, 0x237: 17, 0xDF: 25, 0xE6: 26, 0x153: 27, 0xF8: 28, 0xC6: 29, 0x152: 30, 0xD8: 31,
    0x2018: 96, 0x2019: 39, 0x201C: 92, 0x201D: 34, 0x2013: 123, 0x2014: 124, 0x20: "space", 0xA0: "space",
}
CMSY = {  # cmsy (OMS)
    0x2212: 0, 0x22C5: 1, 0xB7: 1, 0xD7: 2, 0x2A: 3, 0x2217: 3, 0xF7: 4, 0x22C4: 5, 0xB1: 6, 0x2213: 7, 0x2295: 8,
    0x2296: 9, 0x2297: 10, 0x2298: 11, 0x2299: 12, 0x25EF: 13, 0x2218: 14, 0x2219: 15, 0x224D: 16, 0x2261: 17,
    0x2286: 18, 0x2287: 19, 0x2264: 20, 0x2265: 21, 0x2AAF: 22, 0x2AB0: 23, 0x223C: 24, 0x2248: 25, 0x2282: 26,
    0x2283: 27, 0x226A: 28, 0x226B: 29, 0x227A: 30, 0x227B: 31, 0x2190: 32, 0x2192: 33, 0x2191: 34, 0x2193: 35,
    0x2194: 36, 0x2197: 37, 0x2198: 38, 0x2243: 39, 0x21D0: 40, 0x21D2: 41, 0x21D1: 42, 0x21D3: 43, 0x21D4: 44,
    0x2196: 45, 0x2199: 46, 0x221D: 47, 0x221E: 49, 0x2208: 50, 0x220B: 51, 0x25B3: 52, 0x25BD: 53, 0x2200: 56,
    0x2203: 57, 0xAC: 58, 0x2205: 59, 0x211C: 60, 0x2111: 61, 0x22A4: 62, 0x22A5: 63, 0x2135: 64, 0x222A: 91,
    0x2229: 92, 0x228E: 93, 0x2227: 94, 0x2228: 95, 0x22A2: 96, 0x22A3: 97, 0x230A: 98, 0x230B: 99, 0x2308: 100,
    0x2309: 101, 0x7B: 102, 0x7D: 103, 0x27E8: 104, 0x27E9: 105, 0x7C: 106, 0x2223: 106, 0x2225: 107, 0x2016: 107,
    0x2195: 108, 0x21D5: 109, 0x2216: 110, 0x2240: 111, 0x2207: 114, 0x2294: 116, 0x2293: 117, 0x2291: 118,
    0x2292: 119, 0xA7: 120, 0x2020: 121, 0x2021: 122, 0xB6: 123, 0x2663: 124, 0x2662: 125, 0x2661: 126, 0x2660: 127,
}
CMMI_NORMAL = {0x3C: 60, 0x3E: 62, 0x2113: 96, 0x2202: 64, 0x2118: 125, 0x22C6: 63, 0x266D: 91, 0x266E: 92, 0x266F: 93}
CMMI_ITALIC = {
    **{c: s for s, c in enumerate(GREEK_CAPS)}, **GREEK_LOWER, **{0x41 + i: 65 + i for i in range(26)},
    **{0x61 + i: 97 + i for i in range(26)}, 0x131: 123, 0x237: 124, 0x2202: 64,
}
VARIANTS = {
    "normal": {**{c: ("cmr", s) for c, s in CMR.items()}, **{c: ("cmsy", s) for c, s in CMSY.items()},
               **{c: ("cmmi", s) for c, s in CMMI_NORMAL.items()}},
    "italic": {c: ("cmmi", s) for c, s in CMMI_ITALIC.items()},
    "-tex-calligraphic": {0x41 + i: ("cmsy", 65 + i) for i in range(26)},
}


def measure():
    lines = [r"\documentclass{article}\begin{document}"]
    for family in ("cmr", "cmmi", "cmsy"):
        for size in SIZES:
            name = f"{family}{size}"
            lines.append(rf"\font\f={name} \immediate\write16{{S {name} sp \the\fontdimen2\f}}")
            for slot in range(128):
                values = "/".join(rf"\the\fontchar{k}\f{slot}" for k in ("wd", "ht", "dp", "ic"))
                lines.append(rf"\immediate\write16{{C {name} {slot} {values}}}")
    lines.append(r"\end{document}")
    with tempfile.TemporaryDirectory() as work:
        src = os.path.join(work, "metrics.tex")
        with open(src, "w") as f:
            f.write("\n".join(lines) + "\n")
        run = subprocess.run(["tectonic", "-X", "compile", "--keep-logs", "--outdir", work, src],
                             capture_output=True, text=True)
        log = open(os.path.join(work, "metrics.log")).read() if os.path.exists(os.path.join(work, "metrics.log")) else ""
    if "C cmsy5 127" not in log:
        sys.exit("Tectonic did not measure the fonts:\n" + run.stderr[-2000:])
    pt = lambda s: float(s.rstrip("pt"))
    found = {}
    for m in re.finditer(r"^C (\w+?)(\d+) (\d+) ([^/]+)/([^/]+)/([^/]+)/(\S+)$", log, re.M):
        family, size, slot = m.group(1), int(m.group(2)), int(m.group(3))
        found[(family, size, slot)] = tuple(pt(v) / size for v in m.group(4, 5, 6, 7))
    for m in re.finditer(r"^S (\w+?)(\d+) sp (\S+)$", log, re.M):
        found[(m.group(1), int(m.group(2)), "space")] = (pt(m.group(3)) / int(m.group(2)), 0.0, 0.0, 0.0)
    return found


def main():
    found = measure()
    out = ["// Generated by scripts/make-tex-metrics.py from Computer Modern's TFM files (cmr, cmmi, cmsy at 10, 7 and",
           "// 5 pt, measured by Tectonic): for each MathJax variant and character, [w, h, d, ic] in ems of the font at",
           "// each size — [10 pt, 7 pt, 5 pt], the sizes TeX sets text, script and scriptscript styles in. Do not edit.",
           "export const TEX_METRICS = {"]
    r = lambda v: f"{v:.5f}".rstrip("0").rstrip(".") if v else "0"
    for variant, chars in VARIANTS.items():
        out.append(f"  '{variant}': {{")
        for code in sorted(chars):
            family, slot = chars[code]
            sizes = [found.get((family, size, slot)) for size in SIZES]
            if any(s is None or s[0] == 0 and slot != "space" for s in sizes):
                sys.exit(f"{family} has no character in slot {slot} (U+{code:04X})")
            out.append(f"    0x{code:X}: [" + ", ".join("[" + ", ".join(r(v) for v in s) + "]" for s in sizes) + "],")
        out.append("  },")
    out.append("};")
    out.append("// The radical sign's width (cmsy slot 112) at the three sizes: MathJax keeps its own height and depth for it.")
    out.append("export const TEX_RADICAL = [" + ", ".join(r(found[("cmsy", size, 112)][0]) for size in SIZES) + "];")
    with open(OUT, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
