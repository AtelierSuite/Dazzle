#if canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation

/// A piece of an equation laid out: how far it reaches along, above and
/// below its baseline, and the marks that draw it. Marks are placed from the
/// baseline's start, y running upwards, as CoreText draws.
public final class MathBox: NSObject {
    enum Mark {
        case glyphs(CTLine, CGPoint)
        case fill(CGPath, CGColor)
        case stroke(CGPath, CGColor, CGFloat)
    }

    public internal(set) var width: CGFloat
    public internal(set) var ascent: CGFloat
    public internal(set) var descent: CGFloat
    var marks: [Mark] = []
    /// The room the line keeps for it, never less than its text's own.
    var lineAscent: CGFloat = 0
    var lineDescent: CGFloat = 0
    /// How opaque the colour it was laid out in is.
    var baseAlpha: CGFloat = 1

    init(width: CGFloat = 0, ascent: CGFloat = 0, descent: CGFloat = 0) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }

    /// How many marks draw it.
    public var markCount: Int { marks.count }

    /// Sets `box` into this one, its baseline starting at `point`.
    func add(_ box: MathBox, at point: CGPoint) {
        var move = CGAffineTransform(translationX: point.x, y: point.y)
        for mark in box.marks {
            switch mark {
            case .glyphs(let line, let origin):
                marks.append(.glyphs(line, CGPoint(x: origin.x + point.x, y: origin.y + point.y)))
            case .fill(let path, let color):
                if let moved = path.copy(using: &move) { marks.append(.fill(moved, color)) }
            case .stroke(let path, let color, let width):
                if let moved = path.copy(using: &move) { marks.append(.stroke(moved, color, width)) }
            }
        }
    }

    /// This box moved up by `shift`, as a box of its own.
    func raised(by shift: CGFloat) -> MathBox {
        let box = MathBox(width: width, ascent: ascent + shift, descent: descent - shift)
        box.add(self, at: CGPoint(x: 0, y: shift))
        return box
    }

    /// Draws the box, its baseline starting at `origin`, in a context whose y
    /// axis points up and whose text matrix is the identity.
    public func draw(in context: CGContext, at origin: CGPoint) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        for mark in marks {
            switch mark {
            case .glyphs(let line, let point):
                context.textPosition = point
                CTLineDraw(line, context)
            case .fill(let path, let color):
                context.addPath(path)
                context.setFillColor(color)
                context.fillPath()
            case .stroke(let path, let color, let width):
                context.addPath(path)
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.setLineJoin(.miter)
                context.setLineCap(.butt)
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}

/// Lays an equation out as PowerPoint does: fractions stacked about the
/// line through the middle of the signs, scripts raised and lowered,
/// radicals, operators with their limits, delimiters grown to what they
/// hold, and matrices, set in the device's math font.
public struct MathLayout {
    /// The size of the text the equation sits in, in points.
    public var fontSize: CGFloat
    public var color: CGColor
    /// The colour of a run that has one of its own.
    public var runColor: (RunProperties) -> CGColor? = { _ in nil }
    /// The font ordinary text among the math is set in.
    public var textFont: (RunProperties, CGFloat) -> CTFont? = { _, _ in nil }

    public init(fontSize: CGFloat, color: CGColor) {
        self.fontSize = fontSize
        self.color = color
    }

    /// The font math is set in: Cambria Math where the device has it, as
    /// PowerPoint uses, or the STIX math font Apple's platforms carry.
    public static func font(size: CGFloat) -> CTFont {
        for name in ["Cambria Math", "STIX Two Math", "STIXGeneral"] {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            if (CTFontCopyFamilyName(font) as String).lowercased() == name.lowercased() { return font }
        }
        return CTFontCreateWithName("Times New Roman" as CFString, size, nil)
    }

    /// How large and how spread out a part of the equation is set.
    struct Style {
        var size: CGFloat
        /// 0 for the equation's own text, 1 for scripts, 2 for scripts of scripts.
        var level = 0
        var isDisplay: Bool

        /// The style of this style's scripts.
        var scripted: Style {
            Style(size: level == 0 ? size * 0.7 : (level == 1 ? size * 5 / 7 : size), level: min(level + 1, 2), isDisplay: isDisplay)
        }

        /// The height above the baseline of the line fractions and signs are centred on.
        var axis: CGFloat { size * 0.25 }
        /// How thick fraction bars and radical lines are.
        var rule: CGFloat { max(size * 0.06, 0.4) }
    }

    public func box(for equation: MathEquation) -> MathBox {
        row(equation.content, Style(size: fontSize, isDisplay: equation.isDisplay))
    }

    // MARK: - Rows

    private enum Atom {
        case ordinary, binary, relation, punctuation, opening, closing, large
    }

    /// The room between two neighbours, in eighteenths of an em: none in scripts.
    private func space(_ left: Atom, _ right: Atom, _ style: Style) -> CGFloat {
        let thin: CGFloat = 3, medium: CGFloat = 4, thick: CGFloat = 5
        var units: CGFloat = 0
        switch (left, right) {
        case (.punctuation, _): units = thin
        case (.large, .ordinary), (.large, .large), (.ordinary, .large), (.closing, .large): units = thin
        case (.binary, _), (_, .binary): units = style.level == 0 ? medium : 0
        case (.relation, .relation): units = 0
        case (.relation, _), (_, .relation): units = style.level == 0 ? thick : 0
        default: units = 0
        }
        return units / 18 * style.size
    }

    func row(_ nodes: [MathNode], _ style: Style) -> MathBox {
        var pieces: [(box: MathBox, atom: Atom)] = []
        func previous() -> Atom? { pieces.last?.atom }
        for node in nodes {
            switch node {
            case .run(let run):
                pieces += self.pieces(of: run, style, after: previous())
            case .nary:
                pieces.append((box(for: node, style), .large))
            default:
                pieces.append((box(for: node, style), .ordinary))
            }
        }
        let result = MathBox()
        var x: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            if index > 0 { x += space(pieces[index - 1].atom, piece.atom, style) }
            result.add(piece.box, at: CGPoint(x: x, y: 0))
            x += piece.box.width
            result.ascent = max(result.ascent, piece.box.ascent)
            result.descent = max(result.descent, piece.box.descent)
        }
        result.width = x
        return result
    }

    /// A run cut into the stretches drawn together and the signs spaced apart.
    private func pieces(of run: MathRun, _ style: Style, after: Atom?) -> [(box: MathBox, atom: Atom)] {
        let color = runColor(run.properties) ?? self.color
        if run.isNormalText {
            let font = textFont(run.properties, style.size) ?? Self.font(size: style.size)
            return [(text(run.text, font: font, color: color), .ordinary)]
        }
        let font = Self.font(size: style.size)
        var result: [(box: MathBox, atom: Atom)] = []
        var pending = ""
        func flush() {
            if !pending.isEmpty { result.append((text(pending, font: font, color: color), .ordinary)) }
            pending = ""
        }
        for character in run.displayText {
            var atom: Atom = switch MathAlphabet.classification(of: character) {
            case .ordinary: .ordinary
            case .binary: .binary
            case .relation: .relation
            case .punctuation: .punctuation
            case .opening: .opening
            case .closing: .closing
            }
            if atom == .ordinary {
                pending.append(character)
                continue
            }
            flush()
            // A sign with nothing before it to work on is a sign of what follows.
            if atom == .binary {
                switch result.last?.atom ?? after {
                case nil, .binary?, .relation?, .opening?, .punctuation?, .large?: atom = .ordinary
                default: break
                }
            }
            result.append((text(String(character), font: font, color: color), atom))
        }
        flush()
        return result
    }

    /// Text as a box as tall and deep as its ink, so what is built around it sits close.
    private func text(_ string: String, font: CTFont, color: CGColor) -> MathBox {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let box = MathBox(width: width)
        if !ink.isNull, !ink.isEmpty {
            box.ascent = max(ink.maxY, 0)
            box.descent = max(-ink.minY, 0)
        }
        box.marks = [.glyphs(line, .zero)]
        return box
    }

    private func rule(_ rect: CGRect) -> MathBox.Mark { .fill(CGPath(rect: rect, transform: nil), color) }

    // MARK: - Pieces

    private func box(for node: MathNode, _ style: Style) -> MathBox {
        switch node {
        case .run(let run):
            return row([.run(run)], style)
        case .fraction(let kind, let numerator, let denominator):
            return fraction(kind, numerator, denominator, style)
        case .scripts(let base, let sub, let sup, let isBefore):
            return scripts(row(base, style), sub: sub, sup: sup, isBefore: isBefore, style)
        case .radical(let degree, let radicand):
            return radical(degree: degree, radicand, style)
        case .nary(let symbol, let limits, let sub, let sup, let body):
            return nary(symbol, limits, sub: sub, sup: sup, body: body, style)
        case .delimited(let open, let close, let separator, let parts):
            return delimited(open: open, close: close, separator: separator, parts: parts, style)
        case .matrix(let rows, let alignments, let isEquationArray):
            return matrix(rows, alignments: alignments, isEquationArray: isEquationArray, style)
        case .function(let name, let argument):
            let result = row(name, style)
            let argumentBox = row(argument, style)
            // What a function is applied to stands a little off, unless brackets hold it.
            var gap = style.size * 3 / 18
            if case .delimited? = argument.first { gap = 0 }
            result.add(argumentBox, at: CGPoint(x: result.width + gap, y: 0))
            result.width += gap + argumentBox.width
            result.ascent = max(result.ascent, argumentBox.ascent)
            result.descent = max(result.descent, argumentBox.descent)
            return result
        case .limit(let base, let limit, let isUpper):
            let baseBox = row(base, style)
            let limitBox = row(limit, style.scripted)
            return stacked(baseBox, over: isUpper ? limitBox : nil, under: isUpper ? nil : limitBox, gap: style.size * 0.1)
        case .accent(let character, let base):
            return accent(character, row(base, style), style)
        case .bar(let base, let isOver):
            let result = row(base, style)
            let gap = style.size * 0.1
            if isOver {
                result.marks.append(rule(CGRect(x: 0, y: result.ascent + gap, width: result.width, height: style.rule)))
                result.ascent += gap + style.rule
            } else {
                result.marks.append(rule(CGRect(x: 0, y: -result.descent - gap - style.rule, width: result.width, height: style.rule)))
                result.descent += gap + style.rule
            }
            return result
        case .groupCharacter(let character, let isOver, let isCentered, let base):
            return groupCharacter(character, isOver: isOver, isCentered: isCentered, row(base, style), style)
        case .box(let isBordered, let content):
            let inner = row(content, style)
            guard isBordered else { return inner }
            let pad = style.size * 0.14
            let result = MathBox(width: inner.width + pad * 2, ascent: inner.ascent + pad, descent: inner.descent + pad)
            result.add(inner, at: CGPoint(x: pad, y: 0))
            let frame = CGRect(x: 0, y: -result.descent, width: result.width, height: result.ascent + result.descent)
                .insetBy(dx: style.rule / 2, dy: style.rule / 2)
            result.marks.append(.stroke(CGPath(rect: frame, transform: nil), color, style.rule))
            return result
        case .phantom(let isShown, let content):
            let inner = row(content, style)
            if !isShown { inner.marks = [] }
            return inner
        }
    }

    private func fraction(_ kind: MathFractionKind, _ numerator: [MathNode], _ denominator: [MathNode], _ style: Style) -> MathBox {
        if kind == .linear || kind == .skewed {
            let inner = kind == .skewed ? style.scripted : style
            let top = row(numerator, inner).raised(by: kind == .skewed ? style.size * 0.3 : 0)
            let bottom = row(denominator, inner).raised(by: kind == .skewed ? -style.size * 0.12 : 0)
            let slash = text("/", font: Self.font(size: style.size), color: color)
            let result = MathBox()
            for box in [top, slash, bottom] {
                result.add(box, at: CGPoint(x: result.width, y: 0))
                result.width += box.width
                result.ascent = max(result.ascent, box.ascent)
                result.descent = max(result.descent, box.descent)
            }
            return result
        }
        // In a line of text, and in scripts, a fraction's parts are set smaller.
        let inner = style.isDisplay && style.level == 0 ? style : style.scripted
        let top = row(numerator, inner)
        let bottom = row(denominator, inner)
        let gap = style.size * (style.isDisplay && style.level == 0 ? 0.16 : 0.1)
        let pad = style.size * 0.1
        let side = style.size * 0.06
        let barWidth = max(top.width, bottom.width) + pad * 2
        let half = kind == .bar ? style.rule / 2 : 0
        let topY = style.axis + half + gap + top.descent
        let bottomY = style.axis - half - gap - bottom.ascent
        let result = MathBox(width: barWidth + side * 2, ascent: topY + top.ascent, descent: -bottomY + bottom.descent)
        result.add(top, at: CGPoint(x: side + (barWidth - top.width) / 2, y: topY))
        result.add(bottom, at: CGPoint(x: side + (barWidth - bottom.width) / 2, y: bottomY))
        if kind == .bar {
            result.marks.append(rule(CGRect(x: side, y: style.axis - half, width: barWidth, height: style.rule)))
        }
        return result
    }

    private func scripts(_ base: MathBox, sub: [MathNode]?, sup: [MathNode]?, isBefore: Bool, _ style: Style) -> MathBox {
        let small = style.scripted
        let upper = sup.map { row($0, small) }
        let lower = sub.map { row($0, small) }
        var raise = max(style.size * 0.4, base.ascent - small.size * 0.3)
        var drop = max(style.size * 0.2, base.descent + small.size * 0.25)
        // Scripts keep clear of each other, and a subscript of the top of its base.
        if let lower { drop = max(drop, lower.ascent - max(base.ascent, style.size * 0.45) * 0.75) }
        if let upper, let lower {
            let clearance = (raise - upper.descent) - (lower.ascent - drop)
            let least = small.size * 0.2
            if clearance < least {
                raise += (least - clearance) / 2
                drop += (least - clearance) / 2
            }
        }
        let scriptWidth = max(upper?.width ?? 0, lower?.width ?? 0)
        let gap = style.size * 0.03
        let result = MathBox(width: base.width + gap + scriptWidth + gap, ascent: base.ascent, descent: base.descent)
        result.add(base, at: CGPoint(x: isBefore ? scriptWidth + gap : 0, y: 0))
        if let upper {
            result.add(upper, at: CGPoint(x: isBefore ? scriptWidth - upper.width : base.width + gap, y: raise))
            result.ascent = max(result.ascent, raise + upper.ascent)
        }
        if let lower {
            result.add(lower, at: CGPoint(x: isBefore ? scriptWidth - lower.width : base.width + gap, y: -drop))
            result.descent = max(result.descent, drop + lower.descent)
        }
        return result
    }

    private func radical(degree: [MathNode]?, _ radicand: [MathNode], _ style: Style) -> MathBox {
        let inner = row(radicand, style)
        let size = style.size
        let line = style.rule
        let gap = size * (style.isDisplay ? 0.14 : 0.1)
        let bottom = -max(inner.descent, size * 0.02) - size * 0.03
        let top = max(inner.ascent, size * 0.45) + gap + line / 2
        let height = top - bottom
        // The sign: a short tick up, a heavy stroke down to the foot, a fine
        // one up to the line, and the line over what the root is taken of.
        let tickBase = bottom + min(height * 0.5, size * 0.55)
        var points = [
            CGPoint(x: size * 0.04, y: tickBase), CGPoint(x: size * 0.15, y: tickBase + size * 0.07),
            CGPoint(x: size * 0.31, y: bottom + line), CGPoint(x: size * 0.52, y: top),
        ]
        let contentX = size * 0.57
        var offset: CGFloat = 0
        var degreeBox: MathBox?
        if let degree {
            let box = row(degree, Style(size: max(style.size * 0.5, style.scripted.scripted.size), level: 2, isDisplay: style.isDisplay))
            offset = max(box.width - size * 0.24, 0)
            degreeBox = box
        }
        points = points.map { CGPoint(x: $0.x + offset, y: $0.y) }
        let result = MathBox(
            width: offset + contentX + inner.width + size * 0.08, ascent: top + line / 2 + size * 0.03, descent: -bottom
        )
        let sign = CGMutablePath()
        sign.addLines(between: points + [CGPoint(x: result.width - size * 0.02, y: top)])
        result.marks.append(.stroke(sign, color, line))
        let heavy = CGMutablePath()
        heavy.addLines(between: [points[1], points[2]])
        result.marks.append(.stroke(heavy, color, line * 1.7))
        result.add(inner, at: CGPoint(x: offset + contentX, y: 0))
        if let degreeBox {
            let y = tickBase + size * 0.2 + degreeBox.descent
            result.add(degreeBox, at: CGPoint(x: offset + size * 0.24 - degreeBox.width, y: y))
            result.ascent = max(result.ascent, y + degreeBox.ascent)
        }
        return result
    }

    private func nary(
        _ symbol: String, _ limits: MathLimitLocation, sub: [MathNode]?, sup: [MathNode]?, body: [MathNode], _ style: Style
    ) -> MathBox {
        let isIntegral = MathNode.isIntegral(symbol)
        let isLarge = style.isDisplay && style.level == 0
        let scale: CGFloat = isIntegral ? (isLarge ? 1.9 : 1.25) : (isLarge ? 1.5 : 1)
        // The sign is drawn larger, centred on the line through the middle of the signs.
        let sign = centered(text(symbol, font: Self.font(size: style.size * scale), color: color), on: style.axis)
        let small = style.scripted
        let upper = sup.map { row($0, small) }
        let lower = sub.map { row($0, small) }
        var result: MathBox
        if limits == .underOver {
            result = stacked(sign, over: upper, under: lower, gap: style.size * 0.12)
        } else {
            let gap = style.size * 0.04
            // An integral leans, so its lower limit tucks in under it.
            let tuck = isIntegral ? sign.width * 0.3 : 0
            result = MathBox(width: sign.width, ascent: sign.ascent, descent: sign.descent)
            result.add(sign, at: .zero)
            if let upper {
                let y = sign.ascent - upper.ascent * 0.7
                result.add(upper, at: CGPoint(x: sign.width + gap, y: y))
                result.width = max(result.width, sign.width + gap + upper.width)
                result.ascent = max(result.ascent, y + upper.ascent)
            }
            if let lower {
                let y = -sign.descent + lower.ascent * 0.25
                result.add(lower, at: CGPoint(x: sign.width + gap - tuck, y: y))
                result.width = max(result.width, sign.width + gap - tuck + lower.width)
                result.descent = max(result.descent, -y + lower.descent)
            }
        }
        let bodyBox = row(body, style)
        let gap = bodyBox.width > 0 ? style.size * 3 / 18 : 0
        result.add(bodyBox, at: CGPoint(x: result.width + gap, y: 0))
        result.width += gap + bodyBox.width
        result.ascent = max(result.ascent, bodyBox.ascent)
        result.descent = max(result.descent, bodyBox.descent)
        return result
    }

    /// A box moved so its ink is centred `axis` above the baseline.
    private func centered(_ box: MathBox, on axis: CGFloat) -> MathBox {
        box.raised(by: axis - (box.ascent - box.descent) / 2)
    }

    /// A base with boxes centred over and under it.
    private func stacked(_ base: MathBox, over: MathBox?, under: MathBox?, gap: CGFloat) -> MathBox {
        let width = max(base.width, over?.width ?? 0, under?.width ?? 0)
        let result = MathBox(width: width, ascent: base.ascent, descent: base.descent)
        result.add(base, at: CGPoint(x: (width - base.width) / 2, y: 0))
        if let over {
            let y = base.ascent + gap + over.descent
            result.add(over, at: CGPoint(x: (width - over.width) / 2, y: y))
            result.ascent = y + over.ascent
        }
        if let under {
            let y = -base.descent - gap - under.ascent
            result.add(under, at: CGPoint(x: (width - under.width) / 2, y: y))
            result.descent = -y + under.descent
        }
        return result
    }

    // MARK: - Delimiters

    private func delimited(open: String, close: String, separator: String, parts: [[MathNode]], _ style: Style) -> MathBox {
        let boxes = parts.map { row($0, style) }
        let ascent = boxes.map(\.ascent).max() ?? 0
        let descent = boxes.map(\.descent).max() ?? 0
        // Delimiters reach as far above the line through the middle as below it.
        let reach = max(ascent - style.axis, descent + style.axis) + style.size * 0.04
        let result = MathBox()
        func append(_ box: MathBox, gap: CGFloat = 0) {
            result.add(box, at: CGPoint(x: result.width + gap, y: 0))
            result.width += gap + box.width
            result.ascent = max(result.ascent, box.ascent)
            result.descent = max(result.descent, box.descent)
        }
        if !open.isEmpty { append(fence(open, reach: reach, style)) }
        for (index, box) in boxes.enumerated() {
            if index > 0, !separator.isEmpty {
                append(fence(separator, reach: reach, style), gap: style.size * 0.08)
                result.width += style.size * 0.08
            }
            append(box)
        }
        if !close.isEmpty { append(fence(close, reach: reach, style)) }
        return result
    }

    /// A delimiter reaching `reach` above and below the line through the
    /// middle of the signs: the font's own while that is tall enough, or
    /// else drawn to size, straight ones in strokes and curved ones from the
    /// font's outline, stretched.
    private func fence(_ character: String, reach: CGFloat, _ style: Style) -> MathBox {
        let font = Self.font(size: style.size)
        let plain = text(character, font: font, color: color)
        let height = reach * 2
        guard height > (plain.ascent + plain.descent) * 1.08, height > style.size * 1.15 else { return plain }
        let top = style.axis + reach
        let bottom = style.axis - reach
        let line = max(style.size * 0.055, 0.5)
        let size = style.size
        let path = CGMutablePath()
        var width: CGFloat = 0
        func lines(_ points: [CGPoint]) { path.addLines(between: points) }
        switch character.unicodeScalars.first?.value {
        case 0x5B, 0x2308, 0x230A, 0x27E6:
            width = size * 0.36
            let x = size * 0.13, serif = size * 0.31
            let hasTop = character != "\u{230A}", hasBottom = character != "\u{2308}"
            lines((hasTop ? [CGPoint(x: serif, y: top - line / 2)] : []) + [CGPoint(x: x, y: top - (hasTop ? line / 2 : 0)),
                  CGPoint(x: x, y: bottom + (hasBottom ? line / 2 : 0))] + (hasBottom ? [CGPoint(x: serif, y: bottom + line / 2)] : []))
        case 0x5D, 0x2309, 0x230B, 0x27E7:
            width = size * 0.36
            let x = width - size * 0.13, serif = width - size * 0.31
            let hasTop = character != "\u{230B}", hasBottom = character != "\u{2309}"
            lines((hasTop ? [CGPoint(x: serif, y: top - line / 2)] : []) + [CGPoint(x: x, y: top - (hasTop ? line / 2 : 0)),
                  CGPoint(x: x, y: bottom + (hasBottom ? line / 2 : 0))] + (hasBottom ? [CGPoint(x: serif, y: bottom + line / 2)] : []))
        case 0x7C, 0x2223, 0x2502, 0x2758:
            width = size * 0.26
            lines([CGPoint(x: width / 2, y: top), CGPoint(x: width / 2, y: bottom)])
        case 0x2016, 0x2225:
            width = size * 0.42
            lines([CGPoint(x: width / 2 - size * 0.08, y: top), CGPoint(x: width / 2 - size * 0.08, y: bottom)])
            lines([CGPoint(x: width / 2 + size * 0.08, y: top), CGPoint(x: width / 2 + size * 0.08, y: bottom)])
        case 0x27E8, 0x2329, 0x3008, 0x3C:
            width = size * 0.3 + min(height * 0.08, size * 0.3)
            lines([CGPoint(x: width - size * 0.08, y: top), CGPoint(x: size * 0.1, y: style.axis), CGPoint(x: width - size * 0.08, y: bottom)])
        case 0x27E9, 0x232A, 0x3009, 0x3E:
            width = size * 0.3 + min(height * 0.08, size * 0.3)
            lines([CGPoint(x: size * 0.08, y: top), CGPoint(x: width - size * 0.1, y: style.axis), CGPoint(x: size * 0.08, y: bottom)])
        default:
            guard let glyph = Self.outline(of: character, font: font) else { return plain }
            let bounds = glyph.path.boundingBoxOfPath
            guard bounds.height > 0 else { return plain }
            let tall = height / bounds.height
            // Widened a little as it grows, so a tall bracket does not look pinched.
            let wide = min(1 + (tall - 1) * 0.3, 2)
            var stretch = CGAffineTransform(translationX: bounds.minX, y: bottom)
                .scaledBy(x: wide, y: tall).translatedBy(x: -bounds.minX, y: -bounds.minY)
            let box = MathBox(width: glyph.advance + bounds.width * (wide - 1), ascent: top, descent: -bottom)
            if let stretched = glyph.path.copy(using: &stretch) { box.marks = [.fill(stretched, color)] }
            return box
        }
        let box = MathBox(width: width, ascent: top, descent: -bottom)
        box.marks = [.stroke(path, color, line)]
        return box
    }

    /// A character's outline in `font`, or in the font that stands in where
    /// `font` lacks it, with how far it advances.
    private static func outline(of character: String, font: CTFont) -> (path: CGPath, advance: CGFloat)? {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: attributes))
        let result = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            guard count > 0, let value = runAttributes[kCTFontAttributeName as String] else { continue }
            let runFont = value as! CTFont // swiftlint:disable:this force_cast
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                var move = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                if let path = CTFontCreatePathForGlyph(runFont, glyphs[index], &move) { result.addPath(path) }
            }
        }
        guard !result.isEmpty else { return nil }
        return (result, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    // MARK: - Matrices

    private func matrix(_ rows: [[[MathNode]]], alignments: [MathAlignment], isEquationArray: Bool, _ style: Style) -> MathBox {
        let cells = rows.map { $0.map { row($0, style) } }
        let columns = cells.map(\.count).max() ?? 0
        guard columns > 0 else { return MathBox() }
        let size = style.size
        var widths = [CGFloat](repeating: 0, count: columns)
        for line in cells {
            for (index, cell) in line.enumerated() { widths[index] = max(widths[index], cell.width) }
        }
        // Every row is at least as tall as a line of letters, so rows of small things stay apart.
        let ascents = cells.map { max($0.map(\.ascent).max() ?? 0, size * 0.55) }
        let descents = cells.map { max($0.map(\.descent).max() ?? 0, size * 0.15) }
        let rowGap = size * (isEquationArray ? 0.3 : 0.4)
        let columnGap = isEquationArray ? 0 : size * 0.8
        let height = zip(ascents, descents).reduce(0) { $0 + $1.0 + $1.1 } + rowGap * CGFloat(cells.count - 1)
        let top = style.axis + height / 2
        let width = widths.reduce(0, +) + columnGap * CGFloat(columns - 1)
        let result = MathBox(width: width, ascent: top, descent: height - top)
        var y = top
        for (rowIndex, line) in cells.enumerated() {
            y -= ascents[rowIndex]
            var x: CGFloat = 0
            for (index, cell) in line.enumerated() {
                let alignment = alignments.indices.contains(index) ? alignments[index] : .center
                let inset: CGFloat = switch alignment {
                case .left: 0
                case .center: (widths[index] - cell.width) / 2
                case .right: widths[index] - cell.width
                }
                result.add(cell, at: CGPoint(x: x + inset, y: y))
                x += widths[index] + columnGap
            }
            y -= descents[rowIndex] + rowGap
        }
        return result
    }

    // MARK: - Accents and grouping characters

    /// An arrow `width` long along y = 0, pointing right, left or both ways.
    private func arrow(width: CGFloat, left: Bool, right: Bool, _ style: Style) -> CGPath {
        let head = style.size * 0.14
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0)])
        if right {
            path.addLines(between: [CGPoint(x: width - head, y: head * 0.7), CGPoint(x: width, y: 0), CGPoint(x: width - head, y: -head * 0.7)])
        }
        if left {
            path.addLines(between: [CGPoint(x: head, y: head * 0.7), CGPoint(x: 0, y: 0), CGPoint(x: head, y: -head * 0.7)])
        }
        return path
    }

    /// Which way an arrow character points, if it is one drawn to length.
    private static func arrowDirections(_ character: String) -> (left: Bool, right: Bool)? {
        switch character.unicodeScalars.first?.value {
        case 0x20D7, 0x2192, 0x27F6: (false, true)
        case 0x20D6, 0x2190, 0x27F5: (true, false)
        case 0x20E1, 0x2194, 0x27F7: (true, true)
        default: nil
        }
    }

    private func accent(_ character: String, _ base: MathBox, _ style: Style) -> MathBox {
        let size = style.size
        let result = MathBox(width: base.width, ascent: base.ascent, descent: base.descent)
        result.add(base, at: .zero)
        let floor = max(base.ascent, size * 0.4) + size * 0.06
        switch character.unicodeScalars.first?.value {
        case 0x304, 0x305, 0xAF, 0x203E:
            result.marks.append(rule(CGRect(x: 0, y: floor + size * 0.03, width: base.width, height: style.rule)))
            result.ascent = floor + size * 0.03 + style.rule
            return result
        default:
            break
        }
        if let directions = Self.arrowDirections(character) {
            var move = CGAffineTransform(translationX: 0, y: floor + size * 0.1)
            if let path = arrow(width: max(base.width, size * 0.4), left: directions.left, right: directions.right, style).copy(using: &move) {
                result.marks.append(.stroke(path, color, style.rule))
            }
            result.ascent = floor + size * 0.2
            return result
        }
        let mark = MathNode.spacingAccent(character)
        guard let glyph = Self.outline(of: mark, font: Self.font(size: size)) else { return result }
        let bounds = glyph.path.boundingBoxOfPath
        // A hat or tilde over something wide is widened to cover it.
        let wide = base.width > bounds.width * 2 ? min(base.width * 0.8 / bounds.width, 6) : 1
        var place = CGAffineTransform(translationX: (base.width - bounds.width * wide) / 2 + size * 0.03, y: floor)
            .scaledBy(x: wide, y: 1).translatedBy(x: -bounds.minX, y: -bounds.minY)
        if let path = glyph.path.copy(using: &place) { result.marks.append(.fill(path, color)) }
        result.ascent = floor + bounds.height
        return result
    }

    private func groupCharacter(_ character: String, isOver: Bool, isCentered: Bool, _ base: MathBox, _ style: Style) -> MathBox {
        let size = style.size
        let gap = size * 0.08
        let mark = MathBox(width: base.width)
        if let directions = Self.arrowDirections(character) {
            let head = size * 0.1
            var move = CGAffineTransform(translationX: 0, y: head)
            let width = max(base.width + size * 0.3, size * 0.6)
            if let path = arrow(width: width, left: directions.left, right: directions.right, style).copy(using: &move) {
                mark.marks = [.stroke(path, color, style.rule)]
            }
            mark.width = width
            mark.ascent = head * 2
        } else if let glyph = Self.outline(of: character, font: Self.font(size: size)) {
            let bounds = glyph.path.boundingBoxOfPath
            let wide = bounds.width > 0 ? max(base.width / bounds.width, 1) : 1
            var place = CGAffineTransform(scaleX: wide, y: 1).translatedBy(x: -bounds.minX, y: -bounds.minY)
            if let path = glyph.path.copy(using: &place) { mark.marks = [.fill(path, color)] }
            mark.width = bounds.width * wide
            mark.ascent = bounds.height
        }
        let result = stacked(base, over: isOver ? mark : nil, under: isOver ? nil : mark, gap: gap)
        guard isCentered else { return result }
        // The character sits on the line through the middle of the signs, and its base rides on it.
        let middle = isOver ? result.ascent - mark.ascent / 2 : -result.descent + mark.ascent / 2
        return result.raised(by: style.axis - middle)
    }
}
#endif
