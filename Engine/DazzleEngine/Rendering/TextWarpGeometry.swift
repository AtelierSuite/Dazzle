#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A WordArt warp (`a:prstTxWarp`) laid over a text box: the lines the
/// preset's paths draw there, and where a point of the laid-out text lands
/// on them. Shared by the Apple apps' text drawing and the web app, which
/// places its letters the same way from the guides the engine sends it.
///
/// The paths come from ECMA-376's presetTextWarpDefinitions.xml. An even
/// number of them pairs up, top and bottom: the text's lines are stretched
/// between each pair, across its whole length and from the top of their
/// letters to the bottom. An odd number (arches, circles, the button) are
/// each a line the text runs along: its letters keep their shapes, spread
/// evenly from one end to the other (and shrunk if the line is longer than
/// the path), the first line's baseline on the path, or where the letters
/// would stand out of the box, the tops of its letters, so they hang inside
/// it; the lines after it are set off below. Lines are shared out between
/// bands in turn.
public struct TextWarpGeometry: Sendable {
    /// A path the text is laid along, cut into short straight pieces.
    public struct Guide: Sendable {
        public let points: [CGPoint]
        /// How far along the path each point is.
        let distances: [CGFloat]

        public var length: CGFloat { distances.last ?? 0 }

        public init(points: [CGPoint]) {
            self.points = points
            var distances: [CGFloat] = []
            var total: CGFloat = 0
            for (index, point) in points.enumerated() {
                if index > 0 { total += hypot(point.x - points[index - 1].x, point.y - points[index - 1].y) }
                distances.append(total)
            }
            self.distances = distances
        }

        /// The point `fraction` of the way along the path, and which way the
        /// path runs there; past either end, straight on from it.
        public func position(at fraction: CGFloat) -> (point: CGPoint, tangent: CGPoint) {
            guard points.count > 1, length > 0 else { return (points.first ?? .zero, CGPoint(x: 1, y: 0)) }
            let distance = fraction * length
            // The piece the distance falls in: the first or last when it is off the end.
            var low = 0
            var high = distances.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if distances[middle] <= distance { low = middle } else { high = middle }
            }
            // Skip pieces of no length, which have no direction.
            while low > 0, distances[low + 1] - distances[low] <= 0 { low -= 1 }
            let start = points[low], end = points[low + 1]
            let span = distances[low + 1] - distances[low]
            guard span > 0 else { return (start, CGPoint(x: 1, y: 0)) }
            let tangent = CGPoint(x: (end.x - start.x) / span, y: (end.y - start.y) / span)
            let along = distance - distances[low]
            return (CGPoint(x: start.x + tangent.x * along, y: start.y + tangent.y * along), tangent)
        }
    }

    public enum Band: Sendable {
        /// Lines stretched between two paths.
        case between(top: Guide, bottom: Guide)
        /// Lines run along a path.
        case along(Guide)
    }

    /// Where a band's lines lie in the laid-out text, in the text's own
    /// space, its y axis pointing down.
    public struct Placement: Equatable, Sendable {
        public var band: Int
        /// Between two paths: the top of the band's letters, and how tall they stand.
        public var top: CGFloat
        public var height: CGFloat
        /// Along a path: how far down the text the path runs, the first
        /// line's baseline or the top of its letters.
        public var baseline: CGFloat

        public init(band: Int, top: CGFloat = 0, height: CGFloat = 1, baseline: CGFloat = 0) {
            self.band = band
            self.top = top
            self.height = height
            self.baseline = baseline
        }
    }

    public let bands: [Band]
    /// The box the warp is laid over.
    public let rect: CGRect

    /// Whether `warp` leaves the text as it is: none, `textNoShape`, or a preset Dazzle doesn't know.
    public static func isFlat(_ warp: TextWarp?) -> Bool {
        guard let warp else { return true }
        return PresetShapeDefinition.textWarp(named: warp.preset) == nil
    }

    /// The warp laid over a text box at `rect`, or nil when it leaves the text flat.
    public init?(_ warp: TextWarp?, in rect: CGRect) {
        guard let warp, let definition = PresetShapeDefinition.textWarp(named: warp.preset),
              rect.width > 0, rect.height > 0 else { return nil }
        self.rect = rect
        let guides = definition.draw(adjustments: warp.adjustments, in: rect).map { Guide(points: Self.points(of: $0.outline)) }
        guard !guides.isEmpty else { return nil }
        if guides.count % 2 == 0 {
            bands = stride(from: 0, to: guides.count, by: 2).map { .between(top: guides[$0], bottom: guides[$0 + 1]) }
        } else {
            bands = guides.map { .along($0) }
        }
    }

    public init(bands: [Band], rect: CGRect) {
        self.bands = bands
        self.rect = rect
    }

    /// Where band `band`'s lines lie: their letters reaching from `top` to
    /// `bottom` down the text, the first line's baseline at `baseline`.
    public func placement(band: Int, top: CGFloat, bottom: CGFloat, baseline: CGFloat) -> Placement {
        var placement = Placement(band: band, top: top, height: max(bottom - top, 0.01), baseline: baseline)
        if case .along(let guide) = bands[min(max(band, 0), bands.count - 1)], standsOut(guide) {
            placement.baseline = top
        }
        return placement
    }

    /// Whether letters standing on `guide` point out of the box: whether, at
    /// its middle, up from the path leads away from the box's centre.
    public func standsOut(_ guide: Guide) -> Bool {
        let (point, tangent) = guide.position(at: 0.5)
        let away = CGPoint(x: point.x - rect.midX, y: point.y - rect.midY)
        // Up from a path running left to right is to its left.
        let up = CGPoint(x: tangent.y, y: -tangent.x)
        return away.x * up.x + away.y * up.y > 0.25 * hypot(away.x, away.y)
    }

    /// The band line `index` of `count` is laid in: the lines shared out in
    /// turn, the earlier bands taking any left over.
    public func band(forLine index: Int, of count: Int) -> Int {
        guard count > 0, !bands.isEmpty else { return 0 }
        return min(index * bands.count / count, bands.count - 1)
    }

    /// Where the point `x` along a line `lineWidth` long, and `y` down the
    /// text, lands.
    public func point(_ placement: Placement, x: CGFloat, lineWidth: CGFloat, y: CGFloat) -> CGPoint {
        let fraction = lineWidth > 0 ? x / lineWidth : 0.5
        switch bands[min(max(placement.band, 0), bands.count - 1)] {
        case .between(let top, let bottom):
            let v = placement.height > 0 ? (y - placement.top) / placement.height : 0
            let upper = top.position(at: fraction).point
            let lower = bottom.position(at: fraction).point
            return CGPoint(x: upper.x + (lower.x - upper.x) * v, y: upper.y + (lower.y - upper.y) * v)
        case .along(let guide):
            // Below the baseline is to the path's right, which is down a path running left to right.
            let (point, tangent) = guide.position(at: fraction)
            let below = y - placement.baseline
            return CGPoint(x: point.x - tangent.y * below, y: point.y + tangent.x * below)
        }
    }

    /// Takes a letter, in its own space (its origin on the baseline where
    /// it starts, its y axis pointing up), to where it lands: it runs from
    /// `start` to `end` along a line `lineWidth` long whose baseline is at
    /// `baseline`, and `ascent` up from there is mapped too, so it stands
    /// as tall as the warp makes it there.
    public func letterTransform(
        _ placement: Placement, from start: CGFloat, to end: CGFloat, lineWidth: CGFloat, baseline: CGFloat, ascent: CGFloat
    ) -> CGAffineTransform {
        if case .along(let guide) = bands[min(max(placement.band, 0), bands.count - 1)] {
            // Upright on the path where its middle falls, as wide as it is, shrunk only to fit the line in.
            let width = end - start
            let scale = lineWidth > guide.length && lineWidth > 0 ? guide.length / lineWidth : 1
            let (_, tangent) = guide.position(at: lineWidth > 0 ? (start + width / 2) / lineWidth : 0.5)
            let foot = point(placement, x: start + width / 2, lineWidth: lineWidth, y: baseline)
            return CGAffineTransform(
                a: tangent.x * scale, b: tangent.y * scale, c: tangent.y * scale, d: -tangent.x * scale,
                tx: foot.x - tangent.x * scale * width / 2, ty: foot.y - tangent.y * scale * width / 2
            )
        }
        let width = max(end - start, 0.01)
        let rise = max(ascent, 0.01)
        let middle = start + width / 2
        let origin = point(placement, x: start, lineWidth: lineWidth, y: baseline)
        let across = point(placement, x: start + width, lineWidth: lineWidth, y: baseline)
        let foot = point(placement, x: middle, lineWidth: lineWidth, y: baseline)
        let head = point(placement, x: middle, lineWidth: lineWidth, y: baseline - rise)
        return CGAffineTransform(
            a: (across.x - origin.x) / width, b: (across.y - origin.y) / width,
            c: (head.x - foot.x) / rise, d: (head.y - foot.y) / rise,
            tx: origin.x, ty: origin.y
        )
    }

    /// A path's points, its curves cut into short straight pieces, its subpaths run together.
    private static func points(of path: CGPath) -> [CGPoint] {
        #if canImport(CoreGraphics)
        guard #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) else { return LineStyle.polylines(of: path).flatMap(\.points) }
        let flat = path.flattened(threshold: 0.25)
        #else
        let flat = path
        #endif
        return LineStyle.polylines(of: flat).flatMap(\.points)
    }
}

extension PresetShapeDefinition {
    /// A text warp's definition, by its preset name.
    static func textWarp(named name: String) -> PresetShapeDefinition? { textWarps[name] }

    private static let textWarps: [String: PresetShapeDefinition] = encodedTextWarps.compactMapValues(PresetShapeDefinition.init(encoded:))
}
