#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// PowerPoint's Morph between two slides: the shapes they share, and where
/// each is at every moment on its way from one slide to the other.
///
/// Shapes are shared when they have the same name, as a duplicated slide's
/// do. A name beginning `!!` pairs any two shapes; otherwise they must also
/// be the same kind of thing. Each pair is drawn as both of its shapes,
/// placed in the same spot and dissolving from one to the other, so it
/// moves, resizes, turns and changes colour, text or picture together.
/// Everything else cross-fades (`SlideTransition.frame` for `.morph`).
public struct SlideMorph: Sendable {
    /// A shape of the slide being left, and the shape it becomes.
    public struct Pair: Sendable {
        public var outgoing: SlideShape
        public var incoming: SlideShape
    }

    /// A pair at one moment: where each of its shapes is drawn, as a
    /// transform of the slide it is on, in slide points, and how far the
    /// first has dissolved into the second.
    public struct Placement {
        public var outgoing: CGAffineTransform
        public var incoming: CGAffineTransform
        public var mix: Double
    }

    public let outgoing: Slide
    public let incoming: Slide
    /// How the slides' animations have left their shapes: where the first
    /// was left, and how the second first appears.
    public let outgoingFrame: AnimationFrame?
    public let incomingFrame: AnimationFrame?
    /// Back to front, as the arriving slide stacks them.
    public let pairs: [Pair]

    /// The prefix that pairs two shapes whatever they are.
    public static let forcedPrefix = "!!"

    public init(from outgoing: Slide, to incoming: Slide, outgoingFrame: AnimationFrame? = nil, incomingFrame: AnimationFrame? = nil) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.outgoingFrame = outgoingFrame
        self.incomingFrame = incomingFrame
        // Only what is on show: not shapes an animation has yet to bring in, or has taken away.
        func showing(_ slide: Slide, _ frame: AnimationFrame?) -> [SlideShape] {
            slide.shapes.filter { !$0.isHidden && !$0.name.isEmpty && (frame?.shapes[$0.shapeID]?.opacity ?? 1) > 0.001 }
        }
        var free = showing(outgoing, outgoingFrame)
        var pairs: [Pair] = []
        for shape in showing(incoming, incomingFrame) {
            let isForced = shape.name.hasPrefix(Self.forcedPrefix)
            guard let index = free.firstIndex(where: { $0.name == shape.name && (isForced || Self.isSameKind($0, shape)) }) else { continue }
            pairs.append(Pair(outgoing: free.remove(at: index), incoming: shape))
        }
        self.pairs = pairs
    }

    private static func isSameKind(_ first: SlideShape, _ second: SlideShape) -> Bool {
        switch (first.kind, second.kind) {
        case (.shape, .shape), (.connector, .connector), (.picture, .picture), (.group, .group), (.table, .table),
             (.chart, .chart), (.diagram, .diagram), (.unsupported, .unsupported): true
        default: false
        }
    }

    /// One of the slides without its shapes that morph, for the cross-fade
    /// under them.
    public func rest(of content: TransitionFrame.Content) -> AnimationFrame? {
        var frame = (content == .outgoing ? outgoingFrame : incomingFrame) ?? AnimationFrame()
        for pair in pairs { frame.shapes[(content == .outgoing ? pair.outgoing : pair.incoming).shapeID] = .hidden }
        return frame.shapes.isEmpty && frame.paragraphs.isEmpty ? nil : frame
    }

    /// One of the slides with only `shape` showing, as its animations left it.
    public func alone(_ shape: SlideShape, of content: TransitionFrame.Content) -> AnimationFrame {
        var frame = (content == .outgoing ? outgoingFrame : incomingFrame) ?? AnimationFrame()
        for other in (content == .outgoing ? outgoing : incoming).shapes where other.shapeID != shape.shapeID {
            frame.shapes[other.shapeID] = .hidden
        }
        return frame
    }

    /// Where `pair` is `progress` of the way through (0 to 1): between its
    /// two frames and angles, turning the shorter way, easing in and out.
    public func placement(of pair: Pair, progress: Double) -> Placement {
        let t = min(max(progress, 0), 1)
        let eased = CGFloat(t * t * (3 - 2 * t))
        let from = pair.outgoing.frame.points, to = pair.incoming.frame.points
        func between(_ first: CGFloat, _ second: CGFloat) -> CGFloat { first + (second - first) * eased }
        let centre = CGPoint(x: between(from.midX, to.midX), y: between(from.midY, to.midY))
        let size = CGSize(width: between(from.width, to.width), height: between(from.height, to.height))
        let turn = (pair.incoming.rotation - pair.outgoing.rotation + 540).truncatingRemainder(dividingBy: 360) - 180
        let rotation = pair.outgoing.rotation + turn * Double(eased)
        /// Takes a shape from where its slide draws it to where the pair is now.
        func transform(from frame: CGRect, rotation own: Double) -> CGAffineTransform {
            // A line has no height to stretch.
            let scaleX = frame.width > 0.01 ? size.width / frame.width : 1
            let scaleY = frame.height > 0.01 ? size.height / frame.height : 1
            return CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(-own * .pi / 180)))
                .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(rotation * .pi / 180)))
                .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
        }
        return Placement(
            outgoing: transform(from: from, rotation: pair.outgoing.rotation),
            incoming: transform(from: to, rotation: pair.incoming.rotation), mix: Double(eased)
        )
    }
}

#if canImport(CoreGraphics)
extension SlideMorph {
    /// Draws the shapes that morph as they are `progress` of the way
    /// through, over the cross-fade of the rest, into a context whose space
    /// is the slide's points, `size` of them, y downwards.
    public func draw(progress: Double, in context: CGContext, size: CGSize, presentation: Presentation) {
        guard !pairs.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        for pair in pairs {
            let placement = placement(of: pair, progress: progress)
            // The two are added together, so a pair that looks the same in
            // both slides stays solid all the way.
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            draw(pair.outgoing, of: .outgoing, placed: placement.outgoing, opacity: 1 - placement.mix,
                 in: context, size: size, presentation: presentation)
            context.setBlendMode(.plusLighter)
            draw(pair.incoming, of: .incoming, placed: placement.incoming, opacity: placement.mix,
                 in: context, size: size, presentation: presentation)
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func draw(
        _ shape: SlideShape, of content: TransitionFrame.Content, placed transform: CGAffineTransform, opacity: Double,
        in context: CGContext, size: CGSize, presentation: Presentation
    ) {
        guard opacity > 0.001 else { return }
        var options = SlideRenderer.Options.presentation
        options.drawsBackground = false
        options.animation = alone(shape, of: content)
        context.saveGState()
        context.setAlpha(CGFloat(opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.concatenate(transform)
        SlideRenderer(presentation: presentation, slide: content == .outgoing ? outgoing : incoming, options: options)
            .draw(in: context, size: size)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
#endif
