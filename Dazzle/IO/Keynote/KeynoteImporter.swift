import Foundation

/// Opens a Keynote document by converting it into a PowerPoint package and
/// reading that like any other file.
///
/// Every slide goes onto the built-in template's blank layout with its
/// objects placed as Keynote had them: the template slide's own objects,
/// then the slide's, then any title and body text. Keynote's templates are
/// not carried over as layouts, so a converted deck looks the same but
/// saves without them.
enum KeynoteImporter {
    static func presentation(from data: Data) throws -> Presentation {
        try presentation(fromEntries: ZipArchive.entries(in: data))
    }

    /// Reads a `.key` package directory.
    static func presentation(from wrapper: FileWrapper) throws -> Presentation {
        if wrapper.isRegularFile, let data = wrapper.regularFileContents {
            return try presentation(from: data)
        }
        var entries: [String: Data] = [:]
        func collect(_ wrapper: FileWrapper, prefix: String) {
            for (name, child) in wrapper.fileWrappers ?? [:] {
                if child.isDirectory {
                    collect(child, prefix: prefix + name + "/")
                } else if let contents = child.regularFileContents {
                    entries[prefix + name] = contents
                }
            }
        }
        collect(wrapper, prefix: "")
        return try presentation(fromEntries: entries)
    }

    static func presentation(fromEntries entries: [String: Data]) throws -> Presentation {
        let converted = try convert(KeynoteArchive(entries: entries))
        var presentation = try PPTXReader.presentation(fromParts: converted.parts)
        for (index, notes) in converted.notes.enumerated() where !notes.isEmpty && presentation.slides.indices.contains(index) {
            presentation.slides[index].notes = notes
            presentation.slides[index].areNotesModified = true
        }
        fitTextHeights(in: &presentation)
        return presentation
    }

    /// Keynote saves no height for text that sets its own; measure it here,
    /// where text can be laid out. Such text grows from where it is
    /// anchored: down from the top, out from the middle, up from the bottom.
    private static func fitTextHeights(in presentation: inout Presentation) {
        for slideIndex in presentation.slides.indices {
            let slide = presentation.slides[slideIndex]
            let renderer = TextRenderer(style: SlideStyleContext(presentation: presentation, slide: slide), slideNumber: slideIndex + 1)
            for shapeIndex in slide.shapes.indices {
                let shape = slide.shapes[shapeIndex]
                guard let body = shape.text, case .shape = body.properties.autofit else { continue }
                let height = EMU.from(points: renderer.height(of: body, shape: shape, width: shape.frame.points.width))
                let growth: Double = switch body.properties.anchor {
                case .center?: 0.5
                case .bottom?: 1
                default: 0
                }
                var frame = shape.frame
                frame.y -= Int((Double(height - frame.height) * growth).rounded())
                frame.height = height
                presentation.slides[slideIndex].shapes[shapeIndex].frame = frame
                presentation.slides[slideIndex].shapes[shapeIndex].edits.insert(.transform)
                presentation.slides[slideIndex].isModified = true
            }
        }
    }

    struct Conversion {
        var parts: [String: Data]
        /// Speaker notes by slide, which Dazzle writes when it saves.
        var notes: [String]
    }

    static func convert(_ archive: KeynoteArchive) throws -> Conversion {
        guard let document = archive.objects.values.first(where: { $0.type == KeynoteType.document }),
              let show = archive[document.message.reference(2)] else {
            throw KeynoteReadError.notKeynote
        }
        let size = show.message.message(4)
        let slideSize = EMUSize(
            width: KeynoteUnits.emu(size?.float(1) ?? 1_920), height: KeynoteUnits.emu(size?.float(2) ?? 1_080)
        )
        let nodes = show.message.message(3)?.references(2) ?? []
        let media = KeynoteMedia(archive: archive)
        let text = KeynoteText(archive: archive, styles: KeynoteStyles(archive: archive))

        var slides: [PresentationTemplate.SlidePart] = []
        var notes: [String] = []
        for node in nodes.compactMap({ archive[$0] }) {
            guard let slide = archive[node.message.reference(2)] else { continue }
            let partName = "ppt/slides/slide\(slides.count + 1).xml"
            var writer = KeynoteSlideWriter(
                archive: archive, media: media, partName: partName,
                layout: PresentationTemplate.relativeLayout(from: partName)
            )
            let xml = slideXML(slide, hidden: node.message.bool(4) ?? false, writer: &writer)
            slides.append(PresentationTemplate.SlidePart(xml: xml, relationships: writer.relationships))
            let note = archive[slide.message.reference(27)]
            notes.append(text.plainText(archive[note?.message.reference(1)]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !slides.isEmpty else { throw KeynoteReadError.notKeynote }
        return Conversion(parts: PresentationTemplate.parts(size: slideSize, slides: slides, media: media.parts), notes: notes)
    }

    private static func slideXML(_ slide: KeynoteArchive.Object, hidden: Bool, writer: inout KeynoteSlideWriter) -> String {
        let archive = writer.archive
        let styles = writer.styles
        let template = archive[slide.message.reference(17)]

        var background = ""
        let fill = styles.resolve(slide.message.reference(1)) { $0.message.message(11)?.message(1) }
            ?? styles.resolve(template?.message.reference(1)) { $0.message.message(11)?.message(1) }
        if let fill = KeynoteStyles.fill(fill, opacity: 1, image: { writer.imageRelationship($0) }) {
            background = "<p:bg><p:bgPr>\(fill)<a:effectLst/></p:bgPr></p:bg>"
        }

        var shapes = ""
        // The template's own objects sit behind the slide's; its placeholders
        // only stand in for the slide's.
        if let template {
            for identifier in drawables(of: template) where archive[identifier]?.type != KeynoteType.placeholder {
                shapes += writer.drawable(identifier) ?? ""
            }
        }
        for identifier in drawables(of: slide) {
            shapes += writer.drawable(identifier) ?? ""
        }

        let show = hidden ? " show=\"0\"" : ""
        return """
            <p:sld xmlns:a="\(OOXML.drawingML)" xmlns:r="\(OOXML.relationshipsNS)" xmlns:p="\(OOXML.presentationML)"\(show)>\
            <p:cSld>\(background)<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/>\
            </a:xfrm></p:grpSpPr>\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
    }

    /// Back to front. Older files list only the slide's own objects.
    private static func drawables(of slide: KeynoteArchive.Object) -> [UInt64] {
        let ordered = slide.message.references(42)
        return ordered.isEmpty ? slide.message.references(7) : ordered
    }
}
