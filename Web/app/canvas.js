// The slide being edited: drawn at the zoom the window asks for, with the
// selection's handles over it. Shapes are picked, moved, resized and turned
// here, and typed into in place; every change goes to the engine, which
// draws the slide again.

import { SlideDrawer, TURNED_TEXT, fitText, drawTableBorders } from "./slide.js";

const HANDLE = 8;
const SNAP = 5;
const ROTATE_DISTANCE = 22;

const isApple = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

/** A shape's corners on the slide, turned as it is. */
function corners(frame, rotation = 0) {
  const cx = frame.x + frame.w / 2;
  const cy = frame.y + frame.h / 2;
  const radians = (rotation * Math.PI) / 180;
  const cos = Math.cos(radians);
  const sin = Math.sin(radians);
  return [[frame.x, frame.y], [frame.x + frame.w, frame.y], [frame.x + frame.w, frame.y + frame.h], [frame.x, frame.y + frame.h]]
    .map(([x, y]) => [cx + (x - cx) * cos - (y - cy) * sin, cy + (x - cx) * sin + (y - cy) * cos]);
}

/** The upright rectangle covering a turned frame. */
function bounds(frame, rotation = 0) {
  const points = corners(frame, rotation);
  const xs = points.map((p) => p[0]);
  const ys = points.map((p) => p[1]);
  return { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
}

function contains(frame, rotation, x, y) {
  const cx = frame.x + frame.w / 2;
  const cy = frame.y + frame.h / 2;
  const radians = (-rotation * Math.PI) / 180;
  const dx = x - cx;
  const dy = y - cy;
  const lx = cx + dx * Math.cos(radians) - dy * Math.sin(radians);
  const ly = cy + dx * Math.sin(radians) + dy * Math.cos(radians);
  // Lines and very thin shapes get a little room either side.
  const slack = 3;
  return lx >= frame.x - slack && lx <= frame.x + frame.w + slack && ly >= frame.y - slack && ly <= frame.y + frame.h + slack;
}

const intersects = (a, b) => a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;

export class SlideCanvas extends EventTarget {
  /**
   * @param {HTMLElement} element where the slide goes
   * @param {import("./engine-client.js").EngineClient} engine
   * @param {import("./slide.js").MediaStore} media
   */
  constructor(element, engine, media) {
    super();
    this.element = element;
    this.engine = engine;
    this.drawer = new SlideDrawer(media);
    this.zoom = "fit";
    this.scale = 1;
    this.scene = null;
    this.slideID = null;
    this.selection = [];
    this.editing = null; // { id, cell?: { r, c }, flow, timer }
    this.element.classList.add("canvas");
    this.element.tabIndex = 0;
    this.element.setAttribute("role", "application");
    this.element.innerHTML = `<div class="canvas__stage"><div class="canvas__slide"></div><div class="canvas__overlay"></div></div>`;
    this.stage = this.element.querySelector(".canvas__stage");
    this.holder = this.element.querySelector(".canvas__slide");
    this.overlay = this.element.querySelector(".canvas__overlay");
    new ResizeObserver(() => this.layout()).observe(this.element);
    this.bindPointer();
    this.bindKeyboard();
  }

  // MARK: - Drawing

  /** Draws the slide again from the engine, keeping any typing in place. */
  async refresh({ keepEditing = true } = {}) {
    const slide = this.engine.state?.sel?.slide;
    if (!slide) {
      this.holder.replaceChildren();
      this.overlay.replaceChildren();
      this.scene = null;
      return;
    }
    const scene = await this.engine.call("scene", { slide, editing: true });
    if (this.engine.state?.sel?.slide !== slide) return;
    const caret = keepEditing && this.editing ? this.textSelection() : null;
    const editing = keepEditing ? this.editing : null;
    this.slideID = slide;
    this.scene = scene;
    const drawn = this.drawer.draw(scene, { editing: true });
    this.holder.replaceChildren(drawn);
    this.slide = drawn;
    this.layout();
    requestAnimationFrame(() => this.drawer.fit(drawn));
    this.editing = null;
    if (editing) this.beginEditing(editing.id, { cell: editing.cell, caret, quiet: true });
    this.syncSelection();
  }

  setZoom(zoom) {
    this.zoom = zoom;
    this.layout();
  }

  layout() {
    if (!this.scene) return;
    const padding = 32;
    const available = { w: this.element.clientWidth - padding * 2, h: this.element.clientHeight - padding * 2 };
    const fit = Math.max(Math.min(available.w / this.scene.w, available.h / this.scene.h), 0.05);
    this.scale = this.zoom === "fit" ? fit : Number(this.zoom);
    const width = this.scene.w * this.scale;
    const height = this.scene.h * this.scale;
    Object.assign(this.stage.style, {
      width: `${width}px`, height: `${height}px`,
      margin: `${Math.max((this.element.clientHeight - height) / 2, padding)}px ${Math.max((this.element.clientWidth - width) / 2, padding)}px`,
    });
    this.holder.style.transform = `scale(${this.scale})`;
    this.drawOverlay();
    this.dispatchEvent(new CustomEvent("zoom", { detail: this.scale }));
  }

  /** The slide point under a pointer event. */
  point(event) {
    const rect = this.stage.getBoundingClientRect();
    return { x: (event.clientX - rect.left) / this.scale, y: (event.clientY - rect.top) / this.scale };
  }

  // MARK: - Selection

  /** The slide's own shapes, topmost last, flattened to their frames. */
  get shapes() {
    return this.scene?.shapes ?? [];
  }

  shape(id) {
    return this.shapes.find((node) => node.id === id) ?? null;
  }

  shapeAt(point) {
    for (const node of [...this.shapes].reverse()) {
      if (contains(node, node.rot ?? 0, point.x, point.y)) return node;
    }
    return null;
  }

  /** Takes the selection from the engine's state. */
  syncSelection() {
    const sel = this.engine.state?.sel;
    this.selection = (sel?.shapes ?? []).filter((id) => this.shape(id));
    if (this.editing && !this.selection.includes(this.editing.id)) this.endEditing({ commit: false });
    this.drawOverlay();
  }

  async select(ids, { slide = this.slideID } = {}) {
    if (this.editing) await this.endEditing();
    this.selection = ids;
    this.drawOverlay();
    await this.engine.call("select", { slide, shapes: ids });
    this.dispatchEvent(new CustomEvent("selection"));
  }

  drawOverlay() {
    this.overlay.replaceChildren();
    if (!this.scene) return;
    const scale = this.scale;
    const make = (className, style = {}) => {
      const element = document.createElement("div");
      element.className = className;
      Object.assign(element.style, style);
      this.overlay.append(element);
      return element;
    };
    // Empty placeholders show where they are.
    for (const node of this.shapes) {
      if (!node.prompt) continue;
      // Drawn by the slide itself, dashed; nothing to add.
    }
    const selected = this.selection.map((id) => this.shape(id)).filter(Boolean);
    for (const node of selected) {
      const frame = this.preview?.[node.id] ?? node;
      const rotation = frame.rot ?? node.rot ?? 0;
      const box = make("canvas__selection", {
        left: `${frame.x * scale}px`, top: `${frame.y * scale}px`, width: `${frame.w * scale}px`, height: `${frame.h * scale}px`,
        transform: rotation ? `rotate(${rotation}deg)` : "",
      });
      if (node.locked) box.classList.add("is-locked");
      if (this.editing?.id === node.id) box.classList.add("is-editing");
      if (selected.length !== 1 || node.locked || this.editing?.id === node.id) continue;
      const handles = node.open ? ["nw", "se"] : ["nw", "n", "ne", "e", "se", "s", "sw", "w"];
      for (const handle of handles) {
        const element = document.createElement("span");
        element.className = `canvas__handle canvas__handle--${handle}`;
        element.dataset.handle = handle;
        box.append(element);
      }
      if (node.kind !== "table" && node.kind !== "chart") {
        const rotate = document.createElement("span");
        rotate.className = "canvas__handle canvas__handle--rotate";
        rotate.dataset.handle = "rotate";
        box.append(rotate);
      }
    }
    if (this.marquee) {
      const { x, y, w, h } = this.marquee;
      make("canvas__marquee", { left: `${x * scale}px`, top: `${y * scale}px`, width: `${w * scale}px`, height: `${h * scale}px` });
    }
    for (const guide of this.guides ?? []) {
      make(`canvas__guide canvas__guide--${guide.axis}`, guide.axis === "x"
        ? { left: `${guide.at * scale}px`, top: "0", height: `${this.scene.h * scale}px` }
        : { top: `${guide.at * scale}px`, left: "0", width: `${this.scene.w * scale}px` });
    }
  }

  // MARK: - Pointer

  bindPointer() {
    this.element.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || !this.scene) return;
      if (this.editing && event.target.closest?.("[contenteditable='true']")) return;
      const handle = event.target.closest?.("[data-handle]")?.dataset.handle;
      const point = this.point(event);
      if (!handle && this.editing) {
        // A click outside the text being typed ends typing.
        const node = this.shapeAt(point);
        if (node?.id === this.editing.id) return;
        this.endEditing();
      }
      this.element.focus({ preventScroll: true });
      if (handle) {
        event.preventDefault();
        this.drag(event, handle === "rotate" ? "rotate" : `resize:${handle}`);
        return;
      }
      const node = this.shapeAt(point);
      const toggle = event.shiftKey || (isApple ? event.metaKey : event.ctrlKey);
      if (!node) {
        if (!toggle) this.select([]);
        this.drag(event, "marquee");
        return;
      }
      if (toggle) {
        const ids = this.selection.includes(node.id) ? this.selection.filter((id) => id !== node.id) : [...this.selection, node.id];
        this.select(ids);
        return;
      }
      if (!this.selection.includes(node.id)) this.select([node.id]);
      if (!node.locked) this.drag(event, "move");
    });
    this.element.addEventListener("dblclick", (event) => {
      if (!this.scene || this.editing) return;
      const node = this.shapeAt(this.point(event));
      if (!node || node.locked) return;
      if (node.kind === "table") {
        const cell = event.target.closest?.(".table__cell");
        if (cell) this.beginEditing(node.id, { cell: { r: Number(cell.dataset.r), c: Number(cell.dataset.c) }, at: event });
        return;
      }
      if (node.kind === "chart") {
        this.dispatchEvent(new CustomEvent("command", { detail: "chartData" }));
        return;
      }
      if (node.kind === "picture" && !node.media) {
        this.dispatchEvent(new CustomEvent("command", { detail: "crop" }));
        return;
      }
      if (node.text || node.prompt) this.beginEditing(node.id, { at: event });
    });
    this.element.addEventListener("contextmenu", (event) => {
      if (event.target.closest?.("[contenteditable='true']")) return;
      const node = this.scene ? this.shapeAt(this.point(event)) : null;
      if (node && !this.selection.includes(node.id)) this.select([node.id]);
      this.dispatchEvent(new CustomEvent("contextmenu", { detail: { event, shape: node?.id ?? null } }));
    });
  }

  /** Follows the pointer until it is let go, moving, resizing, turning or rubber-banding. */
  drag(start, mode) {
    const origin = this.point(start);
    const nodes = this.selection.map((id) => this.shape(id)).filter((node) => node && !node.locked);
    const others = this.shapes.filter((node) => !this.selection.includes(node.id));
    let moved = false;
    const move = (event) => {
      const point = this.point(event);
      const dx = point.x - origin.x;
      const dy = point.y - origin.y;
      if (!moved && Math.hypot(dx * this.scale, dy * this.scale) < 3) return;
      moved = true;
      if (mode === "marquee") {
        this.marquee = { x: Math.min(origin.x, point.x), y: Math.min(origin.y, point.y), w: Math.abs(dx), h: Math.abs(dy) };
        // The crossings stay on the canvas while dragging; the selection is made once, when let go.
        this.drawOverlay();
        return;
      }
      if (mode === "move") {
        const [sx, sy, guides] = this.snapMove(nodes, dx, dy, others, event.altKey);
        this.preview = Object.fromEntries(nodes.map((node) => [node.id, { ...node, x: node.x + sx, y: node.y + sy }]));
        this.guides = guides;
      } else if (mode === "rotate") {
        const node = nodes[0];
        if (!node) return;
        const cx = node.x + node.w / 2;
        const cy = node.y + node.h / 2;
        let angle = (Math.atan2(point.y - cy, point.x - cx) * 180) / Math.PI + 90;
        // Steps of 15 degrees with Shift, and catching at each quarter turn.
        if (event.shiftKey) angle = Math.round(angle / 15) * 15;
        else for (const step of [0, 90, 180, 270, 360]) if (Math.abs(angle - step) < 3) angle = step;
        angle = Math.round((((angle % 360) + 360) % 360) * 10) / 10;
        this.preview = { [node.id]: { ...node, rot: angle } };
      } else if (mode.startsWith("resize:")) {
        const node = nodes[0];
        if (!node) return;
        this.preview = { [node.id]: this.resized(node, mode.slice(7), point, event.shiftKey || node.kind === "picture" && !event.altKey && false) };
      }
      this.applyPreview();
    };
    const up = async (event) => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      if (mode === "marquee") {
        const area = this.marquee;
        this.marquee = null;
        if (area) {
          const hits = this.shapes.filter((node) => !node.art && intersects(area, bounds(node, node.rot ?? 0))).map((node) => node.id);
          const toggle = event.shiftKey || (isApple ? event.metaKey : event.ctrlKey);
          await this.select(toggle ? [...new Set([...this.selection, ...hits])] : hits);
        } else {
          this.drawOverlay();
        }
        return;
      }
      const preview = this.preview;
      this.preview = null;
      this.guides = null;
      if (!moved || !preview) {
        this.drawOverlay();
        return;
      }
      const frames = {};
      for (const [id, frame] of Object.entries(preview)) {
        frames[id] = { x: frame.x, y: frame.y, w: frame.w, h: frame.h };
        if (mode === "rotate" || (frame.rot ?? 0) !== (this.shape(id)?.rot ?? 0)) frames[id].rot = frame.rot ?? 0;
      }
      await this.engine.call("setFrames", { frames });
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  /** Moves the drawn shapes where the drag has them, before the engine hears of it. */
  applyPreview() {
    for (const [id, frame] of Object.entries(this.preview ?? {})) {
      const element = this.slide?.querySelector(`.shape.is-own[data-id="${id}"]`);
      if (!element) continue;
      const node = this.shape(id);
      element.style.left = `${frame.x}px`;
      element.style.top = `${frame.y}px`;
      element.style.width = `${frame.w}px`;
      element.style.height = `${frame.h}px`;
      const body = element.querySelector(".shape__body");
      const transforms = [];
      if (frame.rot) transforms.push(`rotate(${frame.rot}deg)`);
      if (node?.fh || node?.fv) transforms.push(`scale(${node.fh ? -1 : 1}, ${node.fv ? -1 : 1})`);
      body.style.transform = transforms.join(" ");
      // Outlines stretch with the frame until the engine draws them again.
      const outline = body.querySelector(":scope > .shape__outline");
      if (outline && node && (frame.w !== node.w || frame.h !== node.h)) {
        outline.setAttribute("width", frame.w);
        outline.setAttribute("height", frame.h);
        outline.setAttribute("preserveAspectRatio", "none");
      }
    }
    this.drawOverlay();
  }

  resized(node, handle, point, keepRatio) {
    // Worked out in the shape's own turned space, keeping the opposite side where it is.
    const rotation = ((node.rot ?? 0) * Math.PI) / 180;
    const cos = Math.cos(rotation);
    const sin = Math.sin(rotation);
    const cx = node.x + node.w / 2;
    const cy = node.y + node.h / 2;
    const local = { x: (point.x - cx) * cos + (point.y - cy) * sin, y: -(point.x - cx) * sin + (point.y - cy) * cos };
    let left = -node.w / 2;
    let right = node.w / 2;
    let top = -node.h / 2;
    let bottom = node.h / 2;
    if (handle.includes("w")) left = Math.min(local.x, right - 1);
    if (handle.includes("e")) right = Math.max(local.x, left + 1);
    if (handle.includes("n")) top = Math.min(local.y, bottom - 1);
    if (handle.includes("s")) bottom = Math.max(local.y, top + 1);
    if (keepRatio && node.w > 0 && node.h > 0) {
      const ratio = node.w / node.h;
      const width = right - left;
      const height = bottom - top;
      if (handle.length === 2) {
        if (width / height > ratio) {
          const h = width / ratio;
          if (handle.includes("n")) top = bottom - h; else bottom = top + h;
        } else {
          const w = height * ratio;
          if (handle.includes("w")) left = right - w; else right = left + w;
        }
      } else if (handle === "n" || handle === "s") {
        const w = height * ratio;
        left = -w / 2;
        right = w / 2;
      } else {
        const h = width / ratio;
        top = -h / 2;
        bottom = h / 2;
      }
    }
    // Back to slide space: the new box's centre, turned.
    const mx = (left + right) / 2;
    const my = (top + bottom) / 2;
    const ncx = cx + mx * cos - my * sin;
    const ncy = cy + mx * sin + my * cos;
    const w = right - left;
    const h = bottom - top;
    return { ...node, x: ncx - w / 2, y: ncy - h / 2, w, h };
  }

  /** How far a move goes, caught on the slide's edges and middle and other shapes' edges and middles. */
  snapMove(nodes, dx, dy, others, disabled) {
    if (disabled || !nodes.length) return [dx, dy, []];
    const box = nodes.map((node) => bounds({ ...node, x: node.x + dx, y: node.y + dy }, node.rot ?? 0))
      .reduce((a, b) => ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.max(a.x + a.w, b.x + b.w) - Math.min(a.x, b.x), h: Math.max(a.y + a.h, b.y + b.h) - Math.min(a.y, b.y) }));
    const xs = [0, this.scene.w / 2, this.scene.w];
    const ys = [0, this.scene.h / 2, this.scene.h];
    for (const other of others) {
      if (other.art) continue;
      const b = bounds(other, other.rot ?? 0);
      xs.push(b.x, b.x + b.w / 2, b.x + b.w);
      ys.push(b.y, b.y + b.h / 2, b.y + b.h);
    }
    const limit = SNAP / this.scale;
    const guides = [];
    const best = (edges, targets) => {
      let found = null;
      for (const edge of edges) for (const target of targets) {
        const distance = target - edge;
        if (Math.abs(distance) <= limit && (!found || Math.abs(distance) < Math.abs(found.distance))) found = { distance, target };
      }
      return found;
    };
    const sx = best([box.x, box.x + box.w / 2, box.x + box.w], xs);
    const sy = best([box.y, box.y + box.h / 2, box.y + box.h], ys);
    if (sx) guides.push({ axis: "x", at: sx.target });
    if (sy) guides.push({ axis: "y", at: sy.target });
    return [dx + (sx?.distance ?? 0), dy + (sy?.distance ?? 0), guides];
  }

  // MARK: - Keyboard

  bindKeyboard() {
    this.element.addEventListener("keydown", (event) => {
      if (this.editing) {
        if (event.key === "Escape") {
          event.preventDefault();
          this.endEditing();
        }
        return;
      }
      if (event.target !== this.element) return;
      const mod = isApple ? event.metaKey : event.ctrlKey;
      if (mod) return;
      const step = event.shiftKey ? 10 : 1;
      const arrows = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
      if (arrows[event.key] && this.selection.length) {
        event.preventDefault();
        const [dx, dy] = arrows[event.key];
        const frames = {};
        for (const id of this.selection) {
          const node = this.shape(id);
          if (node && !node.locked) frames[id] = { x: node.x + dx, y: node.y + dy, w: node.w, h: node.h };
        }
        this.engine.call("setFrames", { frames });
        return;
      }
      if ((event.key === "Backspace" || event.key === "Delete") && this.selection.length) {
        event.preventDefault();
        this.dispatchEvent(new CustomEvent("command", { detail: "delete" }));
        return;
      }
      if (event.key === "Escape" && this.selection.length) {
        event.preventDefault();
        this.select([]);
        return;
      }
      if (event.key === "Enter" && this.selection.length === 1) {
        const node = this.shape(this.selection[0]);
        if (node && !node.locked && (node.text || node.prompt)) {
          event.preventDefault();
          this.beginEditing(node.id, { selectAll: true });
        }
        return;
      }
      if (event.key === "Tab" && this.shapes.length) {
        event.preventDefault();
        const index = this.shapes.findIndex((node) => node.id === this.selection[this.selection.length - 1]);
        const next = this.shapes[(index + (event.shiftKey ? -1 : 1) + this.shapes.length) % this.shapes.length];
        this.select([next.id]);
        return;
      }
      // Typing over a selected shape starts typing into it.
      if (event.key.length === 1 && !event.altKey && this.selection.length === 1) {
        const node = this.shape(this.selection[0]);
        if (node && !node.locked && (node.text || node.prompt) && node.kind === "shape") {
          this.beginEditing(node.id, { replace: true });
        }
      }
    });
  }

  // MARK: - Typing

  /** The text box a shape, or one of its table cells, shows its text in. */
  textBox(id, cell) {
    const element = this.slide?.querySelector(`.shape.is-own[data-id="${id}"]`);
    if (!element) return null;
    if (cell) return element.querySelector(`.table__cell[data-r="${cell.r}"][data-c="${cell.c}"] .text`);
    return element.querySelector(":scope > .shape__body > .text");
  }

  /** The text box for typing, made from the shape's own text when an empty placeholder shows a prompt. */
  editableBox(node, cell) {
    let box = this.textBox(node.id, cell);
    if (!cell && node.prompt && box?.classList.contains("text--prompt")) {
      box.remove();
      box = this.drawer.text(node.text, node);
      this.slide.querySelector(`.shape.is-own[data-id="${node.id}"] > .shape__body`).append(box);
      this.slide.querySelector(`.shape.is-own[data-id="${node.id}"] .shape__prompt-outline`)?.remove();
    }
    return box;
  }

  async beginEditing(id, { cell = null, at = null, caret = null, selectAll = false, replace = false, quiet = false } = {}) {
    const node = this.shape(id);
    if (!node) return;
    if (!quiet) {
      if (cell) await this.engine.call("selectCell", { r: cell.r, c: cell.c, editing: true });
      else await this.engine.call("beginText", { shape: id });
    }
    const box = this.editableBox(node, cell);
    if (!box) return;
    const flow = box.querySelector(".text__flow");
    const body = box.textBody;
    // Typed at full size: shrinking applies again when typing ends.
    this.drawer.fillFlow(flow, body, { scale: body.scale ?? 1, reduce: body.reduce ?? 0, editable: true });
    flow.contentEditable = "true";
    flow.spellcheck = true;
    flow.classList.add("is-editing");
    box.classList.add("is-editing");
    this.editing = { id, cell, flow, box, timer: null, body };
    this.selection = [id];
    this.drawOverlay();
    flow.addEventListener("input", () => this.scheduleSync());
    flow.addEventListener("paste", (event) => {
      event.preventDefault();
      const text = event.clipboardData?.getData("text/plain") ?? "";
      document.execCommand("insertText", false, text.replace(/\r\n?/g, "\n"));
    });
    flow.addEventListener("keydown", (event) => {
      if (event.key === "Tab") {
        event.preventDefault();
        this.dispatchEvent(new CustomEvent("command", { detail: event.shiftKey ? "outdent" : "indent" }));
      }
    });
    flow.addEventListener("drop", (event) => event.preventDefault());
    flow.focus({ preventScroll: true });
    const selection = document.getSelection();
    if (caret) {
      this.setTextSelection(caret.loc, caret.len);
    } else if (replace || selectAll) {
      selection.selectAllChildren(flow);
    } else if (at && document.caretRangeFromPoint) {
      const range = document.caretRangeFromPoint(at.clientX, at.clientY);
      if (range && flow.contains(range.startContainer)) {
        selection.removeAllRanges();
        selection.addRange(range);
      }
    } else {
      selection.selectAllChildren(flow);
      selection.collapseToEnd();
    }
    this.watchSelection();
    this.dispatchEvent(new CustomEvent("editing", { detail: true }));
  }

  watchSelection() {
    if (this.selectionWatcher) return;
    this.selectionWatcher = () => {
      if (!this.editing) return;
      clearTimeout(this.selectionTimer);
      this.selectionTimer = setTimeout(async () => {
        const range = this.textSelection();
        if (!range || !this.editing) return;
        await this.sync();
        const look = await this.engine.call("textSelection", range).catch(() => null);
        if (look) this.dispatchEvent(new CustomEvent("look", { detail: look }));
      }, 150);
    };
    document.addEventListener("selectionchange", this.selectionWatcher);
  }

  scheduleSync() {
    if (!this.editing) return;
    clearTimeout(this.editing.timer);
    this.editing.timer = setTimeout(() => this.sync(), 400);
    this.dispatchEvent(new CustomEvent("typed"));
  }

  /** Sends what has been typed to the engine. */
  async sync() {
    const editing = this.editing;
    if (!editing) return;
    clearTimeout(editing.timer);
    editing.timer = null;
    const paras = readParagraphs(editing.flow);
    const signature = JSON.stringify(paras);
    if (signature === editing.sent) return;
    editing.sent = signature;
    const args = { paras };
    // Text grows its shape as it is typed: down, or across when it runs vertically.
    if (editing.body.fit === "grow" && !editing.cell) {
      const node = this.shape(editing.id);
      if (!editing.body.vert) {
        args.height = editing.flow.scrollHeight + (node ? node.h - editing.body.h : 0);
      } else {
        // Text turned a quarter is laid out across the box's height, its lines stacked down the turned box.
        const across = editing.body.vert in TURNED_TEXT ? editing.flow.scrollHeight : editing.flow.scrollWidth;
        args.width = across + (node ? node.w - editing.body.w : 0);
      }
    }
    await this.engine.call("setText", args);
  }

  /** Ends typing, sending the last of it, and draws the slide again. */
  async endEditing({ commit = true } = {}) {
    const editing = this.editing;
    if (!editing) return;
    if (commit) await this.sync();
    if (this.editing !== editing) return;
    this.editing = null;
    editing.flow.contentEditable = "false";
    document.removeEventListener("selectionchange", this.selectionWatcher);
    this.selectionWatcher = null;
    await this.engine.call("endText").catch(() => {});
    this.dispatchEvent(new CustomEvent("editing", { detail: false }));
    await this.refresh({ keepEditing: false });
    this.element.focus({ preventScroll: true });
  }

  /** The selection in the text being typed, as offsets into it, counted as the engine counts them. */
  textSelection() {
    const flow = this.editing?.flow;
    const selection = document.getSelection();
    if (!flow || !selection?.rangeCount || !flow.contains(selection.anchorNode)) return null;
    const range = selection.getRangeAt(0);
    const start = offsetOf(flow, range.startContainer, range.startOffset);
    const end = offsetOf(flow, range.endContainer, range.endOffset);
    return { loc: Math.min(start, end), len: Math.abs(end - start) };
  }

  setTextSelection(loc, len) {
    const flow = this.editing?.flow;
    if (!flow) return;
    const start = positionAt(flow, loc);
    const end = positionAt(flow, loc + len);
    const range = document.createRange();
    range.setStart(start.node, start.offset);
    range.setEnd(end.node, end.offset);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  dispose() {
    clearTimeout(this.editing?.timer);
    this.editing = null;
    this.scene = null;
    this.holder.replaceChildren();
    this.overlay.replaceChildren();
  }
}

// MARK: - Reading typed text back

/** Whether a node is a placeholder line break the browser keeps in an empty line. */
function isTrailingBreak(node) {
  if (node.nodeName !== "BR") return false;
  let next = node.nextSibling;
  while (next && next.nodeType === Node.TEXT_NODE && !next.textContent) next = next.nextSibling;
  return !next;
}

/**
 * The editing flow's paragraphs as the engine takes them back: each with the
 * index of the paragraph it came from, and runs naming the runs they came from.
 */
export function readParagraphs(flow) {
  const paragraphs = [];
  const blocks = [...flow.children].filter((child) => child.nodeName === "P" || child.nodeName === "DIV");
  if (!blocks.length) blocks.push(flow);
  for (const block of blocks) {
    const source = block.dataset.i !== undefined ? Number(block.dataset.i) : null;
    const runs = [];
    const visit = (node, origin) => {
      if (node.nodeType === Node.TEXT_NODE) {
        const text = node.textContent.replace(/​/g, "");
        if (text) runs.push({ src: origin, t: text });
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const element = /** @type {HTMLElement} */ (node);
      if (element.classList.contains("text__bullet")) return;
      if (element.nodeName === "BR") {
        if (!isTrailingBreak(element)) runs.push({ src: spanOrigin(element, source), br: true, t: "" });
        return;
      }
      if (element.dataset.field !== undefined) {
        runs.push({ src: origin ?? spanOrigin(element, source), field: true, t: element.textContent });
        return;
      }
      const own = element.classList.contains("text__run") ? spanOrigin(element, source) : origin;
      for (const child of element.childNodes) visit(child, own);
    };
    for (const child of block.childNodes) visit(child, null);
    paragraphs.push({ src: source, runs });
  }
  return paragraphs;
}

function spanOrigin(element, paragraph) {
  const home = element.closest("p")?.dataset.i;
  const p = element.dataset.p !== undefined ? Number(element.dataset.p) : home !== undefined ? Number(home) : paragraph;
  return element.dataset.r !== undefined && p !== null ? [p, Number(element.dataset.r)] : null;
}

/** How many of the engine's characters a node holds: fields count as stored, breaks as one. */
function lengthOf(node) {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent.replace(/​/g, "").length;
  if (node.nodeType !== Node.ELEMENT_NODE) return 0;
  const element = /** @type {HTMLElement} */ (node);
  if (element.classList.contains("text__bullet")) return 0;
  if (element.nodeName === "BR") return isTrailingBreak(element) ? 0 : 1;
  if (element.dataset.field !== undefined) return Number(element.dataset.len ?? element.textContent.length);
  let total = 0;
  for (const child of element.childNodes) total += lengthOf(child);
  return total;
}

/** The engine offset of a DOM position inside the flow. */
function offsetOf(flow, container, offset) {
  const blocks = [...flow.children].filter((child) => child.nodeName === "P" || child.nodeName === "DIV");
  let total = 0;
  for (const [index, block] of blocks.entries()) {
    if (block === container || block.contains(container)) {
      return total + offsetWithin(block, container, offset);
    }
    total += lengthOf(block) + (index < blocks.length - 1 ? 1 : 0);
  }
  return total;
}

function offsetWithin(root, container, offset) {
  let total = 0;
  let done = false;
  const walk = (node) => {
    if (done) return;
    if (node === container) {
      if (node.nodeType === Node.TEXT_NODE) {
        total += node.textContent.slice(0, offset).replace(/​/g, "").length;
      } else {
        for (const child of [...node.childNodes].slice(0, offset)) total += lengthOf(child);
      }
      done = true;
      return;
    }
    if (node.nodeType === Node.ELEMENT_NODE && (node.dataset?.field !== undefined || node.nodeName === "BR" || node.classList?.contains("text__bullet"))) {
      total += lengthOf(node);
      return;
    }
    if (node.nodeType === Node.TEXT_NODE) {
      total += lengthOf(node);
      return;
    }
    for (const child of node.childNodes) {
      walk(child);
      if (done) return;
    }
  };
  walk(root);
  return total;
}

/** The DOM position at an engine offset. */
function positionAt(flow, target) {
  const blocks = [...flow.children].filter((child) => child.nodeName === "P" || child.nodeName === "DIV");
  let remaining = target;
  for (const [index, block] of blocks.entries()) {
    const length = lengthOf(block);
    if (remaining <= length || index === blocks.length - 1) {
      let found = null;
      const walk = (node) => {
        if (found) return;
        if (node.nodeType === Node.TEXT_NODE) {
          const length = node.textContent.length;
          if (remaining <= length) {
            found = { node, offset: remaining };
            return;
          }
          remaining -= length;
          return;
        }
        if (node.nodeType === Node.ELEMENT_NODE && (node.dataset?.field !== undefined || node.nodeName === "BR" || node.classList?.contains("text__bullet"))) {
          remaining -= lengthOf(node);
          if (remaining < 0) remaining = 0;
          return;
        }
        for (const child of node.childNodes) walk(child);
      };
      walk(block);
      return found ?? { node: block, offset: block.childNodes.length };
    }
    remaining -= length + 1;
  }
  return { node: flow, offset: flow.childNodes.length };
}

export { fitText, drawTableBorders };
