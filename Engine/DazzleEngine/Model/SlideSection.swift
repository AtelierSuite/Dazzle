import Foundation

/// A named run of slides, PowerPoint's `p14:section`. A presentation either
/// has no sections, or sections that between them hold every slide once, in
/// the presentation's order. A section may hold no slides at all.
public struct SlideSection: Identifiable, Equatable, Hashable, Sendable {
    /// PowerPoint's id for the section, a GUID in braces, which section
    /// zooms point at.
    public var id: String
    public var name: String
    public var slideIDs: [Slide.ID]

    public init(id: String = SlideSection.newID(), name: String, slideIDs: [Slide.ID] = []) {
        self.id = id
        self.name = name
        self.slideIDs = slideIDs
    }

    /// A GUID in braces, as PowerPoint writes one.
    public static func newID() -> String {
        "{\(UUID().uuidString)}"
    }

    /// The name PowerPoint gives the section made for the slides before
    /// the first one added.
    public static var defaultName: String { String(localized: "Section.Default", bundle: .engine) }
    /// The name a newly added section starts with.
    public static var untitledName: String { String(localized: "Section.Untitled", bundle: .engine) }
}

extension Presentation {
    /// The section a slide is in, if the presentation has sections.
    public func section(of slideID: Slide.ID) -> SlideSection? {
        sections.first { $0.slideIDs.contains(slideID) }
    }

    public func sectionIndex(of id: SlideSection.ID) -> Int? {
        sections.firstIndex { $0.id == id }
    }

    /// The indices of a section's slides, in order.
    public func slideIndices(in sectionID: SlideSection.ID) -> [Int] {
        guard let section = sections.first(where: { $0.id == sectionID }) else { return [] }
        return section.slideIDs.compactMap(index(of:))
    }

    /// Brings the sections back in step with the slides after slides were
    /// added, removed or moved, so that they again hold every slide once, in
    /// order. A new slide joins the section of the slide before it, or after
    /// it if it comes first. Where moves left a section's slides out of
    /// order, as many slides as possible keep their section, and the rest
    /// join the section they now sit in.
    public mutating func settleSections() {
        guard !sections.isEmpty else { return }
        var owner: [Slide.ID: Int] = [:]
        for (index, section) in sections.enumerated() {
            for id in section.slideIDs where owner[id] == nil { owner[id] = index }
        }
        var owners = slides.map { owner[$0.id] }
        var previous: Int?
        for index in owners.indices {
            if owners[index] == nil { owners[index] = previous } else { previous = owners[index] }
        }
        var following: Int?
        for index in owners.indices.reversed() {
            if owners[index] == nil { owners[index] = following } else { following = owners[index] }
        }
        let wanted = owners.map { $0 ?? 0 }
        let kept = Self.longestNonDecreasingRun(in: wanted)
        var current = kept.min().map { wanted[$0] } ?? 0
        var settled = sections.map { SlideSection(id: $0.id, name: $0.name) }
        for (index, slide) in slides.enumerated() {
            if kept.contains(index) { current = wanted[index] }
            settled[current].slideIDs.append(slide.id)
        }
        if settled != sections { sections = settled }
    }

    /// The positions of a longest non-decreasing subsequence of `values`.
    private static func longestNonDecreasingRun(in values: [Int]) -> Set<Int> {
        var tails: [Int] = []
        var before = [Int?](repeating: nil, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] <= value { low = middle + 1 } else { high = middle }
            }
            before[index] = low > 0 ? tails[low - 1] : nil
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result: Set<Int> = []
        var cursor = tails.last
        while let index = cursor {
            result.insert(index)
            cursor = before[index]
        }
        return result
    }

    /// Puts a slide in the section of another, just before or after it, as
    /// when it was dropped beside it.
    public mutating func placeSlide(_ id: Slide.ID, inSectionOf neighbour: Slide.ID) {
        guard let target = section(of: neighbour)?.id, section(of: id)?.id != target else { return }
        for index in sections.indices { sections[index].slideIDs.removeAll { $0 == id } }
        if let index = sectionIndex(of: target) { sections[index].slideIDs.append(id) }
        areSectionsModified = true
        settleSections()
    }

    /// The slides in the order their sections put them in.
    mutating func orderSlidesBySection() {
        let order = sections.flatMap(\.slideIDs)
        let positions = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        let reordered = slides.sorted { (positions[$0.id] ?? .max) < (positions[$1.id] ?? .max) }
        if reordered.map(\.id) != slides.map(\.id) {
            slides = reordered
            isStructureModified = true
        }
    }

    // MARK: - Editing sections

    /// Starts a new section at a slide, taking it and the slides after it
    /// in its section. With no sections yet, the slides before it go in a
    /// first section of their own; with none before it, every slide goes in
    /// the new one.
    @discardableResult
    public mutating func addSection(at slideID: Slide.ID, name: String = SlideSection.untitledName) -> SlideSection.ID? {
        guard let slideIndex = index(of: slideID) else { return nil }
        if sections.isEmpty {
            let before = slides[..<slideIndex].map(\.id)
            let new = SlideSection(name: name, slideIDs: slides[slideIndex...].map(\.id))
            sections = before.isEmpty ? [new] : [SlideSection(name: SlideSection.defaultName, slideIDs: before), new]
            areSectionsModified = true
            return new.id
        }
        settleSections()
        guard let owner = sections.firstIndex(where: { $0.slideIDs.contains(slideID) }),
              let split = sections[owner].slideIDs.firstIndex(of: slideID) else { return nil }
        let new = SlideSection(name: name, slideIDs: Array(sections[owner].slideIDs[split...]))
        sections[owner].slideIDs.removeSubrange(split...)
        sections.insert(new, at: owner + 1)
        areSectionsModified = true
        return new.id
    }

    /// Adds an empty section at the end.
    @discardableResult
    public mutating func appendSection(name: String = SlideSection.untitledName) -> SlideSection.ID {
        if sections.isEmpty {
            sections = [SlideSection(name: SlideSection.defaultName, slideIDs: slides.map(\.id))]
        }
        let new = SlideSection(name: name)
        sections.append(new)
        areSectionsModified = true
        return new.id
    }

    public mutating func renameSection(_ id: SlideSection.ID, to name: String) {
        guard let index = sectionIndex(of: id), sections[index].name != name else { return }
        sections[index].name = name
        areSectionsModified = true
    }

    /// Removes a section but keeps its slides, which join the section
    /// before it, or the one after it for the first. Removing the last
    /// section leaves the presentation without any.
    public mutating func removeSection(_ id: SlideSection.ID) {
        guard let index = sectionIndex(of: id) else { return }
        let removed = sections.remove(at: index)
        if !sections.isEmpty {
            if index > 0 {
                sections[index - 1].slideIDs += removed.slideIDs
            } else {
                sections[0].slideIDs.insert(contentsOf: removed.slideIDs, at: 0)
            }
        }
        areSectionsModified = true
    }

    /// Removes every section, keeping the slides.
    public mutating func removeAllSections() {
        guard !sections.isEmpty else { return }
        sections = []
        areSectionsModified = true
    }

    /// Moves a section, with its slides, to `destination` among the sections.
    public mutating func moveSection(_ id: SlideSection.ID, to destination: Int) {
        guard let index = sectionIndex(of: id) else { return }
        let target = min(max(destination, 0), sections.count - 1)
        guard target != index else { return }
        let section = sections.remove(at: index)
        sections.insert(section, at: target)
        areSectionsModified = true
        orderSlidesBySection()
    }

    /// Moves slides to the end of a section.
    public mutating func moveSlides(_ ids: [Slide.ID], toSection sectionID: SlideSection.ID) {
        guard sectionIndex(of: sectionID) != nil else { return }
        let moving = slides.map(\.id).filter(ids.contains)
        guard !moving.isEmpty else { return }
        for index in sections.indices { sections[index].slideIDs.removeAll(where: moving.contains) }
        if let index = sectionIndex(of: sectionID) { sections[index].slideIDs += moving }
        areSectionsModified = true
        orderSlidesBySection()
    }
}
