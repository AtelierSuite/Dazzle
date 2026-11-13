import DazzleEngine
import Foundation

/// Putting copies of shapes and slides into a presentation, from the same
/// one or another. The clipboard (Clipboard.swift) decides what to paste;
/// this is how it goes in, on every platform.
extension EditorState {
    /// Puts copies of `shapes`, from `slide` in `source`, on the slide being edited.
    func pasteShapes(_ shapes: [SlideShape], from slide: Slide, of source: Presentation, into presentation: inout Presentation) {
        let index = selectedIndex(in: presentation)
        guard presentation.slides.indices.contains(index), presentation.slides[index].canEditShapes else { return }
        var target = presentation.slides[index]
        var importer = PartImporter(from: source, into: presentation)
        let isSameSlide = importer.sharesPackage && slide.id == target.id
        let sourceStyle = SlideStyleContext(presentation: source, slide: slide)
        var nextID = target.nextShapeID
        var pasted: [SlideShape] = []

        for original in shapes {
            var shape = isSameSlide ? original : importer.transplant(
                original, from: slide, into: &target.relationships,
                targetPart: target.partName ?? PartImporter.newSlidePart
            )
            shape = SlideShape(copying: shape)
            shape.shapeID = nextID
            nextID += 1
            // A placeholder stays one only where the slide has a place for it.
            if let placeholder = shape.placeholder {
                let layoutHasIt = presentation.layout(for: target)?.shapes.inheritedPlaceholder(for: placeholder) != nil
                let slideHasOne = (target.shapes + pasted).contains { $0.placeholder.map { placeholder.matches($0, byIndex: false) } ?? false }
                if !layoutHasIt || slideHasOne {
                    shape = Self.detached(shape, sources: sourceStyle.sources(for: original), style: sourceStyle)
                }
            }
            // Pasted where it came from, a copy steps aside so it shows.
            if (target.shapes + pasted).contains(where: { $0.frame == shape.frame }) {
                shape.frame.x += 182_880
                shape.frame.y += 182_880
            }
            shape.hasOwnFrame = true
            shape.edits.formUnion([.transform, .identity])
            pasted.append(shape)
        }

        // Pasted connectors join the shapes pasted with them.
        pasted.reconnect(Dictionary(zip(shapes.map(\.shapeID), pasted.map(\.shapeID))) { first, _ in first })
        target.shapes.append(contentsOf: pasted)
        target.isModified = true
        presentation.addedParts = importer.target.addedParts
        presentation.addedContentTypes = importer.target.addedContentTypes
        presentation.slides[index] = target
        selectedShapeIDs = pasted.map(\.id)
        isSelectingMultiple = pasted.count > 1
    }

    /// A placeholder made an ordinary shape, keeping the look it inherited.
    private static func detached(_ shape: SlideShape, sources: [SlideShape], style: SlideStyleContext) -> SlideShape {
        var shape = shape
        if var body = shape.text {
            for index in body.paragraphs.indices {
                let level = body.paragraphs[index].properties.level ?? 0
                let base = style.paragraphBase(for: shape, sources: sources, level: level)
                let effective = body.paragraphs[index].properties.merged(over: base)
                body.paragraphs[index].properties.alignment = effective.alignment
                func resolved(_ run: RunProperties) -> RunProperties {
                    var run = run.merged(over: effective.defaultRun)
                    run.latinFont = style.typeface(run.latinFont)
                    return run
                }
                for run in body.paragraphs[index].runs.indices {
                    body.paragraphs[index].runs[run].properties = resolved(body.paragraphs[index].runs[run].properties)
                }
                body.paragraphs[index].endProperties = resolved(body.paragraphs[index].endProperties ?? RunProperties())
            }
            shape.text = body
            shape.edits.insert(.text)
        }
        shape.placeholder = nil
        shape.edits.insert(.placeholder)
        return shape
    }

    /// Puts copies of `slides`, from `source`, after the slide being edited.
    func pasteSlides(_ slides: [Slide], from source: Presentation, into presentation: inout Presentation) {
        // Slides go among slides, never among the masters and layouts, nor those among slides.
        guard !presentation.isInMasterView, !source.isInMasterView else { return }
        var importer = PartImporter(from: source, into: presentation)
        var position = min(selectedIndex(in: presentation) + 1, presentation.slides.count)
        var lastID: Slide.ID?
        for slide in slides {
            let copy = importer.sharesPackage
                ? Self.duplicate(of: slide)
                : Self.imported(slide, from: source, into: presentation, using: &importer)
            presentation.slides.insert(copy, at: position)
            position += 1
            lastID = copy.id
        }
        presentation.addedParts = importer.target.addedParts
        presentation.addedContentTypes = importer.target.addedContentTypes
        presentation.isStructureModified = true
        selectSlide(lastID)
    }

    /// A copy of a slide within its own presentation: the same XML, the
    /// same parts, its own notes.
    static func duplicate(of original: Slide) -> Slide {
        var copy = Slide(layoutPath: original.layoutPath, relationships: original.relationships, shapes: original.shapes)
        copy.sourcePart = original.sourcePart
        copy.background = original.background
        copy.isHidden = original.isHidden
        copy.showsMasterShapes = original.showsMasterShapes
        copy.canEditShapes = original.canEditShapes
        copy.isBackgroundModified = original.isBackgroundModified
        copy.hasRemovedShapes = original.hasRemovedShapes
        copy.autoAdvanceAfter = original.autoAdvanceAfter
        copy.advancesOnClick = original.advancesOnClick
        copy.isTransitionModified = original.isTransitionModified
        copy.transition = original.transition
        copy.isTransitionEffectModified = original.isTransitionEffectModified
        copy.animations = original.animations.map { ShapeAnimation(copying: $0) }
        copy.areAnimationsModified = original.areAnimationsModified
        // Notes and comments belong to one slide; the copy gets its own notes.
        copy.relationships.removeAll {
            $0.type == OOXML.RelationshipType.notesSlide || $0.type == OOXML.RelationshipType.comments
                || $0.type.hasSuffix("/comments")
        }
        copy.notes = original.notes
        copy.areNotesModified = !original.notes.isEmpty
        copy.isModified = original.isModified
        copy.shapes = copy.shapes.map(SlideShape.init(copying:))
        return copy
    }

    /// A slide from another presentation, rebuilt on this one's closest layout.
    private static func imported(
        _ slide: Slide, from source: Presentation, into presentation: Presentation, using importer: inout PartImporter
    ) -> Slide {
        let layout = matchingLayout(for: source.layout(for: slide), in: presentation)
        var copy = Slide(layoutPath: layout?.path ?? slide.layoutPath)
        if let layout {
            copy.relationships = [Relationship(
                id: "rId1", type: OOXML.RelationshipType.slideLayout,
                target: PackagePath.relativeTarget(to: layout.path, from: PartImporter.newSlidePart)
            )]
        }
        copy.shapes = slide.shapes.map { shape in
            importer.transplant(shape, from: slide, into: &copy.relationships, targetPart: PartImporter.newSlidePart)
        }
        if case .fill(let fill) = slide.background {
            copy.background = .fill(fill.remapped { importer.importPart($0) ?? $0 })
        } else {
            copy.background = slide.background
        }
        copy.isBackgroundModified = copy.background != nil
        copy.isHidden = slide.isHidden
        copy.showsMasterShapes = slide.showsMasterShapes
        copy.autoAdvanceAfter = slide.autoAdvanceAfter
        copy.advancesOnClick = slide.advancesOnClick
        copy.transition = slide.transition
        copy.isTransitionEffectModified = slide.transition != nil
        copy.isTransitionModified = slide.autoAdvanceAfter != nil || !slide.advancesOnClick || slide.transition != nil
        // Effects as read may name the other file's parts, such as a sound;
        // only those Dazzle can write anew come across.
        copy.animations = slide.animations.filter(\.effect.isMadeByDazzle).map { animation in
            var copied = ShapeAnimation(copying: animation)
            copied.source = nil
            return copied
        }
        copy.areAnimationsModified = !copy.animations.isEmpty
        copy.notes = slide.notes
        copy.areNotesModified = !slide.notes.isEmpty
        copy.isModified = true
        return copy
    }

    /// The layout in `presentation` most like `layout`: the same name, or
    /// the same placeholders, or failing those, the first.
    static func matchingLayout(for layout: SlideLayout?, in presentation: Presentation) -> SlideLayout? {
        let layouts = presentation.resources.orderedLayouts
        guard let layout else { return layouts.first }
        if let named = layouts.first(where: { $0.name == layout.name }) { return named }
        func kinds(_ layout: SlideLayout) -> Set<String> {
            Set(layout.shapes.compactMap { shape in
                shape.placeholder.flatMap { $0.isFurniture ? nil : ($0.type ?? "body") }
            })
        }
        let wanted = kinds(layout)
        return layouts.first { kinds($0) == wanted } ?? layouts.first
    }
}
