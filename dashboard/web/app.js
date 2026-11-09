/* Pursestrings dashboard ("Drawstring").
   Replay mode ("replay · recorded 09.11 · real txs") is the default and the only mode of the static build: it runs
   the recorded series of 09.11 from data.js (real testnet transactions), behind a visible label.
   Live mode exists only when the page is served by dashboard/server.py (mode.js then says PS_SERVER = true): every
   number comes from api/state (the server reads Base Sepolia, Unichain Sepolia and Lasna, read-only). Motion in live
   mode starts only on a new on-chain log (GrantSent, GrantApplied, Transfer out, StopPressed, Frozen, EpochAck):
   never on a timer.
   One dollars->px scale (K) per screen for the spool coil, the loops, the knots, the spent pieces and the coin.
   Red = counted cord only. The grey groove is the route and carries no budget. */
(function () {
  "use strict";
  const PS = window.PS;
  const $ = (id) => document.getElementById(id);
  const svg = $("fieldSvg");
  const NS = "http://www.w3.org/2000/svg";
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  const chains = PS.deployments.chains;          // rendered from deployments (N = 2)
  const TAU = Math.PI * 2;

  const fmt = (n) => "$" + n.toFixed(2);
  const short = (h) => h.slice(0, 6) + "…" + h.slice(-4);
  const explorer = (k) => k === "lasna" ? PS.deployments.lasna.explorer : chains.find((c) => c.key === k).explorer;
  const chainName = (k) => k === "lasna" ? "Lasna" : chains.find((c) => c.key === k).short;
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const f1 = (v) => (+v).toFixed(1);

  // cubic-bezier easing (CSS semantics), solved by bisection
  function bez(x1, y1, x2, y2) {
    const c = (a, b, u) => 3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u;
    return (t) => {
      if (t <= 0) return 0; if (t >= 1) return 1;
      let lo = 0, hi = 1, u = t;
      for (let i = 0; i < 22; i++) { u = (lo + hi) / 2; if (c(x1, x2, u) < t) lo = u; else hi = u; }
      return c(y1, y2, u);
    };
  }
  const E = { cinch: bez(.2, .9, .1, 1), cam: bez(.3, 0, .2, 1), travel: bez(.3, 0, .2, 1), grav: bez(.5, 0, .75, 0), hold: bez(.4, 0, 1, 1) };

  // ------------------------------------------------------------------ scene state
  let S = null;            // current scene (copy of a state, mutated by replays)
  let replay = null;       // running replay
  let geo = null;          // last layout
  // time-based animations, drawn by renderField on each frame
  const A = { cinch: {}, appear: {}, travel: null, pulse: null, coin: null, cam: null, piece: null, tag: null, rings: [] };
  let view = null;         // camera viewBox when zoomed (null = full field)
  let rafId = null;
  const SERVER = window.PS_SERVER === true;   // served by dashboard/server.py: live mode available
  let MODE = "replay";     // "live" | "replay"
  let LIVE = null;         // last snapshot from the server
  const capOf = () => (S && S.cap != null ? S.cap : PS.CAP);
  const paysAll = () => (S && S.payments) || PS.payments;

  function clone(o) { return JSON.parse(JSON.stringify(o)); }
  const now = () => performance.now();

  function clearAnims() {
    A.cinch = {}; A.appear = {}; A.travel = null; A.pulse = null; A.coin = null; A.cam = null; A.piece = null; A.tag = null; A.rings = []; view = null;
  }

  function setState(name, opts) {
    opts = opts || {};
    if (replay && !opts.fromReplay) stopReplay();
    setMode("replay");
    clearAnims();
    S = clone(PS.states[name]);
    S.name = name;
    S.receiptExtra = null;
    for (const c of chains) S.chains[c.key].frozenNow = S.chains[c.key].plate === "frozen";
    document.querySelectorAll(".debug [data-state]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.state === name)));
    markModes(null);
    if (!opts.fromReplay) {
      $("clock").hidden = true; $("skip").hidden = true;   // the replay label stays: a recorded state is never live
    }
    renderAll();
  }

  // ------------------------------------------------------------------ geometry helpers
  function spiral(cx, cy, r0, pitch, L, endAngle) {
    // Archimedean spiral of exact arc length L (px); its outer end points at endAngle.
    const b = pitch / TAU;
    const pts = [];
    let th = 0, len = 0;
    const dth = 0.04;
    pts.push([r0, 0]);
    while (len < L) {
      const r = r0 + b * th;
      const ds = Math.sqrt(r * r + b * b) * dth;
      if (len + ds > L) { th += dth * (L - len) / ds; len = L; } else { th += dth; len += ds; }
      pts.push([r0 + b * th, th]);
    }
    const rot = endAngle - th;
    const xy = pts.map(([r, t]) => [cx + r * Math.cos(t + rot), cy + r * Math.sin(t + rot)]);
    const d = xy.map((p, i) => (i ? "L" : "M") + p[0].toFixed(2) + " " + p[1].toFixed(2)).join("");
    return { d, end: xy[xy.length - 1], rOuter: r0 + b * th, len };
  }
  // outer radius of a spiral of length L without building it (same formula, for sizing the flange first)
  function spiralROuter(r0, pitch, L) {
    if (L <= 0) return r0;
    return spiral(0, 0, r0, pitch, L, 0).rOuter;
  }

  function el(tag, attrs, parent) {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) if (attrs[k] !== undefined && attrs[k] !== null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function fitRect(rect, t, padX) {
    const w = t.getComputedTextLength() + 2 * padX;
    rect.setAttribute("width", w.toFixed(1));
    return w;
  }
  function txt(x, y, s, cls, parent, anchor) {
    const t = el("text", { x: f1(x), y: f1(y), class: cls, "text-anchor": anchor || "start" }, parent);
    t.textContent = s;
    return t;
  }
  let probe = null;
  function pathLen(d) {
    if (!probe) { probe = document.createElementNS(NS, "path"); probe.setAttribute("fill", "none"); probe.setAttribute("stroke", "none"); probe.setAttribute("visibility", "hidden"); }
    if (!probe.isConnected) svg.appendChild(probe);
    probe.setAttribute("d", d);
    return probe.getTotalLength();
  }

  // Braided rope: soft shadow + dark edge + base + two staggered dash bands (braid) + sheen + (dark mode) top edge.
  function rope(d, w, parent, opts) {
    opts = opts || {};
    const g = el("g", { class: "rope" + (opts.cls ? " " + opts.cls : "") }, parent);
    const base = "var(--cord)", shade = "var(--cord-shade)", deep = "var(--cord-deep)", light = "var(--cord-light)";
    const cap = opts.cap || "round";
    const p = { d, fill: "none", "stroke-linecap": cap, "stroke-linejoin": "round" };
    el("path", Object.assign({}, p, { class: "rope-shadow", "stroke-width": w + 1, filter: "url(#soft)", transform: "translate(1.4 2.6)" }), g);
    const main = el("path", Object.assign({}, p, { stroke: deep, "stroke-width": w + 2 }), g);   // 1 px #8E230A edge each side (3:1 on the ground)
    el("path", Object.assign({}, p, { stroke: base, "stroke-width": w }), g);
    const dash = (w * 0.3).toFixed(2);
    el("path", Object.assign({}, p, { stroke: shade, "stroke-width": w * 0.92, "stroke-dasharray": dash + " " + dash, "stroke-linecap": "butt", opacity: 0.55 }), g);
    el("path", Object.assign({}, p, { stroke: base, "stroke-width": w * 0.5, "stroke-linecap": "butt" }), g);
    el("path", Object.assign({}, p, { stroke: shade, "stroke-width": w * 0.5, "stroke-dasharray": dash + " " + dash, "stroke-dashoffset": dash, "stroke-linecap": "butt", opacity: 0.55 }), g);
    el("path", Object.assign({}, p, { stroke: light, "stroke-width": Math.max(0.8, w * 0.16), opacity: 0.55, "stroke-dasharray": (w * 0.22).toFixed(2) + " " + (w * 0.38).toFixed(2), "stroke-linecap": "butt" }), g);
    el("path", Object.assign({}, p, { class: "rope-edge", stroke: light, "stroke-width": 1, transform: "translate(0 " + (-w * 0.38).toFixed(2) + ")" }), g);
    g._main = main;
    return g;
  }

  // A cut length of cord lying horizontally in the tray: shaded across its width, braid drawn as chevrons.
  function hpiece(x, y, len, w, parent, defs, id) {
    const g = el("g", {}, parent);
    if (!defs.querySelector("#acrossV")) {
      const ag = el("linearGradient", { id: "acrossV", x1: "0", y1: "0", x2: "0", y2: "1" }, defs);
      [["0", "var(--cord-deep)"], [".28", "var(--cord)"], [".45", "var(--cord-light)"], [".62", "var(--cord)"], ["1", "var(--cord-deep)"]]
        .forEach(([o, c]) => el("stop", { offset: o, "stop-color": c }, ag));
    }
    const ph = w * 0.62;
    const pat = el("pattern", { id, width: ph, height: w, patternUnits: "userSpaceOnUse", x, y }, defs);
    el("rect", { width: ph, height: w, fill: "url(#acrossV)" }, pat);
    el("path", { d: "M0 0L" + ph + " " + w / 2 + "L0 " + w, stroke: "var(--cord-shade)", "stroke-width": 0.9, opacity: 0.75, fill: "none" }, pat);
    el("rect", { x: x + 1.2, y: y + 2, width: len, height: w, class: "piece-shadow", filter: "url(#soft)" }, g);
    el("rect", { x, y, width: len, height: w, fill: "url(#" + id + ")", rx: 1, stroke: "var(--cord-deep)", "stroke-width": 1 }, g);
    el("rect", { x, y, width: 1.6, height: w, fill: "var(--cord-deep)", opacity: 0.7 }, g); // cut ends
    el("rect", { x: x + len - 1.6, y, width: 1.6, height: w, fill: "var(--cord-deep)", opacity: 0.7 }, g);
    return g;
  }

  // Loop / cinch / knot: ONE path whose length is always L (= dollars × K).
  // A ring of radius r centred on the mouth, pinched at its bottom. Two tails leave the pinch toward the mouth's two
  // groove notches (where the route enters and leaves the eyelet) and, past a notch, run on along the groove, pulled
  // taut: the drawstring's ends. length = 2πr + core (≈6 px across the pinch) + 2 × tail, so tail = (L − 2πr − core) / 2.
  const CORE = 6;
  function knotPath(m, L, r, R, dirs) {
    const tail = Math.max(0, (L - TAU * r - CORE) / 2);
    const py = m.y - r;                                    // pinch at the top of the ring; the ring hangs below the string
    const n0 = 72, py0 = (py + r) - r * (Math.PI / n0) / Math.sin(Math.PI / n0);   // the 72-gon's top vertex
    const tailPts = (sx, dir) => {
      const nx = m.x + dir[0] * R, ny = m.y + dir[1] * R;
      const dx = nx - sx, dy = ny - py, seg = Math.hypot(dx, dy);
      if (tail <= seg) return [[sx + dx * tail / seg, py + dy * tail / seg]];
      const rest = tail - seg;
      return [[nx, ny], [nx + dir[0] * rest, ny + dir[1] * rest]];
    };
    const pt = (p) => p[0].toFixed(2) + " " + p[1].toFixed(2);
    const a = tailPts(m.x - 3, dirs[0]).reverse(), b = tailPts(m.x + 3, dirs[1]);
    let d = "M" + a.map(pt).join("L");
    d += "L" + (m.x - 3) + " " + py.toFixed(3) + "L" + m.x + " " + (r > 0 ? py0 : py).toFixed(3);
    if (r > 0) {
      // the ring as a 72-gon whose perimeter is exactly 2πr (radius compensated), so its length is checkable
      const n = 72, rr = r * (Math.PI / n) / Math.sin(Math.PI / n), cy = py + r;
      for (let k = 1; k <= n; k++) {
        const t = -Math.PI / 2 + k * TAU / n;              // start at the top (the pinch), go round
        d += "L" + (m.x + rr * Math.cos(t)).toFixed(3) + " " + (cy + rr * Math.sin(t)).toFixed(3);
      }
    }
    d += "L" + (m.x + 3) + " " + py.toFixed(3) + "L" + b.map(pt).join("L");
    return d;
  }

  // ------------------------------------------------------------------ layout
  const paysOn = (key) => paysAll().slice(0, S.spentUpTo).filter((p) => p.chain === key);
  function layout() {
    const W = Math.max(300, Math.floor(svg.getBoundingClientRect().width));
    const mobile = W < 520;
    const g = { mobile, W };
    if (mobile) {
      g.K = 42; g.R = 34; g.rope = 7; g.pitch = 9.1;
      g.spool = { x: 82, y: 86 };
      g.ww = W - 30;
      g.colW = W;
      let y = 226, lastBottom = 0;
      g.mouths = chains.map((c) => {
        const m = { key: c.key, x: 82, y };
        const rows = Math.max(paysOn(c.key).length, 1);
        lastBottom = y + 177 + rows * 11;
        y += 274 + rows * 11;
        return m;
      });
      g.gx = 18;                                          // gutter for the groove between mouths
      g.tape = { x: 4, y0: 20, y1: 20 + 20 * g.K };
      g.H = Math.max(lastBottom, g.tape.y1 + 16) + 84;
      return g;
    }
    g.K = Math.min(84, Math.floor((W - 32) / 10));
    g.R = 42; g.rope = 8; g.pitch = 10.4;
    g.spool = { x: 100, y: 140 };
    const x0 = 244, x1 = W - 6;
    g.colW = (x1 - x0) / chains.length;
    g.narrow = g.colW < 300;
    g.ww = Math.min(230, g.colW - 24);
    g.mouths = chains.map((c, i) => ({ key: c.key, x: x0 + g.colW * (i + 0.5), y: 140 }));
    g.ruler = { x0: 26, x1: 26 + 10 * g.K, y: 552, gap: 30 };
    g.H = 606;
    return g;
  }

  function fullView() { return { x: 0, y: 0, w: geo.W, h: geo.H }; }
  function fitBox(b, maxZ) {
    // expand a box to the field's aspect ratio, cap the zoom (×2.2 default), keep it inside the field
    const cap = maxZ || 2.2;
    const a = geo.W / geo.H;
    let { x, y, w, h } = b;
    if (w / h > a) { const nh = w / a; y -= (nh - h) / 2; h = nh; } else { const nw = h * a; x -= (nw - w) / 2; w = nw; }
    if (geo.W / w > cap) { const nw = geo.W / cap, nh = nw / a; x -= (nw - w) / 2; y -= (nh - h) / 2; w = nw; h = nh; }
    x = Math.max(0, Math.min(x, geo.W - w)); y = Math.max(0, Math.min(y, geo.H - h));
    return { x, y, w, h };
  }
  function camBox(name) {
    const g = geo, R = g.R;
    const zm = name.match(/@([\d.]+)$/);
    const z = zm ? +zm[1] : null;
    name = name.replace(/@[\d.]+$/, "");
    const fit = (b) => fitBox(b, z);
    const mo = (k) => g.mouths.find((m) => m.key === k);
    if (name === "full") return fullView();
    if (g.mobile) {
      if (name === "spool+base" || name === "spool") { const m = mo("base"); return fitBox({ x: 0, y: 10, w: g.W, h: m.y + R + 210 }); }
      const m = mo(name.split(":")[1] || "base");
      return fitBox({ x: 0, y: m.y - R - 70, w: g.W, h: 300 });
    }
    if (name.startsWith("mouth:")) { const m = mo(name.slice(6)); return fit({ x: m.x - 150, y: m.y - R - 70, w: 300, h: 2 * R + 190 }); }
    if (name === "spool") { const sp = g.spool; return fit({ x: sp.x - 100, y: sp.y - 110, w: 360, h: 300 }); }
    if (name === "spool+base") { const m = mo("base"); return fit({ x: 0, y: 20, w: m.x + R + 70, h: 400 }); }
    if (name === "row") { const m = mo(chains[chains.length - 1].key); return fitBox({ x: 0, y: 30, w: m.x + R + 60, h: 300 }); }
    return fullView();
  }
  function currentView() {
    if (A.cam) {
      const p = Math.min(1, (now() - A.cam.t0) / A.cam.ms), e = E.cam(p);
      const v = {}; ["x", "y", "w", "h"].forEach((k) => v[k] = A.cam.from[k] + (A.cam.to[k] - A.cam.from[k]) * e);
      if (p >= 1) { view = A.cam.full ? null : A.cam.to; A.cam = null; }
      return v;
    }
    return view || fullView();
  }
  const lerpBox = (a, b, e) => { const v = {}; ["x", "y", "w", "h"].forEach((k) => v[k] = a[k] + (b[k] - a[k]) * e); return v; };
  function zoomTo(name, ms) {
    if (reduce.matches || !geo) return;
    const to = camBox(name);
    A.cam = { from: currentView(), to, t0: now(), ms, full: name === "full" };
    kick();
  }

  // ------------------------------------------------------------------ render: field
  function renderField() {
    const g = geo = layout();
    const K = g.K, R = g.R;
    const tNow = now();
    svg.innerHTML = "";
    probe = null;
    const v = currentView();
    svg.setAttribute("viewBox", [v.x, v.y, v.w, v.h].map(f1).join(" "));
    svg.style.height = g.H + "px";
    const zoom = g.W / v.w;
    const cc = $("camChip");
    cc.hidden = false;
    cc.style.visibility = zoom < 1.05 ? "hidden" : "visible";   // space reserved: no layout jump when the camera moves
    cc.textContent = "view ×" + zoom.toFixed(1) + " · same scale, closer";

    const defs = el("defs", {}, svg);
    const f = el("filter", { id: "soft", x: "-20%", y: "-20%", width: "140%", height: "140%" }, defs);
    el("feGaussianBlur", { stdDeviation: "1.8" }, f);
    const lg = el("radialGradient", { id: "metal", cx: "38%", cy: "32%", r: "75%" }, defs);
    el("stop", { offset: "0", "stop-color": "var(--metal-1)" }, lg);
    el("stop", { offset: "1", "stop-color": "var(--metal-2)" }, lg);
    const eg = el("linearGradient", { id: "eyeletG", x1: "0", y1: "0", x2: "1", y2: "1" }, defs);
    el("stop", { offset: "0", "stop-color": "#4A5058" }, eg);
    el("stop", { offset: ".5", "stop-color": "var(--eyelet)" }, eg);
    el("stop", { offset: "1", "stop-color": "#000" }, eg);

    const layer = { groove: el("g", {}, svg), base: el("g", {}, svg), cord: el("g", {}, svg), top: el("g", {}, svg), fx: el("g", {}, svg) };

    // ---- spool (Lasna coordinator): flange sized from the coil, coil = reserve × K
    const sp = g.spool;
    const reserveL = S.reserve * K;
    const rOut = spiralROuter(16, g.pitch, reserveL);
    const flangeR = Math.max(g.mobile ? 56 : 64, Math.min(g.mobile ? 72 : 96, rOut + 14));
    g.flangeR = flangeR;
    el("circle", { cx: sp.x + 1.5, cy: sp.y + 3, r: flangeR + 1, class: "drop", filter: "url(#soft)" }, layer.base);
    el("circle", { cx: sp.x, cy: sp.y, r: flangeR, fill: S.paused ? "var(--ground-deep)" : "url(#metal)", class: "flange" }, layer.base);
    el("circle", { cx: sp.x, cy: sp.y, r: flangeR - 2, class: "flange-rim" }, layer.base);
    // engraved rim text
    const er = flangeR - 9;
    const ep = el("path", { id: "engr", d: "M" + sp.x + " " + (sp.y - er) + "A" + er + " " + er + " 0 1 1 " + sp.x + " " + (sp.y + er) + "A" + er + " " + er + " 0 1 1 " + sp.x + " " + (sp.y - er) }, defs);
    void ep;
    const unit = "REACTIVE COORDINATOR · LASNA · ";
    const engr = TAU * er > 470 ? unit + unit : unit;
    [["engr-hi", "translate(0 1)"], ["engr", null]].forEach(([cls, tr]) => {
      const t = el("text", { class: cls, transform: tr }, layer.base);
      const tp = el("textPath", { href: "#engr", startOffset: "0" }, t);
      tp.textContent = engr;
    });
    // core: hub + 3 spokes
    el("circle", { cx: sp.x, cy: sp.y, r: 15, class: "hub" }, layer.base);
    for (let k = 0; k < 3; k++) {
      const a = k * TAU / 3 - Math.PI / 2;
      el("line", { x1: f1(sp.x + 5 * Math.cos(a)), y1: f1(sp.y + 5 * Math.sin(a)), x2: f1(sp.x + 14 * Math.cos(a)), y2: f1(sp.y + 14 * Math.sin(a)), class: "spoke" }, layer.base);
    }
    el("circle", { cx: sp.x, cy: sp.y, r: 4.5, fill: "var(--eyelet)" }, layer.base);
    const endAngle = g.mobile ? Math.PI / 2 : -0.1;
    let threadStart;
    if (reserveL > 0) {
      const coil = spiral(sp.x, sp.y, 16, g.pitch, reserveL, endAngle);
      rope(coil.d, g.rope, layer.cord, { cls: "coil" });
      threadStart = coil.end;
    } else {
      threadStart = [sp.x + flangeR * Math.cos(endAngle), sp.y + flangeR * Math.sin(endAngle)];
    }
    if (S.paused) {
      const cg = el("g", {}, layer.top);
      el("rect", { x: sp.x - flangeR - 8, y: sp.y - 7, width: 2 * flangeR + 16, height: 14, rx: 3, class: "clamp", transform: "rotate(-18 " + sp.x + " " + sp.y + ")" }, cg);
    }
    const sl = g.mobile ? { x: sp.x + flangeR + 16, y: sp.y - 22, a: "start" } : { x: sp.x, y: sp.y + flangeR + 24, a: "middle" };
    txt(sl.x, sl.y, "Lasna · Reactive", "t-label", layer.top, sl.a);
    txt(sl.x, sl.y + 18, "reserve " + fmt(S.reserve) + " · epoch " + (S.spoolEpoch != null ? S.spoolEpoch : S.epoch), "t-mono", layer.top, sl.a);
    let sy = sl.y + 34;
    if (S.reserve === 0) { txt(sl.x, sy, S.dayClosed ? "today's day not opened yet" : "all cord granted out", "t-small t-ink3", layer.top, sl.a); sy += 15; }
    if (S.paused) {
      ["coordinator paused", "nothing can overspend", "one lREACT deposit resumes"].forEach((s, i) => txt(sl.x, sy + 4 + i * 15, s, i ? "t-small" : "t-mono", layer.top, sl.a));
    }

    // ---- groove: the route only (grey, debossed). Carries no budget; red = counted cord only.
    const ms = g.mouths;
    let drawD, fullD;
    const entry = [];                 // path distance at which each mouth is entered
    if (!g.mobile) {
      const sag = 14;
      let a = threadStart;
      drawD = "M" + f1(a[0]) + " " + f1(a[1]);
      fullD = drawD;
      ms.forEach((m, i) => {
        const b = [m.x - R, m.y];
        const c = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + sag];
        const q = "Q" + f1(c[0]) + " " + f1(c[1]) + " " + f1(b[0]) + " " + f1(b[1]);
        drawD += q; fullD += q;
        entry[i] = pathLen(fullD);
        if (i < ms.length - 1) { drawD += "M" + (m.x + R) + " " + m.y; fullD += "L" + (m.x + R) + " " + m.y; a = [m.x + R, m.y]; }
      });
    } else {
      const gx = g.gx;
      const m0 = ms[0];
      drawD = "M" + f1(threadStart[0]) + " " + f1(threadStart[1]) + "L" + m0.x + " " + (m0.y - R);
      fullD = drawD;
      entry[0] = pathLen(fullD);
      for (let i = 1; i < ms.length; i++) {
        const p = ms[i - 1], n = ms[i];
        const seg = "L" + (p.x - R) + " " + p.y + "L" + gx + " " + p.y + "L" + gx + " " + n.y + "L" + (n.x - R) + " " + n.y;
        drawD += "M" + (p.x - R) + " " + p.y + seg.slice(seg.indexOf("L", 1));
        fullD += "L" + p.x + " " + p.y + seg;
        entry[i] = pathLen(fullD);
      }
    }
    el("path", { d: drawD, class: "groove-d" }, layer.groove);
    el("path", { d: drawD, class: "groove-l", transform: "translate(0 1.5)" }, layer.groove);
    // notches where the groove meets each eyelet
    ms.forEach((m, i) => {
      const pts = g.mobile ? (i === 0 ? [[m.x, m.y - R], [m.x - R, m.y]] : [[m.x - R, m.y]])
        : (i < ms.length - 1 ? [[m.x - R, m.y], [m.x + R, m.y]] : [[m.x - R, m.y]]);
      pts.forEach(([x, y]) => el("circle", { cx: x, cy: y, r: 4.5, class: "notch" }, layer.groove));
    });
    const routeEl = el("path", { d: fullD, fill: "none", stroke: "none" }, defs);
    g.routeD = fullD;
    g.route = { el: routeEl, entry, total: routeEl.getTotalLength() };

    // ---- mouths
    ms.forEach((m, i) => {
      const c = chains[i];
      const st = S.chains[c.key];
      const rightCol = g.mobile ? m.x + R + 26 : null;

      // agent chip (answers "where are the agents"); the waiting coin hangs under it
      const cg = el("g", { class: "chipsvg" }, layer.top);
      const lines = !g.mobile && !g.narrow ? ["agent · pays per call on " + c.short] : ["agent", "pays per call on " + c.short];
      const chH = 10 + lines.length * 14;
      const chip = g.mobile ? { x: rightCol, y: m.y - R - 46 } : { x: m.x, y: m.y - R - 74 - (lines.length - 1) * 14 };
      const crect = el("rect", { x: chip.x, y: chip.y, width: 10, height: chH, rx: 4 }, cg);
      let wmax = 0;
      const tl = lines.map((s, k) => { const t = txt(chip.x + 9, chip.y + 16 + k * 14, s, "", cg); wmax = Math.max(wmax, t.getComputedTextLength()); return t; });
      const cw = wmax + 18;
      crect.setAttribute("width", f1(cw));
      if (!g.mobile) { crect.setAttribute("x", f1(m.x - cw / 2)); tl.forEach((t) => t.setAttribute("x", f1(m.x - cw / 2 + 9))); }
      if (!g.mobile) el("line", { x1: m.x, y1: chip.y + chH, x2: m.x, y2: m.y - R - 8, class: "lead" }, layer.base);

      // mouth: drop shadow, fabric inside, gathered pleats, eyelet ring + rivets
      el("circle", { cx: m.x + 1.5, cy: m.y + 3, r: R + 6, class: "drop", filter: "url(#soft)" }, layer.base);
      el("circle", { cx: m.x, cy: m.y, r: R - 4, class: "mouth-in" }, layer.base);

      // cord in this mouth: open loop, a cinch in progress, or a knot. One path of length L = $ × K.
      const ci = A.cinch[c.key];
      let L = 0, r = 0, cinchT = 0;
      let rk = g.rope * 0.95;                             // radius of the closed knot's ring
      if (st.knot > 0) {
        L = st.knot * K;
        const r0 = (L - CORE) / TAU;
        rk = Math.min(rk, r0 * 0.55);                     // a short knot keeps some tail; length is never exceeded
        if (ci && !reduce.matches) {
          const el_ = tNow - ci.t0;
          if (el_ < 0) { cinchT = 0; r = r0; }               // camera still arriving: the loop is about to close
          else if (el_ < 360) { cinchT = E.cinch(el_ / 360); r = rk + (r0 - rk) * (1 - cinchT); }
          else if (el_ < 440) { cinchT = 1; r = rk * (1 - 0.14 * Math.sin(Math.PI * (el_ - 360) / 80)); }
          else { cinchT = 1; r = rk; delete A.cinch[c.key]; }
        } else { cinchT = 1; r = rk; }
      } else if (st.loop > 0) {
        L = st.loop * K;
        r = (L - CORE) / TAU;
      }
      let hank = false;
      if (L > 0 && r > R - 10) { r = R - 10; hank = true; }   // clamp: the excess hangs below the mouth as a hank, same length

      // pleats: 24 fabric lines from the rim to the loop radius; they gather as the cord closes
      const rp = L > 0 ? r : R - 18;
      const twist = (10 + 14 * cinchT) * Math.PI / 180;
      const pg = el("g", { class: "pleats" }, layer.base);
      for (let k = 0; k < 24; k++) {
        const a0 = k * TAU / 24;
        const a1 = a0 + twist;
        const ro = R - 6, ri = Math.min(ro - 4, rp + 3 + (k % 2 ? (ro - rp) * 0.35 * (1 - cinchT) : 0));
        const p0 = [m.x + ro * Math.cos(a0), m.y + ro * Math.sin(a0)];
        const p1 = [m.x + ri * Math.cos(a1), m.y + ri * Math.sin(a1)];
        const am = (a0 + a1) / 2 + 0.08 * (0.3 + cinchT), rm = (ro + ri) / 2;
        el("path", { d: "M" + f1(p0[0]) + " " + f1(p0[1]) + "Q" + f1(m.x + rm * Math.cos(am)) + " " + f1(m.y + rm * Math.sin(am)) + " " + f1(p1[0]) + " " + f1(p1[1]) }, pg);
      }
      el("circle", { cx: m.x, cy: m.y, r: R, fill: "none", stroke: "url(#eyeletG)", "stroke-width": 10 }, layer.base);
      el("circle", { cx: m.x, cy: m.y, r: R + 5, class: "eyelet-rim" }, layer.base);
      for (let k = 0; k < 10; k++) {
        const a = (k / 10) * TAU + Math.PI / 10;
        el("circle", { cx: f1(m.x + R * Math.cos(a)), cy: f1(m.y + R * Math.sin(a)), r: 2.4, class: "rivet" }, layer.base);
      }

      if (L > 0) {
        // the groove meets this mouth here (desktop: left + right; phone: left + top for the first mouth)
        const dirs = g.mobile && i === 0 ? [[-1, 0], [0, -1]] : [[-1, 0], [1, 0]];
        let d = knotPath(m, L, r, R, dirs);
        if (hank) {
          const extra = L - pathLen(d);
          d += "L" + f1(m.x + 3) + " " + f1(m.y + r + 18 + extra);   // hanging hank (excess length, straight)
        }
        const kg = rope(d, Math.min(g.rope, Math.max(4, r * 0.9 + (st.knot ? 3 : 0))), layer.cord, { cls: st.knot ? "knot" : "loop" });
        kg.dataset.chain = c.key;
        const got = kg._main.getTotalLength();
        console.assert(Math.abs(got - L) < 1, "cord length not conserved", c.key, got, L);
        if (st.knot > 0 && cinchT > 0.75) {
          // overhand crossing marks on the closed ring (shading only, not extra cord)
          const o = Math.min(1, (cinchT - 0.75) / 0.25);
          const py = m.y + r;
          el("path", { d: "M" + f1(m.x - r * 1.1) + " " + f1(py - r * 1.6) + "Q" + m.x + " " + f1(py - r * 0.2) + " " + f1(m.x + r * 1.1) + " " + f1(py - r * 1.7), class: "knot-mark", opacity: o.toFixed(2) }, layer.cord);
          el("path", { d: "M" + f1(m.x - r * 0.9) + " " + f1(py - r * 0.3) + "Q" + m.x + " " + f1(py - r * 1.5) + " " + f1(m.x + r * 0.9) + " " + f1(py - r * 0.25), class: "knot-mark", opacity: (o * 0.8).toFixed(2) }, layer.cord);
        }
        const ap = A.appear[c.key];
        if (ap) {
          const p = Math.min(1, (tNow - ap) / 160);
          kg.setAttribute("opacity", p.toFixed(2));
          if (p >= 1) delete A.appear[c.key];
        }
      }

      // waiting coin (the agent's payment on THIS chain; its circumference = price × K)
      if (st.coin) {
        const cr = st.coin * K / TAU;
        let cx = m.x, cy;
        if (g.mobile) cy = m.y - R - 12 - cr;
        else if (cr > 22) { cx = m.x - R - 16 - cr; cy = m.y - 30; }    // too big to hang above: waits beside the mouth
        else cy = m.y - R - 12 - cr;
        let dy = 0, op = 1;
        if (A.coin && A.coin.chain === c.key) {
          const p = Math.min(1, (tNow - A.coin.t0) / 260);
          dy = (m.y - cy) * E.grav(p); op = 1 - p;
        }
        const coinG = el("g", { class: "coinG", opacity: op.toFixed(2), transform: "translate(0 " + f1(dy) + ")" }, layer.top);
        el("circle", { cx: cx + 1, cy: cy + 2, r: cr + 1, class: "drop", filter: "url(#soft)" }, coinG);
        el("circle", { cx, cy, r: cr, class: "coin" }, coinG);
        const big = !g.mobile && cr > 22;
        const tagX = big ? cx : cx + cr + 10, tagY = big ? cy + cr + 16 : cy - 2, ta = big ? "middle" : "start";
        txt(tagX, tagY, fmt(st.coin) + " call", "coin-tag", coinG, ta);
        txt(tagX, tagY + 14, st.coinNote || (st.plate === "red" ? "can't fit" : st.loop >= st.coin ? "fits · agent retries" : "waiting at the mouth"), "t-small", coinG, ta);
      }

      // name + state plate + one caption
      const lblX = g.mobile ? rightCol : m.x;
      const lblY = g.mobile ? m.y + 4 : m.y + R + 38;
      const anchor = g.mobile ? "start" : "middle";
      txt(lblX, lblY, c.name, "t-label", layer.top, anchor);
      // while the knot is visibly closing, the plate and caption swap together with the picture (at 75 % of the cinch)
      const closing = st.knot > 0 && cinchT < 0.75;
      const plateKey = closing ? "open" : st.plate;
      const plateTxt = { open: "open", amber: amberPlate(st), red: "cap reached · 402", frozen: "frozen · epoch " + (st.epochNow != null ? st.epochNow : S.epoch), held: "waiting · coordinator paused" }[plateKey];
      const pgp = el("g", { class: "plate plate-" + plateKey }, layer.top);
      const prect = el("rect", { x: lblX, y: lblY + 8, width: 10, height: 22 }, pgp);
      const ptext = txt(lblX + 9, lblY + 23, plateTxt, "", pgp);
      const pw = fitRect(prect, ptext, 9);
      if (!g.mobile) { prect.setAttribute("x", f1(m.x - pw / 2)); ptext.setAttribute("x", f1(m.x - pw / 2 + 9)); }
      let cap;
      if (st.plate === "amber") cap = "money is there (" + fmt(st.wallet) + ") · permission isn't (" + fmt(st.loop) + ")";
      else if (closing) cap = "loop " + fmt(st.knot) + " · closing";
      else if (st.knot > 0 && st.knotNote) cap = fmt(st.knot) + " " + st.knotNote;
      else if (st.knot > 0) cap = fmt(st.knot) + " held in the knot";
      else if (st.loop > 0 && st.hiddenPending > 0) cap = "loop " + fmt(st.loop) + " · +" + fmt(st.hiddenPending) + " returning";
      else if (st.loop > 0) cap = "loop " + fmt(st.loop) + (g.narrow || g.mobile ? " · can spend" : " can still be spent here");
      else cap = "loop $0.00 · eyelets stay";
      const capT = txt(lblX, lblY + 46, cap, st.plate === "amber" ? "t-mono t-amber" : "t-small", layer.top, anchor);
      if (!g.mobile && capT.getComputedTextLength() > g.colW - 8) {   // amber line on narrow columns: two lines
        capT.textContent = "money is there (" + fmt(st.wallet) + ")";
        txt(lblX, lblY + 60, "permission isn't (" + fmt(st.loop) + ")", "t-mono t-amber", layer.top, anchor);
      }

      // money well: flat, inset, not interactive
      const ww = g.ww, wh = 50;
      const wx = g.mobile ? 30 : m.x - ww / 2;
      const wy = g.mobile ? m.y + R + 34 : lblY + 62;
      const wg = el("g", {}, layer.base);
      el("title", {}, wg).textContent = "money on " + c.name + ": vault " + fmt(st.vault) + " · agent wallet " + fmt(st.wallet) + " · it never leaves this chain" + (S.live ? " · token balanceOf at head" : "");
      el("rect", { x: wx, y: wy, width: ww, height: wh, class: "well" }, wg);
      el("rect", { x: wx + 0.5, y: wy + 0.5, width: ww - 1, height: wh - 1, class: "well-edge" }, wg);
      el("rect", { x: wx + 6, y: wy + 6, width: ww - 12, height: wh - 12, class: "block" }, wg);
      txt(wx + 16, wy + 23, "money on " + c.short, "t-money-s", layer.top);
      txt(wx + 16, wy + 37, "stays here", "t-money-s", layer.top);
      txt(wx + ww - 16, wy + 32, fmt(st.money), "t-money", layer.top, "end");
      txt(wx, wy + wh + 13, "vault " + fmt(st.vault) + " · wallet " + fmt(st.wallet), "t-tiny", layer.top);
      m.well = { x: wx, y: wy, w: ww, h: wh };

      // spent tray: one horizontal cut length per real payment on THIS chain, length = usd × K
      const pays = paysOn(c.key);
      const tray = { x: wx, y: wy + wh + 30, w: ww };
      const tg = el("g", { class: "tray" }, layer.base);
      el("line", { x1: tray.x, y1: tray.y, x2: tray.x + tray.w, y2: tray.y, class: "tray-edge" }, tg);
      const tickMax = Math.max(2, Math.ceil(pays.reduce((a, p) => Math.max(a, p.usd), 0))) + 1;
      for (let k = 0; k <= tickMax && k * K <= tray.w + 0.5; k++) {
        const x = tray.x + k * K;
        el("line", { x1: x, y1: tray.y - 4, x2: x, y2: tray.y + 2, class: "tray-tick" }, tg);
        if (k > 0) txt(x - 3, tray.y - 5, "$" + k, "t-tick", tg, "end");
      }
      pays.forEach((p, j) => {
        const a = el("a", { href: explorer(p.chain) + p.tx, target: "_blank", rel: "noopener" }, layer.cord);
        el("title", {}, a).textContent = "payment " + (paysAll().indexOf(p) + 1) + " · " + fmt(p.usd) + " · " + c.name + " · " + p.utc + " UTC · block " + p.block + " · " + p.tx + (S.live ? " · token Transfer log" : "");
        const pgx = hpiece(tray.x, tray.y + 5 + j * 11, p.usd * K, g.mobile ? 7 : 8, a, defs, "pc" + c.key + j);
        if (A.piece && A.piece.tx === p.tx) {
          const pr = Math.min(1, (tNow - A.piece.t0) / 260);
          pgx.setAttribute("opacity", pr.toFixed(2));
          if (pr >= 1) A.piece = null;
        }
      });
      const sum = pays.reduce((s, p) => s + p.usd, 0);
      const tEnd = tray.y + 5 + Math.max(pays.length, 1) * 11 + 14;
      txt(tray.x, tEnd, "spent " + fmt(sum) + (pays.length ? " · " + pays.length + " payment" + (pays.length > 1 ? "s" : "") : " · no payments"), "t-mono", layer.top);
      el("title", {}, layer.top.lastChild).textContent = "spent on " + c.name + ": one piece per real payment, length = amount × K";
    });

    // ---- ruler / tape: Σ reserve + loops + knots + pieces = cap, at the same K
    const seg = [["reserve", S.reserve]];
    chains.forEach((c) => { const st = S.chains[c.key]; seg.push([c.short + (st.knot ? " knot" : " loop"), st.loop + (st.knot || 0) + (st.hiddenPending || 0)]); });
    chains.forEach((c) => { const st = S.chains[c.key]; if (st.inflight > 0) seg.push(["in flight → " + c.short, st.inflight]); });
    chains.forEach((c) => seg.push(["spent " + c.short, paysOn(c.key).reduce((a, p) => a + p.usd, 0)]));
    const total = seg.reduce((a, s) => a + s[1], 0);
    const books = Math.abs(total - capOf()) > 0.005;
    if (books && !S.live) console.error("cord invariant broken", seg, total);
    if (books && S.live && S.ready) console.warn("live books: tape total differs from today's cap", seg, total, capOf());
    const rl = el("g", {}, layer.top);
    if (!g.mobile) {
      const { x0, y, gap } = g.ruler;
      const half = 10 * K;
      const rows = [y, y + gap];
      rows.forEach((ry, k) => {
        el("line", { x1: x0, y1: ry, x2: x0 + half, y2: ry, class: "ruler-line" }, rl);
        txt(x0 - 4, ry + 3, k ? "$10" : "$0", "t-tick", rl, "end");
      });
      // a position p (dollars) maps to row floor(p/10), x = x0 + (p mod 10)·K
      const pos = (p) => { const r = p >= 10 ? 1 : 0; return [x0 + (p - 10 * r) * K, rows[r]]; };
      const labs = [[], []];
      let p = 0;
      const tick = (q, big) => { const [x, ry] = pos(Math.min(q, 19.9999)); const xx = q >= 20 ? x0 + half : x; el("line", { x1: xx, y1: ry - (big ? 6 : 3), x2: xx, y2: ry + (big ? 6 : 3), class: big ? "ruler-tick" : "ruler-minor" }, rl); };
      for (let q = 0; q <= 20; q++) tick(q, false);
      tick(0, true);
      seg.forEach(([name, val]) => {
        if (val <= 0) return;
        const a = p, b = p + val;
        tick(b, true);
        // a segment crossing $10 is drawn in two parts with the same label
        const parts = a < 10 && b > 10 ? [[a, 10], [10, b]] : [[a, b]];
        parts.forEach(([pa]) => {
          const r = pa >= 10 ? 1 : 0;
          const [x, ry] = pos(pa);
          const t = txt(x + 2, ry + 15, name + " " + fmt(val), "t-small", rl);
          labs[r].push({ t, start: x + 2, w: t.getComputedTextLength() });
        });
        p = b;
      });
      labs.forEach((row) => {
        let end = -1e9;
        row.forEach((l) => { l.x = Math.max(l.start, end + 12); end = l.x + l.w; });
        let limit = x0 + half;
        for (let i = row.length - 1; i >= 0; i--) { const l = row[i]; if (l.x + l.w > limit) l.x = limit - l.w; limit = l.x - 12; }
        row.forEach((l) => l.t.setAttribute("x", l.x.toFixed(1)));
      });
      txt(x0, y - 14, "tape, folded in two · $1 = " + K + " px of cord on this screen", "t-small", rl);
      txt(x0 + half, y - 14, books ? "= " + fmt(total) + " of cord · cap " + fmt(capOf()) + " (books catching up)" : "= " + fmt(total) + " of cord (today's cap)", "t-mono", rl, "end");
    } else {
      const { x, y0 } = g.tape;
      let yy = y0;
      for (let q = 0; q <= 20; q++) el("line", { x1: x, y1: y0 + q * K, x2: x + 5, y2: y0 + q * K, class: "ruler-minor" }, rl);
      el("line", { x1: x, y1: yy, x2: x + 9, y2: yy, class: "ruler-tick" }, rl);
      seg.forEach(([, val]) => { if (val <= 0) return; yy += val * K; el("line", { x1: x, y1: yy, x2: x + 9, y2: yy, class: "ruler-tick" }, rl); });
      const lines = seg.filter((s) => s[1] > 0).map((s) => s[0] + " " + fmt(s[1]));
      const rows = [];
      for (let i = 0; i < lines.length; i += 2) rows.push(lines.slice(i, i + 2).join(" · "));
      let ty = g.H - 20 - rows.length * 15;
      txt(30, ty, "tape = " + fmt(total) + " of cord · $1 = " + K + " px on this screen", "t-mono", rl);
      txt(30, ty + 15, "ticks on the left edge, $1 each", "t-small", rl);
      rows.forEach((r) => { ty += 15; txt(30, ty + 15, r, "t-small", rl); });
    }

    // ---- effects: travel (outlined length in flight), STOP pulse (outlined band)
    const sample = (s0, s1, n) => {
      const pts = [];
      const lo = Math.max(0, s0), hi = Math.min(g.route.total, s1);
      if (hi <= lo) return null;
      for (let k = 0; k <= n; k++) { const pt = g.route.el.getPointAtLength(lo + (hi - lo) * k / n); pts.push(pt); }
      return pts;
    };
    const insideMouth = (pt) => ms.some((m) => Math.hypot(pt.x - m.x, pt.y - m.y) < R - 1);
    const drawOutline = (pts, wOut, wIn, cls) => {
      // split where the route passes under an eyelet
      let cur = [];
      const flush = () => {
        if (cur.length > 1) {
          const d = cur.map((p, k) => (k ? "L" : "M") + f1(p.x) + " " + f1(p.y)).join("");
          el("path", { d, class: cls + "-out", "stroke-width": wOut }, layer.fx);
          el("path", { d, class: cls + "-in", "stroke-width": wIn }, layer.fx);
        }
        cur = [];
      };
      pts.forEach((p) => { if (insideMouth(p)) flush(); else cur.push(p); });
      flush();
    };
    if (A.travel) {
      const T = A.travel;
      const p = Math.min(1, (tNow - T.t0) / T.ms);
      const target = g.route.entry[ms.findIndex((m) => m.key === T.chain)];
      const len = T.usd * K;
      const head = (target + len) * E.travel(p);
      const pts = sample(head - len, Math.min(head, target), 40);
      if (pts) drawOutline(pts, 7, 3.4, "travel");
      if (p >= 1 && !T.hold) A.travel = null;
    }
    if (A.pulse) {
      const P = A.pulse;
      const t = (tNow - P.t0) / 1000;               // seconds since the press
      // keys: [t, s] along the route; linear between keys
      let s = null;
      for (let k = 1; k < P.keys.length; k++) {
        const [ta, sa] = P.keys[k - 1], [tb, sb] = P.keys[k];
        if (t >= ta && t <= tb) { s = sa + (sb - sa) * (t - ta) / Math.max(1e-6, tb - ta); break; }
      }
      if (s === null && t > P.keys[P.keys.length - 1][0]) A.pulse = null;
      else if (s !== null) {
        const band = 90;
        [["pulse-out", 9], ["pulse-in", 3]].forEach(([cls, w]) => {
          const pp = el("path", { d: g.routeD, class: cls, "stroke-width": w }, layer.groove);
          pp.style.strokeDasharray = band + " " + (g.route.total + band * 2);
          pp.style.strokeDashoffset = (-(s - band / 2)).toFixed(1);
        });
      }
    }
    A.rings = A.rings.filter((rg) => {
      const age = tNow - rg.t0, m = ms.find((x) => x.key === rg.key);
      if (age > 450 || !m) return false;
      el("circle", { cx: m.x, cy: m.y, r: R + 6 + age / 40, class: "spool-flash", opacity: (1 - age / 450).toFixed(2) }, layer.fx);
      return true;
    });
    // the Lasna react: the spool's rim flashes as the pulse arrives, and the react tx is tagged on the rim
    if (A.tag && tNow >= A.tag.t0) {
      const sp = g.spool, fr = g.flangeR, age = tNow - A.tag.t0;
      if (age < 500) el("circle", { cx: sp.x, cy: sp.y, r: fr + 3 + age / 60, class: "spool-flash", opacity: (1 - age / 500).toFixed(2) }, layer.fx);
      const tg = el("g", { class: "react-tag" }, layer.fx);
      // below the groove, between the spool rim and the first mouth (clear of chips and labels)
      // phone: between the spool's caption and the first agent chip, kept inside the screen
      let tx = g.mobile ? sp.x + fr + 16 : sp.x + fr * 0.62;
      const ty = g.mobile ? sp.y + 18 : sp.y + fr * 0.36;
      const lead = el("line", { x1: f1(sp.x + fr * 0.8), y1: f1(sp.y + fr * 0.55), x2: f1(tx + 12), y2: f1(ty + 2), class: "lead" }, tg);
      const rect = el("rect", { x: tx, y: ty, width: 10, height: 36, rx: 4 }, tg);
      const t1 = txt(tx + 9, ty + 15, A.tag.l1, "", tg), t2 = txt(tx + 9, ty + 29, A.tag.l2, "tag-sub", tg);
      const tw = Math.max(t1.getComputedTextLength(), t2.getComputedTextLength()) + 18;
      if (tx + tw > g.W - 4) {
        tx = Math.max(4, g.W - 4 - tw);
        rect.setAttribute("x", f1(tx)); t1.setAttribute("x", f1(tx + 9)); t2.setAttribute("x", f1(tx + 9)); lead.setAttribute("x2", f1(tx + 12));
      }
      rect.setAttribute("width", f1(tw));
    }
  }

  // ------------------------------------------------------------------ frame loop (only while something moves)
  function busy() {
    return !!(A.cam || (A.travel && !(A.travel.hold && now() > A.travel.t0 + A.travel.ms)) || A.pulse || (A.tag && now() < A.tag.t0 + 600) || A.rings.length || A.coin || A.piece || Object.keys(A.cinch).length || Object.keys(A.appear).length);
  }
  function frame() {
    rafId = null;
    renderField();
    if (busy()) rafId = requestAnimationFrame(frame);
  }
  function kick() { if (rafId === null) rafId = requestAnimationFrame(frame); }

  // ------------------------------------------------------------------ render: owner column
  function zNow() {
    // Most still possible during a freeze = unspent loops on chains not yet frozen (no grants while frozen).
    return chains.reduce((a, c) => a + (S.chains[c.key].frozenNow ? 0 : S.chains[c.key].loop), 0);
  }
  function renderOwner() {
    const h = S.headline;
    const num = $("hlNum");
    const val = h.usd == null ? "…" : fmt(h.usd);
    if (num.textContent !== val) { num.textContent = val; num.classList.remove("roll"); void num.offsetWidth; num.classList.add("roll"); }
    $("hlLabel").textContent = h.label;
    $("hlSub").textContent = h.sub || "of " + fmt(capOf()) + " today · all chains";
    let note = document.querySelector(".hl-note");
    if (h.note) { if (!note) { note = document.createElement("div"); note.className = "hl-note"; $("hlSub").after(note); } note.textContent = h.note; }
    else if (note) note.remove();
    const held = chains.reduce((a, c) => a + S.chains[c.key].money, 0);
    $("held").innerHTML = "Held <b>" + fmt(held) + "</b> on-chain <span>(vaults + agent wallets" + (S.live ? ", balanceOf at head" : "") + ")</span><br><span>money stays on its own chain · only permission moves</span>";
    $("pausedChip").hidden = !S.paused;
    $("pausedChip").textContent = "coordinator paused · nothing can overspend · one lREACT deposit resumes";
    $("pausedChip").title = "Lasna system contract: reserves " + (S.coordinatorReserves || "");
    renderBadge();
    const inf = $("inflight");
    inf.textContent = "in flight · " + (S.inflight || "nothing");
    inf.classList.toggle("live", !!S.inflight);
    $("stamp").textContent = S.stamp;
    $("stamp").classList.toggle("warn", !!S.stampWarn);
    const stopEl = $("stopBtn");
    stopEl.classList.toggle("locked", MODE === "live");
    stopEl.setAttribute("aria-disabled", String(MODE === "live"));
    if (MODE === "live") {
      $("stopHint").textContent = "Live mode: this button does nothing on purpose. The page holds no keys and sends nothing. A real STOP is the owner's own transaction on any chain (SpendWallet.pressStop, e.g. script/Loop.s.sol stop); the page then draws it from the chain logs.";
      return;
    }
    const can = (S.name === "open" && !replay) || (replay && replay.done);
    $("stopHint").textContent = can ? "replay · press and hold 0.6 s to replay the recorded STOP of 08:16:57 UTC (S1) · sends nothing"
      : replay ? (replay.name === "stop" ? "replaying the recorded press (S1)" : "replay running · STOP is idle") : "replay hold works from the open state (08:16:31 snapshot)";
  }

  // ------------------------------------------------------------------ render: receipts
  function hashLink(step, pending) {
    const [label, ck, tx, off] = step;
    const offTxt = off < 0 ? " (Lasna clock " + off + " s)" : off > 0 ? " +" + off + " s" : "";
    return '<a class="h' + (pending ? " pending" : "") + '" href="' + explorer(ck) + tx + '" target="_blank" rel="noopener" title="' +
      esc(label + " on " + chainName(ck) + offTxt + " · " + tx) + '"><i>' + esc(label) + "·" + chainName(ck) + "</i>" + short(tx) + "</a>";
  }
  const deskQ = window.matchMedia("(min-width: 721px)");
  function renderReceipts() {
    const rows = S.live ? (S.loops || []).slice().sort((a, b) => b.ts - a.ts)
      : PS.loops.filter((l) => l.ts <= S.asOf && (!replay || l.id !== replay.loop)).sort((a, b) => b.ts - a.ts);
    let html = "";
    let n = rows.length;
    if (replay) {
      n++;
      const l = PS.loops.find((x) => x.id === replay.loop);
      const extra = S.receiptExtra ? ' <a class="h print" href="' + explorer("base") + S.receiptExtra.tx + '" target="_blank" rel="noopener" title="paid · ' + S.receiptExtra.tx + '"><i>paid $1.00 · Base</i>' + short(S.receiptExtra.tx) + "</a>" : "";
      html += '<div class="row fresh"><span class="id">' + l.id + '</span><span class="what">' + esc(l.what) + '</span><span class="hashes">' +
        l.steps.map((s, i) => replay.printed[i] ? hashLink(s).replace('class="h', 'class="h print') : hashLink(s, true)).join("") + extra +
        '</span><span class="act">' + (replay.done ? l.actual : "…") + "<small>" + l.utc + " UTC · " + l.path + "</small></span></div>";
    }
    html += rows.map((l) => '<div class="row' + (l.fresh ? " fresh" : "") + '"><span class="id">' + l.id + '</span><span class="what">' + esc(l.what) + '</span><span class="hashes">' +
      l.steps.map((s) => hashLink(s)).join("") + '</span><span class="act">' + l.actual +
      (S.live && l.verified ? ' <span class="ok-mark" title="every hash in this row re-read by our server with eth_getTransactionReceipt: status 1 and the expected event inside">✓</span>' : "") +
      "<small>" + l.utc + " UTC · " + l.path + (S.live && l.verified ? " · re-read" : "") + "</small></span></div>").join("");
    if (!html) html = '<div class="row"><span></span><span class="what">' + (S.live ? (S.ready ? "no loops yet today (UTC)" : "reading today's logs…") : "no loops yet at this time") + '</span></div>';
    const list = $("rList");
    list.innerHTML = html;
    // exactly two full rows, a faded peek of the third, and a count of the rest
    const more = $("rMore");
    if (deskQ.matches && list.children.length > 2) {
      const h = list.children[0].offsetHeight + list.children[1].offsetHeight;
      list.style.maxHeight = (h + 18) + "px";
      list.classList.add("masked");
      more.hidden = false;
      more.textContent = (n - 2) + " more ↓ (scroll)";
    } else {
      list.style.maxHeight = "";
      list.classList.remove("masked");
      more.hidden = true;
    }
    const stats = S.live ? (S.stats || []) : PS.stats;
    const note = S.live
      ? '<div class="st-note" title="Loops are rebuilt from today\'s logs the way script/loop_logger.py matches them: the Lasna react tx carries the origin tx hash; the answer is the wallet event with that grant id or epoch.">today (UTC) · ' + rows.length + ' loop' + (rows.length === 1 ? "" : "s") + ' from chain logs · actual = block times, 1 s · ✓ = receipts re-read by our server</div>'
      : '<div class="st-note" title="Receipts were read back by loop_logger on 09.11. The replay has no live feed, so it shows no ✓ (✓ is reserved for our own RPC re-read).">replay · series 09.11 · 18 loops · block times, 1 s · no live re-read, so no ✓</div>';
    $("rStats").innerHTML = stats.map((s) => '<div class="st"><b>' + s.label + "</b>" + s.value + (s.n ? ' <span class="n">· n=' + s.n + "</span>" : "") + "</div>").join("") + note;
  }
  $("rList").addEventListener("scroll", (e) => {
    const l = e.currentTarget;
    l.classList.toggle("masked", deskQ.matches && l.scrollTop + l.clientHeight < l.scrollHeight - 2);
  });

  function renderAll() { renderOwner(); renderField(); renderReceipts(); kick(); }

  // ------------------------------------------------------------------ STOP hold (local UI only: a pull handle)
  let hold = null;
  function setHold(p) {
    $("stopFill").style.transform = "scaleX(" + p + ")";
    $("stopCord").style.transform = "translateX(" + (40 * p).toFixed(1) + "px)";
    $("stopText").style.transform = "translateX(" + (-2 * p).toFixed(1) + "px)";
  }
  function holdStart(e) {
    if (e) e.preventDefault();
    if (MODE === "live" || (replay && !replay.done) || hold) return;
    if (replay || S.name !== "open") setState("open");   // a finished replay starts again from the recorded open state
    hold = { t0: now(), to: reduce.matches ? null : camBox(STOP_FIRST + "@1.6") };
    const step = () => {
      if (!hold) return;
      const p = Math.min(1, (now() - hold.t0) / 600);
      setHold(E.hold(p));
      if (hold.to) { view = lerpBox(fullView(), hold.to, E.cam(p)); renderField(); }
      if (p >= 1) { hold = null; runReplay("stop", { keepView: true }); return; }
      hold.raf = requestAnimationFrame(step);
    };
    hold.raf = requestAnimationFrame(step);
  }
  function holdEnd() {
    if (!hold) return;
    cancelAnimationFrame(hold.raf);
    const from = E.hold(Math.min(1, (now() - hold.t0) / 600));
    hold = null;
    const t0 = now();
    const v0 = view;
    const relax = () => {           // releasing early lets the cord slide back and the camera return; nothing was sent
      const p = Math.min(1, (now() - t0) / 220);
      setHold(from * (1 - p));
      if (v0) { view = p >= 1 ? null : lerpBox(v0, fullView(), E.cam(p)); renderField(); }
      if (p < 1) requestAnimationFrame(relax);
    };
    requestAnimationFrame(relax);
  }

  // ------------------------------------------------------------------ replay engine (recorded offsets)
  // Camera moves are presentation only; every state change still lands on its recorded offset.
  // STOP: the camera reaches the pressed mouth during the hold; the rest is planned from the recorded offsets in "press".
  const STOP_FIRST = "mouth:" + PS.replays.stop.events.find((e) => e.do === "press").chain;
  const CAMERA = {
    stop: [{ t: 0, box: STOP_FIRST + "@1.6", ms: 300 }],
    topup: [{ t: 0, box: "spool+base", ms: 350 }]
  };
  function stopReplay() {
    if (replay && replay.raf) cancelAnimationFrame(replay.raf);
    replay = null;
    setHold(0);
  }

  function runReplay(name, opts) {
    stopReplay();
    setMode("replay");
    const R = PS.replays[name];
    const keep = opts && opts.keepView ? view : null;
    setState(R.from, { fromReplay: true });
    if (keep) view = keep;
    $("clockT").classList.remove("done");
    replay = { name, loop: R.loop, events: R.events, idx: 0, start: now(), offset: 0, printed: {}, done: false, later: [],
      cams: (CAMERA[name] || []).slice() };
    if (name === "stop") setHold(1);
    markModes(name);
    $("replayTag").hidden = false;
    $("clock").hidden = false;
    $("skip").hidden = true;
    $("clockL").textContent = name === "stop"
      ? "since the press · " + R.t0utc + " UTC · block times, 1 s"
      : "since the refused pay · " + R.t0utc + " UTC · block times, 1 s";
    S.stamp = name === "stop" ? "replaying loop S1 · pressed on Unichain 08:16:57 UTC" : "replaying loop T2 · Base 05:36:40 UTC";
    S.inflight = name === "stop" ? "STOP → Lasna → both chains" : "Short → Lasna → Base";
    renderAll();
    const tick = () => {
      if (!replay) return;
      const t = now();
      let el_ = (t - replay.start) / 1000 + replay.offset;
      if (replay.skipUntil) {
        if (t >= replay.skipUntil) { replay.offset = replay.skipTo - (t - replay.start) / 1000; replay.skipUntil = null; el_ = replay.skipTo; $("skip").hidden = true; }
        else el_ = replay.skipFrom;
      }
      while (replay.cams.length && replay.cams[0].t <= el_) { const c = replay.cams.shift(); zoomTo(c.box, c.ms); }
      while (!replay.skipUntil && replay.idx < replay.events.length && replay.events[replay.idx].t <= el_) {
        fire(replay.events[replay.idx]); replay.idx++;
        if (!replay) return;
      }
      replay.later = replay.later.filter((l) => { if (t >= l.at) { l.fn(); return false; } return true; });
      const shown = replay.done ? replay.endT : el_;
      $("clockT").textContent = "+" + shown.toFixed(1) + " s";
      if (!replay.done || replay.later.length) replay.raf = requestAnimationFrame(tick);
    };
    replay.raf = requestAnimationFrame(tick);
  }
  // owner-column steps land ~120 ms after the cinch is seen (the knot is the cause)
  function afterCinch(fn, delay) {
    if (reduce.matches) { fn(); return; }
    replay.later.push({ at: now() + (delay || 0) + 480, fn });
  }

  function cinch(key) { if (!reduce.matches) A.cinch[key] = { t0: now() }; }

  function fire(ev) {
    if (ev.step !== undefined) replay.printed[ev.step] = true;
    switch (ev.do) {
      case "press": {
        // the press tx freezes its own chain in the same transaction
        const c = S.chains[ev.chain];
        c.frozenNow = true; c.knot = c.loop; c.loop = 0; c.plate = "frozen"; S.spoolEpoch = S.epoch; S.epoch = 3;   // the spool shows the new epoch when the pulse reaches it
        cinch(ev.chain);                                    // at the recorded t=0, on camera (the hold already zoomed in)
        const z = zNow();
        afterCinch(() => { S.headline = { label: "MOST STILL POSSIBLE DURING FREEZE", usd: z, sub: "$3.00 left in today's budget · freezing" }; renderOwner(); });
        // tension pulse: from the pressed mouth to the spool and on to Base, landing on Base's EpochAck,
        // then on to Unichain, landing on Unichain's EpochAck. Times are the recorded offsets.
        const acks = replay.events.filter((e) => e.do === "ack");
        const tB = acks.find((e) => e.chain === "base").t, tU = acks.find((e) => e.chain === "unichain").t;
        const iU = chains.findIndex((x) => x.key === ev.chain), iB = chains.findIndex((x) => x.key === "base");
        const sU = geo.route.entry[iU], sB = geo.route.entry[iB];
        // Unichain -> spool -> Base is one stretch of groove (sU + sB long) covered in tB seconds at constant speed
        const tSpool = tB * sU / (sU + sB);
        if (!reduce.matches) A.pulse = { t0: now(), keys: [[0, sU], [tSpool, 0], [tB, sB], [tU, sU]] };
        // the react tx: recorded in the same second as the press; its own timestamp reads −1 s (Lasna clock behind, SERIES anomaly 5)
        const loop = PS.loops.find((x) => x.id === replay.loop);
        const react = loop.steps.find((st) => st[1] === "lasna");
        A.tag = { t0: now() + (reduce.matches ? 0 : tSpool * 1000), l1: "Lasna react · " + short(react[2]), l2: "within the same second · Lasna clock " + String(react[3]).replace("-", "−") + " s" };
        replay.later.push({ at: A.tag.t0, fn: () => { S.spoolEpoch = null; renderField(); } });
        // camera follows the pulse: pressed mouth -> spool (arrives with it) -> Base (arrives with its ack) -> full field
        replay.cams.push({ t: 0.06, box: "spool@1.6", ms: Math.max(200, (tSpool - 0.06) * 1000) });
        replay.cams.push({ t: tSpool + 0.05, box: "spool+base@1.4", ms: Math.max(200, (tB - tSpool - 0.08) * 1000) });
        replay.cams.push({ t: tB + 0.3, box: "full", ms: 600 });
        break;
      }
      case "ack": {
        const c = S.chains[ev.chain];
        if (!c.frozenNow) { c.frozenNow = true; c.knot = c.loop; c.loop = 0; c.plate = "frozen"; cinch(ev.chain); }
        // the ack drains that chain's unspent allowance back into its own vault (money stays on its chain)
        c.vault = +(c.vault + c.wallet).toFixed(2); c.wallet = 0;
        if (!reduce.matches) A.rings.push({ key: ev.chain, t0: now() });   // a tick on the mouth when its ack lands
        const z = zNow();
        const all = chains.every((x) => S.chains[x.key].frozenNow);
        afterCinch(() => { S.headline = { label: "MOST STILL POSSIBLE DURING FREEZE", usd: z, sub: "$3.00 left in today's budget · " + (all ? "frozen" : "freezing") }; renderOwner(); });
        break;
      }
      case "short": {
        S.chains[ev.chain].plate = "amber";
        break;
      }
      case "react": {
        if (ev.travel && !reduce.matches) {
          // the outlined length is in flight from the Lasna react until GrantApplied: the recorded interval
          A.travel = { chain: ev.travel.chain, usd: ev.travel.usd, t0: now(), ms: (ev.travel.until - ev.t) * 1000 };
        }
        break;
      }
      case "grant": {
        S.reserve -= ev.usd;
        const c = S.chains[ev.chain];
        c.vault = +(c.vault - ev.usd).toFixed(2); c.wallet = +(c.wallet + ev.usd).toFixed(2); // grant pulls from its own vault
        c.loop += ev.usd; c.plate = "open";
        if (!reduce.matches) A.appear[ev.chain] = now();
        S.inflight = null;
        break;
      }
      case "skip": {
        replay.skipFrom = ev.t; replay.skipTo = ev.to; replay.skipUntil = now() + (reduce.matches ? 0 : 900);
        const sk = $("skip"); sk.hidden = false; sk.textContent = "⏩ " + ev.label;
        return;
      }
      case "paid": {
        const c = S.chains[ev.chain];
        const done = () => {
          A.coin = null;
          c.loop -= ev.usd; c.coin = 0; c.money -= ev.usd; c.wallet = +(c.wallet - ev.usd).toFixed(2);
          S.spentUpTo = 1;
          if (!reduce.matches) A.piece = { tx: ev.tx, t0: now() };
          S.headline = Object.assign({}, S.headline, { usd: S.headline.usd - ev.usd });
          S.receiptExtra = { tx: ev.tx };
          S.stamp = "recorded 05:37:52 UTC · first paid call";
          renderAll();
        };
        if (reduce.matches) { done(); break; }
        A.coin = { chain: ev.chain, t0: now() };
        replay.later.push({ at: now() + 260, fn: done });
        break;
      }
      case "end": {
        replay.done = true; replay.endT = ev.t;
        S.inflight = null;
        if (replay.name === "stop") S.stamp = "recorded 08:16:59 UTC · after STOP S1, epoch 3";
        const r = replay;
        if (r.name === "topup") r.later.push({ at: now() + (reduce.matches ? 0 : 500), fn: () => zoomTo("full", 500) });
        $("clockT").classList.add("done");                  // closing beat: the stopwatch settles
        break;
      }
      case "print": break;
    }
    renderAll();
  }

  // ------------------------------------------------------------------ wiring
  const stop = $("stopBtn");
  stop.addEventListener("pointerdown", holdStart);
  ["pointerup", "pointerleave", "pointercancel"].forEach((t) => stop.addEventListener(t, holdEnd));
  stop.addEventListener("keydown", (e) => { if ((e.key === " " || e.key === "Enter") && !e.repeat) holdStart(e); });
  stop.addEventListener("keyup", (e) => { if (e.key === " " || e.key === "Enter") holdEnd(); });
  document.querySelectorAll(".debug [data-state]").forEach((b) => b.addEventListener("click", () => setState(b.dataset.state)));
  document.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => { if (SERVER) goLive(); }));
  document.querySelectorAll("[data-replay]").forEach((b) => b.addEventListener("click", () => runReplay(b.dataset.replay)));
  document.querySelector(".debug [data-theme]").addEventListener("click", () => {
    const r = document.documentElement;
    const dark = r.dataset.theme ? r.dataset.theme === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches;
    r.dataset.theme = dark ? "light" : "dark";
    renderField();
  });
  let rz;
  window.addEventListener("resize", () => { cancelAnimationFrame(rz); rz = requestAnimationFrame(() => { view = null; A.cam = null; renderField(); renderReceipts(); }); });

  // ================================================================== LIVE
  const sleep = (ms) => new Promise((r) => setTimeout(r, reduce.matches ? 0 : ms));
  function setMode(m) {
    MODE = m;
    $("liveTag").hidden = m !== "live";
    $("replayTag").hidden = m !== "replay";
    $("dayLabel").hidden = m !== "live";   // replay stamps carry their own UTC time
    document.querySelectorAll("[data-mode]").forEach((b) => b.setAttribute("aria-pressed", String(m === "live")));
    if (m === "live") document.querySelectorAll(".debug [data-state]").forEach((b) => b.setAttribute("aria-pressed", "false"));
  }
  function markModes(name) {
    document.querySelectorAll(".modes [data-replay]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.replay === name)));
  }
  function amberPlate(st) {
    const st_ = (S.stats || PS.stats).find((x) => x.label === (st.donor ? "chain-to-chain" : "top-up"));
    const m = st_ && st_.value.match(/median ([^·]+)/);
    return "budget on its way" + (m ? " · " + (st.donor ? "chain-to-chain" : "top-up") + " median " + m[1].trim() : "");
  }
  function renderBadge() {
    const ck = S.live ? S.checker : PS.checker;
    if (!ck) { $("overMain").textContent = "Over …"; $("overSub").textContent = "checker · reading token Transfer logs"; return; }
    $("overMain").textContent = "Over " + fmt(ck.over);
    const per = chains.map((c) => { const p = ck.perChain[c.key]; return c.short + " " + fmt(p.out) + " in " + p.n; }).join(" · ");
    $("overSub").textContent = S.live
      ? "checker rule · token Transfer logs · " + per + " · cap " + fmt(ck.cap) + " · read at head " + S.readAtShort + " UTC (day still running)"
      : "replay · checker · token Transfer logs · read at head " + ck.readAt + " (day still running)";
    $("overBadge").title = S.live ? "script/checker.py's rule: the budget token's own Transfer logs out of each wallet (returns to its own vault excluded), summed over the UTC day, against the coordinator's capOfDay on Lasna" : "script/checker.py · live/checker_2026-11-09.log";
  }
  function emptyLive(label, sub, stamp) {
    const s = { name: "live", live: true, ready: false, cap: 0, reserve: 0, epoch: 0, paused: false, payments: [], spentUpTo: 0, loops: [], stats: [],
      checker: null, chains: {}, headline: { label, usd: null, sub }, stamp, asOf: Infinity };
    chains.forEach((c) => { s.chains[c.key] = { loop: 0, knot: 0, money: 0, vault: 0, wallet: 0, plate: "open", coin: 0 }; });
    return s;
  }
  function sceneFromLive(j) {
    if (!j.ready) {   // a half-read day is not a fact: draw nothing chain-derived until the cursor has caught up
      return emptyLive("READING TODAY'S CHAIN LOGS", "cursor catching up · nothing is shown before it is read",
        "catching up · " + chains.map((c) => c.short + " " + Math.round(100 * (j.progress[c.key] || 0)) + " %").join(" · ") + " · Lasna " + Math.round(100 * (j.progress.lasna || 0)) + " %");
    }
    const co = j.coordinator;
    const s = {
      name: "live", live: true, ready: j.ready, cap: co.capToday, reserve: co.pool, epoch: co.epoch, paused: co.paused,
      dayClosed: !co.dayOpen,
      coordinatorReserves: co.reserves.toFixed(4) + " lREACT · debt " + co.debt.toFixed(4),
      payments: j.payments, spentUpTo: j.payments.length, loops: j.loops, stats: j.stats, checker: j.checker,
      readAtShort: j.readAtUtc.slice(0, 5), chains: {}, receiptExtra: null, asOf: Infinity
    };
    j.chains.forEach((c) => {
      let knot = c.knot, hidden = 0;
      if (c.loop > 0 && knot > 0) { hidden = knot; knot = 0; }   // both: the loop is drawn, the return sits on the tape
      s.chains[c.key] = { loop: c.loop, knot, hiddenPending: hidden, inflight: c.inflight, money: c.money, vault: c.vault_, wallet: c.wallet_,
        plate: c.plate, coin: c.plate === "amber" || c.plate === "red" || c.plate === "held" ? c.coin : 0, frozenNow: c.frozen, donor: c.donor,
        epochNow: c.epoch, knotNote: c.frozen ? null : "returning · confirming" };
    });
    s.headline = j.ready ? j.headline : { label: "READING TODAY'S CHAIN LOGS", usd: null, sub: "cursor catching up · nothing is shown before it is read" };
    const prog = j.ready ? "" : " · catching up " + chains.map((c) => c.short + " " + Math.round(100 * (j.progress[c.key] || 0)) + " %").join(" · ");
    s.stamp = "read at head " + j.readAtUtc + " UTC" + prog;
    s.stampWarn = false;
    if (j.rpcError) { s.stamp = "RPC error · showing the read at " + j.readAtUtc + " UTC"; s.stampWarn = true; }
    const fl = (j.inflight || []).map((g) => "Lasna → " + chains.find((c) => c.key === g.chain).short + " · grant #" + g.gid + " " + fmt(g.units / 1e6));
    s.inflight = fl.length ? fl.join(" · ") : null;
    return s;
  }
  function applyLive(j) {
    LIVE = j;
    $("dayLabel").textContent = "UTC day " + j.day + " · testnets";
    if (MODE !== "live") return;
    S = sceneFromLive(j);
    // a grant debited on Lasna but not yet applied on its chain stays drawn as an outline waiting at the mouth
    chains.forEach((c) => {
      const st = S.chains[c.key];
      if (st.inflight > 0 && !(A.travel && A.travel.chain === c.key)) A.travel = { chain: c.key, usd: st.inflight, t0: now() - 1, ms: 1, hold: true };
      if (!(st.inflight > 0) && A.travel && A.travel.chain === c.key && A.travel.hold) A.travel = null;
    });
    renderAll();
  }
  function goLive() {
    stopReplay();
    markModes(null);
    clearAnims();
    setMode("live");
    $("clock").hidden = true; $("skip").hidden = true;
    if (LIVE) applyLive(LIVE); else renderAll();
  }

  // One handler per on-chain event type. Each starts its motion on the current picture; the next snapshot
  // (the chain's own state at head) then replaces the picture, so the motion can never invent a value.
  async function playEvent(ev) {
    if (MODE !== "live" || !S) return;
    const st = S.chains[ev.chain];
    switch (ev.type) {
      case "grantSent": {      // pool debited on Lasna (rule 1): an outlined length leaves the spool
        S.reserve = Math.max(0, +(S.reserve - ev.usd).toFixed(2));
        if (st) st.inflight = +((st.inflight || 0) + ev.usd).toFixed(2);   // on the tape as "in flight", so Σ stays the cap
        if (!reduce.matches) A.travel = { chain: ev.chain, usd: ev.usd, t0: now(), ms: 700, hold: true };
        S.inflight = "Lasna → " + chainName(ev.chain) + " · grant #" + ev.gid + " " + fmt(ev.usd);
        renderAll(); await sleep(700); break;
      }
      case "grantApplied": {   // the wallet applied it: the cord lands as a loop
        if (!(A.travel && A.travel.chain === ev.chain) && !reduce.matches) {
          A.travel = { chain: ev.chain, usd: ev.usd, t0: now(), ms: 600, hold: true };
          renderAll(); await sleep(600);
        }
        A.travel = null;
        if (st) { st.loop = +(st.loop + ev.usd).toFixed(2); st.plate = "open"; st.coin = 0; st.inflight = 0; if (!reduce.matches) A.appear[ev.chain] = now(); }
        S.inflight = null;
        renderAll(); await sleep(200); break;
      }
      case "paid": {           // token Transfer out of the wallet: the coin drops, one piece lands in the tray
        if (st && !reduce.matches) {
          if (!st.coin) st.coin = ev.usd;
          st.coinNote = "paid";
          A.coin = { chain: ev.chain, t0: now() };
          renderAll(); await sleep(260);
        }
        A.coin = null;
        if (st) { st.coin = 0; st.coinNote = null; st.loop = Math.max(0, +(st.loop - ev.usd).toFixed(2)); }
        const p = (LIVE && LIVE.payments || []).find((x) => x.tx === ev.tx);
        if (p && !S.payments.some((x) => x.tx === p.tx)) { S.payments = S.payments.concat([p]); S.spentUpTo = S.payments.length; }
        if (!reduce.matches) A.piece = { tx: ev.tx, t0: now() };
        renderAll(); await sleep(260); break;
      }
      case "stopPressed":      // the pressing chain freezes in the same tx: its loop cinches into a knot
      case "epochAck": {
        if (ev.type === "epochAck" && !ev.frozen) break;
        if (st && !st.frozenNow) {
          st.frozenNow = true; st.knot = +(st.loop + st.knot).toFixed(2); st.loop = 0; st.plate = "frozen"; st.knotNote = null;
          if (ev.epoch != null) st.epochNow = ev.epoch;
          cinch(ev.chain);
        }
        if (ev.type === "epochAck" && !reduce.matches) A.rings.push({ key: ev.chain, t0: now() });
        renderAll(); await sleep(440); break;
      }
      case "frozen": {         // the coordinator on Lasna froze: the spool flashes and the react tx is tagged
        S.epoch = ev.epoch;
        A.tag = { t0: now(), l1: "Lasna react · " + short(ev.tx), l2: "Frozen(epoch " + ev.epoch + ") · on-chain" };
        renderAll(); await sleep(500); break;
      }
      default: break;
    }
  }
  let since = null, polling = false, lastOk = 0;
  async function poll() {
    if (polling) return;
    polling = true;
    try {
      const r = await fetch("api/state" + (since != null ? "?since=" + since : ""), { cache: "no-store" });
      const j = await r.json();
      if (j.ok) {
        lastOk = Date.now();
        $("liveTag").classList.remove("stale");
        const evs = since != null ? (j.events || []) : [];   // first load: history is drawn, never animated
        since = j.seq;
        if (MODE === "live" && evs.length) {
          for (const ev of evs) await playEvent(ev);
          const fresh = new Set(evs.map((e) => e.tx));
          (j.loops || []).forEach((l) => { if (l.steps.some((s) => fresh.has(s[2]))) l.fresh = true; });
        }
        applyLive(j);
      } else if (S === null || (S && S.live)) {
        $("stamp").textContent = "server starting · reading the chains";
      }
    } catch (e) {
      $("liveTag").classList.add("stale");
      if (MODE === "live" && S) { $("stamp").textContent = "server unreachable · last read " + (LIVE ? LIVE.readAtUtc + " UTC" : "none"); $("stamp").classList.add("warn"); }
    } finally {
      polling = false;
      setTimeout(poll, 2000);
    }
  }

  const q = new URLSearchParams(location.search);
  if (q.get("debug") === "1") document.body.classList.add("debug-on");   // developer state bar: ?debug=1 only
  if (q.get("theme")) document.documentElement.dataset.theme = q.get("theme");
  document.querySelectorAll("[data-mode]").forEach((b) => { b.hidden = !SERVER; });
  const start = () => {
    // Default: the labelled replay at the open state (static build), or live when served by server.py.
    // ?mode=replay|live, ?replay=stop|topup and ?state=<name> override it.
    const wantLive = SERVER && q.get("mode") !== "replay" && !q.get("replay") && !q.get("state");
    if (wantLive) {
      // empty live scene until the first snapshot: nothing recorded is ever shown as live
      S = emptyLive("READING THE CHAINS", "connecting to the read-only server", "connecting…");
      setMode("live");
      renderAll();
    } else if (q.get("replay") && PS.replays[q.get("replay")]) runReplay(q.get("replay"));
    else setState(PS.states[q.get("state")] ? q.get("state") : "open");
    if (SERVER) poll();
  };
  (document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve()).then(start);
  window.PSApp = { setState, runReplay, holdStart, holdEnd, zoomTo, goLive, get mode() { return MODE; }, get scene() { return S; }, get geo() { return geo; },
    _playEvent: playEvent };
})();
