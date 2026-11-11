// Smoke tests for the WebAssembly engine, run with Node's built-ins only:
//
//   node Web/engine/tests/smoke.mjs [file.pptx|file.key ...]
//
// Loads build/dazzle-engine.wasm through the same engine.js the app uses,
// edits a presentation the way the page does, saves and reopens it, and
// opens any files given.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { basename } from "node:path";
import { inflateRawSync } from "node:zlib";
import { strict as assert } from "node:assert";
import { Engine } from "../engine.js";

const web = new URL("../../", import.meta.url);
const engine = await Engine.load(readFile(fileURLToPath(new URL("build/dazzle-engine.wasm", web))));
const strings = JSON.parse(await readFile(fileURLToPath(new URL("build/strings/app-en.json", web)), "utf8"));

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log(`✔ ${name}`);
  } catch (error) {
    failures++;
    console.log(`✘ ${name}\n  ${error.stack}`);
  }
}

/** Runs a command, failing the test if the engine reports an error. */
function call(cmd, args = {}, payload) {
  const { response, payload: output } = engine.call({ cmd, ...args }, payload);
  if (!response.ok) throw new Error(`${cmd}: ${response.error}`);
  return { ...response, payload: output };
}

/** Every node in a scene, depth first. */
function nodes(scene) {
  const all = [];
  const visit = (node) => {
    all.push(node);
    for (const child of node.children ?? []) visit(child);
  };
  for (const node of [...scene.art, ...scene.shapes]) visit(node);
  return all;
}

const text = (body) => body.paras.map((p) => p.runs.map((r) => r.t).join("")).join("\n");

test("starts with strings and a locale", () => {
  call("init", { strings, locale: "en-US" });
});

test("makes a new presentation of one title slide", () => {
  const { result, state } = call("new", { name: "Untitled.pptx" });
  assert.equal(result.saveFormats[0].key, "pptx");
  assert.equal(state.slides.length, 1);
  assert.ok(result.layouts.length > 1, "has layouts");
  assert.ok(result.choices.shapes.length > 0, "offers shapes");
  assert.ok(Math.abs(result.size.w / result.size.h - 16 / 9) < 0.01, "is widescreen");
});

test("describes a slide's scene with prompts in empty placeholders", () => {
  const scene = call("scene", { editing: true }).result;
  assert.ok(scene.w > 0 && scene.h > 0);
  assert.ok(scene.bg, "has a background");
  const prompts = scene.shapes.filter((node) => node.prompt);
  assert.ok(prompts.length >= 1, "an empty title says to add one");
  assert.ok(prompts.every((node) => node.text?.paras.length >= 1), "placeholders take typing");
});

test("types into the title and undoes it", () => {
  const { state } = call("info");
  const scene = call("scene").result;
  const title = scene.shapes.find((node) => node.ph === "ctrTitle" || node.ph === "title");
  assert.ok(title, "has a title placeholder");
  call("select", { slide: state.slides[0].id, shapes: [title.id] });
  call("beginText", { shape: title.id });
  const typed = call("setText", { paras: [{ src: 0, runs: [{ t: "Hello, Dazzle" }] }] });
  assert.equal(typed.state.edited, true);
  assert.ok(typed.state.canUndo);
  const after = call("scene").result.shapes.find((node) => node.id === title.id);
  assert.equal(text(after.text), "Hello, Dazzle");
  // Typing more into the same shape is the same step to undo.
  call("setText", { paras: [{ src: 0, runs: [{ src: [0, 0], t: "Hello, Dazzle!" }] }] });
  call("undo");
  const undone = call("scene").result.shapes.find((node) => node.id === title.id);
  assert.ok(undone.prompt, "the title is empty again");
  call("redo");
});

test("formats the whole of the selected text", () => {
  const look = call("format", { set: { bold: true } }).result;
  assert.equal(look.bold, true);
});

test("adds slides, shapes, tables, charts and moves them", () => {
  const before = call("info").state.slides.length;
  const { result: info } = call("info");
  call("addSlide", { layout: info.layouts[1].path });
  const { state } = call("info");
  assert.equal(state.slides.length, before + 1);
  call("insertShape", { preset: "star5" });
  call("insertTable", { rows: 2, columns: 3 });
  call("insertChart", { kind: "pie" });
  call("insertTextBox");
  const scene = call("scene").result;
  const kinds = nodes(scene).map((node) => node.kind);
  assert.ok(kinds.includes("table"), "has a table");
  assert.ok(kinds.includes("chart"), "has a chart");
  const star = scene.shapes.find((node) => node.name.startsWith("Star") || node.path?.length > 40);
  assert.ok(star.path.startsWith("M"), "draws a preset outline as an SVG path");
  call("select", { shapes: [star.id] });
  call("setFrames", { frames: { [star.id]: { x: 10, y: 20, w: 100, h: 100, rot: 45 } } });
  const moved = call("scene").result.shapes.find((node) => node.id === star.id);
  assert.equal(moved.x, 10);
  assert.equal(moved.rot, 45);
  const chart = scene.shapes.find((node) => node.kind === "chart");
  assert.ok(chart.chart.some((item) => item.k === "path"), "a pie draws slices");
});

test("animates a shape and steps through it", () => {
  const scene = call("scene").result;
  const shape = scene.shapes.find((node) => node.kind === "shape");
  call("select", { shapes: [shape.id] });
  call("addAnimation", { category: "entr", effect: { name: "fly", direction: 4 } });
  const timeline = call("timeline").result;
  assert.equal(timeline.steps, 1);
  const hidden = call("frame", { begun: 0, elapsed: 0 }).result;
  assert.equal(hidden.shapes[shape.id].o, 0, "waits unseen for its tap");
  const halfway = call("frame", { begun: 1, elapsed: 0.25 }).result;
  assert.ok(halfway.shapes[shape.id]?.dy > 0, "flies in from below");
  const inspect = call("inspect").result;
  assert.equal(inspect.animations.length, 1);
});

test("finds and replaces text across slides", () => {
  const found = call("find", { text: "Dazzle" }).result;
  assert.ok(found.length >= 1);
  const replaced = call("replace", { text: "Dazzle", with: "the web" }).result;
  assert.equal(replaced, found.length);
});

test("copies a slide and pastes it after", () => {
  const before = call("info").state.slides.length;
  call("select", { shapes: [] });
  call("copy");
  call("paste");
  assert.equal(call("info").state.slides.length, before + 1);
});

test("saves as PowerPoint and reads it back", () => {
  const count = call("info").state.slides.length;
  const { payload, result } = call("save", { format: "pptx" });
  assert.equal(result.fileName, "Untitled.pptx");
  assert.ok(payload[0] === 0x50 && payload[1] === 0x4b, "is a ZIP file");
  const reopened = call("open", { name: "Again.pptx" }, payload);
  assert.equal(reopened.state.slides.length, count);
  const scene = call("scene", { slide: reopened.state.slides[0].id }).result;
  const title = scene.shapes.find((node) => node.ph === "ctrTitle" || node.ph === "title");
  assert.equal(text(title.text), "Hello, the web!");
  assert.equal(title.text.paras[0].runs[0].b, true, "kept the bold");
});

// MARK: - Drawing as the Apple apps do

/** A ZIP file's entries, by name. */
function unzip(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = bytes.length - 22;
  while (view.getUint32(end, true) !== 0x06054b50) end--;
  const entries = new Map();
  let offset = view.getUint32(end + 16, true);
  for (let index = 0; index < view.getUint16(end + 10, true); index++) {
    const method = view.getUint16(offset + 10, true);
    const size = view.getUint32(offset + 20, true);
    const nameLength = view.getUint16(offset + 28, true);
    const skip = nameLength + view.getUint16(offset + 30, true) + view.getUint16(offset + 32, true);
    const local = view.getUint32(offset + 42, true);
    const name = new TextDecoder().decode(bytes.subarray(offset + 46, offset + 46 + nameLength));
    const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
    const data = bytes.subarray(start, start + size);
    entries.set(name, method === 8 ? new Uint8Array(inflateRawSync(data)) : data);
    offset += 46 + skip;
  }
  return entries;
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (data) => (data.reduce((c, byte) => CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8), 0xffffffff) ^ 0xffffffff) >>> 0;

/** A ZIP file of `entries`, stored uncompressed. */
function zip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const [name, data] of entries) {
    const nameBytes = new TextEncoder().encode(name);
    const header = (size, signature) => {
      const buffer = new DataView(new ArrayBuffer(size));
      buffer.setUint32(0, signature, true);
      return buffer;
    };
    const local = header(30, 0x04034b50);
    local.setUint16(4, 20, true);
    local.setUint32(14, crc32(data), true);
    local.setUint32(18, data.length, true);
    local.setUint32(22, data.length, true);
    local.setUint16(26, nameBytes.length, true);
    const central = header(46, 0x02014b50);
    central.setUint16(4, 20, true);
    central.setUint16(6, 20, true);
    central.setUint32(16, crc32(data), true);
    central.setUint32(20, data.length, true);
    central.setUint32(24, data.length, true);
    central.setUint16(28, nameBytes.length, true);
    central.setUint32(42, offset, true);
    locals.push(new Uint8Array(local.buffer), nameBytes, data);
    centrals.push(new Uint8Array(central.buffer), nameBytes);
    offset += 30 + nameBytes.length + data.length;
  }
  const size = centrals.reduce((sum, part) => sum + part.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, entries.size, true);
  end.setUint16(10, entries.size, true);
  end.setUint32(12, size, true);
  end.setUint32(16, offset, true);
  return Buffer.concat([...locals, ...centrals, new Uint8Array(end.buffer)]);
}

// A one-pixel PNG, for a tiled picture fill.
const PIXEL = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==", "base64");

/** The presentation saved above, with shapes added to its first slide that use what each test checks. */
function deckWithShapes() {
  const { payload } = call("save", { format: "pptx" });
  const entries = unzip(payload);
  const decode = (name) => new TextDecoder().decode(entries.get(name));
  const encode = (name, text) => entries.set(name, new TextEncoder().encode(text));
  const frame = (x) => `<a:xfrm><a:off x="${x}" y="914400"/><a:ext cx="1828800" cy="1371600"/></a:xfrm>`;
  const shapes = `
    <p:sp><p:nvSpPr><p:cNvPr id="901" name="Lined"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(457200)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
        <a:ln w="76200" cap="rnd" cmpd="dbl"><a:gradFill><a:gsLst>
          <a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs><a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs>
        </a:gsLst><a:lin ang="0"/></a:gradFill><a:bevel/></a:ln></p:spPr>
      <p:txBody><a:bodyPr/><a:p><a:r><a:rPr lang="en-US" spc="300"><a:latin typeface="Calibri"/></a:rPr><a:t>Spaced</a:t></a:r></a:p></p:txBody>
    </p:sp>
    <p:sp><p:nvSpPr><p:cNvPr id="902" name="Tiled"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(2743200)}<a:prstGeom prst="cloudCallout"><a:avLst/></a:prstGeom>
        <a:blipFill><a:blip r:embed="rIdTile"/><a:tile tx="12700" ty="25400" sx="50000" sy="25000" flip="xy" algn="ctr"/></a:blipFill>
        <a:ln w="12700"><a:solidFill><a:srgbClr val="000000"/></a:solidFill></a:ln></p:spPr>
    </p:sp>`;
  const slide = decode("ppt/slides/slide1.xml");
  const root = slide.includes("xmlns:r=") ? slide : slide.replace("<p:sld ", '<p:sld xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ');
  encode("ppt/slides/slide1.xml", root.replace("</p:spTree>", `${shapes}</p:spTree>`));
  const relsName = "ppt/slides/_rels/slide1.xml.rels";
  encode(relsName, decode(relsName).replace("</Relationships>",
    '<Relationship Id="rIdTile" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/tile.png"/></Relationships>'));
  entries.set("ppt/media/tile.png", PIXEL);
  const types = decode("[Content_Types].xml");
  if (!/Extension="png"/i.test(types)) encode("[Content_Types].xml", types.replace("<Default ", '<Default Extension="png" ContentType="image/png"/><Default '));
  return zip(entries);
}

const drawn = (() => {
  try {
    const opened = call("open", { name: "Shapes.pptx" }, deckWithShapes());
    const shapes = call("scene", { slide: opened.state.slides[0].id }).result.shapes;
    return { info: opened.result, lined: shapes.find((node) => node.name === "Lined"), tiled: shapes.find((node) => node.name === "Tiled") };
  } catch (error) {
    return { error };
  }
})();

test("strokes a gradient outline with its caps, joins and compound strokes", () => {
  if (drawn.error) throw drawn.error;
  const line = drawn.lined.line;
  assert.equal(line.paint?.t, "linear", "the gradient is laid over the line");
  assert.equal(line.c, "#ff0000", "its first colour stands in where only one will do");
  assert.ok(line.box.w > drawn.lined.w, "across the line's bounds");
  assert.equal(line.cap, "round");
  assert.equal(line.join, "bevel");
  assert.equal(line.bands?.length, 2, "a double line is two strokes");
  assert.ok(line.bands.every((band) => Math.abs(band.w - 2) < 0.01), "each a third of the 6pt width");
});

test("spaces characters as the run says", () => {
  if (drawn.error) throw drawn.error;
  assert.equal(drawn.lined.text.paras[0].runs[0].sp, 3, "spc is hundredths of a point");
});

test("lays tiles by their scale, offset, flip and alignment", () => {
  if (drawn.error) throw drawn.error;
  const tile = drawn.tiled.fill?.tile;
  assert.ok(tile, "is a tiled picture");
  assert.deepEqual([tile.sx, tile.sy, tile.tx, tile.ty, tile.flip, tile.ax, tile.ay], [0.5, 0.25, 1, 2, "xy", 0.5, 0.5]);
});

test("fills a cloud callout as one and strokes its puffs", () => {
  if (drawn.error) throw drawn.error;
  assert.equal(drawn.tiled.rule, "nonzero", "bubbles overlapping the cloud don't cut holes");
  assert.ok(drawn.tiled.strokePath?.length > drawn.tiled.path.length, "the puffs' inner curves are stroked too");
});

test("names the typefaces the presentation doesn't carry", () => {
  if (drawn.error) throw drawn.error;
  assert.ok(drawn.info.typefaces.includes("Calibri"));
});

/** Protocol buffer fields, for building a Keynote archive. */
class Proto {
  bytes = [];
  static varint(value) {
    const out = [];
    do {
      let byte = value % 128;
      value = Math.floor(value / 128);
      if (value) byte |= 0x80;
      out.push(byte);
    } while (value);
    return out;
  }
  varint(field, value) { this.bytes.push(...Proto.varint(field * 8), ...Proto.varint(value)); return this; }
  float(field, value) {
    const buffer = new DataView(new ArrayBuffer(4));
    buffer.setFloat32(0, value, true);
    this.bytes.push(...Proto.varint(field * 8 + 5), ...new Uint8Array(buffer.buffer));
    return this;
  }
  double(field, value) {
    const buffer = new DataView(new ArrayBuffer(8));
    buffer.setFloat64(0, value, true);
    this.bytes.push(...Proto.varint(field * 8 + 1), ...new Uint8Array(buffer.buffer));
    return this;
  }
  data(field, bytes) { this.bytes.push(...Proto.varint(field * 8 + 2), ...Proto.varint(bytes.length), ...bytes); return this; }
  string(field, text) { return this.data(field, [...new TextEncoder().encode(text)]); }
  message(field, build) { const nested = new Proto(); build(nested); return this.data(field, nested.bytes); }
  reference(field, id) { return this.message(field, (m) => m.varint(1, id)); }
}

/** An `.iwa` of `objects`, as one snappy chunk of literals. */
function iwa(objects) {
  const stream = [];
  for (const [id, type, message] of objects) {
    const info = new Proto().varint(1, id).message(2, (m) => m.varint(1, type).varint(3, message.bytes.length));
    stream.push(...Proto.varint(info.bytes.length), ...info.bytes, ...message.bytes);
  }
  const block = [...Proto.varint(stream.length)];
  for (let offset = 0; offset < stream.length; offset += 65536) {
    const length = Math.min(65536, stream.length - offset);
    block.push(61 << 2, (length - 1) & 0xff, (length - 1) >> 8, ...stream.slice(offset, offset + length));
  }
  return Uint8Array.from([0, block.length & 0xff, (block.length >> 8) & 0xff, block.length >> 16, ...block]);
}

/** A Keynote deck of three charts: mixed columns and a line, bubbles, and a kind Keynote may add later. */
function keynoteCharts() {
  const types = [10, 22, 99];
  const objects = [
    [1, 1, new Proto().reference(2, 2)],
    [2, 2, new Proto()
      .message(3, (tree) => types.forEach((_, index) => tree.reference(2, 100 + index * 10)))
      .message(4, (size) => size.float(1, 1024).float(2, 768))],
    [50, 5030, new Proto().message(10000, (m) => m.varint(26, 1))],
    [51, 5030, new Proto().message(10000, (m) => m.varint(26, 3))],
  ];
  types.forEach((type, index) => {
    const node = 100 + index * 10;
    objects.push([node, 4, new Proto().reference(2, node + 1)]);
    objects.push([node + 1, 5, new Proto().reference(42, node + 2)]);
    objects.push([node + 2, 5021, new Proto()
      .message(1, (d) => d.message(1, (g) => g
        .message(1, (p) => p.float(1, 100).float(2, 100))
        .message(2, (s) => s.float(1, 600).float(2, 400))
        .varint(3, 3)))
      .message(10000, (info) => {
        info.varint(1, type).varint(5, 2).message(7, (grid) => {
          grid.string(1, "One").string(1, "Two");
          for (const name of ["A", "B", "C"]) grid.string(2, name);
          for (const row of [[1, 2, 3], [4, 5, 6]]) grid.message(3, (r) => row.forEach((v) => r.message(1, (c) => c.double(1, v))));
        });
        if (type === 10) {
          info.message(19, (array) => [[0, 50], [1, 51], [2, 51]].forEach(([series, style]) =>
            array.message(2, (entry) => entry.varint(1, series).reference(2, style))));
        }
      })]);
  });
  return zip(new Map([["Index/Document.iwa", iwa(objects)]]));
}

test("draws every Keynote chart it reads, and a stand-in for one it can't", () => {
  const opened = call("open", { name: "Charts.key" }, keynoteCharts());
  const [mixed, bubbles, unknown] = opened.state.slides.map((slide) => call("scene", { slide: slide.id }).result.shapes[0]);
  assert.equal(mixed.kind, "chart");
  assert.ok(mixed.chart.length > 0, "the mixed chart is drawn");
  assert.equal(bubbles.kind, "chart");
  assert.ok(bubbles.chart.length > 0, "the bubbles are drawn as points");
  assert.equal(unknown.kind, "standin");
  assert.equal(unknown.isChart, true);
  assert.ok(unknown.w > 0 && unknown.h > 0, "the stand-in keeps the chart's place");
  assert.deepEqual(opened.result.omissions, [strings["Notice.Omission.ChartStandIns"] ?? opened.result.omissions[0]]);
  assert.ok(!opened.result.omissions[0].includes("Notice."), "the omission is worded");
  assert.deepEqual(opened.result.unsupported, []);
  for (const format of opened.result.saveFormats.map((f) => f.key)) {
    const saved = call("save", { format, keep: true });
    const reopened = call("open", { name: `Charts.${format}` }, saved.payload);
    assert.equal(reopened.state.slides.length, 3, `saved as ${format}`);
  }
});

for (const path of process.argv.slice(2)) {
  try {
    const bytes = new Uint8Array(await readFile(path));
    const opened = call("open", { name: basename(path) }, bytes);
    let shapes = 0;
    for (const slide of opened.state.slides) shapes += nodes(call("scene", { slide: slide.id }).result).length;
    const saved = call("save", { format: opened.result.saveFormats[0].key, keep: true });
    console.log(`  ${opened.state.slides.length} slides, ${shapes} shapes, saved ${saved.payload.length} bytes`);
  } catch (error) {
    failures++;
    console.log(`✘ ${basename(path)}\n  ${error.stack}`);
  }
}

if (failures) {
  console.log(`${failures} failed`);
  process.exit(1);
}
console.log("All passed");
