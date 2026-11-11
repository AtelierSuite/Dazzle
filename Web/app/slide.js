// Draws a slide from the scene the engine describes (WebRenderer.swift): the
// background, the master's and layout's artwork, then each shape as an
// absolutely placed box holding its outline in SVG and its text in HTML. One
// slide point is one CSS pixel; whoever shows the slide scales it.
//
// The same drawing serves the editor's canvas, the navigator's thumbnails, the
// presenter view and the audience window.

const SVG = "http://www.w3.org/2000/svg";
let uniqueId = 0;
const nextId = (prefix) => `${prefix}${++uniqueId}`;

/** Text turned a quarter, letters and all, by how far. Other vertical text is set in vertical lines (app.css). */
const TURNED_TEXT = { vert: 90, vert270: -90 };

/** Office faces that devices other than Windows rarely have, and what to set them in instead. */
const SUBSTITUTES = [
  [/^calibri/, ["Carlito"]],
  [/^cambria/, ["Caladea", "Georgia"]],
  [/^(aptos|segoe|arial nova|tahoma|candara|corbel|franklin gothic)/, []],
  [/^century gothic/, ["Avenir Next", "Futura", "URW Gothic"]],
  [/^gill sans/, ["Gill Sans", "Gill Sans MT"]],
  [/^(book antiqua|palatino)/, ["Palatino", "Palatino Linotype", "TeX Gyre Pagella"]],
  [/^garamond/, ["Garamond", "EB Garamond", "Baskerville"]],
  [/^(consolas|lucida console)/, ["Menlo", "Monaco", "Consolas"]],
  [/^(meiryo|yu gothic|ms gothic|ms pgothic|游ゴシック|メイリオ|ｍｓ ｐゴシック)/, ["Hiragino Sans", "Yu Gothic", "Meiryo", "Noto Sans JP", "Noto Sans CJK JP"]],
  [/^(ms mincho|ms pmincho|yu mincho|游明朝|ｍｓ 明朝)/, ["Hiragino Mincho ProN", "Yu Mincho", "Noto Serif JP", "Noto Serif CJK JP"]],
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

const quote = (family) => `"${String(family).replace(/["\\]/g, "\\$&")}"`;

/** A CSS font-family list for a run: its own face, East Asian face, then the closest the device has. */
export function fontStack(family, eastAsian) {
  const names = [];
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

  /** Shrinks text that says it shrinks to fit, once the slide is laid out on the page. */
  fit(root) {
    for (const box of root.querySelectorAll(".text[data-fit='shrink']")) fitText(box);
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
    if (node.fill && node.path) {
      const fill = svg("path", { d: node.path, "fill-rule": "evenodd" }, geometry);
      this.paint(fill, node.fill, { x: 0, y: 0, w: node.w, h: node.h }, context, geometry);
      fill.classList.add("shape__fill");
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

  /** Fills `element` with a scene's paint, or strokes it when `attribute` is "stroke": a colour, a gradient or a picture. */
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
      let gradient;
      if (paint.t === "radial") {
        const cx = box.x + box.w * paint.fx;
        const cy = box.y + box.h * paint.fy;
        const r = Math.max(...[[box.x, box.y], [box.x + box.w, box.y], [box.x, box.y + box.h], [box.x + box.w, box.y + box.h]]
          .map(([x, y]) => Math.hypot(x - cx, y - cy)));
        gradient = svg("radialGradient", { id, gradientUnits: "userSpaceOnUse", cx, cy, r }, context.defs);
      } else {
        const angle = (paint.angle * Math.PI) / 180;
        const half = (Math.abs(Math.cos(angle)) * box.w + Math.abs(Math.sin(angle)) * box.h) / 2;
        const cx = box.x + box.w / 2;
        const cy = box.y + box.h / 2;
        gradient = svg("linearGradient", {
          id, gradientUnits: "userSpaceOnUse",
          x1: cx - Math.cos(angle) * half, y1: cy - Math.sin(angle) * half, x2: cx + Math.cos(angle) * half, y2: cy + Math.sin(angle) * half,
        }, context.defs);
      }
      for (const [offset, color] of paint.stops) svg("stop", { offset, "stop-color": color }, gradient);
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
        // A tile is laid at its own size: pixels at 96 to the inch.
        const width = natural.width * 0.75;
        const height = natural.height * 0.75;
        pattern.setAttribute("width", width);
        pattern.setAttribute("height", height);
        image.setAttribute("width", width);
        image.setAttribute("height", height);
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

  /** Greyscale, duotone, brightness and contrast, as SVG filters. */
  effects(target, fx, context) {
    if (!fx) return;
    if (fx.opacity !== undefined) target.setAttribute("opacity", fx.opacity);
    if (!fx.grey && !fx.duotone && !fx.brightness && !fx.contrast) return;
    const id = nextId("f");
    const filter = svg("filter", { id, "color-interpolation-filters": "sRGB" }, context.defs);
    if (fx.grey || fx.duotone) {
      svg("feColorMatrix", { type: "matrix", values: "0.299 0.587 0.114 0 0 0.299 0.587 0.114 0 0 0.299 0.587 0.114 0 0 0 0 0 1 0" }, filter);
    }
    if (fx.duotone) {
      const [dark, light] = fx.duotone.map(channels);
      const transfer = svg("feComponentTransfer", {}, filter);
      ["R", "G", "B"].forEach((channel, index) => {
        svg(`feFunc${channel}`, { type: "table", tableValues: `${dark[index]} ${light[index]}` }, transfer);
      });
    }
    if (fx.brightness || fx.contrast) {
      // Office centres contrast on mid-grey, with half the brightness before it and half after.
      const c = Math.min(Math.max(fx.contrast ?? 0, -1), 1);
      const slope = c >= 0 ? 128 / (128 - 127 * c) : (128 + 127 * c) / 128;
      const shift = Math.min(Math.max(fx.brightness ?? 0, -1), 1) / 2;
      const intercept = shift * slope + 0.5 - 0.5 * slope + shift;
      const transfer = svg("feComponentTransfer", {}, filter);
      for (const channel of ["R", "G", "B"]) svg(`feFunc${channel}`, { type: "linear", slope, intercept }, transfer);
    }
    target.setAttribute("filter", `url(#${id})`);
  }

  // MARK: - Pictures

  picture(node, parent, context) {
    const geometry = svg("svg", { class: "shape__outline", width: node.w, height: node.h, viewBox: `0 0 ${Math.max(node.w, 0.01)} ${Math.max(node.h, 0.01)}`, overflow: "visible" }, parent);
    const clip = nextId("c");
    svg("path", { d: node.path }, svg("clipPath", { id: clip }, context.defs));
    const group = svg("g", { "clip-path": `url(#${clip})` }, geometry);
    const image = svg("image", {
      x: node.image.x, y: node.image.y, width: node.image.w, height: node.image.h, preserveAspectRatio: "none",
    }, group);
    this.setImage(image, node.src);
    this.effects(image, node.fx, context);
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
    const flow = html("div", "text__flow", box);
    if (!body.wrap) {
      flow.style.inlineSize = "max-content";
      const align = body.paras[0]?.align ?? "l";
      flow.style.alignSelf = align === "ctr" ? "center" : align === "r" ? "flex-end" : "flex-start";
    }
    this.fillFlow(flow, body, { scale: scale ?? body.scale ?? 1, reduce: reduce ?? body.reduce ?? 0, prompt });
    return box;
  }

  fillFlow(flow, body, { scale = 1, reduce = 0, prompt = false, editable = false } = {}) {
    flow.replaceChildren();
    flow.dataset.scale = scale;
    for (const paragraph of body.paras) flow.append(this.paragraph(paragraph, { scale, reduce, prompt, editable }));
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
    let hasText = false;
    for (const run of paragraph.runs) {
      if (run.br) {
        const br = document.createElement("br");
        br.dataset.p = paragraph.i;
        br.dataset.r = run.r;
        element.append(br);
        continue;
      }
      const span = html("span", "text__run", element);
      span.dataset.p = paragraph.i;
      span.dataset.r = run.r;
      span.textContent = run.t;
      runStyle(span, run, scale);
      if (run.field) {
        span.dataset.field = run.field;
        span.dataset.len = run.len ?? run.t.length;
        if (editable) span.contentEditable = "false";
      }
      if (run.link) span.dataset.link = JSON.stringify(run.link);
      if (run.t) hasText = true;
    }
    if (!hasText) {
      // An empty paragraph still takes a line, as tall as its end-of-paragraph text.
      const end = html("span", "text__end", element);
      runStyle(end, paragraph.end, scale);
      end.append(document.createElement("br"));
    }
    return element;
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
    if (reflection.blur > 0) copy.style.filter = `blur(${reflection.blur / 2}px)`;
    outer.append(copy);
  }
}

/** A run's look, as CSS. */
export function runStyle(element, run, scale = 1) {
  const size = run.sz * scale * (run.base ? 2 / 3 : 1);
  element.style.fontFamily = fontStack(run.f, run.ea);
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

function isEmptyText(body) {
  return body.paras.every((paragraph) => paragraph.runs.every((run) => !run.t || run.br));
}

/** `#rrggbb` or `rgba(…)` as fractions. */
function channels(color) {
  if (color.startsWith("#")) return [1, 3, 5].map((index) => parseInt(color.slice(index, index + 2), 16) / 255);
  const values = color.match(/[\d.]+/g)?.map(Number) ?? [0, 0, 0];
  return values.slice(0, 3).map((value) => value / 255);
}

/**
 * Shrinks the text in a box that shrinks on overflow, as PowerPoint would have
 * when it last saved, a tenth at a time.
 */
export function fitText(box) {
  const body = box.textBody;
  const flow = box.querySelector(".text__flow");
  if (!body || !flow || body.fit !== "shrink" || (body.scale ?? 1) !== 1) return;
  // Lines stack down the box, or across it when they run vertically.
  const across = Boolean(box.dataset.vertical);
  const room = across ? box.clientWidth : box.clientHeight;
  const used = () => (across ? flow.scrollWidth : flow.scrollHeight);
  if (!room || used() <= room + 1) return;
  const drawer = new SlideDrawer(null);
  for (let scale = 0.9; scale >= 0.3 - 0.001; scale -= 0.1) {
    drawer.fillFlow(flow, body, { scale, reduce: 0.1 });
    if (used() <= room + 1) return;
  }
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
