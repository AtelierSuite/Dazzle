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
    </p:sp>`;
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
      columned: named("Columned"), tabbed: named("Tabbed"), vertical: named("Vertical"),
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
