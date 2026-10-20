// Element capture for `mix bubble.render_diff` (BubbleEx.Frontend.RenderDiff): evaluate this
// expression in a page (Bubble or the generated app) after its data settles; it returns the
// capture as a JSON string. Same shape on both sides; see the moduledoc for the fields.
// It keeps each element's own visible text (app data: store captures privately), but no
// input values, no query strings and not the page URL's query.
(() => {
  // Element capture, same shape for a Bubble page and a bubble_ex page.
  // Bubble: node.bubble_data.bubble_instance.element.id() is the export element ID.
  // bubble_ex: [data-bubble-id].
  const bubble = !!document.querySelector(".bubble-element");
  const nodes = bubble ? [...document.querySelectorAll(".bubble-element")] : [...document.querySelectorAll("[data-bubble-id]")];
  const set = new Set(nodes);
  const idOf = (n) => {
    if (!bubble) return n.getAttribute("data-bubble-id");
    try { const e = n.bubble_data.bubble_instance.element; return typeof e.id === "function" ? e.id() : (e.id || null); } catch (_) { return null; }
  };
  const typeOf = (n) => {
    if (!bubble) return null;
    try { return n.bubble_data.bubble_instance.element._type; } catch (_) { return null; }
  };
  const owner = (node) => { let p = node.parentElement; while (p && !set.has(p)) p = p.parentElement; return p; };
  const own = new Map(nodes.map(n => [n, []]));
  const ownImgs = new Map(nodes.map(n => [n, []]));
  const shown = (el) => {
    if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
    const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0;
  };
  const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let t = tw.nextNode(); t; t = tw.nextNode()) {
    const s = t.nodeValue.replace(/\s+/g, " ").trim(); if (!s) continue;
    const pe = t.parentElement; if (!pe || ["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "TEXTAREA"].includes(pe.tagName)) continue;
    let p = pe; while (p && !set.has(p)) p = p.parentElement;
    if (p && shown(pe)) own.get(p).push(s);
  }
  const bare = (u) => { try { const x = new URL(u, location.href); return x.origin + x.pathname; } catch (_) { return null; } };
  for (const img of document.querySelectorAll("img")) { let p = img; while (p && !set.has(p)) p = p.parentElement; if (p) ownImgs.get(p).push(bare(img.currentSrc || img.src)); }
  const idx = new Map(nodes.map((n, i) => [n, i]));
  const sx = scrollX, sy = scrollY;
  const out = nodes.map((n, i) => {
    const r = n.getBoundingClientRect();
    const cs = getComputedStyle(n);
    const o = owner(n);
    const bg = cs.backgroundImage && cs.backgroundImage !== "none" ? (cs.backgroundImage.match(/url\("?([^")]+)"?\)/) || [])[1] : null;
    const rec = {
      i, id: idOf(n), type: typeOf(n), tag: n.tagName.toLowerCase(), parent: o ? idx.get(o) : null,
      visible: shown(n), box: [Math.round(r.left + sx), Math.round(r.top + sy), Math.round(r.width), Math.round(r.height)],
      text: own.get(n).join(" ").slice(0, 400), imgs: ownImgs.get(n).filter(Boolean).slice(0, 3).map(s => s.slice(0, 300)), bg: bg ? (bare(bg) || "").slice(0, 300) : null,
    };
    const inp = ["INPUT", "TEXTAREA"].includes(n.tagName) ? n : n.querySelector(":scope > input:not([type=hidden]):not([type=password]), :scope > textarea");
    if (inp) rec.placeholder = inp.placeholder || null;
    if (bubble) { try { const bi = n.bubble_data.bubble_instance; rec.bubble_visible = !!bi._is_visible; } catch (_) {} }
    else {
      const m = {};
      for (const a of ["data-bubble-placeholder", "data-bubble-dev-note", "data-bubble-visible", "data-bubble-lazy", "data-bubble-loaded"]) if (n.hasAttribute(a)) m[a.slice(12)] = n.getAttribute(a);
      if (n.hasAttribute("data-bubble-dev-marker") && n.title) m.title = n.title.slice(0, 300);
      if (Object.keys(m).length) rec.marker = m;
    }
    return rec;
  });
  return JSON.stringify({
    source: bubble ? "bubble" : "bubble_ex", path: location.pathname, width: innerWidth, height: innerHeight,
    scroll: [document.documentElement.scrollWidth, document.documentElement.scrollHeight], captured_at: new Date().toISOString(),
    elements: out,
  });
})()
