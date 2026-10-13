import CoreGraphics
import Foundation

/// Carries what was changed in Dazzle back into the Keynote objects the
/// presentation was converted from.
///
/// Edits are measured against the presentation as it was opened. Those
/// Keynote can be given field by field are: shapes moved, resized or
/// turned; text typed or deleted in a shape or in the speaker notes.
/// Anything else would need objects made or styles changed, so it can't be
/// saved to Keynote at all.
struct KeynoteEditor {
    private let source: KeynoteSource
    private(set) var archive: KeynoteArchive

    /// The archive with every edit made in it, or an error naming what
    /// was changed that Keynote can't be given.
    static func archive(for presentation: Presentation) throws -> KeynoteArchive {
        guard let source = presentation.keynoteSource else { throw KeynoteSaveError.notFromKeynote }
        guard !source.archive.hasZippedIndex else { throw KeynoteSaveError.olderFormat }
        var editor = KeynoteEditor(source: source, archive: source.archive)
        try editor.apply(presentation)
        return editor.archive
    }

    /// Whether every edit made to a presentation opened from Keynote can be
    /// saved back to it.
    static func canSave(_ presentation: Presentation) -> Bool {
        (try? archive(for: presentation)) != nil
    }

    private mutating func apply(_ presentation: Presentation) throws {
        let original = source.original
        // Everything outside the slides must be as it was.
        var outside = presentation
        outside.slides = original.slides
        outside.keynoteSource = original.keynoteSource
        guard outside == original else { throw KeynoteSaveError.unsupportedChange }

        let originals = Dictionary(original.slides.map { ($0.id, $0) }) { first, _ in first }
        guard presentation.slides.map(\.id) == original.slides.map(\.id) else { throw KeynoteSaveError.unsupportedChange }

        for slide in presentation.slides {
            guard let before = originals[slide.id] else { throw KeynoteSaveError.unsupportedChange }
            guard slide != before else { continue }
            guard let origin = source.slides[slide.id] else { throw KeynoteSaveError.unsupportedChange }
            try apply(slide, before: before, origin: origin)
        }
    }

    // MARK: - Slides

    private mutating func apply(_ slide: Slide, before: Slide, origin: KeynoteSlideOrigin) throws {
        // Everything but the shapes and notes must be as it was.
        var rest = slide
        rest.shapes = before.shapes
        rest.notes = before.notes
        rest.isModified = before.isModified
        rest.areNotesModified = before.areNotesModified
        guard rest == before else { throw KeynoteSaveError.unsupportedChange }

        try apply(slide.shapes, before: before.shapes, origin: origin)
        if slide.notes != before.notes {
            guard let storage = origin.notesStorage else { throw KeynoteSaveError.unsupportedChange }
            try editNotes(storage, from: before.notes, to: slide.notes)
        }
    }

    // MARK: - Shapes

    private mutating func apply(_ shapes: [SlideShape], before: [SlideShape], origin: KeynoteSlideOrigin) throws {
        guard shapes.map(\.shapeID) == before.map(\.shapeID) else { throw KeynoteSaveError.unsupportedChange }
        for (shape, old) in zip(shapes, before) where shape != old {
            // Everything but where the shape is and what it says must be as it was.
            var rest = shape
            rest.frame = old.frame
            rest.rotation = old.rotation
            rest.text = old.text
            rest.textFrame = old.textFrame
            rest.hasOwnFrame = old.hasOwnFrame
            rest.edits = old.edits
            if case .group(let group) = shape.kind, case .group(let oldGroup) = old.kind {
                guard group.childFrame == oldGroup.childFrame else { throw KeynoteSaveError.unsupportedChange }
                try apply(group.children, before: oldGroup.children, origin: origin)
                rest.kind = old.kind
            }
            guard rest == old else { throw KeynoteSaveError.unsupportedChange }

            if shape.frame != old.frame || shape.rotation != old.rotation {
                guard let drawable = origin.drawables[shape.shapeID] else { throw KeynoteSaveError.unsupportedChange }
                try transform(drawable, from: old, to: shape)
            }
            if shape.text != old.text {
                guard let storage = origin.textStorages[shape.shapeID], let from = old.text, let to = shape.text else {
                    throw KeynoteSaveError.unsupportedChange
                }
                try editText(storage, from: from, to: to)
            }
        }
    }

    /// Moves, sizes or turns a drawable by as much as its shape was.
    ///
    /// The frame Dazzle shows can differ from the one Keynote saved, as for
    /// text that grows to fit, so the drawable moves by the difference rather
    /// than to the new place.
    private mutating func transform(_ drawable: UInt64, from old: SlideShape, to new: SlideShape) throws {
        guard let object = archive[drawable] else { throw KeynoteSaveError.unsupportedChange }
        // The path down to each kind's `TSD.DrawableArchive`.
        let path: [Int]
        var resizable = true
        switch object.type {
        case KeynoteType.shape: path = [1]
        case KeynoteType.shapeInfo: path = [1, 1]
        case KeynoteType.placeholder: path = [1, 1, 1]
        case KeynoteType.image:
            path = [1]
            // A masked picture's crop would need resizing with it.
            resizable = !object.message.has(5)
        case KeynoteType.group:
            path = [1]
            resizable = false
        default: throw KeynoteSaveError.unsupportedChange
        }
        let resized = new.frame.width != old.frame.width || new.frame.height != old.frame.height
        guard resizable || !resized else { throw KeynoteSaveError.unsupportedChange }

        try edit(drawable) { fields in
            try Self.update(&fields, path: path) { drawable in
                // A placeholder that takes its frame from its template has none to change.
                guard var geometry = drawable.nested(1), geometry.has(1) else { throw KeynoteSaveError.unsupportedChange }
                let message = geometry.message
                let flags = message.uint(3) ?? 3
                let position = message.message(1)
                let x = (position?.float(1) ?? 0) + EMU.points(new.frame.x - old.frame.x)
                let y = (position?.float(2) ?? 0) + EMU.points(new.frame.y - old.frame.y)
                geometry.update(1) { point in
                    point.setFloat(1, Float(x))
                    point.setFloat(2, Float(y))
                }
                // Text that grows to fit is left to grow from its new place
                // when only its height changed, as Dazzle refits it.
                let growsOnly = flags & 2 == 0 && new.frame.width == old.frame.width
                if resized, !growsOnly {
                    geometry.update(2) { size in
                        size.setFloat(1, Float(EMU.points(new.frame.width)))
                        size.setFloat(2, Float(EMU.points(new.frame.height)))
                    }
                    geometry.setVarint(3, flags | 3)
                }
                if new.rotation != old.rotation {
                    // Keynote turns anticlockwise; Dazzle clockwise.
                    var angle = (-new.rotation).truncatingRemainder(dividingBy: 360)
                    if angle < 0 { angle += 360 }
                    geometry.setFloat(4, Float(angle))
                }
                drawable.setBytes(1, geometry.bytes)
            }
        }
    }

    private static func update(_ fields: inout ProtoFields, path: [Int], _ change: (inout ProtoFields) throws -> Void) throws {
        guard let first = path.first else { return try change(&fields) }
        guard fields.has(first) else { throw KeynoteSaveError.unsupportedChange }
        try fields.update(first) { try update(&$0, path: Array(path.dropFirst()), change) }
    }

    // MARK: - Text

    private mutating func editText(_ storage: UInt64, from old: TextBody, to new: TextBody) throws {
        guard let fields = archive.fields(storage) else { throw KeynoteSaveError.unsupportedChange }
        try archive.replace(storage, with: KeynoteTextEdit.edit(fields, from: old, to: new))
    }

    private mutating func editNotes(_ storage: UInt64, from old: String, to new: String) throws {
        guard let fields = archive.fields(storage) else { throw KeynoteSaveError.unsupportedChange }
        try archive.replace(storage, with: KeynoteTextEdit.editPlain(fields, from: old, to: new))
    }

    // MARK: - Objects

    private mutating func edit(_ identifier: UInt64, _ change: (inout ProtoFields) throws -> Void) throws {
        guard var fields = archive.fields(identifier) else { throw KeynoteSaveError.unsupportedChange }
        try change(&fields)
        try archive.replace(identifier, with: fields)
    }
}
