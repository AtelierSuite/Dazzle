#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// How the slideshow moves onto a slide: PowerPoint's `p:transition`, and
/// the newer effects PowerPoint 2010 and later write beside it for readers
/// that know them (`p14`, `p15`, `p159`).
///
/// The few effects Dazzle has no drawing of its own for are played as the
/// nearest it has, and the ones with no near match at all as a fade.
public struct SlideTransition: Equatable, Hashable, Sendable {
    /// Which way something moves: the direction of travel, as PowerPoint
    /// spells it (`l` moves leftwards, coming in from the right).
    public enum Direction: String, CaseIterable, Sendable {
        case left = "l", right = "r", up = "u", down = "d"
        case leftUp = "lu", rightUp = "ru", leftDown = "ld", rightDown = "rd"

        /// The unit vector of travel, y downwards.
        public var vector: (x: Double, y: Double) {
            switch self {
            case .left: (-1, 0)
            case .right: (1, 0)
            case .up: (0, -1)
            case .down: (0, 1)
            case .leftUp: (-1, -1)
            case .rightUp: (1, -1)
            case .leftDown: (-1, 1)
            case .rightDown: (1, 1)
            }
        }

        public var isDiagonal: Bool { rawValue.count == 2 }
    }

    public enum Effect: Equatable, Hashable, Sendable {
        /// Straight to the slide, or by way of a moment of black.
        case cut(throughBlack: Bool)
        case fade(throughBlack: Bool)
        /// Through white, as PowerPoint's Flash.
        case flash
        /// The new slide pushes the old one off.
        case push(Direction)
        /// The new slide is uncovered by an edge travelling across.
        case wipe(Direction)
        /// The new slide slides in over the old one.
        case cover(Direction)
        /// The old slide slides off, uncovering the new one.
        case uncover(Direction)
        /// Opens from the middle (or closes in from the edges), along a
        /// vertical or horizontal line.
        case split(vertical: Bool, outward: Bool)
        /// The new slide grows in from the middle, or settles in from large.
        case zoom(outward: Bool)
        /// The new slide spins in, growing.
        case newsflash
        /// Strips of the new slide slide in from alternate sides.
        case comb(vertical: Bool)
        /// A pattern of the new slide filling in: blinds, a checkerboard,
        /// random bars, a dissolve, a circle, a wheel…
        case pattern(AnimationFilter)
        /// One of PowerPoint 2010's or 2013's own: a vortex, a page curl,
        /// curtains…
        case preset(Preset)
        /// A different effect each time, from the ones above.
        case random
        /// Flies into a zoom's picture of the new slide, which grows to fill
        /// the screen, or `returning`, shrinks the old slide back into its
        /// picture on the new one. Played by the slideshow, never saved.
        case zoomObject(ZoomFrame, returning: Bool)
    }

    /// Where a zoom's picture sits, as fractions of the slide.
    public struct ZoomFrame: Equatable, Hashable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// `rect`, in slide points, on a slide of `size`.
        public init(_ rect: CGRect, in size: CGSize) {
            let width = max(Double(size.width), 1), height = max(Double(size.height), 1)
            self.init(x: Double(rect.minX) / width, y: Double(rect.minY) / height,
                      width: Double(rect.width) / width, height: Double(rect.height) / height)
        }
    }

    public var effect: Effect
    /// Seconds the effect takes.
    public var duration: Double
    /// The effect the file asked for, when Dazzle plays something else
    /// because it cannot draw it (a morph…).
    public var approximates: String?

    public init(effect: Effect, duration: Double? = nil, approximates: String? = nil) {
        self.effect = effect
        self.duration = duration ?? Self.defaultDuration(of: effect)
        self.approximates = approximates
    }

    /// PowerPoint's speeds: `fast`, `med` and `slow`.
    public static func duration(ofSpeed speed: String?) -> Double {
        switch speed {
        case "slow": 1
        case "med": 0.75
        default: 0.5
        }
    }

    public static func defaultDuration(of effect: Effect) -> Double {
        switch effect {
        case .cut(let throughBlack): throughBlack ? 0.3 : 0
        case .fade, .flash: 0.7
        default: 1
        }
    }

    /// Whether anything is drawn between the two slides.
    public var isAnimated: Bool { duration > 0 && effect != .cut(throughBlack: false) }

    /// What to play: with Reduce Motion on, everything that moves becomes a
    /// cross-fade. `seed` picks the effect a random transition plays.
    public func played(reduceMotion: Bool, seed: Int = 0) -> SlideTransition {
        var played = self
        if case .random = effect {
            played.effect = Self.randomChoices[abs(seed) % Self.randomChoices.count]
        }
        if reduceMotion {
            switch played.effect {
            case .cut: break
            case .fade(let throughBlack): played.effect = .fade(throughBlack: throughBlack)
            default: played.effect = .fade(throughBlack: false)
            }
        }
        return played
    }

    static let randomChoices: [Effect] = [
        .fade(throughBlack: false), .push(.up), .push(.left), .wipe(.left), .wipe(.down), .cover(.left), .uncover(.left),
        .split(vertical: true, outward: true), .split(vertical: false, outward: false), .zoom(outward: false),
        .pattern(AnimationFilter("blinds(horizontal)")!), .pattern(AnimationFilter("checkerboard(across)")!),
        .pattern(AnimationFilter("dissolve")!), .pattern(AnimationFilter("randombar(vertical)")!),
        .pattern(AnimationFilter("circle(out)")!), .comb(vertical: false),
    ]
}

// MARK: - Reading

extension SlideTransition {
    /// The transition a slide's `p:transition` elements describe — the plain
    /// one and each version an `mc:AlternateContent` offers, richest first —
    /// or `nil` when none has an effect.
    ///
    /// The richest version Dazzle can draw is played; when the richest of
    /// all is one it cannot, it is recorded in `approximates`.
    public init?(versions: [XMLElement]) {
        let parsed = versions.compactMap { element in
            element.children.first.map { (element: element, effect: Self.effect(of: $0)) }
        }
        guard let richest = parsed.first else { return nil }
        let chosen = parsed.first { $0.effect.approximates == nil } ?? richest
        let milliseconds = ([chosen.element] + versions).lazy.compactMap { $0.attribute("dur").flatMap(Double.init) }.first
        let duration = milliseconds.map { $0 / 1_000 }
            ?? (chosen.element.attribute("spd") ?? versions.lazy.compactMap { $0.attribute("spd") }.first)
                .map(Self.duration(ofSpeed:))
        self.init(effect: chosen.effect.effect, duration: duration ?? Self.duration(ofSpeed: nil),
                  approximates: richest.effect.approximates)
    }

    /// One effect element: what Dazzle plays for it, and the element's name
    /// when that is only the nearest Dazzle has.
    static func effect(of element: XMLElement) -> (effect: Effect, approximates: String?) {
        let dir = element.attribute("dir")
        func direction(_ fallback: Direction) -> Direction { dir.flatMap(Direction.init(rawValue:)) ?? fallback }
        func side(_ fallback: Direction) -> Direction {
            let value = direction(fallback)
            return value.isDiagonal ? fallback : value
        }
        let vertical = (element.attribute("orient") ?? dir) == "vert"
        let throughBlack = element.attribute("thruBlk") == "1" || element.attribute("thruBlk") == "true"
        func pattern(_ name: String) -> Effect { .pattern(AnimationFilter(name)!) }
        switch element.name {
        case "cut": return (.cut(throughBlack: throughBlack), nil)
        case "fade": return (.fade(throughBlack: throughBlack), nil)
        case "push": return (.push(side(.left)), nil)
        case "wipe": return (.wipe(side(.left)), nil)
        case "cover": return (.cover(direction(.left)), nil)
        case "pull": return (.uncover(direction(.left)), nil)
        case "split":
            return (.split(vertical: element.attribute("orient") == "vert", outward: element.attribute("dir") != "in"), nil)
        case "zoom": return (.zoom(outward: dir == "out"), nil)
        case "newsflash": return (.newsflash, nil)
        case "comb": return (.comb(vertical: vertical), nil)
        case "blinds": return (pattern(vertical ? "blinds(vertical)" : "blinds(horizontal)"), nil)
        case "checker": return (pattern(vertical ? "checkerboard(down)" : "checkerboard(across)"), nil)
        case "randomBar": return (pattern(vertical ? "randombar(vertical)" : "randombar(horizontal)"), nil)
        case "dissolve": return (pattern("dissolve"), nil)
        case "circle": return (pattern("circle(out)"), nil)
        case "diamond": return (pattern("diamond(out)"), nil)
        case "plus": return (pattern("plus(out)"), nil)
        case "wedge": return (pattern("wedge"), nil)
        case "wheel", "wheelReverse":
            let spokes = Int(element.attribute("spokes") ?? "") ?? 4
            let nearest = [1, 2, 3, 4, 8].min { abs($0 - spokes) < abs($1 - spokes) } ?? 4
            return (pattern("wheel(\(nearest))"), nil)
        case "strips":
            let name = switch direction(.leftUp) {
            case .rightUp: "strips(upRight)"
            case .leftDown: "strips(downLeft)"
            case .rightDown: "strips(downRight)"
            default: "strips(upLeft)"
            }
            return (pattern(name), nil)
        case "random": return (.random, nil)
        // PowerPoint 2010's own (p14), as the nearest Dazzle draws.
        case "flash": return (.flash, nil)
        case "reveal": return (.fade(throughBlack: true), nil)
        case "warp", "flythrough": return (.zoom(outward: dir == "out"), nil)
        case "pan", "prism": return (.push(side(.up)), nil)
        default:
            // A vortex, ripple, page curl and the rest, each as itself.
            if let preset = Preset(element: element) { return (.preset(preset), nil) }
            // A morph, and anything newer still.
            let name = element.name == "prstTrans" ? element.attribute("prst") ?? element.name : element.name
            return (.fade(throughBlack: false), name)
        }
    }
}

// MARK: - Playing

/// One moment of a transition: what is drawn, back to front, over black.
public struct TransitionFrame {
    public enum Content: String, Sendable {
        /// The slide being left, and the slide arriving.
        case outgoing, incoming
        case black, white
    }

    public struct Layer {
        public var content: Content
        public var opacity: Double = 1
        /// Places the content within the slide's bounds, in slide points.
        public var transform: CGAffineTransform = .identity
        /// What of the slide's bounds shows it, in slide points, filled even-odd;
        /// `nil` for all of it.
        public var clip: CGPath?

        public init(content: Content, opacity: Double = 1, transform: CGAffineTransform = .identity, clip: CGPath? = nil) {
            self.content = content
            self.opacity = opacity
            self.transform = transform
            self.clip = clip
        }
    }

    public var layers: [Layer]
}

extension SlideTransition {
    /// The transition `progress` of the way through (0 to 1), on a slide of
    /// `size` points. Every moment of one effect has the same layers, so a
    /// browser can animate between moments.
    public func frame(progress: Double, size: CGSize) -> TransitionFrame {
        let t = min(max(progress, 0), 1)
        let eased = t * t * (3 - 2 * t)
        let width = size.width, height = size.height
        let bounds = CGRect(origin: .zero, size: size)
        typealias Layer = TransitionFrame.Layer
        func offset(_ x: Double, _ y: Double) -> CGAffineTransform {
            CGAffineTransform(translationX: CGFloat(x) * width, y: CGFloat(y) * height)
        }
        /// Scaled by `scale` and turned by `angle` about the middle.
        func scaled(_ scale: Double, angle: Double = 0) -> CGAffineTransform {
            CGAffineTransform(translationX: -width / 2, y: -height / 2)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(angle)))
                .concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                .concatenating(CGAffineTransform(translationX: width / 2, y: height / 2))
        }
        func rect(_ rect: CGRect) -> CGPath {
            let path = CGMutablePath()
            path.addRect(rect)
            return path
        }
        let layers: [Layer]
        switch effect {
        case .cut(let throughBlack):
            layers = throughBlack
                ? [Layer(content: .black), Layer(content: .incoming, opacity: t >= 0.5 ? 1 : 0)]
                : [Layer(content: .incoming)]
        case .fade(false):
            layers = [Layer(content: .outgoing), Layer(content: .incoming, opacity: t)]
        case .fade(true), .flash:
            layers = [
                Layer(content: effect == .flash ? .white : .black),
                Layer(content: .outgoing, opacity: max(1 - 2 * t, 0)),
                Layer(content: .incoming, opacity: max(2 * t - 1, 0)),
            ]
        case .push(let direction):
            let (x, y) = direction.vector
            layers = [
                Layer(content: .outgoing, transform: offset(x * eased, y * eased)),
                Layer(content: .incoming, transform: offset(-x * (1 - eased), -y * (1 - eased))),
            ]
        case .wipe(let direction):
            let (x, y) = direction.vector
            let shown = CGRect(
                x: x < 0 ? width * (1 - eased) : 0, y: y < 0 ? height * (1 - eased) : 0,
                width: x == 0 ? width : width * eased, height: y == 0 ? height : height * eased
            )
            layers = [Layer(content: .outgoing), Layer(content: .incoming, clip: rect(shown))]
        case .cover(let direction):
            let (x, y) = direction.vector
            layers = [
                Layer(content: .outgoing),
                Layer(content: .incoming, transform: offset(-x * (1 - eased), -y * (1 - eased))),
            ]
        case .uncover(let direction):
            let (x, y) = direction.vector
            layers = [Layer(content: .incoming), Layer(content: .outgoing, transform: offset(x * eased, y * eased))]
        case .split(let vertical, let outward):
            let name = "barn(\(outward ? "out" : "in")\(vertical ? "Vertical" : "Horizontal"))"
            layers = [
                Layer(content: .outgoing),
                Layer(content: .incoming, clip: AnimationFilter(name)!.path(progress: eased, frame: bounds)),
            ]
        case .zoom(let outward):
            layers = outward
                ? [Layer(content: .outgoing), Layer(content: .incoming, opacity: t, transform: scaled(1.6 - 0.6 * eased))]
                : [Layer(content: .outgoing, opacity: 1 - t),
                   Layer(content: .incoming, opacity: min(t * 2, 1), transform: scaled(0.2 + 0.8 * eased))]
        case .newsflash:
            layers = [
                Layer(content: .outgoing),
                Layer(content: .incoming, transform: scaled(max(eased, 0.001), angle: -4 * .pi * (1 - eased))),
            ]
        case .comb(let vertical):
            let count = 8
            layers = [Layer(content: .outgoing)] + (0..<count).map { index in
                let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
                let band = vertical
                    ? CGRect(x: width * CGFloat(index) / CGFloat(count), y: 0, width: width / CGFloat(count), height: height)
                    : CGRect(x: 0, y: height * CGFloat(index) / CGFloat(count), width: width, height: height / CGFloat(count))
                let travel = sign * (1 - eased)
                return Layer(content: .incoming, transform: vertical ? offset(0, travel) : offset(travel, 0), clip: rect(band))
            }
        case .pattern(let filter):
            layers = [Layer(content: .outgoing), Layer(content: .incoming, clip: filter.path(progress: t, frame: bounds))]
        case .preset(let preset):
            layers = preset.layers(progress: t, size: size)
        case .random:
            return played(reduceMotion: false).frame(progress: progress, size: size)
        case .zoomObject(let zoom, let returning):
            // The picture's place on the parent slide, and where it has
            // reached on the way to filling the screen.
            let reach = returning ? 1 - eased : eased
            let picture = CGRect(x: zoom.x * width, y: zoom.y * height,
                                 width: max(zoom.width * width, 0.01), height: max(zoom.height * height, 0.01))
            let now = CGRect(
                x: picture.minX * (1 - reach), y: picture.minY * (1 - reach),
                width: picture.width + (width - picture.width) * reach, height: picture.height + (height - picture.height) * reach
            )
            // The zoomed slide fills `now`; the parent is scaled so its picture does too.
            let zoomed = CGAffineTransform(a: now.width / width, b: 0, c: 0, d: now.height / height, tx: now.minX, ty: now.minY)
            let scaleX = now.width / picture.width, scaleY = now.height / picture.height
            let parent = CGAffineTransform(
                a: scaleX, b: 0, c: 0, d: scaleY, tx: now.minX - picture.minX * scaleX, ty: now.minY - picture.minY * scaleY
            )
            // The zoomed slide shows over its picture straight away, and
            // fades only as it nears the picture's size.
            let shown = min(reach * 4, 1)
            layers = returning
                ? [Layer(content: .incoming, transform: parent), Layer(content: .outgoing, opacity: shown, transform: zoomed)]
                : [Layer(content: .outgoing, transform: parent), Layer(content: .incoming, opacity: shown, transform: zoomed)]
        }
        return TransitionFrame(layers: layers)
    }
}

#if canImport(CoreGraphics)
extension TransitionFrame {
    /// Draws the moment into `context`, whose space is the slide's points,
    /// `size` of them. `draw` draws a slide filling that space.
    public func draw(in context: CGContext, size: CGSize, draw: (Content, CGContext) -> Void) {
        for layer in layers where layer.opacity > 0 {
            if let clip = layer.clip, clip.isEmpty { continue }
            context.saveGState()
            context.clip(to: CGRect(origin: .zero, size: size))
            if let clip = layer.clip {
                context.addPath(clip)
                context.clip(using: .evenOdd)
            }
            context.setAlpha(CGFloat(layer.opacity))
            if layer.opacity < 1 {
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.setAlpha(1)
            }
            context.concatenate(layer.transform)
            switch layer.content {
            case .black, .white:
                context.setFillColor(layer.content == .black ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
            case .outgoing, .incoming:
                draw(layer.content, context)
            }
            if layer.opacity < 1 { context.endTransparencyLayer() }
            context.restoreGState()
        }
    }
}
#endif

#if canImport(CoreGraphics)
extension TransitionFrame {
    /// Draws the moment with pictures of the two slides, into a context
    /// that counts y downwards, as views do.
    public func draw(in context: CGContext, size: CGSize, outgoing: CGImage?, incoming: CGImage?) {
        draw(in: context, size: size) { content, context in
            guard let image = content == .outgoing ? outgoing : incoming else { return }
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            context.restoreGState()
        }
    }
}
#endif
