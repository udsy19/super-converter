// Super Converter mockups — shared builders: icons, thumbnails, cards, window chrome. Each screen calls SC.render().
(function () {
  if (location.hash === "#dark") document.documentElement.classList.add("dark");

  const I = {
    plus: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M8 3v10M3 8h10"/></svg>',
    grid: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="2.5" y="2.5" width="4.5" height="4.5" rx="1.2"/><rect x="9" y="2.5" width="4.5" height="4.5" rx="1.2"/><rect x="2.5" y="9" width="4.5" height="4.5" rx="1.2"/><rect x="9" y="9" width="4.5" height="4.5" rx="1.2"/></svg>',
    list: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M5.5 4h8M5.5 8h8M5.5 12h8"/><circle cx="2.6" cy="4" r=".6" fill="currentColor"/><circle cx="2.6" cy="8" r=".6" fill="currentColor"/><circle cx="2.6" cy="12" r=".6" fill="currentColor"/></svg>',
    clear: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.2c.05.7.6 1.3 1.3 1.3h3.2c.7 0 1.25-.6 1.3-1.3l.6-8.2"/></svg>',
    down: '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 4l2.5 2.5L7.5 4"/></svg>',
    updown: '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4l2-2 2 2M3 6l2 2 2-2"/></svg>',
    right: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8h10M9.5 4.5L13 8l-3.5 3.5"/></svg>',
    sliders: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><path d="M2.5 4.5h4M9.5 4.5h4M2.5 11.5h7M12.5 11.5h1"/><circle cx="8" cy="4.5" r="1.6"/><circle cx="11" cy="11.5" r="1.6"/></svg>',
    search: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/></svg>',
    share: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M8 10V2.5M5.5 5L8 2.5 10.5 5M5 7H4a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V8a1 1 0 0 0-1-1h-1"/></svg>',
    eye: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M1.8 8S4 3.8 8 3.8 14.2 8 14.2 8 12 12.2 8 12.2 1.8 8 1.8 8z"/><circle cx="8" cy="8" r="2"/></svg>',
    finder: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/></svg>',
    folder: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><path d="M2 4.5c0-.8.6-1.5 1.5-1.5h2.8l1.4 1.5h4.8c.8 0 1.5.7 1.5 1.5v5.5c0 .8-.7 1.5-1.5 1.5h-9c-.9 0-1.5-.7-1.5-1.5z"/></svg>',
    check: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>',
    bang: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M8 3.5v6"/><circle cx="8" cy="12.5" r=".6" fill="currentColor"/></svg>',
    dl: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2.5v8M4.5 7L8 10.5 11.5 7M3 13.5h10"/></svg>',
    gear: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.8M8 12.4v1.8M1.8 8h1.8M12.4 8h1.8M3.6 3.6l1.3 1.3M11.1 11.1l1.3 1.3M3.6 12.4l1.3-1.3M11.1 4.9l1.3-1.3"/></svg>',
    x: '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M2.5 2.5l5 5M7.5 2.5l-5 5"/></svg>',
    stop: '<svg viewBox="0 0 16 16"><rect x="4" y="4" width="8" height="8" rx="1.6" fill="currentColor"/></svg>',
    lock: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="3.5" y="7" width="9" height="6.5" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/></svg>',
    logo: '<svg viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 7.5a5.5 5.5 0 0 1 9.6-3l1.4 1.5M14.5 2.5V6h-3.5M14.5 10.5a5.5 5.5 0 0 1-9.6 3L3.5 12M3.5 15.5V12H7"/></svg>',
  };

  const CAT = { doc: "doc", img: "img", vid: "vid", aud: "aud", sht: "sht", sld: "sld", ebk: "ebk", arc: "arc", vec: "vec", cad: "cad", fnt: "fnt" };
  const css = (v) => `var(--${v})`;

  // ---------- thumbnails (stand-ins for Quick Look thumbnails) ----------
  const T = {
    photo(seed = 0) {
      const skies = [["#FFB26B", "#FF6F91"], ["#7FD3FF", "#C7B8FF"], ["#FFD86B", "#FF8A5B"], ["#9BE7D8", "#5AA7FF"]];
      const [a, b] = skies[seed % skies.length];
      return `<svg width="128" height="92" viewBox="0 0 128 92"><defs><linearGradient id="s${seed}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient><clipPath id="c${seed}"><rect width="128" height="92" rx="7"/></clipPath></defs><g clip-path="url(#c${seed})"><rect width="128" height="92" fill="url(#s${seed})"/><circle cx="${86 - seed * 9}" cy="${30 + seed * 3}" r="13" fill="#FFF6D6" opacity=".95"/><path d="M0 70 L30 44 L52 62 L80 36 L128 72 V92 H0Z" fill="#3B3F8F" opacity=".55"/><path d="M0 80 Q40 64 70 76 T128 74 V92 H0Z" fill="#23264F" opacity=".75"/></g><rect x=".5" y=".5" width="127" height="91" rx="6.5" fill="none" stroke="rgba(255,255,255,.6)"/></svg>`;
    },
    page(c = "doc", opts = {}) {
      const ink = css(c);
      const lines = Array.from({ length: 7 }, (_, i) => `<rect x="10" y="${opts.title ? 30 + i * 7 : 14 + i * 7}" width="${i === 6 ? 30 : 52 - (i % 3) * 4}" height="2.6" rx="1.3" fill="#C9CDD8"/>`).join("");
      return `<svg width="76" height="98" viewBox="0 0 76 98"><rect width="76" height="98" rx="4" fill="#fff"/>${opts.title ? `<rect x="10" y="12" width="40" height="5" rx="2.5" fill="${ink}"/><rect x="10" y="20" width="24" height="3" rx="1.5" fill="#AEB3C2"/>` : ""}${lines}${opts.figure ? `<rect x="10" y="${opts.title ? 82 : 66}" width="56" height="${opts.title ? 8 : 22}" rx="2" fill="${ink}" opacity=".22"/>` : ""}${opts.math ? `<text x="38" y="88" font-family="Times New Roman" font-style="italic" font-size="11" fill="#555" text-anchor="middle">e = mc²</text>` : ""}</svg>`;
    },
    sheet() {
      let g = "";
      for (let r = 0; r < 7; r++) for (let c = 0; c < 4; c++) g += `<rect x="${6 + c * 23}" y="${8 + r * 9}" width="22" height="8" fill="${r === 0 ? css("sht") : "#fff"}" opacity="${r === 0 ? 0.85 : 1}"/>`;
      return `<svg width="104" height="76" viewBox="0 0 104 76"><rect width="104" height="76" rx="4" fill="#E7EAF0"/>${g}<path d="M36 64 L52 50 L66 56 L92 38" stroke="${css("sht")}" stroke-width="2.4" fill="none" stroke-linecap="round" opacity=".0"/></svg>`;
    },
    slide() {
      return `<svg width="124" height="70" viewBox="0 0 124 70"><rect width="124" height="70" rx="4" fill="#fff"/><rect width="124" height="70" rx="4" fill="${css("sld")}" opacity=".08"/><rect x="10" y="12" width="58" height="7" rx="3.5" fill="${css("sld")}"/><rect x="10" y="25" width="40" height="3" rx="1.5" fill="#AEB3C2"/><rect x="10" y="33" width="46" height="3" rx="1.5" fill="#C9CDD8"/><rect x="10" y="41" width="36" height="3" rx="1.5" fill="#C9CDD8"/><circle cx="94" cy="38" r="17" fill="${css("sld")}" opacity=".85"/><path d="M94 38 L94 21 A17 17 0 0 1 110.2 43.2Z" fill="#FFD0CC"/></svg>`;
    },
    video(dur = "2:14", seed = 1) {
      return `<svg width="132" height="76" viewBox="0 0 132 76"><defs><linearGradient id="v${seed}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2E2A6B"/><stop offset="1" stop-color="#7A5AF0"/></linearGradient><clipPath id="vc${seed}"><rect width="132" height="76" rx="7"/></clipPath></defs><g clip-path="url(#vc${seed})"><rect width="132" height="76" fill="url(#v${seed})"/><circle cx="34" cy="24" r="9" fill="#FFD86B" opacity=".9"/><path d="M0 58 Q34 40 66 54 T132 50 V76 H0Z" fill="#14123A" opacity=".7"/></g><circle cx="66" cy="38" r="14" fill="rgba(255,255,255,.92)"/><path d="M61.5 31 L73 38 L61.5 45Z" fill="#5132C2"/><rect x="100" y="60" width="26" height="12" rx="3" fill="rgba(0,0,0,.55)"/><text x="113" y="69" font-family="system-ui" font-size="8" font-weight="600" fill="#fff" text-anchor="middle">${dur}</text></svg>`;
    },
    audio() {
      const h = [10, 22, 34, 18, 40, 28, 46, 24, 36, 16, 30, 44, 20, 32, 12, 26, 38, 14, 22, 8];
      const bars = h.map((v, i) => `<rect x="${8 + i * 5.4}" y="${38 - v / 2}" width="3.2" height="${v}" rx="1.6" fill="${css("aud")}"/>`).join("");
      return `<svg width="124" height="76" viewBox="0 0 124 76"><rect width="124" height="76" rx="12" fill="#fff"/>${bars}</svg>`;
    },
    book() {
      return `<svg width="68" height="96" viewBox="0 0 68 96"><rect width="68" height="96" rx="3" fill="${css("ebk")}"/><rect width="7" height="96" rx="2" fill="rgba(0,0,0,.18)"/><rect x="16" y="18" width="40" height="5" rx="2.5" fill="#fff"/><rect x="16" y="27" width="28" height="3" rx="1.5" fill="rgba(255,255,255,.7)"/><circle cx="36" cy="60" r="13" fill="rgba(255,255,255,.22)"/><path d="M28 64 Q36 48 44 64" stroke="#fff" stroke-width="2" fill="none"/><rect x="22" y="82" width="28" height="3" rx="1.5" fill="rgba(255,255,255,.7)"/></svg>`;
    },
    zip() {
      const teeth = Array.from({ length: 8 }, (_, i) => `<rect x="${i % 2 ? 38 : 32}" y="${6 + i * 6}" width="6" height="3.5" rx="1" fill="#7F5C00" opacity=".6"/>`).join("");
      return `<svg width="76" height="84" viewBox="0 0 76 84"><rect width="76" height="84" rx="10" fill="${css("arc")}"/><rect x="0" y="0" width="76" height="84" rx="10" fill="url(#none)"/>${teeth}<rect x="28" y="56" width="20" height="18" rx="4" fill="#fff" opacity=".9"/><rect x="34" y="61" width="8" height="4" rx="2" fill="#7F5C00" opacity=".7"/></svg>`;
    },
    font() {
      return `<svg width="104" height="80" viewBox="0 0 104 80"><rect width="104" height="80" rx="12" fill="#fff"/><text x="52" y="56" font-family="Georgia" font-size="44" fill="${css("fnt-ink")}" text-anchor="middle">Aa</text><rect x="22" y="64" width="60" height="3" rx="1.5" fill="${css("fnt")}" opacity=".5"/></svg>`;
    },
    vector() {
      return `<svg width="108" height="84" viewBox="0 0 108 84"><rect width="108" height="84" rx="10" fill="#fff"/><path d="M18 64 C 30 14, 70 14, 88 60" stroke="${css("vec")}" stroke-width="3" fill="none"/><circle cx="18" cy="64" r="4" fill="#fff" stroke="${css("vec")}" stroke-width="2"/><circle cx="88" cy="60" r="4" fill="#fff" stroke="${css("vec")}" stroke-width="2"/><rect x="45" y="12" width="7" height="7" fill="${css("vec")}"/><path d="M30 14 L48.5 15.5 L70 14" stroke="${css("vec")}" stroke-width="1" opacity=".6"/><circle cx="30" cy="14" r="2.5" fill="${css("vec")}"/><circle cx="70" cy="14" r="2.5" fill="${css("vec")}"/></svg>`;
    },
    cad() {
      let grid = "";
      for (let i = 1; i < 12; i++) grid += `<path d="M${i * 10} 0V76" stroke="rgba(255,255,255,.12)"/>`;
      for (let i = 1; i < 8; i++) grid += `<path d="M0 ${i * 10}H124" stroke="rgba(255,255,255,.12)"/>`;
      return `<svg width="124" height="76" viewBox="0 0 124 76"><rect width="124" height="76" rx="6" fill="#0E5D8C"/>${grid}<rect x="20" y="16" width="56" height="40" fill="none" stroke="#fff" stroke-width="1.6"/><path d="M76 36 H100 V56 H76" fill="none" stroke="#fff" stroke-width="1.6"/><circle cx="48" cy="36" r="9" fill="none" stroke="#9BDBFF" stroke-width="1.4"/><path d="M20 64 H76" stroke="#9BDBFF" stroke-width="1"/><path d="M20 61 V67 M76 61 V67" stroke="#9BDBFF" stroke-width="1"/></svg>`;
    },
  };

  // ---------- cards ----------
  function pill(cls, text, cat, extra = "") {
    return `<span class="pill ${cls} c-${cat}">${text}${extra}</span>`;
  }
  const flow = (a, b) => `<span class="flow" style="--a:var(--${a});--b:var(--${b})"></span>`;
  function card(f) {
    const c = f.cat;
    let thumbInner = f.thumb;
    let overlay = "";
    let row = `${pill("src", f.src, c)}${flow(c, f.dstCat)}${pill("dst", f.dst, f.dstCat, I.down)}<span class="end icon-btn ${f.optsOn ? "on" : ""}">${I.sliders}</span>`;
    let meta = f.meta;
    let dim = "";
    if (f.state === "progress") {
      dim = "dim";
      overlay = `<div class="progress" style="--from:${css(c)};--to:${css(f.dstCat)}"><i style="width:${f.progress}%"></i></div>`;
      row = `${pill("src", f.src, c)}${flow(c, f.dstCat)}${pill("dst", f.dst, f.dstCat)}<span class="end icon-btn">${I.x.replace('viewBox="0 0 10 10"', 'viewBox="0 0 10 10" style="width:10px;height:10px"')}</span>`;
    }
    if (f.state === "queued") {
      dim = "dim";
      row = `${pill("src", f.src, c)}${flow(c, f.dstCat)}${pill("dst", f.dst, f.dstCat)}`;
    }
    if (f.state === "done") {
      overlay = `<div class="badge ok">${I.check}Done</div>`;
      row = `<span class="pill src c-${f.dstCat}">${f.dst}</span><span class="end" style="display:flex;gap:2px"><span class="icon-btn">${I.eye}</span><span class="icon-btn">${I.share}</span><span class="icon-btn">${I.folder}</span></span>`;
    }
    if (f.state === "failed") {
      overlay = `<div class="badge bad">${I.bang}Didn’t convert</div>`;
      row = `<span class="secondary" style="height:26px;font-size:12px;padding:0 11px">${I.lock}Enter Password…</span><span class="end icon-btn">${I.sliders}</span>`;
    }
    if (f.state === "helper") {
      overlay = `<div class="notice"><span><b>Needs calibre</b><br>Free · 160 MB</span><span class="mini">Install</span></div>`;
    }
    if (f.state === "installing") {
      overlay = `<div class="notice"><span style="flex:1"><b>Installing calibre…</b><br><span class="progress" style="position:static;display:block;margin-top:5px;height:4px;background:rgba(0,0,0,.08);--from:var(--ebk);--to:var(--ebk)"><i style="width:${f.progress}%"></i></span></span></div>`;
    }
    // a converted card takes the colour of what it became (ux §3.4)
    const tone = f.state === "done" ? f.dstCat : c;
    return `<div class="card ${f.selected ? "selected" : ""} c-${tone}">
      <div class="thumb ${dim}" style="${f.thumbBg ? "background:" + f.thumbBg : ""}">${thumbInner}${overlay}</div>
      ${f.remove ? `<span class="remove">${I.x}</span>` : ""}
      <div class="name">${f.name}</div><div class="meta">${meta}</div>
      <div class="row">${row}</div></div>`;
  }

  // the window and its parts
  function toolbar(o) {
    return `<div class="toolbar"><div class="lights"><i></i><i></i><i></i></div>
      <div class="title"><b>${o.title || "Super Converter"}</b>${o.subtitle ? `<span>${o.subtitle}</span>` : ""}</div>
      <div class="spacer"></div>${o.tools || ""}</div>`;
  }
  const defaultTools = (o = {}) => `
      <span class="tb-btn">${I.plus}</span>
      <span class="tb-group"><span class="tb-btn ${o.list ? "" : "on"}">${I.grid}</span><span class="tb-btn ${o.list ? "on" : ""}">${I.list}</span></span>
      <span class="tb-btn">${I.clear}</span>`;

  function render(o) {
    const W = o.canvas || [1280, 820];
    document.body.style.width = W[0] + "px";
    document.body.style.height = W[1] + "px";
    const win = o.window || { x: 100, y: 60, w: 1080, h: 700 };
    document.body.innerHTML = `<div class="desk"></div>${o.before || ""}
      <div class="window" style="left:${win.x}px;top:${win.y}px;width:${win.w}px;height:${win.h}px">
        ${toolbar(o)}
        <div class="content">${o.content || ""}</div>
      </div>${o.after || ""}`;
  }

  // a scene without the main window (menu bar, Finder, Settings)
  function scene(html, size) {
    const W = size || [1280, 820];
    document.body.style.width = W[0] + "px";
    document.body.style.height = W[1] + "px";
    document.body.innerHTML = `<div class="desk"></div>${html}`;
  }

  window.SC = { I, T, card, pill, flow, render, scene, toolbar, defaultTools, css };
})();
