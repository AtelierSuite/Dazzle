#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

extension SlideTransition {
    /// One of the effects PowerPoint 2010 and 2013 added, played as itself.
    ///
    /// A transition's layers are flat pictures of the two slides, placed,
    /// clipped and faded, so the ones PowerPoint turns in space are drawn
    /// as that looks from the front: a door swinging open narrows towards
    /// its hinge, a page turning over shows its back.
    public struct Preset: Equatable, Hashable, Sendable {
        /// The effect, named as PowerPoint writes it.
        public enum Kind: String, CaseIterable, Sendable {
            // PowerPoint 2010's, each an element of its own (`p14`).
            case vortex, `switch`, flip, ferris, gallery, conveyor, doors, window, glitter, honeycomb, shred, ripple
            // PowerPoint 2013's, the values of `p15:prstTrans`.
            case fallOver, drape, curtains, wind, prestige, fracture, crush, peelOff, pageCurlDouble, pageCurlSingle
            case airplane, origami

            /// Whether PowerPoint writes it as a `p15:prstTrans`.
            public var isPresetTransition: Bool {
                switch self {
                case .vortex, .switch, .flip, .ferris, .gallery, .conveyor, .doors, .window, .glitter, .honeycomb, .shred,
                     .ripple:
                    false
                default: true
                }
            }
        }

        public var kind: Kind
        /// The way it travels, for the ones PowerPoint 2010 gives a choice:
        /// a vortex and glitter any of the four ways, a switch, flip, Ferris
        /// wheel, gallery and conveyor left or right, a ripple towards a
        /// corner (`nil` for out from the middle). Doors and a window open
        /// sideways unless this is up or down.
        public var direction: Direction?
        /// Glitter's diamonds rather than hexagons, and a shred's particles
        /// rather than strips.
        public var isAlternatePattern: Bool
        /// The other way round: a shred's pieces flying apart rather than
        /// coming together, and PowerPoint 2013's effects mirrored (`invX`).
        public var isReversed: Bool

        public init(_ kind: Kind, direction: Direction? = nil, isAlternatePattern: Bool = false, isReversed: Bool = false) {
            self.kind = kind
            self.direction = direction
            self.isAlternatePattern = isAlternatePattern
            self.isReversed = isReversed
        }
    }
}

// MARK: - Reading and writing

extension SlideTransition.Preset {
    /// The preset an effect element describes, or `nil` when it is not one.
    init?(element: XMLElement) {
        let dir = element.attribute("dir")
        let direction = dir.flatMap(SlideTransition.Direction.init(rawValue:))
        func isOn(_ name: String) -> Bool { element.attribute(name) == "1" || element.attribute(name) == "true" }
        if element.name == "prstTrans" {
            guard let kind = element.attribute("prst").flatMap(Kind.init(rawValue:)), kind.isPresetTransition else { return nil }
            self.init(kind, isReversed: isOn("invX"))
            return
        }
        guard let kind = Kind(rawValue: element.name), !kind.isPresetTransition else { return nil }
        switch kind {
        case .doors, .window: self.init(kind, direction: dir == "horz" ? .up : nil)
        case .glitter: self.init(kind, direction: direction, isAlternatePattern: element.attribute("pattern") == "diamond")
        case .shred: self.init(kind, isAlternatePattern: element.attribute("pattern") == "rectangle", isReversed: dir == "out")
        case .honeycomb: self.init(kind)
        default: self.init(kind, direction: direction)
        }
    }

    /// The effect element, as PowerPoint writes it.
    var xml: String {
        if kind.isPresetTransition {
            return "<p15:prstTrans prst=\"\(kind.rawValue)\"\(isReversed ? " invX=\"1\"" : "")/>"
        }
        var attributes = ""
        switch kind {
        case .doors, .window:
            attributes = " dir=\"\(direction == .up || direction == .down ? "horz" : "vert")\""
        case .shred:
            attributes = " pattern=\"\(isAlternatePattern ? "rectangle" : "strip")\" dir=\"\(isReversed ? "out" : "in")\""
        case .ripple:
            attributes = " dir=\"\(direction.map { $0.isDiagonal ? $0.rawValue : "center" } ?? "center")\""
        case .honeycomb: break
        default:
            if let direction { attributes = " dir=\"\(direction.rawValue)\"" }
            if kind == .glitter { attributes += " pattern=\"\(isAlternatePattern ? "diamond" : "hexagon")\"" }
        }
        return "<p14:\(kind.rawValue)\(attributes)/>"
    }
}

// MARK: - Playing

extension SlideTransition.Preset {
    typealias Layer = TransitionFrame.Layer

    /// The effect `t` of the way through (0 to 1) on a slide of `size`
    /// points: the same layers at every moment.
    func layers(progress t: Double, size: CGSize) -> [Layer] {
        let stage = Stage(size: size)
        let layers = stage.layers(of: self, at: CGFloat(min(max(t, 0), 1)))
        guard isReversed, kind.isPresetTransition else { return layers }
        // Drawn travelling one way; the other is its mirror image.
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
        return layers.map { layer in
            var layer = layer
            layer.transform = mirror.concatenating(layer.transform).concatenating(mirror)
            if let clip = layer.clip, !clip.isEmpty {
                let mirrored = CGMutablePath()
                mirrored.addPath(clip, transform: mirror)
                layer.clip = mirrored
            }
            return layer
        }
    }
}

/// The slide's bounds, and the pieces the effects are made of.
private struct Stage {
    typealias Layer = TransitionFrame.Layer
    typealias Content = TransitionFrame.Content

    let width: CGFloat
    let height: CGFloat

    init(size: CGSize) {
        width = size.width
        height = size.height
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    var center: CGPoint { CGPoint(x: width / 2, y: height / 2) }

    // MARK: Timing

    func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
    /// Eased in and out.
    func smooth(_ value: CGFloat) -> CGFloat {
        let t = clamp(value)
        return t * t * (3 - 2 * t)
    }
    /// How far `t` is from `start` to `end`.
    func ramp(_ t: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat { clamp((t - start) / (end - start)) }
    /// The same number from 0 to 1 for the same piece, every time.
    func noise(_ index: Int) -> CGFloat {
        var value = UInt32(truncatingIfNeeded: index) &+ 0x9E3779B9
        value ^= value >> 16; value &*= 0x85EBCA6B; value ^= value >> 13; value &*= 0xC2B2AE35; value ^= value >> 16
        return CGFloat(value) / CGFloat(UInt32.max)
    }

    // MARK: Placing

    func move(_ x: CGFloat, _ y: CGFloat) -> CGAffineTransform { CGAffineTransform(translationX: x, y: y) }
    /// `transform` with `point` as its origin.
    func about(_ point: CGPoint, _ transform: CGAffineTransform) -> CGAffineTransform {
        move(-point.x, -point.y).concatenating(transform).concatenating(move(point.x, point.y))
    }
    func scale(_ x: CGFloat, _ y: CGFloat? = nil) -> CGAffineTransform { CGAffineTransform(scaleX: x, y: y ?? x) }
    func turn(_ angle: CGFloat) -> CGAffineTransform { CGAffineTransform(rotationAngle: angle) }
    /// Scaled, with y leaning by `tilt` for each point across: how a sheet
    /// turning about an upright axis looks from the front.
    func turned(width: CGFloat, height: CGFloat = 1, tilt: CGFloat = 0) -> CGAffineTransform {
        CGAffineTransform(a: width, b: tilt, c: 0, d: height, tx: 0, ty: 0)
    }

    // MARK: Shapes

    func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        add(points, to: path)
        return path
    }

    func add(_ points: [CGPoint], to path: CGMutablePath) {
        guard points.count > 2 else { return }
        path.addLines(between: points)
        path.closeSubpath()
    }

    func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    func centroid(_ points: [CGPoint]) -> CGPoint {
        let count = CGFloat(max(points.count, 1))
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / count, y: points.reduce(0) { $0 + $1.y } / count)
    }

    /// A piece of a slide, cut out along `points` and carried by `transform`.
    /// Cut a hair large, so pieces lying side by side show no seam.
    func piece(_ content: Content, _ points: [CGPoint], _ transform: CGAffineTransform, opacity: CGFloat = 1) -> Layer {
        let grown = grown(points, by: 0.5)
        return Layer(content: content, opacity: Double(clamp(opacity)),
                     transform: content == .black || content == .white ? .identity : transform,
                     clip: polygon(grown.map { $0.applying(transform) }))
    }

    /// An outline with every side moved `amount` outwards.
    func grown(_ points: [CGPoint], by amount: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var area: CGFloat = 0
        for (index, point) in points.enumerated() {
            let next = points[(index + 1) % points.count]
            area += point.x * next.y - next.x * point.y
        }
        let outward: CGFloat = area >= 0 ? 1 : -1
        /// The unit normal of the side from `a` to `b`, pointing out.
        func normal(_ a: CGPoint, _ b: CGPoint) -> CGPoint? {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0.0001 else { return nil }
            return CGPoint(x: (b.y - a.y) / length * outward, y: -(b.x - a.x) / length * outward)
        }
        return points.indices.map { index in
            let point = points[index]
            let before = normal(points[(index + points.count - 1) % points.count], point)
            let after = normal(point, points[(index + 1) % points.count])
            guard let first = before ?? after, let second = after ?? before else { return point }
            // Where the two moved sides meet, kept from running away at a sharp corner.
            let reach = amount / max(1 + first.x * second.x + first.y * second.y, 0.25)
            return CGPoint(x: point.x + (first.x + second.x) * reach, y: point.y + (first.y + second.y) * reach)
        }
    }

    /// The whole of a slide.
    func whole(_ content: Content, _ transform: CGAffineTransform = .identity, opacity: CGFloat = 1) -> Layer {
        Layer(content: content, opacity: Double(clamp(opacity)), transform: transform)
    }

    /// The part of a convex polygon on the side of the line through `point`
    /// that `normal` points away from (or towards, when `beyond`).
    func cut(_ points: [CGPoint], at point: CGPoint, normal: CGPoint, beyond: Bool) -> [CGPoint] {
        func distance(_ p: CGPoint) -> CGFloat {
            let d = (p.x - point.x) * normal.x + (p.y - point.y) * normal.y
            return beyond ? -d : d
        }
        var result: [CGPoint] = []
        for (index, current) in points.enumerated() {
            let next = points[(index + 1) % points.count]
            let a = distance(current), b = distance(next)
            if a <= 0 { result.append(current) }
            if (a < 0 && b > 0) || (a > 0 && b < 0) {
                let f = a / (a - b)
                result.append(CGPoint(x: current.x + (next.x - current.x) * f, y: current.y + (next.y - current.y) * f))
            }
        }
        return result
    }

    /// Each point `fraction` of the way from one outline to another of as many points.
    func blend(_ from: [CGPoint], _ to: [CGPoint], _ fraction: CGFloat) -> [CGPoint] {
        zip(from, to).map { CGPoint(x: $0.x + ($1.x - $0.x) * fraction, y: $0.y + ($1.y - $0.y) * fraction) }
    }

    /// Points of the slide's outline given as fractions of its size.
    func points(_ fractions: [(CGFloat, CGFloat)]) -> [CGPoint] {
        fractions.map { CGPoint(x: $0.0 * width, y: $0.1 * height) }
    }

    /// The slide's outline as eight points: its corners and the middles of its sides.
    var outline: [CGPoint] {
        points([(0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)])
    }

    /// The middles of cells that tile the slide: hexagons, or diamonds.
    func cells(columns: Int, diamonds: Bool) -> (radius: CGFloat, centers: [CGPoint]) {
        var centers: [CGPoint] = []
        if diamonds {
            let radius = width / CGFloat(columns) / 2
            for row in 0...Int((height / radius).rounded(.up)) {
                for column in 0...Int((width / radius).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    centers.append(CGPoint(x: CGFloat(column) * radius, y: CGFloat(row) * radius))
                }
            }
            return (radius, centers)
        }
        let radius = width / (CGFloat(columns) * 1.5)
        let rowHeight = radius * CGFloat(3).squareRoot()
        for column in 0...Int((width / (radius * 1.5)).rounded(.up)) {
            let shift = column.isMultiple(of: 2) ? 0 : rowHeight / 2
            for row in 0...Int((height / rowHeight).rounded(.up)) {
                centers.append(CGPoint(x: CGFloat(column) * radius * 1.5, y: CGFloat(row) * rowHeight + shift))
            }
        }
        return (radius, centers)
    }

    /// A cell about `center`, `across` and `down` of its full size.
    func cell(at center: CGPoint, radius: CGFloat, diamonds: Bool, across: CGFloat, down: CGFloat) -> [CGPoint] {
        let half = radius * CGFloat(3).squareRoot() / 2
        let offsets: [(CGFloat, CGFloat)] = diamonds
            ? [(0, -radius), (radius, 0), (0, radius), (-radius, 0)]
            : [(-radius, 0), (-radius / 2, -half), (radius / 2, -half), (radius, 0), (radius / 2, half), (-radius / 2, half)]
        return offsets.map { CGPoint(x: center.x + $0.0 * across, y: center.y + $0.1 * down) }
    }

    /// The ring between two circles about `center`.
    func ring(about center: CGPoint, from inner: CGFloat, to outer: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard outer > 0 else { return path }
        path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        if inner > 0 {
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        }
        return path
    }

    /// How far along the way `direction` travels a point is: 0 where the
    /// travel starts, 1 where it ends.
    func position(of point: CGPoint, along direction: SlideTransition.Direction) -> CGFloat {
        let (x, y) = direction.vector
        let extent = abs(CGFloat(x)) * width + abs(CGFloat(y)) * height
        return clamp(((point.x - center.x) * CGFloat(x) + (point.y - center.y) * CGFloat(y)) / extent + 0.5)
    }

    // MARK: Effects

    func layers(of preset: SlideTransition.Preset, at t: CGFloat) -> [Layer] {
        let eased = smooth(t)
        /// 1 travelling left, -1 travelling right.
        let side: CGFloat = preset.direction == .right ? -1 : 1
        switch preset.kind {
        case .doors, .window: return doors(eased, t, towards: preset.kind == .window, sideways: preset.direction != .up && preset.direction != .down)
        case .flip:
            // Turns about its middle, the new slide on its back.
            let angle = CGFloat.pi * eased
            let depth = 1 - 0.2 * sin(angle)
            let tilt = side * 0.22 * sin(angle)
            return [
                whole(.black),
                whole(.outgoing, about(center, turned(width: max(cos(angle), 0) * depth, height: depth, tilt: tilt)), opacity: eased < 0.5 ? 1 : 0),
                whole(.incoming, about(center, turned(width: max(-cos(angle), 0) * depth, height: depth, tilt: -tilt)), opacity: eased < 0.5 ? 0 : 1),
            ]
        case .switch:
            // The two change places, one passing in front of the other.
            let swing = side * 0.32 * width * sin(.pi * eased)
            let leaving = about(center, scale(1 - 0.35 * eased)).concatenating(move(-swing, 0))
            let arriving = about(center, scale(0.65 + 0.35 * eased)).concatenating(move(swing, 0))
            return [
                whole(.black),
                whole(.outgoing, leaving, opacity: eased < 0.5 ? 0 : 1),
                whole(.incoming, arriving),
                whole(.outgoing, leaving, opacity: eased < 0.5 ? 1 : 0),
            ]
        case .gallery:
            // Pictures on a wall, passed by: a little further off, and at an angle, on the way.
            let passing = sin(.pi * t)
            let shape = about(center, turned(width: 1 - 0.18 * passing, height: 1 - 0.18 * passing, tilt: side * 0.1 * passing))
            let travel = side * width * 1.12
            return [
                whole(.black),
                whole(.outgoing, shape.concatenating(move(-travel * eased, 0))),
                whole(.incoming, shape.concatenating(move(travel * (1 - eased), 0))),
            ]
        case .conveyor:
            // Steps back, is carried along a belt, and steps forward.
            let back = smooth(ramp(t, 0, 0.3)) - smooth(ramp(t, 0.7, 1))
            let carried = smooth(ramp(t, 0.15, 0.85))
            let shape = about(center, scale(1 - 0.3 * back))
            return [
                whole(.black),
                whole(.outgoing, shape.concatenating(move(-side * width * carried, 0))),
                whole(.incoming, shape.concatenating(move(side * width * (1 - carried), 0))),
            ]
        case .ferris:
            // Both ride a wheel whose hub is below the slide.
            let hub = CGPoint(x: width / 2, y: height / 2 + width * 1.1)
            let sweep: CGFloat = 1.15
            return [
                whole(.black),
                whole(.outgoing, about(hub, turn(-side * sweep * eased))),
                whole(.incoming, about(hub, turn(side * sweep * (1 - eased)))),
            ]
        case .vortex: return vortex(t, towards: preset.direction ?? .left)
        case .glitter: return glitter(t, towards: preset.direction ?? .left, diamonds: preset.isAlternatePattern)
        case .honeycomb: return honeycomb(t)
        case .shred: return shred(t, particles: preset.isAlternatePattern, apart: preset.isReversed)
        case .ripple: return ripple(t, towards: preset.direction)
        case .fallOver:
            // Topples about its bottom corner, and settles.
            let fallen = t < 0.8 ? (t / 0.8) * (t / 0.8) : 1 - 0.05 * sin((t - 0.8) / 0.2 * .pi)
            return [
                whole(.incoming),
                whole(.black, opacity: 0.35 * (1 - clamp(fallen))),
                whole(.outgoing, about(CGPoint(x: 0, y: height), turn(-.pi / 2 * fallen))),
            ]
        case .curtains: return curtains(eased, t)
        case .drape: return drape(t)
        case .wind: return wind(t)
        case .prestige: return prestige(t)
        case .fracture: return fracture(t)
        case .crush: return crush(t)
        case .peelOff: return fold(eased, angle: 0.62)
        case .pageCurlSingle: return fold(eased, angle: 0.14)
        case .pageCurlDouble: return pageTurn(eased)
        case .airplane: return airplane(t)
        case .origami: return origami(t)
        }
    }

    /// The old slide parts down the middle, each half swinging on its outer
    /// edge: away, as doors, or `towards` the audience, as a window.
    private func doors(_ eased: CGFloat, _ t: CGFloat, towards: Bool, sideways: Bool) -> [Layer] {
        let angle = eased * .pi / 2
        let narrow = cos(angle)
        let depth = towards ? 1 + 0.3 * sin(angle) : 1 - 0.22 * sin(angle)
        let halves: [(CGRect, CGPoint)] = sideways
            ? [(CGRect(x: 0, y: 0, width: width / 2, height: height), CGPoint(x: 0, y: height / 2)),
               (CGRect(x: width / 2, y: 0, width: width / 2, height: height), CGPoint(x: width, y: height / 2))]
            : [(CGRect(x: 0, y: 0, width: width, height: height / 2), CGPoint(x: width / 2, y: 0)),
               (CGRect(x: 0, y: height / 2, width: width, height: height / 2), CGPoint(x: width / 2, y: height))]
        var layers = [
            whole(.black),
            whole(.incoming, about(center, scale(towards ? 1.12 - 0.12 * eased : 0.86 + 0.14 * eased)), opacity: smooth(ramp(t, 0, 0.5))),
        ]
        for (rect, hinge) in halves {
            let swing = about(hinge, sideways ? scale(narrow, depth) : scale(depth, narrow))
            layers.append(piece(.outgoing, corners(rect), swing))
            layers.append(piece(.black, corners(rect), swing, opacity: 0.5 * sin(angle)))
        }
        return layers
    }

    /// The old slide breaks into tiles that spin away the way it travels.
    private func vortex(_ t: CGFloat, towards direction: SlideTransition.Direction) -> [Layer] {
        let columns = 6, rows = 4
        let (dx, dy) = direction.vector
        var layers = [whole(.black), whole(.incoming, about(center, scale(0.9 + 0.1 * smooth(t))), opacity: smooth(ramp(t, 0.15, 0.85)))]
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let rect = CGRect(x: width * CGFloat(column) / CGFloat(columns), y: height * CGFloat(row) / CGFloat(rows),
                                  width: width / CGFloat(columns), height: height / CGFloat(rows))
                let middle = CGPoint(x: rect.midX, y: rect.midY)
                // The tiles nearest where it is going leave first.
                let delay = (1 - position(of: middle, along: direction)) * 0.4 + noise(index) * 0.12
                let p = smooth(ramp(t, delay, delay + 0.48))
                let swirl = sin(p * .pi) * 0.3 * (noise(index + 100) - 0.5) * 2
                let spin = about(middle, turned(width: cos(3 * .pi * p) * (1 - 0.6 * p), height: 1 - 0.6 * p)
                    .concatenating(turn((noise(index + 200) - 0.5) * 3 * p)))
                let travel = move(CGFloat(dx) * width * 1.1 * p - CGFloat(dy) * swirl * width,
                                  CGFloat(dy) * height * 1.1 * p + CGFloat(dx) * swirl * height)
                layers.append(piece(.outgoing, corners(rect), spin.concatenating(travel), opacity: 1 - ramp(p, 0.75, 1)))
            }
        }
        return layers
    }

    /// Small tiles turn over one after another across the slide, catching the light as they go.
    private func glitter(_ t: CGFloat, towards direction: SlideTransition.Direction, diamonds: Bool) -> [Layer] {
        let (radius, centers) = cells(columns: diamonds ? 16 : 14, diamonds: diamonds)
        let upright = direction == .up || direction == .down
        let turnedOver = CGMutablePath(), glint = CGMutablePath()
        for (index, middle) in centers.enumerated() {
            let delay = position(of: middle, along: direction) * 0.6 + noise(index) * 0.15
            let p = ramp(t, delay, delay + 0.25)
            let shown = smooth(ramp(p, 0.5, 1)), lit = sin(.pi * p) * 0.9
            if shown > 0.01 {
                add(cell(at: middle, radius: radius, diamonds: diamonds, across: upright ? 1 : shown, down: upright ? shown : 1), to: turnedOver)
            }
            if lit > 0.01 {
                add(cell(at: middle, radius: radius, diamonds: diamonds, across: upright ? 1 : lit, down: upright ? lit : 1), to: glint)
            }
        }
        return [
            whole(.outgoing),
            Layer(content: .incoming, clip: t >= 1 ? nil : turnedOver),
            Layer(content: .white, opacity: 0.75, clip: glint),
        ]
    }

    /// The new slide opens through the cells of a honeycomb, here and there, until they meet.
    private func honeycomb(_ t: CGFloat) -> [Layer] {
        let (radius, centers) = cells(columns: 8, diamonds: false)
        let opening = CGMutablePath(), open = CGMutablePath()
        for (index, middle) in centers.enumerated() {
            let delay = noise(index) * 0.55
            let hollow = smooth(ramp(t, delay, delay + 0.3)), filled = smooth(ramp(t, delay + 0.08, delay + 0.42))
            if hollow > 0.01 { add(cell(at: middle, radius: radius, diamonds: false, across: hollow, down: hollow), to: opening) }
            if filled > 0.01 { add(cell(at: middle, radius: radius, diamonds: false, across: filled, down: filled), to: open) }
        }
        return [
            whole(.outgoing, about(center, scale(1 + 0.1 * smooth(t)))),
            Layer(content: .black, opacity: 0.7, clip: t >= 1 ? nil : opening),
            Layer(content: .incoming, transform: about(center, scale(1.1 - 0.1 * smooth(t))), clip: t >= 1 ? nil : open),
        ]
    }

    /// The new slide flies together from strips or particles, or the old one flies `apart` into them.
    private func shred(_ t: CGFloat, particles: Bool, apart: Bool) -> [Layer] {
        let together = apart ? 1 - t : t
        let content: Content = apart ? .outgoing : .incoming
        var layers = [whole(apart ? .incoming : .outgoing)]
        let columns = particles ? 7 : 14, rows = particles ? 4 : 1
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let rect = CGRect(x: width * CGFloat(column) / CGFloat(columns), y: height * CGFloat(row) / CGFloat(rows),
                                  width: width / CGFloat(columns), height: height / CGFloat(rows))
                let middle = CGPoint(x: rect.midX, y: rect.midY)
                let delay = noise(index) * 0.4
                let away = 1 - smooth(ramp(together, delay, delay + 0.6))
                let scattered: CGAffineTransform
                if particles {
                    // Particles come from all round, the way they lie from the middle.
                    let lean = CGPoint(x: middle.x - center.x + (noise(index + 50) - 0.5) * width * 0.2,
                                       y: middle.y - center.y + (noise(index + 90) - 0.5) * height * 0.2)
                    let far = width * 0.95 / max(hypot(lean.x, lean.y), 1)
                    scattered = about(middle, scale(1 - 0.6 * away).concatenating(turn((noise(index + 30) - 0.5) * 4 * away)))
                        .concatenating(move(lean.x * far * away, lean.y * far * away))
                } else {
                    // Strips come from above and below by turns.
                    let from: CGFloat = column.isMultiple(of: 2) ? -1 : 1
                    scattered = about(middle, turn((noise(index + 30) - 0.5) * 0.7 * away))
                        .concatenating(move((noise(index + 50) - 0.5) * width * 0.3 * away, from * height * 1.25 * away))
                }
                layers.append(piece(content, corners(rect), scattered, opacity: particles ? ramp(1 - away, 0, 0.3) : 1))
            }
        }
        return layers
    }

    /// A wave spreads from the middle, or from the corner opposite the one it
    /// travels `towards`, bending both slides where it passes.
    private func ripple(_ t: CGFloat, towards direction: SlideTransition.Direction?) -> [Layer] {
        var origin = center
        if let direction, direction.isDiagonal {
            origin = CGPoint(x: direction.vector.x < 0 ? width : 0, y: direction.vector.y < 0 ? height : 0)
        }
        let reach = corners(bounds).map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? width
        let band = reach * 0.07
        let front = (reach + band * 2.2) * (0.3 * t + 0.7 * smooth(t))
        func bent(_ by: CGFloat) -> CGAffineTransform { about(origin, scale(by)) }
        return [
            whole(.outgoing),
            Layer(content: .incoming, clip: t >= 1 ? nil : ring(about: origin, from: 0, to: front)),
            Layer(content: .outgoing, transform: bent(1.06), clip: ring(about: origin, from: front, to: front + band)),
            Layer(content: .incoming, transform: bent(0.95), clip: ring(about: origin, from: front - band, to: front)),
            Layer(content: .incoming, transform: bent(1.04), clip: ring(about: origin, from: front - band * 2, to: front - band)),
            Layer(content: .white, opacity: Double(0.2 * ramp(t, 0, 0.1)), clip: ring(about: origin, from: front - band * 0.15, to: front + band * 0.15)),
        ]
    }

    /// The old slide parts like stage curtains, gathering in folds at each side.
    private func curtains(_ eased: CGFloat, _ t: CGFloat) -> [Layer] {
        let gathered = max(1 - 1.02 * eased, 0)
        let left = about(.zero, scale(gathered, 1)), right = about(CGPoint(x: width, y: 0), scale(gathered, 1))
        let folds = CGMutablePath()
        let count = 8
        for index in stride(from: 0, to: count, by: 2) {
            let fold = CGRect(x: width / 2 * CGFloat(index) / CGFloat(count), y: 0, width: width / 2 / CGFloat(count), height: height)
            add(corners(fold).map { $0.applying(left) }, to: folds)
            add(corners(fold.offsetBy(dx: width / 2 + fold.width, dy: 0)).map { $0.applying(right) }, to: folds)
        }
        return [
            whole(.black),
            whole(.incoming, about(center, scale(0.92 + 0.08 * eased)), opacity: smooth(ramp(t, 0, 0.4))),
            piece(.outgoing, corners(CGRect(x: 0, y: 0, width: width / 2, height: height)), left),
            piece(.outgoing, corners(CGRect(x: width / 2, y: 0, width: width / 2, height: height)), right),
            Layer(content: .black, opacity: Double(0.32 * smooth(ramp(t, 0, 0.3))), clip: folds),
        ]
    }

    /// The old slide is drawn off to the left like a cloth, the near side
    /// first and the rest following in folds.
    private func drape(_ t: CGFloat) -> [Layer] {
        let count = 10
        var cloth: [Layer] = [], shade: [Layer] = []
        for index in 0..<count {
            let rect = CGRect(x: width * CGFloat(index) / CGFloat(count), y: 0, width: width / CGFloat(count), height: height)
            let p = smooth(ramp(t, CGFloat(index) * 0.045, 0.55 + CGFloat(index) * 0.045))
            let pulled = about(CGPoint(x: rect.midX, y: 0), turn(0.22 * sin(.pi * p)))
                .concatenating(move(-(rect.maxX + width * 0.08) * p, height * 0.12 * p * p))
            cloth.append(piece(.outgoing, corners(rect), pulled))
            if index.isMultiple(of: 2) { shade.append(piece(.black, corners(rect), pulled, opacity: 0.3 * sin(.pi * p))) }
        }
        return [whole(.incoming)] + cloth + shade
    }

    /// The old slide is blown away to the right in ribbons, like a flag in the wind.
    private func wind(_ t: CGFloat) -> [Layer] {
        let count = 12
        return [whole(.incoming)] + (0..<count).map { index in
            let rect = CGRect(x: 0, y: height * CGFloat(index) / CGFloat(count), width: width, height: height / CGFloat(count))
            let delay = 0.3 * (0.5 + 0.5 * sin(CGFloat(index) * 1.3)) * 0.9 + noise(index) * 0.05
            let p = ramp(t, delay, delay + 0.62)
            let blown = p * p
            let flutter = sin(p * 3 * .pi + CGFloat(index)) * height * 0.025 * p
            let lean = CGAffineTransform(a: 1, b: 0.08 * sin(p * 2 * .pi + CGFloat(index)) * p, c: 0, d: 1, tx: 0, ty: 0)
            return piece(.outgoing, corners(rect), about(CGPoint(x: 0, y: rect.midY), lean).concatenating(move(width * 1.15 * blown, flutter)))
        }
    }

    /// The old slide is whisked up and away from its middle, like a cloth off a table.
    private func prestige(_ t: CGFloat) -> [Layer] {
        let count = 9
        return [whole(.incoming)] + (0..<count).map { index in
            let rect = CGRect(x: width * CGFloat(index) / CGFloat(count), y: 0, width: width / CGFloat(count), height: height)
            let fromMiddle = abs(CGFloat(index) - CGFloat(count - 1) / 2) / (CGFloat(count - 1) / 2)
            let p = ramp(t, 0.28 * fromMiddle, 0.28 * fromMiddle + 0.68)
            let lifted = p * p
            let gather = (center.x - rect.midX) * 0.45 * smooth(p)
            let narrowed = about(CGPoint(x: rect.midX, y: 0), scale(1 - 0.4 * smooth(p), 1))
            return piece(.outgoing, corners(rect), narrowed.concatenating(move(gather, -height * 1.15 * lifted)))
        }
    }

    /// The old slide shatters from its middle, the shards flying out and falling.
    private func fracture(_ t: CGFloat) -> [Layer] {
        let columns = 4, rows = 3
        // The corners of a grid, the ones inside knocked out of line.
        func corner(_ column: Int, _ row: Int) -> CGPoint {
            let index = row * (columns + 1) + column
            let inside = column > 0 && column < columns ? (noise(index) - 0.5) * 0.55 : 0
            let insideDown = row > 0 && row < rows ? (noise(index + 40) - 0.5) * 0.55 : 0
            return CGPoint(x: width * (CGFloat(column) + inside) / CGFloat(columns),
                           y: height * (CGFloat(row) + insideDown) / CGFloat(rows))
        }
        let reach = hypot(width, height) / 2
        var layers = [whole(.incoming)]
        for row in 0..<rows {
            for column in 0..<columns {
                let a = corner(column, row), b = corner(column + 1, row), c = corner(column + 1, row + 1), d = corner(column, row + 1)
                let split = (row + column).isMultiple(of: 2) ? [[a, b, c], [a, c, d]] : [[a, b, d], [b, c, d]]
                for (half, shard) in split.enumerated() {
                    let index = (row * columns + column) * 2 + half
                    let middle = centroid(shard)
                    let delay = 0.22 * hypot(middle.x - center.x, middle.y - center.y) / reach
                    let p = ramp(t, delay, delay + 0.72)
                    let flown = about(middle, scale(1 - 0.35 * p).concatenating(turn((noise(index + 70) - 0.5) * 4 * p)))
                        .concatenating(move((middle.x - center.x) * 0.9 * p, (middle.y - center.y) * 0.9 * p + height * 1.3 * p * p))
                    layers.append(piece(.outgoing, shard, flown, opacity: 1 - ramp(p, 0.8, 1)))
                }
            }
        }
        return layers
    }

    /// The old slide is crumpled into a ball, which drops away.
    private func crush(_ t: CGFloat) -> [Layer] {
        let crumpled = smooth(ramp(t, 0, 0.6))
        let dropped = ramp(t, 0.7, 1)
        let size = 1 - 0.82 * smooth(ramp(t, 0, 0.75))
        let ball = about(center, scale(size).concatenating(turn(0.5 * crumpled + 1.5 * dropped * dropped)))
            .concatenating(move(0, height * 0.95 * dropped * dropped))
        // The outline drawn in unevenly, more as it crumples.
        let edge: [CGPoint] = (0..<16).map { index in
            let along = CGFloat(index % 4) / 4
            let point: CGPoint = switch index / 4 {
            case 0: CGPoint(x: width * along, y: 0)
            case 1: CGPoint(x: width, y: height * along)
            case 2: CGPoint(x: width * (1 - along), y: height)
            default: CGPoint(x: 0, y: height * (1 - along))
            }
            let drawnIn = crumpled * (0.12 + 0.45 * noise(index + 11))
            return CGPoint(x: point.x + (center.x - point.x) * drawnIn, y: point.y + (center.y - point.y) * drawnIn)
        }
        // Creases: the facets between the middle and the outline, shaded by turns.
        func facets(_ offset: Int) -> CGPath {
            let path = CGMutablePath()
            for index in stride(from: offset, to: edge.count, by: 4) {
                add([center, edge[index], edge[(index + 1) % edge.count]].map { $0.applying(ball) }, to: path)
            }
            return path
        }
        return [
            whole(.incoming),
            piece(.outgoing, edge, ball),
            Layer(content: .black, opacity: Double(0.3 * crumpled), clip: facets(0)),
            Layer(content: .black, opacity: Double(0.16 * crumpled), clip: facets(2)),
            Layer(content: .white, opacity: Double(0.14 * crumpled), clip: facets(1)),
        ]
    }

    /// The old slide is folded back on itself along a line that crosses it
    /// from the bottom right corner, showing its back: steeply for a sticker
    /// peeled off, nearly upright for a page turned.
    private func fold(_ eased: CGFloat, angle: CGFloat) -> [Layer] {
        let normal = CGPoint(x: cos(angle), y: sin(angle))
        let crossing = (width * normal.x + height * normal.y) * 1.02 * eased
        let on = CGPoint(x: width - normal.x * crossing, y: height - normal.y * crossing)
        let lying = cut(corners(bounds), at: on, normal: normal, beyond: false)
        let lifted = cut(corners(bounds), at: on, normal: normal, beyond: true)
        // What is lifted lies mirrored in the fold.
        let along = on.x * normal.x + on.y * normal.y
        let mirror = CGAffineTransform(
            a: 1 - 2 * normal.x * normal.x, b: -2 * normal.x * normal.y, c: -2 * normal.x * normal.y, d: 1 - 2 * normal.y * normal.y,
            tx: 2 * along * normal.x, ty: 2 * along * normal.y
        )
        let shadow = lifted.isEmpty ? [] : cut(corners(bounds), at: CGPoint(x: on.x + normal.x * width * 0.03, y: on.y + normal.y * width * 0.03),
                                                normal: normal, beyond: false)
        return [
            whole(.incoming),
            Layer(content: .black, opacity: 0.25, clip: polygon(cut(shadow, at: on, normal: normal, beyond: true))),
            Layer(content: .outgoing, clip: polygon(lying)),
            piece(.white, lifted, mirror),
            piece(.outgoing, lifted, mirror, opacity: 0.22),
        ]
    }

    /// The slides as the two pages of an open book: the right-hand page is
    /// turned over onto the left, the new slide on its back and beneath it.
    private func pageTurn(_ eased: CGFloat) -> [Layer] {
        let angle = CGFloat.pi * eased
        let spine = CGPoint(x: width / 2, y: height / 2)
        let right = corners(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let left = corners(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let lift = 0.16 * sin(angle)
        let rising = about(spine, turned(width: max(cos(angle), 0), tilt: -lift))
        let falling = about(spine, turned(width: max(-cos(angle), 0), tilt: lift))
        let firstHalf = eased < 0.5
        return [
            whole(.outgoing),
            Layer(content: .incoming, clip: polygon(right)),
            piece(.outgoing, right, rising, opacity: firstHalf ? 1 : 0),
            piece(.incoming, left, falling, opacity: firstHalf ? 0 : 1),
            piece(.black, firstHalf ? right : left, firstHalf ? rising : falling, opacity: 0.3 * sin(angle)),
        ]
    }

    /// The old slide is folded into a paper dart, and flies off to the right.
    private func airplane(_ t: CGFloat) -> [Layer] {
        let folded = smooth(ramp(t, 0, 0.42))
        let flown = ramp(t, 0.38, 1)
        let dart = points([(0, 0.12), (0.5, 0.3), (1, 0.5), (1, 0.5), (1, 0.5), (0.5, 0.7), (0, 0.88), (0.16, 0.5)])
        let shape = blend(outline, dart, folded)
        let flight = about(center, scale(1 - 0.5 * folded - 0.25 * flown).concatenating(turn(-0.28 * flown)))
            .concatenating(move(width * 1.35 * flown * flown, -height * 0.45 * flown * flown + height * 0.06 * sin(flown * .pi)))
        // Its upper wing, a lighter fold than the lower.
        let wing = blend(points([(0, 0), (0.5, 0), (1, 0), (1, 0.5), (0, 0.5)]), points([(0, 0.12), (0.5, 0.3), (1, 0.5), (1, 0.5), (0.16, 0.5)]), folded)
        return [
            whole(.incoming),
            piece(.outgoing, shape, flight),
            piece(.white, shape, flight, opacity: 0.3 * folded),
            piece(.white, wing, flight, opacity: 0.3 * folded),
        ]
    }

    /// The old slide is folded up, corners in, into a paper bird, which flies off to the left.
    private func origami(_ t: CGFloat) -> [Layer] {
        let cornersIn = smooth(ramp(t, 0, 0.3))
        let shaped = smooth(ramp(t, 0.25, 0.55))
        let flown = ramp(t, 0.5, 1)
        let diamond = points([(0.25, 0.25), (0.5, 0), (0.75, 0.25), (1, 0.5), (0.75, 0.75), (0.5, 1), (0.25, 0.75), (0, 0.5)])
        // Beak, wing tip, back, tail, and round under the belly to the throat.
        let bird = points([(0.2, 0.38), (0.46, 0.02), (0.6, 0.4), (1, 0.3), (0.72, 0.6), (0.48, 0.72), (0.3, 0.62), (0, 0.3)])
        let shape = blend(blend(outline, diamond, cornersIn), bird, shaped)
        let beat = 1 - 0.45 * abs(sin(flown * 5 * .pi))
        let flight = about(center, scale(1 - 0.45 * cornersIn - 0.25 * flown, (1 - 0.45 * cornersIn - 0.25 * flown) * beat)
            .concatenating(turn(0.2 * flown)))
            .concatenating(move(-width * 1.3 * flown * flown, -height * 0.5 * flown))
        // The wing, lighter than the body.
        let wing = blend(blend(Array(outline[0...2]), Array(diamond[0...2]), cornersIn), Array(bird[0...2]), shaped)
        return [
            whole(.incoming),
            piece(.outgoing, shape, flight),
            piece(.white, shape, flight, opacity: 0.45 * cornersIn),
            piece(.white, wing, flight, opacity: 0.3 * shaped),
        ]
    }
}
