// Exporting slides as pictures, as a movie and as printed pages, as the Mac's
// ExportController does with SlideExporter and VideoExporter.
//
// The browser draws slides as HTML and SVG (slide.js), so a slide becomes a
// picture by drawing that markup into a canvas: it is copied into an SVG
// <foreignObject> with the page's styles, the presentation's own fonts and its
// pictures written in, and the SVG is drawn as an image. A movie is made of
// those pictures with WebCodecs and written into an MP4 file here, since the
// web build uses no packages.

/** Widths offered for pictures and movies, in pixels, as on the Mac. */
export const RESOLUTIONS = [1280, 1920, 3840];

/** The page layouts offered for PDF, as on the Mac: slides, notes pages, and handouts of 2, 3, 4 or 6. */
export const PAGE_LAYOUTS = [
  ["slides", "Export.Layout.Slides"], ["notes", "Export.Layout.Notes"],
  ["handouts2", "Mac.Export.Layout.Handouts2"], ["handouts3", "Mac.Export.Layout.Handouts3"],
  ["handouts4", "Mac.Export.Layout.Handouts4"], ["handouts6", "Mac.Export.Layout.Handouts6"],
];

/** Seconds each slide of a movie dissolves into the next, and frames a second, as VideoExporter has them. */
const DISSOLVE = 0.5;
const FRAMES_PER_SECOND = 30;

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

// MARK: - MP4

/** Writes boxes, big-endian, as ISO/IEC 14496-12 lays them out. */
class BoxWriter {
  constructor() {
    this.parts = [];
  }

  static box(type, ...contents) {
    const body = concat(contents);
    const header = new DataView(new ArrayBuffer(8));
    header.setUint32(0, body.length + 8);
    for (let index = 0; index < 4; index++) header.setUint8(4 + index, type.charCodeAt(index));
    return concat([new Uint8Array(header.buffer), body]);
  }

  static fullBox(type, version, flags, ...contents) {
    return BoxWriter.box(type, BoxWriter.u8(version), BoxWriter.u24(flags), ...contents);
  }

  static u8(value) {
    return new Uint8Array([value & 0xff]);
  }

  static u16(value) {
    return new Uint8Array([(value >>> 8) & 0xff, value & 0xff]);
  }

  static u24(value) {
    return new Uint8Array([(value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff]);
  }

  static u32(value) {
    const view = new DataView(new ArrayBuffer(4));
    view.setUint32(0, value >>> 0);
    return new Uint8Array(view.buffer);
  }

  static u32s(...values) {
    return concat(values.map((value) => BoxWriter.u32(value)));
  }

  static ascii(text) {
    return new TextEncoder().encode(text);
  }
}

const MATRIX = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];

/**
 * An MP4 file holding one H.264 video track: `samples` are the encoder's
 * chunks in decoding order, each with its duration in microseconds and
 * whether it is a key frame; `avcC` is the decoder configuration the encoder gave.
 */
export function mp4({ width, height, avcC, samples }) {
  const { box, fullBox, u8, u16, u32, u32s, ascii } = BoxWriter;
  const timescale = 90_000;
  const ticks = samples.map((sample) => Math.max(Math.round((sample.duration * timescale) / 1e6), 1));
  const duration = ticks.reduce((total, value) => total + value, 0);
  const movieDuration = Math.round((duration * 1000) / timescale);

  const ftyp = box("ftyp", ascii("isom"), u32(0x200), ascii("isomiso2avc1mp41"));
  const mdatSize = samples.reduce((total, sample) => total + sample.data.length, 0) + 8;
  // The samples, one chunk each, start after the file type and the media data's header.
  const offsets = [];
  let at = ftyp.length + 8;
  for (const sample of samples) {
    offsets.push(at);
    at += sample.data.length;
  }

  // Durations, run-length coded.
  const runs = [];
  for (const value of ticks) {
    if (runs.length && runs.at(-1)[1] === value) runs.at(-1)[0] += 1;
    else runs.push([1, value]);
  }
  const keys = samples.map((sample, index) => (sample.key ? index + 1 : 0)).filter(Boolean);

  const avc1 = box("avc1",
    new Uint8Array(6), u16(1), // Reserved; the data reference.
    new Uint8Array(16), u16(width), u16(height),
    u32s(0x00480000, 0x00480000, 0), u16(1),
    new Uint8Array(32), u16(0x0018), u16(0xffff),
    box("avcC", avcC));
  const stbl = box("stbl",
    fullBox("stsd", 0, 0, u32(1), avc1),
    fullBox("stts", 0, 0, u32(runs.length), ...runs.map(([count, delta]) => u32s(count, delta))),
    fullBox("stss", 0, 0, u32(keys.length), ...keys.map((key) => u32(key))),
    fullBox("stsc", 0, 0, u32s(1, 1, 1, 1)),
    fullBox("stsz", 0, 0, u32s(0, samples.length), ...samples.map((sample) => u32(sample.data.length))),
    fullBox("stco", 0, 0, u32(offsets.length), ...offsets.map((offset) => u32(offset))));
  const minf = box("minf",
    fullBox("vmhd", 0, 1, new Uint8Array(8)),
    box("dinf", fullBox("dref", 0, 0, u32(1), fullBox("url ", 0, 1))),
    stbl);
  const mdia = box("mdia",
    fullBox("mdhd", 0, 0, u32s(0, 0, timescale, duration), u16(0x55c4), u16(0)),
    fullBox("hdlr", 0, 0, u32(0), ascii("vide"), new Uint8Array(12), ascii("VideoHandler"), u8(0)),
    minf);
  const tkhd = fullBox("tkhd", 0, 3,
    u32s(0, 0, 1, 0, movieDuration, 0, 0), u16(0), u16(0), u16(0), u16(0),
    u32s(...MATRIX), u32s(width * 0x10000, height * 0x10000));
  const mvhd = fullBox("mvhd", 0, 0,
    u32s(0, 0, 1000, movieDuration, 0x00010000), u16(0x0100), new Uint8Array(10),
    u32s(...MATRIX), new Uint8Array(24), u32(2));
  const moov = box("moov", mvhd, box("trak", tkhd, mdia));
  const mdatHeader = concat([u32(mdatSize), ascii("mdat")]);
  return concat([ftyp, mdatHeader, ...samples.map((sample) => sample.data), moov]);
}

/** Whether this browser can make movies: WebCodecs with an H.264 encoder. */
export const canMakeMovies = typeof globalThis.VideoEncoder === "function" && typeof globalThis.VideoFrame === "function";

/** An H.264 configuration this browser can encode at `width` by `height`, or null. */
async function movieConfig(width, height) {
  // High, Main and Baseline profiles, at a level that holds the size at 30 frames a second.
  // Levels limit the frame's size in 16-pixel macroblocks: 3.1 to 3,600, 4.0 to 8,192, 5.1 to 36,864, 6.0 to 139,264.
  const blocks = Math.ceil(width / 16) * Math.ceil(height / 16);
  const level = blocks > 36_864 ? "3C" : blocks > 8_192 ? "33" : blocks > 3_600 ? "28" : "1F";
  for (const profile of ["6400", "4D00", "4200"]) {
    const config = {
      codec: `avc1.${profile}${level}`, width, height, framerate: FRAMES_PER_SECOND, avc: { format: "avc" },
      bitrate: Math.round(width * height * FRAMES_PER_SECOND * 0.1), latencyMode: "quality",
    };
    try {
      if ((await VideoEncoder.isConfigSupported(config)).supported) return config;
    } catch {
      // Try the next.
    }
  }
  return null;
}

/**
 * A movie of slides, each held for its number of seconds and dissolving into
 * the next over the last half second, as VideoExporter makes it on Apple
 * platforms. `picture(index)` draws slide `index` as a canvas; `progress` hears
 * how far it has got, 0…1; `cancelled()` stops it.
 * @returns {Promise<Uint8Array | null>} the MP4 file, or null if cancelled
 */
export async function makeMovie({ count, durations, width, height, picture, progress = () => {}, cancelled = () => false }) {
  // Encoders want even sizes.
  width -= width % 2;
  height -= height % 2;
  const config = await movieConfig(width, height);
  if (!config) throw new Error("No H.264 encoder.");
  const samples = [];
  let avcC = null;
  let failure = null;
  const encoder = new VideoEncoder({
    output: (chunk, metadata) => {
      const description = metadata?.decoderConfig?.description;
      if (description) avcC = ArrayBuffer.isView(description) ? new Uint8Array(description.buffer, description.byteOffset, description.byteLength).slice() : new Uint8Array(description).slice();
      const data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      samples.push({ data, timestamp: chunk.timestamp, key: chunk.type === "key" });
    },
    error: (error) => { failure = error; },
  });
  encoder.configure(config);
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  const frameLength = 1e6 / FRAMES_PER_SECOND;
  const ends = []; // When each frame ends, in microseconds, in order.
  let time = 0;
  const emit = (length, key) => {
    const frame = new VideoFrame(canvas, { timestamp: Math.round(time), duration: Math.round(length) });
    encoder.encode(frame, { keyFrame: key });
    frame.close();
    time += length;
    ends.push(Math.round(time));
  };
  const total = durations.reduce((sum, value) => sum + value, 0) || 1;
  let done = 0;
  let next = count ? await picture(0) : null;
  try {
    for (let index = 0; index < count; index++) {
      if (cancelled()) return null;
      const current = next;
      next = index + 1 < count ? await picture(index + 1) : null;
      if (cancelled()) return null;
      const hold = Math.max(durations[index], 1 / FRAMES_PER_SECOND);
      const dissolveFrames = next ? Math.min(Math.round(DISSOLVE * FRAMES_PER_SECOND), Math.floor((hold * FRAMES_PER_SECOND) / 2)) : 0;
      // The slide, still, as one long frame; then the frames that dissolve into the next.
      context.globalAlpha = 1;
      context.drawImage(current, 0, 0, width, height);
      emit((hold * 1e6) - dissolveFrames * frameLength, true);
      for (let step = 1; step <= dissolveFrames; step++) {
        context.globalAlpha = 1;
        context.drawImage(current, 0, 0, width, height);
        context.globalAlpha = step / (dissolveFrames + 1);
        context.drawImage(next, 0, 0, width, height);
        emit(frameLength, false);
      }
      // Don't let the encoder fall far behind.
      while (encoder.encodeQueueSize > 8) await new Promise((resolve) => setTimeout(resolve, 5));
      if (failure) throw failure;
      done += durations[index];
      progress(Math.min(done / total, 1) * 0.95);
    }
    await encoder.flush();
  } finally {
    if (encoder.state !== "closed") encoder.close();
  }
  if (failure) throw failure;
  if (!avcC || !samples.length) throw new Error("The encoder made nothing.");
  // Each sample lasts until the next starts; the last, until its frame ends.
  samples.sort((a, b) => a.timestamp - b.timestamp);
  for (let index = 0; index < samples.length; index++) {
    samples[index].duration = index + 1 < samples.length ? samples[index + 1].timestamp - samples[index].timestamp : ends.at(-1) - samples[index].timestamp;
  }
  progress(1);
  return mp4({ width, height, avcC, samples });
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
