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
    /// The picture at a package path, for picture bullets.
    public let picture: (String) -> CGImage?

    /// The kinds of vertical text, by their name in the file, all laid out
    /// across the shape and turned a quarter.
    static let verticalKinds = BodyProperties.verticalKinds
    /// Those set in vertical lines (縦書き, Mongolian and stacked), where
    /// Japanese and Chinese stand upright, rather than turned letters and all.
    static let uprightKinds: Set = ["eaVert", "mongolianVert", "wordArtVert", "wordArtVertRtl"]
    /// Those stacked, where every letter stands upright, Latin ones too.
    static let stackedKinds: Set = ["wordArtVert", "wordArtVertRtl"]

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
        /// Whether the lines follow each other the other way across the
        /// turned box, so vertical lines run left to right.
        var reversesLines = false
        /// How the text was shrunk to fit, when it was.
        var fit = BodyProperties.Autofit.ShrinkStep(fontScale: 1, lineSpacingReduction: 0)
        /// The WordArt warp the letters are laid along, if any.
        var warp: TextWarpGeometry?
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
        // Lines that run left to right, but not turned anticlockwise, follow
        // each other the other way across the turned box.
        var turn: (center: CGPoint, angle: CGFloat)?
        if properties.runsVertically {
            turn = (CGPoint(x: inner.midX, y: inner.midY), properties.vertical == "vert270" ? -.pi / 2 : .pi / 2)
            inner = CGRect(x: -inner.height / 2, y: -inner.width / 2, width: inner.height, height: inner.width)
        }
        let reversesLines = properties.runsVertically && !properties.linesStartAtRight && properties.vertical != "vert270"
        // WordArt warps horizontal text in one column, over the box inside its insets.
        let warp = properties.runsVertically || ColumnSet(properties, width: inner.width).count > 1
            ? nil : TextWarpGeometry(properties.warp, in: inner)
        func shaped(_ string: NSAttributedString) -> NSAttributedString { Self.shaped(string, vertical: properties.vertical) }

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

        // Shrink on overflow a step at a time, as PowerPoint would have when
        // it last saved, unless it said by how much. The least step stands
        // even when the text still overflows.
        var fit = BodyProperties.Autofit.ShrinkStep(fontScale: fontScale, lineSpacingReduction: spacingReduction)
        if let steps = properties.autofit?.shrinkStepsLeft, !steps.isEmpty, overflows() {
            for step in steps {
                fit = step
                string = shaped(attributedString(
                    body, shape: shape, sources: sources, scale: step.fontScale, spacingReduction: step.lineSpacingReduction,
                    colorOverride: colorOverride, hidesText: hidesText, paragraphOpacity: paragraphOpacity,
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
            return Layout(columns: laidOut, turn: turn, reversesLines: reversesLines, fit: fit)
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
            turn: turn, reversesLines: reversesLines, fit: fit, warp: warp
        )
    }

    /// Text as it is set in `vertical` lines. Japanese and Chinese take their
    /// vertical forms, which CoreText draws upright in the turned line, and
    /// stacked text stands every other letter upright too.
    static func shaped(_ string: NSAttributedString, vertical: String?) -> NSAttributedString {
        guard let vertical, uprightKinds.contains(vertical) else { return string }
        let shaped = NSMutableAttributedString(attributedString: string)
        shaped.addAttribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String), value: true,
            range: NSRange(location: 0, length: shaped.length)
        )
        return stackedKinds.contains(vertical) ? stacked(shaped) : shaped
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
        // Text laid out unseen, around what is being typed, stays flat as it is typed.
        if let warp = layout.warp, !hidesText {
            drawWarped(layout, warp: warp, appearances: paragraphAppearances, context: context)
            return
        }
        if !paragraphAppearances.isEmpty {
            drawParagraphs(layout, appearances: paragraphAppearances, context: context)
            return
        }
        let space = context.ctm
        // Every shadow goes down before any letter, so none falls across another run's letters.
        let placed = lines(of: layout)
        func inColumn(_ column: Layout.Column, _ draw: () -> Void) {
            context.saveGState()
            context.translateBy(x: column.origin.x, y: column.origin.y + column.height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            draw()
            context.restoreGState()
        }
        for (line, origin, column) in placed {
            inColumn(column) { drawHighlights(in: line, origin: origin, context: context) }
        }
        for (line, origin, column) in placed {
            inColumn(column) { drawShadows(of: line, at: origin, space: space, context: context) }
        }
        for (line, origin, column) in placed {
            inColumn(column) {
                context.textPosition = origin
                CTLineDraw(line, context)
                drawStackedLetters(in: line, at: origin, context: context)
                drawEquations(in: line, at: origin, context: context)
                drawPictureBullets(in: line, at: origin, context: context)
                drawDecorations(in: line, origin: origin, context: context)
            }
        }
    }

    /// Every line laid out, column by column, with where it starts in its
    /// column's CoreText space. Lines running the other way across the turned
    /// box are set in the opposite order about its middle, which is where it is turned.
    private func lines(of layout: Layout) -> [(line: CTLine, origin: CGPoint, column: Layout.Column)] {
        layout.columns.flatMap { column in
            let lines = CTFrameGetLines(column.frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(column.frame, CFRange(location: 0, length: 0), &origins)
            return zip(lines, origins).map { line, origin in
                guard layout.reversesLines else { return (line, origin, column) }
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                let baseline = column.origin.y + column.height - origin.y
                let reversed = -baseline + ascent - descent
                return (line, CGPoint(x: origin.x, y: column.origin.y + column.height - reversed), column)
            }
        }
    }

    /// Highlighted runs' colour, behind their letters, as tall as the line's letters reach.
    private func drawHighlights(in line: CTLine, origin: CGPoint, context: CGContext) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[Self.highlightKey.rawValue], CFGetTypeID(value as CFTypeRef) == CGColor.typeID else { continue }
            let start = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
            let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
            context.setFillColor(value as! CGColor) // swiftlint:disable:this force_cast
            context.fill(CGRect(x: origin.x + start, y: origin.y - descent, width: width, height: ascent + descent))
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
            drawStackedLetter(in: run, at: origin, context: context)
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
                drawHighlights(in: entry.line, origin: .zero, context: context)
                context.restoreGState()
            }
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
                drawStackedLetters(in: entry.line, at: .zero, context: context)
                drawEquations(in: entry.line, at: .zero, context: context)
                drawPictureBullets(in: entry.line, at: .zero, context: context)
                drawDecorations(in: entry.line, origin: .zero, context: context)
                context.restoreGState()
            }
        }
    }

    // MARK: - Warped text

    /// One run's letters, laid along a warp.
    private struct WarpedRun {
        var paragraph: Int
        var outline: CGPath
        var color: CGColor?
        /// CoreText's stroke width, a percentage of the font size, negative when the letters are filled too.
        var strokeWidth: CGFloat
        var strokeColor: CGColor?
        var shadow: ShadowBox?
    }

    /// Each line's letters as outlines, every one laid along the warp where
    /// its place in the line puts it. Underlines and strikethroughs are left out.
    private func warpedRuns(_ layout: Layout, warp: TextWarpGeometry) -> [WarpedRun] {
        let placed = lines(of: layout)
        let measured = placed.map { line, origin, column in
            let baseline = column.origin.y + column.height - origin.y
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil) - CTLineGetTrailingWhitespaceWidth(line))
            // How high and low the letters themselves reach, or the line's own height when it has none.
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let reach = ink.isNull || ink.isEmpty ? (top: baseline - ascent, bottom: baseline + descent)
                : (top: baseline - ink.maxY, bottom: baseline - ink.minY)
            return (line: line, baseline: baseline, width: width, top: reach.top, bottom: reach.bottom)
        }
        // Each band's lines: how high and low their letters reach, and the first one's baseline.
        var reaches: [Int: (top: CGFloat, bottom: CGFloat, baseline: CGFloat)] = [:]
        for (index, line) in measured.enumerated() {
            let band = warp.band(forLine: index, of: measured.count)
            let reach = reaches[band] ?? (line.top, line.bottom, line.baseline)
            reaches[band] = (min(reach.top, line.top), max(reach.bottom, line.bottom), reach.baseline)
        }
        var placements: [Int: TextWarpGeometry.Placement] = [:]
        for (band, reach) in reaches {
            placements[band] = warp.placement(band: band, top: reach.top, bottom: reach.bottom, baseline: reach.baseline)
        }
        var result: [WarpedRun] = []
        for (index, line) in measured.enumerated() {
            guard let placement = placements[warp.band(forLine: index, of: measured.count)] else { continue }
            for run in CTLineGetGlyphRuns(line.line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard count > 0, let font = attributes[kCTFontAttributeName as String].map({ $0 as! CTFont }) else { // swiftlint:disable:this force_cast
                    continue
                }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                let outline = CGMutablePath()
                for index in 0..<count {
                    var transform = warp.letterTransform(
                        placement, from: positions[index].x, to: positions[index].x + advances[index].width,
                        lineWidth: line.width, baseline: line.baseline - positions[index].y, ascent: CTFontGetSize(font)
                    )
                    if let letter = CTFontCreatePathForGlyph(font, glyphs[index], &transform) { outline.addPath(letter) }
                }
                guard !outline.isEmpty else { continue }
                let color = attributes[Self.colorKey.rawValue].map { $0 as! CGColor } // swiftlint:disable:this force_cast
                let strokePercent = (attributes[Self.strokeWidthKey.rawValue] as? NSNumber)?.doubleValue ?? 0
                result.append(WarpedRun(
                    paragraph: attributes[Self.paragraphIndexKey.rawValue] as? Int ?? 0, outline: outline, color: color,
                    strokeWidth: CGFloat(strokePercent) / 100 * CTFontGetSize(font),
                    strokeColor: attributes[Self.strokeColorKey.rawValue].map { $0 as! CGColor }, // swiftlint:disable:this force_cast
                    shadow: attributes[Self.shadowKey.rawValue] as? ShadowBox
                ))
            }
        }
        return result
    }

    /// Draws text laid along its warp: every shadow first, then the letters,
    /// each paragraph moved and faded as `appearances` says.
    private func drawWarped(_ layout: Layout, warp: TextWarpGeometry, appearances: [Int: AnimatedAppearance], context: CGContext) {
        let runs = warpedRuns(layout, warp: warp)
        let paragraphs = Dictionary(grouping: runs, by: \.paragraph)
        func each(_ draw: (WarpedRun) -> Void) {
            for index in paragraphs.keys.sorted() {
                guard let paragraph = paragraphs[index] else { continue }
                let appearance = appearances[index] ?? AnimatedAppearance()
                guard appearance.opacity > 0.001, appearance.axisScale.width != 0, appearance.axisScale.height != 0 else { continue }
                context.saveGState()
                let bounds = paragraph.reduce(CGRect.null) { $0.union($1.outline.boundingBoxOfPath) }
                let faded = appearances[index].map { SlideRenderer.apply($0, to: bounds, context: context) } ?? false
                paragraph.forEach(draw)
                if faded { context.endTransparencyLayer() }
                context.restoreGState()
            }
        }
        let space = context.ctm
        each { run in
            guard let box = run.shadow else { return }
            context.saveGState()
            // The letters are drawn far off to one side, and their shadow brought back by as much.
            let away = CGSize(width: 100_000, height: 0)
            let ctm = context.ctm
            let displacement = away.applying(CGAffineTransform(a: ctm.a, b: ctm.b, c: ctm.c, d: ctm.d, tx: 0, ty: 0))
            let color = box.color.copy(alpha: box.color.alpha * (run.color?.alpha ?? 1)) ?? box.color
            SlideRenderer.setShadow(box.shadow, color: color, space: space, context: context, displacement: displacement)
            context.translateBy(x: away.width, y: away.height)
            context.addPath(run.outline)
            context.setFillColor(run.color ?? CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        each { run in
            if run.strokeWidth <= 0, let color = run.color {
                context.addPath(run.outline)
                context.setFillColor(color)
                context.fillPath()
            }
            if run.strokeWidth != 0, let color = run.strokeColor {
                context.addPath(run.outline)
                context.setStrokeColor(color)
                context.setLineWidth(abs(run.strokeWidth))
                context.setLineJoin(.round)
                context.strokePath()
            }
        }
    }

    /// Where each linked run of `body` lies, in slide points, where it
    /// goes, and its ScreenTip. Text running vertically has none.
    public func linkAreas(_ body: TextBody, shape: SlideShape, sources: [SlideShape], in rect: CGRect) -> [(CGRect, Hyperlink, String?)] {
        guard let layout = layout(body, shape: shape, sources: sources, in: rect, colorOverride: nil, hidesText: false),
              layout.turn == nil else { return [] }
        var areas: [(CGRect, Hyperlink, String?)] = []
        for (line, origin, column) in lines(of: layout) {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let box = attributes[Self.linkKey.rawValue] as? LinkBox else { continue }
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
                let start = Self.leftEdge(of: run, width: width, in: line)
                areas.append((CGRect(
                    x: column.origin.x + origin.x + start, y: column.origin.y + column.height - origin.y - ascent,
                    width: width, height: ascent + descent
                ), box.link, box.tooltip))
            }
        }
        return areas
    }

    /// The rectangle a shape's text is set in, in slide points, insets and all.
    public static func textFrame(of shape: SlideShape) -> CGRect {
        let frame = shape.frame.points
        return shape.textFrame?.points ?? shape.geometry.presetName.map {
            PresetGeometry.textRect($0, adjustments: shape.geometry.adjustments, in: frame)
        } ?? frame
    }

    /// How `body` shrinks to fit `shape`, worked out afresh as PowerPoint
    /// would after an edit: the `normAutofit` to save, so other apps set the
    /// text the same size. Nil when the text doesn't shrink on overflow.
    public func shrinkFit(of body: TextBody, shape: SlideShape, sources: [SlideShape]) -> BodyProperties.Autofit? {
        var measured = shape
        measured.text = body
        guard case .normal = style.bodyProperties(for: measured, sources: sources).merged(over: body.properties).autofit else {
            return nil
        }
        var unfitted = body
        unfitted.properties.autofit = .normal(fontScale: 1, lineSpacingReduction: 0)
        measured.text = unfitted
        guard let layout = layout(unfitted, shape: measured, sources: sources, in: Self.textFrame(of: shape),
                                  colorOverride: nil, hidesText: false) else {
            return unfitted.properties.autofit
        }
        return layout.fit.autofit
    }

    /// How far `shape`'s text is shrunk where the slide draws it: as the file
    /// says, or as far as it takes to fit when the file says nothing.
    public func drawnShrink(of shape: SlideShape, sources: [SlideShape]) -> BodyProperties.Autofit.ShrinkStep {
        let unshrunk = BodyProperties.Autofit.ShrinkStep(fontScale: 1, lineSpacingReduction: 0)
        guard let body = shape.text else { return unshrunk }
        return layout(body, shape: shape, sources: sources, in: Self.textFrame(of: shape), colorOverride: nil, hidesText: false)?.fit
            ?? unshrunk
    }

    /// Where a shape's text is laid out, in slide points: the shape's text
    /// rectangle with the insets taken off, and the body properties in force.
    public func textArea(of shape: SlideShape, sources: [SlideShape]) -> (rect: CGRect, properties: BodyProperties) {
        let textFrame = Self.textFrame(of: shape)
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
        let string = Self.shaped(
            attributedString(body, shape: shape, sources: [], scale: 1, spacingReduction: 0, colorOverride: nil),
            vertical: properties.vertical
        )
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        // Text in columns is as tall as its columns when balanced.
        let columns = ColumnSet(properties, width: max(width - horizontal, 1))
        if columns.count > 1 {
            return ceil(balancedHeight(framesetter, length: string.length, columns: columns)) + vertical
        }
        let size = suggestedSize(framesetter, string: string, width: max(width - horizontal, 1))
        return ceil(size.height) + vertical
    }

    /// How wide vertical `body` lays out at `height`, insets included: how
    /// far its lines reach across the box when each runs that far down it.
    public func width(of body: TextBody, shape: SlideShape, height: CGFloat) -> CGFloat {
        let properties = style.bodyProperties(for: shape, sources: []).merged(over: body.properties)
        let horizontal = EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440))
        let vertical = EMU.points((properties.topInset ?? 45_720) + (properties.bottomInset ?? 45_720))
        let string = Self.shaped(
            attributedString(body, shape: shape, sources: [], scale: 1, spacingReduction: 0, colorOverride: nil),
            vertical: properties.vertical
        )
        let size = suggestedSize(CTFramesetterCreateWithAttributedString(string), string: string, width: max(height - vertical, 1))
        return ceil(size.height) + horizontal
    }

    /// The width `body` takes, insets included, when its lines never wrap.
    public func unwrappedWidth(of body: TextBody, shape: SlideShape) -> CGFloat {
        let properties = style.bodyProperties(for: shape, sources: []).merged(over: body.properties)
        let horizontal = EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440))
        let string = Self.shaped(
            attributedString(body, shape: shape, sources: [], scale: 1, spacingReduction: 0, colorOverride: nil),
            vertical: properties.vertical
        )
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
    private static let underlineKey = NSAttributedString.Key("DazzleUnderline")
    private static let underlineColorKey = NSAttributedString.Key("DazzleUnderlineColor")
    private static let superscriptKey = NSAttributedString.Key(kCTSuperscriptAttributeName as String)
    private static let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
    private static let strikeKey = NSAttributedString.Key("DazzleStrikethrough")
    private static let linkKey = NSAttributedString.Key("DazzleLink")
    private static let strokeWidthKey = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)
    private static let strokeColorKey = NSAttributedString.Key(kCTStrokeColorAttributeName as String)
    private static let shadowKey = NSAttributedString.Key("DazzleShadow")
    private static let highlightKey = NSAttributedString.Key("DazzleHighlight")

    /// A link riding on the text it belongs to.
    private final class LinkBox: NSObject {
        let link: Hyperlink
        let tooltip: String?
        init(_ link: Hyperlink, tooltip: String?) {
            self.link = link
            self.tooltip = tooltip
        }
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
            var bulletPicture: CGImage?
            if !paragraph.plainText.isEmpty {
                switch properties.bullet {
                case .character(let character):
                    bulletText = character
                case .picture(let path):
                    bulletPicture = picture(path)
                    counters[level] = nil
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
                result.append(string(
                    Self.displayable(bulletText) + "\t", run: bulletRun,
                    attributes: attributes(for: bulletRun, scale: bulletScale, colorOverride: colorOverride)
                ))
            }
            if let bulletPicture {
                result.append(pictureBullet(
                    bulletPicture, run: firstRun, scale: scale * (properties.bulletSize ?? 1),
                    opacity: colorOverride?.alpha == 0 ? 0 : paragraphOpacity[index] ?? 1
                ))
            }

            for run in paragraph.runs {
                var runProperties = run.properties.merged(over: properties.defaultRun)
                // Linked text is drawn in the theme's link colour, underlined, unless it says otherwise.
                if run.properties.link != nil {
                    runProperties.color = run.properties.color ?? .scheme("hlink")
                    runProperties.isUnderlined = run.properties.isUnderlined ?? true
                }
                if case .equation(let equation) = run.kind {
                    result.append(equationString(equation, run: runProperties, scale: scale, colorOverride: textColor))
                    continue
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
                if let link = run.properties.link { runAttributes[Self.linkKey] = LinkBox(link, tooltip: run.properties.linkTooltip) }
                let runStart = result.length
                result.append(string(text, run: runProperties, attributes: runAttributes))
                if runProperties.underline == .words {
                    // Words underlined one by one: the spaces between them are left bare.
                    let spaces = try? NSRegularExpression(pattern: "\\s+")
                    for match in spaces?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                        result.removeAttribute(Self.underlineKey, range: NSRange(location: runStart + match.range.location, length: match.range.length))
                    }
                }
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
                for key in [Self.colorKey, Self.strokeColorKey, Self.underlineColorKey, Self.highlightKey] {
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
                    value: paragraphStyle(properties, fontSize: baseSize, hasBullet: bulletText != nil || bulletPicture != nil, spacingReduction: spacingReduction),
                    range: range
                )
            }
        }
        return result
    }

    /// `text` in `attributes`, with what is in Arabic, Hebrew or another
    /// complex script set in `run`'s complex-script typeface, at the same
    /// size and weight.
    private func string(_ text: String, run: RunProperties, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let stretches = ComplexScript.stretches(in: text)
        guard !stretches.isEmpty, let latin = attributes[Self.fontKey] else { return NSAttributedString(string: text, attributes: attributes) }
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let size = CTFontGetSize(latin as! CTFont) // swiftlint:disable:this force_cast
        for stretch in stretches {
            guard let family = style.complexScriptTypeface(for: run, script: stretch.script) else { continue }
            let font = FontResolver.shared.font(
                family: family, size: size, bold: run.isBold ?? false, italic: run.isItalic ?? false,
                embedded: style.resources.embeddedFonts
            )
            result.addAttribute(Self.fontKey, value: font, range: NSRange(location: stretch.range.lowerBound, length: stretch.range.count))
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
        if let underline = run.underline, underline != .none {
            attributes[Self.underlineKey] = underline.rawValue
            if let underlineColor = run.underlineColor {
                attributes[Self.underlineColorKey] = (colorOverride ?? style.color(underlineColor)).cgColor
            }
        }
        if let strike = run.strike, strike != .none {
            attributes[Self.strikeKey] = strike.rawValue
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
        // Prompts and text laid out unseen cast no shadow, and show no highlight.
        if case .shadow(let shadow) = run.shadow, colorOverride == nil {
            attributes[Self.shadowKey] = ShadowBox(shadow, color: style.color(shadow.color).cgColor)
        }
        if let highlight = run.highlight?.color, colorOverride == nil {
            attributes[Self.highlightKey] = style.color(highlight).cgColor
        }
        return attributes
    }

    private func paragraphStyle(
        _ properties: ParagraphProperties, fontSize: CGFloat, hasBullet: Bool, spacingReduction: Double
    ) -> CTParagraphStyle {
        let marginLeft = CGFloat(EMU.points(properties.marginLeft ?? 0))
        let indent = CGFloat(EMU.points(properties.indent ?? 0))
        // A right-to-left paragraph reads from the right: its margin, indent,
        // bullet and tab stops are measured from there, and it sits at the
        // right unless it says where. Alignment itself stays left and right
        // as the file names them, whichever way the paragraph reads.
        let rightToLeft = properties.isRightToLeft ?? false
        var direction: CTWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
        var alignment: CTTextAlignment = switch properties.effectiveAlignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        // The first line starts at the indent, where a bullet hangs; the tab
        // after the bullet lands on the margin, where the rest of the lines start.
        // The paragraph's own tab stops go alongside, and past them a stop
        // every default tab size.
        var firstLine = max(marginLeft + indent, 0)
        var head = marginLeft
        var tabs = TabLayout.stops(properties, fontSize: Double(fontSize), hasBullet: hasBullet)
            .map { Self.textTab($0, rightToLeft: rightToLeft) } as CFArray
        var defaultTab = CGFloat(TabLayout.defaultInterval(properties))

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
            setting(.baseWritingDirection, &direction),
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

    /// A stop as CoreText takes it. A decimal stop is a right-aligned one that
    /// ends its column at the decimal point.
    /// In a right-to-left paragraph the stops are measured from the right,
    /// and text starts at a left stop and ends at a right one as it reads,
    /// the other way round from how CoreText names them.
    private static func textTab(_ stop: TabLayout.Stop, rightToLeft: Bool) -> CTTextTab {
        let alignment: CTTextAlignment = switch stop.alignment {
        case .left: rightToLeft ? .right : .left
        case .center: .center
        case .right, .decimal: rightToLeft ? .left : .right
        }
        var options: CFDictionary?
        if stop.alignment == .decimal {
            let terminators = CFCharacterSetCreateWithCharactersInString(nil, String(TabLayout.decimalSeparator) as CFString)
            options = [kCTTabColumnTerminatorsAttributeName as String: terminators] as CFDictionary
        }
        return CTTextTabCreate(alignment, stop.location, options)
    }

    /// Where a run's letters start at the left, from its line's origin. A
    /// run read from right to left has its first character at its right.
    private static func leftEdge(of run: CTRun, width: Double, in line: CTLine) -> CGFloat {
        let start = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
        return CTRunGetStatus(run).contains(.rightToLeft) ? start - CGFloat(width) : start
    }

    /// Underlines and strikethroughs, drawn here rather than by CoreText,
    /// which has neither dotted, dashed nor wavy lines, nor double strikes.
    private func drawDecorations(in line: CTLine, origin: CGPoint, context: CGContext) {
        /// A wave about `y`, in step with every other wave on the line.
        func addWave(from left: CGFloat, to right: CGFloat, y: CGFloat, lineStart: CGFloat, thickness: CGFloat) {
            let length = max(thickness * 4, 2)
            let height = max(thickness, 0.75)
            func wave(_ x: CGFloat) -> CGFloat { height * sin((x - lineStart) / length * 2 * .pi) }
            var x = left
            context.move(to: CGPoint(x: x, y: y + wave(x)))
            while x < right {
                x = min(x + length / 8, right)
                context.addLine(to: CGPoint(x: x, y: y + wave(x)))
            }
        }

        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let underline = (attributes[Self.underlineKey.rawValue] as? String).flatMap(UnderlineStyle.init(rawValue:))
            let strike = (attributes[Self.strikeKey.rawValue] as? String).flatMap(StrikeStyle.init(rawValue:))
            guard underline != nil || strike != nil else { continue }
            let font = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } // swiftlint:disable:this force_cast
            let size = font.map { CTFontGetSize($0) } ?? 12
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
            let start = origin.x + Self.leftEdge(of: run, width: Double(width), in: line)
            let textColor = attributes[kCTForegroundColorAttributeName as String].map { $0 as! CGColor } // swiftlint:disable:this force_cast
            // Raised or lowered text keeps its lines with its letters.
            var position = CGPoint.zero
            if CTRunGetGlyphCount(run) > 0 { CTRunGetPositions(run, CFRange(location: 0, length: 1), &position) }
            let baseline = origin.y + position.y
            context.saveGState()
            if let strike {
                if let textColor { context.setStrokeColor(textColor) }
                let thickness = max(size / 16, 0.5)
                let middle = baseline + (font.map { CTFontGetXHeight($0) / 2 } ?? size / 4)
                context.setLineWidth(thickness)
                for offset in strike == .double ? [-thickness, thickness] : [0] {
                    context.move(to: CGPoint(x: start, y: middle + offset))
                    context.addLine(to: CGPoint(x: start + width, y: middle + offset))
                }
                context.strokePath()
            }
            if let underline {
                let color = attributes[Self.underlineColorKey.rawValue].map { $0 as! CGColor } ?? textColor // swiftlint:disable:this force_cast
                if let color { context.setStrokeColor(color) }
                let fontThickness = font.map { CTFontGetUnderlineThickness($0) } ?? 0
                var thickness = max(fontThickness > 0 ? fontThickness : size / 16, size / 24, 0.5)
                if underline.isHeavy { thickness *= 2 }
                let fontPosition = font.map { CTFontGetUnderlinePosition($0) } ?? 0
                let below = fontPosition < 0 ? -fontPosition : size / 10
                let y = baseline - below - thickness / 2
                context.setLineWidth(thickness)
                // Dashes run on from one run to the next, measured from the line's start.
                let dashes = underline.dashPattern.map { CGFloat($0) * thickness }
                if !dashes.isEmpty { context.setLineDash(phase: start - origin.x, lengths: dashes) }
                let offsets: [CGFloat] = underline.isDouble ? [thickness, -thickness] : [0]
                for offset in offsets {
                    if underline.isWavy {
                        addWave(from: start, to: start + width, y: y + offset, lineStart: origin.x, thickness: thickness)
                    } else {
                        context.move(to: CGPoint(x: start, y: y + offset))
                        context.addLine(to: CGPoint(x: start + width, y: y + offset))
                    }
                }
                context.strokePath()
            }
            context.restoreGState()
        }

    }

    // MARK: - Stacked letters

    private static let stackedKey = NSAttributedString.Key("DazzleStacked")

    /// A letter stood upright in stacked text. It is laid out as an object
    /// replacement character, holding a character's height down the line and
    /// an em across it, and drawn as its own line, turned back upright.
    private final class StackedLetter: NSObject {
        let line: CTLine?
        let length: CGFloat
        let breadth: CGFloat
        init(line: CTLine?, length: CGFloat, breadth: CGFloat) {
            self.line = line
            self.length = length
            self.breadth = breadth
        }
    }

    /// Stands upright every letter that vertical forms leave on its side.
    private static func stacked(_ string: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: string)
        let text = string.string as NSString
        let verticalForms = NSAttributedString.Key(kCTVerticalFormsAttributeName as String)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byComposedCharacterSequences) { letter, range, _, _ in
            guard let letter, let first = letter.unicodeScalars.first, !first.properties.isWhitespace,
                  first.properties.generalCategory != .format, !standsUpright(first) else { return }
            var attributes = string.attributes(at: range.location, effectiveRange: nil)
            guard attributes[equationKey] == nil else { return }
            attributes[verticalForms] = nil
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: letter, attributes: attributes))
            let font = attributes[fontKey].map { $0 as! CTFont } // swiftlint:disable:this force_cast
            let size = font.map(CTFontGetSize) ?? 18
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let stacked = StackedLetter(
                line: line, length: font.map { CTFontGetAscent($0) + CTFontGetDescent($0) } ?? size, breadth: max(size, width)
            )
            // A letter of more than one character keeps its length; the rest take no room.
            for offset in 0..<range.length {
                let letter = offset == 0 ? stacked : StackedLetter(line: nil, length: 0, breadth: 0)
                var replaced = attributes
                replaced[stackedKey] = letter
                replaced[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = runDelegate(for: letter)
                result.replaceCharacters(
                    in: NSRange(location: range.location + offset, length: 1),
                    with: NSAttributedString(string: "\u{FFFC}", attributes: replaced)
                )
            }
        }
        return result
    }

    /// Keeps a stacked letter's room in the line: its length down the line,
    /// half its breadth either side of the middle, where vertical forms sit.
    private static func runDelegate(for letter: StackedLetter) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<StackedLetter>.fromOpaque($0).release() },
            getAscent: { Unmanaged<StackedLetter>.fromOpaque($0).takeUnretainedValue().breadth / 2 },
            getDescent: { Unmanaged<StackedLetter>.fromOpaque($0).takeUnretainedValue().breadth / 2 },
            getWidth: { Unmanaged<StackedLetter>.fromOpaque($0).takeUnretainedValue().length }
        )
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(letter).toOpaque())
    }

    /// Whether vertical forms already stand a character upright: Japanese,
    /// Chinese and Korean letters, and their punctuation and symbols.
    static func standsUpright(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x303F, 0x3040...0x31FF, 0x3200...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFE10...0xFE1F, 0xFE30...0xFE4F,
             0xFF01...0xFF60, 0xFFE0...0xFFE6, 0x1F000...0x1FAFF, 0x20000...0x3FFFF:
            true
        default:
            false
        }
    }

    /// Draws each stacked letter of `line`, whose origin is `origin`.
    private func drawStackedLetters(in line: CTLine, at origin: CGPoint, context: CGContext) {
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            drawStackedLetter(in: run, at: origin, context: context)
        }
    }

    /// Draws `run`'s letter upright, if it is a stacked one, in the middle of
    /// the room it keeps: turned back a quarter against the line's turn.
    private func drawStackedLetter(in run: CTRun, at origin: CGPoint, context: CGContext) {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let letter = attributes[Self.stackedKey.rawValue] as? StackedLetter, let line = letter.line,
              CTRunGetGlyphCount(run) > 0 else { return }
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        context.translateBy(x: origin.x + position.x + letter.length / 2, y: origin.y + position.y)
        context.rotate(by: .pi / 2)
        context.textPosition = CGPoint(x: -width / 2, y: -(ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Equations

    private static let equationKey = NSAttributedString.Key("DazzleEquation")

    /// An equation as the one character that keeps its room in the line: an
    /// object replacement character as wide, tall and deep as the equation
    /// laid out, which is drawn in its place.
    private func equationString(
        _ equation: MathEquation, run: RunProperties, scale: Double, colorOverride: RGBAColor?
    ) -> NSAttributedString {
        var attributes = attributes(for: run, scale: scale, colorOverride: colorOverride)
        attributes[Self.underlineKey] = nil
        attributes[Self.strikeKey] = nil
        attributes[Self.shadowKey] = nil
        let size = max(CGFloat(run.size ?? 1_800) / 100 * scale, 1)
        let color = attributes[Self.colorKey].map { $0 as! CGColor } ?? CGColor(gray: 0, alpha: 1) // swiftlint:disable:this force_cast
        var layout = MathLayout(fontSize: size, color: color)
        // Prompts and text laid out unseen are all one colour.
        if colorOverride == nil {
            layout.runColor = { properties in properties.color.map { style.color($0).cgColor } }
        }
        layout.textFont = { properties, size in
            guard let family = style.typeface(properties.latinFont), family.lowercased() != "cambria math" else { return nil }
            return FontResolver.shared.font(
                family: family, size: size, bold: properties.isBold ?? false, italic: properties.isItalic ?? false,
                embedded: style.resources.embeddedFonts
            )
        }
        let box = layout.box(for: equation)
        // The line is never shorter for holding an equation than for holding text.
        let font = MathLayout.font(size: size)
        box.lineAscent = max(box.ascent, CTFontGetAscent(font))
        box.lineDescent = max(box.descent, CTFontGetDescent(font))
        box.baseAlpha = color.alpha
        attributes[Self.equationKey] = box
        attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = Self.runDelegate(for: box)
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }

    private static func runDelegate(for box: MathBox) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<MathBox>.fromOpaque($0).release() },
            getAscent: { Unmanaged<MathBox>.fromOpaque($0).takeUnretainedValue().lineAscent },
            getDescent: { Unmanaged<MathBox>.fromOpaque($0).takeUnretainedValue().lineDescent },
            getWidth: { Unmanaged<MathBox>.fromOpaque($0).takeUnretainedValue().width }
        )
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())
    }

    /// Draws each equation of `line`, whose origin is `origin`, where the line keeps its room.
    private func drawEquations(in line: CTLine, at origin: CGPoint, context: CGContext) {
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let box = attributes[Self.equationKey.rawValue] as? MathBox, CTRunGetGlyphCount(run) > 0 else { continue }
            var position = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
            context.saveGState()
            // An equation fades with its paragraph, as the text's colour says.
            if box.baseAlpha > 0.001, let color = attributes[Self.colorKey.rawValue] {
                let alpha = (color as! CGColor).alpha / box.baseAlpha // swiftlint:disable:this force_cast
                if alpha < 0.999 { context.setAlpha(max(alpha, 0)) }
            }
            box.draw(in: context, at: CGPoint(x: origin.x + position.x, y: origin.y + position.y))
            context.restoreGState()
        }
    }

    // MARK: - Bullets

    private static let pictureBulletKey = NSAttributedString.Key("DazzlePictureBullet")

    /// A picture bullet: the picture, how big it is drawn, and how far its
    /// bottom sits above the baseline.
    private final class PictureBullet: NSObject {
        let image: CGImage
        let size: CGSize
        let rise: CGFloat
        let opacity: CGFloat
        init(image: CGImage, size: CGSize, rise: CGFloat, opacity: CGFloat) {
            self.image = image
            self.size = size
            self.rise = rise
            self.opacity = opacity
        }
    }

    /// A picture bullet and the tab after it: an object replacement character
    /// keeping the picture's room, as tall as the text and centred on its
    /// capitals, the picture's own shape kept.
    private func pictureBullet(_ image: CGImage, run: RunProperties, scale: Double, opacity: Double) -> NSAttributedString {
        let textAttributes = attributes(for: run, scale: scale, colorOverride: nil)
        let font = textAttributes[Self.fontKey].map { $0 as! CTFont } // swiftlint:disable:this force_cast
        let height = max(CGFloat(run.size ?? 1_800) / 100 * scale, 1)
        let aspect = image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 1
        let middle = font.map { CTFontGetCapHeight($0) / 2 } ?? height * 0.35
        let bullet = PictureBullet(
            image: image, size: CGSize(width: height * aspect, height: height), rise: middle - height / 2,
            opacity: CGFloat(opacity)
        )
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<PictureBullet>.fromOpaque($0).release() },
            getAscent: { let bullet = Unmanaged<PictureBullet>.fromOpaque($0).takeUnretainedValue(); return max(bullet.rise + bullet.size.height, 0) },
            getDescent: { max(-Unmanaged<PictureBullet>.fromOpaque($0).takeUnretainedValue().rise, 0) },
            getWidth: { Unmanaged<PictureBullet>.fromOpaque($0).takeUnretainedValue().size.width }
        )
        var pictureAttributes = textAttributes
        pictureAttributes[Self.pictureBulletKey] = bullet
        pictureAttributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] =
            CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(bullet).toOpaque())
        let result = NSMutableAttributedString(string: "\u{FFFC}", attributes: pictureAttributes)
        result.append(NSAttributedString(string: "\t", attributes: textAttributes))
        return result
    }

    /// Draws each picture bullet of `line`, whose origin is `origin`.
    private func drawPictureBullets(in line: CTLine, at origin: CGPoint, context: CGContext) {
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let bullet = attributes[Self.pictureBulletKey.rawValue] as? PictureBullet, bullet.opacity > 0,
                  CTRunGetGlyphCount(run) > 0 else { continue }
            var position = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
            context.saveGState()
            context.setAlpha(bullet.opacity)
            context.interpolationQuality = .high
            context.draw(bullet.image, in: CGRect(
                origin: CGPoint(x: origin.x + position.x, y: origin.y + position.y + bullet.rise), size: bullet.size
            ))
            context.restoreGState()
        }
    }

    public static func symbolsMapped(_ text: String) -> String { TextLabels.symbolsMapped(text) }

    public static func numberLabel(_ number: Int, scheme: String) -> String { TextLabels.numberLabel(number, scheme: scheme) }

    private static func displayable(_ bullet: String) -> String { TextLabels.displayable(bullet) }

    public init(style: SlideStyleContext, slideNumber: Int, picture: @escaping (String) -> CGImage? = { _ in nil }) {
        self.style = style
        self.slideNumber = slideNumber
        self.picture = picture
    }

    /// A renderer that draws picture bullets from `presentation`'s package.
    public init(style: SlideStyleContext, slideNumber: Int, presentation: Presentation) {
        self.init(style: style, slideNumber: slideNumber) { path in
            presentation.data(at: path).flatMap { ImageCache.shared.image(for: $0, path: path) }
        }
    }
}

#endif
