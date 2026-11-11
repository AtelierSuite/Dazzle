import Foundation

/// Lays out SmartArt that has no drawing of itself, from its data model.
///
/// PowerPoint saves a drawing of each SmartArt beside its data, and that is
/// what is shown when it is there. Files from other apps, and older ones,
/// carry only the data: the tree of points in `dgm:dataModel`, the layout
/// that arranges them, and the colours and style that paint them. Rather
/// than run the layout part's own algorithm language, each common family of
/// layouts — lists, processes, cycles, hierarchies, pyramids, radials, Venns
/// and matrices — is drawn here by hand, and anything else as a block list.
///
/// The shapes are made when the file is read and are never written: the
/// SmartArt's parts are saved back as they were read.
struct DiagramLayout {
    /// A point of the data model, with the points below it.
    struct Node {
        /// `dgm:t`: the point's text.
        var text: XMLElement?
        /// `dgm:spPr`: what the point's own formatting says, if anything.
        var properties: XMLElement?
        var children: [Node] = []
    }

    enum Family: Equatable {
        case blockList
        case verticalList
        case horizontalList
        case process(vertical: Bool)
        case continuousProcess
        case chevron
        case cycle
        case hierarchy
        case pyramid
        case radial
        case venn(linear: Bool)
        case matrix

        /// The family a layout's `uniqueId` (or a data model's `loTypeId`) belongs to.
        init(layoutID: String?) {
            let name = (layoutID ?? "").split(separator: "/").last.map { $0.lowercased() } ?? ""
            if name.contains("hierarchy") || name.contains("orgchart") || name.contains("organizationchart")
                || name.contains("organizationalchart") {
                self = .hierarchy
            } else if name.hasPrefix("pyramid") {
                self = .pyramid
            } else if name.contains("venn") {
                self = .venn(linear: name == "venn3")
            } else if name.hasPrefix("radial") {
                self = .radial
            } else if name.contains("matrix") {
                self = .matrix
            } else if name.contains("cycle") {
                self = .cycle
            } else if name.contains("chevron") {
                self = .chevron
            } else if name == "hprocess9" {
                self = .continuousProcess
            } else if name == "process2" || name.hasPrefix("vprocess") {
                self = .process(vertical: true)
            } else if name.contains("process") {
                self = .process(vertical: false)
            } else if name.hasPrefix("hlist") {
                self = .horizontalList
            } else if name.hasPrefix("vlist") {
                self = .verticalList
            } else {
                self = .blockList
            }
        }
    }

    /// How one kind of shape in the diagram is painted.
    struct Paint {
        var fill: Fill?
        var line: LineStyle?
        var text: DrawingColor?
        var style: StyleReferences?
    }

    let family: Family
    /// The top-level points: the children of the document point.
    let nodes: [Node]
    /// `dgm:colorsDef`'s style labels, by name.
    let colorLabels: [String: XMLElement]
    /// `dgm:styleDef`'s style labels, by name.
    let styleLabels: [String: XMLElement]
    /// Reads a point's `dgm:t` as text.
    let textBody: (XMLElement) -> TextBody

    init(
        model: XMLElement, layout: XMLElement?, colors: XMLElement?, style: XMLElement?,
        textBody: @escaping (XMLElement) -> TextBody
    ) {
        let points = model.firstChild(named: "ptLst")?.children(named: "pt") ?? []
        let document = points.first { $0.attribute("type") == "doc" }
        family = Family(
            layoutID: layout?.attribute("uniqueId")?.nilIfEmpty
                ?? document?.firstChild(named: "prSet")?.attribute("loTypeId")
        )
        nodes = Self.tree(points: points, connections: model.firstChild(named: "cxnLst")?.children(named: "cxn") ?? [])
        func labels(_ element: XMLElement?) -> [String: XMLElement] {
            var labels: [String: XMLElement] = [:]
            for label in element?.children(named: "styleLbl") ?? [] {
                if let name = label.attribute("name"), labels[name] == nil { labels[name] = label }
            }
            return labels
        }
        colorLabels = labels(colors)
        styleLabels = labels(style)
        self.textBody = textBody
    }

    // MARK: - The data model

    /// The points under the document point, following its parent-of
    /// connections in order.
    static func tree(points: [XMLElement], connections: [XMLElement]) -> [Node] {
        var byID: [String: XMLElement] = [:]
        for point in points {
            if let id = point.attribute("modelId") { byID[id] = point }
        }
        func isContent(_ point: XMLElement) -> Bool {
            let type = point.attribute("type") ?? "node"
            return type == "node" || type == "asst"
        }
        var children: [String: [(order: Int, id: String)]] = [:]
        var hasParent = Set<String>()
        for connection in connections where (connection.attribute("type") ?? "parOf") == "parOf" {
            guard let source = connection.attribute("srcId"), let destination = connection.attribute("destId") else { continue }
            let order = connection.attribute("srcOrd").flatMap(Int.init) ?? Int.max
            children[source, default: []].append((order, destination))
            hasParent.insert(destination)
        }
        var visited = Set<String>()
        func node(_ id: String, depth: Int) -> Node? {
            guard depth < 16, let point = byID[id], isContent(point), visited.insert(id).inserted else { return nil }
            return Node(
                text: point.firstChild(named: "t"), properties: point.firstChild(named: "spPr"),
                children: below(id, depth: depth + 1)
            )
        }
        func below(_ id: String, depth: Int) -> [Node] {
            (children[id] ?? []).enumerated()
                .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
                .compactMap { node($0.element.id, depth: depth) }
        }
        if let document = points.first(where: { $0.attribute("type") == "doc" })?.attribute("modelId") {
            return below(document, depth: 0)
        }
        // Without a document point, the points no connection leads to are the top.
        return points.filter { isContent($0) && !hasParent.contains($0.attribute("modelId") ?? "") }
            .compactMap { $0.attribute("modelId").flatMap { node($0, depth: 0) } }
    }

    // MARK: - Laying out

    /// The diagram's shapes, in slide space, for a frame placed at `frame`.
    func shapes(in frame: EMURect) -> [SlideShape] {
        guard !nodes.isEmpty, frame.width > 0, frame.height > 0 else { return [] }
        let bounds = CGRect(x: 0, y: 0, width: Double(frame.width), height: Double(frame.height))
        var builder = Builder(layout: self)
        switch family {
        case .blockList: builder.blockList(nodes, in: bounds)
        case .verticalList: builder.verticalList(in: bounds)
        case .horizontalList: builder.horizontalList(in: bounds)
        case .process(let vertical): builder.process(vertical: vertical, in: bounds)
        case .continuousProcess: builder.continuousProcess(in: bounds)
        case .chevron: builder.chevron(in: bounds)
        case .cycle: builder.cycle(in: bounds)
        case .hierarchy: builder.hierarchy(in: bounds)
        case .pyramid: builder.pyramid(in: bounds)
        case .radial: builder.radial(in: bounds)
        case .venn(let linear): builder.venn(linear: linear, in: bounds)
        case .matrix: builder.matrix(in: bounds)
        }
        return builder.finished().map { shape in
            var moved = shape
            moved.frame.x += frame.x
            moved.frame.y += frame.y
            if var text = moved.textFrame {
                text.x += frame.x
                text.y += frame.y
                moved.textFrame = text
            }
            return moved
        }
    }

    // MARK: - Colours and style

    /// Paint for the `index`th of `count` shapes drawn with a style label,
    /// from the colours and style parts, or the theme's first accent where
    /// they say nothing.
    func paint(_ label: String, index: Int, count: Int, node: Node? = nil) -> Paint {
        // An empty list leaves the colour to the style part, or to the default.
        func pick(_ list: String) -> DrawingColor? {
            guard let element = colorLabels[label]?.firstChild(named: list) else { return nil }
            let choices = element.children.compactMap(DrawingColor.init(element:))
            guard !choices.isEmpty else { return nil }
            let position: Int
            if element.attribute("meth") == "span", count > 1 {
                position = Int((Double(index) * Double(choices.count - 1) / Double(count - 1)).rounded())
            } else {
                position = index % choices.count
            }
            return choices[min(max(position, 0), choices.count - 1)]
        }
        let style = styleLabels[label]?.firstChild(named: "style")
        var references = StyleReferences(element: style) ?? Self.defaultStyle
        let fallback = Self.fallbackColors(label)
        let fillColor = pick("fillClrLst") ?? fallback.fill
        let lineColor = pick("linClrLst") ?? fallback.line
        let textColor = pick("txFillClrLst") ?? references.fontColor ?? fallback.text

        var paint = Paint()
        paint.fill = fillColor.map(Fill.solid) ?? Fill.none
        paint.line = LineStyle(fill: lineColor.map(Fill.solid) ?? Fill.none)
        paint.text = textColor
        references.fill?.color = fillColor
        references.line?.color = lineColor
        references.effect?.color = fillColor
        references.fontColor = textColor
        if style == nil, label.hasPrefix("parChTrans") || label.hasPrefix("sibTrans1D") {
            references.line = StyleReferences.Reference(index: 1, color: lineColor)
        }
        paint.style = references

        // A point's own formatting is the user's, and wins.
        if let properties = node?.properties {
            if let fill = Fill.parse(in: properties, image: { _ in nil }) { paint.fill = fill }
            if let line = properties.firstChild(named: "ln").map(LineStyle.init(element:)) {
                paint.line = line.merged(over: paint.line ?? LineStyle())
            }
        }
        return paint
    }

    /// `lnRef 2`, `fillRef 1`, `effectRef 0`: how SmartArt's simple style draws a shape.
    static let defaultStyle: StyleReferences = {
        let xml = #"<style><lnRef idx="2"/><fillRef idx="1"/><effectRef idx="0"/><fontRef idx="minor"/></style>"#
        return (try? XMLLite.parse(Data(xml.utf8))).flatMap(StyleReferences.init(element:))!
    }()

    /// The colours PowerPoint's default colour set (`accent1_2`) gives each label.
    static func fallbackColors(_ label: String) -> (fill: DrawingColor?, line: DrawingColor?, text: DrawingColor?) {
        func accent(_ transforms: [(String, Int)] = []) -> DrawingColor {
            DrawingColor(base: .scheme("accent1"), transforms: transforms.map { DrawingColor.Transform(name: $0.0, value: $0.1) })
        }
        let light = DrawingColor.scheme("lt1")
        let dark = DrawingColor.scheme("dk1")
        switch label {
        case "alignAccFollowNode1":
            return (accent([("alpha", 90_000), ("tint", 40_000)]), accent([("alpha", 90_000), ("tint", 40_000)]), dark)
        case "sibTrans2D1":
            return (accent([("tint", 60_000)]), accent([("tint", 60_000)]), light)
        case "parChTrans1D2":
            return (nil, accent([("shade", 60_000)]), dark)
        case "bgShp":
            return (accent([("tint", 40_000)]), nil, dark)
        case "vennNode1":
            return (accent([("alpha", 50_000)]), light, dark)
        case "revTx":
            return (nil, nil, dark)
        default:
            return (accent(), light, light)
        }
    }

    // MARK: - Text

    /// A point's text set in a shape: its own paragraphs, centred, and if
    /// `withChildren`, the text of the points below it as bullets.
    func text(for node: Node, withChildren: Bool, alignment: ParagraphAlignment = .center) -> TextBody? {
        var body = node.text.map(textBody) ?? TextBody(paragraphs: [])
        body.paragraphs = body.paragraphs.filter { !$0.plainText.isEmpty }
        body.updateParagraphs { if $0.alignment == nil { $0.alignment = alignment } }
        if withChildren {
            body.paragraphs += bullets(below: node, level: body.paragraphs.isEmpty ? 0 : 1)
        }
        if body.paragraphs.isEmpty { return nil }
        if body.properties.anchor == nil { body.properties.anchor = .center }
        if body.properties.wraps == nil { body.properties.wraps = true }
        return body
    }

    /// The text of the points below `node`, as bulleted paragraphs.
    func bullets(below node: Node, level: Int) -> [Paragraph] {
        node.children.flatMap { child -> [Paragraph] in
            var own = child.text.map(textBody)?.paragraphs.filter { !$0.plainText.isEmpty } ?? []
            for index in own.indices {
                own[index].properties.level = level
                if own[index].properties.bullet == nil { own[index].properties.bullet = .character("•") }
                if own[index].properties.alignment == nil { own[index].properties.alignment = .left }
            }
            return own + bullets(below: child, level: level + 1)
        }
    }

    /// The largest size, in points, at which each text fits its area (in
    /// EMU), estimated from its characters: SmartArt sets the text of shapes
    /// alike at one size.
    static func fittedSize(_ texts: [(body: TextBody, area: CGSize)], maximum: Double = 65) -> Double {
        let fitting = texts.filter { !$0.body.isEmpty }
        guard !fitting.isEmpty else { return maximum }
        func fits(_ size: Double) -> Bool {
            fitting.allSatisfy { text in
                let width = text.area.width / 12_700 - 14.4
                let height = text.area.height / 12_700 - 7.2
                guard width > 0, height > 0 else { return false }
                var lines = 0.0
                for paragraph in text.body.paragraphs {
                    let scale = Double(paragraph.runs.first?.properties.size ?? Int(size * 100)) / (size * 100)
                    let indent = paragraph.properties.bullet == nil ? 0
                        : paragraph.properties.marginLeft.map { Double($0) / 12_700 }
                            ?? bulletIndent(level: paragraph.properties.level, size: size)
                    let available = width - indent
                    let words = paragraph.plainText.split(separator: " ").map { Self.width(of: $0) * size * min(scale, 1) }
                    guard words.allSatisfy({ $0 <= available }) else { return false }
                    let total = Self.width(of: Substring(paragraph.plainText)) * size * min(scale, 1)
                    lines += max(1, (total / available).rounded(.up))
                }
                return lines * size * 1.2 <= height
            }
        }
        var size = maximum
        while size > 6, !fits(size) {
            size -= size > 20 ? 2 : 0.5
        }
        return size
    }

    /// A line of text's width in ems, roughly.
    private static func width(of text: Substring) -> Double {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.value >= 0x2E80 ? 1 : scalar.properties.isUppercase ? 0.65 : 0.52)
        }
    }

    /// How far a bullet's text is indented at a level, in points: in step with its size, so the
    /// bullet always has room before its text.
    static func bulletIndent(level: Int?, size: Double) -> Double {
        Double((level ?? 0) + 1) * size * 0.8
    }

    /// Sets every run the file leaves unsized at `size` points, and
    /// indents bullets the file leaves unindented to suit.
    static func sized(_ body: TextBody?, _ size: Double) -> TextBody? {
        guard var body else { return nil }
        let hundredths = Int((size * 100).rounded())
        body.updateRuns { if $0.size == nil { $0.size = hundredths } }
        body.updateParagraphs { properties in
            guard properties.bullet != nil, properties.marginLeft == nil else { return }
            properties.marginLeft = Int((bulletIndent(level: properties.level, size: size) * 12_700).rounded())
            properties.indent = properties.indent ?? -Int((size * 0.8 * 12_700).rounded())
        }
        return body
    }
}

// MARK: - Shapes

private struct Builder {
    let layout: DiagramLayout
    var shapes: [SlideShape] = []
    /// Texts waiting to be sized together, by group, and the shapes they go in.
    var pending: [String: [(index: Int, area: CGSize)]] = [:]
    /// Text below a point is set no larger than this.
    var maximum: [String: Double] = ["bullets": 28]

    init(layout: DiagramLayout) {
        self.layout = layout
    }

    /// Adds a shape. Its text is sized with the rest of `group`'s.
    mutating func add(
        _ geometry: String, adjustments: [String: Int] = [:], frame: CGRect, paint: DiagramLayout.Paint,
        text: TextBody? = nil, group: String = "node", textArea: CGRect? = nil, rotation: Double = 0,
        flipsHorizontally: Bool = false, flipsVertically: Bool = false, isConnector: Bool = false
    ) {
        var shape = SlideShape(
            shapeID: 0, name: "", kind: isConnector ? .connector : .shape,
            frame: EMURect(
                x: Int(frame.minX.rounded()), y: Int(frame.minY.rounded()),
                width: Int(max(frame.width, 0).rounded()), height: Int(max(frame.height, 0).rounded())
            )
        )
        shape.geometry = .preset(geometry, adjustments: adjustments)
        shape.fill = isConnector ? nil : paint.fill
        shape.line = paint.line
        shape.style = paint.style
        shape.rotation = rotation
        shape.flipsHorizontally = flipsHorizontally
        shape.flipsVertically = flipsVertically
        if let textArea {
            shape.textFrame = EMURect(
                x: Int(textArea.minX.rounded()), y: Int(textArea.minY.rounded()),
                width: Int(textArea.width.rounded()), height: Int(textArea.height.rounded())
            )
        }
        if let text {
            shape.text = text
            let area = textArea?.size ?? PresetGeometry.textRect(geometry, adjustments: adjustments, in: frame).size
            pending[group, default: []].append((shapes.count, area))
        }
        shapes.append(shape)
    }

    /// A straight line from one point to another.
    mutating func line(from start: CGPoint, to end: CGPoint, paint: DiagramLayout.Paint) {
        add(
            "line", frame: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)),
            paint: paint, flipsHorizontally: end.x < start.x, flipsVertically: end.y < start.y, isConnector: true
        )
    }

    /// The shapes, with each group's text set at the one size that fits all of it.
    func finished() -> [SlideShape] {
        var result = shapes
        for (group, members) in pending {
            let size = DiagramLayout.fittedSize(
                members.compactMap { member in result[member.index].text.map { ($0, member.area) } },
                maximum: maximum[group] ?? 65
            )
            for member in members {
                result[member.index].text = DiagramLayout.sized(result[member.index].text, size)
            }
        }
        return result
    }

    // MARK: Lists

    /// Boxes in rows, each with its point's text and the text below it.
    mutating func blockList(_ nodes: [DiagramLayout.Node], in bounds: CGRect) {
        let count = nodes.count
        let gap = 0.1, aspect = 0.6
        var best = (columns: 1, width: 0.0)
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let width = min(
                bounds.width / (Double(columns) + Double(columns - 1) * gap),
                bounds.height / (Double(rows) * aspect + Double(rows - 1) * gap)
            )
            if width > best.width { best = (columns, width) }
        }
        let width = best.width, height = width * aspect, spacing = width * gap
        let rows = (count + best.columns - 1) / best.columns
        let totalHeight = Double(rows) * height + Double(rows - 1) * spacing
        for (index, node) in nodes.enumerated() {
            let row = index / best.columns, column = index % best.columns
            let inRow = min(best.columns, count - row * best.columns)
            let rowWidth = Double(inRow) * width + Double(inRow - 1) * spacing
            let frame = CGRect(
                x: bounds.midX - rowWidth / 2 + Double(column) * (width + spacing),
                y: bounds.midY - totalHeight / 2 + Double(row) * (height + spacing),
                width: width, height: height
            )
            add("rect", frame: frame, paint: layout.paint("node1", index: index, count: count, node: node),
                text: layout.text(for: node, withChildren: true))
        }
    }

    /// Bars down the frame, each followed by its points' text as bullets.
    mutating func verticalList(in bounds: CGRect) {
        let nodes = layout.nodes
        let lines = nodes.map { Double(layout.bullets(below: $0, level: 0).count) }
        let gap = 0.15
        let units = zip(nodes, lines).reduce(0) { $0 + 1 + ($1.1 > 0 ? 0.2 + 0.55 * $1.1 : 0) } + gap * Double(nodes.count - 1)
        let unit = min(bounds.height / units, bounds.height * 0.3)
        var y = bounds.minY + (bounds.height - unit * units) / 2
        for (index, node) in nodes.enumerated() {
            let header = CGRect(x: bounds.minX, y: y, width: bounds.width, height: unit)
            add("roundRect", frame: header, paint: layout.paint("node1", index: index, count: nodes.count, node: node),
                text: layout.text(for: node, withChildren: false, alignment: .left))
            y += unit
            if lines[index] > 0 {
                let height = unit * (0.2 + 0.55 * lines[index])
                var body = layout.text(for: DiagramLayout.Node(children: node.children), withChildren: true)
                body?.properties.anchor = .top
                add("rect", frame: CGRect(x: bounds.minX + bounds.width * 0.05, y: y, width: bounds.width * 0.95, height: height),
                    paint: layout.paint("revTx", index: index, count: nodes.count), text: body, group: "bullets")
                y += height
            }
            y += unit * gap
        }
    }

    /// Columns, each a heading over a box of its points' text as bullets.
    mutating func horizontalList(in bounds: CGRect) {
        let nodes = layout.nodes
        let hasBullets = nodes.contains { !$0.children.isEmpty }
        let width = bounds.width / (Double(nodes.count) + Double(nodes.count - 1) * 0.1)
        let headerHeight = hasBullets ? bounds.height * 0.25 : min(bounds.height, width * 0.6)
        let top = hasBullets ? bounds.minY : bounds.midY - headerHeight / 2
        for (index, node) in nodes.enumerated() {
            let x = bounds.minX + Double(index) * width * 1.1
            add("rect", frame: CGRect(x: x, y: top, width: width, height: headerHeight),
                paint: layout.paint("node1", index: index, count: nodes.count, node: node),
                text: layout.text(for: node, withChildren: false))
            guard hasBullets else { continue }
            var body = layout.text(for: DiagramLayout.Node(children: node.children), withChildren: true)
            body?.properties.anchor = .top
            add("rect", frame: CGRect(x: x, y: top + headerHeight, width: width, height: bounds.height - headerHeight),
                paint: layout.paint("alignAccFollowNode1", index: index, count: nodes.count), text: body, group: "bullets")
        }
    }

    // MARK: Processes

    /// Boxes in a row (or a column), with arrows between them.
    mutating func process(vertical: Bool, in bounds: CGRect) {
        let nodes = layout.nodes, count = Double(nodes.count)
        let gap = 0.4
        let long = vertical ? bounds.height : bounds.width
        let across = vertical ? bounds.width : bounds.height
        // Boxes are wider than they are tall, whichever way they run.
        let ratio = vertical ? 1 / 0.6 : 0.6
        var length = long / (count + (count - 1) * gap)
        var breadth = length * ratio
        if breadth > across {
            breadth = across
            length = min(length, across / ratio)
        }
        let total = length * count + length * gap * (count - 1)
        let start = (vertical ? bounds.minY : bounds.minX) + (long - total) / 2
        let middle = vertical ? bounds.midX : bounds.midY
        func rect(along: Double, length: Double, breadth: Double) -> CGRect {
            vertical
                ? CGRect(x: middle - breadth / 2, y: along, width: breadth, height: length)
                : CGRect(x: along, y: middle - breadth / 2, width: length, height: breadth)
        }
        for (index, node) in nodes.enumerated() {
            let along = start + Double(index) * length * (1 + gap)
            add("roundRect", adjustments: ["adj": 10_000], frame: rect(along: along, length: length, breadth: breadth),
                paint: layout.paint("node1", index: index, count: nodes.count, node: node),
                text: layout.text(for: node, withChildren: true))
            if index < nodes.count - 1 {
                let arrowLength = length * gap * 0.6
                let arrow = rect(along: along + length + length * gap * 0.2, length: arrowLength, breadth: min(breadth * 0.35, arrowLength * 1.2))
                add(vertical ? "downArrow" : "rightArrow", adjustments: ["adj1": 60_000, "adj2": 50_000], frame: arrow,
                    paint: layout.paint("sibTrans2D1", index: index, count: nodes.count - 1))
            }
        }
    }

    /// Boxes in a row over a wide arrow.
    mutating func continuousProcess(in bounds: CGRect) {
        let nodes = layout.nodes, count = Double(nodes.count)
        let arrowHeight = min(bounds.height, bounds.width * 0.6)
        add("rightArrow", adjustments: ["adj1": 50_000, "adj2": 50_000],
            frame: CGRect(x: bounds.minX, y: bounds.midY - arrowHeight / 2, width: bounds.width * 0.92, height: arrowHeight),
            paint: layout.paint("bgShp", index: 0, count: 1))
        let span = bounds.width * 0.9
        let width = span / (count + (count - 1) * 0.15)
        let height = min(arrowHeight * 0.4, width)
        for (index, node) in nodes.enumerated() {
            let frame = CGRect(
                x: bounds.minX + bounds.width * 0.02 + Double(index) * width * 1.15, y: bounds.midY - height / 2,
                width: width, height: height
            )
            add("roundRect", frame: frame, paint: layout.paint("node1", index: index, count: nodes.count, node: node),
                text: layout.text(for: node, withChildren: true))
        }
    }

    /// Chevrons nested in a row.
    mutating func chevron(in bounds: CGRect) {
        let nodes = layout.nodes, count = Double(nodes.count)
        var width = bounds.width / (1 + (count - 1) * 0.84)
        var height = width * 0.4
        if height > bounds.height {
            height = bounds.height
            width = height / 0.4
        }
        let step = width - height * 0.4
        let total = width + step * (count - 1)
        let start = bounds.minX + (bounds.width - total) / 2
        for (index, node) in nodes.enumerated() {
            let frame = CGRect(x: start + Double(index) * step, y: bounds.midY - height / 2, width: width, height: height)
            add("chevron", frame: frame, paint: layout.paint("node1", index: index, count: nodes.count, node: node),
                text: layout.text(for: node, withChildren: true),
                textArea: frame.insetBy(dx: height * 0.5, dy: 0))
        }
    }

    // MARK: Cycles and radials

    /// Circles round a ring, with arrows between them, clockwise from the top.
    mutating func cycle(in bounds: CGRect) {
        let nodes = layout.nodes, count = nodes.count
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let chord = 2 * sin(Double.pi / Double(max(count, 2)))
        let diameter = count == 1 ? side * 0.6 : min(chord * side / 2 / (1.5 + chord / 2), side * 0.4)
        let radius = count == 1 ? 0 : side / 2 - diameter / 2
        func point(_ angle: Double, _ radius: Double) -> CGPoint {
            CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
        }
        for (index, node) in nodes.enumerated() {
            let angle = 2 * Double.pi * Double(index) / Double(count)
            let middle = point(angle, radius)
            add("ellipse", frame: CGRect(x: middle.x - diameter / 2, y: middle.y - diameter / 2, width: diameter, height: diameter),
                paint: layout.paint("node1", index: index, count: count, node: node),
                text: layout.text(for: node, withChildren: true))
        }
        guard count > 1 else { return }
        let length = min(max(chord * radius - diameter, 0) * 0.7, diameter * 0.6)
        guard length > 0 else { return }
        for index in 0..<count {
            let angle = 2 * Double.pi * (Double(index) + 0.5) / Double(count)
            let middle = point(angle, radius)
            add("rightArrow", adjustments: ["adj1": 60_000, "adj2": 50_000],
                frame: CGRect(x: middle.x - length / 2, y: middle.y - length * 0.3, width: length, height: length * 0.6),
                paint: layout.paint("sibTrans2D1", index: index, count: count), rotation: angle * 180 / Double.pi)
        }
    }

    /// The first point in the middle, the points below it round it, joined by lines.
    mutating func radial(in bounds: CGRect) {
        guard let hub = layout.nodes.first else { return }
        let outer = hub.children + layout.nodes.dropFirst()
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard !outer.isEmpty else {
            add("ellipse", frame: CGRect(x: center.x - side * 0.3, y: center.y - side * 0.3, width: side * 0.6, height: side * 0.6),
                paint: layout.paint("node0", index: 0, count: 1, node: hub), text: layout.text(for: hub, withChildren: false))
            return
        }
        let spread = sin(Double.pi / Double(max(outer.count, 2)))
        let diameter = min(spread * side / (1.1 + spread), side / 3.7)
        let hubDiameter = diameter * 1.4
        let radius = side / 2 - diameter / 2
        let points = outer.indices.map { index in
            let angle = 2 * Double.pi * Double(index) / Double(outer.count)
            return CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
        }
        for (index, point) in points.enumerated() {
            line(from: center, to: point, paint: layout.paint("parChTrans1D2", index: index, count: outer.count))
        }
        add("ellipse", frame: CGRect(x: center.x - hubDiameter / 2, y: center.y - hubDiameter / 2, width: hubDiameter, height: hubDiameter),
            paint: layout.paint("node0", index: 0, count: 1, node: hub), text: layout.text(for: hub, withChildren: false), group: "hub")
        for (index, node) in outer.enumerated() {
            let point = points[index]
            add("ellipse", frame: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter),
                paint: layout.paint("node1", index: index, count: outer.count, node: node),
                text: layout.text(for: node, withChildren: true))
        }
    }

    // MARK: Hierarchies

    /// A tree drawn top down, each point over the points below it, joined by elbow lines.
    mutating func hierarchy(in bounds: CGRect) {
        func leaves(_ node: DiagramLayout.Node) -> Int { max(1, node.children.reduce(0) { $0 + leaves($1) }) }
        func depth(_ node: DiagramLayout.Node) -> Int { 1 + (node.children.map(depth).max() ?? 0) }
        let roots = layout.nodes
        let leafCount = Double(roots.reduce(0) { $0 + leaves($1) })
        let levels = Double(roots.map(depth).max() ?? 1)
        let gap = 0.2
        var width = bounds.width / (leafCount + (leafCount - 1) * gap)
        var height = width * 0.66
        let rowsHeight = height * levels + height * 0.5 * (levels - 1)
        if rowsHeight > bounds.height {
            height = bounds.height / (levels + (levels - 1) * 0.5)
            width = min(width, height / 0.66 * 1.6)
        }
        let rise = levels > 1 ? min(height, (bounds.height - height * levels) / (levels - 1)) : 0
        let top = bounds.midY - (height * levels + rise * (levels - 1)) / 2
        let span = { (leaves: Int) in Double(leaves) * width + Double(leaves - 1) * width * gap }
        let total = span(Int(leafCount))
        var counter = 0
        let lines = layout.paint("parChTrans1D2", index: 0, count: 1)

        func place(_ node: DiagramLayout.Node, from x: Double, level: Int) -> CGRect {
            let range = span(leaves(node))
            let frame = CGRect(x: x + (range - width) / 2, y: top + Double(level) * (height + rise), width: width, height: height)
            let index = counter
            counter += 1
            add("roundRect", adjustments: ["adj": 10_000], frame: frame,
                paint: layout.paint(level == 0 ? "node0" : "node1", index: index, count: 0, node: node),
                text: layout.text(for: node, withChildren: false))
            var childX = x
            var below: [CGRect] = []
            for child in node.children {
                below.append(place(child, from: childX, level: level + 1))
                childX += span(leaves(child)) + width * gap
            }
            if let first = below.first, let last = below.last {
                let bar = frame.maxY + rise / 2
                line(from: CGPoint(x: frame.midX, y: frame.maxY), to: CGPoint(x: frame.midX, y: bar), paint: lines)
                if below.count > 1 {
                    line(from: CGPoint(x: first.midX, y: bar), to: CGPoint(x: last.midX, y: bar), paint: lines)
                }
                for child in below {
                    line(from: CGPoint(x: child.midX, y: bar), to: CGPoint(x: child.midX, y: child.minY), paint: lines)
                }
            }
            return frame
        }
        var x = bounds.midX - total / 2
        for root in roots {
            _ = place(root, from: x, level: 0)
            x += span(leaves(root)) + width * gap
        }
    }

    // MARK: Pyramids, Venns and matrices

    /// A triangle cut into slices, the first point at the top.
    mutating func pyramid(in bounds: CGRect) {
        let nodes = layout.nodes, count = Double(nodes.count)
        let height = min(bounds.height, bounds.width / 1.155)
        let base = height * 1.155
        let slice = height / count
        let top = bounds.midY - height / 2
        for (index, node) in nodes.enumerated() {
            let upper = base * Double(index) / count
            let lower = base * Double(index + 1) / count
            let frame = CGRect(x: bounds.midX - lower / 2, y: top + Double(index) * slice, width: lower, height: slice)
            let paint = layout.paint("node1", index: index, count: nodes.count, node: node)
            let text = layout.text(for: node, withChildren: true)
            let area = CGRect(x: bounds.midX - (upper + lower) / 4, y: frame.minY, width: (upper + lower) / 2, height: slice)
            if index == 0 {
                add("triangle", frame: frame, paint: paint, text: text,
                    textArea: CGRect(x: frame.midX - lower * 0.3, y: frame.minY + slice * 0.4, width: lower * 0.6, height: slice * 0.6))
            } else {
                let inset = (lower - upper) / 2
                add("trapezoid", adjustments: ["adj": Int((inset / min(lower, slice) * 100_000).rounded())], frame: frame,
                    paint: paint, text: text, textArea: area)
            }
        }
    }

    /// Overlapping, see-through circles: round a ring, or in a row.
    mutating func venn(linear: Bool, in bounds: CGRect) {
        let nodes = layout.nodes, count = nodes.count
        if linear {
            let diameter = min(bounds.width / (1 + Double(count - 1) * 0.75), bounds.height)
            let total = diameter * (1 + Double(count - 1) * 0.75)
            for (index, node) in nodes.enumerated() {
                let frame = CGRect(
                    x: bounds.midX - total / 2 + Double(index) * diameter * 0.75, y: bounds.midY - diameter / 2,
                    width: diameter, height: diameter
                )
                add("ellipse", frame: frame, paint: layout.paint("vennNode1", index: index, count: count, node: node),
                    text: layout.text(for: node, withChildren: true),
                    textArea: frame.insetBy(dx: diameter * 0.2, dy: diameter * 0.2))
            }
            return
        }
        let side = min(bounds.width, bounds.height)
        let spread = count < 2 ? 0 : 0.3 / sin(Double.pi / Double(count))
        let diameter = side / (1 + 2 * spread)
        let radius = diameter * spread
        for (index, node) in nodes.enumerated() {
            let angle = count == 2 ? (index == 0 ? -Double.pi / 2 : Double.pi / 2) : 2 * Double.pi * Double(index) / Double(count)
            let middle = CGPoint(x: bounds.midX + radius * sin(angle), y: bounds.midY - radius * cos(angle))
            let frame = CGRect(x: middle.x - diameter / 2, y: middle.y - diameter / 2, width: diameter, height: diameter)
            // Text sits towards the outside, clear of the overlaps.
            let shift = count < 2 ? 0 : diameter * 0.18
            let textCenter = CGPoint(x: middle.x + shift * sin(angle), y: middle.y - shift * cos(angle))
            add("ellipse", frame: frame, paint: layout.paint("vennNode1", index: index, count: count, node: node),
                text: layout.text(for: node, withChildren: true),
                textArea: CGRect(x: textCenter.x - diameter * 0.3, y: textCenter.y - diameter * 0.25, width: diameter * 0.6, height: diameter * 0.5))
        }
    }

    /// Points in a square grid; a lone point with points below it titles them in the middle.
    mutating func matrix(in bounds: CGRect) {
        let titled = layout.nodes.count == 1 && !layout.nodes[0].children.isEmpty
        let items = titled ? layout.nodes[0].children : layout.nodes
        let columns = Int(Double(items.count).squareRoot().rounded(.up))
        let rows = (items.count + columns - 1) / columns
        let side = min(bounds.width, bounds.height)
        let gap = side * 0.03
        let cell = (side - gap * Double(max(columns, rows) - 1)) / Double(max(columns, rows))
        let width = Double(columns) * cell + Double(columns - 1) * gap
        let height = Double(rows) * cell + Double(rows - 1) * gap
        for (index, node) in items.enumerated() {
            let frame = CGRect(
                x: bounds.midX - width / 2 + Double(index % columns) * (cell + gap),
                y: bounds.midY - height / 2 + Double(index / columns) * (cell + gap), width: cell, height: cell
            )
            add("roundRect", adjustments: ["adj": 10_000], frame: frame,
                paint: layout.paint("node1", index: index, count: items.count, node: node),
                text: layout.text(for: node, withChildren: true))
        }
        if titled {
            let hub = layout.nodes[0]
            let size = side * 0.36
            add("roundRect", frame: CGRect(x: bounds.midX - size / 2, y: bounds.midY - size * 0.3, width: size, height: size * 0.6),
                paint: layout.paint("node0", index: 0, count: 1, node: hub), text: layout.text(for: hub, withChildren: false), group: "hub")
        }
    }
}
