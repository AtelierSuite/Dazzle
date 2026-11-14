// Playing the presentation.
//
// With a second display, the slideshow plays as Keynote and PowerPoint play
// it: the audience sees the slide in a window of its own on the other display,
// filling it, and this window becomes the presenter view, with the current and
// next slides, the notes and the time. The two are linked: this window runs
// the show and tells the audience window what to draw (audience.html), and the
// audience window hands back the keys and clicks it receives, so a clicker
// aimed at either works. Closing either ends the show.
//
// The audience window is placed on the other display with the Window
// Management API (Chrome and Edge, once allowed), and opened with the
// `fullscreen` window feature where the browser has it. Where it doesn't, the
// window covers the other display, and the presenter view's Fill Screen button
// hands it the right to go full screen (capability delegation); failing that,
// a click on the audience window does it. With one display, or no popups, the
// slideshow plays full screen in this window instead.
//
// The show steps through slides and their animations as PresentationSession
// does on Apple platforms, asking the engine for each moment of an animation,
// and moves onto each slide with its transition (transition.js).

import { SlideDrawer, applyFrame } from "./slide.js";
import { TransitionPlayer, prefersReducedMotion } from "./transition.js";

const AUDIENCE_NAME = "dazzle-audience";

/** Where the other display is, if the browser can say and the user lets it. */
async function otherScreen({ ask }) {
  if (!("getScreenDetails" in window)) return null;
  try {
    const status = await navigator.permissions?.query({ name: "window-management" }).catch(() => null);
    if (status?.state === "denied") return null;
    if (status?.state !== "granted" && !ask) return null;
    const details = await window.getScreenDetails();
    const current = details.currentScreen;
    return details.screens.find((screen) => screen !== current && !screen.isInternal)
      ?? details.screens.find((screen) => screen !== current) ?? null;
  } catch {
    return null;
  }
}

/** Whether this device seems to have more than one display. */
export function hasSecondDisplay() {
  return Boolean(window.screen?.isExtended);
}


/**
 * Shows a link's ScreenTip when the pointer rests on it, after a delay like a
 * macOS help tag, in the slideshow's own windows.
 * @param {HTMLElement} area
 */
export function showLinkTips(area) {
  let tip = null;
  let timer = null;
  const hide = () => {
    clearTimeout(timer);
    tip?.remove();
    tip = null;
  };
  area.addEventListener("pointermove", (event) => {
    const element = event.target.closest?.("[data-link]");
    const text = element ? JSON.parse(element.dataset.link).tooltip : null;
    if (tip && tip.textContent === text) return;
    hide();
    if (!text) return;
    const { clientX: x, clientY: y } = event;
    timer = setTimeout(() => {
      tip = document.createElement("span");
      tip.className = "ds-tooltip slideshow__link-tip";
      tip.setAttribute("role", "tooltip");
      tip.textContent = text;
      // Inside the show's own view, so it goes when the show ends.
      (area.closest(".slideshow, .presenter") ?? document.body).append(tip);
      const width = tip.offsetWidth;
      tip.style.left = `${Math.max(0, Math.min(x, window.innerWidth - width))}px`;
      tip.style.top = `${y + 20}px`;
    }, 600);
  });
  area.addEventListener("pointerleave", hide);
  area.addEventListener("pointerdown", hide);
}

export class Slideshow extends EventTarget {
  /**
   * @param {HTMLElement} root the window, which the presenter view or the slide covers
   * @param {import("./engine-client.js").EngineClient} engine
   * @param {import("./slide.js").MediaStore} media
   * @param {{ t: Function, language: string }} strings
   */
  constructor(root, engine, media, { t, language }) {
    super();
    this.root = root;
    this.engine = engine;
    this.media = media;
    this.t = t;
    this.language = language;
    this.drawer = new SlideDrawer(media);
    this.active = false;
    this.onMessage = (event) => this.received(event);
    this.onKey = (event) => this.key(event);
  }

  // MARK: - Starting and stopping

  /**
   * Starts the show at `slideID`, or the first slide that shows. `presenter`
   * asks for the audience window and presenter view; without it, or when the
   * window can't open, the show plays full screen here.
   */
  async start(slideID, { presenter = hasSecondDisplay(), customShow = null } = {}) {
    if (this.active) return;
    const state = this.engine.state;
    const slides = state.slides;
    // Hidden slides are left out, unless every slide is; a custom show plays its own.
    this.order = await this.engine.call("slideshowOrder", customShow != null ? { customShow } : {});
    if (!this.order.length) this.order = slides.map((slide) => slide.id);
    const startIndex = slides.findIndex((slide) => slide.id === slideID);
    this.position = customShow != null ? 0 : Math.max(this.order.findIndex((id) => slides.findIndex((slide) => slide.id === id) >= startIndex), 0);
    // Where to come back to as each custom show a link started ends, the latest last.
    this.returnPoints = [];
    // How the presentation asks to be played: a kiosk show moves on only by its timings and links.
    this.settings = { ...(this.engine.info?.show ?? {}) };
    this.startingOrder = [...this.order];
    this.active = true;
    this.blanked = false;
    this.startedAt = Date.now();
    this.timelines = new Map();

    let audience = null;
    if (presenter) {
      // Opened before anything is awaited, while the click that started the show still counts.
      const placement = await this.placement();
      audience = this.openAudience(placement);
    }
    if (audience) {
      this.audience = audience;
      this.mode = "presenter";
      this.buildPresenter();
    } else {
      this.mode = "single";
      this.buildSingle();
    }
    window.addEventListener("message", this.onMessage);
    window.addEventListener("keydown", this.onKey, true);
    this.unloading = () => this.audience?.close();
    window.addEventListener("pagehide", this.unloading);
    this.watchAudience();
    await this.showSlide({ fullyBuilt: false });
    this.noteActivity();
    this.dispatchEvent(new CustomEvent("start"));
  }

  /** The other display's bounds, if the permission to see displays is already given. */
  async placement() {
    // Only asks when already allowed: a prompt would outlast the click, and the window couldn't open.
    const screen = await otherScreen({ ask: false });
    if (!screen) return null;
    return { left: screen.availLeft ?? screen.left, top: screen.availTop ?? screen.top, width: screen.availWidth ?? screen.width, height: screen.availHeight ?? screen.height };
  }

  openAudience(placement) {
    const url = new URL("audience.html", document.baseURI);
    url.searchParams.set("lang", this.language);
    const features = ["popup"];
    if (placement) {
      features.push(`left=${placement.left}`, `top=${placement.top}`, `width=${placement.width}`, `height=${placement.height}`, "fullscreen");
    } else {
      const width = Math.round(screen.availWidth * 0.6);
      features.push(`width=${width}`, `height=${Math.round((width * 9) / 16)}`);
    }
    let opened = null;
    try {
      opened = window.open(url, AUDIENCE_NAME, features.join(","));
    } catch {
      opened = null;
    }
    this.placed = Boolean(placement);
    return opened;
  }

  /** Ends the show, closing the audience window and going back to editing. */
  end() {
    clearTimeout(this.restartTimer);
    if (!this.active) return;
    this.active = false;
    this.transitions?.finish();
    cancelAnimationFrame(this.animationFrame);
    clearTimeout(this.advanceTimer);
    clearInterval(this.clockTimer);
    clearInterval(this.audienceTimer);
    window.removeEventListener("message", this.onMessage);
    window.removeEventListener("keydown", this.onKey, true);
    window.removeEventListener("pagehide", this.unloading);
    try {
      this.post({ type: "end" });
      this.audience?.close();
    } catch {
      // Already gone.
    }
    this.audience = null;
    this.stopMedia();
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    this.view?.remove();
    this.view = null;
    const last = this.order[this.position];
    this.dispatchEvent(new CustomEvent("end", { detail: last }));
  }

  /** Notices the audience window closing, which ends the show. */
  watchAudience() {
    clearInterval(this.audienceTimer);
    if (!this.audience) return;
    this.audienceTimer = setInterval(() => {
      if (this.audience?.closed) this.end();
    }, 500);
  }

  // MARK: - Moving

  get slideID() {
    return this.order[this.position];
  }

  async timeline(id = this.slideID) {
    if (!this.timelines.has(id)) this.timelines.set(id, await this.engine.call("timeline", { slide: id }));
    return this.timelines.get(id);
  }

  /** Someone touched the show: a kiosk show waits that much longer before starting over. */
  noteActivity() {
    clearTimeout(this.restartTimer);
    if (!this.active || !this.settings.kiosk) return;
    this.restartTimer = setTimeout(async () => {
      if (!this.active) return;
      this.returnPoints = [];
      this.order = [...this.startingOrder];
      this.setBlank(false, { quiet: true });
      const moving = this.position !== 0;
      this.position = 0;
      await this.showSlide({ fullyBuilt: false, transition: moving });
      this.noteActivity();
    }, Math.max(this.settings.restart ?? 300, 1) * 1000);
  }

  /** Whether taps and keys move the show on: not at a kiosk. */
  get isManual() {
    this.noteActivity();
    return !this.settings.kiosk;
  }

  /** Plays the slide's next animation step, or with none left, moves on. */
  async next() {
    if (!this.active) return;
    // A click while the slide arrives finishes its arrival.
    if (this.transitions?.isPlaying) return this.finishTransition();
    if (this.blanked) return this.setBlank(false);
    const timeline = await this.timeline();
    if (this.builds < timeline.steps) {
      this.builds += 1;
      this.buildStartedAt = performance.now();
      this.playStepMedia(timeline, this.builds - 1);
      this.animate();
      this.updatePresenter();
      return;
    }
    let fullyBuilt = false;
    if (this.position < this.order.length - 1) {
      this.position += 1;
    } else if (this.returnPoints.length) {
      // A custom show played from a link comes back to the link's slide, as it was left.
      ({ order: this.order, position: this.position } = this.returnPoints.pop());
      fullyBuilt = true;
    } else if (timeline.loop) {
      this.position = 0;
    } else {
      // Moving on from the last slide ends the show, as in Keynote.
      return this.end();
    }
    await this.showSlide({ fullyBuilt, transition: true });
  }

  /** Takes back the last animation step, or with none played, goes back a slide. */
  async previous() {
    if (!this.active) return;
    // Going back is straight back, without a transition.
    if (this.transitions?.isPlaying) this.finishTransition();
    this.setBlank(false, { quiet: true });
    const timeline = await this.timeline();
    if (this.settings.animations !== false && this.builds > timeline.initial) {
      // Back to how the slide looked before the step, without playing it backwards.
      this.builds -= 1;
      this.buildStartedAt = -Infinity;
      await this.drawFrame();
      this.updatePresenter();
      return;
    }
    if (this.position === 0) return;
    this.position -= 1;
    // Going back finds a slide as it was left: every animation played.
    await this.showSlide({ fullyBuilt: true });
  }

  async go(index) {
    if (!this.active || index < 0 || index >= this.order.length) return;
    const moving = index !== this.position;
    this.position = index;
    this.setBlank(false, { quiet: true });
    await this.showSlide({ fullyBuilt: false, transition: moving });
  }

  async goToSlide(id) {
    let index = this.order.indexOf(id);
    if (index < 0) {
      // A hidden slide shows when a link leads to it.
      this.order.splice(this.position + 1, 0, id);
      index = this.position + 1;
    }
    await this.go(index);
  }

  /** Plays a custom show from its start, coming back afterwards when `returns`. */
  async playCustomShow(id, returns) {
    const order = await this.engine.call("slideshowOrder", { customShow: id });
    const show = (this.engine.info?.customShows ?? []).find((entry) => entry.id === id);
    if (!this.active || !show?.slides.length || !order.length) return;
    if (returns) this.returnPoints.push({ order: this.order, position: this.position });
    this.order = order;
    this.position = 0;
    this.setBlank(false, { quiet: true });
    await this.showSlide({ fullyBuilt: false, transition: true });
  }

  setBlank(on, { quiet = false } = {}) {
    this.blanked = on;
    this.post({ type: "blank", on });
    this.view?.classList.toggle("is-blanked", on);
    if (!quiet) this.updatePresenter();
  }

  /**
   * Draws the slide now showing, its first animations beginning once its
   * transition, if it plays one, has brought it on.
   */
  async showSlide({ fullyBuilt, transition: withTransition = false }) {
    const id = this.slideID;
    const timeline = await this.timeline(id);
    // Without animations, every slide shows as it ends up.
    const built = fullyBuilt || this.settings.animations === false;
    this.builds = built ? timeline.steps : timeline.initial;
    this.buildStartedAt = built ? -Infinity : performance.now();
    this.stopMedia();
    const scene = await this.engine.call("scene", { slide: id });
    if (id !== this.slideID) return;
    const transition = withTransition && this.scene && timeline.transition > 0
      ? await this.engine.call("transition", { slide: id, reduceMotion: prefersReducedMotion(), seed: this.position })
      : null;
    if (id !== this.slideID) return;
    this.scene = scene;
    const frame = await this.frame(0);
    if (id !== this.slideID) return;
    // To the audience: the slide, the pictures and movies on it, and how it starts.
    const media = {};
    for (const path of sceneMedia(scene)) media[path] = await this.media.blob(path);
    if (id !== this.slideID) return;
    const arriving = transition ? transition.duration * 1000 : 0;
    this.transitionEndsAt = performance.now() + arriving;
    if (!fullyBuilt) this.buildStartedAt = performance.now() + arriving;
    this.post({ type: "show", scene, frame, media, transition, number: this.position + 1, count: this.order.length });
    this.drawLocal(scene, frame, transition);
    await this.drawNext();
    this.updatePresenter();
    if (!fullyBuilt) {
      this.playOpeningMedia(timeline, scene);
      this.animate();
    }
    this.scheduleAdvance(timeline);
  }

  /** The engine's AnimationFrame `elapsed` seconds into the latest step. */
  frame(elapsed) {
    return this.engine.call("frame", { slide: this.slideID, begun: this.builds, elapsed });
  }

  /** Runs the step now playing, a frame at a time, until it settles. */
  animate() {
    cancelAnimationFrame(this.animationFrame);
    const slide = this.slideID;
    const tick = async () => {
      if (!this.active || slide !== this.slideID) return;
      const timeline = await this.timeline();
      const elapsed = (performance.now() - this.buildStartedAt) / 1000;
      const duration = this.builds > 0 ? timeline.durations[this.builds - 1] : 0;
      await this.drawFrame(elapsed);
      // Steps that repeat until the next tap (duration -1) keep going.
      if (duration < 0 || elapsed <= duration + 0.05) this.animationFrame = requestAnimationFrame(tick);
      else this.scheduleAdvance(timeline);
    };
    this.animationFrame = requestAnimationFrame(tick);
  }

  async drawFrame(elapsed = (performance.now() - this.buildStartedAt) / 1000) {
    const slide = this.slideID;
    const frame = await this.frame(Number.isFinite(elapsed) ? elapsed : 1e6);
    if (slide !== this.slideID) return;
    this.post({ type: "frame", frame });
    if (this.current) applyFrame(this.current, frame);
  }

  /** Moves on by itself after the slide's time, once its transition and running animations have settled. */
  scheduleAdvance(timeline) {
    clearTimeout(this.advanceTimer);
    if (!this.active || this.blanked || timeline.after == null || this.builds < timeline.steps || this.settings.timings === false) return;
    let settling = Math.max(((this.transitionEndsAt ?? 0) - performance.now()) / 1000, 0);
    if (this.builds > 0) {
      const duration = timeline.durations[this.builds - 1];
      // A step that repeats until the next tap never settles: the show waits for the tap.
      if (duration < 0) return;
      settling = Math.max(duration - (performance.now() - this.buildStartedAt) / 1000, settling);
    }
    const slide = this.slideID;
    const builds = this.builds;
    this.advanceTimer = setTimeout(() => {
      if (this.active && slide === this.slideID && builds === this.builds && !this.blanked) this.next();
    }, (Math.max(timeline.after, 0.1) + settling) * 1000);
  }

  /** Ends the transition playing now, here and in the audience's window, and starts the slide. */
  async finishTransition() {
    this.transitions?.finish();
    this.post({ type: "transitionEnd" });
    const now = performance.now();
    this.transitionEndsAt = now;
    if (this.buildStartedAt > now) this.buildStartedAt = now;
    this.scheduleAdvance(await this.timeline());
  }

  // MARK: - Media

  playStepMedia(timeline, step) {
    for (const id of timeline.media?.[step] ?? []) this.playMedia(id, "play");
  }

  /**
   * Starts what plays as the slide appears, once each: a movie that starts by
   * itself is usually also played by the slide's first step.
   */
  playOpeningMedia(timeline, scene) {
    const ids = new Set();
    for (let step = 0; step < this.builds; step++) for (const id of timeline.media?.[step] ?? []) ids.add(id);
    for (const node of scene.shapes) if (node.media?.auto && (!node.media.narration || this.settings.narration !== false)) ids.add(node.id);
    for (const id of ids) this.playMedia(id, "play");
  }

  /** `action` is "play" for a step or the slide starting it, "toggle" for a tap on it. */
  playMedia(id, action = "toggle") {
    this.post({ type: "media", id, action });
    if (this.mode === "single") toggleMedia(this.current, id, this.media, action);
  }

  stopMedia() {
    this.post({ type: "media", action: "stop" });
    for (const video of this.view?.querySelectorAll(".slideshow__media") ?? []) video.remove();
  }

  // MARK: - Input

  key(event) {
    if (!this.active) return;
    if (event.target.closest?.(".presenter__notes textarea")) return;
    this.handleKey(event.key, event.shiftKey);
    if (["ArrowRight", "ArrowDown", "PageDown", " ", "Enter", "n", "N", "ArrowLeft", "ArrowUp", "PageUp", "Backspace", "p", "P",
      "Escape", "b", "B", ".", "w", "W", ",", "Home", "End"].includes(event.key)) {
      event.preventDefault();
      event.stopPropagation();
    }
  }

  handleKey(key, shift = false) {
    // At a kiosk only Escape does anything: the show moves on by itself.
    if (key !== "Escape" && !this.isManual) return;
    switch (key) {
      case "ArrowRight": case "ArrowDown": case "PageDown": case " ": case "Enter": case "n": case "N":
        if (shift && key === " ") this.previous();
        else this.next();
        break;
      case "ArrowLeft": case "ArrowUp": case "PageUp": case "Backspace": case "p": case "P":
        this.previous();
        break;
      case "Home":
        this.go(0);
        break;
      case "End":
        this.go(this.order.length - 1);
        break;
      case "b": case "B": case ".": case "w": case "W": case ",":
        this.setBlank(!this.blanked);
        break;
      case "Escape":
        this.end();
        break;
      default:
        break;
    }
  }

  received(event) {
    if (event.origin !== location.origin || event.source !== this.audience) return;
    const message = event.data ?? {};
    switch (message.type) {
      case "ready":
        // The audience window has loaded: send it the fonts and the slide.
        this.sendFonts();
        this.resend();
        break;
      case "key":
        this.handleKey(message.key, message.shift);
        break;
      case "click":
        this.clicked(message);
        break;
      case "fullscreen":
        this.audienceFullscreen = message.on;
        this.updatePresenter();
        break;
      case "closed":
        this.end();
        break;
      default:
        break;
    }
  }

  /** A click on the slide: a link or movie on it, or else the next step if the slide moves on by clicking. */
  async clicked({ link, media }) {
    if (media) {
      this.playMedia(media);
      return;
    }
    if (link) {
      this.follow(link);
      return;
    }
    if (!this.isManual) return;
    const timeline = await this.timeline();
    if (this.builds < timeline.steps || timeline.onClick) this.next();
  }

  follow(link) {
    this.noteActivity();
    if (link.url) {
      window.open(link.url, "_blank", "noopener");
    } else if (link.slide) {
      this.goToSlide(link.slide);
    } else if (link.customShow != null) {
      this.playCustomShow(link.customShow, link.return);
    } else {
      ({ next: () => this.next(), previous: () => this.previous(), first: () => this.go(0), last: () => this.go(this.order.length - 1), end: () => this.end() })[link.action]?.();
    }
  }

  // MARK: - The audience window

  post(message) {
    if (!this.audience || this.audience.closed) return;
    try {
      this.audience.postMessage(message, location.origin);
    } catch {
      // Closed under us.
    }
  }

  async sendFonts() {
    if (!this.engine.info?.hasEmbeddedFonts) return;
    const { result, payload } = await this.engine.call("fonts");
    this.post({ type: "fonts", fonts: result, data: payload.buffer.slice(payload.byteOffset, payload.byteOffset + payload.byteLength) });
  }

  async resend() {
    if (!this.scene) return;
    const media = {};
    for (const path of sceneMedia(this.scene)) media[path] = await this.media.blob(path);
    const frame = await this.frame((performance.now() - this.buildStartedAt) / 1000);
    this.post({ type: "show", scene: this.scene, frame, media, number: this.position + 1, count: this.order.length });
    if (this.blanked) this.post({ type: "blank", on: true });
  }

  /** Asks the audience window to fill its display, handing it this click's right to go full screen where the browser can. */
  fillAudienceScreen() {
    if (!this.audience) return;
    try {
      this.audience.postMessage({ type: "fullscreen" }, { targetOrigin: location.origin, delegate: "fullscreen" });
    } catch {
      this.post({ type: "fullscreen" });
    }
    this.audience.focus();
  }

  /** Moves the audience window to the other display, asking to see the displays if need be. */
  async moveAudience() {
    const screen = await otherScreen({ ask: true });
    if (!screen || !this.audience) return;
    try {
      this.audience.moveTo(screen.availLeft, screen.availTop);
      this.audience.resizeTo(screen.availWidth, screen.availHeight);
    } catch {
      // Some browsers don't let a page move its windows.
    }
    this.placed = true;
    this.updatePresenter();
  }

  // MARK: - This window

  /** One display: the slide fills this window's screen. */
  buildSingle() {
    const view = document.createElement("div");
    view.className = "slideshow";
    view.innerHTML = `<div class="slideshow__stage"></div><div class="slideshow__blank" aria-hidden="true"></div>`;
    this.root.append(view);
    this.view = view;
    this.stage = view.querySelector(".slideshow__stage");
    this.transitions = new TransitionPlayer(this.stage, (slide) => this.fit(this.stage, slide));
    showLinkTips(view);
    view.requestFullscreen?.().catch(() => {});
    view.addEventListener("click", (event) => {
      const link = event.target.closest?.("[data-link]");
      const media = event.target.closest?.("[data-media]")?.closest(".shape")?.dataset.id;
      this.clicked({ link: link ? JSON.parse(link.dataset.link) : null, media });
    });
    view.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      this.previous();
    });
    document.addEventListener("fullscreenchange", this.onFullscreenChange = () => {
      // Leaving full screen with Escape ends the show, as Keynote does.
      if (!document.fullscreenElement && this.mode === "single" && this.active) this.end();
    }, { once: false });
    new ResizeObserver(() => this.fit(this.stage, this.current)).observe(this.stage);
  }

  /** Two displays: the presenter view, with the current and next slides, the notes and the time. */
  buildPresenter() {
    const t = this.t;
    const view = document.createElement("div");
    view.className = "presenter ds-window ds-dark";
    view.innerHTML = `
      <div class="presenter__bar">
        <span class="presenter__clock ds-numeric"></span>
        <span class="presenter__elapsed ds-numeric"></span>
        <span class="presenter__position ds-numeric"></span>
        <span class="presenter__spacer"></span>
        <span class="presenter__audience ds-caption"></span>
        <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-action="move"></button>
        <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-action="fill"></button>
        <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-action="blank"></button>
        <button class="ds-button ds-button--primary ds-button--xs" type="button" data-action="end"></button>
      </div>
      <div class="presenter__main">
        <section class="presenter__current"><div class="presenter__stage"></div></section>
        <aside class="presenter__side">
          <h2 class="ds-heading-compact presenter__label"></h2>
          <div class="presenter__next"><div class="presenter__stage presenter__stage--next"></div></div>
          <h2 class="ds-heading-compact presenter__label presenter__label--notes"></h2>
          <div class="presenter__notes ds-document-content"></div>
        </aside>
      </div>
      <div class="presenter__controls">
        <button class="ds-button ds-button--bordered" type="button" data-action="previous"></button>
        <button class="ds-button ds-button--primary" type="button" data-action="next"></button>
      </div>`;
    const labels = {
      move: t("Web.Presenter.MoveToDisplay"), fill: t("Web.Presenter.FillScreen"), blank: t("Slideshow.Blank"),
      end: t("Presenter.End"), previous: t("Slideshow.Previous"), next: t("Slideshow.Next"),
    };
    for (const button of view.querySelectorAll("[data-action]")) {
      button.textContent = labels[button.dataset.action];
      button.addEventListener("click", () => {
        switch (button.dataset.action) {
          case "move": return this.moveAudience();
          case "fill": return this.fillAudienceScreen();
          case "blank": return this.setBlank(!this.blanked);
          case "end": return this.end();
          case "previous": return this.isManual && this.previous();
          case "next": return this.isManual && this.next();
          default: return null;
        }
      });
    }
    view.querySelector(".presenter__label").textContent = t("Presenter.Next");
    view.querySelector(".presenter__label--notes").textContent = t("Presenter.Notes");
    this.root.append(view);
    this.view = view;
    this.stage = view.querySelector(".presenter__stage");
    this.transitions = new TransitionPlayer(this.stage, (slide) => this.fit(this.stage, slide));
    this.nextStage = view.querySelector(".presenter__stage--next");
    this.stage.addEventListener("click", (event) => {
      const link = event.target.closest?.("[data-link]");
      this.clicked({ link: link ? JSON.parse(link.dataset.link) : null });
    });
    showLinkTips(this.stage);
    const resize = new ResizeObserver(() => {
      this.fit(this.stage, this.current);
      this.fit(this.nextStage, this.upcoming);
    });
    resize.observe(this.stage);
    resize.observe(this.nextStage);
    this.clockTimer = setInterval(() => this.updateClock(), 1000);
    this.updateClock();
  }

  drawLocal(scene, frame, transition = null) {
    if (!this.stage) return;
    this.transitions?.finish();
    const previous = this.current;
    const slide = this.drawer.draw(scene, { interactive: true });
    this.stage.replaceChildren(slide);
    this.current = slide;
    this.fit(this.stage, slide);
    this.drawer.fit(slide);
    applyFrame(slide, frame);
    if (transition && previous) this.transitions?.play(transition, previous, slide);
  }

  async drawNext() {
    if (this.mode !== "presenter") return;
    const id = this.order[this.position + 1];
    if (!id) {
      const end = document.createElement("p");
      end.className = "presenter__end ds-caption";
      end.textContent = this.t("Web.Presenter.EndOfShow");
      this.nextStage.replaceChildren(end);
      this.upcoming = null;
      return;
    }
    const scene = await this.engine.call("scene", { slide: id });
    // The next slide as it first appears: animations that wait for a tap haven't happened yet.
    const timeline = await this.timeline(id);
    const frame = await this.engine.call("frame", { slide: id, begun: timeline.initial, elapsed: 1e6 });
    const slide = this.drawer.draw(scene);
    this.nextStage.replaceChildren(slide);
    this.upcoming = slide;
    this.fit(this.nextStage, slide);
    this.drawer.fit(slide);
    applyFrame(slide, frame);
  }

  /** Scales a slide to fill `stage`, centred. */
  fit(stage, slide) {
    if (!stage || !slide?.slideScene) return;
    const scene = slide.slideScene;
    const scale = Math.min(stage.clientWidth / scene.w, stage.clientHeight / scene.h) || 0;
    slide.style.transform = `translate(${(stage.clientWidth - scene.w * scale) / 2}px, ${(stage.clientHeight - scene.h * scale) / 2}px) scale(${scale})`;
  }

  async updatePresenter() {
    if (this.mode !== "presenter" || !this.view) return;
    const t = this.t;
    const timeline = await this.timeline();
    const notes = this.view.querySelector(".presenter__notes");
    notes.textContent = timeline.notes || t("Presenter.NoNotes");
    notes.classList.toggle("is-empty", !timeline.notes);
    const steps = timeline.steps > timeline.initial ? ` · ${this.builds - timeline.initial}/${timeline.steps - timeline.initial}` : "";
    this.view.querySelector(".presenter__position").textContent = `${t("Slideshow.Position", this.position + 1, this.order.length)}${steps}`;
    this.view.querySelector('[data-action="blank"]').textContent = this.blanked ? t("Slideshow.Unblank") : t("Slideshow.Blank");
    this.view.querySelector('[data-action="previous"]').disabled = this.position === 0 && this.builds <= timeline.initial;
    this.view.querySelector('[data-action="fill"]').hidden = Boolean(this.audienceFullscreen);
    this.view.querySelector('[data-action="move"]').hidden = this.placed || !("getScreenDetails" in window);
    this.view.querySelector(".presenter__audience").textContent = this.blanked ? t("Presenter.Blanked") : t("Presenter.Connected");
    this.view.classList.toggle("is-blanked", this.blanked);
  }

  updateClock() {
    if (!this.view) return;
    const clock = this.view.querySelector(".presenter__clock");
    const elapsed = this.view.querySelector(".presenter__elapsed");
    if (!clock) return;
    clock.textContent = new Intl.DateTimeFormat(this.language, { timeStyle: "short" }).format(new Date());
    const seconds = Math.floor((Date.now() - this.startedAt) / 1000);
    const pad = (value) => String(value).padStart(2, "0");
    const text = `${Math.floor(seconds / 3600)}:${pad(Math.floor(seconds / 60) % 60)}:${pad(seconds % 60)}`;
    elapsed.textContent = `${this.t("Presenter.Elapsed")} ${text}`;
  }
}

/** Every picture, movie and sound a scene draws, by part. */
export function sceneMedia(scene) {
  const paths = new Set();
  if (scene.bg?.t === "image") paths.add(scene.bg.src);
  collectMedia([...scene.art, ...scene.shapes], paths);
  return paths;
}

function collectMedia(nodes, paths) {
  for (const node of nodes) {
    if (node.src) paths.add(node.src);
    if (node.media?.path) paths.add(node.media.path);
    if (node.fill?.t === "image") paths.add(node.fill.src);
    if (node.table) for (const cell of node.table.cells) if (cell.fill?.t === "image") paths.add(cell.fill.src);
    if (node.children) collectMedia(node.children, paths);
  }
}

/** Each picture's player, wherever it is shown. */
const players = new WeakMap();

/**
 * Plays or pauses the movie or sound a picture stands for, over the picture,
 * or over the whole show for a video set to play full screen. It plays the
 * trimmed part of the file, at its volume, fading in and out, and when it
 * ends it loops, rewinds or stays on its last frame as it is set to.
 */
export async function toggleMedia(slide, id, media, action = "toggle") {
  const shape = slide?.querySelector(`.shape[data-id="${id}"]`);
  const info = shape?.querySelector("[data-media]")?.dataset.media;
  // A player still on its way plays once it arrives.
  if (!shape || !info || shape.dataset.mediaLoading) return;
  const settings = JSON.parse(info);
  const { kind, path } = settings;
  const [trimStart = 0, trimEnd = 0] = settings.trim ?? [];
  const [fadeIn = 0, fadeOut = 0] = settings.fade ?? [];
  const volume = settings.volume ?? 1;
  let player = players.get(shape);
  if (player?.isConnected) {
    if (player.paused) {
      if (player.ended || player.currentTime >= endOf(player) - 0.05) player.currentTime = trimStart;
      player.play().catch(() => {});
    } else if (action === "toggle") player.pause();
    return;
  }
  if (!path) return;
  shape.dataset.mediaLoading = "1";
  const url = await media.url(path);
  delete shape.dataset.mediaLoading;
  if (!url || !shape.isConnected) return;
  player = document.createElement(kind === "audio" ? "audio" : "video");
  player.className = "slideshow__media";
  player.src = url;
  player.playsInline = true;
  player.volume = Math.min(Math.max(volume, 0), 1);
  player.muted = volume <= 0;
  players.set(shape, player);

  function endOf(element) {
    const duration = Number.isFinite(element.duration) ? element.duration : Infinity;
    return Math.max(duration - trimEnd, trimStart);
  }
  function level() {
    const time = player.currentTime;
    let value = 1;
    if (fadeIn > 0) value = Math.min(value, (time - trimStart) / fadeIn);
    if (fadeOut > 0) value = Math.min(value, (endOf(player) - time) / fadeOut);
    return Math.min(Math.max(value, 0), 1);
  }
  function finished() {
    if (settings.loop) {
      player.currentTime = trimStart;
      player.play().catch(() => {});
      return;
    }
    player.pause();
    if (settings.rewind) player.currentTime = trimStart;
    // Back to its picture, or out of sight if it shows only while playing.
    if (settings.rewind || settings.hide || settings.full) player.remove();
  }
  function tick() {
    if (!player.isConnected) return;
    if (fadeIn > 0 || fadeOut > 0) {
      const amount = level();
      player.volume = Math.min(Math.max(volume, 0), 1) * amount;
      if (kind === "video") player.style.opacity = String(amount);
    }
    if (!player.paused && trimEnd > 0 && player.currentTime >= endOf(player)) finished();
    if (!player.paused) requestAnimationFrame(tick);
  }
  player.addEventListener("loadedmetadata", () => { if (trimStart > 0) player.currentTime = trimStart; }, { once: true });
  player.addEventListener("play", () => requestAnimationFrame(tick));
  player.addEventListener("ended", finished);

  const stage = settings.full ? slide.closest(".slideshow__stage, .presenter__stage, .audience__stage") : null;
  if (stage) {
    player.classList.add("slideshow__media--full");
    stage.append(player);
  } else {
    shape.querySelector(".shape__body").append(player);
  }
  if (fadeIn > 0) {
    player.volume = 0;
    if (kind === "video") player.style.opacity = "0";
  }
  player.play().catch(() => {});
}
