import CoreText
import Foundation

/// Turns a `TSWP.StorageArchive` into DrawingML paragraphs.
///
/// A storage keeps its text as one string, with tables that say from which
/// character on each paragraph style, character style, list style and list
/// level applies. Character positions count UTF-16 units.
struct KeynoteText {
    let archive: KeynoteArchive
    let styles: KeynoteStyles

    /// One entry of an attribute table: from `start` on, `value` applies.
    private struct Span<Value> {
        let start: Int
        let value: Value
    }

    func plainText(_ storage: KeynoteArchive.Object?) -> String {
        guard let storage else { return "" }
        return Self.clean(storage.message.strings(3).joined())
            .replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    /// The `a:p` elements for a storage, or `nil` when it holds no text.
    func paragraphs(_ storage: KeynoteArchive.Object?) -> String? {
        guard let storage else { return nil }
        let message = storage.message
        let text = Array(message.strings(3).joined().utf16)
        guard !text.isEmpty, !Self.clean(String(decoding: text, as: UTF16.self)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        // A paragraph entry with no style keeps the one before it; a character
        // entry with none ends the character style.
        let paragraphStyles = objectTable(message.message(5), carryingForward: true)
        let listStyles = objectTable(message.message(7), carryingForward: true)
        let characterStyles = objectTable(message.message(8), carryingForward: false)
        let levels = (message.message(6)?.messages(1) ?? []).compactMap { entry -> Span<Int>? in
            guard let start = entry.int(1) else { return nil }
            return Span(start: start, value: entry.int(2) ?? 0)
        }
        return paragraphs(
            text, paragraphStyles: paragraphStyles, listStyles: listStyles, characterStyles: characterStyles, levels: levels
        )
    }

    /// Plain text in one paragraph style, as a table cell holds it. Empty
    /// text still makes a paragraph, so the cell keeps its text size.
    func paragraphs(plain: String, style: UInt64?) -> String {
        paragraphs(
            Array(plain.utf16), paragraphStyles: [Span(start: 0, value: style)],
            listStyles: [], characterStyles: [], levels: []
        )
    }

    private func paragraphs(
        _ text: [UInt16], paragraphStyles: [Span<UInt64?>], listStyles: [Span<UInt64?>],
        characterStyles: [Span<UInt64?>], levels: [Span<Int>]
    ) -> String {
        var result = ""
        var paragraphStart = 0
        while paragraphStart <= text.count {
            var paragraphEnd = paragraphStart
            while paragraphEnd < text.count, !Self.isParagraphBreak(text[paragraphEnd]) { paragraphEnd += 1 }

            let paragraphStyle = value(in: paragraphStyles, at: paragraphStart) ?? nil
            let listStyle = value(in: listStyles, at: paragraphStart) ?? nil
            let level = value(in: levels, at: paragraphStart) ?? 0
            result += "<a:p>" + paragraphProperties(
                paragraphStyle, listStyle: listStyle, level: level, isFirst: paragraphStart == 0
            )

            // Runs break wherever the character style changes.
            var boundaries = Set([paragraphStart, paragraphEnd])
            for span in characterStyles where span.start > paragraphStart && span.start < paragraphEnd {
                boundaries.insert(span.start)
            }
            let points = boundaries.sorted()
            for (start, end) in zip(points, points.dropFirst()) {
                let characterStyle = value(in: characterStyles, at: start) ?? nil
                let properties = runProperties(paragraph: paragraphStyle, character: characterStyle, element: "rPr")
                let pieces = String(decoding: text[start..<end], as: UTF16.self).components(separatedBy: "\u{2028}")
                for (index, piece) in pieces.enumerated() {
                    if index > 0 { result += "<a:br>\(properties)</a:br>" }
                    let cleaned = Self.clean(piece)
                    if !cleaned.isEmpty {
                        result += "<a:r>\(properties)<a:t>\(XMLLite.escape(cleaned))</a:t></a:r>"
                    }
                }
            }
            let endCharacter = value(in: characterStyles, at: max(paragraphEnd - 1, paragraphStart)) ?? nil
            result += runProperties(paragraph: paragraphStyle, character: endCharacter, element: "endParaRPr") + "</a:p>"
            paragraphStart = paragraphEnd + 1
            if paragraphEnd == text.count { break }
        }
        return result
    }

    // MARK: - Tables

    private func objectTable(_ table: ProtoMessage?, carryingForward: Bool) -> [Span<UInt64?>] {
        let entries = (table?.messages(1) ?? []).compactMap { entry -> Span<UInt64?>? in
            guard let start = entry.int(1) else { return nil }
            return Span(start: start, value: entry.reference(2))
        }.sorted { $0.start < $1.start }
        guard carryingForward else { return entries }
        var previous: UInt64?
        return entries.map { entry in
            previous = entry.value ?? previous
            return Span(start: entry.start, value: previous)
        }
    }

    private func value<Value>(in spans: [Span<Value>], at position: Int) -> Value? {
        spans.last { $0.start <= position }?.value
    }

    private static func isParagraphBreak(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2029 || unit == 0x0C || unit == 0x04 || unit == 0x05
    }

    /// Drops attachment markers and control characters, keeping tabs.
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || scalar == "\u{2028}"
                || !(scalar.value < 0x20 || scalar.value == 0xFFFC || (0x7F...0x9F).contains(scalar.value))
        }))
    }

    // MARK: - Paragraphs

    private func paragraphProperty<Value>(_ style: UInt64?, _ read: (ProtoMessage) -> Value?) -> Value? {
        styles.resolve(style) { object in
            object.type == KeynoteType.paragraphStyle ? object.message.message(12).flatMap(read) : nil
        }
    }

    private func paragraphProperties(_ style: UInt64?, listStyle: UInt64?, level: Int, isFirst: Bool) -> String {
        var attributes = ""
        var children = ""

        let alignment = paragraphProperty(style) { $0.int(1) }
        switch alignment {
        case 1: attributes += " algn=\"r\""
        case 2: attributes += " algn=\"ctr\""
        case 3: attributes += " algn=\"just\""
        default: attributes += " algn=\"l\""
        }

        var left = paragraphProperty(style) { $0.float(11) } ?? 0
        var first = paragraphProperty(style) { $0.float(7) } ?? 0
        var bullet = "<a:buNone/>"
        if let listStyle, let listBullet = self.bullet(listStyle, level: level) {
            bullet = listBullet
            // Labels sit at the level's indent; text follows a number of ems later.
            let labelIndent = listValue(listStyle, level: level) { $0.floats(13) } ?? 0
            let textIndent = (listValue(listStyle, level: level) { $0.floats(12) } ?? 0) * fontSize(paragraph: style)
            left += labelIndent + textIndent
            first = -textIndent
        } else {
            first -= left
        }
        if level > 0 { attributes += " lvl=\"\(min(level, 8))\"" }
        attributes += " marL=\"\(KeynoteUnits.emu(left))\" indent=\"\(KeynoteUnits.emu(first))\""

        if let spacing = paragraphProperty(style, { $0.message(13) }) {
            let amount = spacing.float(2) ?? 1
            switch spacing.int(1) ?? 0 {
            case 0: children += "<a:lnSpc><a:spcPct val=\"\(Int((amount * 100_000).rounded()))\"/></a:lnSpc>"
            case 1, 2: children += "<a:lnSpc><a:spcPts val=\"\(Int((amount * 100).rounded()))\"/></a:lnSpc>"
            default: break
            }
        }
        // Keynote leaves no space above the first paragraph.
        if !isFirst, let before = paragraphProperty(style, { $0.float(21) }) {
            children += "<a:spcBef><a:spcPts val=\"\(Int((before * 100).rounded()))\"/></a:spcBef>"
        }
        if let after = paragraphProperty(style, { $0.float(20) }) {
            children += "<a:spcAft><a:spcPts val=\"\(Int((after * 100).rounded()))\"/></a:spcAft>"
        }
        children += bullet
        return "<a:pPr\(attributes)>\(children)</a:pPr>"
    }

    /// A list style's value for `level`, from the first style up the chain
    /// that sets the list. Lists shorter than the level repeat their last value.
    private func listValue<Value>(_ list: UInt64, level: Int, _ read: (ProtoMessage) -> [Value]) -> Value? {
        styles.resolve(list) { object -> Value? in
            guard object.type == KeynoteType.listStyle else { return nil }
            let values = read(object.message)
            return values.indices.contains(level) ? values[level] : values.last
        }
    }

    private func listProperty<Value>(_ list: UInt64, _ read: (ProtoMessage) -> Value?) -> Value? {
        styles.resolve(list) { object in object.type == KeynoteType.listStyle ? read(object.message) : nil }
    }

    private func bullet(_ list: UInt64, level: Int) -> String? {
        let color = listProperty(list) { $0.bool(20) == true ? nil : $0.message(21) }
            .flatMap { KeynoteStyles.colorXML($0) }.map { "<a:buClr>\($0)</a:buClr>" }
        let scale = listValue(list, level: level) { $0.messages(14) }.flatMap { $0.float(1) }
            .map { "<a:buSzPct val=\"\(Int(($0 * 100_000).rounded()))\"/>" } ?? ""
        switch listValue(list, level: level, { $0.uints(11) }) ?? 0 {
        case 2:
            guard let string = listValue(list, level: level, { $0.strings(16) }), !string.isEmpty else { return nil }
            let font = listProperty(list) { $0.bool(22) == true ? nil : $0.string(23) }.map {
                "<a:buFont typeface=\"\(XMLLite.escape(Self.font($0).typeface))\"/>"
            } ?? ""
            return (color ?? "") + scale + font + "<a:buChar char=\"\(XMLLite.escape(string))\"/>"
        case 3:
            let scheme = switch listValue(list, level: level, { $0.uints(15) }) ?? 0 {
            case 1: "arabicParenBoth"
            case 2: "arabicParenR"
            case 3: "romanUcPeriod"
            case 4: "romanUcParenBoth"
            case 5: "romanUcParenR"
            case 6: "romanLcPeriod"
            case 7: "romanLcParenBoth"
            case 8: "romanLcParenR"
            case 9: "alphaUcPeriod"
            case 10: "alphaUcParenBoth"
            case 11: "alphaUcParenR"
            case 12: "alphaLcPeriod"
            case 13: "alphaLcParenBoth"
            case 14: "alphaLcParenR"
            case 48: "circleNumDbPlain"
            default: "arabicPeriod"
            }
            return (color ?? "") + scale + "<a:buAutoNum type=\"\(scheme)\"/>"
        default:
            return nil
        }
    }

    // MARK: - Runs

    /// What Keynote draws text at when no style says otherwise.
    private static let defaultFontSize = 24.0

    private func fontSize(paragraph: UInt64?) -> Double {
        characterProperty(paragraph: paragraph, character: nil) { $0.float(3) } ?? Self.defaultFontSize
    }

    /// Character properties: the character style's chain first, then the
    /// paragraph style's.
    private func characterProperty<Value>(
        paragraph: UInt64?, character: UInt64?, _ read: (ProtoMessage) -> Value?
    ) -> Value? {
        let fromCharacter = styles.resolve(character) { object in
            object.type == KeynoteType.characterStyle ? object.message.message(11).flatMap(read) : nil
        }
        if let fromCharacter { return fromCharacter }
        return styles.resolve(paragraph) { object in
            object.type == KeynoteType.paragraphStyle ? object.message.message(11).flatMap(read) : nil
        }
    }

    private func runProperties(paragraph: UInt64?, character: UInt64?, element: String) -> String {
        func property<Value>(_ read: (ProtoMessage) -> Value?) -> Value? {
            characterProperty(paragraph: paragraph, character: character, read)
        }
        // Keynote writes languages as `en_US`; DrawingML wants `en-US`.
        let language = (property { $0.bool(8) == true ? nil : $0.string(9) } ?? "en-US").replacingOccurrences(of: "_", with: "-")
        var attributes = " lang=\"\(XMLLite.escape(language))\""
        var children = ""
        let size = property { $0.float(3) } ?? Self.defaultFontSize
        attributes += " sz=\"\(Int((size * 100).rounded()))\""

        let fontName = property { $0.bool(4) == true ? nil : $0.string(5) }
        let font = fontName.map(Self.font)
        // An explicit bold or italic flag wins over the face: Keynote keeps the
        // face for its family and draws the flagged style of it.
        let bold = property { $0.bool(1) } ?? font?.bold ?? false
        let italic = property { $0.bool(2) } ?? font?.italic ?? false
        if bold { attributes += " b=\"1\"" }
        if italic { attributes += " i=\"1\"" }
        switch property({ $0.int(11) }) ?? 0 {
        case 1: attributes += " u=\"sng\""
        case 2: attributes += " u=\"dbl\""
        case 3: attributes += " u=\"wavy\""
        default: break
        }
        switch property({ $0.int(12) }) ?? 0 {
        case 0: break
        case 2, 3: attributes += " strike=\"dblStrike\""
        default: attributes += " strike=\"sngStrike\""
        }
        switch property({ $0.int(13) }) ?? 0 {
        case 1: attributes += " cap=\"all\""
        case 2: attributes += " cap=\"small\""
        default: break
        }
        if let tracking = property({ $0.float(27) }), tracking != 0 {
            // Tracking is a fraction of the font size; spacing is in hundredths of a point.
            attributes += " spc=\"\(Int((tracking * size * 100).rounded()))\""
        }
        switch property({ $0.int(10) }) ?? 0 {
        case 1: attributes += " baseline=\"30000\""
        case 2: attributes += " baseline=\"-25000\""
        default: break
        }

        if property({ $0.bool(6) == true ? false : $0.has(7) }) == true {
            children += KeynoteStyles.solidFill(property { $0.bool(6) == true ? nil : $0.message(7) }) ?? ""
        }
        if let highlight = property({ $0.bool(25) == true ? nil : $0.message(26) }),
           let color = KeynoteStyles.colorXML(highlight) {
            children += "<a:highlight>\(color)</a:highlight>"
        }
        if let font {
            let typeface = XMLLite.escape(font.typeface)
            children += "<a:latin typeface=\"\(typeface)\"/><a:ea typeface=\"\(typeface)\"/><a:cs typeface=\"\(typeface)\"/>"
        }
        return "<a:\(element)\(attributes) dirty=\"0\">\(children)</a:\(element)>"
    }

    // MARK: - Fonts

    private static let fontCache = FontNameCache()

    /// Keynote names fonts by PostScript name; DrawingML by family. A face
    /// that is the family's regular, bold or italic becomes the family with
    /// those flags; any other face, such as a light weight, keeps its full
    /// name so it is not drawn as the regular.
    static func font(_ postScriptName: String) -> (typeface: String, bold: Bool, italic: Bool) {
        if let cached = fontCache[postScriptName] { return cached }
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        var result = (typeface: postScriptName, bold: false, italic: false)
        if (CTFontCopyPostScriptName(font) as String) == postScriptName {
            let family = CTFontCopyFamilyName(font) as String
            let traits = CTFontGetSymbolicTraits(font).intersection([.traitBold, .traitItalic])
            let regular = CTFontCreateWithName(family as CFString, 12, nil)
            let styled = traits.isEmpty ? regular : CTFontCreateCopyWithSymbolicTraits(regular, 12, nil, traits, traits)
            if let styled, (CTFontCopyPostScriptName(styled) as String) == postScriptName {
                result = (family, traits.contains(.traitBold), traits.contains(.traitItalic))
            } else {
                result = (CTFontCopyFullName(font) as String, false, false)
            }
        }
        fontCache[postScriptName] = result
        return result
    }
}

private final class FontNameCache: @unchecked Sendable {
    private var values: [String: (typeface: String, bold: Bool, italic: Bool)] = [:]
    private let lock = NSLock()

    subscript(name: String) -> (typeface: String, bold: Bool, italic: Bool)? {
        get { lock.withLock { values[name] } }
        set { lock.withLock { values[name] = newValue } }
    }
}
