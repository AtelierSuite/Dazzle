import Foundation

/// Writes text edited in Dazzle back into the `TSWP.StorageArchive` it was
/// read from.
///
/// A storage keeps its text as one string, and its formatting as tables
/// that each say from which character on something applies. Text typed or
/// deleted moves every entry after it along, and a paragraph broken in two
/// gives the new one the formatting of the paragraph it came out of, which
/// is what Keynote itself does. Edits that would need formatting Keynote
/// doesn't have at that point, such as text pasted in another style, can't
/// be written, and neither can deleting a picture or other object set in
/// the text.
enum KeynoteTextEdit {
    /// Tables keyed by where each paragraph starts.
    private static let paragraphTables: Set<Int> = [5, 6, 7, 9, 11, 14, 24, 28]
    /// Tables keyed by character.
    private static let characterTables: Set<Int> = [8, 18, 19, 20]

    private static let paragraphBreak: UInt16 = 0x0A
    private static let lineBreak: UInt16 = 0x2028

    /// One run of text replaced, in the storage's own positions.
    private struct Hunk {
        var start: Int
        var end: Int
        var replacement: [UInt16]
        /// Whether what is put in takes the formatting of the character
        /// after it, rather than of the one before.
        var takesFollowing: Bool
    }

    // MARK: - Shape text

    static func edit(_ storage: ProtoFields, from old: TextBody, to new: TextBody) throws -> ProtoFields {
        guard new.properties == old.properties, new.listStyle == old.listStyle,
              !new.paragraphs.contains(where: { $0.runs.contains { if case .field = $0.kind { true } else { false } } })
        else { throw KeynoteSaveError.unsupportedChange }
        let text = units(storage)
        let visible = visibleMap(text, isVisible: { !isHidden($0) }, display: { isParagraphBreak($0) ? paragraphBreak : $0 })
        let before = characters(old)
        let after = characters(new)
        // The text as Dazzle has it must be the storage's, or the two can't be matched.
        guard before.units == visible.units else { throw KeynoteSaveError.unsupportedChange }

        var hunks: [Hunk] = []
        for change in changes(from: before.units, to: after.units) {
            // What stayed must look as it did.
            for (oldIndex, newIndex) in change.kept where before.runs[oldIndex] != after.runs[newIndex] {
                throw KeynoteSaveError.unsupportedChange
            }
            guard let range = change.range else { continue }
            let inserted = after.units[range.new]
            let insertedRuns = range.new.filter { after.units[$0] != paragraphBreak }.map { after.runs[$0] }
            var takesFollowing = true
            if let first = insertedRuns.first {
                guard insertedRuns.allSatisfy({ $0 == first }) else { throw KeynoteSaveError.unsupportedChange }
                let preceding = range.old.lowerBound > 0 ? range.old.lowerBound - 1 : nil
                let following = range.old.upperBound
                if let preceding, before.units[preceding] != paragraphBreak, before.runs[preceding] == first {
                    takesFollowing = false
                } else if following < before.units.count, before.units[following] != paragraphBreak {
                    guard before.runs[following] == first else { throw KeynoteSaveError.unsupportedChange }
                } else {
                    // An empty end of a paragraph: text typed there looks as its end does.
                    guard before.paragraphEnd(at: range.old.lowerBound) == first else { throw KeynoteSaveError.unsupportedChange }
                }
            }
            hunks.append(try hunk(range.old, inserted: Array(inserted), in: visible, count: text.count, takesFollowing: takesFollowing))
        }
        try checkParagraphs(before: before, after: after, old: old, new: new)
        return try apply(hunks, to: storage, text: text)
    }

    /// A paragraph that was there keeps its formatting; one made by a new
    /// break takes the formatting of the paragraph it was broken out of.
    private static func checkParagraphs(before: Characters, after: Characters, old: TextBody, new: TextBody) throws {
        // The old paragraph each new one carries on.
        var sources = [0: 0]
        for change in changes(from: before.units, to: after.units) {
            for (oldIndex, newIndex) in change.kept where after.units[newIndex] == paragraphBreak {
                sources[after.paragraph(at: newIndex) + 1] = before.paragraph(at: oldIndex) + 1
            }
            guard let range = change.range else { continue }
            for index in range.new where after.units[index] == paragraphBreak {
                sources[after.paragraph(at: index) + 1] = before.paragraph(at: range.old.lowerBound)
            }
        }
        for (index, paragraph) in new.paragraphs.enumerated() {
            guard let source = sources[index], old.paragraphs.indices.contains(source),
                  old.paragraphs[source].properties == paragraph.properties else { throw KeynoteSaveError.unsupportedChange }
        }
    }

    // MARK: - Notes

    /// Speaker notes, which Dazzle keeps as plain text with the storage's
    /// leading and trailing space trimmed away.
    static func editPlain(_ storage: ProtoFields, from old: String, to new: String) throws -> ProtoFields {
        let text = units(storage)
        let visible = visibleMap(
            text,
            isVisible: { unit in
                !(unit == 0xFFFC || (0x7F...0x9F).contains(unit) || (unit < 0x20 && unit != 0x09 && unit != 0x0A))
            },
            display: { $0 == lineBreak ? paragraphBreak : $0 }
        )
        let full = String(decoding: visible.units, as: UTF16.self)
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == old, let range = full.range(of: trimmed) ?? (trimmed.isEmpty ? full.startIndex..<full.startIndex : nil)
        else { throw KeynoteSaveError.unsupportedChange }
        let replaced = String(full[..<range.lowerBound]) + new + String(full[range.upperBound...])
        var hunks: [Hunk] = []
        for change in changes(from: visible.units, to: Array(replaced.utf16)) {
            guard let span = change.range else { continue }
            hunks.append(try hunk(
                span.old, inserted: Array(Array(replaced.utf16)[span.new]), in: visible, count: text.count, takesFollowing: false
            ))
        }
        return try apply(hunks, to: storage, text: text)
    }

    // MARK: - Characters

    /// The text as Dazzle shows it, with the formatting of each character.
    private struct Characters {
        var units: [UInt16] = []
        var runs: [RunProperties?] = []
        /// Where each paragraph begins.
        var paragraphStarts: [Int] = []
        var ends: [RunProperties?] = []

        func paragraph(at index: Int) -> Int {
            (paragraphStarts.lastIndex { $0 <= index } ?? 0)
        }

        func paragraphEnd(at index: Int) -> RunProperties? {
            ends[paragraph(at: index)]
        }
    }

    private static func characters(_ body: TextBody) -> Characters {
        var result = Characters()
        for (index, paragraph) in body.paragraphs.enumerated() {
            if index > 0 {
                result.units.append(paragraphBreak)
                result.runs.append(nil)
            }
            result.paragraphStarts.append(result.units.count)
            result.ends.append(paragraph.endProperties)
            for run in paragraph.runs {
                let units = Array(run.text.utf16)
                result.units += units
                result.runs += Array(repeating: run.properties, count: units.count)
            }
        }
        return result
    }

    // MARK: - Storage

    private static func units(_ storage: ProtoFields) -> [UInt16] {
        Array(storage.all(3).map { String(decoding: $0, as: UTF8.self) }.joined().utf16)
    }

    private static func isParagraphBreak(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2029 || unit == 0x0C || unit == 0x04 || unit == 0x05
    }

    /// What the import leaves out: attachment markers and control characters.
    private static func isHidden(_ unit: UInt16) -> Bool {
        guard !isParagraphBreak(unit) else { return false }
        return (unit < 0x20 && unit != 0x09) || unit == 0xFFFC || (0x7F...0x9F).contains(unit)
    }

    /// The characters that are shown, and where each one is in the storage.
    private struct VisibleMap {
        var units: [UInt16] = []
        var positions: [Int] = []
    }

    private static func visibleMap(_ text: [UInt16], isVisible: (UInt16) -> Bool, display: (UInt16) -> UInt16) -> VisibleMap {
        var map = VisibleMap()
        for (position, unit) in text.enumerated() where isVisible(unit) {
            map.units.append(display(unit))
            map.positions.append(position)
        }
        return map
    }

    /// A run of shown characters replaced, as a run of the storage replaced.
    /// Nothing hidden may be deleted along with it.
    private static func hunk(
        _ range: Range<Int>, inserted: [UInt16], in map: VisibleMap, count: Int, takesFollowing: Bool
    ) throws -> Hunk {
        let start: Int
        let end: Int
        if range.isEmpty {
            start = range.lowerBound < map.positions.count ? map.positions[range.lowerBound]
                : (map.positions.last.map { $0 + 1 } ?? count)
            end = start
        } else {
            start = map.positions[range.lowerBound]
            end = map.positions[range.upperBound - 1] + 1
            guard end - start == range.count else { throw KeynoteSaveError.unsupportedChange }
        }
        return Hunk(start: start, end: end, replacement: inserted, takesFollowing: takesFollowing)
    }

    /// Applies hunks from the last to the first, so each one's positions
    /// still hold when it is reached.
    private static func apply(_ hunks: [Hunk], to storage: ProtoFields, text: [UInt16]) throws -> ProtoFields {
        guard !hunks.isEmpty else { return storage }
        var storage = storage
        var text = text
        // Every table must be one Dazzle knows how to move along.
        var tables: [Int: [ProtoFields]] = [:]
        var dense: Set<Int> = []
        let starts = Set([0] + text.indices.filter { isParagraphBreak(text[$0]) }.map { $0 + 1 }.filter { $0 < text.count })
        for field in storage.fields where field.number >= 5 && field.wireType == 2 {
            guard let table = try? ProtoFields(field.value) else { continue }
            let entries = try table.all(1).map { try ProtoFields($0) }
            guard !entries.isEmpty else { continue }
            guard paragraphTables.contains(field.number) || characterTables.contains(field.number),
                  entries.allSatisfy({ $0.uint(1) != nil }) else { throw KeynoteSaveError.unsupportedChange }
            tables[field.number] = entries
            if paragraphTables.contains(field.number), starts.isSubset(of: Set(entries.compactMap { $0.uint(1) }.map(Int.init))) {
                dense.insert(field.number)
            }
        }

        for hunk in hunks.sorted(by: { $0.start > $1.start }) {
            text.replaceSubrange(hunk.start..<hunk.end, with: hunk.replacement)
            let delta = hunk.replacement.count - (hunk.end - hunk.start)
            let newEnd = hunk.start + hunk.replacement.count
            for (number, entries) in tables {
                tables[number] = paragraphTables.contains(number)
                    ? moveParagraphs(entries, hunk: hunk, delta: delta, isDense: dense.contains(number))
                    : moveCharacters(entries, hunk: hunk, delta: delta, newEnd: newEnd)
            }
        }

        storage.setRepeatedBytes(3, [Array(String(decoding: text, as: UTF16.self).utf8)])
        for (number, entries) in tables {
            storage.update(number) { $0.setRepeatedBytes(1, entries.map(\.bytes)) }
        }
        return storage
    }

    private static func index(_ entry: ProtoFields) -> Int { Int(entry.uint(1) ?? 0) }

    private static func at(_ entry: ProtoFields, _ position: Int) -> ProtoFields {
        var entry = entry
        entry.setVarint(1, UInt64(position))
        return entry
    }

    /// Paragraphs whose breaks were deleted are gone; those after move along;
    /// a break put in starts a paragraph formatted as the one it is in.
    private static func moveParagraphs(_ entries: [ProtoFields], hunk: Hunk, delta: Int, isDense: Bool) -> [ProtoFields] {
        var result: [ProtoFields] = []
        let containing = entries.last { index($0) <= hunk.start }
        for entry in entries {
            let position = index(entry)
            if position <= hunk.start {
                result.append(entry)
            } else if position > hunk.end {
                result.append(at(entry, position + delta))
            }
        }
        if isDense, let containing {
            for (offset, unit) in hunk.replacement.enumerated() where isParagraphBreak(unit) {
                result.append(at(containing, hunk.start + offset + 1))
            }
        }
        return result.sorted { index($0) < index($1) }
    }

    /// Characters after the edit move along. Formatting that began inside
    /// what was replaced begins where the replacement ends, or where it
    /// starts if the replacement takes the formatting that follows it.
    private static func moveCharacters(_ entries: [ProtoFields], hunk: Hunk, delta: Int, newEnd: Int) -> [ProtoFields] {
        var result: [ProtoFields] = []
        var collapsed: ProtoFields?
        for entry in entries {
            let position = index(entry)
            if position < hunk.start {
                result.append(entry)
            } else if position <= hunk.end {
                collapsed = entry
            } else {
                result.append(at(entry, position + delta))
            }
        }
        if let collapsed {
            result.append(at(collapsed, hunk.takesFollowing || hunk.start == 0 ? hunk.start : newEnd))
        }
        return result.sorted { index($0) < index($1) }
    }

    // MARK: - Differences

    /// A stretch of the old text and of the new one: either kept, character
    /// for character, or replaced.
    private struct Change {
        var kept: [(Int, Int)] = []
        var range: (old: Range<Int>, new: Range<Int>)?
    }

    private static func changes(from old: [UInt16], to new: [UInt16]) -> [Change] {
        let difference = new.difference(from: old)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Change] = []
        var kept = Change()
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if removed.contains(oldIndex) || inserted.contains(newIndex) {
                let oldStart = oldIndex
                let newStart = newIndex
                while removed.contains(oldIndex) || inserted.contains(newIndex) {
                    while removed.contains(oldIndex) { oldIndex += 1 }
                    while inserted.contains(newIndex) { newIndex += 1 }
                }
                if !kept.kept.isEmpty { result.append(kept) }
                kept = Change()
                result.append(Change(range: (oldStart..<oldIndex, newStart..<newIndex)))
            } else {
                kept.kept.append((oldIndex, newIndex))
                oldIndex += 1
                newIndex += 1
            }
        }
        if !kept.kept.isEmpty { result.append(kept) }
        return result
    }
}
