// The inspector: Format, Animate and Comments, as on the Mac. Format shows the
// selected shapes' text, fill, outline, effects, table, chart, picture,
// arrangement, link and description, or with nothing selected, the slide and
// the presentation. Every control changes the presentation through the engine.

import { fontStack } from "./slide.js";
import * as fonts from "./fonts.js";

const ICONS = {
  alignLeft: '<path d="M2 3.5h12M2 6.5h8M2 9.5h12M2 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignCenter: '<path d="M2 3.5h12M4 6.5h8M2 9.5h12M4 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignRight: '<path d="M2 3.5h12M6 6.5h8M2 9.5h12M6 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignJustify: '<path d="M2 3.5h12M2 6.5h12M2 9.5h12M2 12.5h12" stroke="currentColor" stroke-width="1.5"/>',
  anchorTop: '<path d="M2 2.5h12M5 5.5h6M5 8.5h6" stroke="currentColor" stroke-width="1.5"/>',
  anchorMiddle: '<path d="M5 5.5h6M2 8h12M5 10.5h6" stroke="currentColor" stroke-width="1.5"/>',
  anchorBottom: '<path d="M5 7.5h6M5 10.5h6M2 13.5h12" stroke="currentColor" stroke-width="1.5"/>',
  outdent: '<path d="M7 3.5h7M7 6.5h7M7 9.5h7M2 12.5h12M5 5L2.5 8 5 11" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  indent: '<path d="M7 3.5h7M7 6.5h7M7 9.5h7M2 12.5h12M2.5 5L5 8 2.5 11" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  chevronDown: '<path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  chevronUp: '<path d="M4 10l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
};
const icon = (name, extra = "") => `<svg class="ds-icon ${extra}" viewBox="0 0 16 16" aria-hidden="true">${ICONS[name]}</svg>`;

export function escapeHTML(text) {
  return String(text ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

/** The system colours the Apple apps offer, in their light-appearance values. */
const SYSTEM_COLORS = [
  ["Color.Red", "#ff3b30"], ["Color.Orange", "#ff9500"], ["Color.Yellow", "#ffcc00"], ["Color.Green", "#34c759"],
  ["Color.Mint", "#00c7be"], ["Color.Teal", "#30b0c7"], ["Color.Cyan", "#32ade6"], ["Color.Blue", "#007aff"],
  ["Color.Indigo", "#5856d6"], ["Color.Purple", "#af52de"], ["Color.Pink", "#ff2d55"], ["Color.Brown", "#a2845e"],
  ["Color.Black", "#000000"], ["Color.Grey", "#8e8e93"], ["Color.LightGrey", "#d1d1d6"], ["Color.White", "#ffffff"],
];

const LINE_SPACINGS = [0.9, 1, 1.15, 1.5, 2, 2.5, 3];

/** A table style's options, as the engine names them, in the order they are offered. */
const TABLE_OPTIONS = [
  ["headerRow", "Table.HeaderRow"], ["totalRow", "Table.TotalRow"], ["bandedRows", "Table.BandedRows"],
  ["firstColumn", "Table.FirstColumn"], ["lastColumn", "Table.LastColumn"], ["bandedColumns", "Table.BandedColumns"],
];

export class Inspector extends EventTarget {
  /**
   * @param {HTMLElement} element
   * @param {import("./engine-client.js").EngineClient} engine
   * @param {{ t: Function, language: string, run: (command: string) => any, ask: object }} options
   */
  constructor(element, engine, { t, language, run, ask }) {
    super();
    this.element = element;
    this.engine = engine;
    this.t = t;
    this.language = language;
    this.run = run;
    this.ask = ask;
    this.pane = readSetting("inspectorPane", "format");
    this.data = null;
    this.number = new Intl.NumberFormat(language, { maximumFractionDigits: 2 });
  }

  /** Asks the engine what's selected and shows it, unless a control inside is being used. */
  async refresh({ force = false } = {}) {
    if (this.element.hidden || !this.engine.state) return;
    const data = await this.engine.call("inspect").catch(() => null);
    this.data = data;
    if (!force && this.element.contains(document.activeElement) && document.activeElement.matches("input[type=text], input:not([type]), textarea, input[type=number]")) {
      this.stale = true;
      return;
    }
    this.render();
  }

  render() {
    const t = this.t;
    const panes = [["format", t("ActionBar.Format")], ["animate", t("ActionBar.Animations")], ["comments", t("ActionBar.Comments")]];
    const data = this.data;
    let body = "";
    if (!data?.slide) body = "";
    else if (this.pane === "animate") body = this.animatePane(data);
    else if (this.pane === "comments") body = this.commentsPane(data);
    else body = data.shape ? this.shapePane(data) : this.slidePane(data);
    this.element.innerHTML = `
      <div class="ds-inspector__switcher">
        <div class="ds-segmented ds-segmented--xs ds-segmented--fill" role="tablist">
          ${panes.map(([key, label]) => `<button class="ds-segmented__segment" role="tab" type="button" data-pane="${key}" aria-selected="${key === this.pane}">${escapeHTML(label)}</button>`).join("")}
        </div>
      </div>
      <div class="ds-inspector__body">${body}</div>`;
    this.bind();
    this.stale = false;
  }

  // MARK: - Building blocks

  section(title, body, { open = true } = {}) {
    return `
      <details class="ds-disclosure"${open ? " open" : ""}>
        <summary>${icon("chevronDown", "ds-disclosure__triangle app__triangle")}${escapeHTML(title)}</summary>
        <div class="ds-disclosure__body ds-form">${body}</div>
      </details>`;
  }

  row(label, control) {
    return `<span class="ds-form__label">${label ? escapeHTML(label) : ""}</span><span class="ds-form__control">${control}</span>`;
  }

  note(text) {
    return `<span class="ds-form__label"></span><span class="ds-form__control"><span class="ds-caption app__note">${escapeHTML(text)}</span></span>`;
  }

  popup(field, label, options, value) {
    return `<span class="ds-popup ds-popup--xs app__inspector-popup"><select class="ds-popup__select" data-field="${field}" aria-label="${escapeHTML(label)}">${
      options.map(([key, text]) => `<option value="${escapeHTML(key)}"${String(key) === String(value) ? " selected" : ""}>${escapeHTML(text)}</option>`).join("")
    }</select>${icon("chevronDown", "ds-popup__chevron")}</span>`;
  }

  stepper(field, label, value, { step = 1, min = 0, max = 10_000, unit = "" } = {}) {
    return `<span class="app__stepper-row"><span class="ds-stepper ds-stepper--xs"><input class="ds-stepper__input ds-numeric" type="number" step="${step}" min="${min}" max="${max}" data-field="${field}" value="${Math.round(value * 100) / 100}" aria-label="${escapeHTML(label)}">
      <span class="ds-stepper__arrows">
        <button class="ds-stepper__arrow" type="button" data-step="${step}" tabindex="-1" aria-label="${escapeHTML(label)} +">${icon("chevronUp")}</button>
        <button class="ds-stepper__arrow" type="button" data-step="${-step}" tabindex="-1" aria-label="${escapeHTML(label)} −">${icon("chevronDown")}</button>
      </span></span>${unit ? `<span class="ds-caption">${escapeHTML(unit)}</span>` : ""}</span>`;
  }

  check(field, label, checked) {
    return `<label class="ds-check"><input type="checkbox" data-field="${field}"${checked ? " checked" : ""}>${escapeHTML(label)}</label>`;
  }

  buttons(entries) {
    return `<span class="app__inspector-buttons">${entries.map(([action, label, pressed]) => `<button class="ds-button ds-button--bordered ds-button--xs" type="button" data-action="${action}"${pressed !== undefined ? ` aria-pressed="${Boolean(pressed)}"` : ""}>${escapeHTML(label)}</button>`).join("")}</span>`;
  }

  /** Toggles and choices side by side, each a glyph or icon with its name as the tooltip. */
  segments(entries) {
    return `<span class="ds-segmented ds-segmented--xs ds-segmented--icons" role="group">${entries.map(([action, label, pressed, glyph]) => {
      const content = ICONS[glyph] ? icon(glyph) : glyph;
      return `<button class="ds-segmented__segment" type="button" data-action="${action}" aria-label="${escapeHTML(label)}" title="${escapeHTML(label)}"${pressed !== undefined ? ` aria-pressed="${Boolean(pressed)}"` : ""}>${content}</button>`;
    }).join("")}</span>`;
  }

  text(field, label, value, { placeholder = "", multiline = false } = {}) {
    if (multiline) return `<textarea class="ds-text-input ds-text-input--xs app__inspector-text" data-field="${field}" rows="3" aria-label="${escapeHTML(label)}" placeholder="${escapeHTML(placeholder)}">${escapeHTML(value)}</textarea>`;
    return `<input class="ds-text-input ds-text-input--xs" data-field="${field}" value="${escapeHTML(value)}" aria-label="${escapeHTML(label)}" placeholder="${escapeHTML(placeholder)}">`;
  }

  /** A colour: a pop-up of the theme's and the system's colours, and a well for any other. */
  color(field, label, current, { none = null } = {}) {
    const t = this.t;
    const theme = this.data?.theme ?? [];
    const options = [];
    if (none) options.push(["none", none]);
    options.push(...theme.map((entry) => [`scheme:${entry.slot}`, entry.label]));
    options.push(...SYSTEM_COLORS.map(([key, hex]) => [hex, t(key)]));
    const value = current === null ? "none" : options.find(([key]) => key === current?.toLowerCase())?.[0]
      ?? theme.find((entry) => entry.color === current)?.slot?.replace(/^/, "scheme:") ?? "custom";
    if (value === "custom") options.push(["custom", t("Mac.Inspector.CustomColour")]);
    const hex = /^#[0-9a-f]{6}$/i.test(current ?? "") ? current : "#000000";
    return `<span class="app__color">${this.popup(`${field}`, label, options, value)}<input type="color" class="ds-color-well" data-field="${field}" data-well="1" value="${hex}" aria-label="${escapeHTML(t("Mac.Inspector.CustomColour"))}"></span>`;
  }

  // MARK: - Panes

  slidePane(data) {
    const t = this.t;
    const info = this.engine.info ?? {};
    const slide = data.slide;
    const background = slide.background;
    let html = this.section(t("Format.Section.Background"),
      this.row(t("Fill.Kind"), this.popup("bgKind", t("Fill.Kind"), [
        ["auto", t("Fill.Automatic")], ["solid", t("Fill.Solid")], ["gradient", t("Fill.Gradient")], ["picture", t("Fill.Picture")],
        ["pattern", t("Fill.Pattern")],
      ], background.own ? background.kind : "auto"))
      + (background.kind === "solid" || !background.own ? this.row(t("Mac.Inspector.Colour"), this.color("bgColor", t("Mac.Inspector.Colour"), background.color)) : "")
      + (background.own && background.kind === "gradient" ? this.gradientRows("bg", background) : "")
      + (background.own && background.kind === "pattern" ? this.patternRows("bg", background) : "")
      + (background.own && background.kind === "picture" ? this.row("", this.buttons([["bgPicture", t("Fill.Picture.Change")]])) + this.row("", this.check("bgTile", t("Fill.Picture.Tile"), background.tiled)) : "")
      + this.note(t("Format.Background.Footer")));
    // A master or layout has a name, and none of what a slide has besides.
    const template = this.engine.state?.masterView ? this.engine.state.slides.find((entry) => entry.id === slide.id) : null;
    if (template) {
      if (template.role === "layout") {
        html += this.section(t("MasterView.Section.Layout"), this.row(t("MasterView.LayoutName"), this.text("layoutName", t("MasterView.LayoutName"), template.name)));
      }
      return html;
    }
    const layouts = (info.layouts ?? []).map((layout) => [layout.path, layout.name]);
    html += this.section(t("Format.Section.Slide"),
      this.row(t("Format.Slide.Layout"), this.popup("layout", t("Format.Slide.Layout"), layouts, slide.layout))
      + this.row("", this.check("hidden", t("Format.Slide.Hidden"), slide.hidden))
      + this.row("", this.buttons([["headerFooter", t("Panel.HeaderFooter.Title")]])));
    const automatic = slide.advanceAfter != null;
    html += this.section(t("Format.Section.Advance"),
      this.row("", this.check("advanceAuto", t("Advance.Automatically"), automatic))
      + (automatic ? this.row(t("Advance.After"), this.stepper("advanceAfter", t("Advance.After"), slide.advanceAfter, { step: 0.5, min: 0.5, max: 3600, unit: t("Advance.Seconds") }))
        + this.row("", this.check("advanceOnClick", t("Advance.OnTap"), slide.onClick)) : "")
      + this.row("", this.buttons([["advanceToAll", t("Advance.ApplyToAll")]]))
      + this.note(t("Advance.Footer")));
    const sizes = (info.choices?.sizes ?? []).map((size) => [size.id, size.label]);
    if (!info.sizePreset) sizes.push(["custom", t("SlideSize.Custom")]);
    html += this.section(t("Format.Section.Presentation"),
      this.row(t("Format.SlideSize"), this.popup("slideSize", t("Format.SlideSize"), sizes, info.sizePreset ?? "custom"))
      + this.row("", this.check("loop", t("Format.LoopSlideshow"), info.loop)));
    return html;
  }

  gradientRows(prefix, fill) {
    const t = this.t;
    return this.row(t("Fill.Gradient.Start"), this.color(`${prefix}Start`, t("Fill.Gradient.Start"), fill.start ?? "#ffffff"))
      + this.row(t("Fill.Gradient.End"), this.color(`${prefix}End`, t("Fill.Gradient.End"), fill.end ?? "#000000"))
      + this.row(t("Fill.Gradient.Style"), this.popup(`${prefix}Path`, t("Fill.Gradient.Style"), [
        ["linear", t("Fill.Gradient.Linear")], ["circle", t("Fill.Gradient.Radial")],
        ["rect", t("Fill.Gradient.Rectangular")], ["shape", t("Fill.Gradient.Path")],
      ], fill.path ?? "linear"))
      + ((fill.path ?? "linear") === "linear"
        ? this.row(t("Fill.Gradient.Direction"), this.stepper(`${prefix}Angle`, t("Fill.Gradient.Direction"), fill.angle ?? 90, { step: 15, min: 0, max: 359, unit: "°" }))
        : "");
  }

  /** A pattern fill's cells and two colours. */
  patternRows(prefix, fill) {
    const t = this.t;
    const patterns = (this.engine.info?.choices?.patterns ?? []).map((pattern) => [pattern.id, pattern.label]);
    if (fill.preset && !patterns.some(([id]) => id === fill.preset)) patterns.push([fill.preset, fill.preset]);
    return this.row(t("Fill.Pattern"), this.popup(`${prefix}Pattern`, t("Fill.Pattern"), patterns, fill.preset))
      + this.row(t("Fill.Pattern.Foreground"), this.color(`${prefix}PatternFg`, t("Fill.Pattern.Foreground"), fill.color ?? "#000000"))
      + this.row(t("Fill.Pattern.Background"), this.color(`${prefix}PatternBg`, t("Fill.Pattern.Background"), fill.background ?? "#ffffff"));
  }

  shapePane(data) {
    const t = this.t;
    const shape = data.shape;
    const text = data.text ?? {};
    let html = "";
    if (!shape.editable) {
      return this.section(shape.name, this.note(t("Format.Locked"))) + this.arrangeSection(shape);
    }
    if (shape.hasText && shape.count === 1 || shape.kind === "table") html += this.textSection(text);
    if (shape.kind === "shape") {
      const fill = shape.fill;
      html += this.section(t("Format.Section.Fill"),
        this.row(t("Fill.Kind"), this.popup("fillKind", t("Fill.Kind"), [
          ["none", t("Fill.None")], ["solid", t("Fill.Solid")], ["gradient", t("Fill.Gradient")], ["picture", t("Fill.Picture")],
          ["pattern", t("Fill.Pattern")],
        ], fill.kind))
        + (fill.kind === "solid" ? this.row(t("Mac.Inspector.Colour"), this.color("fillColor", t("Mac.Inspector.Colour"), fill.color)) : "")
        + (fill.kind === "gradient" ? this.gradientRows("fill", fill) : "")
        + (fill.kind === "pattern" ? this.patternRows("fill", fill) : "")
        + (fill.kind === "picture" ? this.row("", this.buttons([["fillPicture", t("Fill.Picture.Change")]])) + this.row("", this.check("fillTile", t("Fill.Picture.Tile"), fill.tiled)) : ""));
    }
    if (shape.line) html += this.outlineSection(shape.line) + this.effectsSection(shape);
    if (shape.table) html += this.tableSection(shape.table);
    if (shape.chart) html += this.chartSection(shape.chart);
    if (shape.kind === "picture" || shape.kind === "media") {
      html += this.section(t("Format.Section.Picture"), this.row("", this.buttons([
        ["replacePicture", t("Picture.Replace")], ["crop", t("Picture.Crop")], ["resetCrop", t("Picture.ResetCrop")],
      ])));
    }
    html += this.arrangeSection(shape);
    if (shape.count === 1) html += this.linkSection(shape);
    if (shape.count === 1) {
      html += this.section(t("Format.Section.AltText"),
        `<span class="ds-form__wide">${this.text("altText", t("Format.Section.AltText"), shape.altText, { placeholder: t("Format.AltText.Placeholder"), multiline: true })}</span>`
        + this.note(t("Format.AltText.Footer")), { open: Boolean(shape.altText) });
    }
    return html;
  }

  textSection(text) {
    const t = this.t;
    const info = this.engine.info ?? {};
    const families = [...new Set([...(info.fonts ?? []), ...fonts.installedFamilies()])].sort((a, b) => a.localeCompare(b, this.language));
    if (text.font && !families.includes(text.font)) families.unshift(text.font);
    const fontPopup = `<span class="ds-popup ds-popup--xs app__inspector-popup"><select class="ds-popup__select" data-field="font" aria-label="${escapeHTML(t("Format.Font"))}">${
      families.map((family) => `<option value="${escapeHTML(family)}"${family === text.font ? " selected" : ""} style="font-family:${escapeHTML(fontStack(family))}">${escapeHTML(family)}</option>`).join("")
    }</select>${icon("chevronDown", "ds-popup__chevron")}</span>`;
    const lineSpacing = LINE_SPACINGS.map((value) => [value, this.number.format(value)]);
    const current = LINE_SPACINGS.find((value) => Math.abs(value - (text.lineSpacing ?? 1)) < 0.01) ?? (text.lineSpacing ?? 1);
    if (!LINE_SPACINGS.includes(current)) lineSpacing.push([current, this.number.format(current)]);
    return this.section(t("Format.Section.Text"),
      this.row(t("Format.Font"), fontPopup)
      + this.row(t("Format.Text.Size"), this.stepper("size", t("Format.Text.Size"), text.size ?? 18, { step: 1, min: 1, max: 4000, unit: "pt" }))
      + this.row("", this.segments([
        ["bold", t("Format.Bold"), text.bold, "<strong>B</strong>"], ["italic", t("Format.Italic"), text.italic, "<em>I</em>"],
        ["underline", t("Format.Underline"), text.underline, "<u>U</u>"], ["strike", t("Format.Strikethrough"), text.strike, "<s>S</s>"],
      ]))
      + this.row(t("Format.Section.TextColor"), this.color("textColor", t("Format.Section.TextColor"), text.scheme ? `scheme:${text.scheme}` : text.color))
      + this.row(t("Format.Alignment"), this.segments([
        ["alignLeft", t("Menu.Format.AlignLeft"), text.align === "l", "alignLeft"], ["alignCenter", t("Menu.Format.Centre"), text.align === "ctr", "alignCenter"],
        ["alignRight", t("Menu.Format.AlignRight"), text.align === "r", "alignRight"], ["alignJustify", t("Menu.Format.Justify"), text.align === "just", "alignJustify"],
      ]))
      + this.row("", this.segments([
        ["anchorTop", t("Align.Top"), text.anchor === "t", "anchorTop"], ["anchorMiddle", t("Align.Middle"), text.anchor === "ctr", "anchorMiddle"],
        ["anchorBottom", t("Align.Bottom"), text.anchor === "b", "anchorBottom"],
      ]))
      + this.row(t("Format.List"), this.popup("list", t("Format.List"), [["none", t("Format.List.None")], ["bullets", t("Format.List.Bullets")], ["numbers", t("Format.List.Numbers")]], text.list ?? "none"))
      + this.row(t("Format.Indent.Level"), this.segments([["outdent", t("Format.Outdent"), undefined, "outdent"], ["indent", t("Format.Indent"), undefined, "indent"]]))
      + this.row(t("Format.LineSpacing"), this.popup("lineSpacing", t("Format.LineSpacing"), lineSpacing, current)));
  }

  outlineSection(line) {
    const t = this.t;
    const choices = this.engine.info?.choices ?? {};
    return this.section(t("Format.Section.Outline"),
      this.row(t("Mac.Inspector.Colour"), this.color("lineColor", t("Mac.Inspector.Colour"), line.kind === "none" ? null : line.color, { none: t("Fill.None") }))
      + (line.kind === "none" ? "" : this.row(t("Format.Outline.Width"), this.stepper("lineWidth", t("Format.Outline.Width"), line.width, { step: 0.25, min: 0.25, max: 100, unit: "pt" }))
        + this.row(t("Format.Outline.Dash"), this.popup("lineDash", t("Format.Outline.Dash"), (choices.dashes ?? []).map((dash) => [dash.id, dash.label]), line.dash))
        + this.row(t("Format.Outline.Start"), this.popup("lineHead", t("Format.Outline.Start"), (choices.lineEnds ?? []).map((end) => [end.id, end.label]), line.head))
        + this.row(t("Format.Outline.End"), this.popup("lineTail", t("Format.Outline.End"), (choices.lineEnds ?? []).map((end) => [end.id, end.label]), line.tail))));
  }

  effectsSection(shape) {
    const t = this.t;
    const choices = this.engine.info?.choices ?? {};
    const shadows = (choices.shadows ?? []).map((shadow) => [shadow.id, shadow.label]);
    if (shape.shadow === "custom") shadows.push(["custom", t("Shadow.Custom")]);
    const reflections = (choices.reflections ?? []).map((reflection) => [reflection.id, reflection.label]);
    if (shape.reflection === "custom") reflections.push(["custom", t("Reflection.Custom")]);
    const sizes = (list, current) => {
      const options = [["0", t("Effect.None")], ...(list ?? []).map((points) => [String(points), `${points} pt`])];
      if (current && !options.some(([id]) => Number(id) === current)) options.push([String(current), `${Math.round(current * 10) / 10} pt`]);
      return options;
    };
    const named = (list, current, none) => {
      const options = [...(none ? [none] : []), ...(list ?? []).map((choice) => [choice.id, choice.label])];
      if (current && !options.some(([id]) => id === current)) options.push([current, t("Shadow.Custom")]);
      return options;
    };
    let body = this.row(t("Format.Shadow"), this.popup("shadow", t("Format.Shadow"), shadows, shape.shadow))
      + this.row(t("Format.Reflection"), this.popup("reflection", t("Format.Reflection"), reflections, shape.reflection))
      + this.row(t("Format.Glow"), this.popup("glow", t("Format.Glow"), sizes(choices.glowSizes, shape.glow), String(shape.glow ?? 0)))
      + (shape.glow ? this.row(t("Format.Glow.Color"), this.color("glowColor", t("Format.Glow.Color"), shape.glowColor)) : "")
      + this.row(t("Format.SoftEdges"), this.popup("softEdge", t("Format.SoftEdges"), sizes(choices.softEdgeSizes, shape.softEdge), String(shape.softEdge ?? 0)))
      + this.row(t("Format.InnerShadow"), this.popup("innerShadow", t("Format.InnerShadow"), named(choices.innerShadows, shape.innerShadow), shape.innerShadow));
    if (shape.bevel !== undefined) {
      body += this.row(t("Format.Bevel"), this.popup("bevel", t("Format.Bevel"), named(choices.bevels, shape.bevel, ["none", t("Effect.None")]), shape.bevel))
        + this.row(t("Format.Depth"), this.stepper("depth", t("Format.Depth"), shape.depth, { step: 6, min: 0, max: 200, unit: "pt" }))
        + this.row(t("Format.Camera"), this.popup("camera", t("Format.Camera"), named(choices.cameras, shape.camera), shape.camera));
    }
    if (shape.warp !== undefined) {
      body += this.row(t("Format.TextWarp"), this.popup("warp", t("Format.TextWarp"), named(choices.textWarps, shape.warp, ["textNoShape", t("Effect.None")]), shape.warp));
    }
    const isPlain = shape.shadow === "none" && shape.reflection === "none" && !shape.glow && !shape.softEdge && shape.innerShadow === "none"
      && (shape.bevel ?? "none") === "none" && !shape.depth && (shape.warp ?? "textNoShape") === "textNoShape";
    return this.section(t("Mac.Inspector.Effects"), body, { open: !isPlain });
  }

  tableSection(table) {
    const t = this.t;
    let body = TABLE_OPTIONS.map(([option, key]) => this.row("", this.check(`tableOption:${option}`, t(key), table.options[option]))).join("");
    if (table.cell) {
      body += this.row(t("Mac.Inspector.Table.RowsAndColumns"), this.buttons([
        ["rowAbove", t("Table.RowAbove")], ["rowBelow", t("Table.RowBelow")], ["columnLeft", t("Table.ColumnLeft")], ["columnRight", t("Table.ColumnRight")],
      ]))
        + this.row("", this.buttons([["deleteRow", t("Table.DeleteRow")], ["deleteColumn", t("Table.DeleteColumn")]]))
        + this.row(t("Format.Section.CellFill"), this.color("cellFill", t("Format.Section.CellFill"), table.cell.fill.kind === "solid" ? table.cell.fill.color : null, { none: t("Fill.None") }));
    } else {
      body += this.note(t("Mac.Inspector.Table.PickCell"));
    }
    return this.section(t("Format.Section.Table"), body);
  }

  chartSection(chart) {
    const t = this.t;
    const choices = this.engine.info?.choices ?? {};
    const groupings = (choices.groupings ?? []).map((grouping) => [grouping.id, grouping.label]);
    return this.section(t("Panel.Chart.Title"),
      this.row(t("Chart.Type"), this.popup("chartKind", t("Chart.Type"), (chart.kinds ?? choices.charts ?? []).map((kind) => [kind.kind, kind.label]), chart.kind))
      + (chart.hasGrouping ? this.row(t("Chart.Grouping"), this.popup("chartGrouping", t("Chart.Grouping"), groupings, chart.grouping)) : "")
      + this.row("", this.buttons([["chartData", t("ActionBar.ChartData")]]))
      + this.row("", this.check("chartShowTitle", t("Chart.ShowTitle"), Boolean(chart.title)))
      + (chart.title ? this.row(t("Chart.Title"), this.text("chartTitle", t("Chart.Title"), chart.title)) : "")
      + this.row(t("Chart.Legend"), this.popup("chartLegend", t("Chart.Legend"), [
        ["none", t("Chart.Legend.None")], ["t", t("Chart.Legend.Top")], ["b", t("Chart.Legend.Bottom")], ["l", t("Chart.Legend.Left")], ["r", t("Chart.Legend.Right")],
      ], chart.legend))
      + (chart.hasAxes ? this.row("", this.check("chartGridlines", t("Chart.Gridlines"), chart.gridlines)) : "")
      + this.row("", this.check("chartLabels", t("Chart.ValueLabels"), chart.labels)));
  }

  arrangeSection(shape) {
    const t = this.t;
    let body = "";
    if (shape.count === 1) {
      body += this.row(t("Mac.Inspector.Position"), `<span class="app__pair">${this.stepper("x", "X", shape.x, { min: -100000 })}${this.stepper("y", "Y", shape.y, { min: -100000 })}</span>`)
        + this.row(t("Mac.Inspector.Size"), `<span class="app__pair">${this.stepper("w", t("Mac.Inspector.Width"), shape.w)}${this.stepper("h", t("Mac.Inspector.Height"), shape.h)}</span>`);
      if (shape.canRotate) {
        body += this.row(t("Format.Rotation"), this.stepper("rotation", t("Format.Rotation"), shape.rot, { step: 1, min: 0, max: 359, unit: "°" }))
          + this.row("", this.buttons([["rotateLeft", t("Arrange.RotateLeft")], ["rotateRight", t("Arrange.RotateRight")], ["flipH", t("Arrange.FlipHorizontal")], ["flipV", t("Arrange.FlipVertical")]]));
      }
    }
    body += this.row(t("ActionBar.Align"), this.buttons([
      ["alignShapesLeft", t("Align.Left")], ["alignShapesCenter", t("Align.Center")], ["alignShapesRight", t("Align.Right")],
      ["alignShapesTop", t("Align.Top")], ["alignShapesMiddle", t("Align.Middle")], ["alignShapesBottom", t("Align.Bottom")],
    ]));
    if (shape.count > 2) body += this.row(t("Menu.Arrange.Distribute"), this.buttons([["distributeH", t("Align.DistributeHorizontally")], ["distributeV", t("Align.DistributeVertically")]]));
    body += this.row(t("ActionBar.Arrange"), this.buttons([
      ["front", t("Arrange.Front")], ["forward", t("Arrange.Forward")], ["backward", t("Arrange.Backward")], ["back", t("Arrange.Back")],
    ]));
    if (shape.canGroup || shape.kind === "group") {
      body += this.row("", this.buttons([...(shape.canGroup ? [["group", t("Arrange.Group")]] : []), ...(shape.kind === "group" ? [["ungroup", t("Arrange.Ungroup")]] : [])]));
    }
    return this.section(t("Format.Section.Arrange"), body);
  }

  linkSection(shape) {
    const t = this.t;
    const link = shape.link;
    const kind = !link ? "none" : link.url ? "url" : link.slide ? "slide" : link.action;
    const slides = (this.engine.info?.outline ?? []).map((slide) => [slide.id, `${slide.number}. ${slide.title || t("Slide.Untitled")}`]);
    return this.section(t("Format.Section.Link"),
      this.row(t("Link.Kind"), this.popup("linkKind", t("Link.Kind"), [
        ["none", t("Link.None")], ["url", t("Link.URL")], ["slide", t("Link.Slide")], ["next", t("Link.Next")],
        ["previous", t("Link.Previous")], ["first", t("Link.First")], ["last", t("Link.Last")], ["end", t("Link.End")],
      ], kind))
      + (kind === "url" ? this.row("", this.text("linkURL", t("Link.URL"), link.url, { placeholder: t("Link.URL.Placeholder") })) : "")
      + (kind === "slide" ? this.row("", this.popup("linkSlide", t("Link.Slide"), slides, link.slide)) : "")
      + this.note(t("Format.Link.Footer")), { open: Boolean(link) });
  }

  animatePane(data) {
    const t = this.t;
    const choices = this.engine.info?.choices ?? {};
    const animations = data.animations ?? [];
    const canEdit = data.slide.canEdit;
    let html = "";
    const add = [["", t("Animation.Add")]];
    for (const group of choices.animations ?? []) {
      for (const effect of group.effects) add.push([`${group.category}:${effect.name}`, `${group.label} — ${effect.label}`]);
    }
    html += this.section(t("Panel.Animations.Title"),
      (data.shape && canEdit ? this.row("", this.popup("addAnimation", t("Animation.Add"), add, "")) : this.note(t("Animation.SelectHint")))
      + this.row("", this.buttons([["previewAnimations", t("Animation.Preview")]])));
    if (!animations.length) return html;
    const selected = animations.find((animation) => animation.id === this.selectedAnimation)
      ?? animations.find((animation) => animation.shape === data.shape?.id) ?? null;
    this.selectedAnimation = selected?.id ?? null;
    const list = `<ol class="app__animations">${animations.map((animation, index) => `
      <li class="app__animation${animation.id === selected?.id ? " is-selected" : ""}" data-animation="${animation.id}" tabindex="0">
        <span class="ds-numeric app__animation-step">${animation.tap ?? ""}</span>
        <span class="app__animation-label"><span>${escapeHTML(animation.effectLabel)}</span><span class="ds-caption">${escapeHTML(animation.target)}</span></span>
      </li>`).join("")}</ol>`;
    html += this.section(t("Animation.Section.Order"), `<span class="ds-form__wide">${list}</span>` + this.note(t("Mac.Animation.Footer")));
    if (selected) {
      const group = (choices.animations ?? []).find((entry) => entry.category === selected.category);
      const effects = (group?.effects ?? []).map((effect) => [effect.name, effect.label]);
      const directional = group?.effects.find((effect) => effect.name === selected.effect)?.directional;
      let body = selected.editable && effects.length
        ? this.row(t("Animation.Effect"), this.popup("animationEffect", t("Animation.Effect"), effects, selected.effect))
        : this.row(t("Animation.Effect"), `<span class="ds-caption">${escapeHTML(selected.effectLabel)}</span>`) + (selected.editable ? "" : this.note(t("Animation.Custom.Footer")));
      if (directional) {
        body += this.row(t("Animation.Direction"), this.popup("animationDirection", t("Animation.Direction"), (choices.directions ?? []).map((direction) => [direction.id, direction.label]), selected.direction));
      }
      body += this.row(t("Animation.Start"), this.popup("animationTrigger", t("Animation.Start"), (choices.triggers ?? []).map((trigger) => [trigger.id, trigger.label]), selected.trigger));
      if (selected.effect !== "appear") body += this.row(t("Animation.Duration"), this.stepper("animationDuration", t("Animation.Duration"), selected.duration, { step: 0.25, min: 0.1, max: 60, unit: t("Advance.Seconds") }));
      body += this.row(t("Animation.Delay"), this.stepper("animationDelay", t("Animation.Delay"), selected.delay, { step: 0.25, min: 0, max: 60, unit: t("Advance.Seconds") }));
      body += this.row("", this.buttons([["animationEarlier", t("Animation.MoveEarlier")], ["animationLater", t("Animation.MoveLater")], ["animationDelete", t("Animation.Delete")]]));
      html += this.section(selected.target, body);
    }
    return html;
  }

  commentsPane(data) {
    const t = this.t;
    const author = readSetting("author", "");
    let html = this.section(t("Comments.New"),
      this.row(t("Comments.CommentAs"), this.text("author", t("Comments.CommentAs"), author, { placeholder: t("Comments.YourName") }))
      + this.note(t("Comments.YourName.Footer"))
      + `<span class="ds-form__wide">${this.text("commentDraft", t("Comments.Placeholder"), "", { placeholder: t("Comments.Placeholder"), multiline: true })}</span>`
      + this.row("", this.buttons([["addComment", t("Comments.Add")]])));
    const comments = data.comments ?? [];
    if (!comments.length) return html + this.section(t("Panel.Comments.Title"), this.note(t("Comments.Empty")));
    const when = (time) => (time ? new Intl.DateTimeFormat(this.language, { dateStyle: "medium", timeStyle: "short" }).format(time) : "");
    for (const thread of comments) {
      const entries = [thread, ...thread.replies].map((comment, index) => `
        <li class="app__comment${thread.resolved ? " is-done" : ""}">
          <span class="app__comment-head"><span class="ds-heading-compact">${escapeHTML(comment.author || t("Comments.Unknown"))}</span><span class="ds-caption">${escapeHTML(when(comment.date))}</span>
          ${index > 0 ? `<button class="ds-button ds-button--ghost ds-button--xs" type="button" data-action="deleteReply" data-thread="${escapeHTML(thread.id)}" data-reply="${escapeHTML(comment.id)}">${escapeHTML(t("Comments.Delete"))}</button>` : ""}</span>
          <span class="ds-document-content app__comment-text">${escapeHTML(comment.text)}</span>
        </li>`).join("");
      html += this.section(thread.author || t("Comments.Unknown"),
        `<span class="ds-form__wide"><ul class="app__comments">${entries}</ul></span>`
        + `<span class="ds-form__wide">${this.text(`reply:${thread.id}`, t("Comments.Reply"), "", { placeholder: t("Comments.Reply"), multiline: true })}</span>`
        + this.row("", `<span class="app__inspector-buttons">
          <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-action="reply" data-thread="${escapeHTML(thread.id)}">${escapeHTML(t("Comments.Send"))}</button>
          <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-action="resolve" data-thread="${escapeHTML(thread.id)}" data-resolved="${!thread.resolved}">${escapeHTML(thread.resolved ? t("Comments.Reopen") : t("Comments.Resolve"))}</button>
          <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-action="deleteThread" data-thread="${escapeHTML(thread.id)}">${escapeHTML(t("Comments.DeleteThread"))}</button></span>`));
    }
    return html;
  }

  // MARK: - Changes

  bind() {
    for (const tab of this.element.querySelectorAll("[data-pane]")) {
      tab.addEventListener("click", () => {
        this.pane = tab.dataset.pane;
        writeSetting("inspectorPane", this.pane);
        this.render();
      });
    }
    for (const button of this.element.querySelectorAll("[data-action]")) {
      button.addEventListener("mousedown", (event) => event.preventDefault());
      button.addEventListener("click", () => this.act(button.dataset.action, button));
    }
    for (const arrow of this.element.querySelectorAll(".ds-stepper__arrow")) {
      arrow.addEventListener("mousedown", (event) => event.preventDefault());
      arrow.addEventListener("click", () => {
        const input = arrow.closest(".ds-stepper").querySelector("input");
        const next = Number(input.value || 0) + Number(arrow.dataset.step);
        input.value = String(Math.min(Math.max(next, Number(input.min)), Number(input.max)));
        input.dispatchEvent(new Event("change"));
      });
    }
    for (const field of this.element.querySelectorAll("[data-field]")) {
      field.addEventListener("change", () => this.changed(field));
      if (field.type === "number" || field.tagName === "INPUT" && field.type !== "color" && field.type !== "checkbox") {
        field.addEventListener("keydown", (event) => event.key === "Enter" && field.dispatchEvent(new Event("change")));
      }
    }
    for (const row of this.element.querySelectorAll("[data-animation]")) {
      const select = () => {
        this.selectedAnimation = row.dataset.animation;
        this.render();
      };
      row.addEventListener("click", select);
      row.addEventListener("keydown", (event) => event.key === "Enter" && select());
    }
  }

  async act(action, button) {
    const engine = this.engine;
    const data = this.data;
    const format = (set) => this.dispatchEvent(new CustomEvent("format", { detail: set }));
    switch (action) {
      case "bold": case "italic": case "underline": case "strike":
        return format({ [action]: true });
      case "alignLeft": return format({ align: "l" });
      case "alignCenter": return format({ align: "ctr" });
      case "alignRight": return format({ align: "r" });
      case "alignJustify": return format({ align: "just" });
      case "anchorTop": return format({ anchor: "t" });
      case "anchorMiddle": return format({ anchor: "ctr" });
      case "anchorBottom": return format({ anchor: "b" });
      case "indent": return format({ indent: 1 });
      case "outdent": return format({ indent: -1 });
      case "rotateLeft": return engine.call("rotate", { clockwise: false });
      case "rotateRight": return engine.call("rotate", { clockwise: true });
      case "flipH": return engine.call("flip", { horizontally: true });
      case "flipV": return engine.call("flip", { horizontally: false });
      case "front": case "forward": case "backward": case "back":
        return engine.call("arrange", { how: action });
      case "alignShapesLeft": case "alignShapesCenter": case "alignShapesRight": case "alignShapesTop": case "alignShapesMiddle": case "alignShapesBottom":
        return engine.call("align", { how: action.slice(11).toLowerCase() });
      case "distributeH": return engine.call("distribute", { horizontally: true });
      case "distributeV": return engine.call("distribute", { horizontally: false });
      case "group": return engine.call("group");
      case "ungroup": return engine.call("ungroup");
      case "rowAbove": case "rowBelow": case "columnLeft": case "columnRight": case "deleteRow": case "deleteColumn":
        return engine.call("table", { op: action });
      case "headerFooter": case "chartData": case "crop": case "resetCrop": case "replacePicture": case "previewAnimations":
        return this.run(action);
      case "fillPicture":
        return this.run("fillPicture");
      case "bgPicture":
        return this.run("backgroundPicture");
      case "advanceToAll": {
        const slide = data.slide;
        return engine.call("advance", { after: slide.advanceAfter ?? null, onClick: slide.onClick, toAll: true });
      }
      case "animationEarlier": return engine.call("moveAnimation", { id: this.selectedAnimation, step: -1 });
      case "animationLater": return engine.call("moveAnimation", { id: this.selectedAnimation, step: 1 });
      case "animationDelete": return engine.call("deleteAnimations", { ids: [this.selectedAnimation] });
      case "addComment": {
        const draft = this.element.querySelector('[data-field="commentDraft"]');
        const text = draft?.value.trim();
        if (!text) return null;
        draft.value = "";
        return engine.call("addComment", { text, author: readSetting("author", "") });
      }
      case "reply": {
        const field = this.element.querySelector(`[data-field="reply:${CSS.escape(button.dataset.thread)}"]`);
        const text = field?.value.trim();
        if (!text) return null;
        return engine.call("replyComment", { thread: button.dataset.thread, text, author: readSetting("author", "") });
      }
      case "resolve": return engine.call("resolveComment", { thread: button.dataset.thread, resolved: button.dataset.resolved === "true" });
      case "deleteThread": return engine.call("deleteComment", { thread: button.dataset.thread });
      case "deleteReply": return engine.call("deleteComment", { thread: button.dataset.thread, reply: button.dataset.reply });
      default: return null;
    }
  }

  async changed(field) {
    const engine = this.engine;
    const name = field.dataset.field;
    const value = field.type === "checkbox" ? field.checked : field.value;
    const data = this.data;
    const shape = data?.shape;
    const format = (set) => this.dispatchEvent(new CustomEvent("format", { detail: set }));
    /** A colour from a pop-up or well: a theme slot, a hex value, or none. */
    const colorValue = () => {
      if (field.dataset.well) return value;
      if (value === "custom") {
        field.closest(".app__color")?.querySelector("[data-well]")?.showPicker?.();
        return null;
      }
      return value;
    };
    if (name.startsWith("tableOption:")) return engine.call("table", { [name.slice("tableOption:".length)]: value });
    switch (name) {
      // Text
      case "font": return format({ font: value });
      case "size": return Number(value) > 0 && format({ size: Number(value) });
      case "textColor": { const color = colorValue(); return color && format({ color }); }
      case "list": return format({ list: value });
      case "lineSpacing": return format({ lineSpacing: Number(value) });
      // Fill
      case "fillKind":
        if (value === "pattern") return engine.call("setFill", { fill: { kind: "pattern", preset: "pct50", color: shape?.fill?.color ?? "scheme:accent1", background: "scheme:bg1" } });
        if (value === "picture") return this.run("fillPicture");
        if (value === "none") return engine.call("setFill", { fill: { kind: "none" } });
        if (value === "solid") return engine.call("setFill", { fill: { kind: "solid", color: shape?.fill?.color ?? "scheme:accent1" } });
        return engine.call("setFill", { fill: { kind: "gradient", start: shape?.fill?.color ?? "scheme:accent1", end: "scheme:bg1", angle: 90 } });
      case "fillColor": { const color = colorValue(); return color && engine.call("setFill", { fill: { kind: "solid", color } }); }
      case "fillStart": case "fillEnd": case "fillAngle": case "fillPath": {
        const fill = { ...shape.fill };
        const color = name === "fillStart" || name === "fillEnd" ? colorValue() : null;
        if (name === "fillStart") fill.start = color ?? fill.start;
        if (name === "fillEnd") fill.end = color ?? fill.end;
        if (name === "fillAngle") fill.angle = Number(value);
        if (name === "fillPath") fill.path = value;
        // Where it starts, the box it spans and whether it is scaled carry over as they were.
        return engine.call("setFill", { fill: { kind: "gradient", start: fill.start, end: fill.end, angle: fill.angle, path: fill.path, focus: fill.focus, tile: fill.tile, scaled: fill.scaled } });
      }
      case "fillPattern":
        return engine.call("setFill", { fill: { kind: "pattern", preset: value, color: shape.fill.color, background: shape.fill.background } });
      case "bgPattern":
        return engine.call("setBackground", { fill: { kind: "pattern", preset: value, color: data.slide.background.color, background: data.slide.background.background } });
      case "fillPatternFg": case "fillPatternBg": {
        const color = colorValue();
        if (!color) return;
        const fill = { ...shape.fill, [name === "fillPatternFg" ? "color" : "background"]: color };
        return engine.call("setFill", { fill: { kind: "pattern", preset: fill.preset, color: fill.color, background: fill.background } });
      }
      case "fillTile": return engine.call("setTiled", { tiled: value });
      // Background
      case "bgKind":
        if (value === "pattern") return engine.call("setBackground", { fill: { kind: "pattern", preset: "pct50", color: "scheme:accent1", background: data.slide.background.color ?? "scheme:bg1" } });
        if (value === "auto") return engine.call("setBackground", {});
        if (value === "picture") return this.run("backgroundPicture");
        if (value === "solid") return engine.call("setBackground", { fill: { kind: "solid", color: data.slide.background.color ?? "#ffffff" } });
        return engine.call("setBackground", { fill: { kind: "gradient", start: data.slide.background.color ?? "#ffffff", end: "scheme:accent1", angle: 90 } });
      case "bgColor": { const color = colorValue(); return color && engine.call("setBackground", { fill: { kind: "solid", color } }); }
      case "bgStart": case "bgEnd": case "bgAngle": case "bgPath": {
        const fill = { ...data.slide.background };
        const color = name === "bgStart" || name === "bgEnd" ? colorValue() : null;
        if (name === "bgStart") fill.start = color ?? fill.start;
        if (name === "bgEnd") fill.end = color ?? fill.end;
        if (name === "bgAngle") fill.angle = Number(value);
        if (name === "bgPath") fill.path = value;
        return engine.call("setBackground", { fill: { kind: "gradient", start: fill.start, end: fill.end, angle: fill.angle, path: fill.path, focus: fill.focus, tile: fill.tile, scaled: fill.scaled } });
      }
      case "bgPatternFg": case "bgPatternBg": {
        const color = colorValue();
        if (!color) return;
        const fill = { ...data.slide.background, [name === "bgPatternFg" ? "color" : "background"]: color };
        return engine.call("setBackground", { fill: { kind: "pattern", preset: fill.preset, color: fill.color, background: fill.background } });
      }
      case "bgTile": return engine.call("setTiled", { tiled: value, background: true });
      // Outline and effects
      case "lineColor": {
        const color = colorValue();
        if (value === "none") return engine.call("setLine", { set: { color: null } });
        return color && engine.call("setLine", { set: { color } });
      }
      case "lineWidth": return engine.call("setLine", { set: { width: Number(value) } });
      case "lineDash": return engine.call("setLine", { set: { dash: value } });
      case "lineHead": return engine.call("setLine", { set: { head: value } });
      case "lineTail": return engine.call("setLine", { set: { tail: value } });
      case "shadow": return value !== "custom" && engine.call("setShadow", { id: value });
      case "reflection": return value !== "custom" && engine.call("setReflection", { id: value });
      case "glow": return engine.call("setEffect", { glow: Number(value) });
      case "glowColor": { const color = colorValue(); return color && engine.call("setEffect", { glowColor: color }); }
      case "softEdge": return engine.call("setEffect", { softEdge: Number(value) });
      case "innerShadow": return value !== "custom" && engine.call("setEffect", { innerShadow: value });
      case "bevel": return engine.call("setEffect", { bevel: value });
      case "depth": return engine.call("setEffect", { depth: Math.max(0, Number(value)) });
      case "camera": return engine.call("setEffect", { camera: value });
      case "warp": return engine.call("setEffect", { warp: value });
      // Table
      case "cellFill": {
        if (value === "none") return engine.call("setCellFill", { fill: { kind: "none" } });
        const color = colorValue();
        return color && engine.call("setCellFill", { fill: { kind: "solid", color } });
      }
      // Chart
      case "chartKind": return engine.call("chart", { set: { kind: value } });
      case "chartGrouping": return engine.call("chart", { set: { grouping: value } });
      case "chartShowTitle": return engine.call("chart", { set: { title: value ? (shape.chart.series.length === 1 ? shape.chart.series[0].name : this.t("Chart.DefaultTitle")) : "" } });
      case "chartTitle": return engine.call("chart", { set: { title: value } });
      case "chartLegend": return engine.call("chart", { set: { legend: value } });
      case "chartGridlines": return engine.call("chart", { set: { gridlines: value } });
      case "chartLabels": return engine.call("chart", { set: { labels: value } });
      // Arrangement
      case "x": case "y": case "w": case "h": {
        const frame = { x: shape.x, y: shape.y, w: shape.w, h: shape.h, [name]: Number(value) };
        if (frame.w <= 0 || frame.h <= 0) return null;
        return engine.call("setFrames", { frames: { [shape.id]: frame } });
      }
      case "rotation": return engine.call("setFrames", { frames: { [shape.id]: { x: shape.x, y: shape.y, w: shape.w, h: shape.h, rot: Number(value) } } });
      case "altText": return engine.call("setAltText", { text: value });
      case "layoutName": return engine.call("renameLayout", { ids: [data.slide.id], name: value });
      // Links
      case "linkKind":
        if (value === "none") return engine.call("setLink", {});
        if (value === "url") return engine.call("setLink", { link: { url: shape.link?.url || "https://" } });
        if (value === "slide") return engine.call("setLink", { link: { slide: this.engine.info?.outline?.[0]?.id } });
        return engine.call("setLink", { link: { action: value } });
      case "linkURL": return engine.call("setLink", { link: { url: value } });
      case "linkSlide": return engine.call("setLink", { link: { slide: value } });
      // Slide
      case "layout": return engine.call("setLayout", { layout: value });
      case "hidden": return engine.call("toggleHidden", { ids: [data.slide.id] });
      case "advanceAuto": return engine.call("advance", { after: value ? 5 : null });
      case "advanceAfter": return Number(value) > 0 && engine.call("advance", { after: Number(value) });
      case "advanceOnClick": return engine.call("advance", { onClick: value });
      case "slideSize": {
        if (value === "custom") return null;
        const scaling = await this.ask.scaling();
        if (!scaling) return this.render();
        return engine.call("setSlideSize", { preset: value, scaling });
      }
      case "loop": return engine.call("loop", { on: value });
      // Animations
      case "addAnimation": {
        if (!value) return null;
        const [category, effect] = value.split(":");
        const id = await engine.call("addAnimation", { category, effect: { name: effect, direction: 4 } });
        this.selectedAnimation = id;
        return null;
      }
      case "animationEffect": return engine.call("updateAnimation", { id: this.selectedAnimation, set: { effect: { name: value, direction: Number(this.data.animations.find((a) => a.id === this.selectedAnimation)?.direction ?? 4) } } });
      case "animationDirection": return engine.call("updateAnimation", { id: this.selectedAnimation, set: { direction: Number(value) } });
      case "animationTrigger": return engine.call("updateAnimation", { id: this.selectedAnimation, set: { trigger: value } });
      case "animationDuration": return engine.call("updateAnimation", { id: this.selectedAnimation, set: { duration: Number(value) } });
      case "animationDelay": return engine.call("updateAnimation", { id: this.selectedAnimation, set: { delay: Number(value) } });
      // Comments
      case "author": return writeSetting("author", value.trim());
      default: return null;
    }
  }
}

export function readSetting(key, fallback) {
  try {
    return localStorage.getItem(`dazzle.${key}`) ?? fallback;
  } catch {
    return fallback;
  }
}

export function writeSetting(key, value) {
  try {
    localStorage.setItem(`dazzle.${key}`, value);
  } catch {
    // Settings are a convenience.
  }
}
