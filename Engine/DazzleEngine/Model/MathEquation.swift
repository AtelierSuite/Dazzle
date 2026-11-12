import Foundation

/// An Office Math equation (`m:oMath`), as it sits in a paragraph's text.
public struct MathEquation: Equatable, Hashable, Sendable {
    public var content: [MathNode]
    /// Whether it stands as a paragraph of its own (`m:oMathPara`), set
    /// larger than one within a line: fractions at full size, limits above
    /// and below their operators.
    public var isDisplay: Bool

    public init(content: [MathNode], isDisplay: Bool = true) {
        self.content = content
        self.isDisplay = isDisplay
    }

    /// The equation written along a line, as it is searched and read out.
    public var linearText: String { MathNode.linearText(content) }
}

/// The letters a math run is set in: `m:sty`.
public enum MathVariant: String, Equatable, Hashable, Sendable {
    case plain = "p"
    case italic = "i"
    case bold = "b"
    case boldItalic = "bi"
}

/// `m:r`: letters, digits and signs sharing one look.
public struct MathRun: Equatable, Hashable, Sendable {
    public var text: String
    public var variant: MathVariant
    /// `m:nor`: ordinary text among the math, set as text is.
    public var isNormalText: Bool
    /// The run's own `a:rPr`, for its colour.
    public var properties: RunProperties

    public init(text: String, variant: MathVariant = .italic, isNormalText: Bool = false, properties: RunProperties = RunProperties()) {
        self.text = text
        self.variant = variant
        self.isNormalText = isNormalText
        self.properties = properties
    }

    /// The text as it is drawn: letters taken from the math alphabet its
    /// variant asks for, and a hyphen made a minus sign.
    public var displayText: String {
        isNormalText ? text : MathAlphabet.styled(text, variant: variant)
    }
}

/// How a fraction is written: `m:fPr`'s `type`.
public enum MathFractionKind: String, Equatable, Hashable, Sendable {
    case bar
    case noBar
    case skewed = "skw"
    case linear = "lin"
}

/// Where an operator's limits go: `m:limLoc`.
public enum MathLimitLocation: String, Equatable, Hashable, Sendable {
    /// Above and below.
    case underOver = "undOvr"
    /// To its right, as scripts.
    case subSup
}

public enum MathAlignment: String, Equatable, Hashable, Sendable {
    case left, center, right
}

/// One piece of an equation. Every argument is a row of pieces.
public enum MathNode: Equatable, Hashable, Sendable {
    case run(MathRun)
    /// `m:f`.
    case fraction(MathFractionKind, numerator: [MathNode], denominator: [MathNode])
    /// `m:sSub`, `m:sSup`, `m:sSubSup`, and `m:sPre`, whose scripts come before the base.
    case scripts(base: [MathNode], sub: [MathNode]?, sup: [MathNode]?, isBefore: Bool)
    /// `m:rad`: a root, square when it has no degree.
    case radical(degree: [MathNode]?, radicand: [MathNode])
    /// `m:nary`: a sum, product, integral or the like, with its limits and what it ranges over.
    case nary(operator: String, limits: MathLimitLocation, sub: [MathNode]?, sup: [MathNode]?, body: [MathNode])
    /// `m:d`: parts between delimiters that grow to hold them, with separators between parts.
    case delimited(open: String, close: String, separator: String, parts: [[MathNode]])
    /// `m:m`, and `m:eqArr`, whose rows are cut into cells where they are
    /// aligned: rows of cells, with how each column is aligned.
    case matrix(rows: [[[MathNode]]], alignments: [MathAlignment], isEquationArray: Bool)
    /// `m:func`: a named function and what it is applied to.
    case function(name: [MathNode], argument: [MathNode])
    /// `m:limLow` and `m:limUpp`: a limit set below or above its base.
    case limit(base: [MathNode], limit: [MathNode], isUpper: Bool)
    /// `m:acc`: an accent over its base.
    case accent(character: String, base: [MathNode])
    /// `m:bar`: a line over or under.
    case bar(base: [MathNode], isOver: Bool)
    /// `m:groupChr`: a brace or arrow stretched along its base; `isCentered`
    /// puts the character, rather than the base, on the line.
    case groupCharacter(character: String, isOver: Bool, isCentered: Bool, base: [MathNode])
    /// `m:box` and `m:borderBox`.
    case box(isBordered: Bool, content: [MathNode])
    /// `m:phant`: room kept for something, shown or not.
    case phantom(isShown: Bool, content: [MathNode])

    // MARK: - Linear text

    static func linearText(_ nodes: [MathNode]) -> String { nodes.map(\.linearText).joined() }

    /// A row as an argument: in brackets when it is more than one thing.
    private static func argument(_ nodes: [MathNode]) -> String {
        let text = linearText(nodes)
        if nodes.count == 1, case .run = nodes[0], text.allSatisfy({ $0.isLetter || $0.isNumber }) { return text }
        if nodes.count == 1, case .delimited = nodes[0] { return text }
        return text.count <= 1 ? text : "(\(text))"
    }

    public var linearText: String {
        switch self {
        case .run(let run):
            return run.text
        case .fraction(_, let numerator, let denominator):
            return Self.argument(numerator) + "/" + Self.argument(denominator)
        case .scripts(let base, let sub, let sup, let isBefore):
            let scripts = (sub.map { "_" + Self.argument($0) } ?? "") + (sup.map { "^" + Self.argument($0) } ?? "")
            return isBefore ? scripts + " " + Self.linearText(base) : Self.linearText(base) + scripts
        case .radical(let degree, let radicand):
            return (degree.map { Self.linearText($0) }.flatMap { $0.isEmpty ? nil : "(\($0))" } ?? "") + "√" + Self.argument(radicand)
        case .nary(let symbol, _, let sub, let sup, let body):
            return symbol + (sub.map { "_" + Self.argument($0) } ?? "") + (sup.map { "^" + Self.argument($0) } ?? "")
                + " " + Self.linearText(body)
        case .delimited(let open, let close, let separator, let parts):
            return open + parts.map(Self.linearText).joined(separator: separator) + close
        case .matrix(let rows, _, let isEquationArray):
            let lines = rows.map { $0.map(Self.linearText).joined(separator: isEquationArray ? "" : " ") }
            return isEquationArray ? lines.joined(separator: "; ") : "[" + lines.joined(separator: "; ") + "]"
        case .function(let name, let argument):
            return Self.linearText(name) + " " + Self.linearText(argument)
        case .limit(let base, let limit, let isUpper):
            return Self.linearText(base) + (isUpper ? "^" : "_") + Self.argument(limit)
        case .accent(_, let base), .bar(let base, _), .groupCharacter(_, _, _, let base):
            return Self.linearText(base)
        case .box(_, let content), .phantom(_, let content):
            return Self.linearText(content)
        }
    }

    /// Whether the piece is an integral, whose limits go to its right unless told otherwise.
    public static func isIntegral(_ symbol: String) -> Bool {
        symbol.unicodeScalars.first.map { (0x222B...0x2233).contains($0.value) || (0x2A0B...0x2A1C).contains($0.value) } ?? false
    }
}

/// The alphabets math is set in. A letter in a math run is drawn in the
/// italic, bold or bold italic math letters Unicode has for it, which a math
/// font draws as math wants them.
public enum MathAlphabet {
    /// Where each alphabet starts: Latin capitals, Latin small letters,
    /// Greek capitals, Greek small letters, and digits.
    private static func starts(_ variant: MathVariant) -> (upper: UInt32, lower: UInt32, greekUpper: UInt32, greekLower: UInt32, digit: UInt32?)? {
        switch variant {
        case .plain: nil
        case .italic: (0x1D434, 0x1D44E, 0x1D6E2, 0x1D6FC, nil)
        case .bold: (0x1D400, 0x1D41A, 0x1D6A8, 0x1D6C2, 0x1D7CE)
        case .boldItalic: (0x1D468, 0x1D482, 0x1D71C, 0x1D736, nil)
        }
    }

    /// The Greek letter forms that follow each small Greek alphabet, in the order they follow it.
    private static let greekSymbols: [UInt32] = [0x2202, 0x03F5, 0x03D1, 0x03F0, 0x03D5, 0x03F1, 0x03D6]

    public static func styled(_ text: String, variant: MathVariant) -> String {
        var result = String.UnicodeScalarView()
        let starts = starts(variant)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            var mapped: UInt32?
            if value == 0x2D {
                mapped = 0x2212
            } else if let starts {
                switch value {
                case 0x41...0x5A: mapped = starts.upper + value - 0x41
                case 0x61...0x7A: mapped = starts.lower + value - 0x61
                case 0x391...0x3A9: mapped = starts.greekUpper + value - 0x391
                case 0x3B1...0x3C9: mapped = starts.greekLower + value - 0x3B1
                case 0x30...0x39: mapped = starts.digit.map { $0 + value - 0x30 }
                case 0x2207: mapped = starts.greekUpper + 25
                default: mapped = greekSymbols.firstIndex(of: value).map { starts.greekLower + 25 + UInt32($0) }
                }
                // The italic small h was already in Unicode, as the Planck constant.
                if mapped == 0x1D455 { mapped = 0x210E }
            }
            result.append(mapped.flatMap(Unicode.Scalar.init) ?? scalar)
        }
        return String(result)
    }

    /// How a character behaves among its neighbours, which decides the room around it.
    public enum Class: Sendable {
        case ordinary, binary, relation, punctuation, opening, closing
    }

    public static func classification(of character: Character) -> Class {
        guard let scalar = character.unicodeScalars.first else { return .ordinary }
        switch scalar.value {
        case 0x2B, 0x2212, 0xB1, 0x2213, 0xD7, 0xF7, 0x22C5, 0xB7, 0x2217, 0x2A, 0x2218, 0x2219, 0x222A, 0x2229,
             0x2227, 0x2228, 0x2295...0x2299, 0x2216, 0x2A2F, 0x2020, 0x2021, 0x22C6:
            return .binary
        case 0x3D, 0x3C, 0x3E, 0x3A, 0x2260...0x228B, 0x2248, 0x2243, 0x2245, 0x223C, 0x221D, 0x2208...0x220D, 0x2223, 0x2225,
             0x22A2...0x22A9, 0x27C2, 0x2190...0x21FF, 0x27F5...0x27FF, 0x2900...0x297F, 0x2254, 0x2A7D, 0x2A7E:
            return .relation
        case 0x2C, 0x3B:
            return .punctuation
        case 0x28, 0x5B, 0x7B, 0x27E8, 0x2308, 0x230A:
            return .opening
        case 0x29, 0x5D, 0x7D, 0x27E9, 0x2309, 0x230B:
            return .closing
        default:
            return .ordinary
        }
    }
}

// MARK: - MathML

extension MathEquation {
    /// The equation as MathML, which browsers lay out. `color` gives the
    /// CSS colour of a run that has one of its own.
    public func mathML(color: (RunProperties) -> String? = { _ in nil }) -> String {
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" displaystyle=\"\(isDisplay)\">"
            + MathNode.mathML(content, color: color) + "</math>"
    }
}

extension MathNode {
    /// A row as one MathML element.
    static func mathML(_ nodes: [MathNode], color: (RunProperties) -> String?) -> String {
        "<mrow>" + nodes.map { $0.mathML(color: color) }.joined() + "</mrow>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The spacing character that looks as a combining accent does.
    static func spacingAccent(_ character: String) -> String {
        switch character.unicodeScalars.first?.value {
        case 0x300: "`"
        case 0x301: "\u{B4}"
        case 0x302: "^"
        case 0x303: "~"
        case 0x304, 0x305: "\u{AF}"
        case 0x306: "\u{2D8}"
        case 0x307: "\u{2D9}"
        case 0x308: "\u{A8}"
        case 0x30A: "\u{2DA}"
        case 0x30C: "\u{2C7}"
        case 0x20D6: "\u{2190}"
        case 0x20D7: "\u{2192}"
        case 0x20E1: "\u{2194}"
        default: character
        }
    }

    private static func tokens(_ run: MathRun, color: (RunProperties) -> String?) -> String {
        let style = color(run.properties).map { " style=\"color:\(escape($0))\"" } ?? ""
        if run.isNormalText {
            var css = color(run.properties).map { "color:\($0);" } ?? ""
            if run.properties.isBold == true { css += "font-weight:bold;" }
            if run.properties.isItalic == true { css += "font-style:italic;" }
            let text = escape(run.text.replacingOccurrences(of: " ", with: "\u{A0}"))
            return "<mtext\(css.isEmpty ? "" : " style=\"\(escape(css))\"")>\(text)</mtext>"
        }
        var result = ""
        var number = ""
        var word = ""
        func flush() {
            if !number.isEmpty { result += "<mn\(style)>\(escape(number))</mn>" }
            // Upright letters stay upright, where one alone would be made italic.
            if !word.isEmpty { result += "<mi mathvariant=\"normal\"\(style)>\(escape(word))</mi>" }
            number = ""
            word = ""
        }
        let characters = Array(run.displayText)
        for (index, character) in characters.enumerated() {
            let isDigit = character.isNumber
                || (character == "." && !number.isEmpty && index + 1 < characters.count && characters[index + 1].isNumber)
            if isDigit {
                if !word.isEmpty { flush() }
                number.append(character)
            } else if character.isLetter {
                if !number.isEmpty { flush() }
                // A letter already in a math alphabet is set as it is, one to an identifier.
                if character.unicodeScalars.first.map({ $0.value >= 0x1D400 || $0.value == 0x210E }) == true {
                    flush()
                    result += "<mi\(style)>\(character)</mi>"
                } else {
                    word.append(character)
                }
            } else {
                flush()
                if character == " " || character == "\u{A0}" {
                    result += "<mtext>\u{A0}</mtext>"
                } else {
                    // A bracket typed as text stays the size it was typed.
                    result += "<mo stretchy=\"false\"\(style)>\(escape(String(character)))</mo>"
                }
            }
        }
        flush()
        return result
    }

    func mathML(color: (RunProperties) -> String?) -> String {
        func row(_ nodes: [MathNode]) -> String { Self.mathML(nodes, color: color) }
        switch self {
        case .run(let run):
            return Self.tokens(run, color: color)
        case .fraction(let kind, let numerator, let denominator):
            switch kind {
            case .bar: return "<mfrac>\(row(numerator))\(row(denominator))</mfrac>"
            case .noBar: return "<mfrac linethickness=\"0\">\(row(numerator))\(row(denominator))</mfrac>"
            case .skewed, .linear: return "<mrow>\(row(numerator))<mo stretchy=\"false\">/</mo>\(row(denominator))</mrow>"
            }
        case .scripts(let base, let sub, let sup, let isBefore):
            if isBefore {
                return "<mmultiscripts>\(row(base))<mprescripts/>\(row(sub ?? []))\(row(sup ?? []))</mmultiscripts>"
            }
            return Self.scripted(row(base), sub: sub.map(row), sup: sup.map(row), names: ("msub", "msup", "msubsup"))
        case .radical(let degree, let radicand):
            if let degree, !degree.isEmpty { return "<mroot>\(row(radicand))\(row(degree))</mroot>" }
            return "<msqrt>\(row(radicand))</msqrt>"
        case .nary(let symbol, let limits, let sub, let sup, let body):
            let isUnderOver = limits == .underOver
            let symbolML = "<mo largeop=\"true\" movablelimits=\"false\">\(Self.escape(symbol))</mo>"
            let names = isUnderOver ? ("munder", "mover", "munderover") : ("msub", "msup", "msubsup")
            return "<mrow>" + Self.scripted(symbolML, sub: sub.map(row), sup: sup.map(row), names: names) + row(body) + "</mrow>"
        case .delimited(let open, let close, let separator, let parts):
            func fence(_ character: String) -> String {
                character.isEmpty ? "" : "<mo fence=\"true\" stretchy=\"true\">\(Self.escape(character))</mo>"
            }
            let middle = separator.isEmpty ? "" : "<mo separator=\"true\" stretchy=\"true\">\(Self.escape(separator))</mo>"
            return "<mrow>" + fence(open) + parts.map(row).joined(separator: middle) + fence(close) + "</mrow>"
        case .matrix(let rows, let alignments, _):
            let lines = rows.map { cells in
                "<mtr>" + cells.enumerated().map { index, cell in
                    let alignment = alignments.indices.contains(index) ? alignments[index] : .center
                    return "<mtd style=\"text-align:\(alignment.rawValue)\">\(row(cell))</mtd>"
                }.joined() + "</mtr>"
            }
            return "<mtable>\(lines.joined())</mtable>"
        case .function(let name, let argument):
            return "<mrow>\(row(name))<mo>\u{2061}</mo>\(row(argument))</mrow>"
        case .limit(let base, let limit, let isUpper):
            let name = isUpper ? "mover" : "munder"
            return "<\(name)>\(row(base))\(row(limit))</\(name)>"
        case .accent(let character, let base):
            return "<mover accent=\"true\">\(row(base))<mo stretchy=\"true\">\(Self.escape(Self.spacingAccent(character)))</mo></mover>"
        case .bar(let base, let isOver):
            return isOver ? "<mover accent=\"true\">\(row(base))<mo stretchy=\"true\">\u{AF}</mo></mover>"
                : "<munder accentunder=\"true\">\(row(base))<mo stretchy=\"true\">_</mo></munder>"
        case .groupCharacter(let character, let isOver, _, let base):
            let name = isOver ? "mover" : "munder"
            return "<\(name)>\(row(base))<mo stretchy=\"true\">\(Self.escape(character))</mo></\(name)>"
        case .box(let isBordered, let content):
            return isBordered ? "<mrow style=\"border:0.06em solid;padding:0.15em\">\(row(content))</mrow>" : row(content)
        case .phantom(let isShown, let content):
            return isShown ? row(content) : "<mphantom>\(row(content))</mphantom>"
        }
    }

    /// A base with whichever of its two scripts it has, in the elements named for one, the other, and both.
    private static func scripted(_ base: String, sub: String?, sup: String?, names: (String, String, String)) -> String {
        switch (sub, sup) {
        case (let sub?, let sup?): "<\(names.2)>\(base)\(sub)\(sup)</\(names.2)>"
        case (let sub?, nil): "<\(names.0)>\(base)\(sub)</\(names.0)>"
        case (nil, let sup?): "<\(names.1)>\(base)\(sup)</\(names.1)>"
        case (nil, nil): base
        }
    }
}
