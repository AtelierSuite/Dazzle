// Exporting slides as pictures and as printed pages, as the Mac's
// ExportController does with SlideExporter.
//
// The browser draws slides as HTML and SVG (slide.js), so a slide becomes a
// picture by drawing that markup into a canvas: it is copied into an SVG
// <foreignObject> with the page's styles, the presentation's own fonts and its
// pictures written in, and the SVG is drawn as an image.

/** Widths offered for pictures, in pixels, as on the Mac. */
export const RESOLUTIONS = [1280, 1920, 3840];

/** The page layouts offered for PDF, as on the Mac: slides, notes pages, and handouts of 2, 3, 4 or 6. */
export const PAGE_LAYOUTS = [
  ["slides", "Export.Layout.Slides"], ["notes", "Export.Layout.Notes"],
  ["handouts2", "Mac.Export.Layout.Handouts2"], ["handouts3", "Mac.Export.Layout.Handouts3"],
  ["handouts4", "Mac.Export.Layout.Handouts4"], ["handouts6", "Mac.Export.Layout.Handouts6"],
];

// MARK: - Drawing slides as pictures

/** The page's styles, as text, for a slide drawn on its own. */
function pageStyles() {
  let css = "";
  for (const sheet of document.styleSheets) {
    try {
      for (const rule of sheet.cssRules) css += `${rule.cssText}\n`;
    } catch {
      // A sheet from elsewhere can't be read; the slide doesn't use one.
    }
  }
  return css;
}

function dataURL(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

function base64(bytes) {
  let text = "";
  for (let index = 0; index < bytes.length; index += 0x8000) text += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  return btoa(text);
}

const escapeXML = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;");

/**
 * Draws slides laid out on the page into canvases. Made once for an export:
 * it gathers the styles and fonts once, and each picture once.
 */
export class SlideRasteriser {
  /**
   * @param {import("./slide.js").MediaStore} media where the slide's pictures come from
   * @param {{ family: string, bold: boolean, italic: boolean, bytes: Uint8Array }[]} fonts the presentation's own typefaces
   */
  constructor(media, fonts = []) {
    this.media = media;
    this.inlined = new Map();
    const faces = fonts.map((font) => `@font-face { font-family: "${font.family.replace(/["\\]/g, "\\$&")}"; font-weight: ${font.bold ? 700 : 400}; font-style: ${font.italic ? "italic" : "normal"}; src: url(data:font/ttf;base64,${base64(font.bytes)}); }`);
    this.styles = `${faces.join("\n")}\n${pageStyles()}`;
  }

  /** A data URL for a picture the slide shows by its object URL. */
  async inline(url) {
    if (!url.startsWith("blob:")) return url;
    if (!this.inlined.has(url)) {
      let blob = null;
      for (const [path, known] of this.media.urls) if (known === url) blob = this.media.blobs.get(path);
      this.inlined.set(url, blob ? dataURL(blob) : Promise.resolve(url));
    }
    return this.inlined.get(url);
  }

  /**
   * The slide element `slide`, already laid out on the page, as a canvas
   * `width` pixels wide. `opaque` fills what the slide leaves clear with white, as JPEG needs.
   */
  async draw(slide, width, { opaque = true } = {}) {
    const scene = slide.slideScene;
    const scale = width / scene.w;
    const height = Math.max(Math.round(scene.h * scale), 1);
    const copy = slide.cloneNode(true);
    copy.style.transform = "none";
    copy.style.position = "relative";
    copy.style.left = "0";
    copy.style.top = "0";
    // Pictures go in as data: an SVG drawn as an image loads nothing from outside.
    for (const element of copy.querySelectorAll("image, img")) {
      for (const attribute of ["href", "xlink:href", "src"]) {
        const value = element.getAttribute(attribute);
        if (value?.startsWith("blob:")) element.setAttribute(attribute, await this.inline(value));
      }
    }
    for (const element of copy.querySelectorAll("[style*='blob:']")) {
      let style = element.getAttribute("style");
      for (const [, url] of style.matchAll(/url\(["']?(blob:[^"')]+)["']?\)/g)) style = style.replaceAll(url, await this.inline(url));
      element.setAttribute("style", style);
    }
    const markup = new XMLSerializer().serializeToString(copy);
    const picture = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`
      + `<foreignObject x="0" y="0" width="${width}" height="${height}">`
      + `<div xmlns="http://www.w3.org/1999/xhtml" style="width:${width}px;height:${height}px;overflow:hidden">`
      + `<style>${escapeXML(this.styles)}</style>`
      + `<div style="width:${scene.w}px;height:${scene.h}px;transform:scale(${scale});transform-origin:0 0">${markup}</div>`
      + "</div></foreignObject></svg>";
    const image = new Image();
    image.width = width;
    image.height = height;
    await new Promise((resolve, reject) => {
      image.onload = resolve;
      image.onerror = () => reject(new Error("The slide couldn't be drawn."));
      image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(picture)}`;
    });
    // WebKit paints the pictures inside an SVG a moment after the SVG itself has loaded.
    await new Promise((resolve) => setTimeout(resolve, 50));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    if (opaque) {
      context.fillStyle = "#fff";
      context.fillRect(0, 0, width, height);
    }
    context.drawImage(image, 0, 0, width, height);
    return canvas;
  }
}

/** A canvas as PNG or JPEG bytes. */
export async function encodeImage(canvas, format) {
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, format === "jpeg" ? "image/jpeg" : "image/png", 0.9));
  if (!blob) throw new Error("The picture couldn't be made.");
  return new Uint8Array(await blob.arrayBuffer());
}

// MARK: - Zip

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes) {
  let crc = 0xffffffff;
  for (let index = 0; index < bytes.length; index++) crc = CRC_TABLE[(crc ^ bytes[index]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * Files in a zip archive, stored as they are: pictures are already compressed.
 * @param {{ name: string, bytes: Uint8Array }[]} files
 */
export function zip(files) {
  const encoder = new TextEncoder();
  const parts = [];
  const central = [];
  let offset = 0;
  for (const file of files) {
    const name = encoder.encode(file.name);
    const crc = crc32(file.bytes);
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint16(6, 0x0800, true); // Names in UTF-8.
    local.setUint16(12, 0x21, true); // 1 January 1980, the first day a zip can say.
    local.setUint32(14, crc, true);
    local.setUint32(18, file.bytes.length, true);
    local.setUint32(22, file.bytes.length, true);
    local.setUint16(26, name.length, true);
    parts.push(new Uint8Array(local.buffer), name, file.bytes);
    const entry = new DataView(new ArrayBuffer(46));
    entry.setUint32(0, 0x02014b50, true);
    entry.setUint16(4, 20, true);
    entry.setUint16(6, 20, true);
    entry.setUint16(8, 0x0800, true);
    entry.setUint16(14, 0x21, true);
    entry.setUint32(16, crc, true);
    entry.setUint32(20, file.bytes.length, true);
    entry.setUint32(24, file.bytes.length, true);
    entry.setUint16(28, name.length, true);
    entry.setUint32(42, offset, true);
    central.push(new Uint8Array(entry.buffer), name);
    offset += 30 + name.length + file.bytes.length;
  }
  const size = central.reduce((total, part) => total + part.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, files.length, true);
  end.setUint16(10, files.length, true);
  end.setUint32(12, size, true);
  end.setUint32(16, offset, true);
  return concat([...parts, ...central, new Uint8Array(end.buffer)]);
}

function concat(parts) {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

// MARK: - Pages for printing

/** Paper for notes and handouts, in points: Letter where US measures are used, A4 elsewhere. */
export function paperSize(language = navigator.language) {
  let region = "";
  try {
    region = new Intl.Locale(language).maximize().region ?? "";
  } catch {
    // A tag the browser can't read is taken as metric.
  }
  return ["US", "LR", "MM"].includes(region) ? { w: 612, h: 792 } : { w: 595, h: 842 };
}

/** The largest slide-shaped rectangle in `box`, centred, in points. */
function fitted(size, box) {
  const aspect = size.w / size.h;
  let w = box.w;
  let h = box.w / aspect;
  if (h > box.h) {
    h = box.h;
    w = box.h * aspect;
  }
  return { x: box.x + (box.w - w) / 2, y: box.y + (box.h - h) / 2, w, h };
}

/**
 * Lays out printed pages, as SlideExporter's PDFs on the Mac: a page per slide
 * at its own size, notes pages with the slide above its notes, or handouts.
 * `place(page, slide, rect)` puts slide number `slide` on `page` in `rect`, in points.
 * @returns {{ size: { w: number, h: number }, pages: HTMLElement[] }}
 */
export function layoutPages({ slides, size, layout, place }) {
  const pages = [];
  const page = (paper) => {
    const element = document.createElement("div");
    element.className = "app__print-page";
    element.style.width = `${paper.w}pt`;
    element.style.height = `${paper.h}pt`;
    pages.push(element);
    return element;
  };
  const absolute = (element, rect) => Object.assign(element.style, {
    position: "absolute", left: `${rect.x}pt`, top: `${rect.y}pt`, width: `${rect.w}pt`, ...(rect.h != null ? { height: `${rect.h}pt` } : {}),
  });
  const framed = (target, index, rect) => {
    place(target, index, rect);
    // A hairline round each slide on paper.
    const frame = document.createElement("div");
    frame.className = "app__print-frame";
    absolute(frame, rect);
    target.append(frame);
  };
  const number = (target, paper, value) => {
    const label = document.createElement("div");
    label.className = "app__print-number";
    absolute(label, { x: 0, y: paper.h - 30, w: paper.w });
    label.textContent = String(value);
    target.append(label);
  };

  if (layout === "slides") {
    for (let index = 0; index < slides.length; index++) place(page(size), index, { x: 0, y: 0, w: size.w, h: size.h });
    return { size, pages };
  }
  const paper = paperSize();
  if (layout === "notes") {
    const margin = 54;
    slides.forEach((slide, index) => {
      const target = page(paper);
      const rect = fitted(size, { x: margin, y: margin, w: paper.w - margin * 2, h: paper.h * 0.42 });
      framed(target, index, rect);
      const notes = document.createElement("div");
      notes.className = "app__print-notes";
      absolute(notes, { x: margin, y: rect.y + rect.h + 28, w: paper.w - margin * 2, h: paper.h - (rect.y + rect.h) - 28 - margin });
      notes.textContent = slide.notes ?? "";
      target.append(notes);
      number(target, paper, index + 1);
    });
    return { size: paper, pages };
  }
  const count = Number(layout.replace("handouts", "")) || 6;
  // Columns and rows for each count; three to a page leave room to write beside them.
  const [columns, rows] = { 1: [1, 1], 2: [1, 2], 3: [1, 3], 4: [2, 2], 6: [2, 3] }[count] ?? [3, 3];
  const margin = 40;
  const area = { x: margin, y: margin, w: paper.w - margin * 2, h: paper.h - margin * 2 - 24 };
  const slideArea = count === 3 ? { ...area, w: area.w * 0.5 } : area;
  const cell = { w: slideArea.w / columns, h: slideArea.h / rows };
  const pageCount = Math.max(Math.ceil(slides.length / count), 1);
  for (let pageIndex = 0; pageIndex < pageCount; pageIndex++) {
    const target = page(paper);
    for (let position = 0; position < count; position++) {
      const index = pageIndex * count + position;
      if (index >= slides.length) break;
      const column = position % columns;
      const row = Math.floor(position / columns);
      const box = { x: slideArea.x + column * cell.w + 10, y: slideArea.y + row * cell.h + 10, w: cell.w - 20, h: cell.h - 20 };
      const rect = fitted(size, box);
      framed(target, index, rect);
      if (count === 3) {
        // Lines to write notes on, beside the slide.
        for (let y = rect.y + 18; y < rect.y + rect.h; y += 18) {
          const line = document.createElement("div");
          line.className = "app__print-line";
          absolute(line, { x: area.x + area.w / 2 + 16, y, w: area.w / 2 - 16 });
          target.append(line);
        }
      }
    }
    number(target, paper, pageIndex + 1);
  }
  return { size: paper, pages };
}
