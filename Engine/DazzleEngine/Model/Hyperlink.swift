import Foundation

/// Where clicking a shape or a run of text goes, during a slideshow.
public enum Hyperlink: Equatable, Hashable, Sendable {
    /// A web page or other address, outside the presentation.
    case url(String)
    /// Another slide of the presentation.
    case slide(Slide.ID)
    /// A slide by its part, before slides have ids; only while reading.
    case slidePart(String)
    case nextSlide
    case previousSlide
    case firstSlide
    case lastSlide
    case endShow
    /// A custom show, played from its first slide. With `returns`, the
    /// slideshow comes back to the slide the link is on once it ends.
    case customShow(CustomShow.ID, returns: Bool)
    /// A link Dazzle does not follow, such as one that runs a macro. It is
    /// kept in the file as it was.
    case other

    public static let jumpAction = "ppaction://hlinksldjump"
    public static let showJumpAction = "ppaction://hlinkshowjump?jump="
    public static let customShowAction = "ppaction://customshow?"

    /// Reads an `a:hlinkClick`. `target` resolves its relationship id.
    public init?(element: XMLElement?, target: (String) -> Relationship?) {
        guard let element else { return nil }
        let action = element.attribute("action") ?? ""
        let relationship = element.relationshipID.flatMap { $0.isEmpty ? nil : target($0) }
        if action.hasPrefix(Self.showJumpAction) {
            switch action.dropFirst(Self.showJumpAction.count) {
            case "nextslide": self = .nextSlide
            case "previousslide": self = .previousSlide
            case "firstslide": self = .firstSlide
            case "lastslide": self = .lastSlide
            case "endshow": self = .endShow
            default: self = .other
            }
        } else if action.hasPrefix(Self.customShowAction) {
            // `id=0&return=true`
            var query: [Substring: Substring] = [:]
            for pair in action.dropFirst(Self.customShowAction.count).split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { query[parts[0]] = parts[1] }
            }
            guard let id = query["id"].flatMap({ Int($0) }) else { self = .other; return }
            self = .customShow(id, returns: query["return"] == "true")
        } else if action == Self.jumpAction, let relationship {
            self = .slidePart(relationship.target)
        } else if action.isEmpty, let relationship, relationship.isExternal {
            self = .url(relationship.target)
        } else {
            self = .other
        }
    }

    public var isCustomShow: Bool {
        if case .customShow = self { return true }
        return false
    }

    /// The `a:hlinkClick` for this link, given the id of the relationship
    /// it needs, if it needs one.
    public func xml(relationshipID: String?) -> String? {
        switch self {
        case .url:
            return relationshipID.map { "<a:hlinkClick r:id=\"\($0)\"/>" }
        case .slide:
            return relationshipID.map { "<a:hlinkClick r:id=\"\($0)\" action=\"\(Self.jumpAction)\"/>" }
        case .nextSlide: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)nextslide\"/>"
        case .previousSlide: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)previousslide\"/>"
        case .firstSlide: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)firstslide\"/>"
        case .lastSlide: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)lastslide\"/>"
        case .endShow: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)endshow\"/>"
        case .customShow(let id, let returns):
            return "<a:hlinkClick r:id=\"\" action=\"\(Self.customShowAction)id=\(id)\(returns ? "&amp;return=true" : "")\"/>"
        case .slidePart, .other: return nil
        }
    }
}

extension Presentation {
    /// Turns links to slide parts, as read, into links to the slides.
    public mutating func resolveSlideLinks() {
        let ids = Dictionary(slides.compactMap { slide in slide.partName.map { ($0, slide.id) } }) { first, _ in first }
        func resolve(_ link: Hyperlink?) -> Hyperlink? {
            guard case .slidePart(let path)? = link else { return link }
            return ids[path].map(Hyperlink.slide) ?? .other
        }
        func resolve(_ shape: inout SlideShape) {
            shape.link = resolve(shape.link)
            if var body = shape.text {
                for paragraph in body.paragraphs.indices {
                    for run in body.paragraphs[paragraph].runs.indices {
                        body.paragraphs[paragraph].runs[run].properties.link = resolve(body.paragraphs[paragraph].runs[run].properties.link)
                    }
                }
                shape.text = body
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

