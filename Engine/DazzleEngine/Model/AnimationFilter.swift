import CoreGraphics
import Foundation

/// Office's named object transitions. Store the spelling so subtype and
/// direction survive import rather than guessing from a preset number.
public struct AnimationFilter: Equatable, Hashable, Sendable {
    public var name: String
    public var kind: String { String(name.prefix { $0 != "(" }) }
    public var subtype: String { name.split(separator: "(").dropFirst().first.map { String($0.dropLast()) } ?? "" }

    public static let names = ["blinds(horizontal)", "blinds(vertical)", "box(in)", "box(out)",
        "checkerboard(across)", "checkerboard(down)", "circle(in)", "circle(out)", "diamond(in)", "diamond(out)",
        "dissolve", "plus(in)", "plus(out)", "barn(inVertical)", "barn(inHorizontal)", "barn(outVertical)", "barn(outHorizontal)",
        "randombar(horizontal)", "randombar(vertical)", "strips(downLeft)", "strips(upLeft)", "strips(downRight)", "strips(upRight)",
        "wedge", "wheel(1)", "wheel(2)", "wheel(3)", "wheel(4)", "wheel(8)"]

    public init?(_ name: String) {
        guard Self.names.contains(name) else { return nil }
        self.name = name
    }

    /// A deterministic reveal mask in object coordinates, reused by the
    /// editor, slideshow, paragraphs and export. Even-odd fill handles holes.
    public func path(progress: Double, frame: CGRect) -> CGPath {
        let p = CGFloat(min(max(progress, 0), 1))
        let path = CGMutablePath()
        if p >= 1 { path.addRect(frame); return path }
        if p <= 0 { return path }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        func centered(_ fraction: CGFloat) -> CGRect {
            CGRect(x: center.x - frame.width * fraction / 2, y: center.y - frame.height * fraction / 2,
                   width: frame.width * fraction, height: frame.height * fraction)
        }
        func random(_ index: Int) -> CGFloat {
            var value = UInt32(truncatingIfNeeded: index) &+ 0x9E3779B9
            value ^= value >> 16; value &*= 0x85EBCA6B; value ^= value >> 13; value &*= 0xC2B2AE35; value ^= value >> 16
            return CGFloat(value) / CGFloat(UInt32.max)
        }
        let inward = subtype == "in" || subtype.hasPrefix("in")
        let amount = inward ? 1 - p : p
        if inward { path.addRect(frame) }
        switch kind {
        case "box": path.addRect(centered(amount))
        case "circle":
            let radius = hypot(frame.width, frame.height) * amount / 2
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        case "diamond":
            path.move(to: CGPoint(x: center.x, y: center.y - frame.height * amount))
            path.addLine(to: CGPoint(x: center.x + frame.width * amount, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + frame.height * amount))
            path.addLine(to: CGPoint(x: center.x - frame.width * amount, y: center.y)); path.closeSubpath()
        case "plus":
            // A single union outline; overlapping rectangles would cancel
            // their intersection under even-odd clipping.
            let w = frame.width * amount / 2, h = frame.height * amount / 2
            let vertices = [CGPoint(x: center.x-w,y: frame.minY), CGPoint(x: center.x+w,y: frame.minY),
                CGPoint(x: center.x+w,y: center.y-h), CGPoint(x: frame.maxX,y: center.y-h),
                CGPoint(x: frame.maxX,y: center.y+h), CGPoint(x: center.x+w,y: center.y+h),
                CGPoint(x: center.x+w,y: frame.maxY), CGPoint(x: center.x-w,y: frame.maxY),
                CGPoint(x: center.x-w,y: center.y+h), CGPoint(x: frame.minX,y: center.y+h),
                CGPoint(x: frame.minX,y: center.y-h), CGPoint(x: center.x-w,y: center.y-h)]
            path.addLines(between: vertices); path.closeSubpath()
        case "barn":
            let vertical = subtype.lowercased().contains("vertical")
            path.addRect(CGRect(x: vertical ? center.x-frame.width*amount/2 : frame.minX,
                y: vertical ? frame.minY : center.y-frame.height*amount/2,
                width: vertical ? frame.width*amount : frame.width, height: vertical ? frame.height : frame.height*amount))
        case "blinds", "randombar":
            let vertical = subtype == "vertical"
            let count = kind == "blinds" ? 8 : 32
            for i in 0..<count {
                let fraction = kind == "randombar" ? (random(i) < p ? CGFloat(1) : 0) : p
                if vertical {
                    path.addRect(CGRect(x: frame.minX+frame.width*CGFloat(i)/CGFloat(count), y: frame.minY,
                        width: frame.width/CGFloat(count)*fraction, height: frame.height))
                } else {
                    path.addRect(CGRect(x: frame.minX, y: frame.minY+frame.height*CGFloat(i)/CGFloat(count),
                        width: frame.width, height: frame.height/CGFloat(count)*fraction))
                }
            }
        case "checkerboard", "dissolve":
            let columns = kind == "dissolve" ? 32 : 16, rows = kind == "dissolve" ? 24 : 8
            for row in 0..<rows { for column in 0..<columns {
                let fraction = kind == "dissolve" ? (random(row*columns+column) < p ? CGFloat(1) : 0)
                    : min(max(p*2-CGFloat((row+column)%2), 0), 1)
                let down = subtype == "down"
                path.addRect(CGRect(x: frame.minX+frame.width*CGFloat(column)/CGFloat(columns),
                    y: frame.minY+frame.height*CGFloat(row)/CGFloat(rows),
                    width: frame.width/CGFloat(columns)*(down ? 1 : fraction),
                    height: frame.height/CGFloat(rows)*(down ? fraction : 1)))
            } }
        case "wheel", "wedge":
            let spokes = kind == "wedge" ? 1 : max(Int(subtype) ?? 1, 1)
            let radius = hypot(frame.width, frame.height)/2
            for i in 0..<spokes {
                let angle = -.pi/2 + CGFloat(i)*2 * .pi/CGFloat(spokes)
                let start = kind == "wedge" ? angle - .pi*p : angle
                let end = kind == "wedge" ? angle + .pi*p : angle + 2 * .pi*p/CGFloat(spokes)
                path.move(to: center)
                path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                path.closeSubpath()
            }
        case "strips":
            let left = subtype.lowercased().contains("left"), up = subtype.lowercased().hasPrefix("up")
            let vertices = [CGPoint(x: frame.minX,y: frame.minY),CGPoint(x: frame.maxX,y: frame.minY),
                            CGPoint(x: frame.maxX,y: frame.maxY),CGPoint(x: frame.minX,y: frame.maxY)]
            func distance(_ point: CGPoint) -> CGFloat {
                (left ? frame.maxX-point.x : point.x-frame.minX) + (up ? frame.maxY-point.y : point.y-frame.minY)
                    - p*(frame.width+frame.height)
            }
            var clipped: [CGPoint] = []
            for i in vertices.indices {
                let a = vertices[i], b = vertices[(i+1)%vertices.count], da = distance(a), db = distance(b)
                if da <= 0 { clipped.append(a) }
                if (da <= 0) != (db <= 0) {
                    let t = da/(da-db); clipped.append(CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))
                }
            }
            path.addLines(between: clipped); path.closeSubpath()
        default: path.addRect(frame)
        }
        return path
    }
}
