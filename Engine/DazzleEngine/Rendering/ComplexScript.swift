import Foundation

/// The scripts PowerPoint sets in a run's complex-script typeface (`a:cs`)
/// rather than its Latin one: Arabic, Hebrew, Thai, the Indic scripts and
/// the others whose letters join, stack or reorder.
public enum ComplexScript {
    /// A stretch of a run's text in a complex script.
    public struct Stretch: Equatable, Sendable {
        /// Where it lies in the text, in UTF-16 code units.
        public var range: Range<Int>
        /// The script's code as a theme's `a:font` names it, such as `Arab`.
        public var script: String

        public init(range: Range<Int>, script: String) {
            self.range = range
            self.script = script
        }
    }

    private static let blocks: [(ClosedRange<UInt32>, String)] = [
        (0x0590...0x05FF, "Hebr"), (0x0600...0x06FF, "Arab"), (0x0700...0x074F, "Syrc"), (0x0750...0x077F, "Arab"),
        (0x0780...0x07BF, "Thaa"), (0x0860...0x086F, "Syrc"), (0x0870...0x08FF, "Arab"),
        (0x0900...0x097F, "Deva"), (0x0980...0x09FF, "Beng"), (0x0A00...0x0A7F, "Guru"), (0x0A80...0x0AFF, "Gujr"),
        (0x0B00...0x0B7F, "Orya"), (0x0B80...0x0BFF, "Taml"), (0x0C00...0x0C7F, "Telu"), (0x0C80...0x0CFF, "Knda"),
        (0x0D00...0x0D7F, "Mlym"), (0x0D80...0x0DFF, "Sinh"), (0x0E00...0x0E7F, "Thai"), (0x0E80...0x0EFF, "Laoo"),
        (0x0F00...0x0FFF, "Tibt"), (0x1000...0x109F, "Mymr"), (0x1780...0x17FF, "Khmr"), (0x1800...0x18AF, "Mong"),
        (0x19E0...0x19FF, "Khmr"), (0xA8E0...0xA8FF, "Deva"), (0xFB1D...0xFB4F, "Hebr"), (0xFB50...0xFDFF, "Arab"),
        (0xFE70...0xFEFF, "Arab"), (0x1EE00...0x1EEFF, "Arab"),
    ]

    /// The complex script a character belongs to, or nil for Latin, East
    /// Asian and everything else set in the other typefaces.
    public static func script(of scalar: Unicode.Scalar) -> String? {
        let value = scalar.value
        guard value >= 0x0590, value != 0xFEFF else { return nil }
        return blocks.first { $0.0.contains(value) }?.1
    }

    /// Whether any of `text` is in a complex script.
    public static func isUsed(in text: String) -> Bool {
        text.unicodeScalars.contains { script(of: $0) != nil }
    }

    /// The stretches of `text` in complex scripts. Spaces, punctuation and
    /// marks between two of a script's letters, or after the last of the
    /// text's, go with them; digits and anything else stay as they were.
    public static func stretches(in text: String) -> [Stretch] {
        var result: [Stretch] = []
        var open: (start: Int, end: Int, script: String)?
        // Where the neutral characters after the open stretch have reached.
        var reach = 0
        var offset = 0
        func close() {
            if let stretch = open { result.append(Stretch(range: stretch.start..<stretch.end, script: stretch.script)) }
            open = nil
        }
        for scalar in text.unicodeScalars {
            let next = offset + (scalar.value > 0xFFFF ? 2 : 1)
            defer { offset = next }
            if let script = script(of: scalar) {
                if let stretch = open, stretch.script == script {
                    open = (stretch.start, next, script)
                } else {
                    close()
                    open = (offset, next, script)
                }
                reach = next
            } else if open != nil, isNeutral(scalar) {
                reach = next
            } else {
                close()
            }
        }
        if let stretch = open { open = (stretch.start, max(stretch.end, reach), stretch.script) }
        close()
        return result
    }

    /// Whether a character takes the direction and typeface of what it
    /// stands among: spaces, punctuation, marks and formatting characters.
    private static func isNeutral(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return scalar != "\n" && scalar != "\t" }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }
}
