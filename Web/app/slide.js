// Draws a slide from the scene the engine describes (WebRenderer.swift): the
// background, the master's and layout's artwork, then each shape as an
// absolutely placed box holding its outline in SVG and its text in HTML. One
// slide point is one CSS pixel; whoever shows the slide scales it.
//
// The same drawing serves the editor's canvas, the navigator's thumbnails, the
// presenter view and the audience window.

import { bandForLine, letterTransform, placement, warpBands } from "./warp.js";

const SVG = "http://www.w3.org/2000/svg";
let uniqueId = 0;
const nextId = (prefix) => `${prefix}${++uniqueId}`;

/** `box` set in from each edge by `[l, t, r, b]`, fractions of its size; the whole box without them. */
const insetBox = (box, insets) => {
  const [l, t, r, b] = insets ?? [0, 0, 0, 0];
  return { x: box.x + box.w * l, y: box.y + box.h * t, w: box.w * (1 - l - r), h: box.h * (1 - t - b) };
};

/** The outline an SVG path or rectangle draws, as path data. */
const outlineOf = (element) => {
  if (element.localName === "path") return element.getAttribute("d");
  if (element.localName !== "rect") return null;
  const [x, y, w, h] = ["x", "y", "width", "height"].map((name) => Number(element.getAttribute(name) ?? 0));
  return `M${x} ${y}H${x + w}V${y + h}H${x}Z`;
};

/** Text turned a quarter, letters and all, by how far. Other vertical text is set in vertical lines (app.css). */
export const TURNED_TEXT = { vert: 90, vert270: -90 };

/**
 * Office and Windows faces that other devices rarely have, and what to set them in instead, best first: the
 * engine's FontResolver choices on Apple platforms (metric-compatible ones such as Carlito for Calibri first),
 * then their counterparts elsewhere. Whole names for the ones whose longer names are other faces.
 */
const SUBSTITUTES = [
  [/^calibri/, ["Carlito"]],
  [/^cambria/, ["Caladea", "Georgia"]],
  [/^(aptos|segoe|arial nova|tahoma|candara|corbel|franklin gothic)/, []],
  [/^century gothic/, ["Avenir Next", "Futura", "URW Gothic"]],
  [/^gill sans/, ["Gill Sans", "Gill Sans MT"]],
  [/^constantia/, ["Georgia"]],
  [/^(book antiqua|palatino)/, ["Palatino", "Palatino Linotype", "TeX Gyre Pagella"]],
  [/^garamond/, ["Baskerville", "Garamond", "EB Garamond"]],
  [/^(consolas|lucida console)/, ["Menlo", "Monaco", "Consolas"]],
  [/^courier/, ["Courier New", "Courier"]],
  [/^(meiryo|yu gothic|ms gothic|ms pgothic|ms ui gothic|游ゴシック|メイリオ|ｍｓ ゴシック|ｍｓ ｐゴシック)/, ["Hiragino Sans", "Yu Gothic", "Meiryo", "Noto Sans JP", "Noto Sans CJK JP"]],
  [/^(ms mincho|ms pmincho|yu mincho|游明朝|ｍｓ 明朝|ｍｓ ｐ明朝)/, ["Hiragino Mincho ProN", "Yu Mincho", "Noto Serif JP", "Noto Serif CJK JP"]],
  [/^microsoft yahei/, ["PingFang SC", "Noto Sans SC", "Noto Sans CJK SC"]],
  [/^microsoft jhenghei/, ["PingFang TC", "Noto Sans TC", "Noto Sans CJK TC"]],
  [/^malgun gothic/, ["Apple SD Gothic Neo", "Noto Sans KR", "Noto Sans CJK KR"]],
  [/^arial$/, ["Helvetica", "Liberation Sans", "Arimo"]],
  [/^helvetica$/, ["Arial", "Liberation Sans", "Arimo"]],
  [/^(liberation sans|arimo)$/, ["Arial", "Helvetica"]],
  [/^(liberation serif|tinos)$/, ["Times New Roman", "Times"]],
  [/^(liberation mono|cousine)$/, ["Courier New", "Courier"]],
  [/^carlito$/, ["Calibri"]],
  [/^caladea$/, ["Cambria", "Georgia"]],
];

const SERIF_WORDS = ["serif", "times", "georgia", "garamond", "baskerville", "caslon", "bodoni", "didot", "minion", "playfair",
  "merriweather", "lora", "antiqua", "slab", "palatino", "charter", "crimson", "schoolbook", "goudy", "perpetua", "rockwell",
  "bookman", "clarendon", "cochin", "hoefler", "iowan", "literata", "spectral", "cormorant", "cardo", "sabon", "janson",
  "plantin", "utopia", "tiempos", "domine", "alegreya", "cambria", "constantia"];

/** The generic family a typeface's name suggests, as the engine's FontResolver decides on Apple platforms. */
function generic(family) {
  const name = family.toLowerCase();
  const words = family.replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const begins = (prefixes) => words.some((word) => prefixes.some((prefix) => word.startsWith(prefix)));
  if (begins(["courier", "consol", "typewriter", "terminal", "fixed", "monaco", "menlo", "andale", "jetbrains"])
    || words.some((word) => word === "code" || word.endsWith("mono"))) return "ui-monospace, monospace"; // design-lint-allow (document content)
  if (/mincho|明朝/.test(name)) return "serif";
  if (begins(["sans", "grotesk", "grotesque", "gothic"])) return "system-ui, sans-serif";
  if (begins(SERIF_WORDS) || words.some((word) => word.endsWith("serif"))) return "serif";
  return "system-ui, sans-serif";
}

/**
 * What a device without `family` sets it in: `{ family }`, the first substitute `has` says it has, or
 * `{ generic }`, "sans", "serif" or "monospace", for the closest of its own. design-lint-allow (document content)
 */
export function substituteFor(family, has) {
  const substitute = SUBSTITUTES.find(([pattern]) => pattern.test(family.toLowerCase()));
  const found = substitute?.[1].find((other) => has(other));
  if (found) return { family: found };
  const kind = generic(family);
  return { generic: kind.includes("monospace") ? "monospace" : kind === "serif" ? "serif" : "sans" }; // design-lint-allow (document content)
}

const quote = (family) => `"${String(family).replace(/["\\]/g, "\\$&")}"`;

/** What a run's complex-script face sets: Hebrew, Arabic, the Indic scripts, Thai and the like, and the marks that join them. */
const COMPLEX_SCRIPTS = "U+0590-08FF, U+0900-109F, U+1780-18AF, U+19E0-19FF, U+200C-200F, U+A8E0-A8FF, U+FB1D-FDFF, U+FE70-FEFE";
const complexFamilies = new Map();

/**
 * A family that sets complex scripts alone in `name`, or in what stands in for it, so it can lead a
 * run's font list without taking its Latin letters. Null where the page can't make one.
 */
function complexFamily(name) {
  if (complexFamilies.has(name)) return complexFamilies.get(name);
  let alias = null;
  if (typeof FontFace === "function" && typeof document !== "undefined" && document.fonts) {
    alias = `Dazzle Complex ${name}`;
    const names = [name, ...(SUBSTITUTES.find(([pattern]) => pattern.test(name.toLowerCase()))?.[1] ?? [])];
    try {
      document.fonts.add(new FontFace(alias, names.map((other) => `local(${quote(other)})`).join(", "), { unicodeRange: COMPLEX_SCRIPTS }));
      document.fonts.add(new FontFace(alias, names.map((other) => `local(${quote(`${other} Bold`)})`).join(", "),
        { unicodeRange: COMPLEX_SCRIPTS, weight: "700" }));
    } catch {
      alias = null;
    }
  }
  complexFamilies.set(name, alias);
  return alias;
}

/**
 * A CSS font-family list for a run: its complex-script face for Arabic, Hebrew and the like, its
 * own face, East Asian face, then the closest the device has.
 */
export function fontStack(family, eastAsian, complexScript) {
  const names = [];
  const complex = complexScript ? complexFamily(complexScript) : null;
  if (complex) names.push(complex);
  for (const name of [family, eastAsian]) {
    if (!name || names.includes(name)) continue;
    names.push(name);
    const substitute = SUBSTITUTES.find(([pattern]) => pattern.test(name.toLowerCase()));
    for (const other of substitute?.[1] ?? []) if (!names.includes(other)) names.push(other);
  }
  return [...names.map(quote), generic(family ?? "")].join(", ");
}

function svg(name, attributes = {}, parent = null) {
  const element = document.createElementNS(SVG, name);
  for (const [key, value] of Object.entries(attributes)) {
    if (value !== undefined && value !== null) element.setAttribute(key, String(value));
  }
  parent?.append(element);
  return element;
}

/**
 * A preset pattern's tile, `cell` × 8 slide points square: the background, then a rectangle for each run of
 * foreground cells along a row. `rows` are the eight rows, top first, each a byte with the leftmost cell its highest bit.
 */
function patternRects({ rows, cell, fg, bg }) {
  const size = cell * 8;
  const rects = [{ x: 0, y: 0, width: size, height: size, fill: bg }];
  rows.forEach((bits, row) => {
    for (let column = 0; column < 8; column++) {
      if (!(bits & (0x80 >> column))) continue;
      let end = column;
      while (end + 1 < 8 && bits & (0x80 >> (end + 1))) end++;
      rects.push({ x: column * cell, y: row * cell, width: (end - column + 1) * cell, height: cell, fill: fg });
      column = end;
    }
  });
  return rects;
}

/** A preset pattern as a CSS background, for a table cell: an SVG tile repeated from the top left. */
function patternBackground(paint) {
  const size = paint.cell * 8;
  const rects = patternRects(paint).map((r) => `<rect x="${r.x}" y="${r.y}" width="${r.width}" height="${r.height}" fill="${r.fill}"/>`);
  const markup = `<svg xmlns="${SVG}" width="${size}" height="${size}" shape-rendering="crispEdges">${rects.join("")}</svg>`;
  return `url("data:image/svg+xml,${encodeURIComponent(markup)}") 0 0 / ${size}px ${size}px repeat`;
}

function html(name, className, parent = null) {
  const element = document.createElement(name);
  if (className) element.className = className;
  parent?.append(element);
  return element;
}

/**
 * Pictures and movies from the open presentation, as object URLs, asked of the
 * engine once each.
 */
export class MediaStore {
  constructor(engine) {
    this.engine = engine;
    this.urls = new Map();
    this.blobs = new Map();
    this.pending = new Map();
  }

  /** An object URL for a part, once it has arrived; null until then. */
  peek(path) {
    return this.urls.get(path) ?? null;
  }

  url(path) {
    if (this.urls.has(path)) return Promise.resolve(this.urls.get(path));
    if (!this.pending.has(path)) {
      this.pending.set(path, this.engine.call("media", { path }).then(({ result, payload }) => {
        const blob = new Blob([payload], { type: result.mime });
        this.adopt(path, blob);
        this.pending.delete(path);
        return this.urls.get(path);
      }).catch(() => {
        this.pending.delete(path);
        return null;
      }));
    }
    return this.pending.get(path);
  }

  /** The bytes of a part, for handing to another window. */
  async blob(path) {
    await this.url(path);
    return this.blobs.get(path) ?? null;
  }

  adopt(path, blob) {
    if (this.urls.has(path) || !blob) return;
    this.blobs.set(path, blob);
    this.urls.set(path, URL.createObjectURL(blob));
  }

  clear() {
    for (const url of this.urls.values()) URL.revokeObjectURL(url);
    this.urls.clear();
    this.blobs.clear();
    this.pending.clear();
  }
}

/**
 * Draws scenes. `media` supplies pictures; until one arrives its place is
 * left empty and drawn when it does.
 */
export class SlideDrawer {
  /** @param {MediaStore} media */
  constructor(media) {
    this.media = media;
  }

  /**
   * A slide, as an element `scene.w` by `scene.h` pixels.
   * @param {object} scene
   * @param {{ editing?: boolean, interactive?: boolean, hide?: string | null }} options
   *   editing: prompts in empty placeholders and badges on media;
   *   interactive: links answer clicks (slideshow);
   *   hide: a shape left out, being typed into elsewhere.
   */
  draw(scene, { editing = false, interactive = false, hide = null } = {}) {
    const root = html("div", "slide");
    root.style.width = `${scene.w}px`;
    root.style.height = `${scene.h}px`;
    const defs = svg("svg", { class: "slide__defs", width: 0, height: 0, "aria-hidden": "true" }, root);
    const context = { defs: svg("defs", {}, defs), editing, interactive, hide, pending: [] };

    const background = svg("svg", { class: "slide__background", width: scene.w, height: scene.h, viewBox: `0 0 ${scene.w} ${scene.h}` }, root);
    svg("rect", { width: scene.w, height: scene.h, fill: "#ffffff" }, background);
    const backdrop = svg("rect", { width: scene.w, height: scene.h }, background);
    this.paint(backdrop, scene.bg, { x: 0, y: 0, w: scene.w, h: scene.h }, context, background);

    for (const node of scene.art) root.append(this.node(node, context, { x: 0, y: 0 }));
    for (const node of scene.shapes) {
      const element = this.node(node, context, { x: 0, y: 0 });
      element.classList.add("is-own");
      root.append(element);
    }
    root.slideScene = scene;
    return root;
  }

  /** Sets text in its columns, puts tabbed text on its stops and shrinks text that says it shrinks to fit, once the slide is laid out on the page. */
  fit(root) {
    for (const flow of root.querySelectorAll(".text__flow[data-columns]")) layoutColumns(flow.parentElement);
    alignTabs(root);
    for (const box of root.querySelectorAll(".text[data-fit='shrink']")) fitText(box);
    for (const box of root.querySelectorAll(".text[data-warp]")) warpText(box);
    for (const table of root.querySelectorAll(".table")) drawTableBorders(table);
  }

  // MARK: - Shapes

  node(node, context, origin) {
    const outer = html("div", "shape");
    outer.dataset.id = node.id;
    outer.dataset.kind = node.kind;
    if (node.art) outer.classList.add("is-artwork");
    if (node.ph) outer.dataset.placeholder = node.ph;
    Object.assign(outer.style, {
      left: `${node.x - origin.x}px`, top: `${node.y - origin.y}px`, width: `${node.w}px`, height: `${node.h}px`,
    });
    if (node.shadow) outer.style.filter = `drop-shadow(${node.shadow.dx}px ${node.shadow.dy}px ${node.shadow.blur / 2}px ${node.shadow.c})`;
    if (context.hide === node.id) outer.classList.add("is-hidden-for-editing");

    const inner = html("div", "shape__body", outer);
    const transforms = [];
    if (node.rot) transforms.push(`rotate(${node.rot}deg)`);
    if (node.fh || node.fv) transforms.push(`scale(${node.fh ? -1 : 1}, ${node.fv ? -1 : 1})`);
    if (transforms.length) inner.style.transform = transforms.join(" ");

    switch (node.kind) {
      case "group":
        for (const child of node.children ?? []) inner.append(this.node(child, context, { x: node.x, y: node.y }));
        break;
      case "picture":
        this.picture(node, inner, context);
        break;
      case "table":
        this.table(node, inner, context);
        break;
      case "chart":
        this.chart(node, inner);
        break;
      case "standin":
        this.standIn(node, inner);
        break;
      default:
        this.shape(node, inner, context);
    }
    if (node.effects) this.applyEffects(node, outer, inner, context);
    if (node.reflection) this.reflect(node, outer, inner);
    if (node.link && context.interactive) {
      outer.dataset.link = JSON.stringify(node.link);
      outer.classList.add("has-link");
    }
    return outer;
  }

  shape(node, parent, context) {
    const geometry = svg("svg", {
      class: "shape__outline", width: node.w, height: node.h, viewBox: `0 0 ${Math.max(node.w, 0.01)} ${Math.max(node.h, 0.01)}`, overflow: "visible",
    }, parent);
    if (node.path) this.depth(node, node.path, node.rule ?? "evenodd", geometry);
    if (node.fill && node.path) {
      const fill = svg("path", { d: node.path, "fill-rule": node.rule ?? "evenodd" }, geometry);
      this.paint(fill, node.fill, { x: 0, y: 0, w: node.w, h: node.h }, context, geometry);
      fill.classList.add("shape__fill");
      // Shaded parts (a cube's sides, a scroll's curls): the fill again, with black or white over it.
      for (const shade of node.shades ?? []) {
        const base = svg("path", { d: shade.d, "fill-rule": "evenodd" }, geometry);
        this.paint(base, node.fill, { x: 0, y: 0, w: node.w, h: node.h }, context, geometry);
        base.classList.add("shape__fill");
        svg("path", { d: shade.d, "fill-rule": "evenodd", fill: shade.c, "fill-opacity": shade.o, class: "shape__shade" }, geometry);
      }
      this.bevel(node, node.path, node.rule ?? "evenodd", geometry, context);
    }
    if (node.line && (node.strokePath ?? node.path)) this.stroke(node.strokePath ?? node.path, node.line, geometry, context, node);
    if (node.text && !(node.prompt && isEmptyText(node.text))) {
      parent.append(this.text(node.text, node));
    } else if (node.prompt && context.editing) {
      const outline = svg("rect", {
        class: "shape__prompt-outline", x: node.promptRect.x, y: node.promptRect.y, width: node.promptRect.w, height: node.promptRect.h,
      }, geometry);
      outline.setAttribute("fill", "none");
      parent.append(this.text(node.prompt, node, { prompt: true }));
    }
  }

  /**
   * Strokes an outline: in its colour, or with a gradient or picture laid across the line's bounds,
   * with its caps and joins, and a compound line as its parallel strokes.
   */
  stroke(d, line, parent, context, node) {
    const box = line.box ?? { x: 0, y: 0, w: node.w, h: node.h };
    let path;
    for (const band of line.bands ?? [{ d, w: line.w }]) {
      const element = svg("path", {
        d: band.d, fill: "none", stroke: line.c, "stroke-width": band.w, "stroke-linejoin": line.join ?? "round",
        "stroke-linecap": line.cap, "stroke-miterlimit": line.miter, "stroke-dasharray": line.dash?.join(" "), class: "shape__line",
      }, parent);
      if (line.paint) this.paint(element, line.paint, box, context, parent, "stroke");
      path ??= element;
    }
    for (const head of line.heads ?? []) {
      const element = svg("path", {
        d: head.d, fill: head.filled ? line.c : "none", stroke: line.c, "stroke-width": line.w, "stroke-linejoin": "round",
      }, parent);
      if (line.paint) {
        this.paint(element, line.paint, box, context, parent, "stroke");
        if (head.filled) this.paint(element, line.paint, box, context, parent, "fill");
      }
    }
    return path;
  }

  /** Fills `element` with a scene's paint, or strokes it when `attribute` is "stroke": a colour, a gradient, a pattern or a picture. */
  paint(element, paint, box, context, owner, attribute = "fill") {
    if (!paint) {
      element.setAttribute(attribute, "none");
      return;
    }
    if (paint.t === "solid") {
      element.setAttribute(attribute, paint.c);
      return;
    }
    if (paint.t === "linear" || paint.t === "radial") {
      const id = nextId("g");
      const tile = insetBox(box, paint.tile);
      let gradient;
      if (paint.t === "radial") {
        // From a circle around `focus` (fillToRect) to one around the tile.
        const focus = insetBox(box, paint.focus);
        gradient = svg("radialGradient", {
          id, gradientUnits: "userSpaceOnUse",
          cx: tile.x + tile.w / 2, cy: tile.y + tile.h / 2, r: Math.hypot(tile.w, tile.h) / 2,
          fx: focus.x + focus.w / 2, fy: focus.y + focus.h / 2, fr: Math.hypot(focus.w, focus.h) / 2,
        }, context.defs);
      } else {
        // Across the tile; a scaled gradient's angle is set for a unit square, then stretched to the tile.
        const angle = (paint.angle * Math.PI) / 180;
        const w = paint.scaled ? 1 : tile.w;
        const h = paint.scaled ? 1 : tile.h;
        const half = (Math.abs(Math.cos(angle)) * w + Math.abs(Math.sin(angle)) * h) / 2;
        const dx = Math.cos(angle) * half;
        const dy = Math.sin(angle) * half;
        gradient = svg("linearGradient", {
          id, gradientUnits: "userSpaceOnUse", x1: -dx, y1: -dy, x2: dx, y2: dy,
          gradientTransform: `translate(${tile.x + tile.w / 2} ${tile.y + tile.h / 2})${paint.scaled ? ` scale(${tile.w} ${tile.h})` : ""}`,
        }, context.defs);
      }
      for (const [offset, color] of paint.stops) svg("stop", { offset, "stop-color": color }, gradient);
      element.setAttribute(attribute, `url(#${id})`);
      return;
    }
    if (paint.t === "rect" || paint.t === "shape") {
      // Drawn as a pattern of one tile over the area: its end colour throughout, then on top
      // either the four bands from the start rectangle (fillToRect) out to the tile's edges,
      // each its own linear gradient, or copies of the outline from the tile in to the start.
      const id = nextId("p");
      const pattern = svg("pattern", { id, patternUnits: "userSpaceOnUse", x: box.x, y: box.y, width: box.w, height: box.h }, context.defs);
      const layer = svg("g", { transform: `translate(${-box.x} ${-box.y})` }, pattern);
      const focus = insetBox(box, paint.focus);
      const tile = insetBox(box, paint.tile);
      const outline = paint.t === "shape" && attribute === "fill" ? outlineOf(element) : null;
      if (outline) {
        const rule = element.getAttribute("fill-rule") ?? "nonzero";
        const steps = paint.rings.length - 1;
        svg("rect", { x: box.x, y: box.y, width: box.w, height: box.h, fill: paint.rings[0] }, layer);
        paint.rings.forEach((color, index) => {
          const position = 1 - index / steps;
          const x = focus.x + (tile.x - focus.x) * position;
          const y = focus.y + (tile.y - focus.y) * position;
          const w = focus.w + (tile.w - focus.w) * position;
          const h = focus.h + (tile.h - focus.h) * position;
          if (w <= 0 || h <= 0 || box.w <= 0 || box.h <= 0) return;
          svg("path", {
            d: outline, fill: color, "fill-rule": rule,
            transform: `translate(${x} ${y}) scale(${w / box.w} ${h / box.h}) translate(${-box.x} ${-box.y})`,
          }, layer);
        });
      } else {
        const from = paint.from ?? paint.rings?.[paint.rings.length - 1];
        const to = paint.to ?? paint.rings?.[0];
        const stops = paint.stops;
        svg("rect", { x: box.x, y: box.y, width: box.w, height: box.h, fill: to }, layer);
        svg("rect", { x: focus.x, y: focus.y, width: Math.max(focus.w, 0), height: Math.max(focus.h, 0), fill: from }, layer);
        const outer = [[tile.x, tile.y], [tile.x + tile.w, tile.y], [tile.x + tile.w, tile.y + tile.h], [tile.x, tile.y + tile.h]];
        const inner = [[focus.x, focus.y], [focus.x + focus.w, focus.y], [focus.x + focus.w, focus.y + focus.h], [focus.x, focus.y + focus.h]];
        const midX = focus.x + focus.w / 2;
        const midY = focus.y + focus.h / 2;
        // Top, right, bottom, left: each running from the start rectangle's edge to the tile's.
        const lines = [
          [midX, focus.y, midX, tile.y], [focus.x + focus.w, midY, tile.x + tile.w, midY],
          [midX, focus.y + focus.h, midX, tile.y + tile.h], [focus.x, midY, tile.x, midY],
        ];
        lines.forEach(([x1, y1, x2, y2], side) => {
          if (Math.hypot(x2 - x1, y2 - y1) < 0.001) return;
          const next = (side + 1) % 4;
          const band = nextId("g");
          const gradient = svg("linearGradient", { id: band, gradientUnits: "userSpaceOnUse", x1, y1, x2, y2 }, context.defs);
          for (const [offset, color] of stops) svg("stop", { offset, "stop-color": color }, gradient);
          // Bands meet along the diagonals; softened edges would show there as seams.
          svg("polygon", {
            points: [outer[side], outer[next], inner[next], inner[side]].map((point) => point.join(",")).join(" "),
            fill: `url(#${band})`, "shape-rendering": "crispEdges",
          }, layer);
        });
      }
      element.setAttribute(attribute, `url(#${id})`);
      return;
    }
    if (paint.t === "pattern") {
      // Two colours in a grid of eight by eight cells, repeated from the top left of the area.
      const id = nextId("p");
      const size = paint.cell * 8;
      const pattern = svg("pattern", {
        id, patternUnits: "userSpaceOnUse", x: box.x, y: box.y, width: size, height: size, "shape-rendering": "crispEdges",
      }, context.defs);
      for (const rect of patternRects(paint)) svg("rect", rect, pattern);
      element.setAttribute(attribute, `url(#${id})`);
      return;
    }
    if (paint.t === "image") {
      // A picture fills the outline: a pattern of one tile, or of the image at its own size.
      const id = nextId("p");
      const pattern = svg("pattern", { id, patternUnits: "userSpaceOnUse", x: box.x, y: box.y, width: box.w, height: box.h }, context.defs);
      const image = svg("image", { width: box.w, height: box.h, preserveAspectRatio: "none" }, pattern);
      this.setImage(image, paint.src, (natural) => {
        if (!paint.tile || !natural) return;
        // At 100% a tile is the picture's own size: pixels at 96 to the inch.
        const tile = paint.tile === true ? {} : paint.tile;
        const sx = tile.sx ?? 1;
        const sy = tile.sy ?? 1;
        const width = natural.width * 0.75 * Math.abs(sx);
        const height = natural.height * 0.75 * Math.abs(sy);
        if (width < 1 || height < 1) return;
        // One tile sits against the alignment point, moved by the offset; the rest repeat from it both ways.
        // Flipping mirrors every other tile, so the pattern repeats every two; a negative scale mirrors them all.
        const across = tile.flip === "x" || tile.flip === "xy";
        const down = tile.flip === "y" || tile.flip === "xy";
        pattern.setAttribute("x", box.x + (box.w - width) * (tile.ax ?? 0) + (tile.tx ?? 0));
        pattern.setAttribute("y", box.y + (box.h - height) * (tile.ay ?? 0) + (tile.ty ?? 0));
        pattern.setAttribute("width", width * (across ? 2 : 1));
        pattern.setAttribute("height", height * (down ? 2 : 1));
        for (let column = 0; column < (across ? 2 : 1); column++) {
          for (let row = 0; row < (down ? 2 : 1); row++) {
            const copy = column === 0 && row === 0 ? image : pattern.appendChild(image.cloneNode());
            const mirrorsX = (across && column === 1) !== sx < 0;
            const mirrorsY = (down && row === 1) !== sy < 0;
            copy.setAttribute("width", width);
            copy.setAttribute("height", height);
            const x = column * width;
            const y = row * height;
            copy.setAttribute("transform", `translate(${mirrorsX ? x + width : x} ${mirrorsY ? y + height : y}) scale(${mirrorsX ? -1 : 1} ${mirrorsY ? -1 : 1})`);
          }
        }
      });
      this.effects(image, paint.fx, context);
      element.setAttribute(attribute, `url(#${id})`);
      if (paint.fx?.opacity !== undefined) element.setAttribute(`${attribute}-opacity`, paint.fx.opacity);
    }
  }

  setImage(image, src, onSize = null) {
    const apply = (url) => {
      if (!url) return;
      image.setAttribute("href", url);
      if (onSize) {
        const probe = new Image();
        probe.onload = () => onSize({ width: probe.naturalWidth, height: probe.naturalHeight });
        probe.src = url;
      }
    };
    const known = this.media.peek(src);
    if (known) apply(known);
    else this.media.url(src).then(apply);
  }

  /**
   * A picture's effects as one SVG filter, in the order the Apple renderer
   * (ArtisticRenderer and ResolvedPictureEffects) applies them: artistic
   * effects, the colour change, black and white, grey or duotone, hue,
   * saturation and luminance, tint, then brightness and contrast.
   */
  effects(target, fx, context) {
    if (!fx) return;
    if (fx.opacity !== undefined) target.setAttribute("opacity", fx.opacity);
    if (!fx.grey && !fx.duotone && !fx.brightness && !fx.contrast && !fx.change && fx.biLevel === undefined
      && !fx.hsl && !fx.tint && !fx.art) return;
    const id = nextId("f");
    // Effects stay within the picture, as they do on Apple platforms.
    const filter = svg("filter", { id, "color-interpolation-filters": "sRGB", x: 0, y: 0, width: 1, height: 1 }, context.defs);
    let step = 0;
    let current = "SourceGraphic";
    /** Adds a primitive, reading `current` unless told otherwise, and makes its result current. */
    const add = (name, attributes = {}, parent = filter) => {
      const result = `r${step++}`;
      const element = svg(name, { in: current, ...attributes, result }, parent);
      current = result;
      return element;
    };
    const transfer = (attributes) => {
      const element = add("feComponentTransfer");
      for (const channel of ["R", "G", "B"]) svg(`feFunc${channel}`, attributes(channel), element);
    };
    /** A blur that keeps the picture's own edges and transparency, as Core Image's clamped blur does. */
    const blur = (deviation) => {
      add("feGaussianBlur", { stdDeviation: deviation });
      svg("feFuncA", { type: "linear", slope: 0, intercept: 1 }, add("feComponentTransfer"));
      add("feComposite", { in2: "SourceGraphic", operator: "in" });
    };
    const GREY = "0.299 0.587 0.114 0 0 0.299 0.587 0.114 0 0 0.299 0.587 0.114 0 0 0 0 0 1 0";

    // Sizes are fractions of the picture's longer side.
    const side = Math.max(Number(target.getAttribute("width")) || 0, Number(target.getAttribute("height")) || 0, 1);
    for (const art of fx.art ?? []) {
      const before = current;
      switch (art.k) {
        case "matrix":
          add("feColorMatrix", { type: "matrix", values: art.m.join(" ") });
          break;
        case "blur":
          blur(art.s * side);
          break;
        case "sharpen": {
          const a = art.v * 0.5;
          add("feConvolveMatrix", { order: 3, kernelMatrix: `0 ${-a} 0 ${-a} ${1 + 4 * a} ${-a} 0 ${-a} 0`, preserveAlpha: "true" });
          break;
        }
        case "sketch": {
          // Grey, dodged by its own blurred negative: only edges stay dark.
          add("feColorMatrix", { type: "saturate", values: 0 });
          const grey = current;
          transfer(() => ({ type: "table", tableValues: "1 0" }));
          blur(art.s * side);
          add("feBlend", { in2: grey, mode: "color-dodge" });
          if (art.inv) transfer(() => ({ type: "table", tableValues: "1 0" }));
          break;
        }
        case "edges":
          if (art.v > 0) blur(art.v * 0.003 * side);
          add("feConvolveMatrix", { order: 3, kernelMatrix: "-1 -1 -1 -1 8 -1 -1 -1 -1", preserveAlpha: "true" });
          transfer(() => ({ type: "linear", slope: 4 }));
          break;
        case "paint": {
          blur(art.v * 0.004 * side);
          const levels = Math.max(art.n, 2);
          const steps = Array.from({ length: levels }, (_, index) => index / (levels - 1)).join(" ");
          transfer(() => ({ type: "discrete", tableValues: steps }));
          break;
        }
        case "grain":
        case "distort": {
          // Noise in grains about a 600th of the picture across, or a 60th to ripple it.
          const grain = art.k === "grain" ? side / 600 : side / 60;
          const image = current;
          add("feTurbulence", { in: null, type: "fractalNoise", baseFrequency: 0.5 / Math.max(grain, 1), numOctaves: 1, seed: 7 });
          if (art.k === "grain") {
            const s = art.v;
            const row = `${s} 0 0 0 ${0.5 - s / 2}`;
            add("feColorMatrix", { type: "matrix", values: `${row} ${row} ${row} 0 0 0 0 1` });
            // The noise laid over the picture, as Core Image's overlay.
            add("feBlend", { in2: image, mode: "overlay" });
          } else {
            add("feGaussianBlur", { stdDeviation: side * 0.004 });
            add("feDisplacementMap", { in: image, in2: current, scale: art.v * side, xChannelSelector: "R", yChannelSelector: "G" });
          }
          break;
        }
        case "glow": {
          const sharp = current;
          blur(side * 0.01);
          add("feComposite", { in: sharp, in2: current, operator: "arithmetic", k1: 0, k2: 1, k3: art.v * 0.75, k4: 0 });
          break;
        }
        default:
          break;
      }
      if (art.trans > 0 && current !== before) {
        // `trans`: the picture as it was showing through the effect.
        add("feComposite", { in2: before, operator: "arithmetic", k1: 0, k2: 1 - art.trans, k3: art.trans, k4: 0 });
      }
    }

    if (fx.change) {
      // Where the channels' differences from the colour add to no more than
      // the tolerance, the picture takes the new colour, keeping its alpha.
      const source = current;
      const [r, g, b] = fx.change.from;
      add("feColorMatrix", { type: "matrix", values: `1 0 0 0 ${-r} 0 1 0 0 ${-g} 0 0 1 0 ${-b} 0 0 0 0 1` });
      const above = current;
      add("feColorMatrix", { in: source, type: "matrix", values: `-1 0 0 0 ${r} 0 -1 0 0 ${g} 0 0 -1 0 ${b} 0 0 0 0 1` });
      add("feComposite", { in: above, in2: current, operator: "arithmetic", k1: 0, k2: 1, k3: 1, k4: 0 });
      const distance = current;
      const sharpness = 200;
      add("feColorMatrix", { in: distance, type: "matrix", values: `0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ${sharpness} ${sharpness} ${sharpness} 0 ${-sharpness * fx.change.tol}` });
      add("feComposite", { in: source, in2: current, operator: "in" });
      const kept = current;
      add("feColorMatrix", { in: distance, type: "matrix", values: `0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ${-sharpness} ${-sharpness} ${-sharpness} 0 ${sharpness * fx.change.tol + 1}` });
      const swapped = current;
      const [tr, tg, tb, ta] = fx.change.to;
      add("feFlood", { in: null, "flood-color": `rgb(${tr * 255} ${tg * 255} ${tb * 255})`, "flood-opacity": ta });
      add("feComposite", { in2: swapped, operator: "in" });
      add("feComposite", { in2: source, operator: "in" });
      const replaced = current;
      const merge = add("feMerge", { in: null });
      svg("feMergeNode", { in: kept }, merge);
      svg("feMergeNode", { in: replaced }, merge);
    }
    if (fx.biLevel !== undefined) {
      add("feColorMatrix", { type: "matrix", values: GREY });
      transfer(() => ({ type: "linear", slope: 1000, intercept: -1000 * fx.biLevel }));
    } else if (fx.grey || fx.duotone) {
      add("feColorMatrix", { type: "matrix", values: GREY });
      if (fx.duotone && !fx.grey) {
        const [dark, light] = fx.duotone.map(channels);
        transfer((channel) => ({ type: "table", tableValues: `${dark["RGB".indexOf(channel)]} ${light["RGB".indexOf(channel)]}` }));
      }
    }
    if (fx.hsl) add("feColorMatrix", { type: "matrix", values: fx.hsl.join(" ") });
    if (fx.tint) {
      // Grey mapped from black through the hue to white (or grey, away from it), mixed in by the amount.
      const before = current;
      add("feColorMatrix", { type: "matrix", values: GREY });
      if (fx.tint.amt > 0) transfer((channel) => ({ type: "table", tableValues: `0 ${fx.tint.c["RGB".indexOf(channel)]} 1` }));
      const amount = Math.abs(fx.tint.amt);
      add("feComposite", { in2: before, operator: "arithmetic", k1: 0, k2: amount, k3: 1 - amount, k4: 0 });
    }
    if (fx.brightness || fx.contrast) {
      // Office centres contrast on mid-grey, with half the brightness before it and half after.
      const c = Math.min(Math.max(fx.contrast ?? 0, -1), 1);
      const slope = c >= 0 ? 128 / (128 - 127 * c) : (128 + 127 * c) / 128;
      const shift = Math.min(Math.max(fx.brightness ?? 0, -1), 1) / 2;
      const intercept = shift * slope + 0.5 - 0.5 * slope + shift;
      transfer(() => ({ type: "linear", slope, intercept }));
    }
    target.setAttribute("filter", `url(#${id})`);
  }

  // MARK: - Pictures

  picture(node, parent, context) {
    const geometry = svg("svg", { class: "shape__outline", width: node.w, height: node.h, viewBox: `0 0 ${Math.max(node.w, 0.01)} ${Math.max(node.h, 0.01)}`, overflow: "visible" }, parent);
    const clip = nextId("c");
    svg("path", { d: node.path }, svg("clipPath", { id: clip }, context.defs));
    this.depth(node, node.path, "nonzero", geometry);
    const group = svg("g", { "clip-path": `url(#${clip})` }, geometry);
    const image = svg("image", {
      x: node.image.x, y: node.image.y, width: node.image.w, height: node.image.h, preserveAspectRatio: "none",
    }, group);
    this.setImage(image, node.src);
    this.effects(image, node.fx, context);
    this.bevel(node, node.path, "nonzero", geometry, context);
    if (node.line) this.stroke(node.path, node.line, geometry, context, node);
    if (node.media) {
      parent.dataset.media = JSON.stringify(node.media);
      if (context.editing) {
        // A video or sound is marked as one.
        const size = Math.min(Math.max(Math.min(node.w, node.h) * 0.18, 10), 28);
        const badge = svg("g", { class: "shape__media-badge", transform: `translate(${size * 0.4} ${node.h - size * 1.4})` }, geometry);
        svg("circle", { cx: size / 2, cy: size / 2, r: size / 2, fill: "rgba(0,0,0,0.55)" }, badge);
        svg("path", { d: `M${size * 0.38} ${size * 0.27}L${size * 0.38} ${size * 0.73}L${size * 0.75} ${size / 2}Z`, fill: "#fff" }, badge);
      }
    }
  }

  standIn(node, parent) {
    const geometry = svg("svg", { class: "shape__outline", width: node.w, height: node.h, overflow: "visible" }, parent);
    svg("rect", {
      x: 0, y: 0, width: node.w, height: node.h, rx: 8, fill: "rgba(128,128,140,0.12)", stroke: "rgba(128,128,140,0.4)", "stroke-width": 1,
    }, geometry);
    const glyph = Math.min(node.w, node.h) * 0.28;
    const size = Math.max(Math.min(node.h * 0.08, 18), 7);
    if (node.isChart && glyph > 8) {
      // Three bars, the universal sign for "a chart was here".
      const bar = glyph / 4;
      [0.5, 1, 0.75].forEach((height, index) => {
        svg("rect", {
          x: node.w / 2 - glyph / 2 + index * bar * 1.5, y: node.h / 2 + glyph / 2 - glyph * height, width: bar, height: glyph * height,
          fill: "rgba(128,128,140,0.55)",
        }, geometry);
      });
    }
    const label = svg("text", {
      x: node.w / 2, y: node.isChart && glyph > 8 ? node.h / 2 + glyph / 2 + size * 1.4 : node.h / 2 + size / 3,
      "text-anchor": "middle", "font-size": size, fill: "rgb(102,102,115)", class: "shape__standin-label",
    }, geometry);
    label.textContent = node.label;
  }

  // MARK: - Charts

  chart(node, parent) {
    const geometry = svg("svg", { class: "shape__outline", width: node.w, height: node.h, overflow: "hidden" }, parent);
    for (const item of node.chart ?? []) {
      if (item.k === "rect") {
        svg("rect", { x: item.x, y: item.y, width: Math.max(item.w, 0), height: Math.max(item.h, 0), fill: item.fill }, geometry);
      } else if (item.k === "path") {
        svg("path", {
          d: item.d, fill: item.fill ?? "none", stroke: item.stroke, "stroke-width": item.sw,
          "stroke-linejoin": item.round ? "round" : undefined, "stroke-linecap": item.round ? "round" : undefined,
        }, geometry);
      } else if (item.k === "text") {
        const text = svg("text", {
          x: item.x, y: item.y, "text-anchor": item.anchor, "dominant-baseline": "central", "font-size": item.sz, fill: item.fill,
        }, geometry);
        text.style.fontFamily = fontStack(item.f);
        text.textContent = item.t;
      }
    }
  }

  // MARK: - Tables

  table(node, parent, context) {
    const grid = html("div", "table", parent);
    grid.style.gridTemplateColumns = node.table.cols.map((width) => `${width}px`).join(" ");
    grid.style.gridTemplateRows = node.table.rows.map((height) => `minmax(${height}px, auto)`).join(" ");
    for (const cell of node.table.cells) {
      const element = html("div", "table__cell", grid);
      element.dataset.r = cell.r;
      element.dataset.c = cell.c;
      element.style.gridRow = `${cell.r + 1} / span ${cell.rs}`;
      element.style.gridColumn = `${cell.c + 1} / span ${cell.cs}`;
      if (cell.fill) {
        if (cell.fill.t === "solid") element.style.background = cell.fill.c;
        else if (cell.fill.t === "linear") element.style.background = `linear-gradient(${cell.fill.angle + 90}deg, ${cell.fill.stops.map(([o, c]) => `${c} ${o * 100}%`).join(", ")})`;
        else if (cell.fill.t === "pattern") element.style.background = patternBackground(cell.fill);
      }
      if (cell.borders) element.dataset.borders = JSON.stringify(cell.borders);
      if (cell.text) element.append(this.text(cell.text, null, { cell: true }));
    }
    const lines = svg("svg", { class: "table__lines", overflow: "visible" }, grid);
    lines.setAttribute("aria-hidden", "true");
    if (!context.editing) grid.dataset.static = "1";
  }

  // MARK: - Text

  /**
   * A text body: a box at its inset rectangle, anchored top, middle or
   * bottom, with a paragraph element per paragraph and a span per run.
   */
  text(body, node, { prompt = false, cell = false, scale = null, reduce = null } = {}) {
    const box = html("div", `text${prompt ? " text--prompt" : ""}${cell ? " text--cell" : ""}`);
    Object.assign(box.style, { left: `${body.x}px`, top: `${body.y}px`, width: `${Math.max(body.w, 0)}px`, height: `${Math.max(body.h, 0)}px` });
    box.dataset.anchor = body.anchor;
    if (!body.wrap) box.dataset.nowrap = "1";
    if (body.fit) box.dataset.fit = body.fit;
    const turn = TURNED_TEXT[body.vert];
    if (turn) {
      // Text turned a quarter is laid out across the box's height, then turned.
      Object.assign(box.style, {
        left: `${body.x + body.w / 2 - body.h / 2}px`, top: `${body.y + body.h / 2 - body.w / 2}px`,
        width: `${Math.max(body.h, 0)}px`, height: `${Math.max(body.w, 0)}px`, transform: `rotate(${turn}deg)`,
      });
    } else if (body.vert) {
      // Vertical lines, as Japanese and Chinese are set: the page lays them out.
      box.dataset.vertical = body.vert;
    }
    box.textBody = body;
    // WordArt: laid out flat, then each letter placed along the warp once the slide is on the page (warpText).
    if (body.warp && !prompt) box.dataset.warp = "1";
    const flow = html("div", "text__flow", box);
    if (!body.wrap) {
      flow.style.inlineSize = "max-content";
      const align = body.paras[0]?.align ?? "l";
      flow.style.alignSelf = align === "ctr" ? "center" : align === "r" ? "flex-end" : "flex-start";
    }
    if (body.cols > 1) {
      // Text in columns, balanced across them until the slide is laid out and layoutColumns fills them in turn.
      flow.dataset.columns = body.cols;
      Object.assign(flow.style, { columnCount: String(body.cols), columnGap: `${body.colGap ?? 0}px` });
      if (body.rtlCols) flow.dataset.rtlColumns = "1";
    }
    this.fillFlow(flow, body, { scale: scale ?? body.scale ?? 1, reduce: reduce ?? body.reduce ?? 0, prompt });
    return box;
  }

  fillFlow(flow, body, { scale = 1, reduce = 0, prompt = false, editable = false } = {}) {
    flow.replaceChildren();
    flow.dataset.scale = scale;
    flow.dataset.reduce = reduce;
    for (const paragraph of body.paras) flow.append(this.paragraph(paragraph, { scale, reduce, prompt, editable }));
    if (flow.isConnected) alignTabs(flow);
  }

  paragraph(paragraph, { scale = 1, reduce = 0, prompt = false, editable = false }) {
    const element = html("p", "text__p");
    element.dataset.i = paragraph.i;
    const align = { l: "left", ctr: "center", r: "right", just: "justify" }[paragraph.align] ?? "left";
    const first = Math.max(paragraph.ml + paragraph.ind, 0);
    Object.assign(element.style, {
      // Logical sides, so indents and spacing follow vertical lines too.
      textAlign: align, paddingInlineStart: `${paragraph.ml}px`, textIndent: `${first - paragraph.ml}px`,
      marginBlockStart: `${paragraph.sb * scale}px`, marginBlockEnd: `${paragraph.sa * scale}px`,
    });
    // A right-to-left paragraph reads from the right, and its margin, indent and bullet start there.
    if (paragraph.rtl) element.style.direction = "rtl";
    if (paragraph.lh?.pt) {
      element.style.lineHeight = `${paragraph.lh.pt}px`;
    } else {
      element.style.lineHeight = String(1.2 * Math.max((paragraph.lh?.pct ?? 1) - reduce, 0.5));
    }
    if (paragraph.bullet && !prompt) {
      const bullet = html("span", "text__bullet", element);
      bullet.contentEditable = "false";
      bullet.textContent = paragraph.bullet.t;
      runStyle(bullet, paragraph.bullet, scale);
      // The tab after the bullet lands on the margin, or past the bullet when it hangs into nothing.
      const size = (paragraph.runs[0]?.sz ?? paragraph.end.sz) * scale;
      const tab = paragraph.ml > first ? paragraph.ml : first + size * 0.6;
      bullet.style.minWidth = `${Math.max(tab - first, 0)}px`;
    }
    // Default tab stops, until the stops are laid out once the paragraph is on the page.
    if (paragraph.dts) element.style.tabSize = `${paragraph.dts}px`;
    // With tabs, the text between them is held in segments, so each can be
    // measured and the tab before it widened to put it on its stop; for
    // decimal stops, the part before the decimal point is held apart too.
    const tabbed = Boolean(paragraph.tabs) && !prompt;
    const decimal = tabbed && paragraph.tabs.some(([, alignment]) => alignment === "dec");
    let segment = element;
    let lead = null;
    const startSegment = () => {
      segment = html("span", "text__seg", element);
      lead = decimal ? html("span", "text__lead", segment) : null;
    };
    if (tabbed) {
      element.dataset.tabs = JSON.stringify(paragraph.tabs);
      element.dataset.dts = paragraph.dts;
      startSegment();
    }
    const piece = (run, text, parent, className = "text__run") => {
      const span = html("span", className, parent);
      span.dataset.p = paragraph.i;
      span.dataset.r = run.r;
      span.textContent = text;
      runStyle(span, run, scale);
      if (run.link) span.dataset.link = JSON.stringify(run.link);
      return span;
    };
    let hasText = false;
    for (const run of paragraph.runs) {
      if (run.br) {
        const br = document.createElement("br");
        br.dataset.p = paragraph.i;
        br.dataset.r = run.r;
        element.append(br);
        if (tabbed) startSegment();
        continue;
      }
      if (run.t) hasText = true;
      if (run.field || !tabbed) {
        const span = piece(run, run.t, lead ?? segment);
        if (run.field) {
          span.dataset.field = run.field;
          span.dataset.len = run.len ?? run.t.length;
          if (editable) span.contentEditable = "false";
        }
        continue;
      }
      for (const [index, part] of run.t.split("\t").entries()) {
        if (index > 0) {
          piece(run, "\t", element, "text__run text__tab");
          startSegment();
        }
        if (!part) continue;
        const point = lead ? part.indexOf(".") : -1;
        if (point < 0) {
          piece(run, part, lead ?? segment);
          continue;
        }
        if (point > 0) piece(run, part.slice(0, point), lead);
        lead = null;
        piece(run, ".", segment, "text__run text__point");
        if (point + 1 < part.length) piece(run, part.slice(point + 1), segment);
      }
    }
    if (!hasText) {
      // An empty paragraph still takes a line, as tall as its end-of-paragraph text.
      const end = html("span", "text__end", element);
      runStyle(end, paragraph.end, scale);
      end.append(document.createElement("br"));
    }
    return element;
  }

  // MARK: - 3D

  /** A shape's sides, as copies of its outline set off behind it and darkened, and its contour round its edge, as the engine draws them. */
  depth(node, d, rule, parent) {
    const look = node.look3d;
    if (!look) return;
    (look.sides?.casts ?? []).forEach(([a, b, c, e, f, g], index) => {
      svg("path", {
        d, "fill-rule": rule, fill: look.sides.cs[index], transform: `matrix(${a} ${b} ${c} ${e} ${f} ${g})`, class: "shape__side",
      }, parent);
    });
    if (look.contour) {
      svg("path", {
        d, fill: "none", stroke: look.contour.c, "stroke-width": look.contour.w, "stroke-linejoin": "round", class: "shape__contour",
      }, parent);
    }
  }

  /**
   * A shape's bevel, as bands of white or black over its face: each what stays inside the outline when it is set off
   * by `k` (a clip) but not when it is set off by `x` (a mask).
   */
  bevel(node, d, rule, parent, context) {
    const bands = node.look3d?.bands;
    if (!bands?.length) return;
    const reach = Math.max(...bands.map((band) => Math.max(Math.abs(band.xx), Math.abs(band.xy)))) + 1;
    const area = { x: -reach, y: -reach, width: node.w + 2 * reach, height: node.h + 2 * reach };
    for (const band of bands) {
      const element = svg("path", { d, "fill-rule": rule, fill: band.c, "fill-opacity": band.o, class: "shape__bevel" }, parent);
      if (band.kx || band.ky) {
        const clip = nextId("c");
        svg("path", { d, "clip-rule": rule, transform: `translate(${band.kx} ${band.ky})` }, svg("clipPath", { id: clip }, context.defs));
        element.setAttribute("clip-path", `url(#${clip})`);
      }
      const mask = nextId("m");
      const cut = svg("mask", { id: mask, maskUnits: "userSpaceOnUse", ...area }, context.defs);
      svg("rect", { ...area, fill: "#fff" }, cut);
      svg("path", { d, "fill-rule": rule, fill: "#000", transform: `translate(${band.xx} ${band.xy})` }, cut);
      element.setAttribute("mask", `url(#${mask})`);
    }
  }

  // MARK: - Effects

  /**
   * A preset shadow, as copies of the shape's silhouette beneath it; and a glow, soft edges, an inner shadow and a
   * blur, as an SVG filter on the shape itself: the glow round it, its edges feathered or blurred, the inner shadow
   * over it. The outer shadow falls from all of it, as the engine draws it.
   */
  applyEffects(node, outer, inner, context) {
    const fx = node.effects;
    if (fx.preset) {
      const flood = nextId("f");
      const filter = svg("filter", {
        id: flood, x: "-50%", y: "-50%", width: "200%", height: "200%", "color-interpolation-filters": "sRGB",
      }, context.defs);
      svg("feFlood", { "flood-color": fx.preset.c, result: "colour" }, filter);
      svg("feComposite", { in: "colour", in2: "SourceAlpha", operator: "in" }, filter);
      const turn = inner.style.transform;
      for (const [a, b, c, d, e, f] of fx.preset.casts) {
        const copy = inner.cloneNode(true);
        // Not a body, so the shape's own is the one found by what looks for it.
        copy.classList.replace("shape__body", "shape__preset-shadow");
        copy.setAttribute("aria-hidden", "true");
        copy.style.filter = `url(#${flood})`;
        // Cast in the shape's own space, from its top left, then turned with it about its middle.
        copy.style.transform = `${turn} translate(${-node.w / 2}px, ${-node.h / 2}px) matrix(${a}, ${b}, ${c}, ${d}, ${e}, ${f}) translate(${node.w / 2}px, ${node.h / 2}px)`;
        outer.insertBefore(copy, inner);
      }
    }
    if (!fx.glow && fx.soft === undefined && !fx.blur && !fx.inner) return;
    // Room round the shape for the effects to spread, and for outlines and text that stand out past it.
    const reach = Math.max((fx.glow?.r ?? 0) * 1.5, (fx.blur?.r ?? 0) * 2, fx.inner ? Math.hypot(fx.inner.dx, fx.inner.dy) + fx.inner.blur * 2 : 0);
    const margin = reach + 12 + Math.max(node.w, node.h) * 0.1;
    const id = nextId("f");
    const filter = svg("filter", {
      id, filterUnits: "userSpaceOnUse", x: -margin, y: -margin, width: node.w + 2 * margin, height: node.h + 2 * margin,
      "color-interpolation-filters": "sRGB",
    }, context.defs);
    let body = "SourceGraphic";
    if (fx.soft !== undefined) {
      // Faded out from a little in from the edge to the edge.
      svg("feMorphology", { in: "SourceAlpha", operator: "erode", radius: fx.soft / 2, result: "inset" }, filter);
      svg("feGaussianBlur", { in: "inset", stdDeviation: fx.soft / 4, result: "feather" }, filter);
      svg("feComposite", { in: body, in2: "feather", operator: "in", result: "soft" }, filter);
      body = "soft";
    }
    if (fx.blur) {
      // Cut off at the shape's bounds, unless the blur may grow past them.
      const bounds = fx.blur.grow ? {} : { x: 0, y: 0, width: node.w, height: node.h };
      svg("feGaussianBlur", { in: body, stdDeviation: fx.blur.r / 2, result: "blurred", ...bounds }, filter);
      body = "blurred";
    }
    if (fx.inner) {
      // What lies outside the shape, set off and softened, falls inside it.
      const outside = svg("feComponentTransfer", { in: "SourceAlpha", result: "outside" }, filter);
      svg("feFuncA", { type: "table", tableValues: "1 0" }, outside);
      svg("feOffset", { in: "outside", dx: fx.inner.dx, dy: fx.inner.dy, result: "cast" }, filter);
      svg("feGaussianBlur", { in: "cast", stdDeviation: fx.inner.blur / 2, result: "falling" }, filter);
      svg("feFlood", { "flood-color": fx.inner.c, result: "inner-colour" }, filter);
      svg("feComposite", { in: "inner-colour", in2: "falling", operator: "in", result: "inner-shadow" }, filter);
      svg("feComposite", { in: "inner-shadow", in2: body, operator: "in", result: "inner-inside" }, filter);
      const merge = svg("feMerge", { result: "shaded" }, filter);
      svg("feMergeNode", { in: body }, merge);
      svg("feMergeNode", { in: "inner-inside" }, merge);
      body = "shaded";
    }
    if (fx.glow) {
      // Grown by half the radius and softened over the rest, beneath the shape.
      svg("feMorphology", { in: "SourceAlpha", operator: "dilate", radius: fx.glow.r / 2, result: "grown" }, filter);
      svg("feGaussianBlur", { in: "grown", stdDeviation: fx.glow.r / 4, result: "halo" }, filter);
      svg("feFlood", { "flood-color": fx.glow.c, result: "glow-colour" }, filter);
      svg("feComposite", { in: "glow-colour", in2: "halo", operator: "in", result: "glow" }, filter);
      const merge = svg("feMerge", {}, filter);
      svg("feMergeNode", { in: "glow" }, merge);
      svg("feMergeNode", { in: body }, merge);
    }
    inner.style.filter = `url(#${id})`;
  }

  // MARK: - Reflections

  /**
   * The shape again, turned upside down below its bottom edge and faded out
   * from where it meets the shape.
   */
  reflect(node, outer, inner) {
    const reflection = node.reflection;
    const copy = inner.cloneNode(true);
    copy.classList.add("shape__reflection");
    copy.setAttribute("aria-hidden", "true");
    const turned = Boolean(node.rot && reflection.turns);
    const flips = node.fh || node.fv ? `scale(${node.fh ? -1 : 1}, ${node.fv ? -1 : 1})` : "";
    // Mirrored about the shape's own bottom edge, turning with it; or upright,
    // below the bottom of the space the turned shape covers.
    let bottom = node.h;
    if (node.rot && !turned) {
      const radians = (node.rot * Math.PI) / 180;
      bottom = node.h / 2 + (Math.abs(Math.sin(radians)) * node.w + Math.abs(Math.cos(radians)) * node.h) / 2;
    }
    const offset = 2 * bottom + reflection.dist - node.h;
    copy.style.transformOrigin = "50% 50%";
    copy.style.transform = turned
      ? `rotate(${node.rot}deg) translateY(${offset}px) scaleY(-1) ${flips}`
      : `translateY(${offset}px) scaleY(-1) ${node.rot ? `rotate(${node.rot}deg)` : ""} ${flips}`;
    const end = Math.max(reflection.endPos, 0.001) * 100;
    const mask = `linear-gradient(to top, rgba(0,0,0,${reflection.start}) 0%, rgba(0,0,0,${reflection.end}) ${end}%, transparent ${Math.min(end + 0.1, 100)}%)`;
    copy.style.maskImage = mask;
    copy.style.webkitMaskImage = mask;
    // Glows, soft edges and the like come across with the copy; a blur goes after them.
    if (reflection.blur > 0) copy.style.filter = [inner.style.filter, `blur(${reflection.blur / 2}px)`].filter(Boolean).join(" ");
    outer.append(copy);
  }
}

/** A run's look, as CSS. */
export function runStyle(element, run, scale = 1) {
  const size = run.sz * scale * (run.base ? 2 / 3 : 1);
  element.style.fontFamily = fontStack(run.f, run.ea, run.cs);
  element.style.fontSize = `${size}px`;
  element.style.color = run.c;
  if (run.b) element.style.fontWeight = "700";
  if (run.i) element.style.fontStyle = "italic";
  const lines = [run.u && "underline", run.s && "line-through"].filter(Boolean);
  if (lines.length) element.style.textDecoration = lines.join(" ");
  if (run.base) element.style.verticalAlign = run.base > 0 ? "super" : "sub";
  // Spacing shrinks with text fitted to its box, as Apple platforms kern it, but not with superscript.
  if (run.sp) element.style.letterSpacing = `${run.sp * scale}px`; // design-lint-allow (document content)
  if (run.outline) {
    element.style.webkitTextStroke = `${run.outline.w}px ${run.outline.c}`;
    element.style.paintOrder = "stroke fill";
  }
  if (run.shadow) element.style.textShadow = `${run.shadow.dx}px ${run.shadow.dy}px ${run.shadow.blur / 2}px ${run.shadow.c}`;
}

/**
 * Widens each tab in the paragraphs under `root` so the text after it lies on
 * its stop as PowerPoint lays it: from the left of the text, or the right in
 * a right-to-left paragraph, by its left edge, middle or right edge, or with its decimal point centred on the stop;
 * past the paragraph's own stops, on every multiple of the default tab size.
 * Measured with offsets, which slide zoom and turned text leave alone.
 * Text set in vertical lines keeps the page's own tabs.
 */
export function alignTabs(root) {
  for (const paragraph of root.querySelectorAll(".text__p[data-tabs]")) {
    if (paragraph.closest(".text[data-vertical]")) continue;
    const stops = JSON.parse(paragraph.dataset.tabs);
    const interval = Number(paragraph.dataset.dts) || 72;
    const tabs = [...paragraph.querySelectorAll(":scope > .text__tab")];
    // How far along the line an element starts: from the left, or from the right in a right-to-left paragraph.
    const rightToLeft = paragraph.style.direction === "rtl";
    const along = (element) => rightToLeft
      ? paragraph.offsetLeft + paragraph.offsetWidth - element.offsetLeft - element.offsetWidth
      : element.offsetLeft - paragraph.offsetLeft;
    for (const tab of tabs) tab.style.paddingInlineStart = "0px";
    for (const tab of tabs) {
      const at = along(tab);
      const [stop, alignment] = stops.find(([location]) => location > at + 0.5)
        ?? [(Math.floor(at / interval + 0.001) + 1) * interval, "l"];
      const segment = tab.nextElementSibling?.classList.contains("text__seg") ? tab.nextElementSibling : null;
      let before = 0;
      if (segment && alignment === "ctr") before = segment.offsetWidth / 2;
      if (segment && alignment === "r") before = segment.offsetWidth;
      if (segment && alignment === "dec") {
        const point = segment.querySelector(".text__point");
        const lead = segment.querySelector(".text__lead");
        before = point ? (lead?.offsetWidth ?? 0) + point.offsetWidth / 2 : segment.offsetWidth;
      }
      // Widened, then corrected by where the text after it actually lands, as
      // some browsers still give a tab of no size a space's width.
      const target = stop - before;
      tab.style.paddingInlineStart = `${Math.max(target - at, 0)}px`;
      if (!segment) continue;
      const off = along(segment) - Math.max(target, at);
      if (Math.abs(off) > 0.25) tab.style.paddingInlineStart = `${Math.max(target - at - off, 0)}px`;
    }
  }
}

function isEmptyText(body) {
  return body.paras.every((paragraph) => paragraph.runs.every((run) => !run.t || run.br));
}

/** `#rrggbb` or `rgba(…)` as fractions. */
function channels(color) {
  if (color.startsWith("#")) return [1, 3, 5].map((index) => parseInt(color.slice(index, index + 2), 16) / 255);
  const values = color.match(/[\d.]+/g)?.map(Number) ?? [0, 0, 0];
  return values.slice(0, 3).map((value) => value / 255);
}

/** Measures letters' ink and fonts' ascent, as a canvas sets them. */
let measuring = null;
function fontMetrics(font, text) {
  measuring ??= document.createElement("canvas").getContext("2d");
  measuring.font = font;
  const metrics = measuring.measureText(text);
  return {
    ascent: metrics.fontBoundingBoxAscent ?? metrics.actualBoundingBoxAscent,
    descent: metrics.fontBoundingBoxDescent ?? metrics.actualBoundingBoxDescent,
    inkAscent: metrics.actualBoundingBoxAscent, inkDescent: metrics.actualBoundingBoxDescent,
  };
}

/**
 * Lays a WordArt box's letters along its warp, as the Apple apps do: the text
 * stays laid out flat, unseen, and each letter is measured there (offsets,
 * which zoom and turned shapes leave alone) and drawn again in SVG where the
 * warp puts it. Text being typed stays flat, and shows its own letters.
 */
export function warpText(box) {
  const body = box.textBody;
  const flow = box.querySelector(":scope > .text__flow");
  box.querySelector(":scope > .text__warp")?.remove();
  delete box.dataset.warped;
  if (!body?.warp || !flow || box.classList.contains("is-editing")) return;
  // Every letter in a span of its own, so it can be measured where it lies, none joined to the next.
  flow.style.fontVariantLigatures = "none";
  flow.style.fontKerning = "none";
  const segmenter = typeof Intl.Segmenter === "function" ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
  for (const run of flow.querySelectorAll(".text__run, .text__bullet")) {
    if (run.querySelector(".text__glyph") || !run.textContent) continue;
    const text = run.textContent;
    const letters = segmenter ? Array.from(segmenter.segment(text), (part) => part.segment) : Array.from(text);
    run.replaceChildren(...letters.map((letter) => {
      const span = html("span", "text__glyph");
      span.textContent = letter;
      return span;
    }));
  }
  // The letters line by line: a line ends at a break, a new paragraph, or where the text wraps back.
  const lines = [];
  let line = null;
  let paragraph = null;
  for (const element of flow.querySelectorAll(".text__glyph, br")) {
    const inParagraph = element.closest(".text__p");
    if (element.localName === "br") {
      line = null;
      continue;
    }
    const style = getComputedStyle(element);
    const size = parseFloat(style.fontSize) || 0;
    const font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    const metrics = fontMetrics(font, element.textContent);
    const letter = {
      element, style, font, size, text: element.textContent, left: element.offsetLeft, right: element.offsetLeft + element.offsetWidth,
      baseline: element.offsetTop + metrics.ascent, metrics, blank: !element.textContent.trim(),
    };
    if (!line || inParagraph !== paragraph || letter.left < line.letters[line.letters.length - 1].left - 1) {
      line = { letters: [] };
      lines.push(line);
      paragraph = inParagraph;
    }
    line.letters.push(letter);
  }
  for (const each of lines) {
    const inked = each.letters.filter((letter) => !letter.blank);
    each.start = Math.min(...each.letters.map((letter) => letter.left));
    each.width = Math.max(...(inked.length ? inked : each.letters).map((letter) => letter.right)) - each.start;
    each.baseline = Math.max(...each.letters.map((letter) => letter.baseline));
    each.top = Math.min(...each.letters.map((letter) => (letter.blank ? letter.baseline - letter.metrics.ascent : letter.baseline - letter.metrics.inkAscent)));
    each.bottom = Math.max(...each.letters.map((letter) => (letter.blank ? letter.baseline + letter.metrics.descent : letter.baseline + letter.metrics.inkDescent)));
  }
  const bands = warpBands(body.warp);
  // Each band's lines: how high and low their letters reach, and the first one's baseline.
  const reaches = new Map();
  lines.forEach((each, index) => {
    const band = bandForLine(bands, index, lines.length);
    const reach = reaches.get(band);
    reaches.set(band, reach
      ? { top: Math.min(reach.top, each.top), bottom: Math.max(reach.bottom, each.bottom), baseline: reach.baseline }
      : { top: each.top, bottom: each.bottom, baseline: each.baseline });
  });
  // Drawn in the shape's own space, which the box sits in at the text's inset rectangle.
  const drawing = svg("svg", { class: "text__warp", width: 1, height: 1, overflow: "visible", "aria-hidden": "true" });
  Object.assign(drawing.style, { left: `${-body.x}px`, top: `${-body.y}px` });
  lines.forEach((each, index) => {
    const band = bandForLine(bands, index, lines.length);
    const reach = reaches.get(band);
    const place = placement(bands, band, reach.top, reach.bottom, reach.baseline);
    for (const letter of each.letters) {
      if (letter.blank) continue;
      const [a, b, c, d, e, f] = letterTransform(
        bands, place, letter.left - each.start, letter.right - each.start, each.width, letter.baseline, letter.size,
      );
      // SVG letters stand on a y axis pointing down.
      const glyph = svg("text", { transform: `matrix(${a} ${b} ${-c} ${-d} ${e} ${f})` }, drawing);
      glyph.textContent = letter.text;
      Object.assign(glyph.style, {
        font: letter.font, fill: letter.style.color, fontKerning: "none",
      });
      const stroke = letter.style.webkitTextStrokeWidth;
      if (stroke && parseFloat(stroke) > 0) {
        Object.assign(glyph.style, { stroke: letter.style.webkitTextStrokeColor, strokeWidth: stroke, paintOrder: "stroke fill" });
      }
      if (letter.style.textShadow && letter.style.textShadow !== "none") {
        const [color, dx, dy, blur] = parseShadow(letter.style.textShadow);
        if (color) glyph.style.filter = `drop-shadow(${dx} ${dy} ${blur} ${color})`;
      }
    }
  });
  box.append(drawing);
  box.dataset.warped = "1";
}

/** A computed `text-shadow`'s colour and offsets, as `drop-shadow()` takes them. */
function parseShadow(shadow) {
  const color = shadow.match(/rgba?\([^)]*\)|#[0-9a-f]+/i)?.[0];
  const lengths = shadow.replace(color ?? "", "").trim().split(/\s+/).filter(Boolean);
  return [color, lengths[0] ?? "0px", lengths[1] ?? "0px", lengths[2] ?? "0px"];
}

/**
 * Shrinks the text in a box that shrinks on overflow, as PowerPoint would have
 * when it last saved: a step at a time, closing its lines up and then setting
 * it smaller, down to the least step, which stands even if the text still
 * overflows. The engine gives the steps, none when the file said how far.
 */
export function fitText(box) {
  const body = box.textBody;
  const flow = box.querySelector(".text__flow");
  if (!body || !flow || body.fit !== "shrink" || !body.steps?.length) return;
  const drawer = new SlideDrawer(null);
  const shrink = (fits) => {
    for (const [scale, reduce] of body.steps) {
      drawer.fillFlow(flow, body, { scale, reduce });
      if (fits()) return;
    }
  };
  if (body.cols > 1 && !box.dataset.vertical) {
    // Text in columns overflows only when the last column runs past the bottom.
    if (!layoutColumns(box)) shrink(() => layoutColumns(box));
    return;
  }
  // Lines stack down the box, or across it when they run vertically.
  const across = Boolean(box.dataset.vertical);
  const room = across ? box.clientWidth : box.clientHeight;
  const fits = () => (across ? flow.scrollWidth : flow.scrollHeight) <= room + 1;
  if (room && !fits()) shrink(fits);
}

/**
 * Lays text set in columns out as PowerPoint does: each column filled to the
 * bottom of the box before the next, and text that fits in the first column
 * only as tall as it is, so the box's anchor places it. Text running past the
 * last column is balanced across the columns, running on below the box, and
 * so is text in a shape that grows to fit it. Says whether the text fits.
 */
export function layoutColumns(box) {
  const body = box.textBody;
  const flow = box.querySelector(".text__flow");
  if (!body || !flow || !(body.cols > 1)) return true;
  Object.assign(flow.style, { columnCount: String(body.cols), columnFill: "", blockSize: "", inlineSize: "" });
  const room = box.clientHeight;
  if (body.fit === "grow" || box.dataset.vertical || !room) return true;
  // How tall the text stands in one column.
  const gap = body.colGap ?? 0;
  const width = (flow.clientWidth - gap * (body.cols - 1)) / body.cols;
  Object.assign(flow.style, { columnCount: "1", inlineSize: `${Math.max(width, 1)}px` });
  const single = flow.scrollHeight;
  Object.assign(flow.style, { columnCount: String(body.cols), inlineSize: "", columnFill: "auto" });
  if (single <= room + 1) {
    flow.style.blockSize = `${single + 1}px`;
    return true;
  }
  // Text past the last column is set in more columns beside the box, where the last paragraph ends.
  const fitsAt = (height) => {
    flow.style.blockSize = `${height}px`;
    const bounds = flow.getBoundingClientRect();
    const end = [...(flow.lastElementChild?.getClientRects() ?? [])];
    return !end.some((rect) => rect.left >= bounds.right - 1 || rect.right <= bounds.left + 1);
  };
  if (fitsAt(room)) return true;
  // Overflowing, the columns run on below the box, as short as they can be and hold it all.
  let low = room;
  let high = single + 1;
  while (high - low > 1) {
    const middle = (low + high) / 2;
    if (fitsAt(middle)) high = middle;
    else low = middle;
  }
  flow.style.blockSize = `${Math.ceil(high)}px`;
  return false;
}

/** Draws each table cell's borders over the grid, once its rows have their heights. */
export function drawTableBorders(grid) {
  const lines = grid.querySelector(".table__lines");
  if (!lines) return;
  lines.replaceChildren();
  for (const cell of grid.querySelectorAll(".table__cell[data-borders]")) {
    const borders = JSON.parse(cell.dataset.borders);
    const x = cell.offsetLeft;
    const y = cell.offsetTop;
    const w = cell.offsetWidth;
    const h = cell.offsetHeight;
    const edges = { t: [x, y, x + w, y], b: [x, y + h, x + w, y + h], l: [x, y, x, y + h], r: [x + w, y, x + w, y + h] };
    for (const [key, line] of Object.entries(borders)) {
      const [x1, y1, x2, y2] = edges[key];
      svg("line", { x1, y1, x2, y2, stroke: line.c, "stroke-width": line.w, "stroke-dasharray": line.dash?.join(" ") }, lines);
    }
  }
}

// MARK: - Animation

const FAR = 4000;

/**
 * Shows a slide as its animations have it at one moment: the engine's
 * AnimationFrame (Bridge "frame") moving, sizing, turning, wiping, masking,
 * fading and recolouring each shape and paragraph. Shapes the frame leaves
 * out are drawn as they sit.
 */
export function applyFrame(root, frame) {
  for (const element of root.querySelectorAll(".shape.is-own")) {
    const look = frame?.shapes?.[element.dataset.id];
    appearance(element, look, element.offsetWidth || parseFloat(element.style.width), element.offsetHeight || parseFloat(element.style.height));
    recolour(element, look);
    const paragraphs = frame?.paras?.[element.dataset.id];
    for (const paragraph of element.querySelectorAll(".text__p")) {
      const paragraphLook = paragraphs?.[paragraph.dataset.i];
      appearance(paragraph, paragraphLook, paragraph.offsetWidth, paragraph.offsetHeight);
      recolour(paragraph, paragraphLook);
    }
  }
}

function appearance(element, look, width, height) {
  if (!look) {
    if (element.dataset.animated) {
      element.style.opacity = "";
      element.style.transform = "";
      element.style.clipPath = "";
      delete element.dataset.animated;
    }
    return;
  }
  element.dataset.animated = "1";
  element.style.opacity = look.o !== undefined ? String(Math.max(look.o, 0)) : "";
  const transforms = [];
  if (look.dx || look.dy) transforms.push(`translate(${look.dx ?? 0}px, ${look.dy ?? 0}px)`);
  if (look.r) transforms.push(`rotate(${look.r}deg)`);
  const sx = (look.s ?? 1) * (look.sx ?? 1);
  const sy = (look.s ?? 1) * (look.sy ?? 1);
  if (sx !== 1 || sy !== 1) transforms.push(`scale(${Math.max(sx, 0.0001)}, ${Math.max(sy, 0.0001)})`);
  element.style.transform = transforms.join(" ");
  if (look.reveal) {
    // Open on every side but the one the wipe moves, so outlines and shadows there show.
    const f = Math.min(Math.max(look.reveal.f, 0), 1);
    const points = {
      t: [[-FAR, -FAR], [width + FAR, -FAR], [width + FAR, height * f], [-FAR, height * f]],
      b: [[-FAR, height * (1 - f)], [width + FAR, height * (1 - f)], [width + FAR, height + FAR], [-FAR, height + FAR]],
      l: [[-FAR, -FAR], [width * f, -FAR], [width * f, height + FAR], [-FAR, height + FAR]],
      r: [[width * (1 - f), -FAR], [width + FAR, -FAR], [width + FAR, height + FAR], [width * (1 - f), height + FAR]],
    }[look.reveal.edge];
    element.style.clipPath = `polygon(${points.map(([x, y]) => `${x}px ${y}px`).join(", ")})`;
  } else if (look.mask !== undefined) {
    element.style.clipPath = look.mask ? `path(evenodd, "${look.mask}")` : "polygon(0 0, 0 0, 0 0)";
  } else {
    element.style.clipPath = "";
  }
}

function recolour(element, look) {
  if (look?.fill) for (const fill of element.querySelectorAll(":scope > .shape__body > .shape__outline > .shape__fill")) fill.setAttribute("fill", look.fill);
  if (look?.stroke) for (const line of element.querySelectorAll(":scope > .shape__body > .shape__outline > .shape__line")) line.setAttribute("stroke", look.stroke);
  if (look?.text) for (const run of element.querySelectorAll(".text__run, .text__bullet")) run.style.color = look.text;
}
