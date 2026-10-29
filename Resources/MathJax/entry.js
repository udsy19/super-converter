// MathKit's entry into MathJax 3.2.2 (Apache-2.0): TeX input, SVG output, the lite DOM adaptor — no browser, no
// network, no timers. Built into mathjax-tex-svg.js by the command in README.md; MathKit evaluates the result in
// JavaScriptCore and calls `superConverterTeX(tex, display)`, which returns JSON:
//   {w, h, d}      width, height above and depth below the baseline, in em
//   nodes          in em, y up, baseline at 0: [0, fill, segments] a filled path, [2, stroke, width, segments] a
//                  stroked one, [1, fill, text, x, y, size, variant, mono] characters MathJax's fonts lack
//   undefined      macros noundefined set in red; errors: parse errors (MathKit sets the source in red instead)
import {mathjax} from 'mathjax-full/js/mathjax.js';
import {TeX} from 'mathjax-full/js/input/tex.js';
import {SVG} from 'mathjax-full/js/output/svg.js';
import {liteAdaptor} from 'mathjax-full/js/adaptors/liteAdaptor.js';
import {RegisterHTMLHandler} from 'mathjax-full/js/handlers/html.js';
import {AllPackages} from 'mathjax-full/js/input/tex/AllPackages.js';

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
// Quadratics are raised to cubics so Swift needs one curve kind; arcs (enclose's circles) become cubics too.
function pathSegments(d, m) {
  const out = [];
  // Rounded to 1/100000 em (0.0001 pt at 10 pt): keeps the JSON small, which is most of the cost per formula.
  const round = (v) => Math.round(v * 1e5) / 1e5;
  const T = (x, y) => [round(m[0] * x + m[2] * y + m[4]), round(m[1] * x + m[3] * y + m[5])];
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
  errors = [];
  const item = html.convert(source, {display: !!display, em: 16, ex: 8, containerWidth: 80 * 16});
  const svgNode = adaptor.tags(item, 'svg')[0];
  const [, minY, vbW, vbH] = (adaptor.getAttribute(svgNode, 'viewBox') || '0 0 0 0').split(/\s+/).map(Number);
  const nodes = [];
  if (errors.length) return JSON.stringify({w: 0, h: 0, d: 0, nodes, undefined: [], errors});
  // The SVG is y down with the baseline at 0; flip it back to y up and scale units (1/1000 em) to em.
  for (const child of adaptor.childNodes(svgNode)) walk(child, [0.001, 0, 0, -0.001, 0, 0], null, null, nodes);
  const found = [];
  undefinedMacros(tex.parseOptions.root || {childNodes: []}, found);
  return JSON.stringify({w: vbW / 1000, h: -minY / 1000, d: (vbH + minY) / 1000, nodes, undefined: found, errors});
};
