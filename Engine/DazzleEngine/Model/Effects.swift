import Foundation

/// The effects in an `a:effectLst` that Dazzle draws but does not edit: a
/// glow, soft edges, an inner shadow, a preset shadow and a blur. Saving
/// leaves them as the file had them.
public struct ShapeEffects: Equatable, Hashable, Sendable {
    public var glow: Glow?
    /// `a:softEdge`: EMU the shape fades out over, inward from its edge.
    public var softEdge: Int?
    public var innerShadow: InnerShadow?
    public var presetShadow: PresetShadow?
    public var blur: Blur?

    public init(
        glow: Glow? = nil, softEdge: Int? = nil, innerShadow: InnerShadow? = nil, presetShadow: PresetShadow? = nil,
        blur: Blur? = nil
    ) {
        self.glow = glow
        self.softEdge = softEdge
        self.innerShadow = innerShadow
        self.presetShadow = presetShadow
        self.blur = blur
    }

    /// Reads them from an `a:effectLst`, leaving out any that would show nothing.
    public init(element: XMLElement?) {
        glow = Glow(element: element?.firstChild(named: "glow"))
        softEdge = element?.firstChild(named: "softEdge")?.attribute("rad").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        innerShadow = InnerShadow(element: element?.firstChild(named: "innerShdw"))
        presetShadow = PresetShadow(element: element?.firstChild(named: "prstShdw"))
        blur = Blur(element: element?.firstChild(named: "blur"))
    }

    public var isEmpty: Bool { self == ShapeEffects() }

    /// The same effects, with `phClr` standing for `color`.
    public func replacingPlaceholder(with color: DrawingColor?) -> ShapeEffects {
        guard let color else { return self }
        var copy = self
        if let glow { copy.glow?.color = glow.color.replacingPlaceholder(with: color) }
        if let innerShadow { copy.innerShadow?.color = innerShadow.color.replacingPlaceholder(with: color) }
        if let presetShadow { copy.presetShadow?.color = presetShadow.color.replacingPlaceholder(with: color) }
        return copy
    }
}

/// `a:glow`: a soft halo of colour around the shape's outline.
public struct Glow: Equatable, Hashable, Sendable {
    /// EMU the glow reaches out from the shape.
    public var radius: Int
    public var color: DrawingColor

    public init(radius: Int, color: DrawingColor) {
        self.radius = radius
        self.color = color
    }

    public init?(element: XMLElement?) {
        guard let element, let color = DrawingColor.first(in: element),
              let radius = element.attribute("rad").flatMap(Int.init), radius > 0 else { return nil }
        self.radius = radius
        self.color = color
    }
}

/// `a:innerShdw`: a shadow cast inside the shape, as if it were a hole.
public struct InnerShadow: Equatable, Hashable, Sendable {
    /// EMU.
    public var blur: Int
    /// EMU the shadow is set off from the edge that casts it.
    public var distance: Int
    /// Degrees clockwise from pointing right, the way the shadow falls.
    public var direction: Double
    public var color: DrawingColor

    public init(blur: Int, distance: Int, direction: Double, color: DrawingColor) {
        self.blur = blur
        self.distance = distance
        self.direction = direction
        self.color = color
    }

    public init?(element: XMLElement?) {
        guard let element, let color = DrawingColor.first(in: element) else { return nil }
        blur = element.attribute("blurRad").flatMap(Int.init) ?? 0
        distance = element.attribute("dist").flatMap(Int.init) ?? 0
        direction = Double(element.attribute("dir").flatMap(Int.init) ?? 0) / 60_000
        self.color = color
    }
}

/// `a:prstShdw`: one of the twenty hard-edged shadows of older Office,
/// `shdw1`…`shdw20`, set off by a distance in a direction.
public struct PresetShadow: Equatable, Hashable, Sendable {
    /// 1…20.
    public var preset: Int
    /// EMU.
    public var distance: Int
    /// Degrees clockwise from pointing right.
    public var direction: Double
    public var color: DrawingColor

    public init(preset: Int, distance: Int, direction: Double, color: DrawingColor) {
        self.preset = preset
        self.distance = distance
        self.direction = direction
        self.color = color
    }

    public init?(element: XMLElement?) {
        guard let element, let color = DrawingColor.first(in: element),
              let name = element.attribute("prst"), name.hasPrefix("shdw"),
              let preset = Int(name.dropFirst(4)), (1...20).contains(preset) else { return nil }
        self.preset = preset
        distance = element.attribute("dist").flatMap(Int.init) ?? 0
        direction = Double(element.attribute("dir").flatMap(Int.init) ?? 0) / 60_000
        self.color = color
    }

    /// How a preset casts its silhouette, besides the distance and direction
    /// the file gives: scaled and skewed about a point on the shape's bounds,
    /// as fractions of its size, for the perspective shadows.
    public struct Cast: Equatable, Sendable {
        /// Where the silhouette is scaled and skewed about: 0…1 across and down the bounds.
        public var anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
        public var scale: CGSize = CGSize(width: 1, height: 1)
        /// Horizontal shear, `x += skew × y` from the anchor, y pointing down: a positive skew leans what
        /// stands above the anchor to the left, and what lies below it to the right.
        public var skew: CGFloat = 0
        /// How many times the silhouette is cast, each a further distance out.
        public var copies = 1
        /// Whether the silhouette is swept from the shape out to the offset, as a solid box's side.
        public var isExtruded = false
        /// Whether the shadow falls inside the shape rather than behind it.
        public var isInner = false
    }

    /// `shdw1`…`shdw20`, as the specification names them.
    public var cast: Cast {
        let bottom = CGPoint(x: 0.5, y: 1)
        switch preset {
        // Back perspective: the shadow stands up behind the shape, leaning off to one side.
        case 3: return Cast(anchor: bottom, scale: CGSize(width: 1, height: 0.5), skew: 1)
        case 4: return Cast(anchor: bottom, scale: CGSize(width: 1, height: 0.5), skew: -1)
        case 11: return Cast(anchor: bottom, scale: CGSize(width: 1, height: 0.8), skew: 1)
        case 12: return Cast(anchor: bottom, scale: CGSize(width: 1, height: 0.8), skew: -1)
        case 19: return Cast(anchor: bottom, scale: CGSize(width: 1, height: 0.5))
        // Front perspective: the shadow lies on the floor in front, folded down from the bottom edge.
        case 7: return Cast(anchor: bottom, scale: CGSize(width: 1, height: -0.5), skew: -1)
        case 8: return Cast(anchor: bottom, scale: CGSize(width: 1, height: -0.5), skew: 1)
        case 15: return Cast(anchor: bottom, scale: CGSize(width: 1, height: -0.8), skew: -1)
        case 16: return Cast(anchor: bottom, scale: CGSize(width: 1, height: -0.8), skew: 1)
        case 20: return Cast(anchor: bottom, scale: CGSize(width: 1, height: -0.3))
        // Small and large drop shadows.
        case 9, 14: return Cast(scale: CGSize(width: 0.9, height: 0.9))
        case 10: return Cast(scale: CGSize(width: 1.1, height: 1.1))
        case 13: return Cast(copies: 2)
        case 17: return Cast(isExtruded: true)
        case 18: return Cast(isInner: true)
        // 1, 2, 5, 6: plain drop shadows, which way set by the direction.
        default: return Cast()
        }
    }

    /// Points the shadow is set off by, in the shape's own space.
    public var offset: CGSize {
        let radians = direction * .pi / 180
        return CGSize(width: cos(radians) * EMU.points(distance), height: sin(radians) * EMU.points(distance))
    }

    /// Where each copy of the silhouette of a shape filling `bounds` goes,
    /// farthest first: one for most presets, two for the double shadow, and
    /// for the extruded box, one every `1 / stepsPerPoint` points out to the offset.
    public func transforms(in bounds: CGRect, stepsPerPoint: CGFloat = 1) -> [CGAffineTransform] {
        let cast = cast
        guard !cast.isInner else { return [] }
        let offset = offset
        let steps = cast.isExtruded
            ? max(1, min(64, Int((hypot(offset.width, offset.height) * stepsPerPoint).rounded(.up))))
            : max(cast.copies, 1)
        let reach = cast.isExtruded ? 1 : CGFloat(steps)
        return (1...steps).reversed().map { step in
            let fraction = CGFloat(step) / CGFloat(steps) * reach
            return transform(in: bounds, offset: CGSize(width: offset.width * fraction, height: offset.height * fraction))
        }
    }

    /// Where the silhouette of a shape filling `bounds` goes, set off by
    /// `offset` (by default the preset's own).
    public func transform(in bounds: CGRect, offset: CGSize? = nil) -> CGAffineTransform {
        let cast = cast
        let offset = offset ?? self.offset
        let anchor = CGPoint(x: bounds.minX + bounds.width * cast.anchor.x, y: bounds.minY + bounds.height * cast.anchor.y)
        // Scaled and sheared about the anchor, `x += skew × y`, then set off.
        return CGAffineTransform(translationX: anchor.x + offset.width, y: anchor.y + offset.height)
            .shearedBy(cast.skew)
            .scaledBy(x: cast.scale.width, y: cast.scale.height)
            .translatedBy(x: -anchor.x, y: -anchor.y)
    }
}

extension CGAffineTransform {
    /// A horizontal shear, `x += shear × y`, then this transform.
    fileprivate func shearedBy(_ shear: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: 0, ty: 0).concatenating(self)
    }
}

/// `a:blur`: the whole shape blurred.
public struct Blur: Equatable, Hashable, Sendable {
    /// EMU.
    public var radius: Int
    /// Whether the blur spreads past the shape's bounds, or is cut off at them.
    public var grows: Bool

    public init(radius: Int, grows: Bool = true) {
        self.radius = radius
        self.grows = grows
    }

    public init?(element: XMLElement?) {
        guard let element, let radius = element.attribute("rad").flatMap(Int.init), radius > 0 else { return nil }
        self.radius = radius
        grows = element.attribute("grow").map { $0 == "1" || $0 == "true" } ?? true
    }
}

/// One of a theme's `a:effectStyle`s, for shapes whose `p:style` names it.
public struct EffectStyle: Equatable, Hashable, Sendable {
    public var shadow: Shadow?
    public var reflection: Reflection?
    public var effects: ShapeEffects

    public init(shadow: Shadow? = nil, reflection: Reflection? = nil, effects: ShapeEffects = ShapeEffects()) {
        self.shadow = shadow
        self.reflection = reflection
        self.effects = effects
    }

    /// Reads an `a:effectStyle`, or a shape's `a:effectLst`.
    public init(element: XMLElement?) {
        let list = element?.name == "effectLst" ? element : element?.firstChild(named: "effectLst")
        shadow = Shadow(element: list?.firstChild(named: "outerShdw"))
        reflection = Reflection(element: list?.firstChild(named: "reflection"))
        effects = ShapeEffects(element: list)
    }
}

extension DrawingColor {
    /// The colour with `phClr` standing for `color`: its base, then its
    /// own transforms before this one's.
    public func replacingPlaceholder(with color: DrawingColor) -> DrawingColor {
        guard base == .scheme("phClr") else { return self }
        return DrawingColor(base: color.base, transforms: color.transforms + transforms)
    }
}
