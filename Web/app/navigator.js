// The slides down the side of the window: a thumbnail of each, drawn when it
// scrolls into view and again only when its slide changes. Slides are picked,
// several at once with Shift or ⌘, dragged into another order, and changed
// from their context menu. Slides in sections are grouped under each
// section's name, which folds them away and is dragged to move the section.

import { SlideDrawer } from "./slide.js";
import { attachContextMenu } from "../design/menus.js";

const isApple = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
const triangle = '<svg class="ds-icon navigator__triangle" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>';
const slidesType = "application/x-dazzle-slides";
const sectionType = "application/x-dazzle-section";

export class SlideNavigator extends EventTarget {
  /**
   * @param {HTMLElement} element
   * @param {import("./engine-client.js").EngineClient} engine
   * @param {import("./slide.js").MediaStore} media
   * @param {{ t: (key: string, ...values: any[]) => string, menu: (ids: string[]) => object[], sectionMenu: (id: string) => object[] }} options
   */
  constructor(element, engine, media, { t, menu, sectionMenu }) {
    super();
    this.element = element;
    this.engine = engine;
    this.drawer = new SlideDrawer(media);
    this.t = t;
    this.menuFor = menu;
    this.sectionMenuFor = sectionMenu;
    /** Section headers, by section id. */
    this.headers = new Map();
    /** Sections whose slides are folded away. */
    this.collapsed = new Set();
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
      const header = event.target.closest?.(".navigator__section");
      if (header) return this.sectionMenuFor(header.dataset.section);
      const row = event.target.closest?.(".navigator__slide");
      if (row && !this.selected.has(row.dataset.id)) this.pick(row.dataset.id);
      return this.menuFor([...this.selected]);
    });
  }

  get slides() {
    return this.engine.state?.slides ?? [];
  }

  get sections() {
    return this.engine.state?.sections ?? [];
  }

  /** Brings the list in step with the engine's slides, drawing again only what changed. */
  update() {
    const slides = this.slides;
    const current = this.engine.state?.sel?.slide;
    const rows = new Map([...this.list.querySelectorAll(".navigator__slide")].map((row) => [row.dataset.id, row]));
    const ids = new Set(slides.map((slide) => slide.id));
    const sections = this.sections;
    const sectionIDs = new Set(sections.map((section) => section.id));
    for (const [id, header] of this.headers) {
      if (!sectionIDs.has(id)) {
        header.remove();
        this.headers.delete(id);
        this.collapsed.delete(id);
      }
    }
    // A slide picked from elsewhere shows, even in a folded section.
    if (current && current !== this.lastCurrent) {
      const owner = sections.find((section) => section.slides.includes(current));
      if (owner) this.collapsed.delete(owner.id);
    }
    this.lastCurrent = current;
    const sectionOf = new Map();
    for (const section of sections) for (const id of section.slides) sectionOf.set(id, section);
    for (const [id, row] of rows) {
      if (!ids.has(id)) {
        this.visible.unobserve(row);
        row.remove();
        this.drawn.delete(id);
        this.selected.delete(id);
      }
    }
    let previous = null;
    const place = (element) => {
      const expected = previous ? previous.nextSibling : this.list.firstChild;
      if (element !== expected) this.list.insertBefore(element, expected);
      previous = element;
    };
    let section = null;
    slides.forEach((slide, index) => {
      const owner = sectionOf.get(slide.id);
      // Headers of the sections up to this slide's, empty ones included.
      while (owner && owner !== section) {
        const next = sections[section ? sections.indexOf(section) + 1 : 0];
        if (!next) break;
        section = next;
        place(this.header(section));
      }
      let row = rows.get(slide.id);
      if (!row) row = this.makeRow(slide.id);
      place(row);
      row.hidden = Boolean(owner && this.collapsed.has(owner.id));
      row.querySelector(".navigator__number").textContent = String(index + 1);
      row.classList.toggle("is-hidden-slide", Boolean(slide.hidden));
      row.dataset.rev = slide.rev;
      const drawn = this.drawn.get(slide.id);
      if (drawn && drawn.rev !== slide.rev) this.drawThumbnail(row, { force: true });
    });
    for (const rest of sections.slice(section ? sections.indexOf(section) + 1 : 0)) place(this.header(rest));
    if (current && !this.selected.has(current)) {
      this.selected = new Set([current]);
      this.anchor = current;
    }
    if (!this.selected.size && current) this.selected.add(current);
    for (const row of this.list.querySelectorAll(".navigator__slide")) {
      const isSelected = this.selected.has(row.dataset.id);
      row.classList.toggle("is-selected", isSelected);
      row.classList.toggle("is-current", row.dataset.id === current);
      row.setAttribute("aria-selected", String(isSelected));
    }
    this.sizeThumbnails();
  }

  /** The header of a section, made the first time, brought up to date. */
  header(section) {
    let header = this.headers.get(section.id);
    if (!header) {
      header = document.createElement("li");
      header.className = "navigator__section";
      header.dataset.section = section.id;
      header.setAttribute("role", "presentation");
      header.draggable = true;
      header.innerHTML = `<button class="navigator__disclosure" type="button">${triangle}<span class="navigator__section-name"></span></button><span class="ds-source-list__count"></span>`;
      const id = section.id;
      header.querySelector("button").addEventListener("click", () => {
        if (this.collapsed.has(id)) this.collapsed.delete(id);
        else this.collapsed.add(id);
        this.update();
      });
      header.addEventListener("dblclick", () => this.dispatchEvent(new CustomEvent("renameSection", { detail: id })));
      header.addEventListener("dragstart", (event) => {
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData(sectionType, id);
        this.draggingSection = id;
      });
      header.addEventListener("dragend", () => {
        this.draggingSection = null;
        this.clearDropMarker();
      });
      header.addEventListener("dragover", (event) => {
        if (!this.dragging && !this.draggingSection) return;
        event.preventDefault();
        this.clearDropMarker();
        // A section goes before this one; slides go into it.
        header.classList.add(this.draggingSection ? "is-drop-before" : "is-drop-target");
      });
      header.addEventListener("drop", (event) => {
        event.preventDefault();
        this.clearDropMarker();
        if (this.draggingSection) {
          const order = this.sections.map((other) => other.id);
          const from = order.indexOf(this.draggingSection);
          let to = order.indexOf(id);
          if (from < 0 || to < 0 || from === to) return;
          if (to > from) to -= 1;
          this.dispatchEvent(new CustomEvent("moveSection", { detail: { id: this.draggingSection, to } }));
        } else if (this.dragging) {
          const ordered = this.slides.map((slide) => slide.id).filter((other) => this.dragging.includes(other));
          this.dispatchEvent(new CustomEvent("moveToSection", { detail: { ids: ordered, section: id } }));
        }
      });
      this.headers.set(section.id, header);
    }
    const name = section.name || this.t("Section.Untitled");
    const open = !this.collapsed.has(section.id);
    header.querySelector(".navigator__section-name").textContent = name;
    header.querySelector(".ds-source-list__count").textContent = String(section.slides.length);
    header.querySelector("button").setAttribute("aria-expanded", String(open));
    header.classList.toggle("is-collapsed", !open);
    return header;
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
      event.dataTransfer.setData(slidesType, JSON.stringify([...this.selected]));
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
    for (const row of this.list.querySelectorAll(".is-drop-before, .is-drop-after, .is-drop-target")) {
      row.classList.remove("is-drop-before", "is-drop-after", "is-drop-target");
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
      if (event.target.closest?.(".navigator__section")) return;
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
    this.headers.clear();
    this.collapsed.clear();
    this.drawn.clear();
    this.selected.clear();
  }
}
