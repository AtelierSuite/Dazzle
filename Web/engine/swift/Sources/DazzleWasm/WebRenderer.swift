import DazzleEngine
import Foundation

/// Describes a slide for the page to draw: what `SlideRenderer` and
/// `TextRenderer` decide on Apple platforms (inheritance from the layout and
/// master, theme colours, fills, outlines, geometry, text styles, bullets,
/// tables and charts), as JSON the page turns into SVG and HTML.
///
/// Everything is in slide points. A shape's own drawing (its outline, picture
/// and text) is in its local space, with the frame's top-left corner at the
/// origin; the page places it, turns it and flips it.
@MainActor
struct WebRenderer {
    struct Options {
        /// Prompts in empty placeholders and badges on media, as the editor shows them.
        var editing = false
    }

    let presentation: Presentation
    let slide: Slide
    var options = Options()

    private var style: SlideStyleContext { SlideStyleContext(presentation: presentation, slide: slide) }
    private var slideNumber: Int { (presentation.index(of: slide.id) ?? 0) + 1 }

    init(presentation: Presentation, slide: Slide, options: Options = Options()) {
        self.presentation = presentation
        self.slide = slide
        self.options = options
    }

    func scene() -> [String: Any] {
        let size = presentation.slideSize.points
        let style = style
        var artwork: [[String: Any]] = []
        // Master and layout artwork sits under the slide's own shapes. Their
        // placeholders are only templates, so are not drawn.
        if slide.showsMasterShapes {
            if style.layout?.showsMasterShapes ?? true {
                for shape in style.master?.shapes ?? [] where shape.placeholder == nil {
                    if let node = node(shape, sources: [], style: style, isArtwork: true) { artwork.append(node) }
                }
            }
            for shape in style.layout?.shapes ?? [] where shape.placeholder == nil {
                if let node = node(shape, sources: [], style: style, isArtwork: true) { artwork.append(node) }
            }
        }
        var shapes: [[String: Any]] = []
        for shape in slide.shapes {
            if let node = node(shape, sources: style.sources(for: shape), style: style) { shapes.append(node) }
        }
        let background = style.background(of: slide)
        return [
            "w": Double(size.width), "h": Double(size.height),
            "bg": paint(background.fill, placeholder: background.placeholderColor, style: style) ?? ["t": "solid", "c": "#ffffff"],
            "art": artwork,
            "shapes": shapes,
        ]
    }

    // MARK: - Shapes

    private func node(
        _ shape: SlideShape, sources: [SlideShape], style: SlideStyleContext, isArtwork: Bool = false,
        groupFill: SlideStyleContext.ResolvedFill? = nil
    ) -> [String: Any]? {
        guard !shape.isHidden else { return nil }
        // Effects its style gives it, drawn as though its own.
        let shape = style.resolvingEffects(of: shape, sources: sources)
        let frame = shape.frame.points
        var node: [String: Any] = [
            "id": shape.id.uuidString, "sid": shape.shapeID, "name": shape.name,
            "x": n(frame.minX), "y": n(frame.minY), "w": n(frame.width), "h": n(frame.height),
        ]
        if shape.rotation != 0 { node["rot"] = shape.rotation }
        if shape.flipsHorizontally { node["fh"] = true }
        if shape.flipsVertically { node["fv"] = true }
        if isArtwork { node["art"] = true }
        if let placeholder = shape.placeholder { node["ph"] = placeholder.type ?? "obj" }
        if !shape.isEditable { node["locked"] = true }
        if let shadow = shape.shadow { node["shadow"] = self.shadow(shadow, style: style) }
        if let reflection = shape.reflection {
            node["reflection"] = [
                "start": reflection.startOpacity, "end": reflection.endOpacity, "endPos": reflection.endPosition,
                "dist": EMU.points(reflection.distance), "blur": EMU.points(reflection.blur), "turns": reflection.rotatesWithShape,
            ]
        }
        if let effects = effects(shape.effects, size: frame.size, style: style) { node["effects"] = effects }
        if let link = shape.link, let json = Self.link(link) { node["link"] = json }

        switch shape.kind {
        case .group(let group):
            node["kind"] = "group"
            let fill = style.fill(for: shape, sources: [])
            // Members are placed in slide space, so their lines and text keep their sizes.
            node["children"] = group.children.compactMap { member in
                self.node(member.placed(from: group.childFrame, into: shape.frame), sources: [], style: style,
                          isArtwork: isArtwork, groupFill: fill ?? groupFill)
            }
        case .diagram(let members):
            node["kind"] = "group"
            node["children"] = members.compactMap { self.node($0, sources: [], style: style, isArtwork: isArtwork) }
        case .picture(let picture):
            node["kind"] = "picture"
            picturePart(picture, shape: shape, frame: frame, style: style, into: &node)
        case .table(let table):
            node["kind"] = "table"
            node["table"] = self.table(table, shape: shape, frame: frame, style: style)
        case .chart(let chart?):
            node["kind"] = "chart"
            node["chart"] = WebChart(chart: chart, style: style).primitives(in: CGRect(origin: .zero, size: frame.size))
        case .chart(nil):
            node["kind"] = "standin"
            node["label"] = String(localized: "Object.Chart", bundle: .engine)
            node["isChart"] = true
        case .unsupported(let label):
            guard frame.width > 0, frame.height > 0 else { return nil }
            node["kind"] = "standin"
            node["label"] = label
        case .shape, .connector:
            node["kind"] = "shape"
            autoShape(shape, sources: sources, frame: frame, style: style, groupFill: groupFill, into: &node)
        }
        return node
    }

    /// The outline, in the shape's own space, as SVG and as the path its stroke follows.
    private func outline(
        of shape: SlideShape, size: CGSize
    ) -> (fill: String, stroke: String, isOpen: Bool, strokePath: CGPath, shades: [PresetGeometry.Shade]) {
        let rect = CGRect(origin: .zero, size: size)
        switch shape.geometry {
        case .preset(let name, let adjustments):
            // The stroke may add lines over the fill (a ribbon's folds, a cloud's puffs) or leave out parts only filled.
            let outline = PresetGeometry.outline(name, adjustments: adjustments, in: rect)
            return (outline.fill.svgData, outline.stroke.svgData, PresetGeometry.isOpen(name) || shape.kind == .connector,
                    outline.stroke, outline.shades)
        case .custom(let paths):
            let (fill, stroke) = PresetGeometry.path(paths, in: rect)
            return (fill.svgData, stroke.svgData, false, stroke, [])
        }
    }

    private func autoShape(
        _ shape: SlideShape, sources: [SlideShape], frame: CGRect, style: SlideStyleContext,
        groupFill: SlideStyleContext.ResolvedFill?, into node: inout [String: Any]
    ) {
        let (fillPath, strokePath, isOpen, strokeShape, shades) = outline(of: shape, size: frame.size)
        node["path"] = fillPath
        if strokePath != fillPath { node["strokePath"] = strokePath }
        // A cloud callout's bubbles may overlap the cloud. Apple platforms join
        // them into one outline; here they fill as one where they overlap.
        if shape.geometry.presetName == "cloudCallout" { node["rule"] = "nonzero" }
        if isOpen { node["open"] = true }
        if !isOpen, var fill = style.fill(for: shape, sources: sources) {
            if fill.fill == .group, let groupFill { fill = groupFill }
            if let paint = paint(fill.fill, placeholder: fill.placeholderColor, style: style) {
                node["fill"] = paint
                // A cube's sides and a scroll's curls: the fill, darkened or lightened.
                if !shades.isEmpty {
                    node["shades"] = shades.map { shade -> [String: Any] in
                        ["d": shade.path.svgData, "c": shade.tone.isLighter ? "#fff" : "#000", "o": Double(shade.tone.opacity)]
                    }
                }
            }
            if case .solid(let color) = fill.fill { node["fillColor"] = css(style.color(color, placeholder: fill.placeholderColor)) }
        }
        if let (line, placeholder) = style.line(for: shape, sources: sources),
           let stroke = stroke(line, path: Self.elements(strokePath), shape: strokeShape, placeholder: placeholder, style: style) {
            node["line"] = stroke
        }

        let textFrame = shape.textFrame?.points ?? shape.geometry.presetName.map {
            PresetGeometry.textRect($0, adjustments: shape.geometry.adjustments, in: frame)
        } ?? frame
        let local = textFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        // The text, or where typing goes in a shape with none yet.
        let body = shape.text ?? TextBody(paragraphs: [Paragraph(runs: [])])
        if shape.text != nil || shape.canHoldText {
            node["text"] = text(body, shape: shape, sources: sources, in: local, style: style)
        }
        if body.isEmpty, let placeholder = shape.placeholder, !placeholder.isFurniture {
            // An empty placeholder: the editor shows a dashed outline and a prompt.
            let prompt = switch placeholder.type {
            case "title", "ctrTitle": String(localized: "Placeholder.Title", bundle: .engine)
            case "subTitle": String(localized: "Placeholder.Subtitle", bundle: .engine)
            case "pic": String(localized: "Placeholder.Picture", bundle: .engine)
            default: String(localized: "Placeholder.Text", bundle: .engine)
            }
            var prompted = body
            let paragraph = body.paragraphs.first ?? Paragraph(runs: [])
            var run = TextRun(text: prompt, properties: paragraph.endProperties ?? RunProperties())
            run.kind = .text
            prompted.paragraphs = [Paragraph(properties: paragraph.properties, runs: [run])]
            node["prompt"] = text(prompted, shape: shape, sources: sources, in: local, style: style)
            node["promptRect"] = rect(local)
        }
    }

    // MARK: - Paint

    /// How many copies of the outline a shape gradient is drawn with, less one.
    static let shapeGradientSteps = 64

    private func paint(_ fill: Fill, placeholder: RGBAColor?, style: SlideStyleContext) -> [String: Any]? {
        switch fill {
        case .none, .group:
            return nil
        case .solid(let color):
            return ["t": "solid", "c": css(style.color(color, placeholder: placeholder))]
        case .gradient(let gradient):
            let stops = gradient.stops.map { [n(CGFloat($0.position)), css(style.color($0.color, placeholder: placeholder))] as [Any] }
            // Where a path gradient starts, and the box it spans, as insets from
            // each edge of the area by fractions of its size.
            func insets(_ box: Fill.Gradient.Insets) -> [Double] { [box.left, box.top, box.right, box.bottom] }
            var json: [String: Any] = ["stops": stops]
            if gradient.tileRect != .zero { json["tile"] = insets(gradient.tileRect) }
            guard let path = gradient.path else {
                json["t"] = "linear"
                json["angle"] = gradient.angle
                if gradient.isScaled { json["scaled"] = true }
                return json
            }
            json["focus"] = insets(gradient.fillToRect)
            let resolve = { (color: DrawingColor) in style.color(color, placeholder: placeholder) }
            switch path {
            case .circle:
                json["t"] = "radial"
            case .rect:
                json["t"] = "rect"
                json["from"] = css(gradient.color(at: 0, resolve: resolve))
                json["to"] = css(gradient.color(at: 1, resolve: resolve))
            case .shape:
                // Copies of the outline, from the tile in to the start, each a colour.
                json["t"] = "shape"
                json["rings"] = (0...Self.shapeGradientSteps).reversed().map {
                    css(gradient.color(at: Double($0) / Double(Self.shapeGradientSteps), resolve: resolve))
                }
            }
            return json
        case .pattern(let pattern):
            // Its eight rows of cells, top first, each a byte with the
            // leftmost cell its highest bit; set cells are the foreground.
            return [
                "t": "pattern", "rows": pattern.rows.map(Int.init), "cell": Fill.Pattern.cellSize,
                "fg": css(style.color(pattern.foreground, placeholder: placeholder)),
                "bg": css(style.color(pattern.background, placeholder: placeholder)),
            ]
        case .picture(let path, let effects):
            return ["t": "image", "src": path, "tile": false, "fx": self.effects(effects, placeholder: placeholder, style: style)]
        case .tiledPicture(let path, let effects, let layout):
            // How the tiles are laid: their scale, the point of the area the
            // first sits against (as fractions across and down), the offset
            // from there in points, and which are mirrored.
            let anchor = layout.alignment.fractions
            let tile: [String: Any] = [
                "sx": layout.scaleX, "sy": layout.scaleY, "ax": anchor.x, "ay": anchor.y,
                "tx": n(CGFloat(EMU.points(layout.offsetX))), "ty": n(CGFloat(EMU.points(layout.offsetY))),
                "flip": layout.flip.rawValue,
            ]
            return ["t": "image", "src": path, "tile": tile, "fx": self.effects(effects, placeholder: placeholder, style: style)]
        }
    }

    private func effects(_ effects: BlipEffects, placeholder: RGBAColor?, style: SlideStyleContext) -> [String: Any] {
        var json: [String: Any] = [:]
        if effects.opacity < 1 { json["opacity"] = effects.opacity }
        if effects.isGreyscale { json["grey"] = true }
        if effects.duotone.count == 2 { json["duotone"] = effects.duotone.map { css(style.color($0, placeholder: placeholder)) } }
        if effects.brightness != 0 { json["brightness"] = effects.brightness }
        if effects.contrast != 0 { json["contrast"] = effects.contrast }
        // The rest as the Apple renderer applies them, colours resolved and
        // adjustments as `feColorMatrix` values.
        let resolved = effects.resolved { style.color($0, placeholder: placeholder) }
        func rgba(_ color: RGBAColor) -> [Double] { [color.red, color.green, color.blue, color.alpha] }
        if let change = resolved.colorChange {
            json["change"] = ["from": rgba(change.from), "to": rgba(change.to), "tol": BlipEffects.ColorChange.tolerance]
        }
        if let threshold = resolved.biLevelThreshold { json["biLevel"] = threshold }
        if let hsl = resolved.hsl { json["hsl"] = hsl.values }
        if let tint = resolved.tint { json["tint"] = ["c": rgba(tint.color), "amt": tint.amount] }
        if !resolved.artistic.isEmpty { json["art"] = resolved.artistic.map(artistic) }
        return json
    }

    /// An artistic effect's look, for `effects()` in slide.js to draw as an
    /// SVG filter; sizes are fractions of the picture's longer side.
    private func artistic(_ effect: ResolvedPictureEffects.Artistic) -> [String: Any] {
        var json: [String: Any] = effect.transparency > 0 ? ["trans": effect.transparency] : [:]
        switch effect.look {
        case .matrix(let matrix): json["k"] = "matrix"; json["m"] = matrix.values
        case .blur(let sigma): json["k"] = "blur"; json["s"] = sigma
        case .sharpen(let amount): json["k"] = "sharpen"; json["v"] = amount
        case .sketch(let width, let inverted): json["k"] = "sketch"; json["s"] = width; json["inv"] = inverted
        case .edges(let smoothness): json["k"] = "edges"; json["v"] = smoothness
        case .paint(let levels, let softness): json["k"] = "paint"; json["n"] = levels; json["v"] = softness
        case .grain(let strength): json["k"] = "grain"; json["v"] = strength
        case .distort(let scale): json["k"] = "distort"; json["v"] = scale
        case .glow(let strength): json["k"] = "glow"; json["v"] = strength
        }
        return json
    }

    /// A glow, soft edges, an inner shadow, a preset shadow and a blur, in
    /// the shape's own space: the preset shadow as where each copy of the
    /// shape's silhouette goes, farthest first.
    private func effects(_ effects: ShapeEffects, size: CGSize, style: SlideStyleContext) -> [String: Any]? {
        guard !effects.isEmpty else { return nil }
        var json: [String: Any] = [:]
        if let glow = effects.glow {
            json["glow"] = ["r": n(CGFloat(EMU.points(glow.radius))), "c": css(style.color(glow.color))]
        }
        if let softEdge = effects.softEdge { json["soft"] = n(CGFloat(EMU.points(softEdge))) }
        if let blur = effects.blur { json["blur"] = ["r": n(CGFloat(EMU.points(blur.radius))), "grow": blur.grows] }
        var inner = effects.innerShadow.map { shadow -> (offset: CGSize, blur: Double, color: DrawingColor) in
            let radians = shadow.direction * .pi / 180, distance = EMU.points(shadow.distance)
            return (CGSize(width: cos(radians) * distance, height: sin(radians) * distance), EMU.points(shadow.blur), shadow.color)
        }
        if let preset = effects.presetShadow {
            if preset.cast.isInner {
                // The inner box preset is a hard inner shadow.
                inner = inner ?? (preset.offset, 0, preset.color)
            } else {
                json["preset"] = [
                    "c": css(style.color(preset.color)),
                    "casts": preset.transforms(in: CGRect(origin: .zero, size: size)).map { t in
                        [t.a, t.b, t.c, t.d, t.tx, t.ty].map { n(CGFloat($0)) }
                    },
                ]
            }
        }
        if let inner {
            json["inner"] = [
                "dx": n(inner.offset.width), "dy": n(inner.offset.height), "blur": n(CGFloat(inner.blur)),
                "c": css(style.color(inner.color)),
            ]
        }
        return json
    }

    private func shadow(_ shadow: Shadow, style: SlideStyleContext) -> [String: Any] {
        let radians = shadow.direction * .pi / 180
        let distance = EMU.points(shadow.distance)
        return [
            "dx": n(CGFloat(cos(radians) * distance)), "dy": n(CGFloat(sin(radians) * distance)),
            "blur": n(CGFloat(EMU.points(shadow.blur))), "c": css(style.color(shadow.color)),
        ]
    }

    /// An outline's look, with its arrowheads drawn at the ends of `path`,
    /// and a compound line's strokes set off to either side of `shape`.
    private func stroke(
        _ line: LineStyle, path: [CGPoint], shape: CGPath? = nil, placeholder: RGBAColor?, style: SlideStyleContext
    ) -> [String: Any]? {
        let fill = line.fill ?? .none
        if fill == .none || fill == .group { return nil }
        let width = max(EMU.points(line.width ?? 9_525), 0.25)
        // A gradient or picture is laid over the line as over a filled area,
        // across the line's bounds; `c` is its colour where only one will do.
        let resolved: String
        switch fill {
        case .solid(let color):
            resolved = css(style.color(color, placeholder: placeholder))
        case .gradient(let gradient):
            resolved = css(style.color(gradient.stops.first?.color ?? .scheme("tx1"), placeholder: placeholder))
        case .pattern(let pattern):
            resolved = css(style.color(pattern.foreground, placeholder: placeholder))
        default:
            resolved = css(style.color(.scheme("tx1"), placeholder: placeholder))
        }
        var json: [String: Any] = ["c": resolved, "w": n(CGFloat(width))]
        if case .solid = fill {} else if let paint = paint(fill, placeholder: placeholder, style: style) {
            json["paint"] = paint
            if let first = path.first {
                var bounds = CGRect(origin: first, size: .zero)
                for point in path.dropFirst() { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
                json["box"] = rect(bounds.insetBy(dx: -CGFloat(width) / 2, dy: -CGFloat(width) / 2))
            }
        }
        let dashes: [Double]? = switch line.dash {
        case "dash", "sysDash": [4, 3]
        case "lgDash": [8, 3]
        case "dot", "sysDot": [1, 2]
        case "dashDot", "sysDashDot": [4, 2, 1, 2]
        case "lgDashDot", "lgDashDotDot", "sysDashDotDot": [8, 3, 1, 3]
        default: nil
        }
        if let dashes { json["dash"] = dashes.map { n(CGFloat($0 * width)) } }
        switch line.cap {
        case "rnd": json["cap"] = "round"
        case "sq": json["cap"] = "square"
        default: break
        }
        switch line.join {
        case .bevel: json["join"] = "bevel"
        case .miter: json["join"] = "miter"
            json["miter"] = n(line.miterLimit)
        case .round, nil: break
        }
        if let shape {
            let bands = line.compoundStrokes(of: shape, width: CGFloat(width))
            if bands.count > 1 { json["bands"] = bands.map { ["d": $0.path.svgData, "w": n($0.width)] } }
        }
        if line.head != nil || line.tail != nil, path.count >= 2 {
            var heads: [[String: Any]] = []
            if let tail = line.tail { heads.append(arrowhead(tail, at: path[path.count - 1], from: path[path.count - 2], width: width)) }
            if let head = line.head { heads.append(arrowhead(head, at: path[0], from: path[1], width: width)) }
            json["heads"] = heads
        }
        return json
    }

    /// The points along an SVG path the parser below gives back: each move,
    /// line and curve's points, for finding where arrowheads go.
    private static func elements(_ svg: String) -> [CGPoint] {
        var numbers: [CGFloat] = []
        var points: [CGPoint] = []
        var number = ""
        func flush() {
            if let value = Double(number) { numbers.append(CGFloat(value)) }
            number = ""
        }
        for character in svg {
            if character.isNumber || character == "." || (character == "-" && number.isEmpty) {
                number.append(character)
            } else {
                flush()
                if character == "-" { number = "-" }
            }
        }
        flush()
        var index = 0
        while index + 1 < numbers.count {
            points.append(CGPoint(x: numbers[index], y: numbers[index + 1]))
            index += 2
        }
        return points
    }

    /// A line end of `type`: `triangle`, `stealth`, `arrow` (open), `oval` or `diamond`.
    private func arrowhead(_ type: String, at tip: CGPoint, from tail: CGPoint, width: Double) -> [String: Any] {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let length = max(CGFloat(width) * 4, 6)
        let spread: CGFloat = .pi / 7
        func point(_ distance: CGFloat, _ turn: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - distance * cos(angle + turn), y: tip.y - distance * sin(angle + turn))
        }
        let path = CGMutablePath()
        var filled = true
        switch type {
        case "oval":
            let radius = length / 2.5
            path.addEllipse(in: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
        case "diamond":
            let half = length / 2.5
            path.addLines(between: [
                CGPoint(x: tip.x + half * cos(angle), y: tip.y + half * sin(angle)),
                CGPoint(x: tip.x - half * sin(angle), y: tip.y + half * cos(angle)),
                CGPoint(x: tip.x - half * cos(angle), y: tip.y - half * sin(angle)),
                CGPoint(x: tip.x + half * sin(angle), y: tip.y - half * cos(angle)),
            ])
            path.closeSubpath()
        case "arrow":
            filled = false
            path.addLines(between: [point(length, -spread), tip, point(length, spread)])
        case "stealth":
            path.addLines(between: [tip, point(length, -spread), point(length * 0.6, 0), point(length, spread)])
            path.closeSubpath()
        default:
            path.addLines(between: [tip, point(length, -spread), point(length, spread)])
            path.closeSubpath()
        }
        return ["d": path.svgData, "filled": filled]
    }

    // MARK: - Pictures

    private func picturePart(
        _ picture: SlideShape.Picture, shape: SlideShape, frame: CGRect, style: SlideStyleContext, into node: inout [String: Any]
    ) {
        let (outlinePath, _, _, outlineShape, _) = outline(of: shape, size: frame.size)
        node["path"] = outlinePath
        if let path = picture.imagePath, presentation.data(at: path) != nil {
            let image = SlideShape.Picture.imageRect(frame: CGRect(origin: .zero, size: frame.size), picture: picture)
            node["src"] = path
            node["image"] = rect(image)
            node["fx"] = effects(picture.effects, placeholder: nil, style: style)
        } else {
            node["kind"] = "standin"
            node["label"] = String(localized: "Object.Picture", bundle: .engine)
        }
        if let (line, placeholder) = style.line(for: shape, sources: []),
           let stroke = stroke(line, path: Self.elements(outlinePath), shape: outlineShape, placeholder: placeholder, style: style) {
            node["line"] = stroke
        }
        if let media = picture.media {
            node["media"] = [
                "kind": media.kind == .video ? "video" : "audio", "path": media.path as Any, "url": media.url as Any,
                "auto": media.playsAutomatically,
            ]
        }
        if let crop = Optional(picture), crop.cropLeft != 0 || crop.cropTop != 0 || crop.cropRight != 0 || crop.cropBottom != 0 {
            node["crop"] = [crop.cropLeft, crop.cropTop, crop.cropRight, crop.cropBottom]
        }
    }

    // MARK: - Tables

    private func table(_ table: SlideTable, shape: SlideShape, frame: CGRect, style: SlideStyleContext) -> [String: Any] {
        let tableStyle = table.styleID.flatMap { presentation.resources.tableStyles[$0] }
        let usesBuiltInLook = table.styleID != nil && tableStyle == nil
        let accent = style.color(.scheme("accent1"))
        func isHeader(_ row: Int) -> Bool { table.hasHeaderRow && row == 0 }
        func isBanded(_ row: Int) -> Bool { table.hasBandedRows && (row - (table.hasHeaderRow ? 1 : 0)).isMultiple(of: 2) }

        var cells: [[String: Any]] = []
        for (rowIndex, row) in table.rows.enumerated() {
            for (columnIndex, cell) in row.cells.enumerated() where !cell.isMerged && columnIndex < table.columnCount {
                var json: [String: Any] = [
                    "r": rowIndex, "c": columnIndex, "rs": max(cell.rowSpan, 1), "cs": max(cell.columnSpan, 1),
                ]
                var fill = cell.fill
                if fill == nil, let tableStyle {
                    fill = isHeader(rowIndex) ? tableStyle.headerRow.fill : (isBanded(rowIndex) ? tableStyle.bandedRow.fill : nil)
                    fill = fill ?? tableStyle.whole.fill
                }
                if let fill {
                    if let paint = paint(fill, placeholder: nil, style: style) { json["fill"] = paint }
                } else if usesBuiltInLook {
                    let tint = isHeader(rowIndex) ? accent
                        : accent.applying(.init(name: "tint", value: isBanded(rowIndex) ? 40_000 : 20_000))
                    json["fill"] = ["t": "solid", "c": css(tint)]
                }

                // A cell's text, with its margins and the style's text colour and weight.
                let body = self.cellBody(cell, row: rowIndex, tableStyle: tableStyle, usesBuiltInLook: usesBuiltInLook, isHeader: isHeader(rowIndex))
                let width = (columnIndex..<min(columnIndex + max(cell.columnSpan, 1), table.columnCount))
                    .map { CGFloat(EMU.points(table.columnWidths[$0])) }.reduce(0, +)
                let rect = CGRect(x: 0, y: 0, width: width, height: CGFloat(EMU.points(table.rows[rowIndex].height)))
                let cellShape = Self.cellShape(body, rect)
                json["text"] = text(body, shape: cellShape, sources: [], in: rect, style: style)

                let lastRow = min(rowIndex + max(cell.rowSpan, 1), table.rows.count)
                let lastColumn = columnIndex + max(cell.columnSpan, 1) >= table.columnCount
                let edgeNames = [
                    rowIndex == 0 ? "top" : "insideH", lastRow >= table.rows.count ? "bottom" : "insideH",
                    columnIndex == 0 ? "left" : "insideV", lastColumn ? "right" : "insideV",
                ]
                func styleBorder(_ name: String) -> LineStyle? {
                    if let tableStyle {
                        let part = isHeader(rowIndex) ? tableStyle.headerRow : (isBanded(rowIndex) ? tableStyle.bandedRow : nil)
                        return part?.borders[name] ?? tableStyle.whole.borders[name]
                    }
                    return usesBuiltInLook ? LineStyle(fill: .solid(.scheme("lt1")), width: 12_700) : nil
                }
                var borders: [String: Any] = [:]
                for (key, border, name) in [("t", cell.borderTop, edgeNames[0]), ("b", cell.borderBottom, edgeNames[1]),
                                            ("l", cell.borderLeft, edgeNames[2]), ("r", cell.borderRight, edgeNames[3])] {
                    let fallback = styleBorder(name)
                    guard let line = border.map({ $0.merged(over: fallback) }) ?? fallback,
                          let stroke = stroke(line, path: [], placeholder: nil, style: style) else { continue }
                    borders[key] = stroke
                }
                if !borders.isEmpty { json["borders"] = borders }
                cells.append(json)
            }
        }
        return [
            "cols": table.columnWidths.map { n(CGFloat(EMU.points($0))) },
            "rows": table.rows.map { n(CGFloat(EMU.points($0.height))) },
            "cells": cells,
            "header": table.hasHeaderRow, "banded": table.hasBandedRows,
        ]
    }

    private func cellBody(_ cell: SlideTable.Cell, row: Int, tableStyle: TableStyle?, usesBuiltInLook: Bool, isHeader: Bool) -> TextBody {
        var body = cell.text ?? TextBody(paragraphs: [Paragraph(runs: [])])
        body.properties.leftInset = cell.marginLeft ?? 91_440
        body.properties.rightInset = cell.marginRight ?? 91_440
        body.properties.topInset = cell.marginTop ?? 45_720
        body.properties.bottomInset = cell.marginBottom ?? 45_720
        if body.properties.anchor == nil { body.properties.anchor = cell.anchor }
        var color: DrawingColor?
        var bold: Bool?
        if let tableStyle {
            let part = isHeader ? tableStyle.headerRow : tableStyle.whole
            color = part.textColor ?? tableStyle.whole.textColor
            bold = part.isBold
        } else if usesBuiltInLook, isHeader, cell.fill == nil {
            color = .scheme("lt1")
            bold = true
        }
        if color != nil || bold != nil {
            body.updateRuns { run in
                if run.isBold == nil, let bold { run.isBold = bold }
                if run.color == nil, let color { run.color = color }
            }
            for index in body.paragraphs.indices {
                var end = body.paragraphs[index].endProperties ?? RunProperties()
                if end.isBold == nil, let bold { end.isBold = bold }
                if end.color == nil, let color { end.color = color }
                body.paragraphs[index].endProperties = end
            }
        }
        return body
    }

    static func cellShape(_ body: TextBody, _ rect: CGRect) -> SlideShape {
        var shape = SlideShape(shapeID: 0, name: "", kind: .shape, frame: EMURect(points: rect))
        shape.text = body
        return shape
    }

    // MARK: - Text

    /// A text body laid out in `rect`, in the shape's own space: the area
    /// inside its insets, how it is anchored and fitted, and its paragraphs
    /// with every style resolved.
    func text(_ body: TextBody, shape: SlideShape, sources: [SlideShape], in rect: CGRect, style: SlideStyleContext) -> [String: Any] {
        let properties = style.bodyProperties(for: shape, sources: sources).merged(over: body.properties)
        let left = EMU.points(properties.leftInset ?? 91_440)
        let top = EMU.points(properties.topInset ?? 45_720)
        let right = EMU.points(properties.rightInset ?? 91_440)
        let bottom = EMU.points(properties.bottomInset ?? 45_720)
        let inner = CGRect(x: rect.minX + left, y: rect.minY + top, width: rect.width - left - right, height: rect.height - top - bottom)
        var json: [String: Any] = [
            "x": n(inner.minX), "y": n(inner.minY), "w": n(inner.width), "h": n(inner.height),
            "anchor": (properties.anchor ?? .top).rawValue,
            "wrap": properties.wraps ?? true,
        ]
        // How the text runs when it isn't horizontal, by its name in the file:
        // turned a quarter (vert, vert270), or set in vertical lines (eaVert,
        // mongolianVert, wordArtVert, wordArtVertRtl), which the page lays out.
        if let vertical = properties.vertical, ["vert", "eaVert", "vert270", "wordArtVert", "wordArtVertRtl", "mongolianVert"].contains(vertical) {
            json["vert"] = vertical
        }
        // Columns the text flows through, one after another, when it wraps.
        if let count = properties.columnCount, count > 1, properties.wraps ?? true {
            json["cols"] = count
            json["colGap"] = n(CGFloat(EMU.points(properties.columnSpacing ?? 0)))
            if properties.columnsRightToLeft == true { json["rtlCols"] = true }
        }
        switch properties.autofit {
        case .normal(let scale, let reduction)?:
            json["fit"] = "shrink"
            json["scale"] = scale
            json["reduce"] = reduction
        case .shape?:
            json["fit"] = "grow"
        default:
            break
        }
        json["paras"] = paragraphs(body, shape: shape, sources: sources, style: style)
        return json
    }

    private func paragraphs(_ body: TextBody, shape: SlideShape, sources: [SlideShape], style: SlideStyleContext) -> [[String: Any]] {
        var counters: [Int: Int] = [:]
        var result: [[String: Any]] = []
        for (index, paragraph) in body.paragraphs.enumerated() {
            let level = paragraph.properties.level ?? 0
            let properties = paragraph.properties.merged(over: style.paragraphBase(for: shape, sources: sources, level: level))
            let endRun = (paragraph.endProperties ?? paragraph.runs.last?.properties ?? RunProperties())
                .merged(over: properties.defaultRun)
            let firstRun = paragraph.runs.first.map { $0.properties.merged(over: properties.defaultRun) } ?? endRun
            let baseSize = Double(firstRun.size ?? 1_800) / 100

            var json: [String: Any] = ["i": index, "lvl": level]
            json["align"] = (properties.alignment ?? .left).rawValue
            json["ml"] = n(CGFloat(EMU.points(properties.marginLeft ?? 0)))
            json["ind"] = n(CGFloat(EMU.points(properties.indent ?? 0)))
            switch properties.lineSpacing {
            case .percent(let value)?: json["lh"] = ["pct": value]
            case .points(let value)?: json["lh"] = ["pt": value]
            case nil: break
            }
            func spacing(_ value: Spacing?) -> Double {
                switch value {
                case .points(let points): points
                case .percent(let percent): percent * baseSize * 1.2
                case nil: 0
                }
            }
            json["sb"] = spacing(properties.spaceBefore)
            json["sa"] = spacing(properties.spaceAfter)

            // Numbering continues through a level until something interrupts it.
            for deeper in counters.keys where deeper > level { counters[deeper] = nil }
            if !paragraph.plainText.isEmpty {
                var bulletText: String?
                switch properties.bullet {
                case .character(let character):
                    bulletText = character
                case .autoNumber(let scheme, let startAt):
                    let number = (counters[level] ?? (startAt - 1)) + 1
                    counters[level] = number
                    bulletText = TextLabels.numberLabel(number, scheme: scheme)
                default:
                    counters[level] = nil
                }
                if let bulletText {
                    var bulletRun = firstRun
                    bulletRun.isUnderlined = false
                    if let font = properties.bulletFont, !font.hasPrefix("+"), !["Arial", "Wingdings", "Symbol"].contains(font) {
                        bulletRun.latinFont = font
                    }
                    if let color = properties.bulletColor { bulletRun.color = color }
                    var bullet = run(bulletRun, style: style)
                    bullet["t"] = TextLabels.displayable(bulletText)
                    bullet["sz"] = (bullet["sz"] as? Double ?? 18) * (properties.bulletSize ?? 1)
                    json["bullet"] = bullet
                }
            } else {
                counters[level] = nil
            }

            var runs: [[String: Any]] = []
            for (runIndex, textRun) in paragraph.runs.enumerated() {
                var runProperties = textRun.properties.merged(over: properties.defaultRun)
                // Linked text is drawn in the theme's link colour, underlined, unless it says otherwise.
                if textRun.properties.link != nil {
                    runProperties.color = textRun.properties.color ?? .scheme("hlink")
                    runProperties.isUnderlined = textRun.properties.isUnderlined ?? true
                }
                var json = run(runProperties, style: style)
                json["r"] = runIndex
                switch textRun.kind {
                case .lineBreak:
                    json["br"] = true
                    json["t"] = ""
                case .field(let type):
                    json["field"] = type
                    // Offsets count the text as stored, whatever the field shows.
                    json["len"] = textRun.editingLength
                    if type == "slidenum" {
                        json["t"] = String(slideNumber)
                    } else if let date = DateField(rawValue: type) {
                        json["t"] = date.string(for: Date(), locale: Locale(identifier: PortableStrings.localeIdentifier))
                    } else {
                        json["t"] = textRun.text
                    }
                case .text:
                    var text = textRun.text
                    if runProperties.capitalization == "all" { text = text.uppercased() }
                    json["t"] = TextLabels.symbolsMapped(text)
                }
                if let link = textRun.properties.link, let linkJSON = Self.link(link) { json["link"] = linkJSON }
                runs.append(json)
            }
            json["runs"] = runs
            json["end"] = run(endRun, style: style)
            result.append(json)
        }
        return result
    }

    /// A run's look, every style resolved.
    private func run(_ run: RunProperties, style: SlideStyleContext) -> [String: Any] {
        var json: [String: Any] = ["sz": Double(run.size ?? 1_800) / 100]
        json["f"] = style.typeface(run.latinFont) ?? style.theme.minorFont
        if let eastAsian = style.typeface(run.eastAsianFont, eastAsian: true) ?? style.theme.minorEastAsianFont { json["ea"] = eastAsian }
        if run.isBold == true { json["b"] = true }
        if run.isItalic == true { json["i"] = true }
        if run.isUnderlined == true { json["u"] = true }
        if run.isStruckThrough == true { json["s"] = true }
        if let baseline = run.baseline, baseline != 0 { json["base"] = baseline > 0 ? 1 : -1 }
        // Character spacing, in points (`spc` is hundredths of a point).
        if let spacing = run.spacing, spacing != 0 { json["sp"] = Double(spacing) / 100 }
        json["c"] = css(run.color.map { style.color($0) } ?? style.color(.scheme("tx1")))
        if case .line(let width, let color) = run.outline, width > 0 {
            json["outline"] = ["w": EMU.points(width), "c": css(style.color(color))]
        }
        if case .shadow(let shadow) = run.shadow { json["shadow"] = self.shadow(shadow, style: style) }
        return json
    }

    static func link(_ link: Hyperlink) -> [String: Any]? {
        switch link {
        case .url(let address): ["url": address]
        case .slide(let id): ["slide": id.uuidString]
        case .nextSlide: ["action": "next"]
        case .previousSlide: ["action": "previous"]
        case .firstSlide: ["action": "first"]
        case .lastSlide: ["action": "last"]
        case .endShow: ["action": "end"]
        case .slidePart, .other: nil
        }
    }

    // MARK: - Numbers

    private func n(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }

    private func rect(_ rect: CGRect) -> [String: Any] {
        ["x": n(rect.minX), "y": n(rect.minY), "w": n(rect.width), "h": n(rect.height)]
    }
}

/// A colour as CSS writes it.
func css(_ color: RGBAColor) -> String {
    func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    if color.alpha >= 0.999 {
        return String(format: "#%02x%02x%02x", byte(color.red), byte(color.green), byte(color.blue))
    }
    return "rgba(\(byte(color.red)),\(byte(color.green)),\(byte(color.blue)),\((color.alpha * 1000).rounded() / 1000))"
}
