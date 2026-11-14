// The presentation window: menu bar, toolbar, find bar, the slide navigator,
// the slide being edited with its notes below, the inspector, the status bar,
// and the start screen shown when nothing is open. Every change goes through
// the engine; this keeps the window in step with what it reports.

import { t, language } from "./i18n.js";
import * as files from "./files.js";
import * as storage from "./storage.js";
import { attachMenuBar, attachToolbarOverflow, openMenu } from "../design/menus.js";
import { dismissSheet } from "../design/sheets.js";
import { MediaStore, SlideDrawer, applyFrame, substituteFor } from "./slide.js";
import { isInstalled } from "./fonts.js";
import { SlideCanvas } from "./canvas.js";
import { SlideNavigator } from "./navigator.js";
import { Inspector, escapeHTML, readSetting, writeSetting } from "./inspector.js";
import { Slideshow, hasSecondDisplay } from "./slideshow.js";
import { closeTablePicker, openTablePicker } from "./table-picker.js";

const isApple = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
/** Dazzle for iPhone, iPad and Mac: one App Store listing, opened in the visitor's own storefront. */
const APP_STORE_URL = "https://apps.apple.com/app/id6819683894";
const SOURCE_CODE_URL = "https://github.com/AtelierSuite/Dazzle";
/** Which Apple app to offer: "ios" on an iPhone or iPad, "mac" on a Mac, null elsewhere. */
const appStorePlatform = (() => {
  const agent = navigator.userAgent;
  if (/iPhone|iPad|iPod/.test(agent)) return "ios";
  if (/Macintosh/.test(agent)) return navigator.maxTouchPoints > 1 ? "ios" : "mac";
  return null;
})();
const AUTOSAVE_DELAY = 1500;
const ZOOMS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3];

const ICONS = {
  undo: '<path d="M5 4L2 7l3 3M2 7h7.5a3.5 3.5 0 010 7H7" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  redo: '<path d="M11 4l3 3-3 3M14 7H6.5a3.5 3.5 0 000 7H9" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  play: '<path d="M4.5 2.5v11l9-5.5z"/>',
  slide: '<rect x="1.75" y="3.25" width="12.5" height="9.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 5.5v5M5.5 8h5" stroke="currentColor" stroke-width="1.5"/>',
  textBox: '<path d="M3 3.5h10M8 3.5v10M6 13.5h4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  shape: '<circle cx="5.5" cy="10.5" r="3.75" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="7.25" y="1.75" width="7" height="7" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  table: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2 6.5h12M2 10h12M6 3v10" stroke="currentColor" stroke-width="1.2"/>',
  chart: '<path d="M2.5 13.5h11" stroke="currentColor" stroke-width="1.5"/><path d="M3.5 12V8h2.5v4zM7 12V4h2.5v8zM10.5 12V6.5H13V12z"/>',
  picture: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2.5 12l3.5-4 2.5 2.5L10.5 8l3 4" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="10.5" cy="5.5" r="1.1"/>',
  movie: '<rect x="1.75" y="3.25" width="9" height="9.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M11 7l3.5-2.25v6.5L11 9z" fill="none" stroke="currentColor" stroke-width="1.3"/>',
  search: '<circle cx="7" cy="7" r="4.25" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10.2 10.2L14 14" stroke="currentColor" stroke-width="1.5"/>',
  inspector: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10 3v10" stroke="currentColor" stroke-width="1.5"/>',
  navigator: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M6 3v10" stroke="currentColor" stroke-width="1.5"/>',
  notes: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2 9.5h12" stroke="currentColor" stroke-width="1.5"/>',
  chevronDown: '<path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  chevronUp: '<path d="M4 10l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  close: '<path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.5"/>',
  info: '<path d="M8 1a7 7 0 100 14A7 7 0 008 1zm.75 10.5h-1.5V7h1.5zM8 5.75a1 1 0 110-2 1 1 0 010 2z"/>',
  warning: '<path d="M8 1L.5 15h15zm.75 11.5h-1.5V11h1.5zm0-2.5h-1.5V6h1.5z"/>',
  error: '<path d="M8 1a7 7 0 100 14A7 7 0 008 1zm3 9.6L10.6 11 8 8.4 5.4 11 5 10.6 7.6 8 5 5.4 5.4 5 8 7.6 10.6 5l.4.4L8.4 8z"/>',
  presentation: '<rect x="1.75" y="2.25" width="12.5" height="8.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 11v3M5 14h6" stroke="currentColor" stroke-width="1.5"/>',
  download: '<path d="M8 2v8M4.5 6.5L8 10l3.5-3.5M2.5 11v2.5h11V11" fill="none" stroke="currentColor" stroke-width="1.5"/>',
};

const icon = (name, extra = "") => `<svg class="ds-icon ${extra}" viewBox="0 0 16 16" aria-hidden="true">${ICONS[name]}</svg>`;

/** A shortcut as the platform writes it: ⇧⌘S on Apple devices, Ctrl+Shift+S elsewhere. */
function shortcut(key, { shift = false, alt = false } = {}) {
  if (isApple) return `${alt ? "⌥" : ""}${shift ? "⇧" : ""}⌘${key}`;
  return `Ctrl+${shift ? "Shift+" : ""}${alt ? "Alt+" : ""}${key}`;
}

/** Reads a picture's size and kind in the browser, re-encoding what PowerPoint can't read as PNG. */
async function preparePicture(bytes, name = "") {
  const blob = new Blob([bytes]);
  let bitmap;
  try {
    bitmap = await createImageBitmap(blob);
  } catch {
    // SVG and others createImageBitmap won't take.
    bitmap = await new Promise((resolve) => {
      const image = new Image();
      const url = URL.createObjectURL(new Blob([bytes], { type: /\.svg$/i.test(name) ? "image/svg+xml" : "" }));
      image.onload = () => {
        URL.revokeObjectURL(url);
        resolve(image);
      };
      image.onerror = () => {
        URL.revokeObjectURL(url);
        resolve(null);
      };
      image.src = url;
    });
  }
  if (!bitmap) return null;
  const width = bitmap.naturalWidth ?? bitmap.width;
  const height = bitmap.naturalHeight ?? bitmap.height;
  const isPNG = bytes[0] === 0x89 && bytes[1] === 0x50;
  const isJPEG = bytes[0] === 0xff && bytes[1] === 0xd8;
  const isGIF = bytes[0] === 0x47 && bytes[1] === 0x49;
  if (isPNG || isJPEG || isGIF) return { bytes, ext: isPNG ? "png" : isJPEG ? "jpeg" : "gif", w: width, h: height };
  // Anything else, such as HEIC, WebP or SVG, goes in as PNG, which every reader takes.
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  canvas.getContext("2d").drawImage(bitmap, 0, 0);
  const png = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
  return png ? { bytes: new Uint8Array(await png.arrayBuffer()), ext: "png", w: width, h: height } : null;
}

/** A movie's first frame as PNG, and its size. */
function prepareMovie(bytes, type) {
  return new Promise((resolve) => {
    const video = document.createElement("video");
    const url = URL.createObjectURL(new Blob([bytes], { type }));
    video.muted = true;
    video.preload = "auto";
    video.src = url;
    video.addEventListener("loadeddata", () => {
      video.currentTime = Math.min(0.1, video.duration || 0);
    }, { once: true });
    video.addEventListener("seeked", () => {
      const canvas = document.createElement("canvas");
      canvas.width = video.videoWidth || 640;
      canvas.height = video.videoHeight || 360;
      canvas.getContext("2d").drawImage(video, 0, 0, canvas.width, canvas.height);
      canvas.toBlob(async (png) => {
        URL.revokeObjectURL(url);
        resolve(png ? { poster: new Uint8Array(await png.arrayBuffer()), w: canvas.width, h: canvas.height } : null);
      }, "image/png");
    }, { once: true });
    video.addEventListener("error", () => {
      URL.revokeObjectURL(url);
      resolve(null);
    }, { once: true });
  });
}

export class PresentationWindow {
  /** @param {HTMLElement} root @param {import("./engine-client.js").EngineClient} engine */
  constructor(root, engine) {
    this.root = root;
    this.engine = engine;
    this.document = null; // { id, name, handle? }
    this.autosaveTimer = null;
    this.look = {};
    this.media = new MediaStore(engine);
    this.build();
    this.canvas = new SlideCanvas(this.root.querySelector(".app__canvas"), engine, this.media);
    this.navigator = new SlideNavigator(this.root.querySelector(".app__navigator"), engine, this.media, {
      t, menu: (ids) => this.slideMenu(ids),
    });
    this.inspector = new Inspector(this.root.querySelector(".app__inspector"), engine, {
      t, language, run: (command) => this.run(command), ask: { scaling: () => this.askScaling() },
    });
    this.slideshow = new Slideshow(this.root, engine, this.media, { t, language });
    this.bindEngine();
    this.bindKeyboard();
    this.applyAppearance(readSetting("appearance", ""));
    const narrow = matchMedia("(max-width: 720px)").matches;
    this.setPanelVisible("inspector", readSetting("inspector", "1") === "1" && !narrow, { remember: false });
    this.setPanelVisible("navigator", readSetting("navigator", "1") === "1", { remember: false });
    this.setPanelVisible("notes", readSetting("notes", "1") === "1", { remember: false });

    files.onLaunchFiles((file) => file && this.openFile(file));
    files.onDroppedFiles(document.body, (file) => file && this.dropped(file), (hovering) => {
      this.root.classList.toggle("is-dropping", hovering);
    });
    window.addEventListener("beforeunload", (event) => {
      if (this.hasUnkeptChanges) {
        event.preventDefault();
        event.returnValue = "";
      }
    });
  }

  // MARK: - Building

  build() {
    this.root.className = "app ds-window";
    this.root.innerHTML = `
      <div class="ds-menu-bar" id="menu-bar"></div>
      <div class="ds-toolbar" id="toolbar">
        <div class="ds-toolbar__title" data-overflow="never"><span class="app__title"></span><span class="ds-toolbar__subtitle app__subtitle"></span></div>
        <div class="ds-toolbar__separator"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="toggleNavigator">${icon("navigator")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="undo">${icon("undo")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="redo">${icon("redo")}</button>
        <div class="ds-toolbar__separator"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-menu="newSlide">${icon("slide")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="insertTextBox">${icon("textBox")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-menu="shape">${icon("shape")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="insertTable">${icon("table")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-menu="chart">${icon("chart")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="insertPicture">${icon("picture")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="insertMovie">${icon("movie")}</button>
        <div class="ds-toolbar__separator"></div>
        <div class="ds-segmented ds-segmented--xs ds-segmented--icons app__text-tools" role="group" data-overflow-label="${escapeHTML(t("Format.Section.Text"))}" aria-label="${escapeHTML(t("Format.Section.Text"))}">
          <button class="ds-segmented__segment" data-command="bold" aria-pressed="false"><strong>B</strong></button>
          <button class="ds-segmented__segment" data-command="italic" aria-pressed="false"><em>I</em></button>
          <button class="ds-segmented__segment" data-command="underline" aria-pressed="false"><u>U</u></button>
        </div>
        <div class="ds-toolbar__spacer"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="find">${icon("search")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="toggleNotes">${icon("notes")}</button>
        <button class="ds-button ds-button--bordered ds-button--xs app__play" data-command="play" data-overflow="never">${icon("play")}<span></span></button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="toggleInspector" data-overflow="never" id="inspector-toggle">${icon("inspector")}</button>
      </div>
      <nav class="ds-source-list app__navigator" aria-label="${escapeHTML(t("Mac.Navigator.Accessibility"))}"></nav>
      <div class="ds-window__accessory app__accessory">
        <form class="app__find" hidden>
          <span class="ds-search ds-search--xs app__find-field">${icon("search", "ds-search__icon")}<input class="ds-search__input app__find-input" type="search" spellcheck="false" autocomplete="off"></span>
          <span class="ds-caption ds-numeric app__find-count" aria-live="polite"></span>
          <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" type="button" data-find="previous">${icon("chevronUp")}</button>
          <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" type="button" data-find="next">${icon("chevronDown")}</button>
          <label class="ds-check app__find-option"><input type="checkbox" data-find-option="matchCase"><span></span></label>
          <label class="ds-check app__find-option"><input type="checkbox" data-find-option="wholeWords"><span></span></label>
          <input class="ds-text-input ds-text-input--xs app__replace-input" spellcheck="false" autocomplete="off">
          <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-find="replace"></button>
          <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-find="replaceAll"></button>
          <button class="ds-button ds-button--ghost ds-button--xs" type="button" data-find="done"></button>
        </form>
        <div class="app__banners" aria-live="polite"></div>
      </div>
      <div class="ds-window__content app__content">
        <div class="app__editor">
          <div class="app__canvas" aria-label="${escapeHTML(t("Mac.Canvas.Accessibility"))}"></div>
          <div class="app__notes-divider" role="separator" aria-orientation="horizontal"></div>
          <div class="app__notes"><textarea class="ds-document-content app__notes-input" spellcheck="true"></textarea></div>
        </div>
        <section class="app__start" hidden></section>
        <div class="app__drop" aria-hidden="true"><p class="ds-heading-03"></p></div>
      </div>
      <div class="ds-status-bar app__status">
        <span class="app__status-slide ds-numeric"></span>
        <span class="ds-status-bar__spacer"></span>
        <span class="ds-popup ds-popup--xs app__zoom"><select class="ds-popup__select" aria-label="${escapeHTML(t("Mac.Toolbar.Zoom"))}">
          <option value="fit">${escapeHTML(t("Menu.View.ZoomToFit"))}</option>
          ${ZOOMS.map((z) => `<option value="${z}">${Math.round(z * 100)}%</option>`).join("")}
        </select>${icon("chevronDown", "ds-popup__chevron")}</span>
      </div>
      <aside class="ds-inspector ds-on-layer app__inspector" aria-label="${escapeHTML(t("Web.Inspector.Title"))}"></aside>`;

    this.titleElement = this.root.querySelector(".app__title");
    this.subtitleElement = this.root.querySelector(".app__subtitle");
    this.start = this.root.querySelector(".app__start");
    this.banners = this.root.querySelector(".app__banners");
    this.notes = this.root.querySelector(".app__notes-input");
    this.zoomSelect = this.root.querySelector(".app__zoom select");
    this.root.querySelector(".app__drop p").textContent = t("Web.Drop");
    this.notes.placeholder = t("Mac.Notes.Placeholder");
    this.notes.setAttribute("aria-label", t("Panel.Notes.Title"));
    this.root.querySelector(".app__play span").textContent = t("Toolbar.Play");

    this.buildToolbar();
    this.buildMenus();
    this.buildFind();
    this.buildNotes();
    this.zoomSelect.value = "fit";
    this.zoomSelect.addEventListener("change", () => this.canvas.setZoom(this.zoomSelect.value === "fit" ? "fit" : Number(this.zoomSelect.value)));
  }

  buildToolbar() {
    const toolbar = this.root.querySelector("#toolbar");
    const labels = {
      undo: t("Toolbar.Undo"), redo: t("Toolbar.Redo"), bold: t("Format.Bold"), italic: t("Format.Italic"), underline: t("Format.Underline"),
      insertTextBox: t("ActionBar.TextBox"), insertTable: t("ActionBar.Table"), insertPicture: t("ActionBar.Photo"), insertMovie: t("Mac.Toolbar.Media"),
      find: t("Toolbar.Find"), toggleInspector: t("Menu.View.Inspector"), toggleNavigator: t("Menu.View.Navigator"), toggleNotes: t("Menu.View.Notes"),
      play: t("Toolbar.Play"), newSlide: t("Slide.New"), shape: t("ActionBar.Shape"), chart: t("ActionBar.Chart"),
    };
    for (const button of toolbar.querySelectorAll("[data-command], [data-menu]")) {
      const label = labels[button.dataset.command ?? button.dataset.menu];
      button.title = label;
      button.setAttribute("aria-label", label);
      // Keep the selection in the text being typed while a button is pressed.
      button.addEventListener("mousedown", (event) => event.preventDefault());
      if (button.dataset.command) button.addEventListener("click", () => this.run(button.dataset.command));
      else button.addEventListener("click", () => openMenu(this.toolbarMenu(button.dataset.menu), button, { opener: button }));
    }
    this.toolbarOverflow = attachToolbarOverflow(toolbar, { label: t("Toolbar.More"), before: toolbar.querySelector(".app__play") });
  }

  toolbarMenu(name) {
    if (name === "newSlide") return this.layoutItems();
    if (name === "shape") return this.shapeItems();
    return this.chartItems();
  }

  /** Play ▸ Play Custom Show: each of the presentation's custom shows. */
  customShowItems() {
    const shows = this.engine.info?.customShows ?? [];
    if (!shows.length) return [{ label: t("CustomShow.None"), disabled: true }];
    return shows.map((show) => ({ label: show.name, disabled: !show.slides.length, action: () => this.play(null, { customShow: show.id }) }));
  }

  layoutItems() {
    // In master view, what is added is a layout.
    if (this.engine.state?.masterView) return [this.item("newSlide")];
    return (this.engine.info?.layouts ?? []).map((layout) => ({ label: layout.name, action: () => this.engine.call("addSlide", { layout: layout.path }) }));
  }

  shapeItems() {
    return (this.engine.info?.choices?.shapes ?? []).map((shape) => ({ label: shape.label, action: () => this.engine.call("insertShape", { preset: shape.preset }) }));
  }

  chartItems() {
    return (this.engine.info?.choices?.charts ?? []).map((chart) => ({ label: chart.label, action: () => this.engine.call("insertChart", { kind: chart.kind }) }));
  }

  buildFind() {
    const form = this.root.querySelector(".app__find");
    this.findForm = form;
    this.findInput = form.querySelector(".app__find-input");
    this.replaceInput = form.querySelector(".app__replace-input");
    this.findInput.placeholder = t("Find.Placeholder");
    this.findInput.ariaLabel = t("Find.Placeholder");
    this.replaceInput.placeholder = t("Find.ReplacePlaceholder");
    this.replaceInput.ariaLabel = t("Find.ReplacePlaceholder");
    form.querySelector('[data-find-option="matchCase"] + span').textContent = t("Find.MatchCase");
    form.querySelector('[data-find-option="wholeWords"] + span').textContent = t("Find.WholeWords");
    const labels = {
      previous: t("Menu.Edit.Find.Previous"), next: t("Menu.Edit.Find.Next"), replace: t("Find.Replace"),
      replaceAll: t("Find.ReplaceAll"), done: t("Web.Common.Done"),
    };
    for (const button of form.querySelectorAll("[data-find]")) {
      const label = labels[button.dataset.find];
      if (button.classList.contains("ds-button--icon")) {
        button.title = label;
        button.ariaLabel = label;
      } else {
        button.textContent = label;
      }
      button.addEventListener("click", () => this.findAction(button.dataset.find));
    }
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      this.findAction("next");
    });
    const refresh = () => {
      clearTimeout(this.findTimer);
      this.findTimer = setTimeout(() => this.search(), 200);
    };
    this.findInput.addEventListener("input", refresh);
    for (const option of form.querySelectorAll("[data-find-option]")) option.addEventListener("change", refresh);
    form.addEventListener("keydown", (event) => {
      if (event.key === "Escape") this.findAction("done");
      if (event.key === "Enter" && event.target === this.findInput && event.shiftKey) {
        event.preventDefault();
        this.findAction("previous");
      }
    });
  }

  buildNotes() {
    this.notes.addEventListener("input", () => {
      clearTimeout(this.notesTimer);
      this.notesTimer = setTimeout(() => this.engine.call("setNotes", { text: this.notes.value }), 400);
    });
    this.notes.addEventListener("blur", () => {
      if (!this.notesTimer) return;
      clearTimeout(this.notesTimer);
      this.notesTimer = null;
      this.engine.call("setNotes", { text: this.notes.value });
    });
    // The divider drags to make the notes taller or shorter.
    const divider = this.root.querySelector(".app__notes-divider");
    const holder = this.root.querySelector(".app__notes");
    holder.style.height = `${Number(readSetting("notesHeight", "120"))}px`;
    divider.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      const startY = event.clientY;
      const startHeight = holder.offsetHeight;
      const move = (moveEvent) => {
        const height = Math.min(Math.max(startHeight - (moveEvent.clientY - startY), 48), this.root.clientHeight * 0.6);
        holder.style.height = `${height}px`;
      };
      const up = () => {
        window.removeEventListener("pointermove", move);
        window.removeEventListener("pointerup", up);
        writeSetting("notesHeight", String(holder.offsetHeight));
      };
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", up);
    });
  }

  // MARK: - Commands

  get hasDocument() {
    return Boolean(this.document);
  }

  get selection() {
    return this.engine.state?.sel ?? { shapes: [] };
  }

  get commands() {
    const state = this.engine.state;
    const info = this.engine.info;
    const has = this.hasDocument;
    const shapes = this.selection.shapes?.length ?? 0;
    const editingText = Boolean(this.canvas?.editing);
    const textual = has && (shapes > 0 || editingText);
    const look = this.look ?? {};
    const selected = shapes === 1 ? this.canvas?.shape(this.selection.shapes[0]) : null;
    // Master view edits the masters and layouts in the slides' place, so what is only a slide's is off.
    const master = Boolean(state?.masterView);
    const picked = master ? this.pickedSlides().map((id) => state.slides.find((slide) => slide.id === id)) : [];
    const layoutsPicked = picked.length > 0 && picked.every((slide) => slide?.role === "layout");
    return {
      new: { label: t("Menu.File.New"), shortcut: shortcut("N"), run: () => this.newDocument() },
      open: { label: t("Menu.File.Open"), shortcut: shortcut("O"), run: () => this.openPicked() },
      close: { label: t("Menu.File.Close"), shortcut: shortcut("W"), enabled: has, run: () => this.closeDocument() },
      save: { label: t("Menu.File.Save"), shortcut: shortcut("S"), enabled: has, run: () => this.save() },
      saveAs: { label: t("Web.Menu.SaveAs"), shortcut: shortcut("S", { shift: true }), enabled: has, run: () => this.saveAs() },
      rename: { label: t("Menu.File.Rename"), enabled: has, run: () => this.renameDocument() },
      properties: { label: t("Mac.Menu.File.Properties"), enabled: has, run: () => this.showProperties() },
      exportPowerPoint: { label: t("Menu.File.Export.PowerPoint"), enabled: has, run: () => this.exportAs({ key: "pptx", extension: "pptx", mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation" }) },
      exportPDF: { label: t("Menu.File.Export.PDF"), enabled: has && !master, run: () => this.print() },
      print: { label: t("Menu.File.Print"), shortcut: shortcut("P"), enabled: has && !master, run: () => this.print() },
      undo: { label: t("Toolbar.Undo"), shortcut: shortcut("Z"), enabled: has && (state?.canUndo || editingText), run: () => this.undo() },
      redo: { label: t("Toolbar.Redo"), shortcut: shortcut("Z", { shift: true }), enabled: has && (state?.canRedo || editingText), run: () => this.redo() },
      cut: { label: t("Edit.Cut"), shortcut: shortcut("X"), enabled: has, run: () => this.clipboard("cut") },
      copy: { label: t("Edit.Copy"), shortcut: shortcut("C"), enabled: has, run: () => this.clipboard("copy") },
      paste: { label: t("Edit.Paste"), shortcut: shortcut("V"), enabled: has, run: () => this.clipboard("paste") },
      duplicate: { label: t("ActionBar.Duplicate"), shortcut: shortcut("D"), enabled: has && shapes > 0, run: () => this.engine.call("duplicate") },
      delete: { label: t("Menu.Edit.Delete"), enabled: has && shapes > 0, run: () => this.engine.call("delete") },
      selectAll: { label: t("Menu.Edit.SelectAll"), shortcut: shortcut("A"), enabled: has, run: () => this.selectAll() },
      deselectAll: { label: t("Menu.Edit.DeselectAll"), shortcut: shortcut("A", { shift: true }), enabled: has && shapes > 0, run: () => this.canvas.select([]) },
      find: { label: t("Menu.Edit.Find.Find"), shortcut: shortcut("F"), enabled: has, run: () => this.showFind(false) },
      findReplace: { label: t("Mac.Menu.Find.FindReplace"), shortcut: shortcut("F", { alt: true }), enabled: has, run: () => this.showFind(true) },
      findNext: { label: t("Menu.Edit.Find.Next"), shortcut: shortcut("G"), enabled: has, run: () => this.findAction("next") },
      findPrevious: { label: t("Menu.Edit.Find.Previous"), shortcut: shortcut("G", { shift: true }), enabled: has, run: () => this.findAction("previous") },
      newSlide: {
        label: master ? t("MasterView.NewLayout") : t("Slide.New"), shortcut: shortcut("N", { shift: true }), enabled: has,
        run: () => (master ? this.engine.call("addLayout") : this.engine.call("addSlide", { layout: this.currentLayout() })),
      },
      duplicateSlides: {
        label: master ? t("MasterView.Duplicate") : t("Slide.Menu.Duplicate"), enabled: has && (!master || layoutsPicked),
        run: () => this.engine.call("duplicateSlides", { ids: this.pickedSlides() }),
      },
      deleteSlides: {
        label: master ? t("MasterView.Delete") : t("Slide.Menu.Delete"),
        enabled: has && (master ? layoutsPicked && picked.length === 1 && picked[0].canDelete : (state?.slides.length ?? 0) > 1),
        run: () => this.engine.call("deleteSlides", { ids: this.pickedSlides() }),
      },
      renameLayout: { label: t("MasterView.Rename"), enabled: master && this.currentSlide()?.role === "layout", run: () => this.renameLayout(this.selection.slide) },
      masterView: {
        label: master ? t("MasterView.Close") : t("Toolbar.EditMasters"), enabled: has && (master || Boolean(info?.canEditMasters)),
        run: () => this.toggleMasterView(),
      },
      toggleHidden: { label: this.currentSlide()?.hidden ? t("Slide.Menu.Show") : t("Slide.Menu.Hide"), enabled: has && !master, run: () => this.engine.call("toggleHidden", { ids: this.pickedSlides() }) },
      previousSlide: { label: t("Menu.Slide.Previous"), enabled: has, run: () => this.stepSlide(-1) },
      nextSlide: { label: t("Menu.Slide.Next"), enabled: has, run: () => this.stepSlide(1) },
      headerFooter: { label: t("Mac.Menu.Slide.HeaderFooter"), enabled: has && !master, run: () => this.showHeaderFooter() },
      insertTextBox: { label: t("Menu.Insert.TextBox"), enabled: has, run: () => this.insert("insertTextBox") },
      insertTable: { label: t("Menu.Insert.Table"), enabled: has, run: () => this.insertTable() },
      insertPicture: { label: t("Menu.Insert.Choose"), shortcut: shortcut("I", { shift: true }), enabled: has, run: () => this.insertPicture() },
      insertMovie: { label: t("Mac.Toolbar.Media"), enabled: has, run: () => this.insertMovie() },
      bold: { label: t("Format.Bold"), shortcut: shortcut("B"), enabled: textual, checked: look.bold, run: () => this.format({ bold: true }) },
      italic: { label: t("Format.Italic"), shortcut: shortcut("I"), enabled: textual, checked: look.italic, run: () => this.format({ italic: true }) },
      underline: { label: t("Format.Underline"), shortcut: shortcut("U"), enabled: textual, checked: look.underline, run: () => this.format({ underline: true }) },
      strike: { label: t("Format.Strikethrough"), enabled: textual, checked: look.strike, run: () => this.format({ strike: true }) },
      superscript: { label: t("Format.Superscript"), enabled: textual, checked: look.baseline > 0, run: () => this.format({ superscript: true }) },
      subscript: { label: t("Format.Subscript"), enabled: textual, checked: look.baseline < 0, run: () => this.format({ subscript: true }) },
      bigger: { label: t("Menu.Format.Bigger"), shortcut: shortcut("+"), enabled: textual, run: () => this.format({ sizeStep: 1 }) },
      smaller: { label: t("Menu.Format.Smaller"), shortcut: shortcut("-"), enabled: textual, run: () => this.format({ sizeStep: -1 }) },
      alignLeft: { label: t("Menu.Format.AlignLeft"), enabled: textual, checked: look.align === "l", run: () => this.format({ align: "l" }) },
      alignCenter: { label: t("Menu.Format.Centre"), enabled: textual, checked: look.align === "ctr", run: () => this.format({ align: "ctr" }) },
      alignRight: { label: t("Menu.Format.AlignRight"), enabled: textual, checked: look.align === "r", run: () => this.format({ align: "r" }) },
      alignJustify: { label: t("Menu.Format.Justify"), enabled: textual, checked: look.align === "just", run: () => this.format({ align: "just" }) },
      bullets: { label: t("Format.List.Bullets"), enabled: textual, checked: look.list === "bullets", run: () => this.format({ list: look.list === "bullets" ? "none" : "bullets" }) },
      numbers: { label: t("Format.List.Numbers"), enabled: textual, checked: look.list === "numbers", run: () => this.format({ list: look.list === "numbers" ? "none" : "numbers" }) },
      indent: { label: t("Format.Indent"), shortcut: shortcut("]"), enabled: textual, run: () => this.format({ indent: 1 }) },
      outdent: { label: t("Format.Outdent"), shortcut: shortcut("["), enabled: textual, run: () => this.format({ indent: -1 }) },
      front: { label: t("Arrange.Front"), shortcut: shortcut("F", { shift: true, alt: false }), enabled: shapes > 0, run: () => this.engine.call("arrange", { how: "front" }) },
      forward: { label: t("Arrange.Forward"), enabled: shapes > 0, run: () => this.engine.call("arrange", { how: "forward" }) },
      backward: { label: t("Arrange.Backward"), enabled: shapes > 0, run: () => this.engine.call("arrange", { how: "backward" }) },
      back: { label: t("Arrange.Back"), shortcut: shortcut("B", { shift: true }), enabled: shapes > 0, run: () => this.engine.call("arrange", { how: "back" }) },
      group: { label: t("Arrange.Group"), shortcut: shortcut("G", { alt: true }), enabled: shapes > 1, run: () => this.engine.call("group") },
      ungroup: { label: t("Arrange.Ungroup"), shortcut: shortcut("G", { shift: true, alt: true }), enabled: selected?.kind === "group", run: () => this.engine.call("ungroup") },
      rotateLeft: { label: t("Arrange.RotateLeft"), enabled: shapes === 1, run: () => this.engine.call("rotate", { clockwise: false }) },
      rotateRight: { label: t("Arrange.RotateRight"), enabled: shapes === 1, run: () => this.engine.call("rotate", { clockwise: true }) },
      flipH: { label: t("Arrange.FlipHorizontal"), enabled: shapes === 1, run: () => this.engine.call("flip", { horizontally: true }) },
      flipV: { label: t("Arrange.FlipVertical"), enabled: shapes === 1, run: () => this.engine.call("flip", { horizontally: false }) },
      play: { label: t("Toolbar.PlayFromCurrent"), shortcut: shortcut("↩", { alt: true }), enabled: has && !master, run: () => this.play(this.selection.slide) },
      playFromStart: { label: t("Toolbar.PlayFromStart"), shortcut: shortcut("↩", { alt: true, shift: true }), enabled: has && !master, run: () => this.play(this.engine.state?.slides[0]?.id) },
      playFromCurrent: { label: t("Toolbar.PlayFromCurrent"), enabled: has && !master, run: () => this.play(this.selection.slide) },
      playHere: { label: t("Web.Play.ThisWindow"), enabled: has && !master, run: () => this.play(this.selection.slide, { presenter: false }) },
      playPresenter: { label: t("Web.Play.PresenterView"), enabled: has && !master, run: () => this.play(this.selection.slide, { presenter: true }) },
      previewAnimations: { label: t("Menu.Play.PreviewAnimations"), enabled: has, run: () => this.previewAnimations() },
      customShows: { label: t("Menu.Play.CustomShows"), enabled: has, run: () => this.showCustomShows() },
      zoomIn: { label: t("Menu.View.ZoomIn"), shortcut: shortcut("="), enabled: has, run: () => this.stepZoom(1) },
      zoomOut: { label: t("Menu.View.ZoomOut"), shortcut: shortcut("-", { alt: true }), enabled: has, run: () => this.stepZoom(-1) },
      zoomToFit: { label: t("Menu.View.ZoomToFit"), shortcut: shortcut("9"), enabled: has, run: () => this.setZoom("fit") },
      actualSize: { label: t("Menu.View.ActualSize"), shortcut: shortcut("0"), enabled: has, run: () => this.setZoom(1) },
      toggleNavigator: { label: t("Menu.View.Navigator"), checked: !this.root.classList.contains("hides-navigator"), run: () => this.setPanelVisible("navigator", this.root.classList.contains("hides-navigator")) },
      toggleNotes: { label: t("Menu.View.Notes"), checked: !this.root.classList.contains("hides-notes"), run: () => this.setPanelVisible("notes", this.root.classList.contains("hides-notes")) },
      toggleInspector: { label: t("Menu.View.Inspector"), shortcut: shortcut("I", { alt: true }), checked: !this.root.querySelector(".app__inspector").hidden, run: () => this.setPanelVisible("inspector", this.root.querySelector(".app__inspector").hidden) },
      fullScreen: {
        label: t("Web.Menu.FullScreen"),
        enabled: Boolean(document.fullscreenEnabled), checked: Boolean(document.fullscreenElement),
        run: () => (document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen()),
      },
      chartData: { label: t("ActionBar.ChartData"), enabled: selected?.kind === "chart", run: () => this.showChartData() },
      crop: { label: t("Picture.Crop"), enabled: selected?.kind === "picture", run: () => this.crop() },
      resetCrop: { label: t("Picture.ResetCrop"), enabled: selected?.kind === "picture", run: () => this.engine.call("resetCrop") },
      replacePicture: { label: t("Picture.Replace"), enabled: selected?.kind === "picture", run: () => this.pickPicture((picture) => this.engine.call("replacePicture", picture.args, picture.bytes)) },
      fillPicture: { label: t("Fill.Picture.Choose"), enabled: shapes > 0, run: () => this.pickPicture((picture) => this.engine.call("setFillPicture", picture.args, picture.bytes)) },
      backgroundPicture: { label: t("Fill.Picture.Choose"), enabled: has, run: () => this.pickPicture((picture) => this.engine.call("setBackgroundPicture", picture.args, picture.bytes)) },
      about: { label: t("Menu.App.About", "Dazzle"), run: () => this.showAbout() },
      downloadApp: {
        label: t(appStorePlatform === "mac" ? "Web.Help.DownloadMacApp" : "Web.Help.DownloadiOSApp"),
        run: () => window.open(`${APP_STORE_URL}?platform=${appStorePlatform === "mac" ? "mac" : "iphone"}`, "_blank", "noopener"),
      },
      unsupported: {
        label: t("Toolbar.UnsupportedFeatures"),
        enabled: has && Boolean(info?.unsupported?.length || info?.omissions?.length || this.fontSubstitutions().length),
        run: () => this.showNotices({ always: true }),
      },
    };
  }

  run(id) {
    const command = this.commands[id];
    if (!command || command.enabled === false) return null;
    return Promise.resolve(command.run()).catch((error) => this.showMessage(error.message, "error"));
  }

  item(id) {
    const command = this.commands[id];
    return {
      label: command.label,
      shortcut: command.shortcut,
      checked: command.checked === undefined ? undefined : Boolean(command.checked),
      disabled: "enabled" in command && !command.enabled,
      action: () => this.run(id),
    };
  }

  items(...ids) {
    return ids.map((id) => (id === "-" ? { separator: true } : this.item(id)));
  }

  buildMenus() {
    const self = this;
    const menus = [
      { label: t("Menu.File"), get items() { return self.fileMenu(); } },
      { label: t("Menu.Edit"), get items() {
        return [
          ...self.items("undo", "redo", "-", "cut", "copy", "paste", "duplicate", "delete", "-", "selectAll", "deselectAll", "-"),
          { label: t("Menu.Edit.Find"), submenu: self.items("find", "findReplace", "findNext", "findPrevious") },
        ];
      } },
      { label: t("Menu.Insert"), get items() {
        const has = self.hasDocument;
        return [
          ...self.items("insertTextBox"),
          { label: t("Menu.Insert.Shape"), disabled: !has, submenu: self.shapeItems() },
          ...self.items("insertTable"),
          { label: t("Menu.Insert.Chart"), disabled: !has, submenu: self.chartItems() },
          { separator: true },
          ...self.items("insertPicture", "insertMovie"),
        ];
      } },
      { label: t("Menu.Slide"), get items() {
        return [
          ...self.items("newSlide"),
          { label: t("Menu.Slide.NewWithLayout"), disabled: !self.hasDocument, submenu: self.layoutItems() },
          ...self.items("duplicateSlides", "deleteSlides", "renameLayout", "toggleHidden", "-", "previousSlide", "nextSlide", "-", "headerFooter"),
        ];
      } },
      { label: t("Menu.Format"), get items() {
        return [
          { label: t("Format.Section.Font"), submenu: self.items("bold", "italic", "underline", "strike", "-", "bigger", "smaller", "-", "superscript", "subscript") },
          { label: t("Format.Alignment"), submenu: self.items("alignLeft", "alignCenter", "alignRight", "alignJustify") },
          { label: t("Format.List"), submenu: self.items("bullets", "numbers", "-", "indent", "outdent") },
        ];
      } },
      { label: t("ActionBar.Arrange"), get items() {
        return [
          ...self.items("front", "forward", "backward", "back", "-"),
          { label: t("Menu.Arrange.AlignObjects"), disabled: !(self.selection.shapes?.length), submenu: [
            ["left", "Align.Left"], ["center", "Align.Center"], ["right", "Align.Right"], ["top", "Align.Top"], ["middle", "Align.Middle"], ["bottom", "Align.Bottom"],
          ].map(([how, key]) => ({ label: t(key), action: () => self.engine.call("align", { how }) })) },
          { label: t("Menu.Arrange.Distribute"), disabled: (self.selection.shapes?.length ?? 0) < 3, submenu: [
            { label: t("Align.DistributeHorizontally"), action: () => self.engine.call("distribute", { horizontally: true }) },
            { label: t("Align.DistributeVertically"), action: () => self.engine.call("distribute", { horizontally: false }) },
          ] },
          { separator: true },
          ...self.items("rotateLeft", "rotateRight", "flipH", "flipV", "-", "group", "ungroup"),
        ];
      } },
      { label: t("Menu.View"), get items() {
        const current = readSetting("appearance", "");
        return [
          ...self.items("toggleNavigator", "toggleNotes", "toggleInspector", "-", "masterView", "-", "zoomIn", "zoomOut", "zoomToFit", "actualSize", "-"),
          { label: t("Web.Menu.Appearance"), submenu: [
            { label: t("Web.Appearance.System"), checked: current === "", action: () => self.applyAppearance("") },
            { label: t("Web.Appearance.Light"), checked: current === "light", action: () => self.applyAppearance("light") },
            { label: t("Web.Appearance.Dark"), checked: current === "dark", action: () => self.applyAppearance("dark") },
          ] },
          { separator: true },
          self.item("fullScreen"),
        ];
      } },
      { label: t("Menu.Play"), get items() {
        return [
          ...self.items("playFromStart", "playFromCurrent"),
          { label: t("Toolbar.PlayCustomShow"), disabled: !self.hasDocument, submenu: self.customShowItems() },
          ...self.items("customShows", "-", "playPresenter", "playHere", "-", "previewAnimations"),
        ];
      } },
      { label: t("Menu.Window"), get items() {
        return self.document ? [{ label: self.document.name, checked: true, action: () => self.canvas.element.focus() }] : [{ label: "Dazzle", disabled: true }];
      } },
      { label: t("Menu.Help"), get items() { return self.items(...(appStorePlatform ? ["downloadApp", "-"] : []), "about"); } },
    ];
    const bar = this.root.querySelector("#menu-bar");
    this.menuBarOverflow = attachMenuBar(bar, menus, { label: t("Web.Menu.Label"), overflowLabel: t("Toolbar.More") });
    const update = document.createElement("button");
    update.type = "button";
    update.className = "ds-button ds-button--ghost ds-button--xs app__update";
    update.innerHTML = `${icon("download")}<span></span>`;
    update.querySelector("span").textContent = t("Web.Update.Button");
    update.title = t("Web.Update.Available");
    update.hidden = true;
    bar.append(update);
    this.updateButton = update;
  }

  fileMenu() {
    const info = this.engine.info;
    const keynote = info?.saveFormats?.find((format) => format.key === "key");
    return [
      ...this.items("new", "open"),
      { label: t("Menu.File.OpenRecent"), submenu: this.recentItems() },
      { separator: true },
      ...this.items("close", "save", "saveAs", "rename"),
      { separator: true },
      { label: t("Menu.File.ExportTo"), disabled: !this.document, submenu: [
        this.item("exportPDF"), this.item("exportPowerPoint"),
        ...(keynote ? [{ label: t("Web.Export.Keynote"), action: () => this.exportAs(keynote) }] : []),
      ] },
      { separator: true },
      this.item("properties"),
      { separator: true },
      this.item("unsupported"),
      this.item("print"),
    ];
  }

  recentItems() {
    const recents = this.recents ?? [];
    if (!recents.length) return [{ label: t("Web.Start.NoRecent"), disabled: true }];
    return [
      ...recents.slice(0, 10).map((record) => ({ label: record.name, action: () => this.openRecord(record) })),
      { separator: true },
      { label: t("Menu.File.ClearRecent"), action: async () => {
        await storage.clearRecents();
        await this.refreshRecents();
      } },
    ];
  }

  /** The context menu over the slide, or over the selected shapes. */
  canvasMenu(shape) {
    if (!this.hasDocument) return null;
    if (!shape) {
      return [
        ...this.items("paste", "-", "selectAll", "-"),
        { label: t("Menu.Insert.Shape"), submenu: this.shapeItems() },
        ...this.items("insertTextBox", "insertPicture", "-", "newSlide"),
      ];
    }
    return [
      ...this.items("cut", "copy", "paste", "duplicate", "delete", "-", "front", "back", "-", "group", "ungroup"),
      ...(this.canvas.shape(shape)?.kind === "picture" ? [{ separator: true }, ...this.items("crop", "replacePicture")] : []),
      ...(this.canvas.shape(shape)?.kind === "chart" ? [{ separator: true }, this.item("chartData")] : []),
    ];
  }

  /** The context menu over slides in the navigator. */
  slideMenu(ids) {
    if (!this.hasDocument) return null;
    const hidden = ids.length && ids.every((id) => this.engine.state.slides.find((slide) => slide.id === id)?.hidden);
    // A master offers a new layout; a layout, what can be done to it.
    if (this.engine.state.masterView) {
      const isLayout = this.engine.state.slides.find((slide) => slide.id === ids[0])?.role === "layout";
      return [
        this.item("newSlide"),
        ...(isLayout ? [this.item("duplicateSlides"), { label: t("MasterView.Rename"), action: () => this.renameLayout(ids[0]) }, { separator: true }, this.item("deleteSlides")] : []),
        { separator: true },
        this.item("masterView"),
      ];
    }
    return [
      this.item("newSlide"),
      { label: t("Menu.Slide.NewWithLayout"), submenu: this.layoutItems() },
      { separator: true },
      { label: t("Edit.CutSlide"), action: () => this.copySlides(ids, { cut: true }) },
      { label: t("Edit.CopySlide"), action: () => this.copySlides(ids) },
      { label: t("Edit.PasteAfter"), action: () => this.clipboard("paste") },
      { separator: true },
      { label: t("Slide.Menu.Duplicate"), action: () => this.engine.call("duplicateSlides", { ids }) },
      { label: hidden ? t("Slide.Menu.Show") : t("Slide.Menu.Hide"), action: () => this.engine.call("toggleHidden", { ids }) },
      { label: t("Slide.Menu.Delete"), disabled: this.engine.state.slides.length <= ids.length, action: () => this.engine.call("deleteSlides", { ids }) },
      { separator: true },
      { label: t("Slide.Menu.Play"), action: () => this.play(ids[0]) },
    ];
  }

  // MARK: - Editing

  currentSlide() {
    return this.engine.state?.slides.find((slide) => slide.id === this.selection.slide) ?? null;
  }

  /** Shows the masters and layouts in place of the slides, to be edited as slides are, or the slides again. */
  async toggleMasterView() {
    await this.canvas.endEditing();
    await this.flushNotes();
    await this.engine.call("masterView", { on: !this.engine.state?.masterView });
  }

  /** Asks for another name for a layout. */
  async renameLayout(id) {
    const layout = this.engine.state?.slides.find((slide) => slide.id === id);
    if (layout?.role !== "layout") return;
    const name = await this.askText(t("MasterView.Rename.Title"), layout.name, t("MasterView.Rename.Confirm"));
    if (name && name !== layout.name) await this.engine.call("renameLayout", { ids: [id], name });
  }

  currentLayout() {
    return this.engine.info?.outline?.find((slide) => slide.id === this.selection.slide)?.layout;
  }

  /** The slides the navigator has picked, or the current one. */
  pickedSlides() {
    const picked = [...(this.navigator?.selected ?? [])];
    return picked.length ? picked : [this.selection.slide].filter(Boolean);
  }

  async stepSlide(step) {
    const slides = this.engine.state?.slides ?? [];
    const index = slides.findIndex((slide) => slide.id === this.selection.slide);
    const next = slides[index + step];
    if (next) await this.pickSlide(next.id);
  }

  async pickSlide(id) {
    if (id === this.selection.slide) return;
    await this.canvas.endEditing();
    await this.flushNotes();
    await this.engine.call("select", { slide: id, shapes: [] });
  }

  async insert(command, args = {}) {
    await this.canvas.endEditing();
    await this.engine.call(command, args);
  }

  /** Sets character or paragraph formatting: on the text selected while typing, or all of the selected shapes' text. */
  async format(set) {
    if (!this.hasDocument) return;
    if (this.canvas.editing) {
      await this.canvas.sync();
      const range = this.canvas.textSelection();
      if (range) await this.engine.call("textSelection", range);
    }
    this.look = await this.engine.call("format", { set });
    this.updateLook();
  }

  async undo() {
    if (this.canvas.editing) {
      // Typing has its own undo until it is handed over.
      await this.canvas.endEditing();
    }
    await this.engine.call("undo");
  }

  async redo() {
    if (this.canvas.editing) await this.canvas.endEditing();
    await this.engine.call("redo");
  }

  async clipboard(action) {
    if (this.canvas.editing || document.activeElement?.matches?.("input, textarea")) {
      // Text being typed uses the browser's own clipboard.
      if (action === "paste") {
        const text = await navigator.clipboard?.readText?.().catch(() => null);
        if (text != null) document.execCommand("insertText", false, text);
        else this.showMessage(t("Web.Clipboard.PasteShortcut", shortcut("V")), "info");
      } else {
        document.execCommand(action);
      }
      return;
    }
    if (action === "copy" || action === "cut") {
      const slides = document.activeElement?.closest?.(".app__navigator") ? this.pickedSlides() : null;
      const copied = await this.engine.call("copy", slides ? { slides } : {});
      if (copied?.text) navigator.clipboard?.writeText?.(copied.text).catch(() => {});
      this.clipboardStamp = copied?.text ?? "";
      if (action === "cut") {
        if (copied?.kind === "slides") await this.engine.call("deleteSlides", { ids: slides ?? [this.selection.slide] });
        else await this.engine.call("delete");
      }
      return;
    }
    // Paste: this window's own shapes or slides, unless another app's picture or text is newer.
    const items = await navigator.clipboard?.read?.().catch(() => null);
    const image = items?.flatMap((item) => item.types.filter((type) => type.startsWith("image/")).map((type) => [item, type]))[0];
    if (image) {
      const blob = await image[0].getType(image[1]);
      await this.insertPictureBytes(new Uint8Array(await blob.arrayBuffer()));
      return;
    }
    const text = await navigator.clipboard?.readText?.().catch(() => null);
    const hasOwn = await this.engine.call("hasClipboard");
    if (hasOwn && (text == null || text === this.clipboardStamp)) {
      await this.engine.call("paste");
      return;
    }
    if (text) await this.engine.call("pasteText", { text });
    else if (hasOwn) await this.engine.call("paste");
  }

  async copySlides(ids, { cut = false } = {}) {
    const copied = await this.engine.call("copy", { slides: ids });
    this.clipboardStamp = copied?.text ?? "";
    if (copied?.text) navigator.clipboard?.writeText?.(copied.text).catch(() => {});
    if (cut && this.engine.state.slides.length > ids.length) await this.engine.call("deleteSlides", { ids });
  }

  async selectAll() {
    if (this.canvas.editing) {
      document.getSelection().selectAllChildren(this.canvas.editing.flow);
      return;
    }
    await this.engine.call("selectAll");
  }

  /** Opens the table size picker under the toolbar's table button, or closes it when it is open. */
  insertTable() {
    if (closeTablePicker()) return;
    const toolbar = this.root.querySelector("#toolbar");
    const button = toolbar.querySelector('[data-command="insertTable"]');
    // When the button has moved into the toolbar's » menu, the picker hangs from the toolbar.
    const anchor = button && !button.hidden && button.getClientRects().length > 0 ? button : toolbar;
    openTablePicker(this.root, anchor, { icon, onInsert: (size) => this.insert("insertTable", size) });
  }

  async pickPicture(use) {
    const file = await files.pickFile({ pictures: true }).catch(() => null);
    if (!file) return;
    const picture = await preparePicture(file.bytes, file.name);
    if (!picture) {
      this.showMessage(t("Error.UnreadablePicture"), "error");
      return;
    }
    await use({ args: { ext: picture.ext, w: picture.w, h: picture.h, tiled: false }, bytes: picture.bytes });
  }

  async insertPicture() {
    const file = await files.pickFile({ pictures: true }).catch(() => null);
    if (file) await this.insertPictureBytes(file.bytes, file.name);
  }

  async insertPictureBytes(bytes, name = "", frame = null) {
    const picture = await preparePicture(bytes, name);
    if (!picture) {
      this.showMessage(t("Error.UnreadablePicture"), "error");
      return;
    }
    await this.insert("insertPicture", { ext: picture.ext, w: picture.w, h: picture.h, ...(frame ? { frame } : {}) }, picture.bytes);
  }

  async insertMovie() {
    const file = await files.pickFile({ movies: true }).catch(() => null);
    if (file) await this.insertMovieBytes(file.bytes, file.name);
  }

  async insertMovieBytes(bytes, name) {
    const ext = (name.split(".").pop() ?? "mp4").toLowerCase();
    const type = { mov: "video/quicktime", webm: "video/webm", m4v: "video/x-m4v" }[ext] ?? "video/mp4";
    const movie = await prepareMovie(bytes, type);
    if (!movie) {
      this.showMessage(t("Error.UnreadableVideo"), "error");
      return;
    }
    // The poster's PNG, then the movie, in one payload.
    const payload = new Uint8Array(movie.poster.length + bytes.length);
    payload.set(movie.poster, 0);
    payload.set(bytes, movie.poster.length);
    await this.insert("insertVideo", { posterLength: movie.poster.length, w: movie.w * 0.75, h: movie.h * 0.75, ext: ext === "m4v" ? "mp4" : ext }, payload);
  }

  /** A file dropped on the window: a presentation opens, a picture or movie goes on the slide. */
  async dropped(file) {
    if (/\.(pptx|pptm|ppsx|key)$/i.test(file.name) || !this.hasDocument) {
      await this.openFile(file);
    } else if (/\.(mp4|m4v|mov|webm)$/i.test(file.name)) {
      await this.insertMovieBytes(file.bytes, file.name);
    } else {
      await this.insertPictureBytes(file.bytes, file.name);
    }
  }

  print() {
    // Each slide prints on a page of its own, as the slides are drawn for the slideshow.
    this.preparePrint().then(() => window.print());
  }

  async preparePrint() {
    let holder = document.querySelector(".app__print");
    holder?.remove();
    holder = document.createElement("div");
    holder.className = "app__print";
    const drawer = new SlideDrawer(this.media);
    const size = this.engine.info.size;
    const style = document.createElement("style");
    style.textContent = `@page { size: ${size.w}pt ${size.h}pt; margin: 0; }`;
    holder.append(style);
    for (const slide of this.engine.state.slides) {
      if (slide.hidden) continue;
      const scene = await this.engine.call("scene", { slide: slide.id });
      const page = document.createElement("div");
      page.className = "app__print-page";
      page.style.width = `${size.w}pt`;
      page.style.height = `${size.h}pt`;
      const drawn = drawer.draw(scene);
      drawn.style.transform = `scale(${4 / 3})`;
      page.append(drawn);
      holder.append(page);
    }
    document.body.append(holder);
    // Pictures have a moment to arrive before the browser lays out the pages.
    await Promise.all([...holder.querySelectorAll("image")].map(() => Promise.resolve()));
    for (const slide of holder.querySelectorAll(".slide")) drawer.fit(slide);
    await new Promise((resolve) => setTimeout(resolve, 300));
    window.addEventListener("afterprint", () => holder.remove(), { once: true });
  }

  /** Plays the slide's animations through on the canvas, one step after another. */
  async previewAnimations() {
    const slide = this.selection.slide;
    const timeline = await this.engine.call("timeline", { slide });
    if (!timeline.steps || timeline.through < 0) return;
    await this.canvas.endEditing();
    const started = performance.now();
    const element = this.canvas.slide;
    const tick = async () => {
      const elapsed = (performance.now() - started) / 1000;
      if (elapsed > timeline.through + 0.6 || this.canvas.slide !== element) {
        applyFrame(element, null);
        return;
      }
      const frame = await this.engine.call("frame", { slide, elapsed, through: true });
      applyFrame(element, frame);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  async play(slideID, options = {}) {
    if (!this.hasDocument) return;
    await this.canvas.endEditing();
    await this.flushNotes();
    const presenter = options.presenter ?? hasSecondDisplay();
    await this.slideshow.start(slideID ?? this.engine.state.slides[0]?.id, { presenter, customShow: options.customShow });
    if (presenter && this.slideshow.mode !== "presenter") this.showMessage(t("Web.Play.PopupBlocked"), "info");
  }

  stepZoom(direction) {
    const current = this.canvas.scale;
    const next = direction > 0 ? ZOOMS.find((z) => z > current + 0.001) : [...ZOOMS].reverse().find((z) => z < current - 0.001);
    if (next) this.setZoom(next);
  }

  setZoom(zoom) {
    this.canvas.setZoom(zoom);
    this.zoomSelect.value = String(zoom);
  }

  // MARK: - Pictures and charts

  /** Crops the picture: dragging the visible part's edges over the whole image, in a sheet. */
  async crop() {
    const data = await this.engine.call("inspect");
    const shape = data?.shape;
    if (!shape?.image) return;
    const src = this.canvas.slide?.querySelector(`.shape[data-id="${shape.id}"] image`)?.getAttribute("href");
    if (!src) return;
    const image = shape.image;
    const scale = Math.min(480 / image.w, 320 / image.h);
    const backdrop = this.sheet(`
      <form class="ds-sheet app__crop-sheet" role="dialog" aria-labelledby="crop-title">
        <div class="ds-sheet__body">
          <h2 class="ds-sheet__title" id="crop-title">${escapeHTML(t("Picture.Crop"))}</h2>
          <div class="app__crop" style="width:${image.w * scale}px;height:${image.h * scale}px">
            <img src="${src}" alt="" draggable="false" width="${Math.round(image.w * scale)}" height="${Math.round(image.h * scale)}">
            <div class="app__crop-frame">${["nw", "n", "ne", "e", "se", "s", "sw", "w"].map((h) => `<span class="canvas__handle canvas__handle--${h}" data-handle="${h}"></span>`).join("")}</div>
          </div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
          <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("Picture.DoneCropping"))}</button>
        </div>
      </form>`);
    const frame = backdrop.querySelector(".app__crop-frame");
    // The visible part, in the image's own fractions.
    let crop = { l: (shape.x - image.x) / image.w, t: (shape.y - image.y) / image.h, r: (image.x + image.w - shape.x - shape.w) / image.w, b: (image.y + image.h - shape.y - shape.h) / image.h };
    const place = () => Object.assign(frame.style, {
      left: `${crop.l * 100}%`, top: `${crop.t * 100}%`, right: `${crop.r * 100}%`, bottom: `${crop.b * 100}%`,
    });
    place();
    frame.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      const handle = event.target.dataset.handle ?? "move";
      const start = { x: event.clientX, y: event.clientY, crop: { ...crop } };
      const width = image.w * scale;
      const height = image.h * scale;
      const move = (moveEvent) => {
        const dx = (moveEvent.clientX - start.x) / width;
        const dy = (moveEvent.clientY - start.y) / height;
        const next = { ...start.crop };
        if (handle === "move") {
          const w = 1 - next.l - next.r;
          const h = 1 - next.t - next.b;
          next.l = Math.min(Math.max(next.l + dx, 0), 1 - w);
          next.t = Math.min(Math.max(next.t + dy, 0), 1 - h);
          next.r = 1 - w - next.l;
          next.b = 1 - h - next.t;
        } else {
          if (handle.includes("w")) next.l = Math.min(Math.max(next.l + dx, 0), 1 - next.r - 0.02);
          if (handle.includes("e")) next.r = Math.min(Math.max(next.r - dx, 0), 1 - next.l - 0.02);
          if (handle.includes("n")) next.t = Math.min(Math.max(next.t + dy, 0), 1 - next.b - 0.02);
          if (handle.includes("s")) next.b = Math.min(Math.max(next.b - dy, 0), 1 - next.t - 0.02);
        }
        crop = next;
        place();
      };
      const up = () => {
        window.removeEventListener("pointermove", move);
        window.removeEventListener("pointerup", up);
      };
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", up);
    });
    backdrop.querySelector("form").addEventListener("submit", async (event) => {
      event.preventDefault();
      dismissSheet(backdrop);
      const frameRect = {
        x: image.x + crop.l * image.w, y: image.y + crop.t * image.h,
        w: image.w * (1 - crop.l - crop.r), h: image.h * (1 - crop.t - crop.b),
      };
      await this.engine.call("setCrop", { shape: shape.id, crop: [crop.l, crop.t, crop.r, crop.b], frame: frameRect });
    });
  }

  /** The chart's data, as a table to type into, in a sheet. */
  async showChartData() {
    const data = await this.engine.call("inspect");
    const chart = data?.shape?.chart;
    if (!chart) return;
    const series = chart.series.map((entry) => ({ ...entry }));
    const categories = [...chart.categories];
    const backdrop = this.sheet(`
      <form class="ds-sheet app__chart-sheet" role="dialog" aria-labelledby="chart-title">
        <div class="ds-sheet__body">
          <h2 class="ds-sheet__title" id="chart-title">${escapeHTML(t("Chart.Section.Data"))}</h2>
          <div class="app__chart-grid"></div>
          <div class="app__inspector-buttons">
            <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-add="category">${escapeHTML(t("Chart.Data.AddCategory"))}</button>
            <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-add="series">${escapeHTML(t("Chart.Data.AddSeries"))}</button>
          </div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
          <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("Web.Common.Done"))}</button>
        </div>
      </form>`);
    const grid = backdrop.querySelector(".app__chart-grid");
    const render = () => {
      grid.innerHTML = `<table class="ds-table app__chart-table"><thead><tr><th>${escapeHTML(chart.kind === "scatter" ? t("Chart.Data.X") : t("Chart.Data.Category"))}</th>${
        series.map((entry, index) => `<th><input class="ds-text-input ds-text-input--xs" data-series="${index}" value="${escapeHTML(entry.name)}" aria-label="${escapeHTML(t("Chart.Data.SeriesName"))}">${
          series.length > 1 ? `<button class="ds-button ds-button--ghost ds-button--xs" type="button" data-remove-series="${index}">${escapeHTML(t("Chart.Data.DeleteSeries"))}</button>` : ""}</th>`).join("")
      }</tr></thead><tbody>${categories.map((category, row) => `<tr><td><input class="ds-text-input ds-text-input--xs" data-category="${row}" value="${escapeHTML(category)}" aria-label="${escapeHTML(t("Chart.Data.Category"))}">${
        categories.length > 1 ? `<button class="ds-button ds-button--ghost ds-button--xs" type="button" data-remove-category="${row}">${escapeHTML(t("Chart.Data.DeleteCategory"))}</button>` : ""}</td>${
        series.map((entry, column) => `<td><input class="ds-text-input ds-text-input--xs ds-numeric" data-value="${row}:${column}" value="${escapeHTML(entry.values[row] ?? "")}" inputmode="decimal"></td>`).join("")
      }</tr>`).join("")}</tbody></table>`;
      for (const input of grid.querySelectorAll("input")) {
        input.addEventListener("input", () => {
          if (input.dataset.series !== undefined) series[Number(input.dataset.series)].name = input.value;
          if (input.dataset.category !== undefined) categories[Number(input.dataset.category)] = input.value;
          if (input.dataset.value !== undefined) {
            const [row, column] = input.dataset.value.split(":").map(Number);
            series[column].values[row] = input.value;
          }
        });
      }
      for (const button of grid.querySelectorAll("[data-remove-series]")) {
        button.addEventListener("click", () => {
          series.splice(Number(button.dataset.removeSeries), 1);
          render();
        });
      }
      for (const button of grid.querySelectorAll("[data-remove-category]")) {
        button.addEventListener("click", () => {
          const row = Number(button.dataset.removeCategory);
          categories.splice(row, 1);
          for (const entry of series) entry.values.splice(row, 1);
          render();
        });
      }
    };
    render();
    backdrop.querySelector('[data-add="category"]').addEventListener("click", () => {
      categories.push(chart.kind === "scatter" ? String(categories.length + 1) : t("Chart.Sample.Category", categories.length + 1));
      for (const entry of series) entry.values.push("");
      render();
    });
    backdrop.querySelector('[data-add="series"]').addEventListener("click", () => {
      series.push({ name: t("Chart.Sample.Series", series.length + 1), values: categories.map(() => "") });
      render();
    });
    backdrop.querySelector("form").addEventListener("submit", async (event) => {
      event.preventDefault();
      dismissSheet(backdrop);
      await this.engine.call("chart", { set: { categories, series } });
    });
  }

  // MARK: - Find

  showFind(replacing) {
    this.findForm.hidden = false;
    this.findForm.classList.toggle("is-replacing", replacing);
    const selected = document.getSelection()?.toString();
    if (selected && !selected.includes("\n")) this.findInput.value = selected;
    this.findIndex = -1;
    this.search();
    this.findInput.focus();
    this.findInput.select();
  }

  findOptions() {
    const options = {};
    for (const option of this.findForm.querySelectorAll("[data-find-option]")) options[option.dataset.findOption] = option.checked;
    return options;
  }

  async search() {
    const text = this.findInput.value;
    this.matches = text ? await this.engine.call("find", { text, ...this.findOptions() }) : [];
    this.findIndex = -1;
    this.updateFindCount();
  }

  updateFindCount() {
    const count = this.matches?.length ?? 0;
    const output = this.root.querySelector(".app__find-count");
    if (!this.findInput.value) output.textContent = "";
    else if (!count) output.textContent = t("Web.Find.NoMatches");
    else output.textContent = this.findIndex >= 0 ? t("Web.Find.Count", this.findIndex + 1, count) : t("Web.Find.Total", count);
  }

  async findAction(action) {
    if (action === "done") {
      this.findForm.hidden = true;
      this.canvas.element.focus();
      return;
    }
    if (this.findForm.hidden) this.showFind(false);
    if (action === "replaceAll") {
      if (!this.findInput.value) return;
      const count = await this.engine.call("replace", { text: this.findInput.value, with: this.replaceInput.value, ...this.findOptions() });
      this.showMessage(t("Find.Count", count), "info");
      await this.search();
      return;
    }
    if (action === "replace" && this.findIndex >= 0 && this.matches?.[this.findIndex]) {
      const match = this.matches[this.findIndex];
      await this.engine.call("replace", { text: this.findInput.value, with: this.replaceInput.value, ...this.findOptions(), only: { slide: match.slide, loc: match.loc } });
      const index = this.findIndex;
      await this.search();
      this.findIndex = Math.min(index, (this.matches?.length ?? 1) - 1) - 1;
      action = "next";
    }
    const matches = this.matches ?? [];
    if (!matches.length) {
      this.updateFindCount();
      return;
    }
    const step = action === "previous" ? -1 : 1;
    this.findIndex = ((this.findIndex < 0 && step < 0 ? 0 : this.findIndex + step) + matches.length) % matches.length;
    const match = matches[this.findIndex];
    // Shows the slide and selects what holds the match.
    await this.canvas.endEditing();
    await this.engine.call("select", { slide: match.slide, shapes: match.shape ? [match.shape] : [] });
    if (match.notes) {
      this.setPanelVisible("notes", true);
      this.notes.focus();
      this.notes.setSelectionRange(match.loc, match.loc + match.len);
      this.findInput.focus();
    }
    this.updateFindCount();
  }

  // MARK: - Panels

  setPanelVisible(panel, visible, { remember = true } = {}) {
    if (panel === "inspector") {
      const inspector = this.root.querySelector(".app__inspector");
      inspector.hidden = !visible;
      this.root.querySelector("#inspector-toggle").setAttribute("aria-pressed", String(visible));
      if (visible) this.inspector?.refresh({ force: true });
    } else {
      this.root.classList.toggle(`hides-${panel}`, !visible);
      this.root.querySelector(`[data-command="toggle${panel[0].toUpperCase()}${panel.slice(1)}"]`)?.setAttribute("aria-pressed", String(visible));
    }
    if (remember) writeSetting(panel, visible ? "1" : "0");
  }

  // MARK: - Engine events

  bindEngine() {
    this.engine.addEventListener("state", () => this.update());
    this.engine.addEventListener("document", () => {
      this.updateTitle();
      this.navigator.sizeThumbnails();
    });
    this.engine.addEventListener("content", async (event) => {
      if (!this.document && !event.detail.isNew) return;
      const { changed, pageEdit, isNew } = event.detail;
      if (isNew) {
        this.navigator.clear();
        this.media.clear();
        await this.loadFonts();
      }
      this.navigator.update();
      const current = this.selection.slide;
      // The slide on the canvas draws again unless its change was typed on it.
      if (isNew || (!pageEdit && changed.includes(current))) await this.canvas.refresh();
      this.refreshInspector();
    });
    this.engine.addEventListener("fatal", () => this.showMessage(t("Web.Error.Engine"), "error", {
      action: { label: t("Web.Error.Reload"), run: () => location.reload() },
      sticky: true,
    }));
    this.navigator.addEventListener("pick", (event) => this.pickSlide(event.detail));
    this.navigator.addEventListener("move", (event) => this.engine.call("moveSlides", event.detail));
    this.navigator.addEventListener("command", (event) => this.run(event.detail));
    this.canvas.addEventListener("command", (event) => this.run(event.detail));
    this.canvas.addEventListener("selection", () => this.refreshInspector());
    this.canvas.addEventListener("look", (event) => {
      this.look = event.detail;
      this.updateLook();
      this.refreshInspector();
    });
    this.canvas.addEventListener("editing", () => this.updateLook());
    this.canvas.addEventListener("zoom", (event) => {
      if (this.zoomSelect.value === "fit") return;
      const zoom = event.detail;
      const preset = [...this.zoomSelect.options].find((option) => Math.abs(Number(option.value) - zoom) < 0.005);
      if (preset) this.zoomSelect.value = preset.value;
    });
    this.canvas.addEventListener("contextmenu", (event) => {
      const items = this.canvasMenu(event.detail.shape);
      if (!items) return;
      event.detail.event.preventDefault();
      openMenu(items, { x: event.detail.event.clientX, y: event.detail.event.clientY }, { placement: "point" });
    });
    this.canvas.element.addEventListener("paste", (event) => {
      if (this.canvas.editing) return;
      const file = [...(event.clipboardData?.files ?? [])].find((candidate) => candidate.type.startsWith("image/"));
      if (!file) return;
      event.preventDefault();
      file.arrayBuffer().then((buffer) => this.insertPictureBytes(new Uint8Array(buffer), file.name));
    });
    this.inspector.addEventListener("format", (event) => this.format(event.detail));
    this.slideshow.addEventListener("end", async (event) => {
      // Back to editing where the presenter left off.
      if (event.detail && event.detail !== this.selection.slide) await this.engine.call("select", { slide: event.detail, shapes: [] });
      this.canvas.element.focus();
    });
  }

  refreshInspector() {
    clearTimeout(this.inspectorTimer);
    this.inspectorTimer = setTimeout(() => this.inspector.refresh(), 60);
  }

  updateLook() {
    const toolbar = this.root.querySelector("#toolbar");
    const look = this.look ?? {};
    for (const command of ["bold", "italic", "underline"]) {
      toolbar.querySelector(`[data-command="${command}"]`).setAttribute("aria-pressed", String(Boolean(look[command])));
    }
  }

  update() {
    const state = this.engine.state;
    if (!state) return;
    const toolbar = this.root.querySelector("#toolbar");
    toolbar.querySelector('[data-command="undo"]').disabled = !state.canUndo && !this.canvas.editing;
    toolbar.querySelector('[data-command="redo"]').disabled = !state.canRedo;
    this.updateTitle();
    this.updateStatus();
    if (this.canvas.slideID && this.canvas.slideID !== state.sel.slide) {
      this.canvas.refresh({ keepEditing: false });
      this.navigator.update();
      this.navigator.reveal();
    } else {
      this.canvas.syncSelection();
    }
    this.updateNotes();
    if (this.hasUnkeptChanges && !this.autosaveTimer) this.scheduleAutosave();
  }

  /** The notes of the slide being edited, unless they're being typed. */
  async updateNotes() {
    const slide = this.selection.slide;
    if (!slide || document.activeElement === this.notes) return;
    if (this.notesSlide === slide && this.notesRev === this.currentSlide()?.rev) return;
    this.notesSlide = slide;
    this.notesRev = this.currentSlide()?.rev;
    const timeline = await this.engine.call("timeline", { slide }).catch(() => null);
    if (timeline && document.activeElement !== this.notes) this.notes.value = timeline.notes ?? "";
  }

  async flushNotes() {
    if (!this.notesTimer) return;
    clearTimeout(this.notesTimer);
    this.notesTimer = null;
    await this.engine.call("setNotes", { text: this.notes.value });
  }

  updateStatus() {
    const status = this.root.querySelector(".app__status-slide");
    const slides = this.engine.state?.slides ?? [];
    const index = slides.findIndex((slide) => slide.id === this.selection.slide);
    status.textContent = this.document && index >= 0 ? t("Slideshow.Position", index + 1, slides.length) : "";
  }

  updateTitle() {
    const name = this.document?.name ?? "Dazzle";
    this.titleElement.textContent = name;
    const edited = this.engine.state?.edited;
    const status = this.document ? (edited ? t("Web.Document.Edited") : this.document.handle ? t("Web.Document.Saved") : "") : "";
    // Says the masters and layouts are what is being edited.
    this.subtitleElement.textContent = this.document && this.engine.state?.masterView ? [t("MasterView.Title"), status].filter(Boolean).join(" — ") : status;
    document.title = this.document ? `${name}${edited ? " — " + t("Web.Document.Edited") : ""}` : "Dazzle";
  }

  async loadFonts() {
    for (const face of this.fontFaces ?? []) document.fonts.delete(face);
    this.fontFaces = [];
    if (!this.engine.info?.hasEmbeddedFonts) return;
    const { result, payload } = await this.engine.call("fonts").catch(() => ({ result: [] }));
    for (const font of result ?? []) {
      const face = new FontFace(font.family, payload.slice(font.offset, font.offset + font.length), {
        weight: font.bold ? "700" : "400", style: font.italic ? "italic" : "normal",
      });
      try {
        document.fonts.add(await face.load());
        this.fontFaces.push(face);
      } catch {
        // A font the browser can't read is drawn in another.
      }
    }
  }

  // MARK: - Messages

  showMessage(text, kind = "info", { action = null, sticky = false } = {}) {
    if (!text) return;
    const banner = document.createElement("div");
    banner.className = `ds-notification ds-notification--${kind === "info" ? "info" : kind} app__banner`;
    banner.setAttribute("role", kind === "error" ? "alert" : "status");
    banner.innerHTML = `${icon(kind === "error" ? "error" : kind === "warning" ? "warning" : "info", "ds-icon--20")}<div></div>
      <span class="app__banner-actions"></span>`;
    banner.querySelector("div").textContent = text;
    const actions = banner.querySelector(".app__banner-actions");
    if (action) {
      const button = document.createElement("button");
      button.className = "ds-button ds-button--bordered ds-button--xs";
      button.textContent = action.label;
      button.addEventListener("click", () => {
        banner.remove();
        action.run();
      });
      actions.append(button);
    }
    const close = document.createElement("button");
    close.className = "ds-button ds-button--ghost ds-button--icon ds-button--xs";
    close.innerHTML = icon("close");
    close.ariaLabel = close.title = t("Web.Common.Close");
    close.addEventListener("click", () => banner.remove());
    actions.append(close);
    this.banners.append(banner);
    if (!sticky) setTimeout(() => banner.remove(), kind === "error" ? 8000 : 5000);
  }

  /** What the presentation has that Dazzle keeps but can't show or edit, and what a Keynote document lost on the way in. */
  showNotices({ always = false } = {}) {
    const info = this.engine.info;
    if (!info) return;
    if (info.unsupported?.length) {
      this.showMessage(`${t("Notice.UnsupportedFeatures.Intro")} ${info.unsupported.join(" ")}`, "info", { sticky: always });
    }
    if (info.omissions?.length) {
      this.showMessage(`${t("Notice.Omitted.Intro")} ${info.omissions.join(" ")}`, "warning", { sticky: always });
    }
    const substitutions = this.fontSubstitutions();
    if (substitutions.length) {
      this.showMessage(`${t("Notice.Fonts.Intro")} ${substitutions.join(", ")}`, "info", { sticky: always });
    }
  }

  /** The presentation's typefaces this device doesn't have, each as "Requested → what it's set in". */
  fontSubstitutions() {
    const typefaces = this.engine.info?.typefaces ?? [];
    if (!typefaces.length) return [];
    // Typefaces are checked once each, as a check measures text.
    this.installedTypefaces ??= new Map();
    const has = (family) => {
      if (!this.installedTypefaces.has(family)) this.installedTypefaces.set(family, isInstalled(family));
      return this.installedTypefaces.get(family);
    };
    const generic = { sans: "Notice.Fonts.Generic.Sans", serif: "Notice.Fonts.Generic.Serif", monospace: "Notice.Fonts.Generic.Monospace" }; // design-lint-allow (document content)
    return typefaces.filter((family) => !has(family)).map((family) => {
      const substitute = substituteFor(family, has);
      return `${family} → ${substitute.family ?? t(generic[substitute.generic])}`;
    });
  }

  /** A window-modal sheet from `html`, added to the window, closing on Escape or its Cancel button. */
  sheet(html) {
    const backdrop = document.createElement("div");
    backdrop.className = "ds-sheet-backdrop app__sheet-backdrop";
    backdrop.innerHTML = html;
    backdrop.addEventListener("keydown", (event) => event.key === "Escape" && dismissSheet(backdrop));
    backdrop.querySelector("[data-cancel]")?.addEventListener("click", () => dismissSheet(backdrop));
    this.root.append(backdrop);
    backdrop.querySelector("input, [type=submit], button")?.focus();
    return backdrop;
  }

  showAbout() {
    const backdrop = this.sheet(`
      <div class="ds-sheet ds-alert app__about" role="alertdialog" aria-labelledby="about-title" aria-describedby="about-message">
        <div class="ds-sheet__body">
          <img class="app__about-icon" src="app/icons/icon.svg" width="48" height="48" alt="" draggable="false">
          <div>
            <h2 class="ds-sheet__title" id="about-title">Dazzle</h2>
            <p class="ds-caption app__about-version"></p>
            <p class="ds-sheet__message" id="about-message"></p>
            <p class="ds-sheet__message app__about-suite"><a href="https://atelier.ktgk.app" target="_blank" rel="noopener"></a></p>
          </div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-source>${escapeHTML(t("Toolbar.SourceCode"))}</button>
          <button class="ds-button ds-button--primary" type="button" data-cancel>${escapeHTML(t("Web.Common.Close"))}</button>
        </div>
      </div>`);
    backdrop.querySelector("#about-message").textContent = t("Web.About.Message");
    backdrop.querySelector(".app__about-version").textContent = t("Web.About.Version", self.DAZZLE_APP_VERSION ?? "");
    backdrop.querySelector(".app__about-suite a").textContent = t("Web.About.Suite");
    backdrop.querySelector("[data-source]").addEventListener("click", () => window.open(SOURCE_CODE_URL, "_blank", "noopener"));
    backdrop.querySelector("[data-cancel]").focus();
  }

  /**
   * Custom Shows: the presentation's named selections of slides. Shows are made,
   * renamed and removed on the left; on the right, a show's slides are picked and
   * put in order. Each change is made at once, and can be undone.
   */
  showCustomShows() {
    let selected = this.engine.info?.customShows?.[0]?.id ?? null;
    const backdrop = this.sheet(`
      <form class="ds-sheet app__custom-shows-sheet" role="dialog" aria-labelledby="cs-title">
        <div class="ds-sheet__body">
          <h2 class="ds-sheet__title" id="cs-title">${escapeHTML(t("CustomShow.Title"))}</h2>
          <div class="app__custom-shows"></div>
          <p class="ds-caption app__note">${escapeHTML(t("CustomShow.Footer"))}</p>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-play>${escapeHTML(t("CustomShow.Play"))}</button>
          <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("Web.Common.Done"))}</button>
        </div>
      </form>`);
    const body = backdrop.querySelector(".app__custom-shows");
    const slideLabel = (id) => {
      const slide = (this.engine.info?.outline ?? []).find((entry) => entry.id === id);
      return slide ? `${slide.number}. ${slide.title || t("Slide.Untitled")}` : "";
    };
    const render = () => {
      const shows = this.engine.info?.customShows ?? [];
      if (!shows.some((show) => show.id === selected)) selected = shows[0]?.id ?? null;
      const show = shows.find((entry) => entry.id === selected);
      const outline = this.engine.info?.outline ?? [];
      body.innerHTML = `
        <div class="app__custom-shows-list">
          <nav class="ds-source-list" aria-label="${escapeHTML(t("CustomShow.Title"))}">${shows.map((entry) => `
            <button class="ds-source-list__item" type="button" data-show="${entry.id}" aria-selected="${entry.id === selected}">${escapeHTML(entry.name)}<span class="ds-source-list__count">${entry.slides.length}</span></button>`).join("")}
          </nav>
          <span class="app__inspector-buttons">
            <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-op="new">${escapeHTML(t("CustomShow.New"))}</button>
            <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-op="duplicate"${show ? "" : " disabled"}>${escapeHTML(t("CustomShow.Duplicate"))}</button>
            <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-op="delete"${show ? "" : " disabled"}>${escapeHTML(t("CustomShow.Delete"))}</button>
          </span>
        </div>
        ${show ? `<div class="app__custom-show">
          <label class="ds-form app__custom-show-name"><span class="ds-form__label">${escapeHTML(t("CustomShow.Name"))}</span><span class="ds-form__control"><input class="ds-text-input ds-text-input--xs" name="name" value="${escapeHTML(show.name)}"></span></label>
          <div class="app__custom-show-columns">
            <div class="app__custom-show-table"><table class="ds-table"><thead><tr><th>${escapeHTML(t("CustomShow.AllSlides"))}</th></tr></thead><tbody>${outline.map((slide) => `
              <tr><td><label class="ds-check"><input type="checkbox" data-include="${slide.id}"${show.slides.includes(slide.id) ? " checked" : ""}>${escapeHTML(slideLabel(slide.id))}</label></td></tr>`).join("")}
            </tbody></table></div>
            <div class="app__custom-show-table"><table class="ds-table"><thead><tr><th colspan="2">${escapeHTML(t("CustomShow.InShow"))}</th></tr></thead><tbody>${show.slides.length ? show.slides.map((id, index) => `
              <tr><td>${escapeHTML(slideLabel(id))}</td><td class="app__custom-show-moves">
                <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" type="button" data-move="${index}:-1"${index ? "" : " disabled"} aria-label="${escapeHTML(t("CustomShow.MoveUp"))}" title="${escapeHTML(t("CustomShow.MoveUp"))}">${icon("chevronUp")}</button>
                <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" type="button" data-move="${index}:1"${index < show.slides.length - 1 ? "" : " disabled"} aria-label="${escapeHTML(t("CustomShow.MoveDown"))}" title="${escapeHTML(t("CustomShow.MoveDown"))}">${icon("chevronDown")}</button>
                <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" type="button" data-remove="${index}" aria-label="${escapeHTML(t("CustomShow.Remove"))}" title="${escapeHTML(t("CustomShow.Remove"))}">${icon("close")}</button>
              </td></tr>`).join("") : `<tr><td class="ds-caption">${escapeHTML(t("CustomShow.Empty"))}</td></tr>`}
            </tbody></table></div>
          </div>
        </div>` : ""}`;
      backdrop.querySelector("[data-play]").disabled = !show?.slides.length;
      const setSlides = (slides) => this.engine.call("setCustomShowSlides", { id: selected, slides }).then(render);
      for (const button of body.querySelectorAll("[data-show]")) {
        button.addEventListener("click", () => {
          selected = Number(button.dataset.show);
          render();
        });
      }
      body.querySelector('[data-op="new"]').addEventListener("click", async () => {
        const first = this.selection.slide ? [this.selection.slide] : [];
        selected = await this.engine.call("addCustomShow", { slides: first });
        render();
        body.querySelector('input[name="name"]')?.select();
      });
      body.querySelector('[data-op="duplicate"]').addEventListener("click", async () => {
        await this.engine.call("duplicateCustomShow", { id: selected });
        selected = (this.engine.info?.customShows ?? []).at(-1)?.id ?? selected;
        render();
      });
      body.querySelector('[data-op="delete"]').addEventListener("click", () => this.engine.call("deleteCustomShow", { id: selected }).then(render));
      body.querySelector('input[name="name"]')?.addEventListener("change", (event) => {
        this.engine.call("renameCustomShow", { id: selected, name: event.target.value }).then(render);
      });
      for (const box of body.querySelectorAll("[data-include]")) {
        box.addEventListener("change", () => {
          const id = box.dataset.include;
          setSlides(box.checked ? [...show.slides, id] : show.slides.filter((entry) => entry !== id));
        });
      }
      for (const button of body.querySelectorAll("[data-move]")) {
        button.addEventListener("click", () => {
          const [index, step] = button.dataset.move.split(":").map(Number);
          const slides = [...show.slides];
          const [moving] = slides.splice(index, 1);
          slides.splice(index + step, 0, moving);
          setSlides(slides);
        });
      }
      for (const button of body.querySelectorAll("[data-remove]")) {
        button.addEventListener("click", () => setSlides(show.slides.filter((_, index) => index !== Number(button.dataset.remove))));
      }
    };
    render();
    backdrop.querySelector("[data-play]").addEventListener("click", async () => {
      document.activeElement?.blur();
      await dismissSheet(backdrop);
      if (selected != null) this.play(null, { customShow: selected });
    });
    backdrop.querySelector("form").addEventListener("submit", (event) => {
      event.preventDefault();
      document.activeElement?.blur();
      dismissSheet(backdrop);
    });
  }

  /** The date, slide number and footer, on this slide or every slide. */
  async showHeaderFooter() {
    const data = await this.engine.call("inspect");
    const settings = data?.headerFooter ?? {};
    const formats = this.engine.info?.choices?.dateFormats ?? [];
    const backdrop = this.sheet(`
      <form class="ds-sheet" role="dialog" aria-labelledby="hf-title">
        <div class="ds-sheet__body">
          <h2 class="ds-sheet__title" id="hf-title">${escapeHTML(t("Panel.HeaderFooter.Title"))}</h2>
          <div class="ds-form app__header-footer">
            <span class="ds-form__label"></span><span class="ds-form__control"><label class="ds-check"><input type="checkbox" name="date"${settings.date ? " checked" : ""}>${escapeHTML(t("HeaderFooter.Date"))}</label></span>
            <span class="ds-form__label"></span><span class="ds-form__control"><label class="ds-radio"><input type="radio" name="updates" value="1"${settings.updates !== false ? " checked" : ""}>${escapeHTML(t("HeaderFooter.Automatic"))}</label>
              <span class="ds-popup ds-popup--xs"><select class="ds-popup__select" name="dateFormat" aria-label="${escapeHTML(t("HeaderFooter.Format"))}">${formats.map((format) => `<option value="${format.id}"${format.id === settings.dateFormat ? " selected" : ""}>${escapeHTML(format.label)}</option>`).join("")}</select>${icon("chevronDown", "ds-popup__chevron")}</span></span>
            <span class="ds-form__label"></span><span class="ds-form__control"><label class="ds-radio"><input type="radio" name="updates" value="0"${settings.updates === false ? " checked" : ""}>${escapeHTML(t("HeaderFooter.Fixed"))}</label>
              <input class="ds-text-input ds-text-input--xs" name="fixedDate" value="${escapeHTML(settings.fixedDate ?? "")}" aria-label="${escapeHTML(t("HeaderFooter.FixedDate"))}"></span>
            <span class="ds-form__label"></span><span class="ds-form__control"><label class="ds-check"><input type="checkbox" name="number"${settings.number ? " checked" : ""}>${escapeHTML(t("HeaderFooter.SlideNumber"))}</label></span>
            <span class="ds-form__label"></span><span class="ds-form__control"><label class="ds-check"><input type="checkbox" name="footer"${settings.footer ? " checked" : ""}>${escapeHTML(t("HeaderFooter.Footer"))}</label></span>
            <span class="ds-form__label"></span><span class="ds-form__control"><input class="ds-text-input ds-text-input--xs" name="footerText" value="${escapeHTML(settings.footerText ?? "")}" aria-label="${escapeHTML(t("HeaderFooter.FooterText"))}" placeholder="${escapeHTML(t("HeaderFooter.FooterText"))}"></span>
            <span class="ds-form__label"></span><span class="ds-form__control"><label class="ds-check"><input type="checkbox" name="hideOnTitle">${escapeHTML(t("HeaderFooter.HideOnTitle"))}</label></span>
          </div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
          <button class="ds-button" type="submit" value="one">${escapeHTML(t("HeaderFooter.Apply"))}</button>
          <button class="ds-button ds-button--primary" type="submit" value="all">${escapeHTML(t("HeaderFooter.ApplyToAll"))}</button>
        </div>
      </form>`);
    const form = backdrop.querySelector("form");
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const values = new FormData(form);
      dismissSheet(backdrop);
      await this.engine.call("headerFooter", {
        date: values.get("date") === "on", updates: values.get("updates") !== "0", dateFormat: values.get("dateFormat"),
        fixedDate: values.get("fixedDate") ?? "", number: values.get("number") === "on", footer: values.get("footer") === "on",
        footerText: values.get("footerText") ?? "", hideOnTitle: values.get("hideOnTitle") === "on", toAll: event.submitter?.value === "all",
      });
    });
  }

  /** The presentation's title, author and the rest, and when it was created and last saved. */
  async showProperties() {
    const properties = await this.engine.call("properties");
    if (!properties) return;
    const fields = [
      ["title", "Properties.Title"], ["subject", "Properties.Subject"], ["author", "Properties.Author"], ["company", "Properties.Company"],
      ["keywords", "Properties.Keywords"], ["category", "Properties.Category"],
    ];
    const row = (label, control) => `<span class="ds-form__label">${escapeHTML(label)}</span><span class="ds-form__control">${control}</span>`;
    const when = (value) => value ? new Date(value).toLocaleString(language, { dateStyle: "medium", timeStyle: "short" }) : "—";
    const history = [
      ["Properties.Created", when(properties.created)], ["Properties.Modified", when(properties.modified)],
      ["Properties.LastModifiedBy", properties.lastModifiedBy || "—"],
      ...(properties.revision != null ? [["Properties.Revision", String(properties.revision)]] : []),
      ...(properties.application ? [["Properties.Application", properties.application]] : []),
    ];
    const backdrop = this.sheet(`
      <form class="ds-sheet" role="dialog" aria-labelledby="properties-title">
        <div class="ds-sheet__body">
          <h2 class="ds-sheet__title" id="properties-title">${escapeHTML(t("Panel.Properties.Title"))}</h2>
          <div class="ds-form app__properties">
            ${fields.map(([key, label]) => row(t(label), `<input class="ds-text-input ds-text-input--xs" name="${key}" value="${escapeHTML(properties[key] ?? "")}" aria-label="${escapeHTML(t(label))}">`)).join("")}
            ${row(t("Properties.Comments"), `<textarea class="ds-text-input" name="comments" rows="3" aria-label="${escapeHTML(t("Properties.Comments"))}">${escapeHTML(properties.comments ?? "")}</textarea>`)}
            ${history.map(([label, value]) => row(t(label), `<span>${escapeHTML(value)}</span>`)).join("")}
          </div>
          ${properties.keynote ? `<p class="ds-caption">${escapeHTML(t("Properties.Keynote.Footer"))}</p>` : ""}
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
          <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("Common.OK"))}</button>
        </div>
      </form>`);
    const form = backdrop.querySelector("form");
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const values = Object.fromEntries([...fields.map(([key]) => key), "comments"].map((key) => [key, String(new FormData(form).get(key) ?? "")]));
      dismissSheet(backdrop);
      await this.engine.call("setProperties", values);
    });
  }

  /** How everything on the slides should change size with them. Resolves with "maximize", "ensureFit" or null. */
  askScaling() {
    return new Promise((resolve) => {
      const backdrop = this.sheet(`
        <div class="ds-sheet ds-alert" role="alertdialog" aria-labelledby="scale-title" aria-describedby="scale-message">
          <div class="ds-sheet__body"><div>
            <h2 class="ds-sheet__title" id="scale-title">${escapeHTML(t("SlideSize.Scaling.Title"))}</h2>
            <p class="ds-sheet__message" id="scale-message">${escapeHTML(t("SlideSize.Scaling.Message"))}</p>
          </div></div>
          <div class="ds-sheet__buttons">
            <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Common.Cancel"))}</button>
            <button class="ds-button" type="button" data-scaling="maximize">${escapeHTML(t("SlideSize.Scaling.Maximize"))}</button>
            <button class="ds-button ds-button--primary" type="button" data-scaling="ensureFit">${escapeHTML(t("SlideSize.Scaling.EnsureFit"))}</button>
          </div>
        </div>`);
      backdrop.querySelector("[data-cancel]").addEventListener("click", () => resolve(null));
      for (const button of backdrop.querySelectorAll("[data-scaling]")) {
        button.addEventListener("click", () => {
          dismissSheet(backdrop);
          resolve(button.dataset.scaling);
        });
      }
    });
  }

  /** Shows the menu bar's Update button. */
  offerUpdate(download) {
    this.updateButton.hidden = false;
    this.menuBarOverflow.layout();
    this.updateButton.onclick = () => this.showUpdate(download);
  }

  showUpdate(download) {
    const backdrop = this.sheet(`
      <div class="ds-sheet" role="dialog" aria-labelledby="update-title" aria-describedby="update-message">
        <div class="ds-sheet__body app__update-body">
          <h2 class="ds-sheet__title" id="update-title">${escapeHTML(t("Web.Update.Title"))}</h2>
          <p class="ds-sheet__message" id="update-message"></p>
          <div class="ds-progress" role="progressbar" aria-labelledby="update-title" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><div class="ds-progress__bar"></div></div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
          <button class="ds-button ds-button--primary" type="button" data-retry hidden>${escapeHTML(t("Web.Update.TryAgain"))}</button>
        </div>
      </div>`);
    const message = backdrop.querySelector("#update-message");
    const progress = backdrop.querySelector(".ds-progress");
    const retry = backdrop.querySelector("[data-retry]");
    const setProgress = (fraction) => {
      const percent = Math.round(Math.min(Math.max(fraction, 0), 1) * 100);
      progress.style.setProperty("--ds-progress", `${percent}%`);
      progress.setAttribute("aria-valuenow", String(percent));
    };
    let open = true;
    backdrop.querySelector("[data-cancel]").addEventListener("click", () => {
      // The download carries on in the service worker; the next attempt picks up from there.
      open = false;
    });
    const attempt = async () => {
      message.textContent = t("Web.Update.Downloading");
      retry.hidden = true;
      progress.hidden = false;
      setProgress(0);
      try {
        await download((fraction) => open && setProgress(fraction));
      } catch {
        if (!open) return;
        message.textContent = t("Web.Update.Failed");
        progress.hidden = true;
        retry.hidden = false;
        retry.focus();
        return;
      }
      if (!open) return;
      await this.flushAutosave();
      location.reload();
    };
    retry.addEventListener("click", attempt);
    attempt();
  }

  /** A window-modal sheet asking for one line of text. Resolves with it, or null on Cancel. */
  askText(title, value, confirmLabel) {
    return new Promise((resolve) => {
      const backdrop = this.sheet(`
        <form class="ds-sheet" role="dialog" aria-labelledby="ask-title">
          <div class="ds-sheet__body">
            <h2 class="ds-sheet__title" id="ask-title"></h2>
            <input class="ds-text-input" spellcheck="false" aria-labelledby="ask-title">
          </div>
          <div class="ds-sheet__buttons">
            <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
            <button class="ds-button ds-button--primary" type="submit"></button>
          </div>
        </form>`);
      backdrop.querySelector("#ask-title").textContent = title;
      backdrop.querySelector('[type="submit"]').textContent = confirmLabel;
      const input = backdrop.querySelector("input");
      input.value = value;
      backdrop.querySelector("[data-cancel]").addEventListener("click", () => resolve(null));
      backdrop.querySelector("form").addEventListener("submit", (event) => {
        event.preventDefault();
        dismissSheet(backdrop);
        resolve(input.value.trim() || null);
      });
      input.focus();
      const dot = value.lastIndexOf(".");
      input.setSelectionRange(0, dot > 0 ? dot : value.length);
    });
  }

  /** Asks how many rows and columns a new table has. */
  applyAppearance(value) {
    if (value) document.documentElement.dataset.theme = value;
    else delete document.documentElement.dataset.theme;
    writeSetting("appearance", value);
  }

  // MARK: - Keyboard

  bindKeyboard() {
    window.addEventListener("keydown", (event) => {
      if (this.slideshow.active) return;
      const mod = isApple ? event.metaKey : event.ctrlKey;
      if (!mod) return;
      const key = event.key.toLowerCase();
      const inField = event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement || event.target instanceof HTMLTextAreaElement;
      const map = {
        n: event.shiftKey ? "newSlide" : "new", o: "open", s: event.shiftKey ? "saveAs" : "save", w: "close", p: "print",
        z: event.shiftKey ? "redo" : "undo", y: "redo", b: event.shiftKey ? "back" : "bold", i: event.altKey ? "toggleInspector" : event.shiftKey ? "insertPicture" : "italic",
        u: "underline", f: event.altKey ? "findReplace" : event.shiftKey ? "front" : "find", g: event.altKey ? (event.shiftKey ? "ungroup" : "group") : event.shiftKey ? "findPrevious" : "findNext",
        "=": "zoomIn", "+": event.shiftKey ? "bigger" : "zoomIn", "-": event.altKey ? "zoomOut" : "smaller", "0": "actualSize", "9": "zoomToFit",
        "]": "indent", "[": "outdent", d: "duplicate", a: event.shiftKey ? "deselectAll" : "selectAll",
        c: "copy", x: "cut", v: "paste", enter: event.altKey ? (event.shiftKey ? "playFromStart" : "play") : null,
      };
      const command = map[key];
      if (!command) return;
      // Fields keep their own undo, clipboard, select all and text styling.
      if (inField && ["undo", "redo", "bold", "italic", "underline", "copy", "cut", "paste", "selectAll"].includes(command)) return;
      // Typing on the slide keeps the browser's own clipboard and undo while it lasts.
      if (this.canvas.editing && ["copy", "cut", "paste", "undo", "redo"].includes(command)) return;
      if (["copy", "cut", "paste"].includes(command) && !this.hasDocument) return;
      event.preventDefault();
      this.run(command);
    });
  }

  // MARK: - Documents

  async refreshRecents() {
    this.recents = await storage.recentDocuments();
    if (!this.document) this.renderStart();
  }

  showStart() {
    this.document = null;
    this.look = {};
    this.root.classList.add("is-empty");
    this.toolbarOverflow.layout();
    this.start.hidden = false;
    this.findForm.hidden = true;
    this.canvas.dispose();
    this.navigator.clear();
    this.updateTitle();
    this.updateStatus();
    this.root.querySelector(".app__inspector").replaceChildren();
    this.refreshRecents();
  }

  renderStart() {
    const recents = this.recents ?? [];
    const relative = new Intl.RelativeTimeFormat(language, { numeric: "auto" });
    const when = (time) => {
      const minutes = Math.round((time - Date.now()) / 60000);
      if (Math.abs(minutes) < 60) return relative.format(minutes, "minute");
      const hours = Math.round(minutes / 60);
      if (Math.abs(hours) < 24) return relative.format(hours, "hour");
      return new Intl.DateTimeFormat(language, { dateStyle: "medium" }).format(time);
    };
    this.start.innerHTML = `
      <div class="app__start-inner">
        <h1 class="ds-heading-04">Dazzle</h1>
        <p class="ds-body app__start-intro"></p>
        <div class="app__start-actions">
          <button class="ds-button ds-button--primary" data-start="new">${escapeHTML(t("Launch.NewPresentation"))}</button>
          <button class="ds-button ds-button--bordered" data-start="open">${escapeHTML(t("Menu.File.Open"))}</button>
        </div>
        <h2 class="ds-heading-compact app__start-heading">${escapeHTML(t("Menu.File.OpenRecent"))}</h2>
        ${recents.length ? `<table class="ds-table app__recents"><tbody>
          ${recents.map((record) => {
            const name = record.draftAt && !record.handle ? record.draftName ?? record.name : record.name;
            return `<tr data-id="${record.id}" tabindex="0">
            <td>${icon("presentation")} <span>${escapeHTML(name)}</span></td>
            <td class="app__recent-note">${record.draftAt ? escapeHTML(t("Web.Start.Unsaved")) : ""}</td>
            <td class="ds-numeric app__recent-date">${escapeHTML(when(Math.max(record.openedAt, record.draftAt ?? 0)))}</td>
            <td class="app__recent-remove"><button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" data-remove="${record.id}" aria-label="${escapeHTML(t("Web.Start.Remove"))}" title="${escapeHTML(t("Web.Start.Remove"))}">${icon("close")}</button></td>
          </tr>`;
          }).join("")}</tbody></table>`
        : `<p class="ds-caption">${escapeHTML(t("Web.Start.NoRecent"))}</p>`}
      </div>`;
    this.start.querySelector(".app__start-intro").textContent = t("Web.Start.Intro");
    this.start.querySelector('[data-start="new"]').addEventListener("click", () => this.newDocument());
    this.start.querySelector('[data-start="open"]').addEventListener("click", () => this.openPicked());
    for (const row of this.start.querySelectorAll("tr[data-id]")) {
      const record = recents.find((entry) => entry.id === row.dataset.id);
      row.addEventListener("click", (event) => {
        if (event.target.closest("[data-remove]")) return;
        this.openRecord(record);
      });
      row.addEventListener("keydown", (event) => event.key === "Enter" && this.openRecord(record));
    }
    for (const button of this.start.querySelectorAll("[data-remove]")) {
      button.addEventListener("click", async () => {
        await storage.removeRecord(button.dataset.remove);
        this.refreshRecents();
      });
    }
  }

  showDocument(record) {
    this.document = record;
    this.keptVersion = this.engine.state?.version;
    this.root.classList.remove("is-empty");
    this.toolbarOverflow.layout();
    this.start.hidden = true;
    this.banners.replaceChildren();
    this.findForm.hidden = true;
    this.notesSlide = null;
    this.updateTitle();
    this.updateStatus();
    this.updateNotes();
    storage.saveRecord({ ...record, openedAt: Date.now() });
    storage.persist();
    requestAnimationFrame(() => {
      this.canvas.element.focus();
      this.navigator.reveal();
    });
  }

  async flushAutosave() {
    if (this.autosaveTimer) {
      clearTimeout(this.autosaveTimer);
      this.autosaveTimer = null;
      await this.autosave();
    }
  }

  /** Everything typed so far, with the engine. */
  async flushEdits() {
    if (!this.document) return;
    await this.canvas.endEditing();
    await this.flushNotes();
  }

  async newDocument() {
    await this.flushEdits();
    await this.flushAutosave();
    const name = t("Web.Document.Untitled");
    this.document = null;
    await this.engine.call("new", { name });
    this.showDocument({ id: crypto.randomUUID(), name, openedAt: Date.now() });
  }

  async openPicked() {
    try {
      const file = await files.pickFile();
      if (file) await this.openFile(file);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  /** @param {{ name: string, bytes: Uint8Array, handle?: FileSystemFileHandle }} file */
  async openFile(file, { draftOf = null } = {}) {
    await this.flushEdits();
    await this.flushAutosave();
    try {
      this.document = null;
      await this.engine.call("open", { name: file.name }, file.bytes);
    } catch (error) {
      this.showMessage(t("Web.Error.Open", file.name, error.message), "error");
      if (!this.document) this.showStart();
      return;
    }
    const recents = await storage.recentDocuments();
    const existing = file.handle
      ? await (async () => {
        for (const record of recents) if (record.handle && (await record.handle.isSameEntry?.(file.handle))) return record;
        return null;
      })()
      : null;
    const record = draftOf ?? existing ?? { id: crypto.randomUUID() };
    this.showDocument({ ...record, name: file.name, handle: file.handle ?? record.handle, openedAt: Date.now() });
    this.showNotices();
    // A slide show file opens straight into playing, as PowerPoint opens one.
    if (/\.ppsx$/i.test(file.name)) this.showMessage(t("Web.Play.SlideShowFile"), "info", { action: { label: t("Toolbar.Play"), run: () => this.run("playFromStart") } });
  }

  async openRecord(record) {
    if (record.draftAt) {
      const bytes = await storage.readDraft(record.id);
      if (bytes) {
        await this.openFile({ name: record.draftName ?? record.name, bytes, handle: record.handle }, { draftOf: record });
        // The draft has unsaved changes: show it as edited.
        this.engine.state.edited = true;
        this.updateTitle();
        return;
      }
    }
    if (!record.handle) {
      this.showMessage(t("Web.Error.Missing", record.name), "error");
      return;
    }
    try {
      const file = await files.readHandle(record.handle);
      if (file) await this.openFile(file, { draftOf: record });
    } catch (error) {
      this.showMessage(t("Web.Error.Open", record.name, error.message), "error");
    }
  }

  async closeDocument() {
    await this.flushEdits();
    await this.flushAutosave();
    this.showStart();
  }

  /** Changes neither saved nor autosaved yet. */
  get hasUnkeptChanges() {
    const state = this.engine.state;
    return Boolean(this.document && (state?.edited && state.version !== this.keptVersion));
  }

  scheduleAutosave() {
    if (!this.document) return;
    clearTimeout(this.autosaveTimer);
    this.autosaveTimer = setTimeout(() => {
      this.autosaveTimer = null;
      this.autosave();
    }, AUTOSAVE_DELAY);
  }

  /** Keeps a copy of the open presentation on this device, so closing the window loses nothing. */
  async autosave() {
    const record = this.document;
    if (!this.hasUnkeptChanges) return;
    const version = this.engine.state.version;
    try {
      const { result, payload } = await this.engine.call("save", { keep: true, draft: true });
      if (await storage.writeDraft(record.id, payload)) {
        record.draftAt = Date.now();
        record.draftName = result.fileName;
        this.keptVersion = version;
        await storage.saveRecord(record);
      }
    } catch {
      // A failed autosave leaves the last one in place; saving will report errors.
    }
  }

  defaultFormat() {
    return this.engine.info?.saveFormats?.[0] ?? { key: "pptx", extension: "pptx", mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation" };
  }

  formatLabel(key) {
    return t({ pptx: "Web.FileType.PowerPoint", pptm: "Web.FileType.PowerPointMacros", ppsx: "Web.FileType.SlideShow", key: "Web.Export.Keynote" }[key] ?? "Web.FileType.PowerPoint");
  }

  async save() {
    const record = this.document;
    if (!record) return;
    await this.flushEdits();
    const format = this.defaultFormat();
    const sameKind = record.handle && record.handle.name === format.fileName;
    if (!sameKind) return this.saveAs();
    try {
      const { payload } = await this.engine.call("save", { format: format.key, author: readSetting("author", "") });
      if (!(await files.writeHandle(record.handle, payload))) return;
      await this.saved(record);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  async saveAs(format = this.defaultFormat()) {
    const record = this.document;
    if (!record) return;
    await this.flushEdits();
    try {
      const { result, payload } = await this.engine.call("save", { format: format.key, author: readSetting("author", ""), keep: true });
      const saved = await files.saveFileAs(payload, result.fileName, { ...format, description: this.formatLabel(format.key) });
      if (!saved) return;
      await this.engine.call("rename", { name: saved.name });
      await this.engine.call("save", { format: format.key, author: readSetting("author", ""), keep: false }).catch(() => {});
      record.name = saved.name;
      if (saved.handle) record.handle = saved.handle;
      await this.saved(record);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  /** Saves a copy in another format, leaving the open presentation as it is. */
  async exportAs(format) {
    if (!this.document) return;
    await this.flushEdits();
    try {
      const { result, payload } = await this.engine.call("save", { format: format.key, author: readSetting("author", ""), keep: true });
      await files.saveFileAs(payload, result.fileName, { ...format, description: this.formatLabel(format.key) });
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  async saved(record) {
    clearTimeout(this.autosaveTimer);
    this.autosaveTimer = null;
    await storage.removeDraft(record.id);
    delete record.draftAt;
    delete record.draftName;
    await storage.saveRecord({ ...record, openedAt: Date.now() });
    if (this.engine.state) this.engine.state.edited = false;
    this.keptVersion = this.engine.state?.version;
    this.updateTitle();
    this.showMessage(t("Web.Document.SavedAs", record.name), "success");
  }

  async renameDocument() {
    const record = this.document;
    if (!record) return;
    const name = await this.askText(t("Web.Document.RenamePrompt"), record.name, t("Menu.File.Rename").replace("…", ""));
    if (!name || name === record.name) return;
    await this.engine.call("rename", { name });
    record.name = name;
    if (record.handle?.move) {
      try {
        await record.handle.move(name);
      } catch {
        // The file keeps its name on disk; the next save asks where.
        delete record.handle;
      }
    }
    await storage.saveRecord(record);
    this.updateTitle();
  }
}
