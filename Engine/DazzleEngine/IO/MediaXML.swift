import Foundation

/// Reads and writes how a slide's videos and sounds play, which PowerPoint
/// keeps in the slide's timing rather than with the picture: a `p:video` or
/// `p:audio` node per media shape, beside the main sequence.
///
/// Trimming and fades are the picture's own, in its `p14:media`, and are
/// read and written with the rest of the shape.
public enum MediaXML {
    // MARK: - Reading

    /// Sets each media shape's playback settings from its node in `timing`.
    public static func read(_ timing: XMLElement, into shapes: inout [SlideShape]) {
        var nodes: [Int: XMLElement] = [:]
        func visit(_ element: XMLElement) {
            if ["video", "audio"].contains(element.name), let id = shapeID(of: element), nodes[id] == nil {
                nodes[id] = element
            }
            element.children.forEach(visit)
        }
        visit(timing)
        guard !nodes.isEmpty else { return }
        apply(nodes, to: &shapes)
    }

    private static func apply(_ nodes: [Int: XMLElement], to shapes: inout [SlideShape]) {
        for index in shapes.indices {
            switch shapes[index].kind {
            case .picture(var picture):
                guard var media = picture.media, let node = nodes[shapes[index].shapeID] else { continue }
                read(node, into: &media)
                picture.media = media
                shapes[index].kind = .picture(picture)
            case .group(var group):
                apply(nodes, to: &group.children)
                shapes[index].kind = .group(group)
            default:
                continue
            }
        }
    }

    private static func read(_ node: XMLElement, into media: inout SlideShape.Media) {
        let common = node.firstChild(named: "cMediaNode")
        let timing = common?.firstChild(named: "cTn")
        // The schema's default volume is half; PowerPoint writes it out.
        media.volume = (common?.attribute("vol").flatMap(Double.init) ?? 50_000) / 100_000
        media.isMuted = isTrue(common?.attribute("mute"))
        media.hidesWhenNotPlaying = common?.attribute("showWhenStopped").map { !isTrue($0) } ?? false
        media.playsAcrossSlides = (common?.attribute("numSld").flatMap(Int.init) ?? 1) > 1
        media.loops = timing?.attribute("repeatCount") == "indefinite"
        media.rewinds = timing?.attribute("fill") == "remove"
        media.playsFullScreen = node.name == "video" && isTrue(node.attribute("fullScrn"))
    }

    // MARK: - Writing

    /// Writes the playback settings of the media shapes in `changed` into
    /// the slide's timing: into each one's node if it has one, or a new node
    /// if its settings are not PowerPoint's defaults.
    public static func write(_ shapes: [SlideShape], changed: Set<Int>, into root: XMLElement) {
        let media = shapes.compactMap { shape -> (Int, SlideShape.Media)? in
            guard changed.contains(shape.shapeID), case .picture(let picture) = shape.kind, let media = picture.media else {
                return nil
            }
            return (shape.shapeID, media)
        }
        guard !media.isEmpty else { return }
        var existing: [Int: XMLElement] = [:]
        if let timing = root.firstChild(named: "timing") {
            func visit(_ element: XMLElement) {
                if ["video", "audio"].contains(element.name), let id = shapeID(of: element), existing[id] == nil {
                    existing[id] = element
                }
                element.children.forEach(visit)
            }
            visit(timing)
        }
        for (shapeID, settings) in media {
            if let node = existing[shapeID] {
                write(settings, into: node)
            } else if settings.hasTimingSettings, let list = rootList(in: root) {
                let nextID = (AnimationXML.allNodeIDs(in: root.firstChild(named: "timing") ?? root).max() ?? 1) + 1
                guard let node = XMLLite.fragment(nodeXML(shapeID: shapeID, media: settings, id: nextID),
                                                  namespaces: OOXML.namespaces) else { continue }
                write(settings, into: node)
                list.insertChild(node, at: list.children.count)
            }
        }
    }

    private static func write(_ media: SlideShape.Media, into node: XMLElement) {
        let common = node.firstChild(named: "cMediaNode")
        let timing = common?.firstChild(named: "cTn")
        common?.setAttribute("vol", String(Int((min(max(media.volume, 0), 1) * 100_000).rounded())))
        common?.setAttribute("mute", media.isMuted ? "1" : nil)
        common?.setAttribute("showWhenStopped", media.hidesWhenNotPlaying ? "0" : nil)
        if media.playsAcrossSlides {
            if (common?.attribute("numSld").flatMap(Int.init) ?? 1) <= 1 { common?.setAttribute("numSld", "999") }
        } else {
            common?.setAttribute("numSld", nil)
        }
        timing?.setAttribute("repeatCount", media.loops ? "indefinite" : nil)
        timing?.setAttribute("fill", media.rewinds ? "remove" : "hold")
        if node.name == "video" { node.setAttribute("fullScrn", media.playsFullScreen ? "1" : nil) }
    }

    private static func nodeXML(shapeID: Int, media: SlideShape.Media, id: Int) -> String {
        let name = media.kind == .audio ? "audio" : "video"
        return """
            <p:\(name)><p:cMediaNode vol="100000"><p:cTn id="\(id)" fill="hold" display="0"><p:stCondLst>\
            <p:cond delay="indefinite"/></p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid="\(shapeID)"/></p:tgtEl>\
            </p:cMediaNode></p:\(name)>
            """
    }

    /// The list the timing's root node plays, made with the timing if the slide has none.
    private static func rootList(in root: XMLElement) -> XMLElement? {
        if root.firstChild(named: "timing") == nil,
           let created = XMLLite.fragment(AnimationXML.emptyTiming, namespaces: OOXML.namespaces) {
            // After the slide's transition; before its extensions.
            let after = root.children.lastIndex { ["cSld", "clrMapOvr", "transition", "AlternateContent"].contains($0.name) }
            root.insertChild(created, at: (after ?? 0) + 1)
        }
        return root.firstChild(named: "timing")?.firstDescendant(atPath: "tnLst/par/cTn/childTnLst")
    }

    // MARK: - Helpers

    private static func shapeID(of node: XMLElement) -> Int? {
        node.firstDescendant(atPath: "cMediaNode/tgtEl/spTgt")?.attribute("spid").flatMap(Int.init)
    }

    private static func isTrue(_ value: String?) -> Bool {
        value == "1" || value == "true"
    }
}
