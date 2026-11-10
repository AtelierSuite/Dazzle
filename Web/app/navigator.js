// The slides down the side of the window: a thumbnail of each, drawn when it
// scrolls into view and again only when its slide changes. Slides are picked,
// several at once with Shift or ⌘, dragged into another order, and changed
// from their context menu.

import { SlideDrawer } from "./slide.js";
import { attachContextMenu } from "../design/menus.js";

const isApple = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

export class SlideNavigator extends EventTarget {
  /**
   * @param {HTMLElement} element
   * @param {import("./engine-client.js").EngineClient} engine
   * @param {import("./slide.js").MediaStore} media
   * @param {{ t: (key: string, ...values: any[]) => string, menu: (ids: string[]) => object[] }} options
   */
  constructor(element, engine, media, { t, menu }) {
    super();
    this.element = element;
    this.engine = engine;
    this.drawer = new SlideDrawer(media);
    this.t = t;
    this.menuFor = menu;
    this.selected = new Set();
    this.anchor = null;
    /** Thumbnails drawn, by slide id: { rev, element }. */
    this.drawn = new Map();
    this.element.classList.add("navigator");
    this.element.setAttribute("role", "listbox");
    this.element.setAttribute("aria-multiselectable", "true");
    this.element.tabIndex = 0;
    this.list = document.createElement("ol");
    this.list.className = "navigator__list";
    this.element.append(this.list);
    this.visible = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) this.drawThumbnail(entry.target);
    }, { root: this.element, rootMargin: "200px 0px" });
    new ResizeObserver(() => this.sizeThumbnails()).observe(this.element);
    this.bindKeyboard();
    attachContextMenu(this.element, (event) => {
      const row = event.target.closest?.(".navigator__slide");
      if (row && !this.selected.has(row.dataset.id)) this.pick(row.dataset.id);
      return this.menuFor([...this.selected]);
    });
  }

  get slides() {
    return this.engine.state?.slides ?? [];
  }

  /** Brings the list in step with the engine's slides, drawing again only what changed. */
  update() {
    const slides = this.slides;
    const current = this.engine.state?.sel?.slide;
    const rows = new Map([...this.list.children].map((row) => [row.dataset.id, row]));
    const ids = new Set(slides.map((slide) => slide.id));
    for (const [id, row] of rows) {
      if (!ids.has(id)) {
        this.visible.unobserve(row);
        row.remove();
        this.drawn.delete(id);
        this.selected.delete(id);
      }
    }
    let previous = null;
    slides.forEach((slide, index) => {
      let row = rows.get(slide.id);
      if (!row) row = this.makeRow(slide.id);
      const expected = previous ? previous.nextSibling : this.list.firstChild;
      if (row !== expected) this.list.insertBefore(row, expected);
      previous = row;
      row.querySelector(".navigator__number").textContent = String(index + 1);
      row.classList.toggle("is-hidden-slide", Boolean(slide.hidden));
      row.dataset.rev = slide.rev;
      const drawn = this.drawn.get(slide.id);
      if (drawn && drawn.rev !== slide.rev) this.drawThumbnail(row, { force: true });
    });
    if (current && !this.selected.has(current)) {
      this.selected = new Set([current]);
      this.anchor = current;
    }
    if (!this.selected.size && current) this.selected.add(current);
    for (const row of this.list.children) {
      const isSelected = this.selected.has(row.dataset.id);
      row.classList.toggle("is-selected", isSelected);
      row.classList.toggle("is-current", row.dataset.id === current);
      row.setAttribute("aria-selected", String(isSelected));
    }
    this.sizeThumbnails();
  }

  makeRow(id) {
    const row = document.createElement("li");
    row.className = "navigator__slide";
    row.dataset.id = id;
    row.setAttribute("role", "option");
    row.draggable = true;
    row.innerHTML = `<span class="navigator__number ds-numeric"></span><span class="navigator__thumbnail"><span class="navigator__frame"></span></span>`;
    row.addEventListener("click", (event) => this.clicked(id, event));
    row.addEventListener("dblclick", () => this.dispatchEvent(new CustomEvent("command", { detail: "playFromCurrent" })));
    row.addEventListener("dragstart", (event) => {
      if (!this.selected.has(id)) this.pick(id);
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("application/x-dazzle-slides", JSON.stringify([...this.selected]));
      this.dragging = [...this.selected];
    });
    row.addEventListener("dragend", () => {
      this.dragging = null;
      this.clearDropMarker();
    });
    row.addEventListener("dragover", (event) => {
      if (!this.dragging) return;
      event.preventDefault();
      const rect = row.getBoundingClientRect();
      const after = event.clientY > rect.top + rect.height / 2;
      this.clearDropMarker();
      row.classList.add(after ? "is-drop-after" : "is-drop-before");
    });
    row.addEventListener("drop", (event) => {
      if (!this.dragging) return;
      event.preventDefault();
      const rect = row.getBoundingClientRect();
      const after = event.clientY > rect.top + rect.height / 2;
      const ids = this.dragging;
      this.clearDropMarker();
      // Where they go, counted among the slides that stay.
      const order = this.slides.map((slide) => slide.id).filter((other) => !ids.includes(other));
      let to = order.indexOf(id);
      if (to < 0) return;
      if (after) to += 1;
      const ordered = this.slides.map((slide) => slide.id).filter((other) => ids.includes(other));
      this.dispatchEvent(new CustomEvent("move", { detail: { ids: ordered, to } }));
    });
    this.visible.observe(row);
    return row;
  }

  clearDropMarker() {
    for (const row of this.list.querySelectorAll(".is-drop-before, .is-drop-after")) {
      row.classList.remove("is-drop-before", "is-drop-after");
    }
  }

  /** Thumbnails as wide as the sidebar, in the slide's proportions. */
  sizeThumbnails() {
    const size = this.engine.info?.size;
    if (!size) return;
    const width = Math.max(this.list.clientWidth - 40, 60);
    this.thumbnailScale = width / size.w;
    for (const frame of this.list.querySelectorAll(".navigator__frame")) {
      frame.style.width = `${width}px`;
      frame.style.height = `${size.h * this.thumbnailScale}px`;
      const slide = frame.firstElementChild;
      if (slide) slide.style.transform = `scale(${this.thumbnailScale})`;
    }
  }

  async drawThumbnail(row, { force = false } = {}) {
    const id = row.dataset.id;
    const rev = Number(row.dataset.rev);
    const drawn = this.drawn.get(id);
    if (!force && drawn && drawn.rev === rev) return;
    if (row.drawing === rev) return;
    row.drawing = rev;
    try {
      const scene = await this.engine.call("scene", { slide: id });
      if (Number(row.dataset.rev) !== rev || !row.isConnected) return;
      const slide = this.drawer.draw(scene);
      slide.style.transform = `scale(${this.thumbnailScale ?? 0.1})`;
      const frame = row.querySelector(".navigator__frame");
      frame.replaceChildren(slide);
      this.drawn.set(id, { rev });
      const title = this.engine.info?.outline?.find((entry) => entry.id === id)?.title;
      row.setAttribute("aria-label", this.t("Slide.Accessibility", Number(row.querySelector(".navigator__number").textContent), title || this.t("Slide.Untitled")));
      requestAnimationFrame(() => this.drawer.fit(slide));
    } catch {
      // The slide went away while it was being drawn.
    } finally {
      row.drawing = null;
    }
  }

  clicked(id, event) {
    const toggle = isApple ? event.metaKey : event.ctrlKey;
    if (event.shiftKey && this.anchor) {
      const ids = this.slides.map((slide) => slide.id);
      const [from, to] = [ids.indexOf(this.anchor), ids.indexOf(id)].sort((a, b) => a - b);
      this.selected = new Set(ids.slice(from, to + 1));
    } else if (toggle) {
      if (this.selected.has(id) && this.selected.size > 1) this.selected.delete(id);
      else this.selected.add(id);
      this.anchor = id;
    } else {
      this.selected = new Set([id]);
      this.anchor = id;
    }
    this.dispatchEvent(new CustomEvent("pick", { detail: id }));
    this.update();
    this.element.focus({ preventScroll: true });
  }

  pick(id) {
    this.selected = new Set([id]);
    this.anchor = id;
    this.dispatchEvent(new CustomEvent("pick", { detail: id }));
    this.update();
  }

  /** Scrolls the current slide into view. */
  reveal() {
    const current = this.list.querySelector(".navigator__slide.is-current");
    current?.scrollIntoView({ block: "nearest" });
  }

  bindKeyboard() {
    this.element.addEventListener("keydown", (event) => {
      const ids = this.slides.map((slide) => slide.id);
      const current = ids.indexOf(this.engine.state?.sel?.slide);
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const next = Math.min(Math.max(current + (event.key === "ArrowDown" ? 1 : -1), 0), ids.length - 1);
        if (ids[next]) {
          if (event.shiftKey) {
            this.selected.add(ids[next]);
            this.dispatchEvent(new CustomEvent("pick", { detail: ids[next] }));
            this.update();
          } else {
            this.pick(ids[next]);
          }
          requestAnimationFrame(() => this.reveal());
        }
      } else if (event.key === "Backspace" || event.key === "Delete") {
        event.preventDefault();
        this.dispatchEvent(new CustomEvent("command", { detail: "deleteSlides" }));
      } else if (event.key === "Enter") {
        event.preventDefault();
        this.dispatchEvent(new CustomEvent("command", { detail: "newSlide" }));
      }
    });
  }

  clear() {
    for (const row of this.list.children) this.visible.unobserve(row);
    this.list.replaceChildren();
    this.drawn.clear();
    this.selected.clear();
  }
}
