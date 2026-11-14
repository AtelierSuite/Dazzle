import Foundation

/// Master view: editing the masters and layouts the slides are built on.
///
/// Going in sets the slides aside and puts the masters and layouts in their
/// place, each as a slide of its own, so whatever edits a slide edits them.
/// Coming out writes the changed ones into their parts, reads them back as
/// the presentation's resources, and puts the slides back to follow them.
extension Presentation {
    public var isInMasterView: Bool { masterView != nil }

    /// Whether there are masters to edit, and somewhere to save them: a
    /// Keynote document is saved into itself, where they have no counterpart.
    public var canEditMasters: Bool { keynoteSource == nil && !resources.masters.isEmpty }

    /// The presentation with its slides back in place, for whatever shows
    /// or exports the slides while master view is open.
    public var outOfMasterView: Presentation {
        (try? leavingMasterView()) ?? self
    }

    /// Every part as it stands: read, added or replaced, and not removed.
    private var currentParts: [String: Data] {
        var parts = package.parts.merging(addedParts) { _, added in added }
        for path in removedParts { parts[path] = nil }
        return parts
    }

    /// Puts the masters, each followed by its layouts, in place of the slides.
    public mutating func enterMasterView(selectedSlideID: Slide.ID? = nil) {
        guard !isInMasterView, canEditMasters else { return }
        let parts = currentParts
        var templates: [Slide] = []
        for masterPath in resources.masterOrder {
            guard let master = resources.masters[masterPath],
                  let slide = PPTXReader.templateSlide(masterPath, role: .master, inheritedShapes: [], parts: parts) else { continue }
            templates.append(slide)
            templates += master.layoutPaths.compactMap { layoutPath in
                PPTXReader.templateSlide(
                    layoutPath, role: .layout(masterPath: masterPath), inheritedShapes: [master.shapes], parts: parts
                )
            }
        }
        guard !templates.isEmpty else { return }
        masterView = MasterView(slides: slides, resources: resources, selectedSlideID: selectedSlideID)
        slides = templates
    }

    /// How many slides are built on a layout, which cannot be deleted while any are.
    public func slideCount(usingLayoutAt path: String?) -> Int {
        guard let path else { return 0 }
        return (masterView?.slides ?? slides).filter { $0.layoutPath == path }.count
    }

    /// A layout to add beneath a master: a title, and the date, footer and
    /// slide number the master has, each where the master puts it.
    public func newLayout(named name: String, masterPath: String) -> Slide {
        var layout = Slide(layoutPath: "")
        layout.role = .layout(masterPath: masterPath)
        layout.layoutName = name
        layout.isModified = true
        let master = slides.first { $0.role == .master && $0.partName == masterPath }?.shapes
            ?? resources.masters[masterPath]?.shapes ?? []
        var nextID = 2
        for type in ["title", "dt", "ftr", "sldNum"] {
            guard let template = master.first(where: { $0.placeholder?.type == type }) else { continue }
            var shape = SlideShape(shapeID: nextID, name: template.name, kind: .shape, frame: template.frame, hasOwnFrame: false)
            // Indices past the master's own, so a slide's placeholders find these by index.
            shape.placeholder = Placeholder(type: type, index: type == "title" ? nil : 8 + nextID)
            // The master's prompt, with everything about how it looks left to the master.
            shape.text = TextBody(paragraphs: template.text?.paragraphs ?? [Paragraph(runs: [])])
            layout.shapes.append(shape)
            nextID += 1
        }
        return layout
    }

    /// Puts layouts' placeholders that take their place from the master
    /// where it now has them, and has everything drawn from the masters and
    /// layouts drawn again. Called after a change in master view.
    public mutating func refreshTemplates() {
        guard isInMasterView else { return }
        for index in slides.indices {
            guard case .layout(let masterPath) = slides[index].role,
                  let master = slides.first(where: { $0.role == .master && $0.partName == masterPath }) else { continue }
            for position in slides[index].shapes.indices {
                let shape = slides[index].shapes[position]
                guard !shape.hasOwnFrame, let placeholder = shape.placeholder,
                      let source = master.shapes.masterPlaceholder(for: placeholder), source.frame != shape.frame else { continue }
                slides[index].shapes[position].frame = source.frame
            }
        }
        resources = resources.copy()
    }

    /// The presentation out of master view: the changed masters and layouts
    /// written into their parts, and the slides back, following them.
    public func leavingMasterView() throws -> Presentation {
        guard let view = masterView else { return self }
        var result = self
        var templates = slides
        result.slides = view.slides
        result.masterView = nil

        func setPart(_ path: String, _ data: Data) {
            result.addedParts[path] = data
            result.removedParts.remove(path)
        }

        // Layouts that are new get somewhere to be saved.
        var taken = partNames
        for index in templates.indices where templates[index].partName == nil {
            let path = PackagePath.unused(prefix: "ppt/slideLayouts/slideLayout", suffix: ".xml", taken: taken)
            taken.insert(path)
            templates[index].partName = path
        }
        let slidePaths = Dictionary(view.slides.compactMap { slide in slide.partName.map { (slide.id, $0) } }) { first, _ in first }
        var nextListID = try nextLayoutListID()

        for master in templates where master.role == .master {
            guard let masterPath = master.partName else { continue }
            var masterRelationships = Relationship.parse(data(at: PackagePath.relationships(of: masterPath)))
            let layouts = templates.filter { $0.role == .layout(masterPath: masterPath) }
            let before = resources.masters[masterPath]?.layoutPaths ?? []
            let after = layouts.compactMap(\.partName)

            for var layout in layouts {
                guard let path = layout.partName else { continue }
                let isNew = path != layout.sourcePart
                if isNew, !layout.relationships.contains(where: { $0.type == OOXML.RelationshipType.slideMaster }) {
                    layout.relationships.append(Relationship(
                        id: Relationship.unusedID(in: layout.relationships), type: OOXML.RelationshipType.slideMaster,
                        target: PackagePath.relativeTarget(to: masterPath, from: path)
                    ))
                }
                if layout.isModified || isNew {
                    let base = layout.sourcePart.flatMap { data(at: $0) }
                        ?? Data(SlideSkeleton.layout(name: layout.layoutName ?? "").utf8)
                    setPart(path, try Self.templateXML(for: &layout, base: base, path: path, slidePaths: slidePaths))
                }
                if isNew { result.addedContentTypes[path] = OOXML.ContentType.slideLayout }
                let relationshipsPath = PackagePath.relationships(of: path)
                if isNew || layout.relationships != Relationship.parse(data(at: relationshipsPath)) {
                    setPart(relationshipsPath, Relationship.xml(layout.relationships))
                }
            }

            for path in before where !after.contains(path) {
                result.removedParts.formUnion([path, PackagePath.relationships(of: path)])
                result.addedParts[path] = nil
                result.addedParts[PackagePath.relationships(of: path)] = nil
                result.addedContentTypes[path] = nil
                masterRelationships.removeAll {
                    $0.type == OOXML.RelationshipType.slideLayout && PackagePath.resolve($0.target, from: masterPath) == path
                }
            }

            guard master.isModified || before != after, let base = data(at: masterPath) else { continue }
            var master = master
            var xml = master.isModified
                ? try Self.templateXML(for: &master, base: base, path: masterPath, slidePaths: slidePaths) : base
            // What editing the master's shapes added, such as a picture.
            for relationship in master.relationships where !masterRelationships.contains(where: { $0.id == relationship.id }) {
                masterRelationships.append(relationship)
            }
            if before != after {
                xml = try Self.listingLayouts(
                    after, in: xml, masterPath: masterPath, relationships: &masterRelationships, nextID: &nextListID
                )
            }
            setPart(masterPath, xml)
            let relationshipsPath = PackagePath.relationships(of: masterPath)
            if masterRelationships != Relationship.parse(data(at: relationshipsPath)) {
                setPart(relationshipsPath, Relationship.xml(masterRelationships))
            }
        }

        // Nothing written: the masters and layouts are as they were.
        guard result.addedParts != addedParts || result.removedParts != removedParts else {
            result.resources = view.resources
            return result
        }
        result.resources = PPTXReader.resources(
            resources, rereadingTemplatesIn: result.currentParts, mainPart: package.mainPart
        )
        result.followTemplates()
        return result
    }

    /// Puts each slide's placeholders that take their place from the layout
    /// or master where those now have them.
    private mutating func followTemplates() {
        for index in slides.indices {
            let layout = resources.layouts[slides[index].layoutPath]
            let master = resources.master(for: layout)
            for position in slides[index].shapes.indices {
                let shape = slides[index].shapes[position]
                guard !shape.hasOwnFrame, let placeholder = shape.placeholder,
                      let source = layout?.shapes.inheritedPlaceholder(for: placeholder)
                        ?? master?.shapes.masterPlaceholder(for: placeholder),
                      source.frame != shape.frame else { continue }
                slides[index].shapes[position].frame = source.frame
            }
        }
    }

    // The ids below are read by their qualified name: with prefixes stripped,
    // an entry's `id` and its `r:id` are one attribute.

    /// The first id no master or layout is listed under. Masters and
    /// layouts share one run of ids, from 2147483648 up: past what an `Int`
    /// holds where it is 32 bits wide.
    private func nextLayoutListID() throws -> Int64 {
        var ids: [Int64] = []
        if let main = data(at: package.mainPart).flatMap({ try? XMLLite.parse($0) }) {
            ids += main.firstChild(named: "sldMasterIdLst")?.children(named: "sldMasterId")
                .compactMap { $0.qualifiedAttributes["id"].flatMap(Int64.init) } ?? []
        }
        for path in resources.masterOrder {
            guard let root = data(at: path).flatMap({ try? XMLLite.parse($0) }) else { continue }
            ids += root.firstChild(named: "sldLayoutIdLst")?.children(named: "sldLayoutId")
                .compactMap { $0.qualifiedAttributes["id"].flatMap(Int64.init) } ?? []
        }
        return max(2_147_483_648, (ids.max() ?? 0) + 1)
    }

    /// A master's or layout's XML with its shapes, background and name as
    /// they were left in master view. Everything else in it stays as it was.
    private static func templateXML(
        for slide: inout Slide, base: Data, path: String, slidePaths: [Slide.ID: String]
    ) throws -> Data {
        guard let root = try? XMLLite.parse(base), let common = root.firstChild(named: "cSld"),
              let tree = common.firstChild(named: "spTree") else {
            throw PresentationWriteError.unwritablePart(path)
        }
        let scope = PPTXReader.namespacesInScope(of: tree)
        var writer = ShapeWriter(partPath: path, namespaces: scope, relationships: slide.relationships) { slidePaths[$0] }
        if slide.canEditShapes {
            for child in tree.children where !["nvGrpSpPr", "grpSpPr"].contains(child.name) {
                tree.removeChild(child)
            }
            for shape in slide.shapes {
                guard let xml = writer.xml(for: shape),
                      let element = XMLLite.fragment(xml, namespaces: scope.filter { !$0.key.isEmpty }) else {
                    throw PresentationWriteError.unwritablePart(path)
                }
                tree.insertChild(element, at: tree.children.count)
            }
        }
        if let name = slide.layoutName { common.setAttribute("name", name) }
        if slide.isBackgroundModified {
            if let existing = common.firstChild(named: "bg") { common.removeChild(existing) }
            if case .fill(let fill) = slide.background,
               let background = XMLLite.fragment(
                "<p:bg><p:bgPr>\(writer.fillXML(fill))<a:effectLst/></p:bgPr></p:bg>", namespaces: writer.fragmentNamespaces
               ) {
                common.insertChild(background, at: 0)
            }
        }
        slide.relationships = writer.relationships
        guard let xml = XMLLite.serialize(root) else { throw PresentationWriteError.unwritablePart(path) }
        return Data((PackagePath.declaration + xml).utf8)
    }

    /// A master's XML listing `layouts`, in order, as the ones it offers,
    /// with a relationship to each.
    private static func listingLayouts(
        _ layouts: [String], in data: Data, masterPath: String, relationships: inout [Relationship], nextID: inout Int64
    ) throws -> Data {
        guard let root = try? XMLLite.parse(data) else { throw PresentationWriteError.unwritablePart(masterPath) }
        let scope = PPTXReader.namespacesInScope(of: root)
        let namespaces = OOXML.namespaces.merging(scope.filter { !$0.key.isEmpty }) { _, inScope in inScope }
        guard let list = root.firstChild(named: "sldLayoutIdLst") ?? {
            let created = XMLLite.fragment("<p:sldLayoutIdLst/>", namespaces: namespaces)
            // After the colour map; before the transition, timing, header and text styles.
            let after = root.children.lastIndex { ["cSld", "clrMap"].contains($0.name) }
            if let created { root.insertChild(created, at: (after ?? -1) + 1) }
            return created
        }() else { throw PresentationWriteError.unwritablePart(masterPath) }

        var listIDs: [String: Int64] = [:]
        for entry in list.children(named: "sldLayoutId") {
            if let relationship = entry.relationshipID, let id = entry.qualifiedAttributes["id"].flatMap(Int64.init) {
                listIDs[relationship] = id
            }
        }
        for entry in list.children { list.removeChild(entry) }
        for path in layouts {
            let relationship = relationships.first {
                $0.type == OOXML.RelationshipType.slideLayout && PackagePath.resolve($0.target, from: masterPath) == path
            } ?? {
                let created = Relationship(
                    id: Relationship.unusedID(in: relationships), type: OOXML.RelationshipType.slideLayout,
                    target: PackagePath.relativeTarget(to: path, from: masterPath)
                )
                relationships.append(created)
                return created
            }()
            let id = listIDs[relationship.id] ?? {
                defer { nextID += 1 }
                return nextID
            }()
            if let entry = XMLLite.fragment("<p:sldLayoutId id=\"\(id)\" r:id=\"\(relationship.id)\"/>", namespaces: namespaces) {
                list.insertChild(entry, at: list.children.count)
            }
        }
        guard let xml = XMLLite.serialize(root) else { throw PresentationWriteError.unwritablePart(masterPath) }
        return Data((PackagePath.declaration + xml).utf8)
    }
}
