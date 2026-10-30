// MathKit's entry into MathJax 3.2.2 (Apache-2.0): TeX input, SVG output, the lite DOM adaptor — no browser, no
// network, no timers. Built into mathjax-tex-svg.js by the command in README.md; MathKit evaluates the result in
// JavaScriptCore and calls `superConverterTeX(tex, display)`, which returns JSON:
//   {w, h, d}      width, height above and depth below the baseline, in em
//   nodes          in em, y up, baseline at 0: [0, fill, segments] a filled path, [2, stroke, width, segments] a
//                  stroked one, [1, fill, text, x, y, size, variant, mono] \text{…} and characters MathJax's fonts lack
//   breaks         in em: [x, width, stretch, shrink, penalty] the glue and break penalties between the atoms of the
//                  formula's outer list, which TeX's paragraph builder stretches, shrinks and breaks at (TeXbook ch. 18)
//   undefined      macros noundefined set in red; errors: parse errors (MathKit sets the source in red instead)
import {mathjax} from 'mathjax-full/js/mathjax.js';
import {TeX} from 'mathjax-full/js/input/tex.js';
import {SVG} from 'mathjax-full/js/output/svg.js';
import {liteAdaptor} from 'mathjax-full/js/adaptors/liteAdaptor.js';
import {RegisterHTMLHandler} from 'mathjax-full/js/handlers/html.js';
import {AllPackages} from 'mathjax-full/js/input/tex/AllPackages.js';
import {MapHandler} from 'mathjax-full/js/input/tex/MapHandler.js';
import {MmlMath} from 'mathjax-full/js/core/MmlTree/MmlNodes/math.js';
import {MmlMstyle} from 'mathjax-full/js/core/MmlTree/MmlNodes/mstyle.js';
import {SVGTextNode} from 'mathjax-full/js/output/svg/Wrappers/TextNode.js';
import {SVGscriptbase} from 'mathjax-full/js/output/svg/Wrappers/scriptbase.js';
import {SVGmfrac} from 'mathjax-full/js/output/svg/Wrappers/mfrac.js';
import {SVGmtable} from 'mathjax-full/js/output/svg/Wrappers/mtable.js';
import {SVGmo} from 'mathjax-full/js/output/svg/Wrappers/mo.js';
import {SVGmath} from 'mathjax-full/js/output/svg/Wrappers/math.js';
import {TEXCLASS} from 'mathjax-full/js/core/MmlTree/MmlNode.js';
import {TEX_METRICS, TEX_RADICAL} from './tex-metrics.js';

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
let errors = [];
const tex = new TeX({
  packages: AllPackages.filter((p) => p !== 'noerrors' && p !== 'html'),
  tags: 'none',
  formatError: (jax, err) => { errors.push(err.message); return jax.formatError(err); },
});
const svg = new SVG({fontCache: 'none', internalSpeechTitles: false});
const html = mathjax.document('', {InputJax: tex, OutputJax: svg});

// ---- TeX's metrics (quality §3.7: the same lines as LaTeX). MathJax scales one 10 pt design to every size and
// approximates what its font data lacks; TeX's widths decide where lines break, so MathKit gives MathJax TeX's own.

// Scripts at 70 % and scriptscripts at 50 % (\scriptfont = 7 pt, \scriptscriptfont = 5 pt), not MathML's 1/√2: the
// second level is clamped to scriptminsize, 8px of the 16px em.
MmlMath.defaults.scriptsizemultiplier = MmlMstyle.defaults.scriptsizemultiplier = 0.7;

// Each character's width, height, depth and italic correction from cmr/cmmi/cmsy at the size TeX sets its style in
// (tex-metrics.js, made by scripts/make-tex-metrics.py): the 7 and 5 pt designs are wider than the 10 pt one scaled
// down, and MathJax's data lacks most italic corrections (β, y, z). Keyed by what TextNode asks for: italic letters by
// their Math Alphanumeric code point, as MathJax remaps them.
const texChars = {};
for (const [variant, chars] of Object.entries(TEX_METRICS)) {
  const map = texChars[variant] = new Map();
  for (const [code, sizes] of Object.entries(chars)) {
    const n = Number(code), entry = {sizes, cache: []};
    map.set(n, entry);
    const smp = svg.font.getChar(variant, n)?.[3]?.smp;
    if (smp) map.set(smp, entry);
  }
}
// The radical sign takes TeX's width but keeps MathJax's height and depth, which place it against the rule, and drops
// MathJax's italic correction (TeX's has none); its outline sits at the right so it still meets the rule.
texChars.normal.set(0x221A, {radical: TEX_RADICAL, cache: []});
const variantChar = SVGTextNode.prototype.getVariantChar;
SVGTextNode.prototype.getVariantChar = function (variant, n) {
  const char = variantChar.call(this, variant, n);
  const entry = texChars[variant]?.get(n);
  if (!entry || !('p' in char[3])) return char;
  const level = Math.min(2, this.parent.node.attributes.get('scriptlevel') || 0);
  if (!entry.cache[level] && entry.radical) {
    const w = entry.radical[level];
    entry.cache[level] = [char[0], char[1], w, {...char[3], ic: 0, texShift: w - char[2]}];
  } else if (!entry.cache[level]) {
    const [w, h, d, ic] = entry.sizes[level];
    // The 10 pt outline is centred in TeX's advance.
    entry.cache[level] = [h, d, w, {...char[3], ic, texShift: (w - char[2]) / 2}];
  }
  return entry.cache[level];
};
const placeChar = SVGTextNode.prototype.placeChar;
SVGTextNode.prototype.placeChar = function (n, x, y, parent, variant) {
  const shift = this.getVariantChar(variant ?? this.variant, n)[3].texShift || 0;
  return placeChar.call(this, n, x + shift, y, parent, variant);
};
// With real italic corrections, scripts follow Appendix G rule 18 exactly: a superscript starts at the nucleus's width
// plus its italic correction, a subscript at its width; MathJax's padding for the corrections it lacked goes.
svg.font.params.extra_ic = 0;
SVGscriptbase.prototype.getAdjustedIc = function () { return this.baseIc; };

// A fraction is its numerator or denominator, whichever is wider, between two \nulldelimiterspace kerns (rule 15e);
// MathJax also runs the rule 0.1 em past each side. Adapted from MathJax 3.2.2's SVGmfrac.makeFraction (Apache-2.0).
SVGmfrac.prototype.getFractionBBox = function (bbox, display, t) {
  const nbox = this.childNodes[0].getOuterBBox(), dbox = this.childNodes[1].getOuterBBox();
  const a = this.font.params.axis_height, {T, u, v} = this.getTUV(display, t);
  bbox.combine(nbox, 0, a + T + Math.max(nbox.d * nbox.rscale, u));
  bbox.combine(dbox, 0, a - T - Math.max(dbox.h * dbox.rscale, v));
  bbox.w += 2 * this.pad;
};
SVGmfrac.prototype.makeFraction = function (display, t) {
  const {numalign, denomalign} = this.node.attributes.getList('numalign', 'denomalign');
  const [num, den] = this.childNodes;
  const nbox = num.getOuterBBox(), dbox = den.getOuterBBox();
  const a = this.font.params.axis_height, pad = this.pad;
  const W = Math.max((nbox.L + nbox.w + nbox.R) * nbox.rscale, (dbox.L + dbox.w + dbox.R) * dbox.rscale);
  const {T, u, v} = this.getTUV(display, t);
  num.toSVG(this.element);
  num.place(this.getAlignX(W, nbox, numalign) + pad, a + T + Math.max(nbox.d * nbox.rscale, u));
  den.toSVG(this.element);
  den.place(this.getAlignX(W, dbox, denomalign) + pad, a - T - Math.max(dbox.h * dbox.rscale, v));
  this.adaptor.append(this.element, this.svg('rect', {width: this.fixed(W), height: this.fixed(t), x: this.fixed(pad), y: this.fixed(a - t / 2)}));
};

// A null delimiter (`\left.`, `\right.`, the right of cases) is \nulldelimiterspace wide, not nothing (rule 19).
const moBBox = SVGmo.prototype.computeBBox;
SVGmo.prototype.computeBBox = function (bbox, recompute = false) {
  moBBox.call(this, bbox, recompute);
  if (this.node.attributes.get('fence') && this.node.getText() === '') bbox.w = this.font.params.nulldelimiterspace;
};

// Rows of arrays and alignments as TeX stacks them: every row holds a strut, and baselines are \baselineskip apart
// unless the rows would come closer than \lineskiplimit, when \lineskip separates them (TeXbook p. 79). In ems of
// 10 pt type with LaTeX's 12 pt \baselineskip: arrays and matrices have 8.4/3.6 pt struts and nothing between rows;
// cases is an array with \arraystretch 1.2; amsmath's alignments \openup\jot (3 pt) around 8.4/3.6 pt struts.
// `\\[x]` adds x, as TeX adds it below the row.
const ROWS = {
  array: {h: 0.84, d: 0.36, skip: 0, lineskip: 0, limit: 0},
  cases: {h: 1.008, d: 0.432, skip: 0, lineskip: 0, limit: 0},
  jot: {h: 0.84, d: 0.36, skip: 1.5, lineskip: 0.4, limit: 0.3},
};
for (const [map, names, rows] of [
  ['environment', ['array'], 'array'],
  ['AMSmath-environment', ['matrix', 'pmatrix', 'bmatrix', 'Bmatrix', 'vmatrix', 'Vmatrix'], 'array'],
  ['AMSmath-environment', ['cases'], 'cases'],
  ['AMSmath-environment', ['aligned', 'gathered', 'alignedat', 'align', 'align*', 'gather', 'gather*', 'alignat',
    'alignat*', 'split'], 'jot'],
]) {
  for (const name of names) {
    const macro = MapHandler.getMap(map).lookup(name);
    const parse = macro._func;
    macro._func = (parser, begin, ...args) => {
      const item = parse(parser, begin, ...args);
      // The rows' TeX model and the environment's own row spacing, which `\\[x]` adds to.
      if (item?.arraydef) item.arraydef['data-tex-rows'] = `${rows} ${item.arraydef.rowspacing || 0}`;
      return item;
    };
  }
}
const tableData = SVGmtable.prototype.getTableData;
SVGmtable.prototype.getTableData = function () {
  if (this.data) return this.data;
  const data = tableData.call(this);
  const spec = this.node.attributes.getExplicit('data-tex-rows');
  if (!spec) return data;
  const [kind, base] = spec.split(' '), rows = ROWS[kind], own = this.length2em(base);
  const {H, D} = data;
  for (let j = 0; j < H.length; j++) {
    H[j] = Math.max(H[j], rows.h);
    D[j] = Math.max(D[j], rows.d);
  }
  for (let j = 0; j + 1 < H.length; j++) {
    const gap = rows.skip - D[j] - H[j + 1];
    this.rSpace[j] = (gap >= rows.limit ? gap : rows.lineskip) + Math.max(0, this.rSpace[j] - own);
  }
  return data;
};

// The outer list's glue: TeX sets inline math inside the paragraph, so the spaces between its atoms stretch and shrink
// with the line — \thinmuskip 3mu, \medmuskip 4mu plus 2mu minus 4mu, \thickmuskip 5mu plus 5mu — and a line may
// break after a relation (\relpenalty 500) or a binary operator (\binoppenalty 700), Appendix G rule 20. A space that
// is no breakpoint is marked with penalty 10000 (glue inside math never is one).
const MU = 1 / 18;
const GLUE = {thinmathspace: [0, 0], mediummathspace: [2 * MU, 4 * MU], thickmathspace: [5 * MU, 0]};
let breaks = [];
const mathSVG = SVGmath.prototype.toSVG;
SVGmath.prototype.toSVG = function (parent) {
  mathSVG.call(this, parent);
  const atoms = this.childNodes[0]?.childNodes || [];
  const r = (v) => Math.round(v * 1e5) / 1e5;
  let x = 0;
  atoms.forEach((atom, i) => {
    const bbox = atom.getOuterBBox(), left = bbox.L * bbox.rscale;
    const before = atoms[i - 1]?.node.texClass, kind = atom.node.texClass;
    const penalty = before === TEXCLASS.REL && kind !== TEXCLASS.REL ? 500 : before === TEXCLASS.BIN ? 700 : 10000;
    const [stretch, shrink] = GLUE[atom.node.texSpacing()] || [0, 0];
    if (i > 0 && (stretch || shrink || penalty < 10000)) breaks.push([r(x), r(left), r(stretch), r(shrink), penalty]);
    x += left + (bbox.w + bbox.R) * bbox.rscale;
  });
};

// \text{…} is text in the surrounding text font, as LaTeX sets it (and PDF readers extract it as words): MathKit
// emits it as a <text> run at TeX's position instead of MathJax's glyph outlines.
const textNodeSVG = SVGTextNode.prototype.toSVG;
SVGTextNode.prototype.toSVG = function (parent) {
  const variant = this.parent.variant, text = this.node.getText();
  if (!this.parent.node.isKind('mtext') || variant === '-explicitFont' || text.length === 0) return textNodeSVG.call(this, parent);
  this.element = this.adaptor.append(parent, this.svg('text', {
    'data-variant': variant, transform: 'scale(1,-1)', 'font-size': '1000px',
    'font-family': variant.includes('monospace') ? 'monospace' : 'serif',
  }, [this.text(text)]));
};

// Affine matrices [a b c d e f] as in SVG.
const multiply = (m, n) => [m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1], m[0] * n[2] + m[2] * n[3],
  m[1] * n[2] + m[3] * n[3], m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]];
function parseTransform(s) {
  let m = [1, 0, 0, 1, 0, 0];
  if (!s) return m;
  for (const [, op, args] of s.matchAll(/(\w+)\s*\(([^)]*)\)/g)) {
    const v = args.split(/[\s,]+/).filter((x) => x !== '').map(Number);
    let n;
    switch (op) {
      case 'translate': n = [1, 0, 0, 1, v[0], v[1] || 0]; break;
      case 'scale': n = [v[0], 0, 0, v.length > 1 ? v[1] : v[0], 0, 0]; break;
      case 'matrix': n = v; break;
      case 'rotate': {
        const r = v[0] * Math.PI / 180, c = Math.cos(r), sn = Math.sin(r);
        n = [c, sn, -sn, c, 0, 0];
        if (v.length > 2) n = multiply(multiply([1, 0, 0, 1, v[1], v[2]], n), [1, 0, 0, 1, -v[1], -v[2]]);
        break;
      }
      case 'skewX': n = [1, 0, Math.tan(v[0] * Math.PI / 180), 1, 0, 0]; break;
      case 'skewY': n = [1, Math.tan(v[0] * Math.PI / 180), 0, 1, 0, 0]; break;
      default: n = [1, 0, 0, 1, 0, 0];
    }
    m = multiply(m, n);
  }
  return m;
}

// SVG path data → absolute segments under `m`: [0 x y] move, [1 x y] line, [2 x1 y1 x2 y2 x y] cubic, [3] close.
// Quadratics are raised to cubics so Swift needs one curve kind; arcs (enclose's circles) become cubics too. Each path
// string is parsed once, in its own units (a glyph recurs in nearly every formula), and only transformed per use: the
// curves are built before the transform, which maps them exactly, so the result is the same as parsing every time.
const pathCache = new Map();
function pathSegments(d, m) {
  let local = pathCache.get(d);
  if (!local) {
    if (pathCache.size >= 4096) pathCache.clear();   // bars and rules carry their positions; glyphs are a few hundred
    local = parsePath(d);
    pathCache.set(d, local);
  }
  // Rounded to 1/100000 em (0.0001 pt at 10 pt): keeps the JSON small, which is most of the cost per formula.
  const round = (v) => Math.round(v * 1e5) / 1e5;
  return local.map((seg) => {
    const out = [seg[0]];
    for (let k = 1; k < seg.length; k += 2) {
      out.push(round(m[0] * seg[k] + m[2] * seg[k + 1] + m[4]), round(m[1] * seg[k] + m[3] * seg[k + 1] + m[5]));
    }
    return out;
  });
}

// SVG path data → the same segments in the path's own units.
function parsePath(d) {
  const out = [];
  const T = (x, y) => [x, y];
  const tokens = d.match(/[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?/g) || [];
  let i = 0, cmd = '', x = 0, y = 0, sx = 0, sy = 0, cx = 0, cy = 0, qx = 0, qy = 0, prev = '';
  const num = () => Number(tokens[i++]);
  const cubic = (x1, y1, x2, y2, ex, ey) => { out.push([2, ...T(x1, y1), ...T(x2, y2), ...T(ex, ey)]); };
  const quad = (x1, y1, ex, ey) => {
    cubic(x + 2 / 3 * (x1 - x), y + 2 / 3 * (y1 - y), ex + 2 / 3 * (x1 - ex), ey + 2 / 3 * (y1 - ey), ex, ey);
  };
  function arc(rx, ry, phi, large, sweep, ex, ey) {
    if (rx === 0 || ry === 0) { out.push([1, ...T(ex, ey)]); return; }
    const p = phi * Math.PI / 180, cp = Math.cos(p), sp = Math.sin(p);
    const dx = (x - ex) / 2, dy = (y - ey) / 2, x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy;
    rx = Math.abs(rx); ry = Math.abs(ry);
    const l = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
    if (l > 1) { rx *= Math.sqrt(l); ry *= Math.sqrt(l); }
    const sign = large === sweep ? -1 : 1;
    const num2 = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    const co = sign * Math.sqrt(Math.max(0, num2 / (rx * rx * y1 * y1 + ry * ry * x1 * x1)));
    const cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx;
    const ccx = cp * cxp - sp * cyp + (x + ex) / 2, ccy = sp * cxp + cp * cyp + (y + ey) / 2;
    const ang = (ux, uy, vx, vy) => Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    let t1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry);
    let dt = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry);
    if (!sweep && dt > 0) dt -= 2 * Math.PI; else if (sweep && dt < 0) dt += 2 * Math.PI;
    const n = Math.ceil(Math.abs(dt) / (Math.PI / 2)), step = dt / n, k = 4 / 3 * Math.tan(step / 4);
    const P = (t) => [ccx + rx * Math.cos(t) * cp - ry * Math.sin(t) * sp, ccy + rx * Math.cos(t) * sp + ry * Math.sin(t) * cp];
    const D = (t) => [-rx * Math.sin(t) * cp - ry * Math.cos(t) * sp, -rx * Math.sin(t) * sp + ry * Math.cos(t) * cp];
    for (let j = 0; j < n; j++) {
      const a = t1 + j * step, b = a + step, pa = P(a), pb = P(b), da = D(a), db = D(b);
      cubic(pa[0] + k * da[0], pa[1] + k * da[1], pb[0] - k * db[0], pb[1] - k * db[1], pb[0], pb[1]);
    }
  }
  while (i < tokens.length) {
    if (/[A-Za-z]/.test(tokens[i])) cmd = tokens[i++];
    const rel = cmd === cmd.toLowerCase(), ox = rel ? x : 0, oy = rel ? y : 0;
    switch (cmd.toUpperCase()) {
      case 'M': x = ox + num(); y = oy + num(); sx = x; sy = y; out.push([0, ...T(x, y)]); cmd = rel ? 'l' : 'L'; break;
      case 'L': x = ox + num(); y = oy + num(); out.push([1, ...T(x, y)]); break;
      case 'H': x = ox + num(); out.push([1, ...T(x, y)]); break;
      case 'V': y = oy + num(); out.push([1, ...T(x, y)]); break;
      case 'C': {
        const x1 = ox + num(), y1 = oy + num(), x2 = ox + num(), y2 = oy + num(), ex = ox + num(), ey = oy + num();
        cubic(x1, y1, x2, y2, ex, ey); cx = x2; cy = y2; x = ex; y = ey; break;
      }
      case 'S': {
        const x1 = /[CS]/i.test(prev) ? 2 * x - cx : x, y1 = /[CS]/i.test(prev) ? 2 * y - cy : y;
        const x2 = ox + num(), y2 = oy + num(), ex = ox + num(), ey = oy + num();
        cubic(x1, y1, x2, y2, ex, ey); cx = x2; cy = y2; x = ex; y = ey; break;
      }
      case 'Q': {
        const x1 = ox + num(), y1 = oy + num(), ex = ox + num(), ey = oy + num();
        quad(x1, y1, ex, ey); qx = x1; qy = y1; x = ex; y = ey; break;
      }
      case 'T': {
        const x1 = /[QT]/i.test(prev) ? 2 * x - qx : x, y1 = /[QT]/i.test(prev) ? 2 * y - qy : y;
        const ex = ox + num(), ey = oy + num();
        quad(x1, y1, ex, ey); qx = x1; qy = y1; x = ex; y = ey; break;
      }
      case 'A': {
        const rx = num(), ry = num(), phi = num(), large = num(), sweep = num(), ex = ox + num(), ey = oy + num();
        arc(rx, ry, phi, large, sweep, ex, ey); x = ex; y = ey; break;
      }
      case 'Z': out.push([3]); x = sx; y = sy; break;
      default: i++;
    }
    prev = cmd;
  }
  return out;
}

const colour = (node, inherited) => {
  const f = adaptor.getAttribute(node, 'fill');
  return f && f !== 'currentColor' ? f : inherited;
};
const strokeColour = (node, inherited) => {
  const s = adaptor.getAttribute(node, 'stroke');
  return s && s !== 'currentColor' ? s : inherited;
};

// Walks MathJax's SVG: <g> nests transforms and colours, <path>, <rect>, <line>, <ellipse> and <polygon> draw (frac
// bars, \rule, enclosures), <text> carries characters MathJax's fonts lack (set by MathKit in a system font).
function walk(node, m, fill, stroke, nodes) {
  if (adaptor.kind(node) === '#text') return;
  const tag = adaptor.kind(node);
  const own = multiply(m, parseTransform(adaptor.getAttribute(node, 'transform')));
  const f = colour(node, fill), s = strokeColour(node, stroke);
  const attr = (k) => Number(adaptor.getAttribute(node, k) || 0);
  const strokeWidth = () => Number(adaptor.getAttribute(node, 'stroke-width') || 0) * Math.sqrt(Math.abs(own[0] * own[3] - own[1] * own[2]));
  switch (tag) {
    case 'path': nodes.push([0, f, pathSegments(adaptor.getAttribute(node, 'd') || '', own)]); return;
    case 'rect': {
      const x = attr('x'), y = attr('y'), w = attr('width'), h = attr('height');
      if (adaptor.getAttribute(node, 'fill') === 'none') {
        nodes.push([2, s, strokeWidth(), pathSegments(`M${x} ${y}H${x + w}V${y + h}H${x}Z`, own)]);
      } else {
        nodes.push([0, f, pathSegments(`M${x} ${y}H${x + w}V${y + h}H${x}Z`, own)]);
      }
      return;
    }
    case 'line':
      nodes.push([2, s, strokeWidth(), pathSegments(`M${attr('x1')} ${attr('y1')}L${attr('x2')} ${attr('y2')}`, own)]);
      return;
    case 'ellipse': {
      const cx = attr('cx'), cy = attr('cy'), rx = attr('rx'), ry = attr('ry');
      const d = `M${cx - rx} ${cy}A${rx} ${ry} 0 1 0 ${cx + rx} ${cy}A${rx} ${ry} 0 1 0 ${cx - rx} ${cy}Z`;
      nodes.push([2, s, strokeWidth(), pathSegments(d, own)]);
      return;
    }
    case 'polygon': case 'polyline': {
      const p = (adaptor.getAttribute(node, 'points') || '').trim();
      nodes.push([2, s, strokeWidth(), pathSegments('M' + p + (tag === 'polygon' ? 'Z' : ''), own)]);
      return;
    }
    case 'text': {
      const size = Number((adaptor.getAttribute(node, 'font-size') || '1000').replace('px', ''));
      const variant = adaptor.getAttribute(node, 'data-variant') || 'normal';
      const family = adaptor.getAttribute(node, 'font-family') || '';
      const scale = Math.sqrt(Math.abs(own[0] * own[3] - own[1] * own[2]));
      nodes.push([1, f, adaptor.textContent(node), own[4], own[5], size * scale, variant, family.includes('monospace')]);
      return;
    }
    default:
      for (const child of adaptor.childNodes(node)) walk(child, own, f, s, nodes);
  }
}

// Macros noundefined set in red: the text of each red mtext in the internal MathML.
function undefinedMacros(root, found) {
  if (root.isKind && root.isKind('mtext') && root.attributes.get('mathcolor') === 'red') {
    const t = root.childNodes.map((c) => (c.getText ? c.getText() : '')).join('');
    if (t.startsWith('\\')) found.push(t);
  }
  for (const c of root.childNodes || []) if (c && typeof c === 'object' && 'childNodes' in c) undefinedMacros(c, found);
}

globalThis.superConverterTeX = function (source, display) {
  errors = []; breaks = [];
  const item = html.convert(source, {display: !!display, em: 16, ex: 8, containerWidth: 80 * 16});
  const svgNode = adaptor.tags(item, 'svg')[0];
  const [, minY, vbW, vbH] = (adaptor.getAttribute(svgNode, 'viewBox') || '0 0 0 0').split(/\s+/).map(Number);
  const nodes = [];
  if (errors.length) return JSON.stringify({w: 0, h: 0, d: 0, nodes, breaks: [], undefined: [], errors});
  // The SVG is y down with the baseline at 0; flip it back to y up and scale units (1/1000 em) to em.
  for (const child of adaptor.childNodes(svgNode)) walk(child, [0.001, 0, 0, -0.001, 0, 0], null, null, nodes);
  const found = [];
  undefinedMacros(tex.parseOptions.root || {childNodes: []}, found);
  return JSON.stringify({w: vbW / 1000, h: -minY / 1000, d: (vbH + minY) / 1000, nodes, breaks, undefined: found, errors});
};
