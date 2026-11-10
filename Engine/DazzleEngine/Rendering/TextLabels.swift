import Foundation

/// What text shows that isn't its characters: bullets, list numbers, and
/// symbol-font characters, worked out the same way wherever text is drawn.
public enum TextLabels {
    /// Wingdings and Symbol bullets name private-use glyphs; draw the
    /// common ones as the characters they look like.
    public static func displayable(_ bullet: String) -> String {
        // Symbol fonts are often written in the private use area, U+F0xx,
        // standing for the font's own character xx.
        if let scalar = bullet.unicodeScalars.first, bullet.unicodeScalars.count == 1,
           (0xF000...0xF0FF).contains(scalar.value) {
            let symbol = String(UnicodeScalar(UInt8(scalar.value - 0xF000)))
            let mapped = displayable(symbol)
            return mapped == symbol ? "•" : mapped
        }
        return switch bullet {
        case "§": "■"
        case "Ø": "➢"
        case "ü": "✓"
        case "û": "✗"
        case "à": "→"
        case "è": "➔"
        case "q", "o": "◦"
        case "Ÿ", "·": "•"
        case "n": "■"
        case "l": "●"
        case "v": "❖"
        case "": "•"
        default: bullet
        }
    }

    /// Run text in a symbol font can carry the same private-use characters
    /// as bullets do; those are drawn as what they look like, the rest left be.
    public static func symbolsMapped(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0xF000...0xF0FF).contains($0.value) }) else { return text }
        var result = ""
        for scalar in text.unicodeScalars {
            if (0xF000...0xF0FF).contains(scalar.value) {
                result += displayable(String(scalar))
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    public static func numberLabel(_ number: Int, scheme: String) -> String {
        let core: String
        if scheme.hasPrefix("alphaLc") {
            core = alphabetic(number, uppercase: false)
        } else if scheme.hasPrefix("alphaUc") {
            core = alphabetic(number, uppercase: true)
        } else if scheme.hasPrefix("romanLc") {
            core = roman(number).lowercased()
        } else if scheme.hasPrefix("romanUc") {
            core = roman(number)
        } else {
            core = String(number)
        }
        if scheme.hasSuffix("ParenBoth") { return "(\(core))" }
        if scheme.hasSuffix("ParenR") { return "\(core))" }
        if scheme.hasSuffix("Plain") { return core }
        return "\(core)."
    }

    private static func alphabetic(_ number: Int, uppercase: Bool) -> String {
        let letter = Character(UnicodeScalar(UInt8((number - 1) % 26) + (uppercase ? 65 : 97)))
        return String(repeating: letter, count: (number - 1) / 26 + 1)
    }

    private static func roman(_ number: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var remaining = max(number, 1)
        var result = ""
        for (value, numeral) in table {
            while remaining >= value {
                result += numeral
                remaining -= value
            }
        }
        return result
    }
}

/// The date and time fields PowerPoint fills in as the slide is shown,
/// by the `type` each writes.
public enum DateField: String, CaseIterable, Identifiable, Sendable {
    case datetime1, datetime2, datetime3, datetime4, datetime5, datetime6, datetime7
    case datetime8, datetime9, datetime10, datetime11, datetime12, datetime13

    public var id: Self { self }

    /// The pattern each shows, as a template the locale arranges.
    private var template: String {
        switch self {
        case .datetime1: "yMd"
        case .datetime2: "EEEEyMMMMd"
        case .datetime3: "dMMMMy"
        case .datetime4: "MMMMdy"
        case .datetime5: "dMMMyy"
        case .datetime6: "MMMMyy"
        case .datetime7: "MMMyy"
        case .datetime8: "yMdjmm"
        case .datetime9: "yMdjmmss"
        case .datetime10: "Hmm"
        case .datetime11: "Hmmss"
        case .datetime12: "hmma"
        case .datetime13: "hmmssa"
        }
    }

    public func string(for date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
