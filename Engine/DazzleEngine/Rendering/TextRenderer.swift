#if canImport(CoreText)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif
import Foundation

/// Lays out and draws a shape's text with CoreText.
public struct TextRenderer {
    public let style: SlideStyleContext
    public let slideNumber: Int

    /// The kinds of vertical text, by their name in the file, all laid out
    /// across the shape and turned a quarter.
    static let verticalKinds: Set = ["vert", "eaVert", "vert270", "wordArtVert", "wordArtVertRtl", "mongolianVert"]
    /// Those set in vertical lines (縦書き and stacked), where Japanese and
    /// Chinese stand upright, rather than turned letters and all.
    static let uprightKinds: Set = ["eaVert", "wordArtVert", "wordArtVertRtl"]

    /// Text laid out in a shape: a frame CoreText made for each column the
    /// text reaches, and where each sits.
    private struct Layout {
        struct Column {
            var frame: CTFrame
            /// The frame's top-left corner, in slide points, in the turned
            /// space when the text runs vertically.
            var origin: CGPoint
            var height: CGFloat
        }

        var columns: [Column]
        /// For vertical text: the point turned about, and by how much.
        var turn: (center: CGPoint, angle: CGFloat)?
    }

    /// How text is set in columns: how many, how wide, and how far apart.
    private struct ColumnSet {
        var count: Int
        var width: CGFloat
        var gap: CGFloat

        init(_ properties: BodyProperties, width: CGFloat) {
            let wraps = properties.wraps ?? true
            count = wraps ? max(properties.columnCount ?? 1, 1) : 1
            gap = count > 1 ? CGFloat(EMU.points(properties.columnSpacing ?? 0)) : 0
            self.width = max((width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
        }
    }

    /// The stretch of text each column holds when columns are `height` tall:
    /// every column but the last takes what fits, and the last the rest.
    private func columnRanges(_ framesetter: CTFramesetter, length: Int, columns: ColumnSet, height: CGFloat) -> [CFRange] {
        var ranges: [CFRange] = []
        var start = 0
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: columns.width, height: max(height, 1)), transform: nil)
        for _ in 0..<(columns.count - 1) where start < length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame).length
            guard visible > 0 else { break }
            ranges.append(CFRange(location: start, length: visible))
            start += visible
        }
        if start < length || ranges.isEmpty {
            ranges.append(CFRange(location: start, length: length - start))
        }
        return ranges
    }

    private func suggestedHeight(_ framesetter: CTFramesetter, range: CFRange, width: CGFloat) -> CGFloat {
        CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, range, nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil
        ).height
    }

    /// How tall the text in the last column stands when columns are `height`
    /// tall: no taller than `height` when everything fits.
    private func lastColumnHeight(_ framesetter: CTFramesetter, length: Int, columns: ColumnSet, height: CGFloat) -> CGFloat {
        let ranges = columnRanges(framesetter, length: length, columns: columns, height: height)
        return ranges.last.map { suggestedHeight(framesetter, range: $0, width: columns.width) } ?? 0
    }

    /// The least height columns can have and still hold all the text, the
    /// text balanced across them.
    private func balancedHeight(_ framesetter: CTFramesetter, length: Int, columns: ColumnSet) -> CGFloat {
        let whole = suggestedHeight(framesetter, range: CFRange(location: 0, length: length), width: columns.width)
        guard columns.count > 1, whole > 0 else { return whole }
        var low = whole / CGFloat(columns.count)
        var high = whole
        if lastColumnHeight(framesetter, length: length, columns: columns, height: low) <= low + 1 { return low }
        while high - low > 0.5 {
            let middle = (low + high) / 2
            if lastColumnHeight(framesetter, length: length, columns: columns, height: middle) <= middle + 1 {
                high = middle
            } else {
                low = middle
            }
        }
        return high
    }

    private func layout(
        _ body: TextBody, shape: SlideShape, sources: [SlideShape], in rect: CGRect,
        colorOverride: RGBAColor?, hidesText: Bool, paragraphOpacity: [Int: Double] = [:],
        colorChanges: [AnimationColorChange.Value] = [], paragraphColorChanges: [Int: [AnimationColorChange.Value]] = [:]
    ) -> Layout? {
        let properties = style.bodyProperties(for: shape, sources: sources)
            .merged(over: body.properties)
        var inner = CGRect(
            x: rect.minX + EMU.points(properties.leftInset ?? 91_440),
            y: rect.minY + EMU.points(properties.topInset ?? 45_720),
            width: rect.width - EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440)),
            height: rect.height - EMU.points((properties.topInset ?? 45_720) + (properties.bottomInset ?? 45_720))
        )
        guard inner.width > 0 || properties.wraps == false else { return nil }

        // Vertical text is laid out across the shape's height, then turned.
        var turn: (center: CGPoint, angle: CGFloat)?
        if let vertical = properties.vertical, Self.verticalKinds.contains(vertical) {
            turn = (CGPoint(x: inner.midX, y: inner.midY), vertical == "vert270" ? -.pi / 2 : .pi / 2)
            inner = CGRect(x: -inner.height / 2, y: -inner.width / 2, width: inner.height, height: inner.width)
        }
        // Set in vertical lines rather than turned, Japanese and Chinese take
        // their vertical forms, which CoreText draws upright in the turned line.
        let upright = properties.vertical.map(Self.uprightKinds.contains) ?? false
        func shaped(_ string: NSAttributedString) -> NSAttributedString {
            guard upright else { return string }
            let shaped = NSMutableAttributedString(attributedString: string)
            shaped.addAttribute(NSAttributedString.Key(kCTVerticalFormsAttributeName as String), value: true, range: NSRange(location: 0, length: shaped.length))
            return shaped
        }

        var fontScale = 1.0
        var spacingReduction = 0.0
        if case .normal(let scale, let reduction) = properties.autofit {
            fontScale = scale
            spacingReduction = reduction
        }
        let wraps = properties.wraps ?? true
        let layoutWidth = wraps ? max(inner.width, 1) : 100_000

        var string = shaped(attributedString(
            body, shape: shape, sources: sources, scale: fontScale, spacingReduction: spacingReduction,
            colorOverride: colorOverride, hidesText: hidesText, paragraphOpacity: paragraphOpacity,
            colorChanges: colorChanges, paragraphColorChanges: paragraphColorChanges
        ))
        let columns = ColumnSet(properties, width: inner.width)
        var framesetter = CTFramesetterCreateWithAttributedString(string)
        var size = suggestedSize(framesetter, string: string, width: layoutWidth)
        // Text in columns overflows only when the last column runs past the bottom.
        func overflows() -> Bool {
            let needed = columns.count > 1
                ? lastColumnHeight(framesetter, length: string.length, columns: columns, height: inner.height)
                : size.height
            return needed > inner.height + 1
        }

        // Shrink on overflow, as PowerPoint would have when it last saved.
        if case .normal = properties.autofit, fontScale == 1, overflows() {
            for scale in stride(from: 0.9, through: 0.3, by: -0.1) {
                string = shaped(attributedString(
                    body, shape: shape, sources: sources, scale: scale, spacingReduction: 0.1, colorOverride: colorOverride,
                    hidesText: hidesText, paragraphOpacity: paragraphOpacity,
                    colorChanges: colorChanges, paragraphColorChanges: paragraphColorChanges
                ))
                framesetter = CTFramesetterCreateWithAttributedString(string)
                size = suggestedSize(framesetter, string: string, width: layoutWidth)
                if !overflows() { break }
            }
        }

        if columns.count > 1 {
            // Text fills each column to the bottom before the next; the last
            // column takes what is left, running on past the bottom if it must.
            let ranges = columnRanges(framesetter, length: string.length, columns: columns, height: inner.height)
            let heights = ranges.map { ceil(suggestedHeight(framesetter, range: $0, width: columns.width)) + 1 }
            let blockHeight = heights.max() ?? 0
            let offset: CGFloat = switch properties.anchor ?? .top {
            case .top: 0
            case .center: (inner.height - blockHeight) / 2
            case .bottom: inner.height - blockHeight
            }
            let step = columns.width + columns.gap
            let rightToLeft = properties.columnsRightToLeft ?? false
            let laidOut = zip(ranges, heights).enumerated().map { index, column in
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: columns.width, height: column.1), transform: nil)
                let x = rightToLeft
                    ? inner.maxX - columns.width - CGFloat(index) * step
                    : inner.minX + CGFloat(index) * step
                return Layout.Column(
                    frame: CTFramesetterCreateFrame(framesetter, column.0, path, nil),
                    origin: CGPoint(x: x, y: inner.minY + offset), height: column.1
                )
            }
            return Layout(columns: laidOut, turn: turn)
        }

        var originX = inner.minX
        var frameWidth = layoutWidth
        if !wraps {
            frameWidth = max(ceil(size.width + trailingWhitespace(framesetter)) + 1, inner.width)
            switch body.paragraphs.first?.properties.alignment ?? .left {
            case .center: originX = inner.midX - frameWidth / 2
            case .right: originX = inner.maxX - frameWidth
            default: break
            }
        }
        let frameHeight = ceil(size.height) + 1
        let offset: CGFloat = switch properties.anchor ?? .top {
        case .top: 0
        case .center: (inner.height - frameHeight) / 2
        case .bottom: inner.height - frameHeight
        }

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        return Layout(
            columns: [Layout.Column(frame: frame, origin: CGPoint(x: originX, y: inner.minY + offset), height: frameHeight)],
            turn: turn
        )
    }

    /// Draws `body` into `rect`, in a context whose y axis points down.
    /// `colorOverride` replaces every colour, for placeholder prompts.
    /// `hidesText` lays the text out but draws only its bullets.
    /// `paragraphAppearances` moves, scales, rotates, and fades built paragraphs.
    public func draw(
        _ body: TextBody, shape: SlideShape, sources: [SlideShape], in rect: CGRect, context: CGContext,
        colorOverride: RGBAColor? = nil, hidesText: Bool = false, paragraphOpacity: [Int: Double] = [:],
        paragraphAppearances: [Int: AnimatedAppearance] = [:], colorChanges: [AnimationColorChange.Value] = []
    ) {
        guard let layout = layout(
            body, shape: shape, sources: sources, in: rect, colorOverride: colorOverride, hidesText: hidesText,
            paragraphOpacity: paragraphOpacity, colorChanges: colorChanges,
            paragraphColorChanges: paragraphAppearances.mapValues { $0.colors[.text] ?? [] }
        ) else {
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        if let turn = layout.turn {
            context.translateBy(x: turn.center.x, y: turn.center.y)
            context.rotate(by: turn.angle)
        }
        if !paragraphAppearances.isEmpty {
            drawParagraphs(layout, appearances: paragraphAppearances, context: context)
            return
        }
        let space = context.ctm
        // Every shadow goes down before any letter, so none falls across another run's letters.
        func inColumns(_ draw: (Layout.Column) -> Void) {
            for column in layout.columns {
                context.saveGState()
                context.translateBy(x: column.origin.x, y: column.origin.y + column.height)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                draw(column)
                context.restoreGState()
            }
        }
        inColumns { column in
            let lines = CTFrameGetLines(column.frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(column.frame, CFRange(location: 0, length: 0), &origins)
            for (line, origin) in zip(lines, origins) {
                drawShadows(of: line, at: origin, space: space, context: context)
            }
        }
        inColumns { column in
            CTFrameDraw(column.frame, context)
            drawStrikethroughs(in: column.frame, context: context)
        }
    }

    /// Every line laid out, column by column, with its origin within its frame.
    private func lines(of layout: Layout) -> [(line: CTLine, origin: CGPoint, column: Layout.Column)] {
        layout.columns.flatMap { column in
            let lines = CTFrameGetLines(column.frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(column.frame, CFRange(location: 0, length: 0), &origins)
            return zip(lines, origins).map { ($0, $1, column) }
        }
    }

    /// Draws only the shadows a line's letters cast from `origin`. `space` is
    /// the slide's coordinates, which shadows fall in.
    private func drawShadows(of line: CTLine, at origin: CGPoint, space: CGAffineTransform, context: CGContext) {
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let box = attributes[Self.shadowKey.rawValue] as? ShadowBox else { continue }
            context.saveGState()
            // The letters are drawn far off to one side, and their shadow brought back by as much.
            let away = CGSize(width: 100_000, height: 0)
            let ctm = context.ctm
            let displacement = away.applying(CGAffineTransform(a: ctm.a, b: ctm.b, c: ctm.c, d: ctm.d, tx: 0, ty: 0))
            // Fading text fades its shadow with it.
            let textAlpha = attributes[Self.colorKey.rawValue].map { ($0 as! CGColor).alpha } ?? 1 // swiftlint:disable:this force_cast
            let color = box.color.copy(alpha: box.color.alpha * textAlpha) ?? box.color
            SlideRenderer.setShadow(box.shadow, color: color, space: space, context: context, displacement: displacement)
            context.translateBy(x: away.width, y: away.height)
            context.textPosition = origin
            CTRunDraw(run, context, CFRange(location: 0, length: 0))
            context.restoreGState()
        }
    }

    /// Draw whole paragraphs in their unchanged CoreText layout. Wrapped lines,
    /// bullets, links, and decorations move together around the paragraph bounds.
    private func drawParagraphs(_ layout: Layout, appearances: [Int: AnimatedAppearance], context: CGContext) {
        var paragraphs: [Int: [(line: CTLine, baseline: CGPoint, bounds: CGRect)]] = [:]
        for (line, origin, column) in lines(of: layout) {
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            let index = runs.first.flatMap { (CTRunGetAttributes($0) as NSDictionary)[Self.paragraphIndexKey.rawValue] as? Int } ?? 0
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let baseline = CGPoint(x: column.origin.x + origin.x, y: column.origin.y + column.height - origin.y)
            let bounds = CGRect(x: baseline.x, y: baseline.y - ascent, width: width, height: ascent + descent)
            paragraphs[index, default: []].append((line, baseline, bounds))
        }
        // Every paragraph's shadows go down before any paragraph's letters, so
        // none falls across another's, each moved and faded as its paragraph is.
        func each(_ draw: (_ paragraph: [(line: CTLine, baseline: CGPoint, bounds: CGRect)]) -> Void) {
            for index in paragraphs.keys.sorted() {
                guard let paragraph = paragraphs[index] else { continue }
                let appearance = appearances[index] ?? AnimatedAppearance()
                guard appearance.opacity > 0.001, appearance.axisScale.width != 0, appearance.axisScale.height != 0 else { continue }
                let bounds = paragraph.reduce(CGRect.null) { $0.union($1.bounds) }
                context.saveGState()
                let faded = SlideRenderer.apply(appearance, to: bounds, context: context)
                draw(paragraph)
                if faded { context.endTransparencyLayer() }
                context.restoreGState()
            }
        }
        each { paragraph in
            let space = context.ctm
            for entry in paragraph {
                context.saveGState()
                context.translateBy(x: entry.baseline.x, y: entry.baseline.y)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                drawShadows(of: entry.line, at: .zero, space: space, context: context)
                context.restoreGState()
            }
        }
        each { paragraph in
            for entry in paragraph {
                context.saveGState()
                context.translateBy(x: entry.baseline.x, y: entry.baseline.y)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(entry.line, context)
                drawStrikethroughs(in: entry.line, origin: .zero, context: context)
                context.restoreGState()
            }
        }
    }

    /// Where each linked run of `body` lies, in slide points, and where it
    /// goes. Text running vertically has none.
    public func linkAreas(_ body: TextBody, shape: SlideShape, sources: [SlideShape], in rect: CGRect) -> [(CGRect, Hyperlink)] {
        guard let layout = layout(body, shape: shape, sources: sources, in: rect, colorOverride: nil, hidesText: false),
              layout.turn == nil else { return [] }
        var areas: [(CGRect, Hyperlink)] = []
        for (line, origin, column) in lines(of: layout) {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let box = attributes[Self.linkKey.rawValue] as? LinkBox else { continue }
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
                let start = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
                areas.append((CGRect(
                    x: column.origin.x + origin.x + start, y: column.origin.y + column.height - origin.y - ascent,
                    width: width, height: ascent + descent
                ), box.link))
            }
        }
        return areas
    }

    /// Where a shape's text is laid out, in slide points: the shape's text
    /// rectangle with the insets taken off, and the body properties in force.
    public func textArea(of shape: SlideShape, sources: [SlideShape]) -> (rect: CGRect, properties: BodyProperties) {
        let frame = shape.frame.points
        let textFrame = shape.textFrame?.points ?? shape.geometry.presetName.map {
            PresetGeometry.textRect($0, adjustments: shape.geometry.adjustments, in: frame)
        } ?? frame
        let properties = style.bodyProperties(for: shape, sources: sources)
        let rect = CGRect(
            x: textFrame.minX + EMU.points(properties.leftInset ?? 91_440),
            y: textFrame.minY + EMU.points(properties.topInset ?? 45_720),
            width: textFrame.width - EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440)),
            height: textFrame.height - EMU.points((properties.topInset ?? 45_720) + (properties.bottomInset ?? 45_720))
        )
        return (rect, properties)
    }

    /// How tall `body` lays out at `width`, insets included.
    public func height(of body: TextBody, shape: SlideShape, width: CGFloat) -> CGFloat {
        let properties = style.bodyProperties(for: shape, sources: []).merged(over: body.properties)
        let horizontal = EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440))
        let vertical = EMU.points((properties.topInset ?? 45_720) + (properties.bottomInset ?? 45_720))
        let string = attributedString(body, shape: shape, sources: [], scale: 1, spacingReduction: 0, colorOverride: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        // Text in columns is as tall as its columns when balanced.
        let columns = ColumnSet(properties, width: max(width - horizontal, 1))
        if columns.count > 1 {
            return ceil(balancedHeight(framesetter, length: string.length, columns: columns)) + vertical
        }
        let size = suggestedSize(framesetter, string: string, width: max(width - horizontal, 1))
        return ceil(size.height) + vertical
    }

    /// The width `body` takes, insets included, when its lines never wrap.
    public func unwrappedWidth(of body: TextBody, shape: SlideShape) -> CGFloat {
        let properties = style.bodyProperties(for: shape, sources: []).merged(over: body.properties)
        let horizontal = EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440))
        let string = attributedString(body, shape: shape, sources: [], scale: 1, spacingReduction: 0, colorOverride: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let size = suggestedSize(framesetter, string: string, width: 100_000)
        return ceil(size.width + trailingWhitespace(framesetter)) + 1 + horizontal
    }

    /// The widest run of spaces ending a line. Suggested sizes leave these
    /// out, but a frame only that wide wraps the line before them.
    private func trailingWhitespace(_ framesetter: CTFramesetter) -> CGFloat {
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 100_000, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        return lines.map { CGFloat(CTLineGetTrailingWhitespaceWidth($0)) }.max() ?? 0
    }

    private func suggestedSize(_ framesetter: CTFramesetter, string: NSAttributedString, width: CGFloat) -> CGSize {
        CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: string.length), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
    }

    // MARK: - Attributed string

    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let paragraphIndexKey = NSAttributedString.Key("DazzleParagraphIndex")
    private static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    private static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
    private static let superscriptKey = NSAttributedString.Key(kCTSuperscriptAttributeName as String)
    private static let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
    private static let strikeKey = NSAttributedString.Key("DazzleStrikethrough")
    private static let linkKey = NSAttributedString.Key("DazzleLink")
    private static let strokeWidthKey = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)
    private static let strokeColorKey = NSAttributedString.Key(kCTStrokeColorAttributeName as String)
    private static let shadowKey = NSAttributedString.Key("DazzleShadow")

    /// A link riding on the text it belongs to.
    private final class LinkBox: NSObject {
        let link: Hyperlink
        init(_ link: Hyperlink) { self.link = link }
    }

    /// A shadow riding on the text that casts it, its colour worked out.
    private final class ShadowBox: NSObject {
        let shadow: Shadow
        let color: CGColor
        init(_ shadow: Shadow, color: CGColor) {
            self.shadow = shadow
            self.color = color
        }
    }

    public func attributedString(
        _ body: TextBody, shape: SlideShape, sources: [SlideShape], scale: Double, spacingReduction: Double,
        colorOverride: RGBAColor?, hidesText: Bool = false, paragraphOpacity: [Int: Double] = [:],
        colorChanges: [AnimationColorChange.Value] = [], paragraphColorChanges: [Int: [AnimationColorChange.Value]] = [:]
    ) -> NSAttributedString {
        let textColor = hidesText ? RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) : colorOverride
        let result = NSMutableAttributedString()
        var counters: [Int: Int] = [:]

        for (index, paragraph) in body.paragraphs.enumerated() {
            let level = paragraph.properties.level ?? 0
            let properties = paragraph.properties.merged(over: style.paragraphBase(for: shape, sources: sources, level: level))
            let start = result.length
            // A paragraph break is as tall as the text before it; only an empty
            // paragraph, or one that says so, takes its end-of-paragraph size.
            let endRun = (paragraph.endProperties ?? paragraph.runs.last?.properties ?? RunProperties())
                .merged(over: properties.defaultRun)
            let firstRun = paragraph.runs.first.map { $0.properties.merged(over: properties.defaultRun) } ?? endRun
            let baseSize = CGFloat(firstRun.size ?? 1_800) / 100 * scale

            // Numbering continues through a level until something interrupts it.
            for deeper in counters.keys where deeper > level { counters[deeper] = nil }
            var bulletText: String?
            if !paragraph.plainText.isEmpty {
                switch properties.bullet {
                case .character(let character):
                    bulletText = character
                case .autoNumber(let scheme, let startAt):
                    let number = (counters[level] ?? (startAt - 1)) + 1
                    counters[level] = number
                    bulletText = Self.numberLabel(number, scheme: scheme)
                default:
                    counters[level] = nil
                }
            }
            if let bulletText {
                var bulletRun = firstRun
                bulletRun.isUnderlined = false
                if let font = properties.bulletFont, !font.hasPrefix("+"), !["Arial", "Wingdings", "Symbol"].contains(font) {
                    bulletRun.latinFont = font
                }
                if let color = properties.bulletColor { bulletRun.color = color }
                let bulletScale = scale * (properties.bulletSize ?? 1)
                result.append(NSAttributedString(
                    string: Self.displayable(bulletText) + "\t",
                    attributes: attributes(for: bulletRun, scale: bulletScale, colorOverride: colorOverride)
                ))
            }

            for run in paragraph.runs {
                var runProperties = run.properties.merged(over: properties.defaultRun)
                // Linked text is drawn in the theme's link colour, underlined, unless it says otherwise.
                if run.properties.link != nil {
                    runProperties.color = run.properties.color ?? .scheme("hlink")
                    runProperties.isUnderlined = run.properties.isUnderlined ?? true
                }
                var text = run.text
                if case .field(let type) = run.kind {
                    if type == "slidenum" {
                        text = String(slideNumber)
                    } else if let date = DateField(rawValue: type) {
                        text = date.string(for: Date())
                    }
                }
                if runProperties.capitalization == "all" { text = text.uppercased() }
                text = Self.symbolsMapped(text)
                var runAttributes = attributes(for: runProperties, scale: scale, colorOverride: textColor)
                if let link = run.properties.link { runAttributes[Self.linkKey] = LinkBox(link) }
                result.append(NSAttributedString(string: text, attributes: runAttributes))
            }

            // A paragraph break, or for the last paragraph a zero-width space
            // so an empty paragraph still occupies a line.
            let terminator = index < body.paragraphs.count - 1 ? "\n" : (paragraph.runs.isEmpty ? "\u{200B}" : "")
            if !terminator.isEmpty {
                result.append(NSAttributedString(
                    string: terminator, attributes: attributes(for: endRun, scale: scale, colorOverride: textColor)
                ))
            }

            let range = NSRange(location: start, length: result.length - start)
            let changes = colorChanges + (paragraphColorChanges[index] ?? [])
            if !hidesText, !changes.isEmpty, range.length > 0 {
                result.enumerateAttribute(Self.colorKey, in: range) { value, subrange, _ in
                    guard let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID,
                          let color = (value as! CGColor).converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
                          let components = color.components, components.count >= 4 else { return }
                    let base = RGBAColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
                    let animated = changes.reduce(base) { base, change in change.color(base: base) { style.color($0) } }
                    result.addAttribute(Self.colorKey, value: animated.cgColor, range: subrange)
                }
            }
            // A paragraph not yet built in keeps its place, bullet and all, unseen.
            if let opacity = paragraphOpacity[index], opacity < 1, range.length > 0 {
                for key in [Self.colorKey, Self.strokeColorKey] {
                    result.enumerateAttribute(key, in: range) { value, subrange, _ in
                        guard let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID else { return }
                        let color = value as! CGColor // swiftlint:disable:this force_cast
                        result.addAttribute(key, value: color.copy(alpha: color.alpha * opacity) ?? color, range: subrange)
                    }
                }
            }
            if range.length > 0 {
                result.addAttribute(Self.paragraphIndexKey, value: index, range: range)
                result.addAttribute(
                    Self.paragraphKey,
                    value: paragraphStyle(properties, fontSize: baseSize, hasBullet: bulletText != nil, spacingReduction: spacingReduction),
                    range: range
                )
            }
        }
        return result
    }

    private func attributes(for run: RunProperties, scale: Double, colorOverride: RGBAColor?) -> [NSAttributedString.Key: Any] {
        var size = CGFloat(run.size ?? 1_800) / 100 * scale
        if run.baseline.map({ $0 != 0 }) == true { size *= 2 / 3 }
        let family = style.typeface(run.latinFont) ?? style.theme.minorFont
        let font = FontResolver.shared.font(
            family: family, size: max(size, 1), bold: run.isBold ?? false, italic: run.isItalic ?? false,
            embedded: style.resources.embeddedFonts
        )
        let color = colorOverride ?? run.color.map { style.color($0) } ?? style.color(.scheme("tx1"))
        var attributes: [NSAttributedString.Key: Any] = [
            Self.fontKey: font,
            Self.colorKey: color.cgColor,
        ]
        if run.isUnderlined == true {
            attributes[Self.underlineKey] = NSNumber(value: CTUnderlineStyle.single.rawValue)
        }
        if run.isStruckThrough == true {
            attributes[Self.strikeKey] = NSNumber(value: true)
        }
        if let baseline = run.baseline, baseline != 0 {
            attributes[Self.superscriptKey] = NSNumber(value: baseline > 0 ? 1 : -1)
        }
        if let spacing = run.spacing, spacing != 0 {
            // Spacing scales with the text when it is shrunk to fit, but not with superscript.
            attributes[Self.kernKey] = NSNumber(value: Double(spacing) / 100 * scale)
        }
        if case .line(let width, let outlineColor) = run.outline, width > 0 {
            // CoreText strokes by a percentage of the font size; negative fills the letters too.
            attributes[Self.strokeWidthKey] = NSNumber(value: -EMU.points(width) / Double(size) * 100)
            attributes[Self.strokeColorKey] = (colorOverride ?? style.color(outlineColor)).cgColor
        }
        // Prompts and text laid out unseen cast no shadow.
        if case .shadow(let shadow) = run.shadow, colorOverride == nil {
            attributes[Self.shadowKey] = ShadowBox(shadow, color: style.color(shadow.color).cgColor)
        }
        return attributes
    }

    private func paragraphStyle(
        _ properties: ParagraphProperties, fontSize: CGFloat, hasBullet: Bool, spacingReduction: Double
    ) -> CTParagraphStyle {
        let marginLeft = CGFloat(EMU.points(properties.marginLeft ?? 0))
        let indent = CGFloat(EMU.points(properties.indent ?? 0))
        var alignment: CTTextAlignment = switch properties.alignment ?? .left {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        // The first line starts at the indent, where a bullet hangs; the tab
        // after the bullet lands on the margin, where the rest of the lines start.
        var firstLine = max(marginLeft + indent, 0)
        var head = marginLeft
        let tabLocation = marginLeft > firstLine || !hasBullet ? marginLeft : firstLine + fontSize * 0.6
        var tabs = [CTTextTabCreate(.left, Double(tabLocation), nil)] as CFArray
        var defaultTab: CGFloat = 72

        var lineMultiple: CGFloat = 1
        var minimumLine: CGFloat = 0
        var maximumLine: CGFloat = 0
        switch properties.lineSpacing {
        case .percent(let value): lineMultiple = CGFloat(max(value - spacingReduction, 0.5))
        case .points(let value):
            minimumLine = CGFloat(value)
            maximumLine = CGFloat(value)
        case nil: lineMultiple = CGFloat(max(1 - spacingReduction, 0.5))
        }
        func spacing(_ value: Spacing?) -> CGFloat {
            switch value {
            case .points(let points): CGFloat(points)
            case .percent(let percent): CGFloat(percent) * fontSize * 1.2
            case nil: 0
            }
        }
        var before = spacing(properties.spaceBefore)
        var after = spacing(properties.spaceAfter)

        var cleanups: [() -> Void] = []
        defer { cleanups.forEach { $0() } }
        func setting<T>(_ specifier: CTParagraphStyleSpecifier, _ value: inout T) -> CTParagraphStyleSetting {
            let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
            pointer.initialize(to: value)
            cleanups.append {
                pointer.deinitialize(count: 1)
                pointer.deallocate()
            }
            return CTParagraphStyleSetting(spec: specifier, valueSize: MemoryLayout<T>.size, value: pointer)
        }
        var settings = [
            setting(.alignment, &alignment),
            setting(.firstLineHeadIndent, &firstLine),
            setting(.headIndent, &head),
            setting(.tabStops, &tabs),
            setting(.defaultTabInterval, &defaultTab),
            setting(.paragraphSpacingBefore, &before),
            setting(.paragraphSpacing, &after),
        ]
        if minimumLine > 0 {
            settings.append(setting(.minimumLineHeight, &minimumLine))
            settings.append(setting(.maximumLineHeight, &maximumLine))
        } else {
            settings.append(setting(.lineHeightMultiple, &lineMultiple))
        }
        return CTParagraphStyleCreate(settings, settings.count)
    }

    /// Strikethrough is a TextKit attribute that CoreText does not draw.
    private func drawStrikethroughs(in frame: CTFrame, context: CGContext) {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            drawStrikethroughs(in: line, origin: origin, context: context)
        }
    }

    private func drawStrikethroughs(in line: CTLine, origin: CGPoint, context: CGContext) {
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard attributes[Self.strikeKey.rawValue] != nil else { continue }
            let font = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } // swiftlint:disable:this force_cast
            let height = font.map { CTFontGetXHeight($0) / 2 } ?? 4
            let start = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
            let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
            if let color = attributes[kCTForegroundColorAttributeName as String] {
                context.setStrokeColor(color as! CGColor) // swiftlint:disable:this force_cast
            }
            context.setLineWidth(max((font.map { CTFontGetSize($0) } ?? 12) / 16, 0.5))
            context.move(to: CGPoint(x: origin.x + start, y: origin.y + height))
            context.addLine(to: CGPoint(x: origin.x + start + width, y: origin.y + height))
            context.strokePath()
        }
    }

    // MARK: - Bullets

    public static func symbolsMapped(_ text: String) -> String { TextLabels.symbolsMapped(text) }

    public static func numberLabel(_ number: Int, scheme: String) -> String { TextLabels.numberLabel(number, scheme: scheme) }

    private static func displayable(_ bullet: String) -> String { TextLabels.displayable(bullet) }

    public init(style: SlideStyleContext, slideNumber: Int) {
        self.style = style
        self.slideNumber = slideNumber
    }
}

#endif
