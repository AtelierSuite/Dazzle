import Foundation

/// A named selection of the presentation's slides, played in an order of
/// its own: `p:custShow`.
public struct CustomShow: Identifiable, Equatable, Hashable, Sendable {
    /// The number the file and links to the show know it by.
    public var id: Int
    public var name: String
    /// Its slides, in the order it plays them. A slide can come more than once.
    public var slideIDs: [Slide.ID]

    public init(id: Int, name: String, slideIDs: [Slide.ID] = []) {
        self.id = id
        self.name = name
        self.slideIDs = slideIDs
    }
}

extension Presentation {
    public func customShow(withID id: CustomShow.ID?) -> CustomShow? {
        customShows.first { $0.id == id }
    }

    /// The indices of the slides a custom show plays, in its order, leaving
    /// out hidden ones unless every one of them is hidden.
    public func slideIndices(of show: CustomShow) -> [Int] {
        let indices = show.slideIDs.compactMap(index(of:))
        let visible = indices.filter { !slides[$0].isHidden }
        return visible.isEmpty ? indices : visible
    }

    /// The slides a slideshow plays: a custom show's when one is asked for,
    /// otherwise those the show settings choose, leaving out hidden ones.
    public func slideshowOrder(customShow: CustomShow.ID? = nil) -> [Int] {
        if let show = customShow.flatMap(self.customShow(withID:)), let order = slideIndices(of: show).nilIfEmpty {
            return order
        }
        switch showSettings.range {
        case .all:
            break
        case .slides(let from, let to):
            let range = (min(from, to) - 1)...(max(from, to) - 1)
            let chosen = slides.indices.filter { range.contains($0) }
            let visible = chosen.filter { !slides[$0].isHidden }
            if let order = (visible.isEmpty ? chosen : visible).nilIfEmpty { return order }
        case .customShow(let id):
            if let show = self.customShow(withID: id), let order = slideIndices(of: show).nilIfEmpty { return order }
        }
        return visibleSlideIndices
    }

    /// A number for a new custom show that none uses yet.
    public var unusedCustomShowID: Int {
        (customShows.map(\.id).max() ?? -1) + 1
    }
}
