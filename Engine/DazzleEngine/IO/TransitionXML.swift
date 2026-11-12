import Foundation

/// Writing a slide's transition as `p:transition`, for a transition Dazzle
/// set rather than read. One it read is left exactly as the file had it.
enum TransitionXML {
    static let p14 = "http://schemas.microsoft.com/office/powerpoint/2010/main"
    static let markupCompatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"

    /// The effect element, as PowerPoint 2007 reads it, and as PowerPoint
    /// 2010 and later do when that differs.
    static func elements(for effect: SlideTransition.Effect) -> (plain: String, p14: String?) {
        func dir(_ direction: SlideTransition.Direction, default fallback: SlideTransition.Direction = .left) -> String {
            direction == fallback ? "" : " dir=\"\(direction.rawValue)\""
        }
        func orientation(_ vertical: Bool) -> String { vertical ? " dir=\"vert\"" : "" }
        switch effect {
        case .cut(let black): return ("<p:cut\(black ? " thruBlk=\"1\"" : "")/>", nil)
        case .fade(let black): return ("<p:fade\(black ? " thruBlk=\"1\"" : "")/>", nil)
        case .flash: return ("<p:fade/>", "<p14:flash/>")
        case .push(let direction): return ("<p:push\(dir(direction))/>", nil)
        case .wipe(let direction): return ("<p:wipe\(dir(direction))/>", nil)
        case .cover(let direction): return ("<p:cover\(dir(direction))/>", nil)
        case .uncover(let direction): return ("<p:pull\(dir(direction))/>", nil)
        case .split(let vertical, let outward):
            return ("<p:split\(vertical ? " orient=\"vert\"" : "")\(outward ? "" : " dir=\"in\"")/>", nil)
        case .zoom(let outward): return ("<p:zoom\(outward ? " dir=\"out\"" : "")/>", nil)
        case .newsflash: return ("<p:newsflash/>", nil)
        case .comb(let vertical): return ("<p:comb\(orientation(vertical))/>", nil)
        case .random: return ("<p:random/>", nil)
        // Only ever played, for a zoom; its slide keeps its own transition.
        case .zoomObject: return ("<p:fade/>", nil)
        case .pattern(let filter):
            let vertical = ["vertical", "down"].contains(filter.subtype)
            switch filter.kind {
            case "blinds": return ("<p:blinds\(orientation(vertical))/>", nil)
            case "checkerboard": return ("<p:checker\(orientation(vertical))/>", nil)
            case "randombar": return ("<p:randomBar\(orientation(vertical))/>", nil)
            case "dissolve": return ("<p:dissolve/>", nil)
            case "circle": return ("<p:circle/>", nil)
            case "diamond": return ("<p:diamond/>", nil)
            case "plus": return ("<p:plus/>", nil)
            case "wedge": return ("<p:wedge/>", nil)
            case "wheel": return ("<p:wheel\(filter.subtype == "4" ? "" : " spokes=\"\(filter.subtype)\"")/>", nil)
            case "strips":
                let direction = switch filter.subtype {
                case "upRight": "ru"
                case "downLeft": "ld"
                case "downRight": "rd"
                default: "lu"
                }
                return ("<p:strips\(direction == "lu" ? "" : " dir=\"\(direction)\"")/>", nil)
            case "barn":
                return elements(for: .split(vertical: filter.subtype.hasSuffix("Vertical"), outward: filter.subtype.hasPrefix("out")))
            default: return ("<p:fade/>", nil)
            }
        }
    }

    /// `p:transition`, inside an `mc:AlternateContent` that gives PowerPoint
    /// 2010 and later its exact duration (`p14:dur`) and own effect, with
    /// the nearest speed for older readers.
    static func xml(for transition: SlideTransition?, advanceAfter: Double?, advancesOnClick: Bool) -> String? {
        var advance = advancesOnClick ? "" : " advClick=\"0\""
        if let advanceAfter { advance += " advTm=\"\(Int((advanceAfter * 1_000).rounded()))\"" }
        guard let transition, transition.effect != .cut(throughBlack: false) || transition.duration > 0 else {
            return advance.isEmpty ? nil : "<p:transition\(advance)/>"
        }
        let speed = transition.duration < 0.625 ? "fast" : transition.duration < 0.875 ? "med" : "slow"
        let (plain, newer) = elements(for: transition.effect)
        let milliseconds = Int((transition.duration * 1_000).rounded())
        return """
            <mc:AlternateContent xmlns:mc="\(markupCompatibility)" xmlns:p14="\(p14)"><mc:Choice Requires="p14">\
            <p:transition spd="\(speed)" p14:dur="\(milliseconds)"\(advance)>\(newer ?? plain)</p:transition>\
            </mc:Choice><mc:Fallback><p:transition spd="\(speed)"\(advance)>\(plain)</p:transition></mc:Fallback>\
            </mc:AlternateContent>
            """
    }
}
