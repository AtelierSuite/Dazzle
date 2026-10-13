import Foundation

/// Opens a Keynote document by converting it into a PowerPoint package and
/// reading that like any other file.
///
/// Each template slide in use becomes a layout of the built-in template's
/// master, with its background, objects, and title and body placeholders.
/// Slides go onto their template's layout with their objects placed as
/// Keynote had them, their title and body as the layout's placeholders.
enum KeynoteImporter {
    static func presentation(from data: Data) throws -> Presentation {
        // A file that isn't a ZIP archive isn't a Keynote document either.
        guard let entries = try? ZipArchive.orderedEntries(in: data) else { throw KeynoteReadError.notKeynote }
        return try presentation(fromEntries: entries, isPackage: false)
    }

    /// Reads a `.key` package directory.
    static func presentation(from wrapper: FileWrapper) throws -> Presentation {
        if wrapper.isRegularFile, let data = wrapper.regularFileContents {
            return try presentation(from: data)
        }
        var entries: [(path: String, data: Data)] = []
        func collect(_ wrapper: FileWrapper, prefix: String) {
            for (name, child) in (wrapper.fileWrappers ?? [:]).sorted(by: { $0.key < $1.key }) {
                if child.isDirectory {
                    collect(child, prefix: prefix + name + "/")
                } else if let contents = child.regularFileContents {
                    entries.append((prefix + name, contents))
                }
            }
        }
        collect(wrapper, prefix: "")
        return try presentation(fromEntries: entries, isPackage: true)
    }

    /// Keynote saves no height for text that sets its own, and only laying
    /// the text out can tell it. So the deck is converted once, read, its
    /// growing text measured, and converted again with those heights.
    ///
    /// The presentation keeps the document it came from, so that it can be
    /// written back.
    static func presentation(fromEntries entries: [(path: String, data: Data)], isPackage: Bool) throws -> Presentation {
        let archive = try KeynoteArchive(entries: Dictionary(entries.map { ($0.path, $0.data) }) { _, last in last })
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
        for (index, animations) in converted.animations.enumerated()
        where !animations.isEmpty && presentation.slides.indices.contains(index) {
            presentation.slides[index].animations = animations
            presentation.slides[index].areAnimationsModified = true
            presentation.slides[index].isModified = true
        }
        var origins: [Slide.ID: KeynoteSlideOrigin] = [:]
        for (index, origin) in converted.origins.enumerated() where presentation.slides.indices.contains(index) {
            origins[presentation.slides[index].id] = origin
        }
        presentation.keynoteSource = KeynoteSource(
            entries: entries, isPackage: isPackage, archive: archive, original: presentation, slides: origins
        )
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
                    var frame = shape.frame
                    // Text that doesn't wrap is as wide as its longest line, and
                    // grows away from the side it's aligned to.
                    if body.properties.wraps == false {
                        let width = EMU.from(points: renderer.unwrappedWidth(of: body, shape: shape))
                        let spread: Double = switch body.paragraphs.first?.properties.alignment {
                        case .center?: 0.5
                        case .right?: 1
                        default: 0
                        }
                        frame.x -= Int((Double(width - frame.width) * spread).rounded())
                        frame.width = width
                    }
                    let height = EMU.from(points: renderer.height(of: body, shape: shape, width: EMU.points(frame.width)))
                    let growth: Double = switch body.properties.anchor {
                    case .center?: 0.5
                    case .bottom?: 1
                    default: 0
                    }
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
        /// Builds by slide, as animations, which Dazzle writes when it saves.
        var animations: [[ShapeAnimation]]
        /// What could not be brought across.
        var omissions: Set<UnsupportedFeatureReport.Omission>
        /// The objects each slide was converted from.
        var origins: [KeynoteSlideOrigin] = []
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
        let nodes = slideNodes(show.message.message(3), in: archive)
        let text = KeynoteText(archive: archive, styles: KeynoteStyles(archive: archive))

        var slides: [PresentationTemplate.SlidePart] = []
        var notes: [String] = []
        var omissions: Set<UnsupportedFeatureReport.Omission> = []
        var animations: [[ShapeAnimation]] = []
        var origins: [KeynoteSlideOrigin] = []
        // A layout for each template slide in use, in order of first use.
        var layouts: [PresentationTemplate.SlidePart] = []
        var layoutPaths: [UInt64: String] = [:]
        for node in nodes.compactMap({ archive[$0] }) {
            guard let slide = archive[node.message.reference(2)] else { continue }
            let notesStorage = archive[slide.message.reference(27)]?.message.reference(1)
            let template = archive[slide.message.reference(17)]
            var layoutPath: String?
            if let template {
                if let existing = layoutPaths[template.identifier] {
                    layoutPath = existing
                } else {
                    let path = PresentationTemplate.addedLayoutPath(layouts.count)
                    var writer = KeynoteSlideWriter(
                        archive: archive, media: media, partName: path,
                        parent: Relationship(
                            id: "rId1", type: OOXML.RelationshipType.slideMaster,
                            target: PackagePath.relativeTarget(to: PresentationTemplate.masterPath, from: path)
                        ),
                        isLayout: true
                    )
                    let xml = layoutXML(template, number: layouts.count + 1, writer: &writer)
                    layouts.append(PresentationTemplate.SlidePart(xml: xml, relationships: writer.relationships))
                    omissions.formUnion(writer.skipped.map(omission))
                    layoutPaths[template.identifier] = path
                    layoutPath = path
                }
            }
            let partName = "ppt/slides/slide\(slides.count + 1).xml"
            let layout = layoutPath.map { PackagePath.relativeTarget(to: $0, from: partName) }
                ?? PresentationTemplate.relativeLayout(from: partName)
            var writer = KeynoteSlideWriter(
                archive: archive, media: media, partName: partName,
                parent: Relationship(id: "rId1", type: OOXML.RelationshipType.slideLayout, target: layout),
                fittedFrames: fittedFrames.indices.contains(slides.count) ? fittedFrames[slides.count] : [:]
            )
            // Placeholders by kind: slide number, title, body and object.
            for (kind, field) in [(1, 20), (2, 5), (3, 6), (4, 30)] {
                if let placeholder = archive[template?.message.reference(field)]?.message.message(1) {
                    writer.templatePlaceholders[kind] = placeholder
                }
            }
            let xml = slideXML(slide, hidden: node.message.bool(4) ?? false, writer: &writer)
            slides.append(PresentationTemplate.SlidePart(xml: xml, relationships: writer.relationships))
            omissions.formUnion(writer.skipped.map(omission))
            let builds = KeynoteBuilds(archive: archive).animations(slide, shapeIDs: writer.shapeIDs)
            animations.append(builds.animations)
            if builds.lost { omissions.insert(.builds) }
            notes.append(text.plainText(archive[notesStorage]).trimmingCharacters(in: .whitespacesAndNewlines))
            origins.append(KeynoteSlideOrigin(
                node: node.identifier, slide: slide.identifier,
                drawables: Dictionary(writer.shapeIDs.map { ($1, $0) }) { first, _ in first },
                textStorages: writer.textStorages, notesStorage: archive[notesStorage] == nil ? nil : notesStorage
            ))
        }
        guard !slides.isEmpty else { throw KeynoteReadError.notKeynote }
        return Conversion(
            parts: PresentationTemplate.parts(
                size: slideSize, slides: slides, layouts: layouts, media: media.parts, mediaTypes: media.contentTypes
            ),
            notes: notes, animations: animations, omissions: omissions, origins: origins
        )
    }

    /// The show's slide nodes in order. Keynote 6 kept them as a tree under
    /// a root node, with each slide's indented slides as its children.
    private static func slideNodes(_ tree: ProtoMessage?, in archive: KeynoteArchive) -> [UInt64] {
        let slides = tree?.references(2) ?? []
        guard slides.isEmpty, let root = tree?.reference(1) else { return slides }
        var nodes: [UInt64] = []
        var visited: Set<UInt64> = []
        func visit(_ identifier: UInt64) {
            guard visited.insert(identifier).inserted, let node = archive[identifier] else { return }
            if node.message.has(2) { nodes.append(identifier) }
            node.message.references(1).forEach(visit)
        }
        visit(root)
        return nodes
    }

    private static func omission(_ type: UInt32) -> UnsupportedFeatureReport.Omission {
        switch type {
        case KeynoteType.table: .tables
        case KeynoteType.chart: .charts
        case KeynoteType.movie: .movies
        default: .otherObjects
        }
    }

    /// A template slide as a layout: its background, its objects, and its
    /// title and body placeholders, named as the template is.
    private static func layoutXML(_ template: KeynoteArchive.Object, number: Int, writer: inout KeynoteSlideWriter) -> String {
        let background = backgroundXML(template.message.reference(1), writer: &writer)
        let shapes = drawables(of: template).compactMap { writer.drawable($0) }.joined()
        let name = XMLLite.escape(template.message.string(10).flatMap { $0.isEmpty ? nil : $0 } ?? "Keynote \(number)")
        return """
            <p:sldLayout xmlns:a="\(OOXML.drawingML)" xmlns:r="\(OOXML.relationshipsNS)" xmlns:p="\(OOXML.presentationML)" \
            preserve="1"><p:cSld name="\(name)">\(background)\(spTree(shapes))</p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
            """
    }

    private static func backgroundXML(_ style: UInt64?, writer: inout KeynoteSlideWriter) -> String {
        let fill = writer.styles.resolve(style) { $0.message.message(11)?.message(1) }
        guard let xml = KeynoteStyles.fill(fill, opacity: 1, image: { writer.imageRelationship($0) }) else { return "" }
        return "<p:bg><p:bgPr>\(xml)<a:effectLst/></p:bgPr></p:bg>"
    }

    private static func spTree(_ shapes: String) -> String {
        """
        <p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/>\
        </a:xfrm></p:grpSpPr>\(shapes)</p:spTree>
        """
    }

    /// A slide on its template's layout, which draws the template's objects
    /// behind it. The slide's own background is written only where it
    /// differs from the template's.
    private static func slideXML(_ slide: KeynoteArchive.Object, hidden: Bool, writer: inout KeynoteSlideWriter) -> String {
        let template = writer.archive[slide.message.reference(17)]
        let style = slide.message.reference(1)
        let background = template != nil && style == template?.message.reference(1)
            ? "" : backgroundXML(style, writer: &writer)
        let shapes = drawables(of: slide).compactMap { writer.drawable($0) }.joined()
        let show = hidden ? " show=\"0\"" : ""
        return """
            <p:sld xmlns:a="\(OOXML.drawingML)" xmlns:r="\(OOXML.relationshipsNS)" xmlns:p="\(OOXML.presentationML)"\(show)>\
            <p:cSld>\(background)\(spTree(shapes))</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
            \(transitionXML(slide.message.message(4)?.message(2)?.message(8)))</p:sld>
            """
    }

    /// A slide's `KN.AnimationAttributesArchive` as `p:transition`: the
    /// nearest of PowerPoint's own effects, at the nearest of its speeds,
    /// moving on by itself after the delay if Keynote's does.
    private static func transitionXML(_ attributes: ProtoMessage?) -> String {
        guard let attributes else { return "" }
        let effect = (attributes.string(2) ?? "none").lowercased()
        let isAutomatic = attributes.bool(6) ?? false
        guard effect != "none" || isAutomatic else { return "" }
        let element: String? = if effect == "none" {
            nil
        } else if effect.contains("push") {
            "push"
        } else if effect.contains("wipe") {
            "wipe"
        } else if effect.contains("move-in") || effect.contains("cover") {
            "cover"
        } else if effect.contains("reveal") || effect.contains("pull") {
            "pull"
        } else if effect.contains("zoom") || effect.contains("scale") {
            "zoom"
        } else {
            // Dissolve, Magic Move and everything PowerPoint has no match for.
            "fade"
        }
        let duration = attributes.float(3) ?? 1
        var properties = element == nil ? "" : " spd=\"\(duration < 0.75 ? "fast" : duration < 1.25 ? "med" : "slow")\""
        if isAutomatic {
            properties += " advClick=\"0\" advTm=\"\(Int(((attributes.float(5) ?? 0) * 1_000).rounded()))\""
        }
        return "<p:transition\(properties)>\(element.map { "<p:\($0)/>" } ?? "")</p:transition>"
    }

    /// Back to front. Older files list only the slide's own objects.
    private static func drawables(of slide: KeynoteArchive.Object) -> [UInt64] {
        let ordered = slide.message.references(42)
        return ordered.isEmpty ? slide.message.references(7) : ordered
    }
}
