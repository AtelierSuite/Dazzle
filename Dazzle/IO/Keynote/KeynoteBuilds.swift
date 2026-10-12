import Foundation

/// A slide's builds as PowerPoint animations.
///
/// Keynote keeps a build per object and a list of chunks, in playing order,
/// each naming its build. A build delivered by paragraph has a chunk per
/// paragraph. A chunk starts on a tap, or by itself after a delay; In, Out
/// and Action builds become entrance, exit and emphasis effects, each the
/// nearest of Dazzle's.
struct KeynoteBuilds {
    let archive: KeynoteArchive

    /// The animations, and whether any build had no counterpart.
    func animations(_ slide: KeynoteArchive.Object, shapeIDs: [UInt64: Int]) -> (animations: [ShapeAnimation], lost: Bool) {
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
    static func effect(type: String?, name: String?) -> (ShapeAnimation.Category, ShapeAnimation.Effect)? {
        let name = (name ?? "").lowercased()
        switch type?.lowercased() {
        case "in", "out":
            let category: ShapeAnimation.Category = type?.lowercased() == "in" ? .entrance : .exit
            let effect: ShapeAnimation.Effect = if name.contains("appear") {
                .appear
            } else if name.contains("move") || name.contains("fly") {
                .fly(.bottom)
            } else if name.contains("wipe") {
                .wipe(.left)
            } else if name.contains("zoom") || name.contains("scale") || name.contains("pop") {
                .zoom
            } else {
                // Dissolve, and anything without a match, fades.
                .fade
            }
            return (category, effect)
        case "action":
            let effect: ShapeAnimation.Effect? = if name.contains("rotat") || name.contains("spin") {
                .spin
            } else if name.contains("blink") || name.contains("pulse") || name.contains("pop") {
                .pulse
            } else if name.contains("jiggle") {
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
}
