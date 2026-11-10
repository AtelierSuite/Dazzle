import Foundation

/// A slide's builds as PowerPoint animations.
///
/// Keynote keeps a build per object and a list of chunks, in playing order,
/// each naming its build. A build delivered by paragraph has a chunk per
/// paragraph. A chunk starts on a tap, or by itself after a delay; In, Out
/// and Action builds become entrance, exit and emphasis effects, each the
/// nearest of Dazzle's.
public struct KeynoteBuilds {
    public let archive: KeynoteArchive

    /// The animations, and whether any build had no counterpart.
    public func animations(_ slide: KeynoteArchive.Object, shapeIDs: [UInt64: Int]) -> (animations: [ShapeAnimation], lost: Bool) {
        var animations: [ShapeAnimation] = []
        var lost = false
        var paragraphsBuilt: [UInt64: Int] = [:]
        for chunkID in slide.message.references(43) {
            guard let chunk = archive[chunkID]?.message, let buildID = chunk.reference(1),
                  let build = archive[buildID]?.message else { continue }
            let attributes = build.message(4)?.message(18)
            guard let shapeID = build.reference(1).flatMap({ shapeIDs[$0] }),
                  let (category, effect) = Self.effect(type: attributes?.string(1), name: attributes?.string(2)) else {
                lost = true
                continue
            }
            var paragraphs: ClosedRange<Int>?
            if build.string(2)?.lowercased().contains("paragraph") == true {
                let index = paragraphsBuilt[buildID, default: 0]
                paragraphsBuilt[buildID] = index + 1
                paragraphs = index...index
            }
            animations.append(ShapeAnimation(
                shapeID: shapeID, paragraphs: paragraphs, category: category, effect: effect,
                trigger: chunk.bool(5) == true ? .afterPrevious : .onClick,
                duration: chunk.float(4) ?? attributes?.float(3), delay: chunk.float(3) ?? 0
            ))
        }
        return (animations, lost)
    }

    /// Keynote's build type and effect name as a category and effect.
    ///
    /// Keynote names its effects like `apple:dissolve` or
    /// `apple:action-rotation`, so they are matched by the words in them.
    public static func effect(type: String?, name: String?) -> (ShapeAnimation.Category, ShapeAnimation.Effect)? {
        let name = (name ?? "").lowercased()
        switch type?.lowercased() {
        case "in", "out":
            let entering = type?.lowercased() == "in"
            let category: ShapeAnimation.Category = entering ? .entrance : .exit
            let effect: ShapeAnimation.Effect? = if name.contains("appear") {
                .appear
            } else if name.contains("dissolve") || name.contains("fade") || name.contains("opacity") {
                .fade
            } else if name.contains("drift") || name.contains("float") || name.contains("rise") {
                .float
            } else if name.contains("drop") || name.contains("fall") || name.contains("anvil") {
                // Things that drop in from above, or fall away below.
                .fly(entering ? .top : .bottom)
            } else if ["move", "fly", "skid", "slide", "push", "bounce", "clothesline"].contains(where: name.contains) {
                .fly(.bottom)
            } else if name.contains("blind") {
                filter("blinds(horizontal)", id: 3, subtype: 10)
            } else if name.contains("iris") || name.contains("circle") {
                filter("circle(out)", id: 6, subtype: 32)
            } else if name.contains("grid") || name.contains("checker") {
                filter("checkerboard(across)", id: 5, subtype: 10)
            } else if ["sparkle", "shimmer", "confetti", "crumble", "blast", "shatter", "flame"].contains(where: name.contains) {
                // Effects that break the object up, or build it from specks.
                filter("dissolve", id: 9, subtype: 0)
            } else if name.contains("wipe") || name.contains("typewriter") || name.contains("keyboard")
                        || name.contains("line-draw") || name.contains("reveal") {
                .wipe(.left)
            } else if ["zoom", "scale", "pop", "compress", "squeeze", "twirl", "orbital", "spin", "blur"].contains(where: name.contains) {
                .zoom
            } else {
                // Anything without a match fades.
                .fade
            }
            return effect.map { (category, $0) }
        case "action":
            let effect: ShapeAnimation.Effect? = if name.contains("rotat") || name.contains("spin") || name.contains("flip") {
                .spin
            } else if name.contains("blink") || name.contains("pulse") || name.contains("pop") {
                .pulse
            } else if name.contains("jiggle") || name.contains("swing") || name.contains("shake") || name.contains("bounce") {
                .teeter
            } else if name.contains("scale") {
                .growShrink
            } else {
                nil
            }
            return effect.map { (.emphasis, $0) }
        default:
            return nil
        }
    }

    /// One of the filter effects PowerPoint calls by `presetID`.
    private static func filter(_ name: String, id: Int, subtype: Int) -> ShapeAnimation.Effect? {
        AnimationFilter(name).map { .filter($0, id: id, subtype: subtype) }
    }
}
