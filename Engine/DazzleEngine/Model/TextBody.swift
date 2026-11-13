import Foundation

/// The text inside a shape: how it sits in the shape, and its paragraphs.
public struct TextBody: Equatable, Hashable, Sendable {
    public var properties: BodyProperties
    public var listStyle: ListStyle
    public var paragraphs: [Paragraph]

    public init(properties: BodyProperties = BodyProperties(), listStyle: ListStyle = ListStyle(), paragraphs: [Paragraph]) {
        self.properties = properties
        self.listStyle = listStyle
        self.paragraphs = paragraphs
    }

    /// The text as one string, a line per paragraph — how it is edited.
    public var plainText: String {
        paragraphs.map(\.plainText).joined(separator: "\n")
    }

    public var isEmpty: Bool { paragraphs.allSatisfy { $0.plainText.isEmpty } }

    /// Replaces the text, keeping the formatting of every paragraph whose
    /// text did not change, and lending new paragraphs the formatting of the
    /// paragraph that was in their place.
    public mutating func setPlainText(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        let old = paragraphs
        paragraphs = lines.enumerated().map { index, line in
            if old.indices.contains(index), old[index].plainText == line { return old[index] }
            let template = old.isEmpty ? Paragraph(runs: []) : old[min(index, old.count - 1)]
            return template.replacingText(line)
        }
    }

    /// Applies a change to every run's properties, and to each paragraph's
    /// end-of-paragraph properties so text typed later matches.
    public mutating func updateRuns(_ change: (inout RunProperties) -> Void) {
        for paragraphIndex in paragraphs.indices {
            for runIndex in paragraphs[paragraphIndex].runs.indices {
                change(&paragraphs[paragraphIndex].runs[runIndex].properties)
            }
            var end = paragraphs[paragraphIndex].endProperties ?? RunProperties()
            change(&end)
            paragraphs[paragraphIndex].endProperties = end
        }
    }

    public mutating func updateParagraphs(_ change: (inout ParagraphProperties) -> Void) {
        for index in paragraphs.indices {
            change(&paragraphs[index].properties)
        }
    }
}

/// `a:prstTxWarp`: a WordArt warp, the text laid along the preset's paths.
public struct TextWarp: Equatable, Hashable, Sendable {
    /// The preset's name, such as `textArchUp`; `textNoShape` leaves the text flat.
    public var preset: String
    /// `avLst`'s adjust values, by name.
    public var adjustments: [String: Int]

    public init(preset: String, adjustments: [String: Int] = [:]) {
        self.preset = preset
        self.adjustments = adjustments
    }

    public init?(element: XMLElement?) {
        guard let element, let preset = element.attribute("prst") else { return nil }
        var adjustments: [String: Int] = [:]
        for guide in element.firstChild(named: "avLst")?.children(named: "gd") ?? [] {
            if let name = guide.attribute("name"), let formula = guide.attribute("fmla"), formula.hasPrefix("val "),
               let value = Int(String(formula.dropFirst(4)).trimmed) {
                adjustments[name] = value
            }
        }
        self.init(preset: preset, adjustments: adjustments)
    }

    /// The warp as `a:prstTxWarp`.
    public var xml: String {
        let guides = adjustments.keys.sorted().map { "<a:gd name=\"\(XMLLite.escape($0))\" fmla=\"val \(adjustments[$0] ?? 0)\"/>" }
        return "<a:prstTxWarp prst=\"\(XMLLite.escape(preset))\"><a:avLst>\(guides.joined())</a:avLst></a:prstTxWarp>"
    }
}

/// `a:bodyPr`: insets, anchoring and fitting.
public struct BodyProperties: Equatable, Hashable, Sendable {
    public enum Anchor: String, Sendable {
        case top = "t"
        case center = "ctr"
        case bottom = "b"
    }

    public enum Autofit: Equatable, Hashable, Sendable {
        case none
        /// Shrink text on overflow, by the scale PowerPoint last worked out.
        case normal(fontScale: Double, lineSpacingReduction: Double)
        /// Grow the shape to fit the text.
        case shape

        /// One step PowerPoint takes as it shrinks text that overflows: how
        /// much of its size the text keeps, and how much less its lines are
        /// spaced, as fractions.
        public struct ShrinkStep: Equatable, Hashable, Sendable {
            public var fontScale: Double
            public var lineSpacingReduction: Double

            public init(fontScale: Double, lineSpacingReduction: Double) {
                self.fontScale = fontScale
                self.lineSpacingReduction = lineSpacingReduction
            }

            /// As `normAutofit` says it.
            public var autofit: Autofit { .normal(fontScale: fontScale, lineSpacingReduction: lineSpacingReduction) }
        }

        /// The steps PowerPoint takes, in turn, until text fits: first it
        /// closes up the lines by a tenth and then a fifth, then it shrinks
        /// the letters by 7.5% at a time, at first with lines a tenth closer
        /// and then a fifth, down to 40%, and last to a quarter, the least it
        /// goes to. These are the `fontScale` and `lnSpcReduction` values it
        /// writes (92500, 85000 … 40000, 25000 with 10000 or 20000).
        public static let shrinkSteps: [ShrinkStep] = [
            (1, 0.1), (1, 0.2), (0.925, 0.1), (0.925, 0.2), (0.85, 0.1), (0.85, 0.2),
            (0.775, 0.2), (0.7, 0.2), (0.625, 0.2), (0.55, 0.2), (0.475, 0.2), (0.4, 0.2), (0.25, 0.2),
        ].map { ShrinkStep(fontScale: $0.0, lineSpacingReduction: $0.1) }

        /// The steps still to try when text set this way overflows. Text the
        /// file gave a font scale keeps it, as PowerPoint worked it out; text
        /// whose lines alone were closed up goes on from there; and text the
        /// file says nothing about starts at the first step.
        public var shrinkStepsLeft: [ShrinkStep] {
            guard case .normal(let scale, let reduction) = self, scale >= 1 else { return [] }
            return Self.shrinkSteps.filter { $0.fontScale < 1 || $0.lineSpacingReduction > reduction + 0.0001 }
        }
    }

    public var anchor: Anchor?
    public var leftInset: Int?
    public var topInset: Int?
    public var rightInset: Int?
    public var bottomInset: Int?
    public var wraps: Bool?
    public var autofit: Autofit?
    /// `vert`, when the text runs other than horizontally.
    public var vertical: String?
    /// `numCol`: how many columns the text flows through, one after another.
    public var columnCount: Int?
    /// `spcCol`: the gap between columns, in EMU.
    public var columnSpacing: Int?
    /// `rtlCol`: whether the columns run from right to left.
    public var columnsRightToLeft: Bool?
    /// `prstTxWarp`: the WordArt warp the text is laid along.
    public var warp: TextWarp?

    public init() {
        // Every property unsaid: inherited.
    }

    public init(element: XMLElement?) {
        guard let element else { return }
        anchor = element.attribute("anchor").flatMap(Anchor.init(rawValue:))
        leftInset = element.attribute("lIns").flatMap(Int.init)
        topInset = element.attribute("tIns").flatMap(Int.init)
        rightInset = element.attribute("rIns").flatMap(Int.init)
        bottomInset = element.attribute("bIns").flatMap(Int.init)
        wraps = element.attribute("wrap").map { $0 != "none" }
        vertical = element.attribute("vert").flatMap { $0 == "horz" ? nil : $0 }
        columnCount = element.attribute("numCol").flatMap(Int.init).map { min(max($0, 1), 16) }
        columnSpacing = element.attribute("spcCol").flatMap(Int.init).map { max($0, 0) }
        columnsRightToLeft = element.attribute("rtlCol").map { $0 == "1" || $0 == "true" }
        warp = TextWarp(element: element.firstChild(named: "prstTxWarp"))
        if let normal = element.firstChild(named: "normAutofit") {
            autofit = .normal(
                fontScale: Double(normal.attribute("fontScale").flatMap(Int.init) ?? 100_000) / 100_000,
                lineSpacingReduction: Double(normal.attribute("lnSpcReduction").flatMap(Int.init) ?? 0) / 100_000
            )
        } else if element.firstChild(named: "spAutoFit") != nil {
            autofit = .shape
        } else if element.firstChild(named: "noAutofit") != nil {
            autofit = Autofit.none
        }
    }

    /// Values left unsaid here are taken from `base`.
    public func merged(over base: BodyProperties) -> BodyProperties {
        var result = self
        result.anchor = anchor ?? base.anchor
        result.leftInset = leftInset ?? base.leftInset
        result.topInset = topInset ?? base.topInset
        result.rightInset = rightInset ?? base.rightInset
        result.bottomInset = bottomInset ?? base.bottomInset
        result.wraps = wraps ?? base.wraps
        result.autofit = autofit ?? base.autofit
        result.vertical = vertical ?? base.vertical
        result.columnCount = columnCount ?? base.columnCount
        result.columnSpacing = columnSpacing ?? base.columnSpacing
        result.columnsRightToLeft = columnsRightToLeft ?? base.columnsRightToLeft
        result.warp = warp ?? base.warp
        return result
    }

    /// The kinds of vertical text, by their name in the file.
    public static let verticalKinds: Set = ["vert", "eaVert", "vert270", "wordArtVert", "wordArtVertRtl", "mongolianVert"]

    /// Whether the text runs down the box, its lines stacked across it.
    public var runsVertically: Bool { vertical.map(Self.verticalKinds.contains) ?? false }

    /// Whether vertical lines start at the box's right and follow each other
    /// leftwards, as Japanese and Chinese do; Mongolian and stacked text, and
    /// text turned anticlockwise, start at its left.
    public var linesStartAtRight: Bool { ["vert", "eaVert", "wordArtVertRtl"].contains(vertical ?? "") }
}

/// A paragraph of runs.
public struct Paragraph: Equatable, Hashable, Sendable {
    public var properties: ParagraphProperties
    public var runs: [TextRun]
    /// `a:endParaRPr`: what an empty paragraph, or text typed at its end, looks like.
    public var endProperties: RunProperties?
    /// The paragraph's `a:pPr` as the file wrote it, so what Dazzle does not
    /// model survives being written back.
    public var sourceProperties: String?
    public var sourceEndProperties: String?

    public init(
        properties: ParagraphProperties = ParagraphProperties(), runs: [TextRun],
        endProperties: RunProperties? = nil
    ) {
        self.properties = properties
        self.runs = runs
        self.endProperties = endProperties
    }

    public var plainText: String { runs.map(\.text).joined() }

    /// This paragraph's formatting holding different text, in the formatting
    /// of its first run.
    public func replacingText(_ text: String) -> Paragraph {
        var paragraph = self
        let first = runs.first { $0.kind == .text }
        var run = first ?? TextRun(text: "", properties: endProperties ?? RunProperties())
        run.kind = .text
        run.text = text
        if first == nil { run.sourceProperties = sourceEndProperties }
        paragraph.runs = text.isEmpty ? [] : [run]
        if paragraph.endProperties == nil { paragraph.endProperties = run.properties }
        return paragraph
    }
}

/// A run of text sharing one set of properties.
public struct TextRun: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case text
        /// `a:br`: a line break within the paragraph.
        case lineBreak
        /// `a:fld`: text PowerPoint fills in, such as the slide number.
        case field(type: String)
    }

    public var kind: Kind = .text
    public var text: String
    public var properties: RunProperties
    /// The run's `a:rPr` as the file wrote it.
    public var sourceProperties: String?
    /// A field's `id`, which PowerPoint wants kept.
    public var fieldID: String?

    public init(kind: Kind = .text, text: String, properties: RunProperties = RunProperties()) {
        self.kind = kind
        self.text = text
        self.properties = properties
    }
}

/// A tab stop, as `a:tab` gives it.
public struct TabStop: Equatable, Hashable, Sendable {
    public enum Alignment: String, CaseIterable, Sendable {
        case left = "l"
        case center = "ctr"
        case right = "r"
        /// The text's decimal point lines up on the stop.
        case decimal = "dec"
    }

    /// EMU, from the left of the text, insets taken off.
    public var position: Int
    public var alignment: Alignment

    public init(position: Int, alignment: Alignment = .left) {
        self.position = position
        self.alignment = alignment
    }

    /// The stops an `a:tabLst` lists, in order along the line; none when it lists none.
    public static func list(in element: XMLElement?) -> [TabStop]? {
        guard let element else { return nil }
        let stops = element.children.filter { $0.name == "tab" }.compactMap { tab -> TabStop? in
            guard let position = tab.attribute("pos").flatMap(Int.init), position >= 0 else { return nil }
            return TabStop(position: position, alignment: tab.attribute("algn").flatMap(Alignment.init(rawValue:)) ?? .left)
        }
        return stops.isEmpty ? nil : stops.sorted { $0.position < $1.position }
    }

    /// The stops as an `a:tabLst`.
    public static func xml(_ stops: [TabStop]) -> String {
        "<a:tabLst>" + stops.map { "<a:tab pos=\"\($0.position)\" algn=\"\($0.alignment.rawValue)\"/>" }.joined() + "</a:tabLst>"
    }
}

public enum ParagraphAlignment: String, CaseIterable, Sendable {
    case left = "l"
    case center = "ctr"
    case right = "r"
    case justified = "just"

    public init?(attribute: String?) {
        guard let attribute else { return nil }
        switch attribute {
        case "dist", "justLow", "thaiDist": self = .justified
        default: self.init(rawValue: attribute)
        }
    }

    public var symbolName: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
        }
    }
}

/// A paragraph's bullet.
public enum Bullet: Equatable, Hashable, Sendable {
    case none
    case character(String)
    case autoNumber(scheme: String, startAt: Int)
}

/// Line or paragraph spacing.
public enum Spacing: Equatable, Hashable, Sendable {
    /// A multiple of single spacing, 1 being single.
    case percent(Double)
    case points(Double)

    public init?(element: XMLElement?) {
        guard let element else { return nil }
        if let percent = element.firstChild(named: "spcPct")?.attribute("val").flatMap(Int.init) {
            self = .percent(Double(percent) / 100_000)
        } else if let points = element.firstChild(named: "spcPts")?.attribute("val").flatMap(Int.init) {
            self = .points(Double(points) / 100)
        } else {
            return nil
        }
    }
}

/// Paragraph properties, as `a:pPr` or a list style level gives them. Every
/// property is optional, because unsaid means inherited.
public struct ParagraphProperties: Equatable, Hashable, Sendable {
    public var level: Int?
    public var alignment: ParagraphAlignment?
    /// EMU.
    public var marginLeft: Int?
    /// EMU; negative for a hanging indent.
    public var indent: Int?
    public var bullet: Bullet?
    public var bulletColor: DrawingColor?
    /// A fraction of the text size.
    public var bulletSize: Double?
    public var bulletFont: String?
    public var lineSpacing: Spacing?
    public var spaceBefore: Spacing?
    public var spaceAfter: Spacing?
    /// Where tabs stop before the default ones take over.
    public var tabStops: [TabStop]?
    /// EMU between the default tab stops.
    public var defaultTabSize: Int?
    /// `rtl`: whether the paragraph reads from right to left, its margin,
    /// indent, bullet and tab stops measured from the right.
    public var isRightToLeft: Bool?
    public var defaultRun = RunProperties()

    public init() {
        // Every property unsaid: inherited.
    }

    public init(element: XMLElement?) {
        guard let element else { return }
        level = element.attribute("lvl").flatMap(Int.init)
        alignment = ParagraphAlignment(attribute: element.attribute("algn"))
        marginLeft = element.attribute("marL").flatMap(Int.init)
        indent = element.attribute("indent").flatMap(Int.init)
        lineSpacing = Spacing(element: element.firstChild(named: "lnSpc"))
        spaceBefore = Spacing(element: element.firstChild(named: "spcBef"))
        spaceAfter = Spacing(element: element.firstChild(named: "spcAft"))
        tabStops = TabStop.list(in: element.firstChild(named: "tabLst"))
        defaultTabSize = element.attribute("defTabSz").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        isRightToLeft = element.attribute("rtl").map { $0 == "1" || $0 == "true" }
        if element.firstChild(named: "buNone") != nil {
            bullet = Bullet.none
        } else if let character = element.firstChild(named: "buChar")?.attribute("char") {
            bullet = .character(character)
        } else if let number = element.firstChild(named: "buAutoNum") {
            bullet = .autoNumber(
                scheme: number.attribute("type") ?? "arabicPeriod",
                startAt: number.attribute("startAt").flatMap(Int.init) ?? 1
            )
        }
        bulletColor = DrawingColor.first(in: element.firstChild(named: "buClr"))
        bulletSize = element.firstChild(named: "buSzPct")?.attribute("val").flatMap(Int.init).map { Double($0) / 100_000 }
        bulletFont = element.firstChild(named: "buFont")?.attribute("typeface")
        defaultRun = RunProperties(element: element.firstChild(named: "defRPr"))
    }

    /// Where the paragraph sits across its box: where it says, which is left
    /// or right whichever way it reads, or at the side it reads from.
    public var effectiveAlignment: ParagraphAlignment {
        alignment ?? (isRightToLeft == true ? .right : .left)
    }

    /// Values left unsaid here are taken from `base`.
    public func merged(over base: ParagraphProperties) -> ParagraphProperties {
        var result = self
        result.level = level ?? base.level
        result.alignment = alignment ?? base.alignment
        result.marginLeft = marginLeft ?? base.marginLeft
        result.indent = indent ?? base.indent
        result.bullet = bullet ?? base.bullet
        result.bulletColor = bulletColor ?? base.bulletColor
        result.bulletSize = bulletSize ?? base.bulletSize
        result.bulletFont = bulletFont ?? base.bulletFont
        result.lineSpacing = lineSpacing ?? base.lineSpacing
        result.spaceBefore = spaceBefore ?? base.spaceBefore
        result.spaceAfter = spaceAfter ?? base.spaceAfter
        result.tabStops = tabStops ?? base.tabStops
        result.defaultTabSize = defaultTabSize ?? base.defaultTabSize
        result.isRightToLeft = isRightToLeft ?? base.isRightToLeft
        result.defaultRun = defaultRun.merged(over: base.defaultRun)
        return result
    }
}

/// Character properties, as `a:rPr` and its relatives give them.
public struct RunProperties: Equatable, Hashable, Sendable {
    /// Hundredths of a point.
    public var size: Int?
    public var isBold: Bool?
    public var isItalic: Bool?
    /// `u`: how the text is underlined, `none` taking away an inherited one.
    public var underline: UnderlineStyle?
    /// `strike`: how the text is struck through, `none` taking away an inherited one.
    public var strike: StrikeStyle?
    /// `a:uFill`, or failing that `a:uLn`'s fill: the underline's own colour, where it isn't the text's.
    public var underlineColor: DrawingColor?
    public var color: DrawingColor?
    /// A typeface name, or a theme font such as `+mn-lt`.
    public var latinFont: String?
    public var eastAsianFont: String?
    /// `a:cs`: the typeface Arabic, Hebrew and other complex scripts are set in.
    public var complexScriptFont: String?
    /// Thousandths of a percent; positive for superscript.
    public var baseline: Int?
    /// Extra space between letters, in hundredths of a point; negative condenses.
    public var spacing: Int?
    /// `all` or `small` capitals.
    public var capitalization: String?
    /// A line drawn around each letter.
    public var outline: TextOutline?
    /// A shadow each letter casts.
    public var shadow: TextShadow?
    /// Where clicking the text goes. Never inherited.
    public var link: Hyperlink?

    public init() {
        // Every property unsaid: inherited.
    }

    /// Whether the text is underlined. Turning it on keeps the style the text
    /// already has, or underlines it with a single line.
    public var isUnderlined: Bool? {
        get { underline.map { $0 != .none } }
        set { underline = newValue.map { $0 ? (underline.flatMap { $0 == .none ? nil : $0 } ?? .single) : UnderlineStyle.none } }
    }

    /// Whether the text is struck through. Turning it on keeps the style the
    /// text already has, or strikes it with a single line.
    public var isStruckThrough: Bool? {
        get { strike.map { $0 != .none } }
        set { strike = newValue.map { $0 ? (strike.flatMap { $0 == .none ? nil : $0 } ?? .single) : StrikeStyle.none } }
    }

    public init(element: XMLElement?) {
        guard let element else { return }
        func flag(_ key: String) -> Bool? {
            element.attribute(key).map { $0 == "1" || $0 == "true" }
        }
        size = element.attribute("sz").flatMap(Int.init)
        isBold = flag("b")
        isItalic = flag("i")
        // A style Dazzle doesn't know is still a line under the text.
        underline = element.attribute("u").map { UnderlineStyle(rawValue: $0) ?? .single }
        strike = element.attribute("strike").map { StrikeStyle(rawValue: $0) ?? .single }
        if let fill = element.firstChild(named: "uFill")?.firstChild(named: "solidFill") {
            underlineColor = DrawingColor.first(in: fill)
        } else if let fill = element.firstChild(named: "uLn")?.firstChild(named: "solidFill") {
            underlineColor = DrawingColor.first(in: fill)
        }
        baseline = element.attribute("baseline").flatMap(Int.init)
        spacing = element.attribute("spc").flatMap(Int.init)
        capitalization = element.attribute("cap").flatMap { $0 == "none" ? nil : $0 }
        if let fill = element.firstChild(named: "solidFill") {
            color = DrawingColor.first(in: fill)
        } else if let gradient = element.firstChild(named: "gradFill") {
            // Gradient text is drawn in its first colour.
            color = DrawingColor.first(in: gradient.firstChild(named: "gsLst")?.firstChild(named: "gs"))
        }
        latinFont = element.firstChild(named: "latin")?.attribute("typeface")
        eastAsianFont = element.firstChild(named: "ea")?.attribute("typeface")
        complexScriptFont = element.firstChild(named: "cs")?.attribute("typeface")
        outline = element.firstChild(named: "ln").flatMap(TextOutline.init(element:))
        shadow = element.firstChild(named: "effectLst").map {
            Shadow(element: $0.firstChild(named: "outerShdw")).map(TextShadow.shadow) ?? TextShadow.none
        }
    }

    /// Values left unsaid here are taken from `base`.
    public func merged(over base: RunProperties) -> RunProperties {
        var result = self
        result.size = size ?? base.size
        result.isBold = isBold ?? base.isBold
        result.isItalic = isItalic ?? base.isItalic
        result.underline = underline ?? base.underline
        result.strike = strike ?? base.strike
        result.underlineColor = underlineColor ?? base.underlineColor
        result.color = color ?? base.color
        result.latinFont = latinFont ?? base.latinFont
        result.eastAsianFont = eastAsianFont ?? base.eastAsianFont
        result.complexScriptFont = complexScriptFont ?? base.complexScriptFont
        result.baseline = baseline ?? base.baseline
        result.spacing = spacing ?? base.spacing
        result.capitalization = capitalization ?? base.capitalization
        result.outline = outline ?? base.outline
        result.shadow = shadow ?? base.shadow
        return result
    }
}

/// `u` in run properties: the line drawn under the text.
public enum UnderlineStyle: String, CaseIterable, Hashable, Sendable {
    case none
    /// A single line under the words, leaving the spaces between them bare.
    case words
    case single = "sng"
    case double = "dbl"
    case heavy
    case dotted
    case dottedHeavy
    case dash
    case dashHeavy
    case dashLong
    case dashLongHeavy
    case dotDash
    case dotDashHeavy
    case dotDotDash
    case dotDotDashHeavy
    case wavy
    case wavyHeavy
    case wavyDouble = "wavyDbl"

    /// Drawn twice as thick as the font's own underline.
    public var isHeavy: Bool {
        switch self {
        case .heavy, .dottedHeavy, .dashHeavy, .dashLongHeavy, .dotDashHeavy, .dotDotDashHeavy, .wavyHeavy: true
        default: false
        }
    }

    public var isDouble: Bool { self == .double || self == .wavyDouble }

    public var isWavy: Bool { self == .wavy || self == .wavyHeavy || self == .wavyDouble }

    /// Dashes and gaps along the line, in multiples of its thickness; empty for a solid line.
    public var dashPattern: [Double] {
        switch self {
        case .dotted, .dottedHeavy: [1, 1]
        case .dash, .dashHeavy: [4, 2]
        case .dashLong, .dashLongHeavy: [8, 3]
        case .dotDash, .dotDashHeavy: [4, 2, 1, 2]
        case .dotDotDash, .dotDotDashHeavy: [4, 2, 1, 2, 1, 2]
        default: []
        }
    }
}

/// `strike` in run properties: the line drawn through the text.
public enum StrikeStyle: String, CaseIterable, Hashable, Sendable {
    case none = "noStrike"
    case single = "sngStrike"
    case double = "dblStrike"
}

/// `a:ln` in run properties: a line around each letter, or none, which
/// takes away one the text would inherit.
public enum TextOutline: Equatable, Hashable, Sendable {
    case none
    /// Width in EMU, centred on the letter's edge.
    case line(width: Int, color: DrawingColor)

    /// Nil when the line says nothing of its fill, leaving the inherited one.
    public init?(element: XMLElement) {
        let color: DrawingColor?
        if element.firstChild(named: "noFill") != nil {
            self = .none
            return
        } else if let fill = element.firstChild(named: "solidFill") {
            color = DrawingColor.first(in: fill)
        } else if let gradient = element.firstChild(named: "gradFill") {
            // A gradient outline is drawn in its first colour.
            color = DrawingColor.first(in: gradient.firstChild(named: "gsLst")?.firstChild(named: "gs"))
        } else if let pattern = element.firstChild(named: "pattFill") {
            // A patterned outline is drawn in its foreground colour.
            color = DrawingColor.first(in: pattern.firstChild(named: "fgClr"))
        } else {
            return nil
        }
        guard let color else { return nil }
        // PowerPoint outlines text three quarters of a point wide unless told otherwise.
        self = .line(width: element.attribute("w").flatMap(Int.init) ?? 9_525, color: color)
    }

    public var xml: String {
        switch self {
        case .none: "<a:ln><a:noFill/></a:ln>"
        case .line(let width, let color): "<a:ln w=\"\(width)\"><a:solidFill>\(color.xml)</a:solidFill></a:ln>"
        }
    }
}

/// `a:effectLst` in run properties: a shadow, or none, which takes away
/// one the text would inherit.
public enum TextShadow: Equatable, Hashable, Sendable {
    case none
    case shadow(Shadow)

    public var xml: String {
        switch self {
        case .none: "<a:effectLst/>"
        case .shadow(let shadow): "<a:effectLst>\(shadow.xml)</a:effectLst>"
        }
    }
}

/// `a:lstStyle` and the master's text styles: paragraph properties per
/// outline level, 1 through 9.
public struct ListStyle: Equatable, Hashable, Sendable {
    public var levels: [Int: ParagraphProperties] = [:]

    public init() {
        // No levels: everything inherited.
    }

    public init(element: XMLElement?) {
        guard let element else { return }
        for level in 1...9 {
            if let properties = element.firstChild(named: "lvl\(level)pPr") {
                levels[level] = ParagraphProperties(element: properties)
            }
        }
        // `defPPr` applies beneath every level.
        if let defaults = element.firstChild(named: "defPPr") {
            let base = ParagraphProperties(element: defaults)
            for level in 1...9 {
                levels[level] = (levels[level] ?? ParagraphProperties()).merged(over: base)
            }
        }
    }

    /// The properties at a zero-based outline level.
    public func level(_ index: Int) -> ParagraphProperties {
        levels[min(max(index, 0), 8) + 1] ?? ParagraphProperties()
    }

    /// Changes the properties at a zero-based outline level.
    public mutating func updateLevel(_ index: Int, _ change: (inout ParagraphProperties) -> Void) {
        var properties = level(index)
        change(&properties)
        // A level is its place in the list, never something it says.
        properties.level = nil
        levels[min(max(index, 0), 8) + 1] = properties
    }

    /// Each level's values left unsaid here are taken from `base`.
    public func merged(over base: ListStyle) -> ListStyle {
        var result = ListStyle()
        for level in Set(levels.keys).union(base.levels.keys) {
            result.levels[level] = (levels[level] ?? ParagraphProperties())
                .merged(over: base.levels[level] ?? ParagraphProperties())
        }
        return result
    }
}
