import CoreGraphics
import Foundation

/// A `TSD.PathSourceArchive` as DrawingML geometry.
///
/// Rounded rectangles and the simple preset shapes become their DrawingML
/// presets so they stay adjustable; everything else becomes a custom path.
enum KeynoteGeometry {
    static func xml(_ source: ProtoMessage?, size: CGSize) -> String {
        guard let source else { return preset("rect") }
        if let scalar = source.message(4) {
            let value = scalar.float(2) ?? 0
            switch scalar.int(1) ?? 0 {
            case 0:
                let shortest = min(size.width, size.height)
                let adjust = shortest > 0 ? min(value / shortest, 0.5) : 0
                return preset("roundRect", adjustments: ["adj": Int((adjust * 100_000).rounded())])
            case 1:
                return custom(polygon(sides: max(Int(value.rounded()), 3), in: natural(scalar.message(3), size)))
            default:
                return preset("chevron")
            }
        }
        if let point = source.message(3) {
            let natural = natural(point.message(3), size)
            switch point.int(1) ?? 0 {
            case 0: return preset("leftArrow")
            case 1: return preset("rightArrow")
            case 10: return preset("leftRightArrow")
            case 100:
                let points = max(Int((point.message(2)?.float(1) ?? 5).rounded()), 3)
                let inner = point.message(2)?.float(2) ?? 0.5
                return custom(star(points: points, innerRatio: inner, in: natural))
            default: return preset("plus")
            }
        }
        if let bezier = source.message(5) ?? source.message(7)?.message(1) {
            return bezierXML(bezier.message(3), natural: natural(bezier.message(2), size))
        }
        if let editable = source.message(8) {
            return custom(editablePath(editable, natural: natural(editable.message(2), size)))
        }
        if source.has(6) {
            return preset("wedgeRoundRectCallout")
        }
        return preset("rect")
    }

    private static func preset(_ name: String, adjustments: [String: Int] = [:]) -> String {
        let guides = adjustments.sorted { $0.key < $1.key }
            .map { "<a:gd name=\"\($0.key)\" fmla=\"val \($0.value)\"/>" }.joined()
        return "<a:prstGeom prst=\"\(name)\"><a:avLst>\(guides)</a:avLst></a:prstGeom>"
    }

    private static func natural(_ message: ProtoMessage?, _ fallback: CGSize) -> CGSize {
        let width = message?.float(1) ?? 0
        let height = message?.float(2) ?? 0
        return width > 0 || height > 0 ? CGSize(width: width, height: height) : fallback
    }

    // MARK: - Paths

    private struct Path {
        var size: CGSize
        var commands: [String] = []

        mutating func move(_ point: CGPoint) { commands.append("<a:moveTo>\(Self.point(point))</a:moveTo>") }
        mutating func line(_ point: CGPoint) { commands.append("<a:lnTo>\(Self.point(point))</a:lnTo>") }
        mutating func quad(_ control: CGPoint, _ point: CGPoint) {
            commands.append("<a:quadBezTo>\(Self.point(control))\(Self.point(point))</a:quadBezTo>")
        }
        mutating func curve(_ first: CGPoint, _ second: CGPoint, _ point: CGPoint) {
            commands.append("<a:cubicBezTo>\(Self.point(first))\(Self.point(second))\(Self.point(point))</a:cubicBezTo>")
        }
        mutating func close() { commands.append("<a:close/>") }

        static func point(_ point: CGPoint) -> String {
            "<a:pt x=\"\(KeynoteUnits.emu(point.x))\" y=\"\(KeynoteUnits.emu(point.y))\"/>"
        }
    }

    private static func custom(_ path: Path) -> String {
        guard !path.commands.isEmpty else { return preset("rect") }
        let width = max(KeynoteUnits.emu(path.size.width), 1)
        let height = max(KeynoteUnits.emu(path.size.height), 1)
        return """
            <a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l="0" t="0" r="r" b="b"/>\
            <a:pathLst><a:path w="\(width)" h="\(height)">\(path.commands.joined())</a:path></a:pathLst></a:custGeom>
            """
    }

    private static func point(_ message: ProtoMessage?) -> CGPoint {
        CGPoint(x: message?.float(1) ?? 0, y: message?.float(2) ?? 0)
    }

    /// A `TSP.Path`. Keynote stretches a path's bounds over its natural
    /// size, which need not be the space its points were drawn in.
    private static func bezierXML(_ message: ProtoMessage?, natural: CGSize) -> String {
        var elements = (message?.messages(1) ?? []).map { (type: $0.int(1) ?? 0, points: $0.messages(2).map(point)) }
        // Keynote ends closed paths with a move that draws nothing.
        while let last = elements.last, last.type == 1 { elements.removeLast() }
        let points = elements.flatMap(\.points)
        guard let first = points.first else { return preset("rect") }
        let bounds = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }

        let corners = Set([bounds.minX, bounds.maxX].flatMap { x in [bounds.minY, bounds.maxY].map { "\(x),\($0)" } })
        let isRectangle = bounds.width > 0 && bounds.height > 0
            && elements.allSatisfy { [1, 2, 5].contains($0.type) }
            && Set(points.map { "\($0.x),\($0.y)" }) == corners
        if isRectangle { return preset("rect") }

        func scale(_ extent: CGFloat, _ target: CGFloat) -> CGFloat { extent > 0 && target > 0 ? target / extent : 1 }
        let scaleX = scale(bounds.width, natural.width)
        let scaleY = scale(bounds.height, natural.height)
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - bounds.minX) * scaleX, y: (point.y - bounds.minY) * scaleY)
        }
        var path = Path(size: natural)
        for element in elements {
            let points = element.points.map(place)
            switch element.type {
            case 1 where points.count >= 1: path.move(points[0])
            case 2 where points.count >= 1: path.line(points[0])
            case 3 where points.count >= 2: path.quad(points[0], points[1])
            case 4 where points.count >= 3: path.curve(points[0], points[1], points[2])
            case 5: path.close()
            default: continue
            }
        }
        return custom(path)
    }

    /// Nodes with control points either side, as the shape editor keeps them.
    private static func editablePath(_ message: ProtoMessage, natural: CGSize) -> Path {
        var path = Path(size: natural)
        for subpath in message.messages(1) {
            let nodes = subpath.messages(1).map { node in
                (incoming: point(node.message(1)), point: point(node.message(2)), outgoing: point(node.message(3)))
            }
            guard let first = nodes.first else { continue }
            path.move(first.point)
            var previous = first
            for node in nodes.dropFirst() {
                path.curve(previous.outgoing, node.incoming, node.point)
                previous = node
            }
            if subpath.bool(2) ?? false {
                path.curve(previous.outgoing, first.incoming, first.point)
                path.close()
            }
        }
        return path
    }

    private static func polygon(sides: Int, in size: CGSize) -> Path {
        var path = Path(size: size)
        for index in 0..<sides {
            let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(sides)
            let point = CGPoint(x: size.width / 2 * (1 + cos(angle)), y: size.height / 2 * (1 + sin(angle)))
            index == 0 ? path.move(point) : path.line(point)
        }
        path.close()
        return path
    }

    private static func star(points: Int, innerRatio: Double, in size: CGSize) -> Path {
        var path = Path(size: size)
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? 1 : innerRatio
            let angle = -Double.pi / 2 + Double(index) * .pi / Double(points)
            let point = CGPoint(
                x: size.width / 2 * (1 + radius * cos(angle)), y: size.height / 2 * (1 + radius * sin(angle))
            )
            index == 0 ? path.move(point) : path.line(point)
        }
        path.close()
        return path
    }
}
