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
import { bandForLine, letterTransform, placement, warpBands, warpPoint } from "../../app/warp.js";
import { COLUMN_LIMIT, INITIAL_GRID, LARGEST_GRID, ROW_LIMIT, TableSizeSelection, cellAt } from "../../app/table-size.js";

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

test("the table size picker keeps sizes within limits and grows its grid", () => {
  const size = new TableSizeSelection();
  assert.deepEqual([size.rows, size.columns, size.gridRows, size.gridColumns], [3, 3, INITIAL_GRID.rows, INITIAL_GRID.columns]);
  size.select(1, 3);
  assert.deepEqual([size.rows, size.columns], [2, 4]);
  assert.ok(size.contains(1, 3) && !size.contains(2, 3) && !size.contains(1, 4));
  size.select(4, 5);
  assert.deepEqual([size.gridRows, size.gridColumns], [6, 7], "keeps a spare row and column");
  size.select(0, 0);
  assert.deepEqual([size.gridRows, size.gridColumns], [6, 7], "doesn't shrink back");
  size.select(40, 40);
  assert.deepEqual([size.rows, size.columns, size.gridRows], [LARGEST_GRID.rows, LARGEST_GRID.columns, LARGEST_GRID.rows]);
  size.set({ rows: 500, columns: "500" }).move("down").move("right");
  assert.deepEqual([size.rows, size.columns], [ROW_LIMIT.max, COLUMN_LIMIT.max]);
  size.set({ rows: 0, columns: "" }).move("up").move("left");
  assert.deepEqual([size.rows, size.columns], [1, 1]);
  assert.equal(cellAt(-1, 4, 20), null);
  assert.deepEqual(cellAt(45, 5, 20), { row: 0, column: 2 });
  assert.deepEqual(cellAt(5000, 5000, 20), { row: LARGEST_GRID.rows - 1, column: LARGEST_GRID.columns - 1 });
  for (const key of ["Table.Size", "Table.Size.Spoken", "Table.Columns", "Table.Rows", "Table.Insert", "Table.Picker.Grid", "Table.Picker.Hint"]) {
    assert.ok(strings[key], `has the string ${key}`);
  }
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

test("attaches a connector to a shape, which then takes it along", () => {
  call("insertShape", { preset: "rect" });
  const box = call("scene").result.shapes.at(-1);
  call("setFrames", { frames: { [box.id]: { x: 300, y: 200, w: 100, h: 60 } } });
  call("insertShape", { preset: "bentConnector3" });
  const connector = call("scene").result.shapes.at(-1);
  assert.ok(connector.ends, "a connector says where its ends are");
  const left = call("connectionSites").result.find((site) => site.x === 300 && site.y === 230);
  assert.ok(left, "the box has a site in the middle of its left side");
  call("setConnectorEnd", { id: connector.id, end: "end", x: 0, y: 0, shape: left.shape, site: left.site });
  let ends = call("scene").result.shapes.find((node) => node.id === connector.id).ends;
  assert.ok(ends.end.attached && !ends.start.attached);
  assert.equal(ends.end.x, 300);
  call("setFrames", { frames: { [box.id]: { x: 340, y: 260, w: 100, h: 60 } } });
  ends = call("scene").result.shapes.find((node) => node.id === connector.id).ends;
  assert.equal(ends.end.x, 340);
  assert.equal(ends.end.y, 290);
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

/** A picture of the one-pixel PNG whose blip carries `effects`. */
function picture(id, name, x, effects) {
  return `<p:pic><p:nvPicPr><p:cNvPr id="${id}" name="${name}"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
    <p:blipFill><a:blip r:embed="rIdTile">${effects}</a:blip><a:stretch><a:fillRect/></a:stretch></p:blipFill>
    <p:spPr><a:xfrm><a:off x="${x}" y="914400"/><a:ext cx="1371600" cy="1371600"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>`;
}

/** Office 2010's artistic effects on a picture, on an original picture kept apart when `layer` names one. */
function artistic(layer, ...effects) {
  return `<a:extLst><a:ext uri="{BEBA8EAE-BF5A-486C-A8C5-ECC9F3942E4B}">
    <a14:imgProps xmlns:a14="http://schemas.microsoft.com/office/drawing/2010/main"><a14:imgLayer${layer}>
    ${effects.map((effect) => `<a14:imgEffect>${effect}</a14:imgEffect>`).join("")}
    </a14:imgLayer></a14:imgProps></a:ext></a:extLst>`;
}

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
    </p:sp>
    <p:sp><p:nvSpPr><p:cNvPr id="903" name="Patterned"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(5029200)}<a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>
        <a:pattFill prst="dkUpDiag"><a:fgClr><a:srgbClr val="FF0000"/></a:fgClr><a:bgClr><a:srgbClr val="FFFF00"/></a:bgClr></a:pattFill>
        <a:ln w="38100"><a:pattFill prst="smCheck"><a:fgClr><a:srgbClr val="00FF00"/></a:fgClr><a:bgClr><a:srgbClr val="000000"/></a:bgClr></a:pattFill></a:ln></p:spPr>
    </p:sp>
    <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="904" name="Grid"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
      <p:xfrm><a:off x="457200" y="3200400"/><a:ext cx="1828800" cy="740664"/></p:xfrm>
      <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr/>
        <a:tblGrid><a:gridCol w="914400"/><a:gridCol w="914400"/></a:tblGrid>
        <a:tr h="370332"><a:tc><a:txBody><a:bodyPr/><a:p><a:endParaRPr lang="en-US"/></a:p></a:txBody>
          <a:tcPr><a:pattFill prst="lgGrid"><a:fgClr><a:srgbClr val="0000FF"/></a:fgClr><a:bgClr><a:srgbClr val="FFFFFF"/></a:bgClr></a:pattFill></a:tcPr></a:tc>
          <a:tc><a:txBody><a:bodyPr/><a:p><a:endParaRPr lang="en-US"/></a:p></a:txBody><a:tcPr/></a:tc></a:tr>
      </a:tbl></a:graphicData></a:graphic></p:graphicFrame>
    ${["cube", "gear6", "bracePair"].map((prst, index) => `
    <p:sp><p:nvSpPr><p:cNvPr id="${905 + index}" name="${prst}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(457200 + index * 2286000)}<a:prstGeom prst="${prst}"><a:avLst/></a:prstGeom>
        <a:solidFill><a:srgbClr val="3366CC"/></a:solidFill>
        <a:ln w="12700"><a:solidFill><a:srgbClr val="000000"/></a:solidFill></a:ln></p:spPr>
    </p:sp>`).join("")}
    ${gradientShapes(frame)}
    ${picture(920, "Recoloured", 4572000, `
      <a:clrChange><a:clrFrom><a:srgbClr val="FFFFFF"/></a:clrFrom><a:clrTo><a:srgbClr val="FFFFFF"><a:alpha val="0"/></a:srgbClr></a:clrTo></a:clrChange>
      <a:biLevel thresh="50000"/><a:hsl hue="7200000" sat="0" lum="0"/><a:tint hue="14400000" amt="50000"/>
      ${artistic("", '<a14:artisticPencilSketch trans="20000" pressure="40"/>', '<a14:saturation sat="0"/>')}`)}
    ${picture(921, "Stylised", 6400800, artistic(' r:embed="rIdTile"', '<a14:artisticWatercolorSponge brushSize="4"/>'))}
    <p:sp><p:nvSpPr><p:cNvPr id="930" name="Columned"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(5029200)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>
      <p:txBody><a:bodyPr wrap="square" numCol="3" spcCol="457200" rtlCol="1"><a:normAutofit/></a:bodyPr><a:lstStyle/>
        <a:p><a:r><a:rPr lang="en-US"/><a:t>First</a:t></a:r></a:p><a:p><a:r><a:rPr lang="en-US"/><a:t>Second</a:t></a:r></a:p></p:txBody>
    </p:sp>
    <p:sp><p:nvSpPr><p:cNvPr id="931" name="Tabbed"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(5029200)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
      <p:txBody><a:bodyPr/><a:lstStyle><a:lvl1pPr defTabSz="457200"/></a:lstStyle>
        <a:p><a:pPr><a:tabLst><a:tab pos="1828800" algn="dec"/><a:tab pos="914400" algn="ctr"/></a:tabLst></a:pPr>
          <a:r><a:rPr lang="en-US"/><a:t>Item\tMiddle\t12.5</a:t></a:r></a:p>
        <a:p><a:pPr marL="342900" indent="-342900"><a:buChar char="•"/><a:tabLst><a:tab pos="114300"/><a:tab pos="1371600" algn="r"/></a:tabLst></a:pPr>
          <a:r><a:rPr lang="en-US"/><a:t>Bullet\tRight</a:t></a:r></a:p>
        <a:p><a:r><a:rPr lang="en-US"/><a:t>No tabs</a:t></a:r></a:p>
      </p:txBody>
    </p:sp>
    <p:sp><p:nvSpPr><p:cNvPr id="932" name="Vertical"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(5029200)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>
      <p:txBody><a:bodyPr vert="eaVert"><a:spAutoFit/></a:bodyPr><a:p><a:r><a:rPr lang="ja-JP"/><a:t>縦書きText</a:t></a:r></a:p></p:txBody>
    </p:sp>
    <p:sp><p:nvSpPr><p:cNvPr id="933" name="RightToLeft"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(5029200)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>
      <p:txBody><a:bodyPr/><a:lstStyle/>
        <a:p><a:pPr marL="342900" indent="-342900" algn="r" rtl="1"><a:buChar char="•"/></a:pPr>
          <a:r><a:rPr lang="ar-SA"><a:latin typeface="Georgia"/><a:cs typeface="Damascus"/></a:rPr><a:t>مرحبا Dazzle</a:t></a:r>
          <a:r><a:rPr lang="en-US"><a:latin typeface="Georgia"/><a:cs typeface="Damascus"/></a:rPr><a:t> 2024</a:t></a:r></a:p>
        <a:p><a:pPr rtl="0"/><a:r><a:rPr lang="en-US"/><a:t>Left to right</a:t></a:r></a:p>
      </p:txBody>
    </p:sp>
    ${wordArtShapes(frame)}`;
  const background = '<p:bg><p:bgPr><a:pattFill prst="pct20"><a:fgClr><a:srgbClr val="333333"/></a:fgClr><a:bgClr><a:srgbClr val="EEEEEE"/></a:bgClr></a:pattFill><a:effectLst/></p:bgPr></p:bg>';
  const slide = decode("ppt/slides/slide1.xml");
  const root = slide.includes("xmlns:r=") ? slide : slide.replace("<p:sld ", '<p:sld xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ');
  encode("ppt/slides/slide1.xml", root.replace(/<p:bg>.*?<\/p:bg>/s, "").replace(/<p:cSld(\s[^>]*)?>/, (tag) => tag + background)
    .replace("</p:spTree>", `${shapes}</p:spTree>`));
  const relsName = "ppt/slides/_rels/slide1.xml.rels";
  encode(relsName, decode(relsName).replace("</Relationships>",
    '<Relationship Id="rIdTile" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/tile.png"/></Relationships>'));
  entries.set("ppt/media/tile.png", PIXEL);
  const types = decode("[Content_Types].xml");
  if (!/Extension="png"/i.test(types)) encode("[Content_Types].xml", types.replace("<Default ", '<Default Extension="png" ContentType="image/png"/><Default '));
  return zip(entries);
}

/** WordArt warped along an arch and a wave, and text that says it has no warp. */
function wordArtShapes(frame) {
  const warps = {
    Arched: '<a:prstTxWarp prst="textArchUp"><a:avLst><a:gd name="adj" fmla="val 12000000"/></a:avLst></a:prstTxWarp>',
    Waved: '<a:prstTxWarp prst="textWave1"><a:avLst><a:gd name="adj1" fmla="val 20000"/><a:gd name="adj2" fmla="val 0"/></a:avLst></a:prstTxWarp>',
    Unwarped: '<a:prstTxWarp prst="textNoShape"><a:avLst/></a:prstTxWarp>',
  };
  return Object.entries(warps).map(([name, warp], index) => `
    <p:sp><p:nvSpPr><p:cNvPr id="${940 + index}" name="${name}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(457200 + 2286000 * index)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>
      <p:txBody><a:bodyPr wrap="none">${warp}</a:bodyPr><a:lstStyle/>
        <a:p><a:r><a:rPr lang="en-US" sz="3600"/><a:t>${name}</a:t></a:r></a:p><a:p><a:r><a:rPr lang="en-US" sz="3600"/><a:t>Two</a:t></a:r></a:p></p:txBody>
    </p:sp>`).join("");
}

/** Shapes filled with each kind of path gradient, and a scaled linear one, named for what they hold. */
function gradientShapes(frame) {
  const stops = '<a:gsLst><a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs><a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs></a:gsLst>';
  const fills = {
    "Rect gradient": `<a:path path="rect"><a:fillToRect l="25000" t="25000" r="25000" b="25000"/></a:path>`,
    "Shape gradient": `<a:path path="shape"><a:fillToRect l="50000" t="50000" r="50000" b="50000"/></a:path>`,
    "Circle gradient": `<a:path path="circle"><a:fillToRect r="100000" b="100000"/></a:path><a:tileRect l="-100000" t="-100000"/>`,
    "Scaled gradient": `<a:lin ang="2700000" scaled="1"/>`,
  };
  return Object.entries(fills).map(([name, shade], index) => `
    <p:sp><p:nvSpPr><p:cNvPr id="${910 + index}" name="${name}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr>${frame(457200 + 2286000 * index)}<a:prstGeom prst="${name === "Shape gradient" ? "ellipse" : "rect"}"><a:avLst/></a:prstGeom>
        <a:gradFill rotWithShape="1">${stops}${shade}</a:gradFill></p:spPr>
    </p:sp>`).join("");
}

const drawn = (() => {
  try {
    const opened = call("open", { name: "Shapes.pptx" }, deckWithShapes());
    const scene = call("scene", { slide: opened.state.slides[0].id }).result;
    const shapes = scene.shapes;
    const named = (name) => shapes.find((node) => node.name === name);
    return {
      info: opened.result, shapes, slide: opened.state.slides[0].id, scene,
      lined: named("Lined"), tiled: named("Tiled"), patterned: named("Patterned"), grid: named("Grid"),
      cube: named("cube"), gear: named("gear6"), braces: named("bracePair"),
      recoloured: named("Recoloured"), stylised: named("Stylised"),
      columned: named("Columned"), tabbed: named("Tabbed"), vertical: named("Vertical"), rightToLeft: named("RightToLeft"),
      arched: named("Arched"), waved: named("Waved"), unwarped: named("Unwarped"),
    };
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

test("draws pattern fills on shapes, outlines, table cells and the background, and keeps them on save", () => {
  if (drawn.error) throw drawn.error;
  const fill = drawn.patterned.fill;
  assert.equal(fill?.t, "pattern", "the shape is patterned, not solid");
  assert.deepEqual([fill.fg, fill.bg, fill.cell], ["#ff0000", "#ffff00", 0.75]);
  assert.deepEqual(fill.rows, [0x33, 0x66, 0xcc, 0x99, 0x33, 0x66, 0xcc, 0x99], "dark upward diagonal cells, top row first");
  assert.equal(drawn.patterned.line.paint?.t, "pattern", "the outline is patterned too");
  assert.equal(drawn.patterned.line.c, "#00ff00", "its foreground stands in where only one colour will do");
  assert.deepEqual([drawn.scene.bg.t, drawn.scene.bg.fg, drawn.scene.bg.bg], ["pattern", "#333333", "#eeeeee"]);
  const cell = drawn.grid.table.cells.find((c) => c.r === 0 && c.c === 0);
  assert.deepEqual([cell.fill?.t, cell.fill?.fg], ["pattern", "#0000ff"]);

  // The inspector shows it as a pattern, and recolouring keeps the preset.
  call("select", { slide: drawn.slide, shapes: [drawn.patterned.id] });
  const inspected = call("inspect").result;
  assert.deepEqual([inspected.shape.fill.kind, inspected.shape.fill.preset, inspected.shape.fill.background], ["pattern", "dkUpDiag", "#ffff00"]);
  assert.deepEqual([inspected.slide.background.kind, inspected.slide.background.preset], ["pattern", "pct20"]);
  call("setFill", { fill: { kind: "pattern", preset: "dkUpDiag", color: "#00ff00", background: "#ffff00" } });
  const recoloured = call("scene", { slide: drawn.slide }).result.shapes.find((node) => node.name === "Patterned");
  assert.deepEqual([recoloured.fill.t, recoloured.fill.fg, recoloured.fill.rows[0]], ["pattern", "#00ff00", 0x33]);

  const saved = unzip(call("save", { format: "pptx", keep: true }).payload);
  const slide = new TextDecoder().decode(saved.get("ppt/slides/slide1.xml"));
  assert.ok(/<a:pattFill prst="dkUpDiag"><a:fgClr><a:srgbClr val="00FF00"\/><\/a:fgClr><a:bgClr><a:srgbClr val="FFFF00"\/>/.test(slide), "the recoloured shape");
  for (const preset of ["smCheck", "lgGrid", "pct20"]) assert.ok(slide.includes(`<a:pattFill prst="${preset}">`), `keeps ${preset}`);
});

test("draws the presets ECMA-376 defines rather than their frames", () => {
  if (drawn.error) throw drawn.error;
  assert.ok(drawn.gear.path.split("L").length > 20, "a gear has teeth");
  assert.ok(!drawn.gear.path.startsWith("M0 0L"), "not the frame's rectangle");
  assert.deepEqual(drawn.cube.shades?.map((shade) => shade.c), ["#000", "#fff"], "the side darkened, the top lightened");
  assert.ok(drawn.cube.shades.every((shade) => shade.d.length > 0 && shade.o > 0 && shade.o < 1));
  assert.ok(drawn.cube.strokePath?.length > 0, "the outline and edges are stroked apart from the faces");
  assert.equal(drawn.braces.open, true, "a brace pair is never filled");
  assert.equal(drawn.braces.fill, undefined);
  assert.ok(drawn.braces.path.includes("C"), "its braces curve");
});

test("names the typefaces the presentation doesn't carry", () => {
  if (drawn.error) throw drawn.error;
  assert.ok(drawn.info.typefaces.includes("Calibri"));
});

test("passes vertical text to the page to set in vertical lines", () => {
  if (drawn.error) throw drawn.error;
  assert.equal(drawn.vertical.text.vert, "eaVert");
});

test("grows vertical text across as it is typed, leftwards from its first line on the right", () => {
  if (drawn.error) throw drawn.error;
  const before = drawn.vertical;
  call("select", { slide: drawn.slide, shapes: [before.id] });
  call("beginText", { shape: before.id });
  call("setText", { paras: [{ src: 0, runs: [{ t: "縦書きText" }] }, { src: 0, runs: [{ t: "二行目" }] }], width: before.w + 40 });
  call("endText");
  const after = call("scene", { slide: drawn.slide }).result.shapes.find((node) => node.name === "Vertical");
  assert.ok(Math.abs(after.w - (before.w + 40)) < 0.5, "as wide as the page measured it");
  assert.ok(Math.abs(after.x + after.w - (before.x + before.w)) < 0.5, "its right side stays put");
  assert.equal(after.h, before.h, "as tall as before");
});

test("sets text in the columns its body asks for, and keeps them when typed into and saved", () => {
  if (drawn.error) throw drawn.error;
  const body = drawn.columned.text;
  assert.equal(body.cols, 3);
  assert.equal(body.colGap, 36, "spcCol is EMU");
  assert.equal(body.rtlCols, true);
  assert.equal(body.fit, "shrink");
  assert.equal(drawn.lined.text.cols, undefined, "one column says nothing");

  call("select", { shapes: [drawn.columned.id] });
  call("beginText", { shape: drawn.columned.id });
  call("setText", { paras: [{ src: 0, runs: [{ t: "Typed" }] }, { src: 1, runs: [{ t: "Into" }] }] });
  call("endText");
  const slide = new TextDecoder().decode(unzip(call("save", { format: "pptx", keep: true }).payload).get("ppt/slides/slide1.xml"));
  const columned = slide.slice(slide.indexOf('name="Columned"'));
  assert.match(columned, /<a:bodyPr[^>]*numCol="3"/);
  assert.match(columned, /<a:bodyPr[^>]*spcCol="457200"/);
  assert.match(columned, /<a:t>Typed<\/a:t>/);
});

test("recolours pictures and applies the artistic effects still to be applied", () => {
  if (drawn.error) throw drawn.error;
  const fx = drawn.recoloured.fx;
  assert.deepEqual(fx.change.from, [1, 1, 1, 1], "the colour change starts from white");
  assert.equal(fx.change.to[3], 0, "and makes it transparent");
  assert.ok(fx.change.tol > 0, "near colours too");
  assert.equal(fx.biLevel, 0.5);
  assert.equal(fx.hsl.length, 20, "hue, saturation and luminance as a colour matrix");
  assert.ok(fx.hsl[5] > fx.hsl[0] && fx.hsl[5] > fx.hsl[10], "a third of the way round makes red green");
  assert.deepEqual(fx.tint.c.map((value) => Math.round(value * 255)), [0, 0, 255, 255], "the tint's hue is blue");
  assert.equal(fx.tint.amt, 0.5);
  assert.deepEqual(fx.art.map((art) => art.k), ["sketch", "matrix"], "a sketch, then saturation");
  assert.equal(fx.art[0].trans, 0.2);
  assert.ok(Math.abs(fx.art[1].m[0] - 0.213) < 0.001, "no saturation is grey");
  assert.equal(drawn.stylised.fx?.art, undefined, "a picture Office already drew its effects on is shown as it is");
});

test("saves picture effects as they were read", () => {
  if (drawn.error) throw drawn.error;
  // Cropping rewrites the picture's blip fill, around its effects.
  const { recoloured } = drawn;
  call("setCrop", { shape: recoloured.id, crop: [0.1, 0, 0, 0], frame: { x: recoloured.x, y: recoloured.y, w: recoloured.w, h: recoloured.h } });
  const entries = unzip(call("save", { format: "pptx" }).payload);
  const xml = new TextDecoder().decode(entries.get("ppt/slides/slide1.xml"));
  assert.match(xml, /<a:srcRect l="10000"/, "the crop was written");
  for (const part of [/<a:clrChange>.*<a:alpha val="0"\/>/s, /<a:biLevel thresh="50000"/, /<a:hsl hue="7200000"/, /<a:tint amt="50000" hue="14400000"/,
    /<a14:artisticPencilSketch[^>]*pressure="40"/, /<a14:imgLayer r:embed="rIdTile">\s*<a14:imgEffect><a14:artisticWatercolorSponge/]) {
    assert.match(xml, part);
  }
  assert.equal(xml.match(/<a:clrChange>/g).length, 1, "once");
});

test("draws path gradients from fillToRect to their tile, and scaled linear ones", () => {
  if (drawn.error) throw drawn.error;
  const fill = (name) => drawn.shapes.find((node) => node.name === name)?.fill;
  const rect = fill("Rect gradient");
  assert.equal(rect?.t, "rect");
  assert.deepEqual(rect.focus, [0.25, 0.25, 0.25, 0.25]);
  assert.deepEqual([rect.from, rect.to], ["#ff0000", "#0000ff"], "from its first colour inside fillToRect to its last at the edges");
  const shape = fill("Shape gradient");
  assert.equal(shape?.t, "shape");
  assert.deepEqual([shape.rings[0], shape.rings.at(-1)], ["#0000ff", "#ff0000"], "outline copies from the edge in to the centre");
  const circle = fill("Circle gradient");
  assert.equal(circle?.t, "radial");
  assert.deepEqual([circle.focus, circle.tile], [[0, 0, 1, 1], [-1, -1, 0, 0]], "from the top-left corner");
  const scaled = fill("Scaled gradient");
  assert.deepEqual([scaled?.t, scaled?.angle, scaled?.scaled], ["linear", 45, true]);
});

test("reads right-to-left paragraphs from the right, their complex scripts in their own typeface, and saves both", () => {
  if (drawn.error) throw drawn.error;
  const [arabic, latin] = drawn.rightToLeft.text.paras;
  assert.equal(arabic.rtl, true);
  assert.equal(arabic.align, "r", "left and right stay as the file names them");
  assert.equal(arabic.ml, 27, "the margin, measured from the right");
  assert.equal(arabic.bullet.t, "•");
  assert.deepEqual([arabic.runs[0].f, arabic.runs[0].cs], ["Georgia", "Damascus"], "Arabic takes the run's complex-script typeface");
  assert.equal(arabic.runs[1].cs, undefined, "a run with no complex script says nothing");
  assert.equal(latin.rtl, undefined);
  assert.equal(latin.align, "l");

  call("select", { slide: drawn.slide, shapes: [drawn.rightToLeft.id] });
  call("beginText", { shape: drawn.rightToLeft.id });
  call("setText", { paras: [
    { src: 0, runs: [{ src: [0, 0], t: "أهلا Dazzle" }, { src: [0, 1], t: " 2024" }] },
    { src: 1, runs: [{ src: [1, 0], t: "Left to right" }] },
  ] });
  call("endText");
  const slide = new TextDecoder().decode(unzip(call("save", { format: "pptx", keep: true }).payload).get("ppt/slides/slide1.xml"));
  assert.match(slide, /أهلا Dazzle/, "the typed text is saved");
  assert.match(slide, /<a:pPr[^>]*rtl="1"/);
  assert.match(slide, /<a:cs typeface="Damascus"\/>/);
});

test("sets tabbed text on its stops and the default tab size, and saves them", () => {
  if (drawn.error) throw drawn.error;
  const [stops, bulleted, plain] = drawn.tabbed.text.paras;
  assert.deepEqual(stops.tabs, [[0, "l"], [72, "ctr"], [144, "dec"]], "in order along the line, with the margin's");
  assert.equal(stops.dts, 36, "the default tab size comes from the list style");
  assert.deepEqual(bulleted.tabs, [[27, "l"], [108, "r"]], "the bullet's tab still reaches the margin");
  assert.equal(plain.tabs, undefined, "only tabbed paragraphs are laid out by stop");

  // Typed into, the paragraphs are written again, their stops with them.
  call("select", { slide: drawn.slide, shapes: [drawn.tabbed.id] });
  call("beginText", { shape: drawn.tabbed.id });
  call("setText", { paras: [
    { src: 0, runs: [{ src: [0, 0], t: "Item\tMiddle\t99.25" }] },
    { src: 1, runs: [{ src: [1, 0], t: "Bullet\tRight" }] },
    { src: 2, runs: [{ src: [2, 0], t: "No tabs" }] },
  ] });
  call("endText");
  const saved = call("save", { format: "pptx" }).payload;
  const slide = new TextDecoder().decode(unzip(saved).get("ppt/slides/slide1.xml"));
  assert.match(slide, /99\.25/, "the typed text is saved");
  assert.match(slide, /<a:tabLst><a:tab algn="ctr" pos="914400"\/><a:tab algn="dec" pos="1828800"\/><\/a:tabLst>/);
  const reopened = call("open", { name: "Tabbed.pptx" }, saved);
  const again = call("scene", { slide: reopened.state.slides[0].id }).result.shapes.find((node) => node.name === "Tabbed");
  assert.deepEqual(again.text.paras[0].tabs, stops.tabs);
  assert.equal(again.text.paras[0].dts, 36);
});

test("keeps path gradients when saved and when the inspector changes their colours or style", () => {
  if (drawn.error) throw drawn.error;
  const reopened = call("open", { name: "Saved.pptx" }, call("save", { format: "pptx", keep: true }).payload);
  const slide = reopened.state.slides[0].id;
  const shapes = call("scene", { slide }).result.shapes;
  const circle = shapes.find((node) => node.name === "Circle gradient");
  assert.deepEqual([circle.fill.t, circle.fill.focus, circle.fill.tile], ["radial", [0, 0, 1, 1], [-1, -1, 0, 0]]);
  assert.equal(shapes.find((node) => node.name === "Scaled gradient").fill.scaled, true);

  // The inspector sends back what it was told, with one thing changed, as inspector.js does.
  call("select", { slide, shapes: [circle.id] });
  const told = call("inspect").result.shape.fill;
  assert.deepEqual([told.path, told.focus, told.tile, told.scaled], ["circle", [0, 0, 1, 1], [-1, -1, 0, 0], false]);
  call("setFill", { fill: { ...told, kind: "gradient", end: "#00ff00", path: "rect" } });
  const changed = call("scene", { slide }).result.shapes.find((node) => node.name === "Circle gradient").fill;
  assert.deepEqual([changed.t, changed.focus, changed.tile, changed.to], ["rect", [0, 0, 1, 1], [-1, -1, 0, 0], "#00ff00"]);
});

/**
 * The presentation as saved, with shapes that glow, fade at their edges, cast inner and preset shadows and blur,
 * and one that takes a glow from the theme's second effect style.
 */
function deckWithEffects() {
  const { payload } = call("save", { format: "pptx" });
  const entries = unzip(payload);
  const decode = (name) => new TextDecoder().decode(entries.get(name));
  const encode = (name, text) => entries.set(name, new TextEncoder().encode(text));
  const shape = (id, name, effects, style = "") => `
    <p:sp><p:nvSpPr><p:cNvPr id="${id}" name="${name}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr><a:xfrm><a:off x="914400" y="914400"/><a:ext cx="1828800" cy="914400"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>${effects}</p:spPr>${style}
    </p:sp>`;
  const shapes = shape(911, "Glowing", `<a:effectLst><a:glow rad="127000"><a:srgbClr val="00FF00"/></a:glow>
      <a:innerShdw blurRad="25400" dist="50800" dir="2700000"><a:srgbClr val="0000FF"/></a:innerShdw>
      <a:softEdge rad="63500"/></a:effectLst>`)
    + shape(912, "Blurred", `<a:effectLst><a:blur rad="38100" grow="0"/>
      <a:prstShdw prst="shdw13" dist="25400" dir="2700000"><a:srgbClr val="000000"/></a:prstShdw></a:effectLst>`)
    + shape(913, "Boxed", `<a:effectLst><a:prstShdw prst="shdw18" dist="25400" dir="2700000"><a:srgbClr val="000000"/></a:prstShdw></a:effectLst>`)
    + shape(914, "Themed", "", `<p:style><a:lnRef idx="0"><a:schemeClr val="accent1"/></a:lnRef>
      <a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="2"><a:srgbClr val="FFFF00"/></a:effectRef>
      <a:fontRef idx="minor"/></p:style>`);
  encode("ppt/slides/slide1.xml", decode("ppt/slides/slide1.xml").replace("</p:spTree>", `${shapes}</p:spTree>`));
  const theme = decode("ppt/theme/theme1.xml");
  const empty = "<a:effectStyle><a:effectLst/></a:effectStyle>";
  const second = theme.indexOf(empty, theme.indexOf(empty) + empty.length);
  assert.ok(second > 0, "the theme has an empty second effect style");
  const glow = '<a:effectStyle><a:effectLst><a:glow rad="63500"><a:schemeClr val="phClr"><a:alpha val="50000"/></a:schemeClr></a:glow></a:effectLst></a:effectStyle>';
  encode("ppt/theme/theme1.xml", theme.slice(0, second) + glow + theme.slice(second + empty.length));
  return zip(entries);
}

test("passes WordArt warps to the page as the paths its letters are laid along", () => {
  if (drawn.error) throw drawn.error;
  // The text's inset rectangle in the 144 × 108 point shape: 7.2 points in at the sides, 3.6 at the top and bottom.
  const inner = { x: 7.2, y: 3.6, w: 129.6, h: 100.8 };
  const inside = (flat) => flat.every((value, index) => (index % 2
    ? value >= inner.y - 0.01 && value <= inner.y + inner.h + 0.01
    : value >= inner.x - 0.01 && value <= inner.x + inner.w + 0.01));

  const arch = drawn.arched.text.warp;
  assert.equal(arch.length, 1, "an arch is one path to follow");
  assert.ok(arch[0].along.length > 20 && inside(arch[0].along), "an arc cut into short pieces, inside the text's box");
  assert.equal(arch[0].out, true, "its letters would stand out of the top, so they hang inside it");
  // adj moves where the arch starts: 200° clockwise from the right, a little above the middle on the left.
  const [startX, startY] = arch[0].along;
  assert.ok(startX < inner.x + inner.w * 0.1 && startY < inner.y + inner.h / 2 && startY > inner.y + inner.h * 0.25);

  const wave = drawn.waved.text.warp;
  assert.equal(wave.length, 1, "a wave is one band, between two paths");
  assert.ok(inside(wave[0].top) && inside(wave[0].bottom));
  const tops = wave[0].top.filter((_, index) => index % 2);
  assert.ok(Math.max(...tops) - Math.min(...tops) > 10, "its top edge waves");

  assert.equal(drawn.unwarped.text.warp, undefined, "textNoShape leaves the text flat");
  assert.equal(drawn.lined.text.warp, undefined);
});

test("places letters on a warp as the Apple apps do", () => {
  if (drawn.error) throw drawn.error;
  const bands = warpBands(drawn.waved.text.warp);
  assert.deepEqual([0, 1].map((index) => bandForLine(bands, index, 2)), [0, 0], "both lines share the one band");
  const place = placement(bands, 0, 10, 50, 40);
  // The text's corners land on the paths' ends; its middle half way between them.
  const [top, bottom] = [bands[0].top.points, bands[0].bottom.points];
  const topLeft = warpPoint(bands, place, 0, 100, 10);
  const bottomRight = warpPoint(bands, place, 100, 100, 50);
  assert.ok(Math.hypot(topLeft.x - top[0].x, topLeft.y - top[0].y) < 0.01);
  assert.ok(Math.hypot(bottomRight.x - bottom.at(-1).x, bottomRight.y - bottom.at(-1).y) < 0.01);
  // A letter stands upright, from its baseline towards the top path.
  const [a, , c, d] = letterTransform(bands, place, 45, 55, 100, 50, 40);
  assert.ok(a > 0 && d < 0 && Math.abs(c) < Math.abs(d), "runs right, and up is up the page");

  const arch = warpBands(drawn.arched.text.warp);
  const hanging = placement(arch, 0, 10, 50, 40);
  assert.equal(hanging.baseline, 10, "letters hang from the arch by their tops");
  const [width, , , , e, f] = letterTransform(arch, hanging, 0, 10, 30, 40, 36);
  assert.ok(Math.abs(width) <= 1.0001, "a letter on a path keeps its width");
  assert.ok(Number.isFinite(e) && Number.isFinite(f));
});

test("draws glows, soft edges, inner, preset and themed shadows and blurs, and saves them as they were", () => {
  const opened = call("open", { name: "Effects.pptx" }, deckWithEffects());
  const shapes = call("scene", { slide: opened.state.slides[0].id }).result.shapes;
  const named = (name) => shapes.find((node) => node.name === name)?.effects;

  const glowing = named("Glowing");
  assert.deepEqual(glowing.glow, { r: 10, c: "#00ff00" });
  assert.equal(glowing.soft, 5);
  assert.deepEqual([glowing.inner.dx, glowing.inner.dy, glowing.inner.blur, glowing.inner.c], [2.83, 2.83, 2, "#0000ff"]);

  const blurred = named("Blurred");
  assert.deepEqual(blurred.blur, { r: 3, grow: false });
  assert.equal(blurred.preset.casts.length, 2, "a double shadow is cast twice");
  const [far, near] = blurred.preset.casts;
  assert.ok(far[4] > near[4] && far[5] > near[5], "the farther copy first, twice as far");
  assert.ok(Math.abs(near[4] - 1.41) < 0.01 && Math.abs(near[5] - 1.41) < 0.01);

  const boxed = named("Boxed");
  assert.equal(boxed.preset, undefined, "the inner box preset falls inside");
  assert.ok(boxed.inner && boxed.inner.blur === 0, "as a hard inner shadow");

  const themed = named("Themed");
  assert.equal(themed?.glow?.r, 5, "the glow comes from the theme's effect style");
  assert.match(themed.glow.c, /^rgba\(255, ?255, ?0, ?0\.5\)$/, "in the reference's colour, at the style's alpha");

  const saved = unzip(call("save", { format: "pptx" }).payload);
  const slide = new TextDecoder().decode(saved.get("ppt/slides/slide1.xml"));
  for (const element of ["<a:glow ", "<a:innerShdw ", "<a:softEdge ", "<a:blur ", 'prst="shdw13"', 'prst="shdw18"']) {
    assert.ok(slide.includes(element), `keeps ${element}`);
  }
});

/** A deck of shapes in 3D: bevelled, set in depth, contoured, and one with none. */
function deckWithDepth() {
  const { payload } = call("save", { format: "pptx" });
  const entries = unzip(payload);
  const decode = (name) => new TextDecoder().decode(entries.get(name));
  const encode = (name, text) => entries.set(name, new TextEncoder().encode(text));
  const shape = (id, name, extra) => `
    <p:sp><p:nvSpPr><p:cNvPr id="${id}" name="${name}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr><a:xfrm><a:off x="914400" y="914400"/><a:ext cx="1828800" cy="914400"/></a:xfrm>
        <a:prstGeom prst="roundRect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="3366CC"/></a:solidFill>${extra}</p:spPr>
    </p:sp>`;
  const scene = (camera, light) => `<a:scene3d><a:camera prst="${camera}"/><a:lightRig rig="threePt" dir="${light}"/></a:scene3d>`;
  const shapes = shape(941, "Bevelled", `${scene("orthographicFront", "t")}<a:sp3d prstMaterial="metal"><a:bevelT w="127000" h="63500" prst="cross"/></a:sp3d>`)
    + shape(942, "Deep", `${scene("obliqueTopLeft", "tl")}<a:sp3d extrusionH="381000"><a:extrusionClr><a:srgbClr val="00FF00"/></a:extrusionClr></a:sp3d>`)
    + shape(943, "Contoured", `${scene("orthographicFront", "t")}<a:sp3d contourW="25400"><a:contourClr><a:srgbClr val="FF0000"/></a:contourClr></a:sp3d>`)
    + shape(944, "Flat", "");
  encode("ppt/slides/slide1.xml", decode("ppt/slides/slide1.xml").replace("</p:spTree>", `${shapes}</p:spTree>`));
  return zip(entries);
}

test("draws bevels, depth and contours in 3D, and saves them as they were", () => {
  const opened = call("open", { name: "Depth.pptx" }, deckWithDepth());
  const shapes = call("scene", { slide: opened.state.slides[0].id }).result.shapes;
  const named = (name) => shapes.find((node) => node.name === name);

  const bands = named("Bevelled").look3d?.bands;
  assert.ok(bands?.length > 0, "a bevel is drawn as bands over the face");
  // Lit from the top: the bands kept by moving the outline down are the top edge's.
  const top = bands.filter((band) => band.xy > 0);
  const bottom = bands.filter((band) => band.xy < 0);
  assert.ok(top.length && bottom.length && bands.every((band) => band.xx === 0 && band.kx === 0), "along the top and bottom edges only");
  assert.equal(top.find((band) => band.ky === 0)?.c, "#fff", "the top edge's outer band catches the light");
  assert.equal(bottom.find((band) => band.ky === 0)?.c, "#000", "the bottom edge's is in shade");
  assert.ok(top.some((band) => band.c === "#000"), "a cross turns away from the light further in");
  assert.ok(bands.every((band) => band.o > 0 && band.o < 1));

  const sides = named("Deep").look3d?.sides;
  assert.ok(sides?.casts.length > 1 && sides.casts.length === sides.cs.length, "the sides are copies of the outline, each its colour");
  const [far] = sides.casts;
  assert.ok(far[4] < 0 && far[5] < 0, "seen from the top left, they stand out up and to the left");
  assert.match(sides.cs[0], /^#00[0-9a-f]{2}00$/, "in the extrusion colour, darkened");
  assert.equal(named("Deep").look3d.bands, undefined, "no bevel, no bands");

  assert.deepEqual(named("Contoured").look3d?.contour, { w: 4, c: "#ff0000" }, "the contour straddles the edge");
  assert.equal(named("Flat").look3d, undefined, "a shape without 3D draws as before");

  const saved = unzip(call("save", { format: "pptx" }).payload);
  const slide = new TextDecoder().decode(saved.get("ppt/slides/slide1.xml"));
  for (const element of ['<a:camera prst="obliqueTopLeft"/>', 'prst="cross"', 'extrusionH="381000"', 'contourW="25400"', 'prstMaterial="metal"']) {
    assert.ok(slide.includes(element), `keeps ${element}`);
  }
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

/** A chart part of `plot`, with the axes it names, as PowerPoint writes one. */
function chartPart(plot, { axes = "cat", view3D = "" } = {}) {
  const axis = (id, cross, pos, name = "valAx", extra = "") =>
    `<c:${name}><c:axId val="${id}"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="${pos}"/>`
    + `${extra}<c:crossAx val="${cross}"/></c:${name}>`;
  const axisXML = {
    cat: axis(1, 2, "b", "catAx") + axis(2, 1, "l", "valAx", "<c:majorGridlines/>"),
    xy: axis(1, 2, "b", "valAx", "<c:majorGridlines/>") + axis(2, 1, "l", "valAx", "<c:majorGridlines/>"),
    surface: axis(1, 2, "b", "catAx") + axis(2, 1, "l", "valAx", "<c:majorGridlines/>") + axis(3, 2, "b", "serAx"),
    none: "",
  }[axes];
  return new TextEncoder().encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
    + ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:chart><c:autoTitleDeleted val="1"/>'
    + `${view3D}<c:plotArea><c:layout/>${plot}${axisXML}</c:plotArea><c:legend><c:legendPos val="b"/></c:legend></c:chart></c:chartSpace>`);
}

/** A series of a category chart: its name, categories (or dates) and values. */
function chartSeries(index, name, values, { categories = ["North", "East", "South", "West", "Middle"], dates = false, extra = "" } = {}) {
  const points = (list) => list.map((value, at) => `<c:pt idx="${at}"><c:v>${value}</c:v></c:pt>`).join("");
  const category = dates
    ? `<c:cat><c:numRef><c:f>Sheet1!$A$2:$A$6</c:f><c:numCache><c:formatCode>m/d/yyyy</c:formatCode><c:ptCount val="5"/>${points([45292, 45293, 45294, 45295, 45296])}</c:numCache></c:numRef></c:cat>`
    : `<c:cat><c:strRef><c:f>Sheet1!$A$2:$A$${categories.length + 1}</c:f><c:strCache><c:ptCount val="${categories.length}"/>${points(categories)}</c:strCache></c:strRef></c:cat>`;
  return `<c:ser><c:idx val="${index}"/><c:order val="${index}"/><c:tx><c:v>${name}</c:v></c:tx>${extra}${category}`
    + `<c:val><c:numRef><c:f>Sheet1!$B$2:$B$6</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val="${values.length}"/>${points(values)}</c:numCache></c:numRef></c:val></c:ser>`;
}

const FRUIT = [["Apples", [4.3, 2.5, 3.5, 4.5, 3]], ["Pears", [2.4, 4.4, 1.8, 2.8, 3.6]], ["Plums", [2, 2, 3, 5, 1.5]]];
const literal = (values) => `<c:numLit><c:ptCount val="${values.length}"/>${values.map((v, i) => `<c:pt idx="${i}"><c:v>${v}</c:v></c:pt>`).join("")}</c:numLit>`;
const NEW_CHART_KINDS = [
  chartPart(`<c:radarChart><c:radarStyle val="filled"/>${FRUIT.map(([name, values], index) => chartSeries(index, name, values)).join("")}<c:axId val="1"/><c:axId val="2"/></c:radarChart>`),
  chartPart(`<c:stockChart>${[["Open", [44, 25, 38, 50, 36]], ["High", [55, 57, 57, 58, 58]], ["Low", [11, 12, 13, 11, 25]], ["Close", [25, 38, 50, 35, 43]]]
    .map(([name, values], index) => chartSeries(index, name, values, { dates: true, extra: "<c:spPr><a:ln><a:noFill/></a:ln></c:spPr>" })).join("")}`
    + "<c:hiLowLines/><c:upDownBars><c:upBars/><c:downBars/></c:upDownBars><c:axId val=\"1\"/><c:axId val=\"2\"/></c:stockChart>"),
  chartPart("<c:bubbleChart><c:varyColors val=\"0\"/><c:ser><c:idx val=\"0\"/><c:order val=\"0\"/><c:tx><c:v>Sales</c:v></c:tx>"
    + `<c:xVal>${literal([1, 2, 3])}</c:xVal><c:yVal>${literal([2, 3, 1])}</c:yVal><c:bubbleSize>${literal([1, 4, 9])}</c:bubbleSize>`
    + "</c:ser><c:bubbleScale val=\"100\"/><c:axId val=\"1\"/><c:axId val=\"2\"/></c:bubbleChart>", { axes: "xy" }),
  chartPart(`<c:ofPieChart><c:ofPieType val="pie"/><c:varyColors val="1"/>${chartSeries(0, "Drinks", [42, 25, 15, 8, 6, 4], { categories: ["Tea", "Coffee", "Juice", "Water", "Milk", "Soda"] })}`
    + "<c:gapWidth val=\"100\"/><c:splitType val=\"pos\"/><c:splitPos val=\"3\"/><c:secondPieSize val=\"75\"/><c:serLines/></c:ofPieChart>", { axes: "none" }),
  chartPart(`<c:bar3DChart><c:barDir val="col"/><c:grouping val="clustered"/>${FRUIT.map(([name, values], index) => chartSeries(index, name, values)).join("")}<c:axId val="1"/><c:axId val="2"/></c:bar3DChart>`,
    { view3D: "<c:view3D><c:rotX val=\"15\"/><c:rotY val=\"20\"/><c:rAngAx val=\"1\"/></c:view3D>" }),
  chartPart(`<c:surfaceChart><c:wireframe val="0"/>${[["Morning", [10, 20, 30, 25, 15]], ["Noon", [20, 40, 55, 45, 25]], ["Night", [5, 10, 15, 12, 8]]]
    .map(([name, values], index) => chartSeries(index, name, values)).join("")}<c:axId val="1"/><c:axId val="2"/><c:axId val="3"/></c:surfaceChart>`, { axes: "surface" }),
];

/** A deck of one chart of each kind above: column charts inserted and saved, their parts then swapped for these. */
function deckOfNewChartKinds() {
  call("new", { name: "Kinds.pptx" });
  for (let index = 0; index < NEW_CHART_KINDS.length; index++) call("insertChart", { kind: "column" });
  const entries = unzip(call("save", { format: "pptx", keep: true }).payload);
  NEW_CHART_KINDS.forEach((part, index) => entries.set(`ppt/charts/chart${index + 1}.xml`, part));
  return zip(entries);
}

test("draws radar, stock, bubble, of-pie, 3D and surface charts as themselves, and keeps their kind when edited", () => {
  const opened = call("open", { name: "Kinds.pptx" }, deckOfNewChartKinds());
  const charts = call("scene", { slide: opened.state.slides[0].id }).result.shapes.filter((node) => node.kind === "chart");
  assert.equal(charts.length, NEW_CHART_KINDS.length);
  const [radar, stock, bubble, ofPie, column3D, surface] = charts.map((node) => node.chart);
  const filled = (items) => items.filter((item) => item.k === "path" && item.fill);
  const texts = (items) => items.filter((item) => item.k === "text").map((item) => item.t);

  assert.equal(filled(radar).length, 3, "a filled radar fills each series");
  assert.ok(radar.some((item) => item.k === "path" && !item.fill && item.d.split("L").length > 4), "inside polygon gridlines");
  assert.ok(["North", "East", "South", "West", "Middle"].every((name) => texts(radar).includes(name)), "with its categories round the outside");
  assert.equal(filled(stock).length, 5, "a stock chart draws a bar from each open to close");
  assert.ok(texts(stock).includes("1/1/2024"), "and its dates as dates");
  const diameters = filled(bubble).map((item) => item.d);
  assert.equal(new Set(diameters).size, 3, "a bubble of its own size per point");
  assert.ok(texts(ofPie).includes(strings["Chart.Other"] ?? "Other"), "an of-pie chart's legend names the slice it splits out");
  assert.equal(filled(ofPie).length, 7, "three slices and the rest in the first pie, three in the second");
  assert.equal(filled(column3D).length, 30, "3D columns show a top and a side each");
  assert.ok(surface.filter((item) => item.k === "rect").length > 50, "a surface is a map of its value bands");
  assert.ok(texts(surface).includes("0-10"), "which its legend lists");

  call("select", { shapes: [charts[0].id] });
  const before = call("inspect").result.shape.chart;
  assert.equal(before.kind, "radar");
  assert.equal(before.hasGrouping, false);
  assert.equal(before.kinds.at(-1).kind, "radar", "the chart's own kind is offered beside those a chart can be made as");
  call("chart", { set: { series: [{ name: "Apples", values: ["1", "1", "1", "1", "1"] }, { name: "Pears" }, { name: "Plums" }] } });
  const after = call("inspect").result.shape.chart;
  assert.equal(after.kind, "radar", "Edit Data keeps the kind");
  assert.equal(after.series[0].values[0], "1");

  const reopened = call("open", { name: "Again.pptx" }, call("save", { format: "pptx", keep: true }).payload);
  const again = call("scene", { slide: reopened.state.slides[0].id }).result.shapes.filter((node) => node.kind === "chart");
  assert.equal(filled(again[0].chart).length, 3, "and saving keeps it");
  assert.equal(filled(again[4].chart).length, 30);
});

const TRENDLINE = (type, extra = "") => `<c:trendline><c:spPr><a:ln w="19050"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>`
  + `<a:prstDash val="sysDot"/></a:ln></c:spPr><c:trendlineType val="${type}"/>${extra}<c:dispRSqr val="1"/><c:dispEq val="1"/></c:trendline>`;
const ERROR_BARS = (valueType, extra = "") => `<c:errBars><c:errBarType val="both"/><c:errValType val="${valueType}"/><c:noEndCap val="0"/>${extra}`
  + `<c:spPr><a:ln w="9525"><a:solidFill><a:srgbClr val="0000FF"/></a:solidFill></a:ln></c:spPr></c:errBars>`;
const ANALYSIS_CHARTS = [
  ...[["linear"], ["exp"], ["log"], ["poly", "<c:order val=\"3\"/>"], ["power"], ["movingAvg", "<c:period val=\"2\"/>"]].map(([type, extra]) =>
    chartPart(`<c:lineChart><c:grouping val="standard"/>${chartSeries(0, "Apples", [2, 3, 5, 4, 6], { extra: TRENDLINE(type, extra) })}<c:axId val="1"/><c:axId val="2"/></c:lineChart>`)),
  ...[["fixedVal", "<c:val val=\"1\"/>"], ["percentage", "<c:val val=\"10\"/>"], ["stdDev", "<c:val val=\"1\"/>"], ["stdErr", ""],
    ["cust", `<c:plus>${literal([1, 2, 1, 2, 1])}</c:plus><c:minus>${literal([0.5, 0.5, 0.5, 0.5, 0.5])}</c:minus>`]].map(([type, extra]) =>
    chartPart(`<c:barChart><c:barDir val="col"/><c:grouping val="clustered"/>${chartSeries(0, "Apples", [4.3, 2.5, 3.5, 4.5, 3], { extra: ERROR_BARS(type, extra) })}<c:axId val="1"/><c:axId val="2"/></c:barChart>`)),
];

test("draws trendlines and error bars over a chart's series, and keeps them when saved", () => {
  call("new", { name: "Analysis.pptx" });
  for (let index = 0; index < ANALYSIS_CHARTS.length; index++) call("insertChart", { kind: "column" });
  const entries = unzip(call("save", { format: "pptx", keep: true }).payload);
  ANALYSIS_CHARTS.forEach((part, index) => entries.set(`ppt/charts/chart${index + 1}.xml`, part));
  const check = (opened) => {
    const charts = call("scene", { slide: opened.state.slides[0].id }).result.shapes.filter((node) => node.kind === "chart").map((node) => node.chart);
    assert.equal(charts.length, ANALYSIS_CHARTS.length);
    const stroked = (items, color) => items.filter((item) => item.k === "path" && !item.fill && item.stroke === color);
    const texts = (items) => items.filter((item) => item.k === "text").map((item) => item.t);
    charts.slice(0, 6).forEach((items, index) => {
      assert.equal(stroked(items, "#ff0000").length, 2, `trendline ${index} is drawn, and shown in the legend`);
    });
    assert.ok(texts(charts[0]).includes("Linear (Apples)"), "the legend names a trendline by its kind and series");
    assert.ok(texts(charts[0]).some((text) => text.startsWith("y = ")), "with its equation");
    assert.ok(texts(charts[0]).some((text) => text.startsWith("R² = ")), "and R²");
    assert.ok(texts(charts[5]).includes("2 per. Mov. Avg. (Apples)"));
    charts.slice(6).forEach((items, index) => {
      assert.equal(stroked(items, "#0000ff").length, 1, `error bars ${index} are drawn`);
    });
  };
  check(call("open", { name: "Analysis.pptx" }, zip(entries)));
  check(call("open", { name: "Again.pptx" }, call("save", { format: "pptx", keep: true }).payload));
});

const CX = "http://schemas.microsoft.com/office/drawing/2014/chartex";

/** A block of an Office 2016 chart's data: labels level by level, the innermost first, and numbers of a type. */
function cxData(id, levels, values, type = "val") {
  const level = (labels) => `<cx:lvl ptCount="${labels.length}">${labels.map((label, i) => (label ? `<cx:pt idx="${i}">${label}</cx:pt>` : "")).join("")}</cx:lvl>`;
  return `<cx:data id="${id}">${levels.length ? `<cx:strDim type="cat">${levels.map(level).join("")}</cx:strDim>` : ""}`
    + `<cx:numDim type="${type}"><cx:lvl ptCount="${values.length}">${values.map((v, i) => `<cx:pt idx="${i}">${v}</cx:pt>`).join("")}</cx:lvl></cx:numDim></cx:data>`;
}

/** A chart part of Office 2016's format, as PowerPoint writes one. */
function cxPart(data, series, { legend = true } = {}) {
  return new TextEncoder().encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + `<cx:chartSpace xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:cx="${CX}"><cx:chartData>${data}</cx:chartData>`
    + `<cx:chart><cx:plotArea><cx:plotAreaRegion>${series}</cx:plotAreaRegion><cx:axis id="0"><cx:catScaling/></cx:axis>`
    + `<cx:axis id="1"><cx:valScaling/><cx:majorGridlines/></cx:axis></cx:plotArea>${legend ? '<cx:legend pos="t"/>' : ""}</cx:chart></cx:chartSpace>`);
}

const cxSeries = (layout, name, layoutProperties = "", data = 0) => `<cx:series layoutId="${layout}"><cx:tx><cx:txData><cx:v>${name}</cx:v></cx:txData></cx:tx>`
  + `<cx:dataId val="${data}"/>${layoutProperties ? `<cx:layoutPr>${layoutProperties}</cx:layoutPr>` : ""}</cx:series>`;

const SUBJECTS = ["Maths", "Maths", "Maths", "Maths", "Maths", "Maths", "Art", "Art", "Art", "Art", "Art", "Art"];
const OFFICE_2016_CHARTS = [
  cxPart(cxData(0, [["Start", "Sales", "Returns", "Services", "Costs", "End"]], [120, 80, -30, 45, -60, 155]),
    cxSeries("waterfall", "Cash", '<cx:subtotals><cx:idx val="0"/><cx:idx val="5"/></cx:subtotals>')),
  cxPart(cxData(0, [["Leads", "Qualified", "Proposals", "Negotiation", "Won"]], [500, 420, 260, 140, 90]), cxSeries("funnel", "Pipeline"), { legend: false }),
  cxPart(cxData(0, [["Apples", "Pears", "Plums", "Carrots", "Leeks", "Peas", "Rice", "Oats"],
    ["Fruit", "Fruit", "Fruit", "Vegetables", "Vegetables", "Vegetables", "Grains", "Grains"]], [30, 12, 8, 25, 20, 15, 18, 6], "size"), cxSeries("treemap", "Stock")),
  cxPart(cxData(0, [["Tokyo", "Osaka", "", "Seoul", "Busan", "Paris", "Lyon", ""], ["Japan", "Japan", "Taiwan", "Korea", "Korea", "France", "France", "Spain"],
    ["Asia", "Asia", "Asia", "Asia", "Asia", "Europe", "Europe", "Europe"]], [40, 22, 18, 26, 9, 30, 12, 20], "size"), cxSeries("sunburst", "Visitors")),
  cxPart(cxData(0, [], [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), cxSeries("clusteredColumn", "Minutes", '<cx:binning intervalClosed="r"><cx:binSize val="3"/></cx:binning>'), { legend: false }),
  cxPart(cxData(0, [["Late", "Damaged", "Wrong item", "Late", "Billing", "Damaged", "Late", "Other"]], [14, 9, 6, 21, 4, 8, 12, 3]),
    cxSeries("clusteredColumn", "Complaints", "<cx:aggregation/>") + '<cx:series layoutId="paretoLine" ownerIdx="0"><cx:axisId val="2"/></cx:series>', { legend: false }),
  cxPart(cxData(0, [SUBJECTS], [52, 61, 64, 68, 73, 98, 70, 74, 77, 80, 84, 88]) + cxData(1, [SUBJECTS], [48, 55, 60, 66, 70, 75, 62, 68, 72, 79, 85, 91]),
    cxSeries("boxWhisker", "Class A") + cxSeries("boxWhisker", "Class B", "", 1)),
];

/**
 * A deck of one chart of each of Office 2016's kinds: column charts inserted and saved, their parts then swapped for
 * these, and each frame put the way PowerPoint writes one, beside a text box for readers that don't know the kind.
 */
function deckOfOffice2016Charts(parts = OFFICE_2016_CHARTS) {
  call("new", { name: "Office2016.pptx" });
  for (let index = 0; index < parts.length; index++) call("insertChart", { kind: "column" });
  const entries = unzip(call("save", { format: "pptx", keep: true }).payload);
  parts.forEach((part, index) => entries.set(`ppt/charts/chart${index + 1}.xml`, part));
  const edit = (path, change) => entries.set(path, new TextEncoder().encode(change(new TextDecoder().decode(entries.get(path)))));
  edit("ppt/slides/slide1.xml", (xml) => xml.replace(/<p:graphicFrame>.*?<\/p:graphicFrame>/gs, (frame) => {
    if (!frame.includes("<c:chart ")) return frame;
    const choice = frame.replace(/<a:graphicData uri="[^"]*">/, `<a:graphicData uri="${CX}">`)
      .replace(/<c:chart xmlns:c="[^"]*"/, `<cx:chart xmlns:cx="${CX}"`);
    return '<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">'
      + `<mc:Choice xmlns:cx1="http://schemas.microsoft.com/office/drawing/2015/9/8/chartex" Requires="cx1">${choice}</mc:Choice>`
      + '<mc:Fallback><p:sp><p:nvSpPr><p:cNvPr id="99" name="Chart"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/>'
      + '<a:ext cx="914400" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:p><a:r>'
      + "<a:t>This chart isn't available in your version of PowerPoint.</a:t></a:r></a:p></p:txBody></p:sp></mc:Fallback></mc:AlternateContent>";
  }));
  edit("ppt/slides/_rels/slide1.xml.rels", (xml) => xml.replaceAll("http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart\"",
    "http://schemas.microsoft.com/office/2014/relationships/chartEx\""));
  return zip(entries);
}

test("draws waterfall, funnel, treemap, sunburst, histogram, Pareto and box and whisker charts as themselves", () => {
  const opened = call("open", { name: "Office2016.pptx" }, deckOfOffice2016Charts());
  const slide = opened.state.slides[0].id;
  const charts = call("scene", { slide }).result.shapes.filter((node) => node.kind === "chart");
  assert.equal(charts.length, OFFICE_2016_CHARTS.length, "each is drawn as a chart, not as the text box kept for older readers");
  const [waterfall, funnel, treemap, sunburst, histogram, pareto, boxWhisker] = charts.map((node) => node.chart);
  const rects = (items) => items.filter((item) => item.k === "rect");
  const filled = (items) => items.filter((item) => item.k === "path" && item.fill);
  const texts = (items) => items.filter((item) => item.k === "text").map((item) => item.t);

  assert.equal(rects(waterfall).length, 9, "a waterfall draws a column per point, under a legend of its three kinds");
  assert.equal(new Set(rects(waterfall).slice(3).map((item) => item.fill)).size, 3, "rises, falls and totals each in a colour");
  assert.ok(texts(waterfall).includes(strings["Chart.Waterfall.Total"] ?? "Total"));
  assert.equal(rects(funnel).length, 5, "a funnel draws a bar per stage");
  assert.ok(rects(funnel).every((item, index, all) => index === 0 || item.w < all[index - 1].w), "each narrower than the last");
  assert.equal(filled(treemap).length, 8, "a treemap draws a rectangle per leaf");
  assert.ok(["Vegetables", "Carrots"].every((name) => texts(treemap).includes(name)), "named, under their branches");
  assert.equal(filled(sunburst).length, 13, "a sunburst draws a piece of ring per branch and leaf");
  assert.equal(rects(histogram).length, 3, "a histogram draws a column per bin");
  assert.ok(texts(histogram).includes("(4, 7]"), "named by its range");
  assert.equal(rects(pareto).length, 5, "a Pareto chart adds up each category");
  assert.ok(texts(pareto).includes("100%"), "beside a scale of the running share");
  assert.ok(pareto.some((item) => item.k === "path" && !item.fill && item.d.split("L").length === 5), "which a line follows");
  assert.equal(filled(boxWhisker).filter((item) => item.stroke).length, 4, "a box per series in each category");
  assert.ok(texts(boxWhisker).includes("Art"));

  call("select", { shapes: [charts[0].id] });
  const before = call("inspect").result.shape.chart;
  assert.equal(before.kind, "waterfall");
  assert.equal(before.kinds.at(-1).kind, "waterfall", "the chart's own kind is named");
  call("chart", { set: { title: "Changed", kind: "column" } });
  assert.equal(call("inspect").result.shape.chart.kind, "waterfall", "and it is left as it was");

  const saved = call("save", { format: "pptx", keep: true }).payload;
  const part = new TextDecoder().decode(unzip(saved).get("ppt/charts/chart1.xml"));
  assert.ok(part.includes("<cx:chartSpace") && !part.includes("Changed"), "saving keeps the part as it was");
  const reopened = call("open", { name: "Again.pptx" }, saved);
  const again = call("scene", { slide: reopened.state.slides[0].id }).result.shapes.filter((node) => node.kind === "chart");
  assert.equal(again.length, OFFICE_2016_CHARTS.length);
  assert.equal(rects(again[1].chart).length, 5);

  const map = cxPart(cxData(0, [["A", "B"]], [1, 2]), cxSeries("regionMap", "Places"));
  const unknown = call("open", { name: "Map.pptx" }, deckOfOffice2016Charts([map]));
  assert.ok(!call("scene", { slide: unknown.state.slides[0].id }).result.shapes.some((node) => node.kind === "chart"),
    "a kind that isn't drawn shows what is kept for older readers");
});

/**
 * A Keynote deck of two tables: one of 2 × 2 cells as Keynote kept them
 * before 2019, its top row merged, and one with nothing to read its cells from.
 */
function keynoteTables() {
  const offsets = (values) => [...Array(256).keys()].flatMap((c) => {
    const v = c < values.length ? values[c] : 0xffff;
    return [v & 0xff, v >> 8];
  });
  // Version 4: the flags at byte 4, then a string key.
  const older = (key) => [4, 3, 0, 0, 0x10, 0, 0, 0, 0, 0, 0, 0, key, 0, 0, 0];
  const objects = [
    [1, 1, new Proto().reference(2, 2)],
    [2, 2, new Proto()
      .message(3, (tree) => tree.reference(2, 100).reference(2, 110))
      .message(4, (size) => size.float(1, 1024).float(2, 768))],
    [20, 6002, new Proto()
      .message(5, (row) => row.varint(1, 0).data(3, older(1)).data(4, offsets([0])))
      .message(5, (row) => row.varint(1, 1).data(3, [...older(2), ...older(3)]).data(4, offsets([0, 16])))],
    [21, 6005, new Proto()
      .message(3, (e) => e.varint(1, 1).string(3, "Merged"))
      .message(3, (e) => e.varint(1, 2).string(3, "Left"))
      .message(3, (e) => e.varint(1, 3).string(3, "Right"))],
    [22, 6010, new Proto().message(1, (range) => range
      .message(1, (m) => m.varint(1, 0)).message(2, (m) => m.varint(1, (2 << 16) | 1)))],
  ];
  [0, 1].forEach((index) => {
    const node = 100 + index * 10;
    objects.push([node, 4, new Proto().reference(2, node + 1)]);
    objects.push([node + 1, 5, new Proto().reference(42, node + 2)]);
    objects.push([node + 2, 6000, new Proto()
      .message(1, (d) => d.message(1, (g) => g
        .message(1, (p) => p.float(1, 100).float(2, 100))
        .message(2, (s) => s.float(1, 400).float(2, 200))
        .varint(3, 3)))
      .reference(2, node + 3)]);
    objects.push([node + 3, 6001, new Proto()
      .message(4, (store) => {
        if (index === 0) store.message(3, (t) => t.message(1, (tile) => tile.varint(1, 0).reference(2, 20))).reference(4, 21).reference(13, 22);
      })
      .varint(6, 2).varint(7, 2)]);
  });
  // The second table has no data store at all.
  objects[objects.length - 1][2] = new Proto().varint(6, 2).varint(7, 2);
  return zip(new Map([["Index/Document.iwa", iwa(objects)]]));
}

test("draws Keynote tables saved before 2019, and a stand-in for one it can't read", () => {
  const opened = call("open", { name: "Tables.key" }, keynoteTables());
  const [older, unreadable] = opened.state.slides.map((slide) => call("scene", { slide: slide.id }).result.shapes[0]);
  assert.equal(older.kind, "table");
  const cells = older.table.cells;
  assert.equal(cells.length, 3, "the top row is one merged cell");
  assert.equal(cells[0].cs, 2);
  assert.deepEqual(cells.map((cell) => text(cell.text)), ["Merged", "Left", "Right"]);
  assert.equal(unreadable.kind, "standin");
  assert.equal(unreadable.label, strings["Object.Table"] ?? "Table");
  assert.ok(unreadable.w > 0 && unreadable.h > 0, "the stand-in keeps the table's place");
  assert.deepEqual(opened.result.omissions, [strings["Notice.Omission.TableStandIns"] ?? opened.result.omissions[0]]);
  assert.ok(!opened.result.omissions[0].includes("Notice."), "the omission is worded");
  assert.deepEqual(opened.result.unsupported, []);
  for (const format of opened.result.saveFormats.map((f) => f.key)) {
    const saved = call("save", { format, keep: true });
    const reopened = call("open", { name: `Tables.${format}` }, saved.payload);
    const kinds = reopened.state.slides.map((slide) => call("scene", { slide: slide.id }).result.shapes[0].kind);
    assert.deepEqual(kinds, ["table", "standin"], `saved as ${format}`);
  }
});

// Protocol buffer fields, for building a Keynote document object by object.
const proto = {
  varint(value) {
    const bytes = [];
    let rest = BigInt(value);
    do {
      let byte = Number(rest & 0x7fn);
      rest >>= 7n;
      if (rest) byte |= 0x80;
      bytes.push(byte);
    } while (rest);
    return bytes;
  },
  uint: (field, value) => [...proto.varint(field << 3), ...proto.varint(value)],
  float(field, value) {
    const buffer = new DataView(new ArrayBuffer(4));
    buffer.setFloat32(0, value, true);
    return [...proto.varint((field << 3) | 5), ...new Uint8Array(buffer.buffer)];
  },
  bytes: (field, value) => [...proto.varint((field << 3) | 2), ...proto.varint(value.length), ...value],
  string: (field, value) => proto.bytes(field, [...new TextEncoder().encode(value)]),
  message: (field, ...parts) => proto.bytes(field, parts.flat()),
  reference: (field, id) => proto.message(field, proto.uint(1, id)),
  frame: (x, y, w, h) => proto.message(1, proto.message(1, proto.message(1, proto.float(1, x), proto.float(2, y)),
    proto.message(2, proto.float(1, w), proto.float(2, h)), proto.uint(3, 3))),
};

/** Objects as an `.iwa`: each behind its ArchiveInfo, compressed as Snappy literals. */
function iwaOfBytes(objects) {
  const stream = [];
  for (const [id, type, body] of objects) {
    const info = [...proto.uint(1, id), ...proto.message(2, proto.uint(1, type), proto.uint(3, body.length))];
    stream.push(...proto.varint(info.length), ...info, ...body);
  }
  const block = proto.varint(stream.length);
  for (let offset = 0; offset < stream.length; offset += 65536) {
    const length = Math.min(65536, stream.length - offset);
    block.push(61 << 2, (length - 1) & 0xff, (length - 1) >> 8, ...stream.slice(offset, offset + length));
  }
  return new Uint8Array([0, block.length & 0xff, (block.length >> 8) & 0xff, block.length >> 16, ...block]);
}

/** A Keynote deck of one slide: a movie that starts by itself and a sound a Start Movie build starts on a tap. */
function keynoteWithMovies() {
  const objects = [
    [1, 1, proto.reference(2, 2)],
    [2, 2, [...proto.message(3, proto.reference(2, 10)), ...proto.message(4, proto.float(1, 1024), proto.float(2, 768))]],
    [10, 4, proto.reference(2, 11)],
    [11, 5, [...proto.reference(42, 13), ...proto.reference(42, 14), ...proto.reference(43, 80)]],
    [13, 3007, [...proto.frame(100, 100, 320, 180), ...proto.reference(14, 901), ...proto.reference(15, 900), ...proto.uint(24, 1)]],
    [14, 3007, [...proto.frame(500, 100, 100, 100), ...proto.reference(14, 902), ...proto.reference(16, 900), ...proto.uint(9, 1)]],
    [80, 153, proto.reference(1, 81)],
    [81, 8, [...proto.reference(1, 14), ...proto.string(2, "All at Once"),
      ...proto.message(4, proto.message(18, proto.string(1, "In"), proto.string(2, "apple:movie-start")))]],
  ];
  const files = [[900, "poster.png"], [901, "clip.mov"], [902, "sound.m4a"]];
  const metadata = files.flatMap(([id, name]) => proto.message(4, proto.uint(1, id), proto.string(3, name), proto.string(4, name)));
  return zip(new Map([
    ["Index/Document.iwa", iwaOfBytes(objects)],
    ["Index/Metadata.iwa", iwaOfBytes([[50, 11006, metadata]])],
    ["Data/poster.png", PIXEL],
    ["Data/clip.mov", new TextEncoder().encode("movie")],
    ["Data/sound.m4a", new TextEncoder().encode("sound")],
  ]));
}

test("plays a Keynote movie as the slide appears and its sound on a tap, and saves them into PowerPoint", () => {
  const opened = call("open", { name: "Movies.key" }, keynoteWithMovies());
  const slide = opened.state.slides[0].id;
  const scene = call("scene", { slide }).result;
  const [movie, sound] = scene.shapes;
  assert.equal(movie.media?.kind, "video");
  assert.equal(movie.media.auto, true, "the movie starts by itself");
  assert.equal(sound.media?.kind, "audio");
  assert.equal(sound.media.auto, false, "the sound waits for its build");
  assert.ok(movie.src, "the movie shows its poster frame");
  const clip = call("media", { path: movie.media.path });
  assert.equal(clip.result.mime, "video/quicktime");
  assert.equal(new TextDecoder().decode(clip.payload), "movie");
  const timeline = call("timeline", { slide }).result;
  assert.equal(timeline.initial, 1, "the movie's play command runs with the slide");
  assert.deepEqual(timeline.media, [[movie.id], [sound.id]]);
  assert.equal(opened.result.omissions.length, 0, "nothing is left behind");

  const saved = unzip(call("save", { format: "pptx", keep: true }).payload);
  const media = [...saved.keys()].filter((name) => name.startsWith("ppt/media/media"));
  assert.deepEqual(media.map((name) => new TextDecoder().decode(saved.get(name))).sort(), ["movie", "sound"]);
  assert.match(new TextDecoder().decode(saved.get("ppt/slides/slide1.xml")), /p14:media/);
});

test("passes a movie's trim, fades, volume, looping, full screen and hiding to the slideshow", () => {
  call("open", { name: "Movies.key" }, keynoteWithMovies());
  const entries = unzip(call("save", { format: "pptx", keep: true }).payload);
  const name = "ppt/slides/slide1.xml";
  let xml = new TextDecoder().decode(entries.get(name));
  const pic = xml.match(/<p:pic>.*?<p:cNvPr id="(\d+)"[^]*?<a:videoFile/s);
  assert.ok(pic, "the movie is saved as a picture with a video");
  xml = xml.replace(/(<p14:media [^>]*?)\/>/, '$1><p14:trim st="1500" end="500"/><p14:fade in="250" out="1000"/></p14:media>');
  const node = `<p:video fullScrn="1"><p:cMediaNode vol="40000" showWhenStopped="0"><p:cTn id="99" repeatCount="indefinite" fill="remove" display="0">`
    + `<p:stCondLst><p:cond delay="indefinite"/></p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid="${pic[1]}"/></p:tgtEl></p:cMediaNode></p:video>`;
  xml = xml.includes("<p:timing>")
    ? xml.replace(/(<p:cTn [^>]*nodeType="tmRoot"[^>]*><p:childTnLst>)/, `$1${node}`)
    : xml.replace("</p:sld>", `<p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>${node}</p:childTnLst></p:cTn></p:par></p:tnLst></p:timing></p:sld>`);
  entries.set(name, new TextEncoder().encode(xml));
  const opened = call("open", { name: "Settings.pptx" }, zip(entries));
  const movie = call("scene", { slide: opened.state.slides[0].id }).result.shapes.find((shape) => shape.media?.kind === "video");
  assert.deepEqual(movie.media.trim, [1.5, 0.5]);
  assert.deepEqual(movie.media.fade, [0.25, 1]);
  assert.equal(movie.media.volume, 0.4);
  assert.equal(movie.media.loop, true);
  assert.equal(movie.media.rewind, true);
  assert.equal(movie.media.full, true);
  assert.equal(movie.media.hide, true);
});

/**
 * A Keynote deck of one slide of the objects beyond shapes, pictures, movies, charts and tables: a connection line,
 * a freehand drawing, a sound with no icon, an equation typeset into a PDF this platform can't draw, a 3D object with
 * a still and one without, a kind Keynote may add later, a chart from before 2013 and a sticky comment.
 */
function keynoteObjects() {
  const style = proto.message(11, proto.message(1, proto.message(1, proto.uint(1, 1), proto.float(3, 1), proto.float(6, 1))),
    proto.message(2, proto.message(1, proto.uint(1, 1), proto.float(5, 1), proto.float(6, 1)), proto.float(2, 3)));
  const path = (points) => proto.message(3, ...points.map(([x, y], index) =>
    proto.message(1, proto.uint(1, index ? 2 : 1), proto.message(2, proto.float(1, x), proto.float(2, y)))));
  const drawables = [13, 14, 18, 23, 25, 26, 33, 34, 39];
  const objects = [
    [1, 1, proto.reference(2, 2)],
    [2, 2, [...proto.message(3, proto.reference(2, 10)), ...proto.message(4, proto.float(1, 1024), proto.float(2, 768))]],
    [10, 4, proto.reference(2, 11)],
    [11, 5, drawables.flatMap((id) => proto.reference(42, id))],
    [15, 3015, style],
    [13, 3009, proto.message(1, ...proto.frame(50, 50, 300, 100), ...proto.reference(2, 15),
      ...proto.message(3, proto.message(7, proto.message(1, path([[0, 0], [150, 100], [300, 0]])))))],
    [14, 3008, [...proto.frame(400, 50, 200, 200), ...proto.reference(2, 16), ...proto.message(100, proto.float(2, 0.5))]],
    [16, 3004, [...proto.frame(0, 0, 200, 200), ...proto.reference(2, 15), ...proto.message(3, proto.message(5, path([[0, 0], [200, 50], [20, 200]])))]],
    [18, 3007, [...proto.frame(700, 50, 64, 64), ...proto.reference(14, 902), ...proto.uint(9, 1)]],
    [23, 3005, [...proto.frame(50, 300, 200, 60), ...proto.reference(11, 904), ...proto.string(103, "e^{i\\pi} = -1")]],
    [25, 3007, [...proto.frame(300, 300, 150, 150), ...proto.message(200, proto.reference(1, 905), proto.reference(5, 900))]],
    [26, 3007, [...proto.frame(500, 300, 150, 150), ...proto.message(200, proto.reference(1, 905))]],
    [33, 3999, proto.message(1, ...proto.frame(50, 500, 300, 150))],
    [34, 2014, [...proto.message(1, proto.message(1, ...proto.frame(900, 20, 100, 100))), ...proto.reference(2, 36)]],
    [36, 3056, [...proto.string(1, "Check these figures"), ...proto.reference(3, 37), ...proto.reference(4, 38)]],
    [37, 212, proto.string(1, "Ada Lovelace")],
    [38, 3056, proto.string(1, "Done")],
    [39, 5000, proto.frame(400, 500, 300, 200)],
  ];
  const files = [[900, "still.png"], [902, "sound.m4a"], [904, "equation.pdf"], [905, "model.usdz"]];
  const metadata = files.flatMap(([id, name]) => proto.message(4, proto.uint(1, id), proto.string(3, name), proto.string(4, name)));
  return zip(new Map([
    ["Index/Document.iwa", iwaOfBytes(objects)],
    ["Index/Metadata.iwa", iwaOfBytes([[50, 11006, metadata]])],
    ["Data/still.png", PIXEL],
    ["Data/sound.m4a", new TextEncoder().encode("sound")],
    ["Data/equation.pdf", new TextEncoder().encode("%PDF-1.4 not really")],
    ["Data/model.usdz", new TextEncoder().encode("model")],
  ]));
}

test("draws Keynote connection lines, drawings, sounds, equations, 3D objects and stand-ins, and keeps sticky comments", () => {
  const opened = call("open", { name: "Objects.key" }, keynoteObjects());
  const slide = opened.state.slides[0].id;
  const [line, drawing, sound, equation, still, model, other, chart] = call("scene", { slide }).result.shapes;
  assert.equal(line.kind, "shape", "the connection line is drawn as a line");
  assert.ok(line.path.includes("L"), "along its own path");
  assert.equal(line.line?.w, 3);
  assert.equal(drawing.kind, "group");
  assert.equal(drawing.children.length, 1, "the drawing keeps its stroke");
  assert.equal(drawing.children[0].kind, "shape");
  assert.equal(sound.kind, "standin");
  assert.equal(sound.label, strings["Object.Audio"]);
  assert.equal(sound.media?.kind, "audio", "the sound still plays");
  assert.equal(equation.kind, "standin");
  assert.equal(equation.label, strings["Object.Equation"]);
  assert.ok(equation.w > 0 && equation.h > 0, "the stand-in keeps the equation's place");
  assert.equal(still.kind, "picture");
  assert.ok(still.src, "the 3D object shows its still");
  assert.equal(still.media, undefined, "and doesn't play");
  assert.equal(model.kind, "standin");
  assert.equal(model.label, strings["Object.3D"]);
  assert.equal(other.kind, "standin");
  assert.equal(other.label, strings["Object.Other"]);
  assert.equal(chart.kind, "standin");
  assert.equal(chart.isChart, true);
  assert.deepEqual(opened.result.omissions.sort(), [
    strings["Notice.Omission.ChartStandIns"], strings["Notice.Omission.Objects3D"],
    strings["Notice.Omission.EquationStandIns"], strings["Notice.Omission.ObjectStandIns"],
  ].sort());
  assert.ok(opened.result.omissions.every((omission) => omission && !omission.includes("Notice.")), "the omissions are worded");
  const [comment] = call("inspect").result.comments;
  assert.equal(comment?.text, "Check these figures");
  assert.equal(comment.author, "Ada Lovelace");
  assert.deepEqual([comment.x, comment.y], [900, 20]);
  assert.deepEqual(comment.replies.map((reply) => reply.text), ["Done"]);

  for (const format of opened.result.saveFormats.map((f) => f.key)) {
    const saved = call("save", { format, keep: true });
    const reopened = call("open", { name: `Objects.${format}` }, saved.payload);
    const shapes = call("scene", { slide: reopened.state.slides[0].id }).result.shapes;
    assert.deepEqual(shapes.map((shape) => shape.kind), [line, drawing, sound, equation, still, model, other, chart].map((s) => s.kind),
      `saved as ${format}`);
    assert.equal(shapes[6].label, strings["Object.Other"], `the stand-in is one still, saved as ${format}`);
    assert.equal(call("inspect").result.comments.length, 1, `the comment is kept, saved as ${format}`);
  }
});

/** A new presentation whose slide holds SmartArt with no drawing of itself: a basic cycle of three points. */
function deckWithSmartArt() {
  call("new", { name: "SmartArt.pptx" });
  const entries = unzip(call("save", { format: "pptx" }).payload);
  const decode = (name) => new TextDecoder().decode(entries.get(name));
  const encode = (name, text) => entries.set(name, new TextEncoder().encode(text));
  const dgm = "http://schemas.openxmlformats.org/drawingml/2006/diagram";
  const a = "http://schemas.openxmlformats.org/drawingml/2006/main";
  const points = ["Plan", "Do", "Check"].map((text, index) => `<dgm:pt modelId="{n${index}}"><dgm:prSet/><dgm:spPr/>
    <dgm:t><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>${text}</a:t></a:r></a:p></dgm:t></dgm:pt>`).join("");
  const connections = [0, 1, 2].map((index) => `<dgm:cxn modelId="{c${index}}" srcId="{doc}" destId="{n${index}}" srcOrd="${index}" destOrd="0"/>`).join("");
  encode("ppt/diagrams/data1.xml", `<dgm:dataModel xmlns:dgm="${dgm}" xmlns:a="${a}"><dgm:ptLst>
    <dgm:pt modelId="{doc}" type="doc"><dgm:prSet loTypeId="urn:microsoft.com/office/officeart/2005/8/layout/cycle2"/><dgm:spPr/></dgm:pt>
    ${points}</dgm:ptLst><dgm:cxnLst>${connections}</dgm:cxnLst><dgm:bg/><dgm:whole/></dgm:dataModel>`);
  encode("ppt/diagrams/layout1.xml", `<dgm:layoutDef xmlns:dgm="${dgm}" uniqueId="urn:microsoft.com/office/officeart/2005/8/layout/cycle2"/>`);
  encode("ppt/diagrams/quickStyle1.xml", `<dgm:styleDef xmlns:dgm="${dgm}" xmlns:a="${a}" uniqueId="urn:microsoft.com/office/officeart/2005/8/quickstyle/simple1"/>`);
  encode("ppt/diagrams/colors1.xml", `<dgm:colorsDef xmlns:dgm="${dgm}" xmlns:a="${a}" uniqueId="urn:test/colors"><dgm:styleLbl name="node1">
    <dgm:fillClrLst meth="repeat"><a:srgbClr val="FF0000"/><a:srgbClr val="00FF00"/></dgm:fillClrLst></dgm:styleLbl></dgm:colorsDef>`);
  const frame = `<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="950" name="Cycle"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
    <p:xfrm><a:off x="914400" y="914400"/><a:ext cx="7315200" cy="4572000"/></p:xfrm><a:graphic>
    <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram"><dgm:relIds xmlns:dgm="${dgm}"
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:dm="rIdDm" r:lo="rIdLo" r:qs="rIdQs" r:cs="rIdCs"/>
    </a:graphicData></a:graphic></p:graphicFrame>`;
  encode("ppt/slides/slide1.xml", decode("ppt/slides/slide1.xml").replace("</p:spTree>", `${frame}</p:spTree>`));
  const relsName = "ppt/slides/_rels/slide1.xml.rels";
  const relationship = (id, type, target) =>
    `<Relationship Id="${id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/${type}" Target="../diagrams/${target}"/>`;
  encode(relsName, decode(relsName).replace("</Relationships>", relationship("rIdDm", "diagramData", "data1.xml")
    + relationship("rIdLo", "diagramLayout", "layout1.xml") + relationship("rIdQs", "diagramQuickStyle", "quickStyle1.xml")
    + relationship("rIdCs", "diagramColors", "colors1.xml") + "</Relationships>"));
  return { bytes: zip(entries), entries };
}

test("lays out SmartArt that has no drawing of itself, and saves its parts as they were", () => {
  const { bytes, entries } = deckWithSmartArt();
  const sceneOf = (opened) => call("scene", { slide: opened.state.slides[0].id }).result.shapes.find((node) => node.name === "Cycle");
  const cycle = sceneOf(call("open", { name: "SmartArt.pptx" }, bytes));
  assert.equal(cycle?.kind, "group", "drawn, not a stand-in");
  const labelled = (node) => node.text && text(node.text) !== "";
  const circles = cycle.children.filter(labelled);
  assert.deepEqual(circles.map((node) => text(node.text)), ["Plan", "Do", "Check"]);
  assert.deepEqual(circles.map((node) => node.fill?.c), ["#ff0000", "#00ff00", "#ff0000"], "in the colours part's colours, in turn");
  const arrows = cycle.children.filter((node) => !labelled(node));
  assert.equal(arrows.length, 3, "an arrow between each");
  assert.ok(arrows.every((node) => node.rot > 0), "turned to point round the ring");

  const saved = unzip(call("save", { format: "pptx", keep: true }).payload);
  for (const name of ["data1", "layout1", "quickStyle1", "colors1"]) {
    assert.deepEqual(saved.get(`ppt/diagrams/${name}.xml`), entries.get(`ppt/diagrams/${name}.xml`), `keeps ${name} as it was`);
  }
  assert.ok(![...saved.keys()].some((name) => name.includes("drawing")), "makes up no drawing");
  const reopened = sceneOf(call("open", { name: "Again.pptx" }, zip(saved)));
  assert.deepEqual(reopened.children.filter(labelled).map((node) => text(node.text)), ["Plan", "Do", "Check"]);
});

// MARK: - Slide transitions

/** A new presentation saved with `transition` (slide XML) after its first slide's shapes. */
function deckWithTransition(transition) {
  call("new", { name: "Transitions.pptx" });
  const entries = unzip(call("save", { format: "pptx" }).payload);
  const name = "ppt/slides/slide1.xml";
  const namespaces = 'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" ';
  const slide = new TextDecoder().decode(entries.get(name)).replace("<p:sld ", `<p:sld ${namespaces}`);
  const anchor = slide.includes("</p:clrMapOvr>") ? "</p:clrMapOvr>" : "</p:cSld>";
  entries.set(name, new TextEncoder().encode(slide.replace(anchor, anchor + transition)));
  return zip(entries);
}

const alternate = (choice, fallback = "<p:fade/>") => `<mc:AlternateContent><mc:Choice Requires="p14"><p:transition spd="slow" p14:dur="1500" advTm="2000">${choice}</p:transition></mc:Choice>`
  + `<mc:Fallback><p:transition spd="slow" advTm="2000">${fallback}</p:transition></mc:Fallback></mc:AlternateContent>`;

test("plays a slide's transition as keyframes the browser animates, a cross-fade when motion is reduced", () => {
  const opened = call("open", { name: "Push.pptx" }, deckWithTransition(alternate('<p:push dir="u"/>')));
  const slide = opened.state.slides[0].id;
  assert.equal(opened.result.unsupported.length, 0, "a push plays, so nothing is said about it");
  const timeline = call("timeline", { slide }).result;
  assert.equal(timeline.transition, 1.5, "the exact duration, from p14:dur");
  assert.equal(timeline.after, 2, "moves on by itself after its time");
  const { w, h } = call("scene", { slide }).result;
  const push = call("transition", { slide }).result;
  assert.equal(push.duration, 1.5);
  assert.deepEqual(push.layers.map((layer) => layer.content), ["outgoing", "incoming"]);
  const incoming = push.layers[1].keyframes;
  assert.ok(incoming.length >= 45, "a moment every thirtieth of a second");
  assert.equal(incoming[0].offset, 0);
  assert.equal(incoming.at(-1).offset, 1);
  assert.equal(incoming[0].transform, `matrix(1, 0, 0, 1, 0, ${h})`, "the new slide starts below");
  assert.equal(incoming.at(-1).transform, "matrix(1, 0, 0, 1, 0, 0)");
  assert.equal(push.layers[0].keyframes.at(-1).transform, `matrix(1, 0, 0, 1, 0, -${h})`, "the old one leaves upwards");
  assert.ok(w > 0);

  const calm = call("transition", { slide, reduceMotion: true }).result;
  assert.deepEqual(calm.layers.map((layer) => layer.content), ["outgoing", "incoming"]);
  assert.ok(calm.layers.every((layer) => layer.keyframes.every((frame) => frame.transform === "matrix(1, 0, 0, 1, 0, 0)")), "nothing moves");
  assert.equal(calm.layers[1].keyframes[0].opacity, 0);
  assert.equal(calm.layers[1].keyframes.at(-1).opacity, 1);
});

test("plays PowerPoint 2010's and 2013's own transitions as themselves", () => {
  const vortex = call("open", { name: "Vortex.pptx" }, deckWithTransition(alternate('<p14:vortex dir="r"/>')));
  assert.equal(vortex.result.unsupported.length, 0, "a vortex plays, so nothing is said about it");
  const { w } = call("scene", { slide: vortex.state.slides[0].id }).result;
  const played = call("transition", { slide: vortex.state.slides[0].id }).result;
  assert.deepEqual(played.layers.slice(0, 2).map((layer) => layer.content), ["black", "incoming"]);
  const tiles = played.layers.slice(2);
  assert.equal(tiles.length, 24, "the old slide in tiles");
  assert.ok(tiles.every((layer) => layer.content === "outgoing"));
  assert.ok(tiles.every((layer) => layer.keyframes[0].transform === "matrix(1, 0, 0, 1, 0, 0)"), "all in place to start with");
  assert.ok(tiles.every((layer) => layer.keyframes.at(-1).opacity === 0), "all gone by the end");
  const flown = tiles.map((layer) => Number(layer.keyframes.at(-1).transform.match(/, (-?[\d.]+), -?[\d.]+\)$/)[1]));
  assert.ok(flown.every((x) => x > w / 2), "each flown off to the right");
  assert.match(tiles[0].keyframes[0].clipPath, /^path\(evenodd, "M/, "each tile cut out of the slide");
  assert.equal(played.layers[1].keyframes.at(-1).opacity, 1);
  const calm = call("transition", { slide: vortex.state.slides[0].id, reduceMotion: true }).result;
  assert.deepEqual(calm.layers.map((layer) => layer.content), ["outgoing", "incoming"], "a cross-fade when motion is reduced");

  const p15 = 'xmlns:p15="http://schemas.microsoft.com/office/powerpoint/2012/main"';
  const curl = `<mc:AlternateContent ${p15}><mc:Choice Requires="p15"><p:transition spd="slow" p14:dur="1250"><p15:prstTrans prst="peelOff"/></p:transition></mc:Choice>`
    + '<mc:Fallback><p:transition spd="slow"><p:fade/></p:transition></mc:Fallback></mc:AlternateContent>';
  const peel = call("open", { name: "Peel.pptx" }, deckWithTransition(curl));
  assert.equal(peel.result.unsupported.length, 0);
  const peeled = call("transition", { slide: peel.state.slides[0].id }).result;
  assert.equal(peeled.duration, 1.25);
  assert.deepEqual(peeled.layers.map((layer) => layer.content), ["incoming", "black", "outgoing", "white", "outgoing"]);
  const back = peeled.layers[4].keyframes[Math.floor(peeled.layers[4].keyframes.length / 2)];
  const [a, b, c, d] = back.transform.match(/-?[\d.]+/g).map(Number);
  assert.ok(a * d - b * c < 0, "the back of the page, mirrored in the fold");
  assert.equal(peeled.layers[2].keyframes.at(-1).clipPath, "polygon(0 0, 0 0, 0 0)", "nothing of the old slide left lying");
});

test("clips patterned transitions, plays unknown ones as a fade, and saves them as they were", () => {
  const blinds = call("open", { name: "Blinds.pptx" }, deckWithTransition('<p:transition spd="med"><p:blinds dir="vert"/></p:transition>'));
  const slide = blinds.state.slides[0].id;
  const played = call("transition", { slide }).result;
  assert.equal(played.duration, 0.75);
  const middle = played.layers[1].keyframes[Math.floor(played.layers[1].keyframes.length / 2)];
  assert.match(middle.clipPath, /^path\(evenodd, "M/);
  assert.equal(played.layers[1].keyframes[0].clipPath, "polygon(0 0, 0 0, 0 0)", "nothing of the new slide to start with");

  const unknown = call("open", { name: "Unknown.pptx" }, deckWithTransition(alternate('<p14:somethingNew dir="r"/>')));
  assert.equal(unknown.result.unsupported.length, 1, "says the effect plays as something simpler");
  const fallback = call("transition", { slide: unknown.state.slides[0].id }).result;
  assert.deepEqual(fallback.layers.map((layer) => layer.content), ["outgoing", "incoming"]);
  assert.equal(fallback.layers[1].keyframes.at(-1).opacity, 1);
  const saved = new TextDecoder().decode(unzip(call("save", { format: "pptx", keep: true }).payload).get("ppt/slides/slide1.xml"));
  assert.match(saved, /<p14:somethingNew dir="r"\/>/);
  assert.match(saved, /p14:dur="1500"/);

  const none = call("open", { name: "None.pptx" }, deckWithTransition(""));
  assert.equal(call("timeline", { slide: none.state.slides[0].id }).result.transition, 0);
  assert.ok(call("transition", { slide: none.state.slides[0].id }).result == null, "a slide without one cuts");
});

/** Text boxes that shrink on overflow, some saying how far and some not, and a table whose cell says to shrink. */
/** Two slides sharing a box by name and, as a box and an ellipse, by a `!!` name; the second arrives with a Morph. */
function deckWithMorph() {
  call("new", { name: "Morph.pptx" });
  call("addSlide");
  const entries = unzip(call("save", { format: "pptx" }).payload);
  const shape = (id, name, preset, x, cx, rot, colour) => `<p:sp><p:nvSpPr><p:cNvPr id="${id}" name="${name}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>`
    + `<p:spPr><a:xfrm${rot ? ` rot="${rot}"` : ""}><a:off x="${x}" y="914400"/><a:ext cx="${cx}" cy="914400"/></a:xfrm>`
    + `<a:prstGeom prst="${preset}"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="${colour}"/></a:solidFill></p:spPr></p:sp>`;
  const morph = '<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main">'
    + '<mc:Choice xmlns:p159="http://schemas.microsoft.com/office/powerpoint/2015/09/main" Requires="p159"><p:transition spd="slow" p14:dur="1000"><p159:morph option="byObject"/></p:transition></mc:Choice>'
    + '<mc:Fallback><p:transition spd="slow"><p:fade/></p:transition></mc:Fallback></mc:AlternateContent>';
  const edit = (name, shapes, transition = "") => {
    const slide = new TextDecoder().decode(entries.get(name)).replace("</p:spTree>", `${shapes}</p:spTree>`);
    const anchor = slide.includes("</p:clrMapOvr>") ? "</p:clrMapOvr>" : "</p:cSld>";
    entries.set(name, new TextEncoder().encode(slide.replace(anchor, anchor + transition)));
  };
  edit("ppt/slides/slide1.xml", shape(901, "Box", "rect", 914400, 914400, 0, "FF0000") + shape(902, "!!Hero", "rect", 4572000, 914400, 0, "00FF00")
    + shape(903, "Leaving", "rect", 7315200, 914400, 0, "888888"));
  edit("ppt/slides/slide2.xml", shape(911, "Box", "rect", 2743200, 1828800, 5400000, "0000FF") + shape(912, "!!Hero", "ellipse", 4572000, 914400, 0, "00FF00")
    + shape(913, "Arriving", "rect", 7315200, 914400, 0, "888888"), morph);
  return zip(entries);
}

test("plays a Morph as pairs of shared shapes placed together over a cross-fade, and saves it as it was", () => {
  const opened = call("open", { name: "Morph.pptx" }, deckWithMorph());
  assert.equal(opened.result.unsupported.length, 0, "a Morph plays, so nothing is said about it");
  const [first, second] = opened.state.slides.map((slide) => slide.id);
  const ids = (slide) => call("scene", { slide }).result.shapes.map((node) => node.id);
  assert.equal(call("timeline", { slide: second }).result.transition, 1);
  const played = call("transition", { slide: second, from: first, fromBegun: 0 }).result;
  assert.deepEqual(played.layers.map((layer) => layer.content), ["outgoing", "incoming"], "the rest cross-fades");
  assert.equal(played.layers[1].keyframes[0].opacity, 0);
  // The layout's placeholders pair too; the shapes added here come last.
  const pairs = played.morph.slice(-2);
  assert.equal(played.morph.length, ids(second).length - 1, "every shape but the one only this slide has: the box by name, the hero by its !! name");
  for (const pair of pairs) {
    assert.ok(ids(first).includes(pair.from) && ids(second).includes(pair.to));
    assert.equal(pair.keyframes[0].from, "matrix(1, 0, 0, 1, 0, 0)", "the shape being left starts where it sits");
    assert.equal(pair.keyframes.at(-1).to, "matrix(1, 0, 0, 1, 0, 0)", "the shape arriving ends where it sits");
    assert.equal(pair.keyframes[0].mix, 0);
    assert.equal(pair.keyframes.at(-1).mix, 1);
  }
  // The box ends twice as wide, a quarter turn round, 3 inches to the right of where it began (its middle 216 + 72 points on).
  const end = pairs[0].keyframes.at(-1).from.match(/-?[\d.]+/g).map(Number);
  assert.ok(Math.abs(end[0]) < 0.001 && Math.abs(end[1] - 2) < 0.001 && Math.abs(end[2] + 1) < 0.001 && Math.abs(end[3]) < 0.001, `turned and stretched: ${end}`);
  assert.ok(call("transition", { slide: second, from: first, reduceMotion: true }).result.morph === undefined, "a plain cross-fade when motion is reduced");
  const saved = new TextDecoder().decode(unzip(call("save", { format: "pptx" }).payload).get("ppt/slides/slide2.xml"));
  assert.ok(saved.includes('<p159:morph option="byObject"/>'), "saved as it was");
});

function deckWithShrinkingText() {
  call("new", { name: "Shrinking.pptx" });
  const entries = unzip(call("save", { format: "pptx" }).payload);
  const name = "ppt/slides/slide1.xml";
  const box = (id, label, fit, bodyAttributes = "") => `
    <p:sp><p:nvSpPr><p:cNvPr id="${id}" name="${label}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr><a:xfrm><a:off x="457200" y="457200"/><a:ext cx="1828800" cy="457200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
      <p:txBody><a:bodyPr wrap="square"${bodyAttributes}>${fit}</a:bodyPr><a:lstStyle/>
        <a:p><a:r><a:rPr lang="en-US"/><a:t>Text that runs on past the bottom of its box</a:t></a:r></a:p></p:txBody>
    </p:sp>`;
  const shapes = box(950, "Unsaid", "<a:normAutofit/>")
    + box(951, "Said", '<a:normAutofit fontScale="62500" lnSpcReduction="20000"/>')
    + box(952, "Closed up", '<a:normAutofit lnSpcReduction="10000"/>')
    + box(953, "Columns", "<a:normAutofit/>", ' numCol="2"')
    + box(954, "Upright", "<a:normAutofit/>", ' vert="eaVert"')
    + `<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="955" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
      <p:xfrm><a:off x="457200" y="3200400"/><a:ext cx="914400" cy="370332"/></p:xfrm>
      <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr/>
        <a:tblGrid><a:gridCol w="914400"/></a:tblGrid>
        <a:tr h="370332"><a:tc><a:txBody><a:bodyPr><a:normAutofit fontScale="40000"/></a:bodyPr><a:p><a:r><a:rPr lang="en-US"/><a:t>Cell</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc></a:tr>
      </a:tbl></a:graphicData></a:graphic></p:graphicFrame>`;
  entries.set(name, new TextEncoder().encode(new TextDecoder().decode(entries.get(name)).replace("</p:spTree>", `${shapes}</p:spTree>`)));
  return zip(entries);
}

test("shrinks overflowing text in PowerPoint's steps unless the file says how far, but never in a table", () => {
  const opened = call("open", { name: "Shrinking.pptx" }, deckWithShrinkingText());
  const shapes = call("scene", { slide: opened.state.slides[0].id }).result.shapes;
  const body = (label) => shapes.find((node) => node.name === label)?.text;
  const steps = body("Unsaid").steps;
  assert.deepEqual(steps[0], [1, 0.1], "lines close up a tenth first");
  assert.deepEqual(steps[1], [1, 0.2], "and then a fifth");
  assert.deepEqual(steps.map(([scale]) => scale).filter((scale, index, all) => all.indexOf(scale) === index),
    [1, 0.925, 0.85, 0.775, 0.7, 0.625, 0.55, 0.475, 0.4, 0.25], "then the letters shrink as PowerPoint's fontScale steps");
  assert.ok(steps.slice(6).every(([, reduce]) => reduce === 0.2), "a fifth closer from 77.5% down");
  assert.deepEqual(steps.at(-1), [0.25, 0.2], "a quarter is the least");

  const said = body("Said");
  assert.equal(said.steps, undefined, "a file that says how far is drawn as it says");
  assert.deepEqual([said.scale, said.reduce], [0.625, 0.2]);
  assert.deepEqual(body("Closed up").steps[0], [1, 0.2], "lines PowerPoint closed up go on from there");
  assert.equal(body("Columns").cols, 2);
  assert.deepEqual(body("Columns").steps, steps, "text in columns shrinks the same way");
  assert.equal(body("Upright").vert, "eaVert");
  assert.deepEqual(body("Upright").steps, steps, "and vertical text");

  const cell = shapes.find((node) => node.name === "Table").table.cells[0].text;
  assert.equal(cell.fit, undefined, "a table's rows grow rather than its text shrink");
  assert.equal(cell.steps, undefined);
});

test("keeps WordArt warps when the text is typed into, saved and reopened", () => {
  call("new", { name: "Untitled.pptx" });
  const opened = call("open", { name: "WordArt.pptx" }, deckWithShapes());
  const slide = opened.state.slides[0].id;
  const waved = call("scene", { slide }).result.shapes.find((node) => node.name === "Waved");
  call("select", { slide, shapes: [waved.id] });
  call("beginText", { shape: waved.id });
  call("setText", { paras: [{ src: 0, runs: [{ src: [0, 0], t: "Typed" }] }, { src: 1, runs: [{ src: [1, 0], t: "Over" }] }] });
  call("endText");
  const saved = call("save", { format: "pptx" }).payload;
  const xml = new TextDecoder().decode(unzip(saved).get("ppt/slides/slide1.xml"));
  const shape = xml.slice(xml.indexOf('name="Waved"'));
  assert.match(shape, /<a:bodyPr[^>]*><a:prstTxWarp prst="textWave1"><a:avLst><a:gd fmla="val 20000" name="adj1"\/><a:gd fmla="val 0" name="adj2"\/><\/a:avLst><\/a:prstTxWarp>/, "kept as it was");
  assert.match(shape, /<a:t>Typed<\/a:t>/);

  const reopened = call("open", { name: "WordArt again.pptx" }, saved);
  const again = call("scene", { slide: reopened.state.slides[0].id }).result.shapes;
  const wave = again.find((node) => node.name === "Waved").text;
  assert.equal(text(wave), "Typed\nOver");
  assert.deepEqual(wave.warp, waved.text.warp, "warped just as before");
  assert.equal(again.find((node) => node.name === "Arched").text.warp?.[0].out, true);
});

test("edits glow, soft edges, inner shadow, bevel, depth, text warp and pattern fills, and saves them", () => {
  call("new", { name: "Untitled.pptx" });
  const opened = call("open", { name: "Effects.pptx" }, deckWithShapes());
  const slide = opened.state.slides[0].id;
  const choices = opened.result.choices;
  assert.equal(choices.patterns.length, 48, "offers PowerPoint's patterns");
  assert.ok(choices.textWarps.some((warp) => warp.id === "textArchUp"), "offers the warps");
  const lined = call("scene", { slide }).result.shapes.find((node) => node.name === "Lined");
  call("select", { slide, shapes: [lined.id] });
  call("setEffect", { glow: 8 });
  call("setEffect", { glowColor: "#00ff00" });
  call("setEffect", { softEdge: 5 });
  call("setEffect", { innerShadow: "topLeft" });
  call("setEffect", { bevel: "artDeco" });
  call("setEffect", { depth: 18 });
  call("setEffect", { camera: "obliqueTopLeft" });
  call("setEffect", { warp: "textArchUp" });
  call("setFill", { fill: { kind: "pattern", preset: "smCheck", color: "#ff0000", background: "#ffffff" } });
  const shape = call("inspect").result.shape;
  assert.deepEqual([shape.glow, shape.glowColor, shape.softEdge, shape.innerShadow], [8, "#00ff00", 5, "topLeft"]);
  assert.deepEqual([shape.bevel, shape.depth, shape.camera, shape.warp], ["artDeco", 18, "obliqueTopLeft", "textArchUp"]);
  assert.equal(shape.fill.preset, "smCheck");

  const saved = call("save", { format: "pptx" }).payload;
  const xml = new TextDecoder().decode(unzip(saved).get("ppt/slides/slide1.xml"));
  const lines = xml.slice(xml.indexOf('name="Lined"'), xml.indexOf("</p:sp>", xml.indexOf('name="Lined"')));
  assert.match(lines, /<a:pattFill prst="smCheck">/);
  assert.match(lines, /<a:effectLst><a:glow rad="101600"><a:srgbClr val="00FF00"><a:alpha val="40000"\/><\/a:srgbClr><\/a:glow><a:innerShdw [^>]*dir="13500000"[^>]*>.*<\/a:innerShdw><a:softEdge rad="63500"\/><\/a:effectLst>/);
  assert.match(lines, /<a:scene3d><a:camera prst="obliqueTopLeft"\/><a:lightRig dir="t" rig="threePt"\/><\/a:scene3d><a:sp3d extrusionH="228600"><a:bevelT h="76200" prst="artDeco" w="76200"\/><\/a:sp3d>/);
  assert.match(lines, /<a:prstTxWarp prst="textArchUp">/);

  // Taken off again, nothing is left behind.
  call("setEffect", { glow: 0, softEdge: 0, innerShadow: "none", bevel: "none", depth: 0, camera: "orthographicFront", warp: "textNoShape" });
  const plain = call("inspect").result.shape;
  assert.deepEqual([plain.glow, plain.softEdge, plain.innerShadow, plain.bevel, plain.depth, plain.warp], [0, 0, "none", "none", 0, "textNoShape"]);
  const again = new TextDecoder().decode(unzip(call("save", { format: "pptx" }).payload).get("ppt/slides/slide1.xml"));
  const after = again.slice(again.indexOf('name="Lined"'), again.indexOf("</p:sp>", again.indexOf('name="Lined"')));
  assert.doesNotMatch(after, /<a:glow|<a:softEdge|<a:innerShdw|<a:sp3d|<a:scene3d|prstTxWarp/);
});

test("makes custom shows, plays them in their order and keeps them on saving", () => {
  call("new", { name: "Shows.pptx" });
  const layout = call("info").result.layouts[1].path;
  call("addSlide", { layout });
  call("addSlide", { layout });
  const slides = call("info").state.slides.map((slide) => slide.id);
  const id = call("addCustomShow", { slides: [slides[2]] }).result;
  call("setCustomShowSlides", { id, slides: [slides[2], slides[0]] });
  call("renameCustomShow", { id, name: "Highlights" });
  const info = call("info").result;
  assert.deepEqual(info.customShows, [{ id, name: "Highlights", slides: [slides[2], slides[0]] }]);
  assert.deepEqual(call("slideshowOrder", { customShow: id }).result, [slides[2], slides[0]]);
  assert.deepEqual(call("slideshowOrder").result, slides);

  call("insertTextBox");
  call("setLink", { link: { customShow: id, return: true } });
  const linked = call("scene", { slide: slides[2] }).result.shapes.find((node) => node.link);
  assert.deepEqual(linked.link, { customShow: id, return: true });

  const saved = call("save", { format: "pptx", keep: true }).payload;
  const reopened = call("open", { name: "Shows again.pptx" }, saved);
  const again = reopened.state.slides.map((slide) => slide.id);
  assert.deepEqual(call("info").result.customShows.map((show) => show.slides), [[again[2], again[0]]]);
  call("duplicateCustomShow", { id });
  call("deleteCustomShow", { id });
  assert.deepEqual(call("info").result.customShows.map((show) => show.name), ["Highlights Copy"]);
});

test("honours and keeps the slideshow settings", () => {
  call("new", { name: "Settings.pptx" });
  const layout = call("info").result.layouts[1].path;
  call("addSlide", { layout });
  call("addSlide", { layout });
  const slides = call("info").state.slides.map((slide) => slide.id);
  call("toggleHidden", { ids: [slides[1]] });
  call("showSettings", { range: "slides", from: 2, to: 3 });
  assert.deepEqual(call("slideshowOrder").result, [slides[2]], "plays the range, without its hidden slide");
  call("showSettings", { kiosk: true, restart: 120, timings: false, animations: false, narration: false });
  const show = call("info").result.show;
  assert.deepEqual(show, { range: "slides", from: 2, to: 3, kiosk: true, restart: 120, loop: true, timings: true, animations: false, narration: false });
  assert.equal(call("timeline", { slide: slides[0] }).result.loop, true, "a kiosk show loops");

  const saved = call("save", { format: "pptx", keep: true }).payload;
  call("open", { name: "Settings again.pptx" }, saved);
  assert.deepEqual(call("info").result.show, show);
  call("showSettings", { range: "all", kiosk: false });
  assert.equal(call("info").result.show.timings, false);
});

test("reads, edits and saves document properties", () => {
  call("new", { name: "Properties.pptx" });
  call("setProperties", { title: "Quarterly <Review>", author: "Ada", keywords: "plans, numbers", comments: "Line one\nLine two" });
  assert.equal(call("properties").result.title, "Quarterly <Review>");
  const before = Date.now() - 1000;
  const saved = unzip(call("save", { format: "pptx", author: "Grace" }).payload);
  const core = new TextDecoder().decode(saved.get("docProps/core.xml"));
  assert.match(core, /<dc:title>Quarterly &lt;Review&gt;<\/dc:title>/);
  assert.match(core, /<cp:lastModifiedBy>Grace<\/cp:lastModifiedBy>/);
  const reopened = call("open", { name: "Properties.pptx" }, zip(saved));
  assert.ok(reopened);
  const properties = call("properties").result;
  assert.equal(properties.author, "Ada");
  assert.equal(properties.comments, "Line one\nLine two");
  assert.equal(properties.lastModifiedBy, "Grace");
  assert.ok(Date.parse(properties.modified) >= before, "modified when saved");
  // A draft kept on the device leaves the saving stamp alone.
  const draft = new TextDecoder().decode(unzip(call("save", { keep: true, draft: true, author: "Someone" }).payload).get("docProps/core.xml"));
  assert.match(draft, /<cp:lastModifiedBy>Grace<\/cp:lastModifiedBy>/);
});

test("changes the theme's colours and fonts, every slide follows, and saves them", () => {
  call("new", { name: "Theme.pptx" });
  const { result: info } = call("info");
  assert.equal(info.canEditTheme, true);
  call("addSlide", { layout: info.layouts[1].path });
  call("insertShape", { preset: "rect" });
  const before = call("inspect").result.themeSettings;
  assert.equal(before.colors.length, 12);
  assert.deepEqual(before.colors.map((color) => color.slot).slice(0, 5), ["dk1", "lt1", "dk2", "lt2", "accent1"]);
  assert.ok(before.colors.every((color) => color.label && /^#[0-9a-f]{6}$/.test(color.color)));
  assert.ok(JSON.stringify(call("scene").result).includes(before.colors[4].color), "the shape is filled with accent 1");

  call("setTheme", { colors: { accent1: "#8e44ad" }, heading: "Georgia", body: "" });
  const after = call("inspect").result.themeSettings;
  assert.equal(after.colors[4].color, "#8e44ad");
  assert.equal(after.colors[5].color, before.colors[5].color, "other colours stay");
  assert.equal(after.heading, "Georgia");
  assert.equal(after.body, before.body, "an empty font leaves the body font alone");
  assert.ok(call("info").result.fonts.includes("Georgia"));
  for (const slide of call("info").state.slides) {
    assert.ok(!JSON.stringify(call("scene", { slide: slide.id }).result).includes(before.colors[4].color), "no slide keeps the old accent");
  }
  assert.ok(JSON.stringify(call("scene").result).includes("#8e44ad"), "the shape follows the new accent");

  call("undo");
  assert.equal(call("inspect").result.themeSettings.colors[4].color, before.colors[4].color);
  call("redo");
  const { payload } = call("save", { format: "pptx" });
  call("open", { name: "Theme.pptx" }, payload);
  const reopened = call("inspect").result.themeSettings;
  assert.equal(reopened.colors[4].color, "#8e44ad");
  assert.equal(reopened.heading, "Georgia");
});

function deckWithLineStyles() {
  call("new", { name: "Lines.pptx" });
  const entries = unzip(call("save", { format: "pptx" }).payload);
  const name = "ppt/slides/slide1.xml";
  const run = (attributes, children = "") => `<a:r><a:rPr lang="en-US" ${attributes}>${children}</a:rPr><a:t>Line</a:t></a:r>`;
  const shapes = `
    <p:sp><p:nvSpPr><p:cNvPr id="960" name="Lined"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr><a:xfrm><a:off x="457200" y="457200"/><a:ext cx="4572000" cy="457200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
      <p:txBody><a:bodyPr wrap="none"/><a:lstStyle/><a:p>${run('u="wavyDbl"', '<a:uFill><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></a:uFill>')}${run('u="dotDashHeavy" strike="dblStrike"')}${run('strike="sngStrike"')}</a:p></p:txBody>
    </p:sp>`;
  entries.set(name, new TextEncoder().encode(new TextDecoder().decode(entries.get(name)).replace("</p:spTree>", `${shapes}</p:spTree>`)));
  return zip(entries);
}

test("draws underline and strikethrough styles and colours, and keeps them through an edit", () => {
  const opened = call("open", { name: "Lines.pptx" }, deckWithLineStyles());
  const slide = opened.state.slides[0].id;
  const runs = call("scene", { slide }).result.shapes.find((node) => node.name === "Lined").text.paras[0].runs;
  assert.equal(runs[0].u, "wavyDbl");
  assert.ok(runs[0].uc, "the underline has its own colour");
  assert.equal(runs[1].u, "dotDashHeavy");
  assert.equal(runs[1].s, 2, "a double strikethrough");
  assert.equal(runs[2].s, 1);
  assert.equal(runs[2].u, undefined);
  const shape = call("scene", { slide }).result.shapes.find((node) => node.name === "Lined");
  call("select", { slide, shapes: [shape.id] });
  call("format", { set: { bold: true } });
  call("beginText", { shape: shape.id });
  call("setText", { paras: [{ src: 0, runs: [{ src: [0, 0], t: "Edited" }, { src: [0, 1], t: "Line" }, { src: [0, 2], t: "Line" }] }] });
  call("endText");
  const saved = new TextDecoder().decode(unzip(call("save", { format: "pptx", keep: true }).payload).get("ppt/slides/slide1.xml"));
  assert.match(saved, /<a:t>Edited<\/a:t>/);
  assert.match(saved, /<a:uFill><a:solidFill><a:srgbClr val="FF0000"\/><\/a:solidFill><\/a:uFill>/);
  assert.match(saved, /u="wavyDbl"/);
  assert.match(saved, /u="dotDashHeavy"[^>]*strike="dblStrike"|strike="dblStrike"[^>]*u="dotDashHeavy"/);
});

test("edits masters and layouts in master view, and has slides follow them", () => {
  const made = call("new", { name: "Untitled.pptx" });
  assert.equal(made.result.canEditMasters, true);
  call("addSlide", { layout: made.result.layouts.find((layout) => layout.name === "Title and Content").path });
  const slides = call("info").state.slides.map((slide) => slide.id);

  // The masters and layouts take the slides' place, opening on the slide's layout.
  let state = call("masterView", { on: true }).state;
  assert.equal(state.masterView, true);
  assert.deepEqual(state.slides.map((slide) => slide.role), ["master", "layout", "layout", "layout", "layout", "layout"]);
  const content = state.slides.find((slide) => slide.name === "Title and Content");
  assert.equal(state.sel.slide, content.id);
  assert.equal(content.canDelete, false, "a layout a slide is built on stays");

  // Its title is moved and made bold; the layout's own scene shows both.
  const title = call("scene", { slide: content.id }).result.shapes.find((node) => node.ph === "title");
  call("select", { slide: content.id, shapes: [title.id] });
  call("setFrames", { frames: { [title.id]: { x: 60, y: 300, w: 500, h: 80 } } });
  call("format", { set: { bold: true } });
  const moved = call("scene", { slide: content.id }).result.shapes.find((node) => node.ph === "title");
  assert.deepEqual([moved.x, moved.y, moved.w, moved.h], [60, 300, 500, 80]);

  // A layout is added, renamed and copied; one no slide uses is deleted.
  call("select", { slide: content.id, shapes: [] });
  state = call("addLayout").state;
  const added = state.slides.find((slide) => slide.id === state.sel.slide);
  assert.equal(added.name, "Custom Layout");
  assert.equal(added.canDelete, true);
  call("renameLayout", { ids: [added.id], name: "Quote" });
  call("duplicateSlides", { ids: [added.id] });
  state = call("deleteSlides", { ids: [state.slides.find((slide) => slide.name === "Blank").id] }).state;
  assert.deepEqual(state.slides.slice(1).map((slide) => slide.name), ["Title Slide", "Title and Content", "Quote", "Quote Copy", "Section Header", "Title Only"]);
  // The master's background is every layout's that has none of its own.
  call("select", { slide: state.slides[0].id, shapes: [] });
  call("setBackground", { fill: { kind: "solid", color: "#203864" } });
  assert.equal(call("scene", { slide: content.id }).result.bg.c, call("scene", { slide: state.slides[0].id }).result.bg.c);

  // Back among the slides, the one built on the layout has followed it.
  const left = call("masterView", { on: false });
  assert.equal(left.state.masterView, false);
  assert.deepEqual(left.state.slides.map((slide) => slide.id), slides);
  assert.equal(left.state.sel.slide, slides[1]);
  assert.deepEqual(call("info").result.layouts.map((layout) => layout.name), ["Title Slide", "Title and Content", "Quote", "Quote Copy", "Section Header", "Title Only"]);
  const followed = call("scene", { slide: slides[1], editing: true }).result;
  const followedTitle = followed.shapes.find((node) => node.ph === "title");
  assert.deepEqual([followedTitle.x, followedTitle.y, followedTitle.w, followedTitle.h], [60, 300, 500, 80]);

  // Saved, the layouts are parts of the file, and it opens the same way.
  const saved = call("save", { format: "pptx" }).payload;
  const parts = unzip(saved);
  const layout = new TextDecoder().decode(parts.get("ppt/slideLayouts/slideLayout2.xml"));
  assert.match(layout, /<a:off x="762000" y="3810000"\/><a:ext cx="6350000" cy="1016000"\/>/);
  assert.match(layout, /<a:lvl1pPr><a:defRPr b="1"\/><\/a:lvl1pPr>/);
  assert.ok(!parts.has("ppt/slideLayouts/slideLayout5.xml"), "the deleted layout is gone");
  const master = new TextDecoder().decode(parts.get("ppt/slideMasters/slideMaster1.xml"));
  assert.equal(master.match(/<p:sldLayoutId /g).length, 6);
  assert.match(master, /<p:bg><p:bgPr><a:solidFill><a:srgbClr val="203864"\/><\/a:solidFill>/);
  const reopened = call("open", { name: "Masters.pptx" }, saved);
  assert.deepEqual(reopened.result.layouts.map((entry) => entry.name), ["Title Slide", "Title and Content", "Quote", "Quote Copy", "Section Header", "Title Only"]);
  const again = call("scene", { slide: reopened.state.slides[1].id, editing: true }).result.shapes.find((node) => node.ph === "title");
  assert.deepEqual([again.x, again.y], [60, 300]);
});

// MARK: - Sections and zooms

test("organises slides into sections, and keeps them on save", () => {
  call("new", { name: "Sections.pptx" });
  for (let index = 0; index < 4; index++) call("addSlide");
  let { state } = call("info");
  const slides = state.slides.map((slide) => slide.id);
  const added = call("addSection", { slide: slides[2] });
  assert.equal(typeof added.result, "string", "the new section's id, to name it");
  assert.deepEqual(added.state.sections.map((section) => section.slides.length), [2, 3]);
  call("renameSection", { id: added.result, name: "Results" });
  const later = call("addSection", { slide: slides[4] }).result;
  call("renameSection", { id: later, name: "Wrap-up" });
  state = call("moveSection", { id: later, to: 0 }).state;
  assert.deepEqual(state.sections.map((section) => section.name), ["Wrap-up", strings["Section.Default"], "Results"]);
  assert.equal(state.slides[0].id, slides[4], "the section's slides move with it");
  state = call("moveSlidesToSection", { ids: [slides[0]], section: later }).state;
  assert.deepEqual(state.sections[0].slides, [slides[4], slides[0]]);

  const saved = unzip(call("save", { format: "pptx", keep: true }).payload);
  const main = new TextDecoder().decode(saved.get("ppt/presentation.xml"));
  assert.match(main, /<p14:section [^>]*name="Results"/);
  const reopened = call("open", { name: "Again.pptx" }, zip(saved)).state;
  assert.deepEqual(reopened.sections.map((section) => section.name), ["Wrap-up", strings["Section.Default"], "Results"]);
  assert.deepEqual(reopened.sections.map((section) => section.slides.length), [2, 1, 2]);
  const removed = call("removeSection", { id: reopened.sections[1].id }).state;
  assert.deepEqual(removed.sections.map((section) => section.slides.length), [3, 2], "its slides join the section before");
  assert.equal(call("removeAllSections").state.sections.length, 0);
});

test("follows slide and section zooms, drawing each from the slide it leads to", () => {
  call("new", { name: "Zooms.pptx" });
  call("addSlide");
  call("addSlide");
  const { state } = call("info");
  const section = call("addSection", { slide: state.slides[2].id }).result;
  const entries = unzip(call("save", { format: "pptx" }).payload);
  const zoom = (prefix, uri, element, object, x) => `<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">`
    + `<mc:Choice xmlns:${prefix}="${uri}" Requires="${prefix}"><p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="${x}" name="Zoom ${x}"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>`
    + `<p:xfrm><a:off x="${x * 100000}" y="0"/><a:ext cx="3657600" cy="2057400"/></p:xfrm><a:graphic><a:graphicData uri="${uri}">`
    + `<${prefix}:${element}>${object}</${prefix}:${element}></a:graphicData></a:graphic></p:graphicFrame></mc:Choice>`
    + `<mc:Fallback><p:pic><p:nvPicPr><p:cNvPr id="${x}" name="Zoom ${x}"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId99"/></p:blipFill>`
    + `<p:spPr><a:xfrm><a:off x="${x * 100000}" y="0"/><a:ext cx="3657600" cy="2057400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></mc:Fallback></mc:AlternateContent>`;
  const slideZoom = zoom("pslz", "http://schemas.microsoft.com/office/powerpoint/2016/slidezoom", "sldZm",
    '<pslz:sldZmObj sldId="257"><pslz:zmPr id="{1}" transitionDur="1000"/></pslz:sldZmObj>', 10);
  const sectionZoom = zoom("psez", "http://schemas.microsoft.com/office/powerpoint/2016/sectionzoom", "sectionZm",
    `<psez:sectionZmObj sectionId="${section}"><psez:zmPr id="{2}" returnToParent="0"/></psez:sectionZmObj>`, 60);
  const name = "ppt/slides/slide1.xml";
  const slide = new TextDecoder().decode(entries.get(name)).replace("</p:spTree>", slideZoom + sectionZoom + "</p:spTree>");
  entries.set(name, new TextEncoder().encode(slide));

  const opened = call("open", { name: "Zooms.pptx" }, zip(entries)).state;
  const shapes = call("scene", { slide: opened.slides[0].id }).result.shapes;
  const zooms = shapes.filter((node) => node.link?.zoom);
  assert.equal(zooms.length, 2);
  assert.deepEqual(zooms[0].link.zoom, { slide: opened.slides[1].id, returns: true, dur: 1 });
  assert.deepEqual(zooms[0].link.frame, [zooms[0].x, zooms[0].y, zooms[0].w, zooms[0].h]);
  assert.deepEqual(zooms[1].link.zoom, { section, returns: false });
  assert.ok(zooms.every((node) => node.locked), "kept as they were");
  const target = call("scene", { slide: opened.slides[1].id }).result;
  assert.deepEqual(zooms[0].zoomScene?.shapes.map((node) => node.id), target.shapes.map((node) => node.id), "drawn from the slide it leads to");
  assert.ok(zooms[0].zoomScene.shapes.every((node) => !node.zoomScene), "a zoom's picture holds no further zooms");

  const flight = call("transition", { slide: opened.slides[1].id, zoom: { frame: zooms[0].link.frame, dur: 1 } }).result;
  assert.equal(flight.duration, 1);
  assert.equal(flight.layers.length, 2, "the zoom's slide and the slide it grows out of");
  const calm = call("transition", { slide: opened.slides[1].id, zoom: { frame: zooms[0].link.frame, dur: 1 }, reduceMotion: true }).result;
  assert.ok(calm.layers.length === 2 && calm.duration === 1);

  const saved = unzip(call("save", { format: "pptx", keep: true }).payload);
  assert.match(new TextDecoder().decode(saved.get(name)), /<pslz:sldZmObj sldId="257">/, "saved as it was");
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
