// The audience's window in a slideshow with a presenter view (slideshow.js):
// it draws what the presenter's window sends, filling its display, and sends
// back the keys and clicks it receives. It has no engine of its own.

import "../design/base.js";
import { loadStrings, t } from "./i18n.js";
import { SlideDrawer, MediaStore, applyFrame } from "./slide.js";
import { toggleMedia } from "./slideshow.js";

const stage = document.querySelector(".audience__stage");
const fill = document.querySelector(".audience__fill");
/** Pictures and movies the presenter's window hands over with each slide. */
const media = new MediaStore(null);
const drawer = new SlideDrawer(media);
let current = null;

const owner = window.opener;
const tell = (message) => {
  try {
    owner?.postMessage(message, location.origin);
  } catch {
    // The presenter's window has gone.
  }
};

function fit() {
  if (!current?.slideScene) return;
  const scene = current.slideScene;
  const scale = Math.min(stage.clientWidth / scene.w, stage.clientHeight / scene.h) || 0;
  current.style.transform = `translate(${(stage.clientWidth - scene.w * scale) / 2}px, ${(stage.clientHeight - scene.h * scale) / 2}px) scale(${scale})`;
}

async function goFullScreen() {
  if (document.fullscreenElement) return;
  try {
    await document.documentElement.requestFullscreen({ navigationUI: "hide" });
  } catch {
    // Wants a click here first: the button says so.
    fill.hidden = false;
  }
}

function fullscreenChanged() {
  const on = Boolean(document.fullscreenElement);
  fill.hidden = on;
  document.body.classList.toggle("is-fullscreen", on);
  tell({ type: "fullscreen", on });
}

window.addEventListener("message", async (event) => {
  if (event.origin !== location.origin || event.source !== owner) return;
  const message = event.data ?? {};
  switch (message.type) {
    case "show": {
      for (const [path, blob] of Object.entries(message.media ?? {})) media.adopt(path, blob);
      const slide = drawer.draw(message.scene, { interactive: true });
      stage.replaceChildren(slide);
      current = slide;
      fit();
      drawer.fit(slide);
      applyFrame(slide, message.frame);
      document.title = t("Slideshow.Position", message.number, message.count);
      break;
    }
    case "frame":
      if (current) applyFrame(current, message.frame);
      break;
    case "blank":
      document.body.classList.toggle("is-blanked", Boolean(message.on));
      break;
    case "media":
      if (message.action === "stop") for (const player of stage.querySelectorAll(".slideshow__media")) player.remove();
      else toggleMedia(current, message.id, media);
      break;
    case "fonts": {
      const bytes = new Uint8Array(message.data);
      for (const font of message.fonts) {
        const face = new FontFace(font.family, bytes.slice(font.offset, font.offset + font.length), {
          weight: font.bold ? "700" : "400", style: font.italic ? "italic" : "normal",
        });
        try {
          document.fonts.add(await face.load());
        } catch {
          // A font the browser can't read is drawn in another.
        }
      }
      if (current) drawer.fit(current);
      break;
    }
    case "fullscreen":
      // Sent with the presenter's click, which this window may use to go full screen.
      goFullScreen();
      break;
    case "end":
      window.close();
      break;
    default:
      break;
  }
});

window.addEventListener("keydown", (event) => {
  // Keys a clicker or keyboard sends here run the show from the presenter's window.
  if (event.key === "f" || event.key === "F") {
    goFullScreen();
    return;
  }
  event.preventDefault();
  tell({ type: "key", key: event.key, shift: event.shiftKey });
});

stage.addEventListener("click", (event) => {
  if (!document.fullscreenElement && !fill.hidden) goFullScreen();
  const link = event.target.closest?.("[data-link]");
  const movie = event.target.closest?.("[data-media]")?.closest(".shape")?.dataset.id;
  tell({ type: "click", link: link ? JSON.parse(link.dataset.link) : null, media: movie ?? null });
});
stage.addEventListener("contextmenu", (event) => {
  event.preventDefault();
  tell({ type: "key", key: "ArrowLeft" });
});

fill.addEventListener("click", (event) => {
  event.stopPropagation();
  goFullScreen();
});
document.addEventListener("fullscreenchange", fullscreenChanged);
new ResizeObserver(fit).observe(stage);
window.addEventListener("pagehide", () => tell({ type: "closed" }));

loadStrings().then(() => {
  fill.textContent = t("Web.Presenter.FillScreen");
  if (!owner) {
    // Opened on its own: there is no show to follow.
    window.close();
    return;
  }
  // Already full screen when the browser opened it so (the `fullscreen` window feature).
  fill.hidden = Boolean(document.fullscreenElement);
  tell({ type: "ready" });
});
