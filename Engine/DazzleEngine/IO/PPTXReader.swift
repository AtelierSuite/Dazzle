import Foundation

public enum PresentationReadError: LocalizedError {
    case notAPresentation

    public var errorDescription: String? {
        String(localized: "Error.NotAPresentation", bundle: .engine)
    }
}

/// Reads a `.pptx`, `.pptm` or `.ppsx` package.
public enum PPTXReader {
    public static func presentation(from data: Data) throws -> Presentation {
        try presentation(fromParts: ZipArchive.entries(in: data))
    }

    /// `omissions` is what a file converted into these parts lost on the way.
    public static func presentation(
        fromParts parts: [String: Data], omissions: Set<UnsupportedFeatureReport.Omission> = []
    ) throws -> Presentation {
        let rootRelationships = Relationship.parse(parts["_rels/.rels"])
        let mainPart = rootRelationships.first { $0.type == OOXML.RelationshipType.officeDocument }
            .map { PackagePath.resolve($0.target, from: "") } ?? "ppt/presentation.xml"
        guard let mainData = parts[mainPart], let main = try? XMLLite.parse(mainData),
              main.name == "presentation" else {
            throw PresentationReadError.notAPresentation
        }
        let mainRelationships = Relationship.parse(parts[PackagePath.relationships(of: mainPart)])
        func target(_ id: String?) -> String? {
            guard let id, let relationship = mainRelationships.first(where: { $0.id == id }) else { return nil }
            return PackagePath.resolve(relationship.target, from: mainPart)
        }

        var features: Set<UnsupportedFeatureReport.Feature> = []
        if mainRelationships.contains(where: { $0.type == OOXML.RelationshipType.vbaProject })
            || parts.keys.contains(where: { $0.hasSuffix("vbaProject.bin") }) {
            features.insert(.macros)
        }

        let templates = readTemplates(main: main, mainRelationships: mainRelationships, mainPart: mainPart, parts: parts)
        let resources = DeckResources(
            masters: templates.masters, layouts: templates.layouts, layoutOrder: templates.layoutOrder,
            defaultTextStyle: ListStyle(element: main.firstChild(named: "defaultTextStyle")),
            notesMasterPath: target(main.firstChild(named: "notesMasterIdLst")?.firstChild(named: "notesMasterId")?.relationshipID),
            tableStyles: readTableStyles(
                mainRelationships.first { $0.type.hasSuffix("/tableStyles") }
                    .flatMap { parts[PackagePath.resolve($0.target, from: mainPart)] }
            ),
            embeddedFonts: readEmbeddedFonts(main.firstChild(named: "embeddedFontLst"), parts: parts, target: target),
            masterOrder: templates.masterOrder
        )

        func part(of type: String) -> Data? {
            mainRelationships.first { $0.type == type }.flatMap { parts[PackagePath.resolve($0.target, from: mainPart)] }
        }
        let authors = CommentXML.authors(part(of: OOXML.RelationshipType.commentAuthors))
        let modernAuthors = CommentXML.modernAuthors(part(of: OOXML.RelationshipType.authors))

        // Slides, in the order the presentation lists them.
        var slides: [Slide] = []
        for entry in main.firstChild(named: "sldIdLst")?.children(named: "sldId") ?? [] {
            guard let path = target(entry.relationshipID), parts[path] != nil else { continue }
            guard var slide = readSlide(path, resources: resources, parts: parts, features: &features) else { continue }
            for relationship in slide.relationships where !relationship.isExternal {
                let commentsPath = PackagePath.resolve(relationship.target, from: path)
                if relationship.type == OOXML.RelationshipType.comments {
                    slide.legacyCommentsPart = commentsPath
                    slide.comments += CommentXML.legacyComments(parts[commentsPath], authors: authors)
                } else if relationship.type == OOXML.RelationshipType.modernComments {
                    slide.modernCommentsPart = commentsPath
                    slide.comments += CommentXML.modernComments(parts[commentsPath], authors: modernAuthors)
                }
            }
            slide.partName = path
            slide.sourcePart = path
            slides.append(slide)
        }

        let size = main.firstChild(named: "sldSz")
        var presentation = Presentation(
            slideSize: EMUSize(
                width: size?.attribute("cx").flatMap(Int.init) ?? EMUSize.widescreen.width,
                height: size?.attribute("cy").flatMap(Int.init) ?? EMUSize.widescreen.height
            ),
            slides: slides,
            resources: resources,
            package: Package(
                parts: parts, mainPart: mainPart,
                unsupportedFeatures: UnsupportedFeatureReport(features: features, omissions: omissions)
            )
        )
        presentation.commentAuthors = authors
        presentation.modernCommentAuthors = modernAuthors
        if let properties = part(of: OOXML.RelationshipType.presProps), let root = try? XMLLite.parse(properties) {
            if let settings = root.firstChild(named: "showPr") {
                presentation.showSettings = readShowSettings(settings)
            }
        }
        presentation.customShows = readCustomShows(main.firstChild(named: "custShowLst"), slides: slides, target: target)
        presentation.properties = DocumentPropertiesXML.properties(in: parts)
        presentation.resolveSlideLinks()
        return presentation
    }

    /// `p:showPr`: which slides play, and how.
    static func readShowSettings(_ element: XMLElement) -> SlideshowSettings {
        var settings = SlideshowSettings()
        func flag(_ name: String, default value: Bool) -> Bool {
            element.attribute(name).map { ["1", "true"].contains($0) } ?? value
        }
        settings.loops = flag("loop", default: false)
        settings.usesTimings = flag("useTimings", default: true)
        settings.showsAnimations = flag("showAnimation", default: true)
        settings.playsNarration = flag("showNarration", default: false)
        if let kiosk = element.firstChild(named: "kiosk") {
            settings.isKiosk = true
            if let restart = kiosk.attribute("restart").flatMap(Double.init) { settings.kioskRestartAfter = max(restart / 1_000, 1) }
        }
        if let range = element.firstChild(named: "sldRg") {
            let from = range.attribute("st").flatMap(Int.init) ?? 1
            settings.range = .slides(from: max(from, 1), to: max(range.attribute("end").flatMap(Int.init) ?? from, 1))
        } else if let show = element.firstChild(named: "custShow")?.attribute("id").flatMap(Int.init) {
            settings.range = .customShow(show)
        }
        return settings
    }

    /// `p:custShowLst`: each show's name, and its slides by relationship.
    private static func readCustomShows(_ list: XMLElement?, slides: [Slide], target: (String?) -> String?) -> [CustomShow] {
        let ids = Dictionary(slides.compactMap { slide in slide.partName.map { ($0, slide.id) } }) { first, _ in first }
        return list?.children(named: "custShow").compactMap { show in
            guard let id = show.attribute("id").flatMap(Int.init) else { return nil }
            let slideIDs = show.firstChild(named: "sldLst")?.children(named: "sld").compactMap { target($0.relationshipID).flatMap { ids[$0] } }
            return CustomShow(id: id, name: show.attribute("name") ?? "", slideIDs: slideIDs ?? [])
        } ?? []
    }

    // MARK: - Embedded fonts

    /// `p:embeddedFontLst`: each typeface and the files for its styles. They
    /// are decoded only once text asks for them.
    private static func readEmbeddedFonts(
        _ list: XMLElement?, parts: [String: Data], target: (String?) -> String?
    ) -> EmbeddedFonts {
        var files: [String: [EmbeddedFonts.Face: Data]] = [:]
        for entry in list?.children(named: "embeddedFont") ?? [] {
            guard let typeface = entry.firstChild(named: "font")?.attribute("typeface")?.nilIfEmpty else { continue }
            let styles = [("regular", false, false), ("bold", true, false), ("italic", false, true), ("boldItalic", true, true)]
            for (style, bold, italic) in styles {
                guard let path = target(entry.firstChild(named: style)?.relationshipID), let data = parts[path] else { continue }
                files[typeface, default: [:]][EmbeddedFonts.Face(isBold: bold, isItalic: italic)] = data
            }
        }
        return files.isEmpty ? .none : EmbeddedFonts(files: files)
    }

    // MARK: - Masters and layouts

    private struct Templates {
        var masters: [String: SlideMaster] = [:]
        var layouts: [String: SlideLayout] = [:]
        var layoutOrder: [String] = []
        var masterOrder: [String] = []
    }

    /// The masters, and the layouts each one offers.
    private static func readTemplates(
        main: XMLElement, mainRelationships: [Relationship], mainPart: String, parts: [String: Data]
    ) -> Templates {
        var templates = Templates()
        let masterPaths = main.firstChild(named: "sldMasterIdLst")?.children(named: "sldMasterId").compactMap { entry in
            mainRelationships.first { $0.id == entry.relationshipID }.map { PackagePath.resolve($0.target, from: mainPart) }
        } ?? []
        let masterTargets = masterPaths.isEmpty
            ? mainRelationships.filter { $0.type == OOXML.RelationshipType.slideMaster }
                .map { PackagePath.resolve($0.target, from: mainPart) }
            : masterPaths
        for masterPath in masterTargets {
            guard templates.masters[masterPath] == nil, var master = readMaster(masterPath, parts: parts) else { continue }
            templates.masterOrder.append(masterPath)
            master.layoutPaths = master.layoutPaths.filter { layoutPath in
                guard templates.layouts[layoutPath] == nil,
                      let layout = readLayout(layoutPath, master: master, parts: parts) else { return false }
                templates.layouts[layoutPath] = layout
                if templates.masterOrder.count == 1 { templates.layoutOrder.append(layoutPath) }
                return true
            }
            templates.masters[masterPath] = master
        }
        return templates
    }

    /// `resources` with its masters and layouts read again from `parts`,
    /// after master view has changed them.
    static func resources(_ resources: DeckResources, rereadingTemplatesIn parts: [String: Data], mainPart: String) -> DeckResources {
        guard let main = parts[mainPart].flatMap({ try? XMLLite.parse($0) }) else { return resources }
        let templates = readTemplates(
            main: main, mainRelationships: Relationship.parse(parts[PackagePath.relationships(of: mainPart)]),
            mainPart: mainPart, parts: parts
        )
        return DeckResources(
            masters: templates.masters, layouts: templates.layouts, layoutOrder: templates.layoutOrder,
            defaultTextStyle: resources.defaultTextStyle, notesMasterPath: resources.notesMasterPath,
            tableStyles: resources.tableStyles, embeddedFonts: resources.embeddedFonts, masterOrder: templates.masterOrder
        )
    }

    /// A master or layout as a slide of its own, for master view to edit:
    /// its shapes keep their XML, so they are written back as slides' are.
    static func templateSlide(_ path: String, role: Slide.Role, inheritedShapes: [[SlideShape]], parts: [String: Data]) -> Slide? {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return nil }
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
        let common = root.firstChild(named: "cSld")
        let tree = common?.firstChild(named: "spTree")
        let parser = ShapeParser(
            partPath: path, relationships: relationships, namespaces: namespacesInScope(of: tree),
            inheritedShapes: inheritedShapes, parts: parts, capturesSource: true
        )
        var slide = Slide(layoutPath: "", relationships: relationships, shapes: parser.shapes(in: tree))
        slide.role = role
        slide.partName = path
        slide.sourcePart = path
        slide.background = Background(element: common?.firstChild(named: "bg"), image: parser.target(of:))
        slide.showsMasterShapes = root.attribute("showMasterSp") != "0"
        slide.canEditShapes = !parser.hasUncapturableShape
        if role != .master { slide.layoutName = common?.attribute("name") ?? "" }
        return slide
    }

    private static func readMaster(_ path: String, parts: [String: Data]) -> SlideMaster? {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return nil }
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
        let theme = relationships.first { $0.type == OOXML.RelationshipType.theme }
            .map { PackagePath.resolve($0.target, from: path) }
            .flatMap { themePath in readTheme(at: themePath, parts: parts) } ?? .office
        let parser = ShapeParser(partPath: path, relationships: relationships, namespaces: [:], parts: parts)
        let common = root.firstChild(named: "cSld")
        let styles = root.firstChild(named: "txStyles")

        var colorMap = SlideMaster.defaultColorMap
        if let map = root.firstChild(named: "clrMap") {
            for key in colorMap.keys {
                if let value = map.attribute(key) { colorMap[key] = value }
            }
        }

        let layoutIDs = root.firstChild(named: "sldLayoutIdLst")?.children(named: "sldLayoutId")
            .compactMap(\.relationshipID) ?? []
        var layoutPaths = layoutIDs.compactMap { id in
            relationships.first { $0.id == id }.map { PackagePath.resolve($0.target, from: path) }
        }
        if layoutPaths.isEmpty {
            layoutPaths = relationships.filter { $0.type == OOXML.RelationshipType.slideLayout }
                .map { PackagePath.resolve($0.target, from: path) }
        }

        return SlideMaster(
            path: path, layoutPaths: layoutPaths, theme: theme, colorMap: colorMap,
            background: Background(element: common?.firstChild(named: "bg"), image: parser.target(of:)),
            shapes: parser.shapes(in: common?.firstChild(named: "spTree")),
            titleStyle: ListStyle(element: styles?.firstChild(named: "titleStyle")),
            bodyStyle: ListStyle(element: styles?.firstChild(named: "bodyStyle")),
            otherStyle: ListStyle(element: styles?.firstChild(named: "otherStyle"))
        )
    }

    private static func readLayout(_ path: String, master: SlideMaster, parts: [String: Data]) -> SlideLayout? {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return nil }
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
        let parser = ShapeParser(
            partPath: path, relationships: relationships, namespaces: [:],
            inheritedShapes: [master.shapes], parts: parts
        )
        let common = root.firstChild(named: "cSld")
        var override: [String: String]?
        if let mapping = root.firstChild(named: "clrMapOvr")?.firstChild(named: "overrideClrMapping") {
            override = SlideMaster.defaultColorMap.keys.reduce(into: [:]) { map, key in
                map[key] = mapping.attribute(key)
            }
        }
        return SlideLayout(
            path: path,
            name: common?.attribute("name") ?? (path as NSString).lastPathComponent,
            masterPath: master.path,
            background: Background(element: common?.firstChild(named: "bg"), image: parser.target(of:)),
            shapes: parser.shapes(in: common?.firstChild(named: "spTree")),
            showsMasterShapes: root.attribute("showMasterSp") != "0",
            colorMapOverride: override
        )
    }

    private static func readTableStyles(_ data: Data?) -> [String: TableStyle] {
        guard let data, let root = try? XMLLite.parse(data) else { return [:] }
        var styles: [String: TableStyle] = [:]
        for style in root.children(named: "tblStyle") {
            if let id = style.attribute("styleId") { styles[id] = TableStyle(element: style) }
        }
        return styles
    }

    private static func readTheme(at path: String, parts: [String: Data]) -> Theme? {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return nil }
        // Picture fills in the theme name images relative to the theme part.
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
        let image: (String) -> String? = { id in
            relationships.first { $0.id == id && !$0.isExternal }.map { PackagePath.resolve($0.target, from: path) }
        }
        let elements = root.firstChild(named: "themeElements")
        var colors = Theme.office.colors
        for slot in elements?.firstChild(named: "clrScheme")?.children ?? [] {
            if let rgb = slot.firstChild(named: "srgbClr")?.attribute("val").flatMap({ UInt32($0, radix: 16) }) {
                colors[slot.name] = rgb
            } else if let system = slot.firstChild(named: "sysClr") {
                colors[slot.name] = system.attribute("lastClr").flatMap { UInt32($0, radix: 16) }
                    ?? (system.attribute("val") == "window" ? 0xFFFFFF : 0x000000)
            }
        }
        let fonts = elements?.firstChild(named: "fontScheme")
        let format = elements?.firstChild(named: "fmtScheme")
        func fills(_ name: String) -> [Fill] {
            format?.firstChild(named: name)?.children.compactMap { Fill.parse(element: $0, image: image) } ?? []
        }
        func scriptFonts(_ name: String) -> [String: String] {
            var result: [String: String] = [:]
            for font in fonts?.firstChild(named: name)?.children(named: "font") ?? [] {
                if let script = font.attribute("script"), let typeface = font.attribute("typeface")?.nilIfEmpty {
                    result[script] = typeface
                }
            }
            return result
        }
        return Theme(
            colors: colors,
            majorFont: fonts?.firstChild(named: "majorFont")?.firstChild(named: "latin")?.attribute("typeface")
                ?? Theme.office.majorFont,
            minorFont: fonts?.firstChild(named: "minorFont")?.firstChild(named: "latin")?.attribute("typeface")
                ?? Theme.office.minorFont,
            majorEastAsianFont: fonts?.firstChild(named: "majorFont")?.firstChild(named: "ea")?.attribute("typeface")?.nilIfEmpty,
            minorEastAsianFont: fonts?.firstChild(named: "minorFont")?.firstChild(named: "ea")?.attribute("typeface")?.nilIfEmpty,
            majorComplexScriptFont: fonts?.firstChild(named: "majorFont")?.firstChild(named: "cs")?.attribute("typeface")?.nilIfEmpty,
            minorComplexScriptFont: fonts?.firstChild(named: "minorFont")?.firstChild(named: "cs")?.attribute("typeface")?.nilIfEmpty,
            majorScriptFonts: scriptFonts("majorFont"),
            minorScriptFonts: scriptFonts("minorFont"),
            fillStyles: fills("fillStyleLst"),
            backgroundFillStyles: fills("bgFillStyleLst"),
            lineStyles: format?.firstChild(named: "lnStyleLst")?.children(named: "ln").map(LineStyle.init(element:)) ?? [],
            effectStyles: format?.firstChild(named: "effectStyleLst")?.children(named: "effectStyle")
                .map(EffectStyle.init(element:)) ?? []
        )
    }

    // MARK: - Slides

    private static func readSlide(
        _ path: String, resources: DeckResources, parts: [String: Data],
        features: inout Set<UnsupportedFeatureReport.Feature>
    ) -> Slide? {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return nil }
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
        let layoutPath = relationships.first { $0.type == OOXML.RelationshipType.slideLayout }
            .map { PackagePath.resolve($0.target, from: path) } ?? resources.layoutOrder.first ?? ""
        let layout = resources.layouts[layoutPath]
        let master = resources.master(for: layout)
        let tree = root.firstChild(named: "cSld")?.firstChild(named: "spTree")

        let parser = ShapeParser(
            partPath: path, relationships: relationships,
            namespaces: namespacesInScope(of: tree),
            inheritedShapes: [layout?.shapes ?? [], master?.shapes ?? []],
            parts: parts, capturesSource: true
        )
        var slide = Slide(layoutPath: layoutPath, relationships: relationships, shapes: parser.shapes(in: tree))
        slide.background = Background(element: root.firstChild(named: "cSld")?.firstChild(named: "bg"), image: parser.target(of:))
        slide.isHidden = root.attribute("show") == "0"
        let versions = transitions(in: root)
        if let transition = versions.first {
            slide.transition = SlideTransition(versions: versions)
            // An effect Dazzle has no drawing for is played as a fade.
            if slide.transition?.approximates != nil { features.insert(.transitions) }
            slide.autoAdvanceAfter = transition.attribute("advTm").flatMap(Double.init).map { $0 / 1_000 }
            slide.advancesOnClick = transition.attribute("advClick") != "0"
        }
        slide.showsMasterShapes = root.attribute("showMasterSp") != "0"
        slide.canEditShapes = !parser.hasUncapturableShape
        features.formUnion(parser.features)
        if let timing = root.firstChild(named: "timing") {
            slide.animations = AnimationXML.animations(in: timing)
            markAutoplay(in: timing, shapes: &slide.shapes)
            MediaXML.read(timing, into: &slide.shapes)
        }

        if let notesPath = relationships.first(where: { $0.type == OOXML.RelationshipType.notesSlide })
            .map({ PackagePath.resolve($0.target, from: path) }) {
            slide.notesPart = notesPath
            slide.notes = notesText(parts[notesPath]) ?? ""
        }
        return slide
    }

    /// Media a slide's timing plays without waiting for a tap: a play command
    /// that runs with or after the slide's start rather than on a click.
    private static func markAutoplay(in timing: XMLElement, shapes: inout [SlideShape]) {
        var automatic: Set<Int> = []
        var narrations: Set<Int> = []
        func visit(_ element: XMLElement) {
            if element.name == "audio", ["1", "true"].contains(element.attribute("isNarration") ?? ""),
               let target = element.firstDescendant(atPath: "cMediaNode/tgtEl/spTgt")?.attribute("spid").flatMap(Int.init) {
                narrations.insert(target)
            }
            if element.name == "cmd", element.attribute("cmd")?.hasPrefix("playFrom") == true,
               let target = element.firstDescendant(atPath: "cBhvr/tgtEl/spTgt")?.attribute("spid").flatMap(Int.init) {
                var node = element.parent
                var isClick = false
                while let current = node {
                    if current.name == "cTn", current.attribute("nodeType") == "clickEffect" { isClick = true }
                    node = current.parent
                }
                if !isClick { automatic.insert(target) }
            }
            element.children.forEach(visit)
        }
        visit(timing)
        for index in shapes.indices where automatic.union(narrations).contains(shapes[index].shapeID) {
            if case .picture(var picture) = shapes[index].kind, picture.media != nil {
                // A narration plays as its slide starts.
                picture.media?.playsAutomatically = true
                if narrations.contains(shapes[index].shapeID) { picture.media?.isNarration = true }
                shapes[index].kind = .picture(picture)
            }
        }
    }

    /// A slide's `p:transition`, and each version of it PowerPoint writes
    /// side by side for older readers.
    public static func transitions(in root: XMLElement) -> [XMLElement] {
        root.children(named: "transition") + root.children(named: "AlternateContent").flatMap { alternative in
            alternative.children.flatMap { $0.children(named: "transition") }
        }
    }

    /// The speaker notes: the text of a notes page's body placeholder.
    public static func notesText(_ data: Data?) -> String? {
        guard let data, let root = try? XMLLite.parse(data),
              let tree = root.firstChild(named: "cSld")?.firstChild(named: "spTree") else { return nil }
        let parser = ShapeParser(partPath: "", relationships: [], namespaces: [:], parts: [:])
        let body = parser.shapes(in: tree).first { $0.placeholder?.type == "body" }
        return body?.text?.plainText
    }

    /// Every namespace binding visible at `element`, from it up to the root.
    public static func namespacesInScope(of element: XMLElement?) -> [String: String] {
        var result: [String: String] = [:]
        var current = element
        while let node = current {
            for (prefix, uri) in node.namespaceDeclarations where result[prefix] == nil {
                result[prefix] = uri
            }
            current = node.parent
        }
        return result
    }
}
