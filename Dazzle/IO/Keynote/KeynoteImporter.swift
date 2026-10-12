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

    /// Keynote saves no height for text that sets its own, and only laying
    /// the text out can tell it. So the deck is converted once, read, its
    /// growing text measured, and converted again with those heights.
    static func presentation(fromEntries entries: [String: Data]) throws -> Presentation {
        let archive = try KeynoteArchive(entries: entries)
        let media = KeynoteMedia(archive: archive)
        var converted = try convert(archive, media: media)
        var presentation = try PPTXReader.presentation(fromParts: converted.parts)
        let fitted = fittedFrames(in: presentation)
        if fitted.contains(where: { !$0.isEmpty }) {
            converted = try convert(archive, media: media, fittedFrames: fitted)
        }
        presentation = try PPTXReader.presentation(fromParts: converted.parts, omissions: converted.omissions)
        for (index, notes) in converted.notes.enumerated() where !notes.isEmpty && presentation.slides.indices.contains(index) {
            presentation.slides[index].notes = notes
            presentation.slides[index].areNotesModified = true
        }
        return presentation
    }

    /// Where growing text ends up, by slide and shape id, in the space of
    /// whatever holds it. It grows from where it is anchored: down from the
    /// top, out from the middle, up from the bottom.
    private static func fittedFrames(in presentation: Presentation) -> [[Int: EMURect]] {
        presentation.slides.enumerated().map { index, slide in
            let renderer = TextRenderer(style: SlideStyleContext(presentation: presentation, slide: slide), slideNumber: index + 1)
            var frames: [Int: EMURect] = [:]
            func visit(_ shapes: [SlideShape]) {
                for shape in shapes {
                    if case .group(let group) = shape.kind { visit(group.children) }
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
                    frames[shape.shapeID] = frame
                }
            }
            visit(slide.shapes)
            return frames
        }
    }

    struct Conversion {
        var parts: [String: Data]
        /// Speaker notes by slide, which Dazzle writes when it saves.
        var notes: [String]
        /// What could not be brought across.
        var omissions: Set<UnsupportedFeatureReport.Omission>
    }

    static func convert(_ archive: KeynoteArchive, media: KeynoteMedia, fittedFrames: [[Int: EMURect]] = []) throws -> Conversion {
        guard let document = archive.objects.values.first(where: { $0.type == KeynoteType.document }),
              let show = archive[document.message.reference(2)] else {
            throw KeynoteReadError.notKeynote
        }
        let size = show.message.message(4)
        let slideSize = EMUSize(
            width: KeynoteUnits.emu(size?.float(1) ?? 1_920), height: KeynoteUnits.emu(size?.float(2) ?? 1_080)
        )
        let nodes = show.message.message(3)?.references(2) ?? []
        let text = KeynoteText(archive: archive, styles: KeynoteStyles(archive: archive))

        var slides: [PresentationTemplate.SlidePart] = []
        var notes: [String] = []
        var omissions: Set<UnsupportedFeatureReport.Omission> = []
        for node in nodes.compactMap({ archive[$0] }) {
            guard let slide = archive[node.message.reference(2)] else { continue }
            let partName = "ppt/slides/slide\(slides.count + 1).xml"
            var writer = KeynoteSlideWriter(
                archive: archive, media: media, partName: partName,
                layout: PresentationTemplate.relativeLayout(from: partName),
                fittedFrames: fittedFrames.indices.contains(slides.count) ? fittedFrames[slides.count] : [:]
            )
            let xml = slideXML(slide, hidden: node.message.bool(4) ?? false, writer: &writer)
            slides.append(PresentationTemplate.SlidePart(xml: xml, relationships: writer.relationships))
            omissions.formUnion(writer.skipped.map(omission))
            if !slide.message.references(2).isEmpty || !slide.message.references(43).isEmpty {
                omissions.insert(.builds)
            }
            if let effect = slide.message.message(4)?.message(2)?.message(8)?.string(2), effect != "none" {
                omissions.insert(.transitions)
            }
            let note = archive[slide.message.reference(27)]
            notes.append(text.plainText(archive[note?.message.reference(1)]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !slides.isEmpty else { throw KeynoteReadError.notKeynote }
        return Conversion(
            parts: PresentationTemplate.parts(size: slideSize, slides: slides, media: media.parts, mediaTypes: media.contentTypes),
            notes: notes, omissions: omissions
        )
    }

    private static func omission(_ type: UInt32) -> UnsupportedFeatureReport.Omission {
        switch type {
        case KeynoteType.table: .tables
        case KeynoteType.chart: .charts
        case KeynoteType.movie: .movies
        default: .otherObjects
        }
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
