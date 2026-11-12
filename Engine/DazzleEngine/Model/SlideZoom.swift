import Foundation

/// A slide zoom, section zoom, or one section of a summary zoom
/// (`pslz:sldZm`, `psez:sectionZm`, `psuz:summaryZm`): a picture of a slide
/// or section that, tapped in the slideshow, zooms into it, and when its
/// slides are done, back out to the slide it is on.
public struct SlideZoom: Equatable, Hashable, Sendable {
    public enum Target: Equatable, Hashable, Sendable {
        case slide(Slide.ID)
        case section(SlideSection.ID)
        /// A slide by its `p:sldId` number; only while reading.
        case slideNumber(String)
    }

    public var target: Target
    /// Whether the show comes back to the zoom's slide after the slide, or
    /// the section's last slide.
    public var returnsToParent = true
    /// Seconds the zoom takes to fly in and out; `nil` when the target's
    /// own transition plays instead.
    public var transitionDuration: Double?
    /// Whether the picture shows the target slide as it is now (rather than
    /// a picture chosen for it), so it is drawn from the slide.
    public var showsPreview = true
    /// Whether that picture includes the slide's background.
    public var showsBackground = true

    public init(
        target: Target, returnsToParent: Bool = true, transitionDuration: Double? = nil,
        showsPreview: Bool = true, showsBackground: Bool = true
    ) {
        self.target = target
        self.returnsToParent = returnsToParent
        self.transitionDuration = transitionDuration
        self.showsPreview = showsPreview
        self.showsBackground = showsBackground
    }

    public static let slideNamespace = "http://schemas.microsoft.com/office/powerpoint/2016/slidezoom"
    public static let sectionNamespace = "http://schemas.microsoft.com/office/powerpoint/2016/sectionzoom"
    public static let summaryNamespace = "http://schemas.microsoft.com/office/powerpoint/2016/summaryzoom"

    /// The zooms an `mc:AlternateContent` offers, in order: one for a slide
    /// or section zoom, one per section for a summary zoom.
    public static func zooms(in alternate: XMLElement) -> [SlideZoom] {
        var found: [SlideZoom] = []
        func visit(_ element: XMLElement) {
            switch element.name {
            case "sldZmObj":
                if let number = element.attribute("sldId") { found.append(zoom(.slideNumber(number), element)) }
            case "sectionZmObj", "summaryZmObj":
                if let id = element.attribute("sectionId") { found.append(zoom(.section(id), element)) }
            case "Fallback":
                return
            default:
                element.children.forEach(visit)
            }
        }
        visit(alternate)
        return found
    }

    private static func zoom(_ target: Target, _ object: XMLElement) -> SlideZoom {
        let properties = object.firstChild(named: "zmPr")
        func flag(_ name: String) -> Bool { properties?.attribute(name).map { $0 == "1" || $0 == "true" } ?? true }
        return SlideZoom(
            target: target,
            returnsToParent: flag("returnToParent"),
            transitionDuration: properties?.attribute("transitionDur").flatMap(Double.init).map { $0 / 1_000 },
            showsPreview: properties?.attribute("imageType") != "cover",
            showsBackground: flag("showBg")
        )
    }

    // MARK: - Where it leads

    /// The slides the zoom shows, as indices into the presentation: the
    /// slide, or the section's slides that are not hidden (all of them, if
    /// every one is).
    public func slideIndices(in presentation: Presentation) -> [Int] {
        switch target {
        case .slide(let id):
            return presentation.index(of: id).map { [$0] } ?? []
        case .section(let id):
            let all = presentation.slideIndices(in: id)
            let visible = all.filter { !presentation.slides[$0].isHidden }
            return visible.isEmpty ? all : visible
        case .slideNumber:
            return []
        }
    }

    /// The slide its picture shows: the slide, or the section's first.
    public func previewSlide(in presentation: Presentation) -> Slide? {
        let index: Int? = switch target {
        case .slide(let id): presentation.index(of: id)
        case .section(let id): presentation.slideIndices(in: id).first
        case .slideNumber: nil
        }
        return index.map { presentation.slides[$0] }
    }
}

extension Presentation {
    /// Points zooms read with slide numbers at the slides.
    mutating func resolveZoomTargets(numbers: [String: Slide.ID]) {
        func resolve(_ shape: inout SlideShape) {
            if case .zoom(var zoom)? = shape.link, case .slideNumber(let number) = zoom.target {
                if let id = numbers[number] {
                    zoom.target = .slide(id)
                    shape.link = .zoom(zoom)
                } else {
                    shape.link = .other
                }
            }
            if case .group(var group) = shape.kind {
                for index in group.children.indices { resolve(&group.children[index]) }
                shape.kind = .group(group)
            }
        }
        for slide in slides.indices {
            for shape in slides[slide].shapes.indices { resolve(&slides[slide].shapes[shape]) }
        }
    }
}
