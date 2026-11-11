#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

#if canImport(CoreGraphics)
/// How an outline's caps and joins are drawn.
extension LineStyle {
    var cgLineCap: CGLineCap {
        switch cap {
        case "rnd": .round
        case "sq": .square
        default: .butt
        }
    }

    /// Lines that do not say are joined round, as they always have been here.
    var cgLineJoin: CGLineJoin {
        switch join {
        case .bevel: .bevel
        case .miter: .miter
        case .round, nil: .round
        }
    }

    /// Sets the line's caps and joins for stroking.
    func applyCapAndJoin(to context: CGContext) {
        context.setLineCap(cgLineCap)
        context.setLineJoin(cgLineJoin)
        context.setMiterLimit(miterLimit)
    }
}
#endif

/// How an outline's miters and compound strokes are drawn, here and on the web.
extension LineStyle {
    /// `lim` is a percentage of the width, in thousandths; 800% unless said.
    public var miterLimit: CGFloat {
        guard case .miter(let limit) = join else { return 10 }
        return max(CGFloat(limit ?? 800_000) / 100_000, 1)
    }

    /// The strokes `path` is drawn with at `width`: the path itself for a
    /// single line, or for a compound line one path per stroke, set off to
    /// either side of it, with the width each is drawn at. The outer side
    /// is outside a closed outline, and left of an open line's direction
    /// (above a line drawn left to right).
    public func compoundStrokes(of path: CGPath, width: CGFloat) -> [(path: CGPath, width: CGFloat)] {
        let bands = compoundBands
        #if canImport(CoreGraphics)
        guard bands.count > 1, #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) else { return [(path, width)] }
        let subpaths = Self.polylines(of: path.flattened(threshold: 0.1))
        #else
        guard bands.count > 1 else { return [(path, width)] }
        let subpaths = Self.polylines(of: path)
        #endif
        return bands.map { band in
            // From the middle of the full width to the middle of this stroke, outwards.
            let offset = width * CGFloat(0.5 - (band.start + band.end) / 2)
            let stroke = CGMutablePath()
            for subpath in subpaths {
                let points = Self.offset(subpath.points, isClosed: subpath.isClosed, by: offset)
                guard points.count >= 2 else { continue }
                stroke.addLines(between: points)
                if subpath.isClosed { stroke.closeSubpath() }
            }
            return (stroke, width * CGFloat(band.end - band.start))
        }
    }

    #if canImport(CoreGraphics)
    /// A flattened path's subpaths as runs of points, without repeats.
    static func polylines(of path: CGPath) -> [(points: [CGPoint], isClosed: Bool)] {
        var result: [(points: [CGPoint], isClosed: Bool)] = []
        var points: [CGPoint] = []
        var isClosed = false
        func finish() {
            if isClosed, points.count > 1, let first = points.first, let last = points.last,
                hypot(last.x - first.x, last.y - first.y) < 0.0001 {
                points.removeLast()
            }
            if points.count >= 2 { result.append((points, isClosed)) }
            points = []
            isClosed = false
        }
        path.applyWithBlock { element in
            let element = element.pointee
            switch element.type {
            case .moveToPoint:
                finish()
                points = [element.points[0]]
            case .addLineToPoint, .addQuadCurveToPoint, .addCurveToPoint:
                let index = element.type == .addLineToPoint ? 0 : element.type == .addQuadCurveToPoint ? 1 : 2
                let point = element.points[index]
                if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 0.0001 { return }
                points.append(point)
            case .closeSubpath:
                isClosed = true
                let start = points.first
                finish()
                // Drawing may go on from where the closed subpath began.
                if let start { points = [start] }
            @unknown default:
                break
            }
        }
        finish()
        return result
    }
    #else
    /// A path's subpaths as runs of points, without repeats, its curves cut
    /// into short straight pieces.
    static func polylines(of path: CGPath) -> [(points: [CGPoint], isClosed: Bool)] {
        var result: [(points: [CGPoint], isClosed: Bool)] = []
        var points: [CGPoint] = []
        var isClosed = false
        func finish() {
            if isClosed, points.count > 1, let first = points.first, let last = points.last,
                hypot(last.x - first.x, last.y - first.y) < 0.0001 {
                points.removeLast()
            }
            if points.count >= 2 { result.append((points, isClosed)) }
            points = []
            isClosed = false
        }
        func add(_ point: CGPoint) {
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 0.0001 { return }
            points.append(point)
        }
        /// Enough pieces that each is about a point long.
        func pieces(_ hull: [CGPoint]) -> Int {
            let length = zip(hull, hull.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            return min(max(Int(length.rounded(.up)), 4), 64)
        }
        for element in path.elements {
            let start = points.last ?? .zero
            switch element {
            case .move(let point):
                finish()
                points = [point]
            case .line(let point):
                add(point)
            case .quadratic(let control, let end):
                let count = pieces([start, control, end])
                for step in 1...count {
                    let t = CGFloat(step) / CGFloat(count), u = 1 - t
                    add(CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y))
                }
            case .cubic(let c1, let c2, let end):
                let count = pieces([start, c1, c2, end])
                for step in 1...count {
                    let t = CGFloat(step) / CGFloat(count), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    add(CGPoint(x: a * start.x + b * c1.x + c * c2.x + d * end.x,
                                y: a * start.y + b * c1.y + c * c2.y + d * end.y))
                }
            case .close:
                isClosed = true
                let first = points.first
                finish()
                if let first { points = [first] }
            }
        }
        finish()
        return result
    }
    #endif

    /// `points` moved `distance` to the outer side, each corner along the
    /// bisector of its two edges so the run stays parallel to the original.
    static func offset(_ points: [CGPoint], isClosed: Bool, by distance: CGFloat) -> [CGPoint] {
        let count = points.count
        guard count >= 2, distance != 0 else { return points }
        // A closed run's outside depends on which way round it goes.
        var area: CGFloat = 0
        if isClosed {
            for index in 0..<count {
                let a = points[index], b = points[(index + 1) % count]
                area += a.x * b.y - b.x * a.y
            }
        }
        let outwards: CGFloat = area < 0 ? -1 : 1
        let edges = isClosed ? count : count - 1
        typealias Vector = (dx: CGFloat, dy: CGFloat)
        let normals: [Vector] = (0..<edges).map { index in
            let a = points[index], b = points[(index + 1) % count]
            let length = max(hypot(b.x - a.x, b.y - a.y), .ulpOfOne)
            return (dx: (b.y - a.y) / length * outwards, dy: -(b.x - a.x) / length * outwards)
        }
        return (0..<count).map { index in
            let before: Vector? = isClosed ? normals[(index - 1 + count) % count] : index > 0 ? normals[index - 1] : nil
            let after: Vector? = isClosed ? normals[index] : index < count - 1 ? normals[index] : nil
            let shift: Vector
            switch (before, after) {
            case let (before?, after?):
                // Along the bisector, as far as keeps both edges `distance` away,
                // within reason at hairpin turns.
                let scale = 1 / max(1 + before.dx * after.dx + before.dy * after.dy, 0.2)
                shift = (dx: (before.dx + after.dx) * scale, dy: (before.dy + after.dy) * scale)
            case let (normal?, nil), let (nil, normal?):
                shift = normal
            case (nil, nil):
                shift = (dx: 0, dy: 0)
            }
            return CGPoint(x: points[index].x + shift.dx * distance, y: points[index].y + shift.dy * distance)
        }
    }
}
