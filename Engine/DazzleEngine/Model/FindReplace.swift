import Foundation

/// Finding text across a presentation, and replacing it while keeping the
/// formatting of the text it replaces.
public struct FindQuery: Equatable, Sendable {
    public var text: String
    public var matchesCase = false
    public var matchesWholeWords = false

    /// Where `text` occurs in `string`, as UTF-16 ranges.
    public func ranges(in string: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let haystack = string as NSString
        var options: NSString.CompareOptions = []
        if !matchesCase { options.insert(.caseInsensitive) }
        var result: [NSRange] = []
        var location = 0
        while location < haystack.length {
            let found = haystack.range(of: text, options: options, range: NSRange(location: location, length: haystack.length - location))
            guard found.location != NSNotFound else { break }
            if !matchesWholeWords || Self.isWholeWord(found, in: haystack) { result.append(found) }
            location = found.location + max(found.length, 1)
        }
        return result
    }

    private static func isWholeWord(_ range: NSRange, in string: NSString) -> Bool {
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < string.length,
                  let scalar = UnicodeScalar(string.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return !isWordCharacter(at: range.location - 1) && !isWordCharacter(at: range.location + range.length)
    }

    public init(text: String, matchesCase: Bool = false, matchesWholeWords: Bool = false) {
        self.text = text
        self.matchesCase = matchesCase
        self.matchesWholeWords = matchesWholeWords
    }
}

/// One place the query was found.
public struct FindMatch: Identifiable, Equatable, Sendable {
    public enum Place: Equatable, Hashable, Sendable {
        case shape(SlideShape.ID)
        case cell(SlideShape.ID, TableCellPosition)
        case notes
    }

    public var slideID: Slide.ID
    public var place: Place
    /// In the text's editing offsets: paragraphs joined by line breaks.
    public var range: NSRange
    /// The match with a little of the text round it.
    public var excerpt: String
    /// Where the match starts in `excerpt`.
    public var excerptRange: NSRange

    public var id: String { "\(slideID)|\(place)|\(range.location)" }
}

extension TextBody {
    /// The text as matched against: paragraphs joined by line breaks, the
    /// same offsets formatting by range uses.
    public var searchableText: String { paragraphs.map(\.plainText).joined(separator: "\n") }

    /// Replaces the text in `range`, which lies within one paragraph, with
    /// `replacement` in the formatting of the text's first character.
    public mutating func replace(_ range: NSRange, with replacement: String) {
        var offset = 0
        for index in paragraphs.indices {
            let length = paragraphs[index].editingLength
            defer { offset += length + 1 }
            guard range.location >= offset, range.location + range.length <= offset + length else { continue }
            let start = range.location - offset
            paragraphs[index].split(at: start)
            paragraphs[index].split(at: start + range.length)
            var position = 0
            var kept: [TextRun] = []
            var inserted = false
            for run in paragraphs[index].runs {
                let runLength = run.editingLength
                defer { position += runLength }
                guard position >= start, position + runLength <= start + range.length, runLength > 0 else {
                    kept.append(run)
                    continue
                }
                if !inserted {
                    var replaced = run
                    replaced.kind = .text
                    replaced.text = replacement
                    replaced.fieldID = nil
                    if !replacement.isEmpty { kept.append(replaced) }
                    inserted = true
                }
            }
            paragraphs[index].runs = kept
            return
        }
    }
}

extension SlideShape {
    /// Runs `body` on the text of the shape with `id`, searching inside groups
    /// as well as at the top level. Returns true when a shape was found and
    /// edited.
    @discardableResult
    public mutating func editText(of id: ID, _ body: (inout TextBody) -> Void) -> Bool {
        if self.id == id {
            guard var text else { return false }
            body(&text)
            self.text = text
            edits.insert(.text)
            return true
        }
        guard case .group(var group) = kind else { return false }
        for index in group.children.indices where group.children[index].editText(of: id, body) {
            kind = .group(group)
            return true
        }
        return false
    }

    /// Runs `body` on the text of the table cell at `position` in the table
    /// shape with `id`, searching inside groups as well as at the top level.
    @discardableResult
    public mutating func editCell(of id: ID, _ position: TableCellPosition, _ body: (inout TextBody) -> Void) -> Bool {
        if self.id == id {
            guard case .table(var table) = kind, table.cell(at: position) != nil else { return false }
            if var text = table.rows[position.row].cells[position.column].text {
                body(&text)
                table.rows[position.row].cells[position.column].text = text
            }
            kind = .table(table)
            edits.insert(.table)
            return true
        }
        guard case .group(var group) = kind else { return false }
        for index in group.children.indices where group.children[index].editCell(of: id, position, body) {
            kind = .group(group)
            return true
        }
        return false
    }
}

extension Slide {
    public func topLevelShapeID(containing id: SlideShape.ID) -> SlideShape.ID? {
        shapes.first { $0.flattened.contains { $0.id == id } }?.id
    }
}

extension Presentation {
    /// Every match, slide by slide: shapes in stacking order, then table
    /// cells, then the speaker notes.
    public func matches(for query: FindQuery) -> [FindMatch] {
        var matches: [FindMatch] = []
        for slide in slides {
            func add(_ text: String, place: FindMatch.Place) {
                for range in query.ranges(in: text) {
                    let (excerpt, excerptRange) = Self.excerpt(of: text, around: range)
                    matches.append(FindMatch(slideID: slide.id, place: place, range: range, excerpt: excerpt, excerptRange: excerptRange))
                }
            }
            // Groups hold their members' text too: walk into them, depth first.
            func walk(_ shapes: [SlideShape]) {
                for shape in shapes where shape.isEditable {
                    if let text = shape.text { add(text.searchableText, place: .shape(shape.id)) }
                    if case .table(let table) = shape.kind {
                        for (row, cells) in table.rows.enumerated() {
                            for (column, cell) in cells.cells.enumerated() where !cell.isMerged {
                                if let text = cell.text {
                                    add(text.searchableText, place: .cell(shape.id, TableCellPosition(row: row, column: column)))
                                }
                            }
                        }
                    }
                    if case .group(let group) = shape.kind { walk(group.children) }
                }
            }
            walk(slide.shapes)
            add(slide.notes, place: .notes)
        }
        return matches
    }

    /// Replaces each of `matches` with `replacement`, as one change.
    public mutating func replace(_ matches: [FindMatch], with replacement: String) {
        // From the end of each text backwards, so earlier offsets stay true.
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            guard let slideIndex = index(of: match.slideID) else { continue }
            switch match.place {
            case .notes:
                let notes = slides[slideIndex].notes as NSString
                guard match.range.location + match.range.length <= notes.length else { continue }
                slides[slideIndex].notes = notes.replacingCharacters(in: match.range, with: replacement)
                slides[slideIndex].areNotesModified = true
            case .shape(let id):
                guard slides[slideIndex].canEditShapes else { continue }
                for shapeIndex in slides[slideIndex].shapes.indices
                where slides[slideIndex].shapes[shapeIndex].editText(of: id, { $0.replace(match.range, with: replacement) }) {
                    slides[slideIndex].isModified = true
                    break
                }
            case .cell(let id, let position):
                guard slides[slideIndex].canEditShapes else { continue }
                for shapeIndex in slides[slideIndex].shapes.indices
                where slides[slideIndex].shapes[shapeIndex].editCell(of: id, position, { $0.replace(match.range, with: replacement) }) {
                    slides[slideIndex].isModified = true
                    break
                }
            }
        }
    }

    private static func excerpt(of text: String, around range: NSRange) -> (String, NSRange) {
        let string = text as NSString
        let start = max(range.location - 24, 0)
        let end = min(range.location + range.length + 40, string.length)
        var excerpt = string.substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: "\n", with: " ")
        var offset = range.location - start
        if start > 0 {
            excerpt = "…" + excerpt
            offset += 1
        }
        if end < string.length { excerpt += "…" }
        return (excerpt, NSRange(location: offset, length: range.length))
    }
}
