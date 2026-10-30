/* Super Converter website. The pictures of the app are built ahead of time (src/build.mjs); this script runs the hero
   window, the format list's search and the header. Nothing a visitor does here is stored or sent anywhere. Scrolling
   is left to the browser: nothing here moves the page except anchor links the visitor clicks. */
(() => {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const root = document.documentElement;

  // ---------- Header: frost on scroll, inverted over dark sections, menu ----------
  const frost = $(".frost");
  if (frost && !(window.CSS && CSS.supports("animation-timeline: scroll()"))) {
    let ticking = false;
    const paint = () => { ticking = false; frost.style.opacity = String(Math.min(1, window.scrollY / 69)); };
    addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(paint); } }, { passive: true });
    paint();
  }

  const darkSections = $$("[data-invert-header]");
  let invertIO = null;
  const watchInvert = () => {
    if (invertIO) invertIO.disconnect();
    const under = new Set();
    invertIO = new IntersectionObserver((entries) => {
      entries.forEach((e) => (e.isIntersecting ? under.add(e.target) : under.delete(e.target)));
      root.toggleAttribute("data-header-invert", under.size > 0);
    }, { rootMargin: `0px 0px ${-(innerHeight - 72)}px 0px` });
    darkSections.forEach((s) => invertIO.observe(s));
  };
  if (darkSections.length) { watchInvert(); addEventListener("resize", watchInvert); }

  const burger = $("[data-burger]");
  const menu = $("[data-menu]");
  const outside = [$("main"), $("footer")];
  function setMenu(open) {
    root.classList.toggle("menu-open", open);
    burger.setAttribute("aria-expanded", String(open));
    burger.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    outside.forEach((el) => el && (el.inert = open));
  }
  if (burger && menu) {
    burger.addEventListener("click", () => setMenu(!root.classList.contains("menu-open")));
    $$("a", menu).forEach((a) => a.addEventListener("click", () => setMenu(false)));
    addEventListener("keydown", (e) => { if (e.key === "Escape" && root.classList.contains("menu-open")) { setMenu(false); burger.focus({ preventScroll: true }); } });
    matchMedia("(min-width: 62.5rem)").addEventListener("change", (m) => { if (m.matches) setMenu(false); });
  }

  // ---------- Reveal on scroll ----------
  const rise = $$(".rise-in");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) { e.target.dataset.revealed = ""; io.unobserve(e.target); }
    }), { rootMargin: "0px 0px -15% 0px" });
    rise.forEach((el) => io.observe(el));
  } else {
    rise.forEach((el) => { el.dataset.revealed = ""; });
  }

  // ---------- Hero: pick a format, convert eight files (ux §5.4–5.7) ----------
  // A 16-second loop that plays while half of the window is on screen; Reduce Motion keeps the still picture.
  (function hero() {
    const app = $("[data-app]");
    if (!app || reduced || !("IntersectionObserver" in window)) return;
    const cards = $$(".hc", app);
    const sub = $("[data-sub]", app), doneCount = $("[data-done]", app), bar = $("[data-bar]", app);
    // When each card starts and how long it takes (ms after Convert): small files beside the long video (ux §6.4).
    const plan = { heic: [0, 900], docx: [150, 1400], mov: [0, 4600], wav: [300, 2800], xlsx: [1000, 900], pptx: [1500, 1900], epub: [2100, 1500], svg: [2500, 600] };
    let timers = [];
    const at = (ms, fn) => timers.push(setTimeout(fn, ms));
    const phase = (p) => { app.dataset.phase = p; };
    function reset() {
      timers.forEach(clearTimeout); timers = [];
      phase("ready");
      app.classList.remove("is-reset", "is-press");
      cards.forEach((c) => c.classList.remove("is-run", "is-done"));
      sub.textContent = "8 files · 1.7 GB";
      doneCount.textContent = "0";
      bar.style.width = "0%";
    }
    function play() {
      reset();
      at(1400, () => phase("pick"));
      at(4200, () => phase("ready"));
      at(5200, () => app.classList.add("is-press"));
      at(5400, () => {
        app.classList.remove("is-press");
        phase("run");
        sub.textContent = "Converting 0 of 8";
        let done = 0;
        cards.forEach((c) => {
          const [start, length] = plan[c.dataset.k];
          at(start, () => { c.style.setProperty("--t", length + "ms"); c.classList.add("is-run"); });
          at(start + length, () => {
            c.classList.add("is-done");
            done += 1;
            sub.textContent = done === 8 ? "8 of 8 converted" : `Converting ${done} of 8`;
            doneCount.textContent = String(done);
            bar.style.width = `${(done / 8) * 100}%`;
            if (done === 8) at(400, () => phase("done"));
          });
        });
      });
      at(14400, () => app.classList.add("is-reset"));
      at(15000, play);
    }
    let on = false;
    new IntersectionObserver(([e]) => {
      const visible = e.intersectionRatio >= .499;
      if (visible && !on) { on = true; play(); }
      if (!visible && on) { on = false; reset(); }
    }, { threshold: [0, .5] }).observe(app);
  })();

  // ---------- What it converts: search and filter ----------
  (function formats() {
    const box = $("[data-fx]");
    if (!box) return;
    const q = $("[data-fx-q]", box), status = $("[data-fx-status]", box), groups = $("[data-fx-groups]", box), more = $("[data-fx-more]", box);
    const chips = $$("[data-filter]", box);
    const rows = $$(".fx", box).map((li) => ({ li, s: li.dataset.s, ext: li.dataset.s.split(" ")[0], out: $(".fx-out", li), pills: $$(".fx-out b", li) }));
    // Plain words people search with (ux §5.4 synonyms).
    const SAY = { word: "docx", excel: "xlsx", powerpoint: "pptx", jpeg: "jpg", kindle: "azw3", text: "txt", markdown: "md", tif: "tiff", keynote: "key" };
    const norm = (w) => SAY[w] || w;
    let cat = "", expanded = false;
    function apply() {
      const text = q.value.trim().toLowerCase().replace(/^\./, "");
      const pair = text.match(/^(.+?)\s*(?:\bto\b|→|->|>)\s*\.?(.*)$/);
      const from = norm(pair ? pair[1].trim() : text), to = pair ? norm(pair[2].trim()) : "";
      let shown = 0;
      rows.forEach((r) => {
        const inCat = !cat || r.li.closest("[data-cat]").dataset.cat === cat;
        const fromOK = !from || r.ext.startsWith(from) || (from.length > 2 && r.s.includes(from));
        let toOK = true;
        r.pills.forEach((b) => { b.classList.remove("hit", "off"); });
        if (to) {
          const hits = r.pills.filter((b) => b.firstChild.textContent.toLowerCase().startsWith(to));
          toOK = hits.length > 0;
          if (toOK) r.pills.forEach((b) => b.classList.add(hits.includes(b) ? "hit" : "off"));
        }
        const show = inCat && fromOK && toOK;
        r.li.hidden = !show;
        if (show) shown += 1;
      });
      $$("[data-cat]", groups).forEach((g) => { g.hidden = !$$(".fx", g).some((li) => !li.hidden); });
      const filtered = Boolean(text || cat);
      groups.classList.toggle("is-clipped", !filtered && !expanded);
      more.parentElement.hidden = filtered;
      const n = `${shown} ${shown === 1 ? "format" : "formats"}`;
      status.textContent = !filtered ? "" : shown === 0 ? `No format matches “${q.value.trim()}”.` : to ? `${n} ${shown === 1 ? "converts" : "convert"} to ${to.toUpperCase()}.` : `${n}.`;
    }
    q.addEventListener("input", apply);
    chips.forEach((b) => b.addEventListener("click", () => {
      cat = b.dataset.filter;
      chips.forEach((c) => c.setAttribute("aria-pressed", String(c === b)));
      apply();
    }));
    $$("[data-q]", box).forEach((b) => b.addEventListener("click", () => { q.value = b.dataset.q; apply(); }));
    const showAll = more.textContent;
    more.addEventListener("click", () => {
      expanded = !expanded;
      more.setAttribute("aria-expanded", String(expanded));
      more.textContent = expanded ? "Show fewer formats" : showAll;
      apply();
    });
    apply();
  })();

  // ---------- Copy the install command ----------
  $$("[data-copy]").forEach((b) => b.addEventListener("click", async () => {
    const status = $("[data-copy-status]");
    try {
      await navigator.clipboard.writeText(b.dataset.copy);
      b.textContent = "Copied";
      if (status) status.textContent = "Copied to the clipboard.";
    } catch (e) {
      const code = b.parentElement.querySelector("code");
      if (code) { const r = document.createRange(); r.selectNodeContents(code); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
      if (status) status.textContent = "Press ⌘C to copy.";
    }
    setTimeout(() => { b.textContent = "Copy"; if (status) status.textContent = ""; }, 2000);
  }));
})();
