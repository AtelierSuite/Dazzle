import Foundation

/// Reads Office Math (`m:oMath`) into a `MathEquation`.
public enum MathParser {
    /// The equations an `a14:m` holds: the one it wraps, or each line of the
    /// math paragraph it wraps, with how that paragraph is aligned.
    public static func equations(in element: XMLElement) -> (equations: [MathEquation], alignment: ParagraphAlignment?) {
        if let paragraph = element.firstChild(named: "oMathPara") {
            let justification = paragraph.firstChild(named: "oMathParaPr")?.firstChild(named: "jc")?.attribute("val")
            let alignment: ParagraphAlignment = switch justification {
            case "left": .left
            case "right": .right
            default: .center
            }
            let equations = paragraph.children(named: "oMath").map { MathEquation(content: nodes(in: $0), isDisplay: true) }
            return (equations, alignment)
        }
        return (element.children(named: "oMath").map { MathEquation(content: nodes(in: $0), isDisplay: false) }, nil)
    }

    /// The first `a:rPr` among an equation's runs, which says how large it is set.
    public static func firstRunProperties(in element: XMLElement) -> XMLElement? {
        for child in element.children {
            if child.name == "rPr", !isMathProperties(child) { return child }
            if let found = firstRunProperties(in: child) { return found }
        }
        return nil
    }

    /// Whether any equation lies within `element`.
    public static func containsMath(_ element: XMLElement) -> Bool {
        element.name == "oMath" || element.children.contains(where: containsMath)
    }

    /// `m:rPr` and `a:rPr` share a name; the math one is in the math namespace.
    private static func isMathProperties(_ element: XMLElement) -> Bool {
        element.qualifiedName.hasPrefix("m:")
            || element.children.contains { ["sty", "nor", "scr", "lit", "brk", "aln"].contains($0.name) }
    }

    /// An on/off property: there and not switched off.
    private static func flag(_ properties: XMLElement?, _ name: String) -> Bool? {
        guard let element = properties?.firstChild(named: name) else { return nil }
        guard let value = element.attribute("val") else { return true }
        return ["1", "on", "true"].contains(value)
    }

    private static func value(_ properties: XMLElement?, _ name: String) -> String? {
        properties?.firstChild(named: name)?.attribute("val")
    }

    /// The pieces an argument holds, in order.
    static func nodes(in element: XMLElement?) -> [MathNode] {
        guard let element else { return [] }
        return element.children.flatMap { node(from: $0) }
    }

    private static func node(from element: XMLElement) -> [MathNode] {
        func argument(_ name: String) -> [MathNode] { nodes(in: element.firstChild(named: name)) }
        let properties = element.firstChild(named: element.name + "Pr")
        switch element.name {
        case "r":
            return run(element).map { [.run($0)] } ?? []
        case "f":
            let kind = value(properties, "type").flatMap(MathFractionKind.init(rawValue:)) ?? .bar
            return [.fraction(kind, numerator: argument("num"), denominator: argument("den"))]
        case "sSub":
            return [.scripts(base: argument("e"), sub: argument("sub"), sup: nil, isBefore: false)]
        case "sSup":
            return [.scripts(base: argument("e"), sub: nil, sup: argument("sup"), isBefore: false)]
        case "sSubSup":
            return [.scripts(base: argument("e"), sub: argument("sub"), sup: argument("sup"), isBefore: false)]
        case "sPre":
            return [.scripts(base: argument("e"), sub: argument("sub"), sup: argument("sup"), isBefore: true)]
        case "rad":
            let degree = argument("deg")
            let hidesDegree = flag(properties, "degHide") ?? false
            return [.radical(degree: hidesDegree || degree.isEmpty ? nil : degree, radicand: argument("e"))]
        case "nary":
            let symbol = value(properties, "chr") ?? "\u{222B}"
            let limits = value(properties, "limLoc").flatMap(MathLimitLocation.init(rawValue:))
                ?? (MathNode.isIntegral(symbol) ? .subSup : .underOver)
            let sub = flag(properties, "subHide") == true ? [] : argument("sub")
            let sup = flag(properties, "supHide") == true ? [] : argument("sup")
            return [.nary(
                operator: symbol, limits: limits, sub: sub.isEmpty ? nil : sub, sup: sup.isEmpty ? nil : sup, body: argument("e")
            )]
        case "d":
            return [.delimited(
                open: value(properties, "begChr") ?? "(", close: value(properties, "endChr") ?? ")",
                separator: value(properties, "sepChr") ?? "|", parts: element.children(named: "e").map { nodes(in: $0) }
            )]
        case "m":
            let rows = element.children(named: "mr").map { $0.children(named: "e").map { nodes(in: $0) } }
            var alignments: [MathAlignment] = []
            for column in properties?.firstChild(named: "mcs")?.children(named: "mc") ?? [] {
                let columnProperties = column.firstChild(named: "mcPr")
                let alignment = value(columnProperties, "mcJc").flatMap(MathAlignment.init(rawValue:)) ?? .center
                let count = value(columnProperties, "count").flatMap(Int.init) ?? 1
                alignments += Array(repeating: alignment, count: min(max(count, 1), 64))
            }
            return [.matrix(rows: rows, alignments: alignments, isEquationArray: false)]
        case "eqArr":
            // Each row is cut where an ampersand aligns it: what comes before
            // ends at the mark, and what follows starts there.
            let rows = element.children(named: "e").map { cells(nodes(in: $0)) }
            let columns = rows.map(\.count).max() ?? 1
            let alignments: [MathAlignment] = columns == 1 ? [.center] : (0..<columns).map { $0 % 2 == 0 ? .right : .left }
            return [.matrix(rows: rows, alignments: alignments, isEquationArray: true)]
        case "func":
            return [.function(name: argument("fName"), argument: argument("e"))]
        case "limLow":
            return [.limit(base: argument("e"), limit: argument("lim"), isUpper: false)]
        case "limUpp":
            return [.limit(base: argument("e"), limit: argument("lim"), isUpper: true)]
        case "acc":
            return [.accent(character: value(properties, "chr") ?? "\u{302}", base: argument("e"))]
        case "bar":
            return [.bar(base: argument("e"), isOver: value(properties, "pos") == "top")]
        case "groupChr":
            let isOver = value(properties, "pos") == "top"
            let isCentered = value(properties, "vertJc").map { $0 == (isOver ? "top" : "bot") } ?? false
            return [.groupCharacter(
                character: value(properties, "chr") ?? "\u{23DF}", isOver: isOver, isCentered: isCentered, base: argument("e")
            )]
        case "box":
            return [.box(isBordered: false, content: argument("e"))]
        case "borderBox":
            return [.box(isBordered: true, content: argument("e"))]
        case "phant":
            return [.phantom(isShown: flag(properties, "show") ?? true, content: argument("e"))]
        case "oMath":
            return nodes(in: element)
        default:
            return []
        }
    }

    private static func run(_ element: XMLElement) -> MathRun? {
        guard let text = element.firstChild(named: "t")?.text, !text.isEmpty else { return nil }
        let mathProperties = element.children.first { $0.name == "rPr" && isMathProperties($0) }
        let runProperties = element.children.first { $0.name == "rPr" && !isMathProperties($0) }
        return MathRun(
            text: text,
            variant: value(mathProperties, "sty").flatMap(MathVariant.init(rawValue:)) ?? .italic,
            isNormalText: flag(mathProperties, "nor") ?? false,
            properties: RunProperties(element: runProperties)
        )
    }

    /// A row cut into cells at the ampersands in its own runs.
    private static func cells(_ row: [MathNode]) -> [[MathNode]] {
        var cells: [[MathNode]] = [[]]
        for node in row {
            guard case .run(let run) = node, !run.isNormalText, run.text.contains("&") else {
                cells[cells.count - 1].append(node)
                continue
            }
            for (index, part) in run.text.components(separatedBy: "&").enumerated() {
                if index > 0 { cells.append([]) }
                guard !part.isEmpty else { continue }
                var piece = run
                piece.text = part
                cells[cells.count - 1].append(.run(piece))
            }
        }
        return cells
    }
}
