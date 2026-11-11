#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// How a shape's `a:scene3d` and `a:sp3d` are drawn, flat, without real 3D:
/// its depth as copies of its silhouette set off behind it and darkened,
/// when the camera looks at it from an angle; its contour as a band round
/// its edge; and its top bevel as bands of light and shade just inside its
/// edge, lit on the side facing the light and shaded on the other, shaped
/// by the bevel's profile and as strong as its slope, the lights and the
/// material make them.
///
/// Everything is in the shape's own space, before it is turned and flipped,
/// so the light and camera stay where the slide has them however it turns.
public struct Shape3DLook: Equatable, Sendable {
    /// Part of the bevel: what stays inside the shape when the shape is set
    /// off by `kept`, but not when it is set off by `cut`, washed over in
    /// white or black.
    public struct Band: Equatable, Sendable {
        public var kept: CGSize
        public var cut: CGSize
        public var isLight: Bool
        public var opacity: Double
    }

    /// The shape's sides: its silhouette at each transform, farthest first,
    /// filled in the matching colour.
    public struct Extrusion: Equatable, Sendable {
        public var transforms: [CGAffineTransform]
        public var colors: [RGBAColor]
    }

    /// A band `width` points wide round the shape's edge, half outside it.
    public struct Contour: Equatable, Sendable {
        public var width: CGFloat
        public var color: RGBAColor
    }

    public var bands: [Band] = []
    public var extrusion: Extrusion?
    public var contour: Contour?

    /// How many bands each side of a bevel is drawn in.
    public static let bandCount = 6

    /// The look of a shape filling `bounds`, turned `rotation` degrees and
    /// flipped as given, whose face is `face` (its fill's colour, or `nil`
    /// when it is not filled, which leaves out the bevel), with `color`
    /// resolving colours. `nil` when there is nothing to draw.
    public init?(
        scene: Scene3D?, shape: Shape3D?, bounds: CGRect, rotation: Double = 0, flipsHorizontally: Bool = false,
        flipsVertically: Bool = false, face: RGBAColor?, color: (DrawingColor) -> RGBAColor
    ) {
        guard let shape, bounds.width > 0, bounds.height > 0 else { return nil }
        let scene = scene ?? Scene3D()
        // Slide space to the shape's own: turned back, then flipped back.
        let radians = -rotation * .pi / 180
        func local(_ vector: CGSize) -> CGSize {
            let x = vector.width * cos(radians) - vector.height * sin(radians)
            let y = vector.width * sin(radians) + vector.height * cos(radians)
            return CGSize(width: flipsHorizontally ? -x : x, height: flipsVertically ? -y : y)
        }

        // The sides, seen when the camera looks at the shape from an angle.
        let depth = CGFloat(EMU.points(shape.extrusionHeight))
        let view = Self.depthDirection(of: scene)
        if depth > 0, hypot(view.width, view.height) > 0.001 {
            let offset = local(CGSize(width: view.width * depth, height: view.height * depth))
            let reach = hypot(offset.width, offset.height)
            // A copy every half point, and smaller farther off through a perspective camera.
            let steps = max(1, min(64, Int((reach * 2).rounded(.up))))
            let shrink = scene.camera.hasPrefix("perspective") || scene.camera.hasPrefix("legacyPerspective")
                ? min(0.2, depth / max(bounds.width, bounds.height) * 0.25) : 0
            let side = shape.extrusionColor.map(color) ?? face ?? RGBAColor(red: 0.6, green: 0.6, blue: 0.6)
            var transforms: [CGAffineTransform] = []
            var colors: [RGBAColor] = []
            for step in (1...steps).reversed() {
                let fraction = CGFloat(step) / CGFloat(steps)
                let scale = 1 - shrink * fraction
                transforms.append(
                    CGAffineTransform(translationX: bounds.midX + offset.width * fraction, y: bounds.midY + offset.height * fraction)
                        .scaledBy(x: scale, y: scale)
                        .translatedBy(x: -bounds.midX, y: -bounds.midY)
                )
                // Darker the farther back, as the sides turn from the light.
                colors.append(side.scaled(by: 0.72 - 0.22 * Double(fraction)))
            }
            extrusion = Extrusion(transforms: transforms, colors: colors)
        }

        if shape.contourWidth > 0 {
            let width = CGFloat(EMU.points(shape.contourWidth))
            contour = Contour(width: width * 2, color: shape.contourColor.map(color) ?? RGBAColor(red: 0, green: 0, blue: 0))
        }

        // The bevel: on a face that shows, sloping as steeply as its height against its width.
        if face != nil, let bevel = shape.topBevel, bevel.width > 0, bevel.height > 0 {
            let width = min(CGFloat(EMU.points(bevel.width)), min(bounds.width, bounds.height) / 2)
            let slope = min(1, sqrt(Double(bevel.height) / Double(bevel.width)))
            let material = Self.material(shape.material)
            let rig = Self.lightStrength(scene.lightRig)
            let light = min(0.9, 0.5 * slope * rig * material.light)
            let shade = min(0.9, 0.38 * slope * rig * material.shade)
            // Towards the light, scaled so a straight edge across it gets the bevel's full width.
            var toward = Self.lightDirection(of: scene)
            toward = local(CGSize(width: toward.width / max(abs(toward.width), abs(toward.height)),
                                  height: toward.height / max(abs(toward.width), abs(toward.height))))
            let profile = Self.profile(bevel.preset)
            let step = width / CGFloat(profile.count)
            if width > 0.05, light > 0 || shade > 0 {
                for (isLitSide, sign) in [(true, CGFloat(1)), (false, CGFloat(-1))] {
                    for (index, value) in profile.enumerated() where value != 0 {
                        // On the lit side, what lies within this band of the edge facing the light.
                        func setOff(_ distance: CGFloat) -> CGSize {
                            CGSize(width: -toward.width * distance * sign, height: -toward.height * distance * sign)
                        }
                        let isLight = (value > 0) == isLitSide
                        let opacity = abs(value) * (isLight ? light : shade)
                        guard opacity > 0.004 else { continue }
                        bands.append(Band(
                            kept: setOff(step * CGFloat(index)), cut: setOff(step * CGFloat(index + 1)),
                            isLight: isLight, opacity: (opacity * 1000).rounded() / 1000
                        ))
                    }
                }
            }
        }
        guard !bands.isEmpty || extrusion != nil || contour != nil else { return nil }
    }

    /// How far the shape's back shows past its face, as a fraction of its
    /// depth, which way on the slide: up and left when the camera looks
    /// from above and from the left. Nothing, face on.
    static func depthDirection(of scene: Scene3D) -> CGSize {
        var name = scene.camera
        var length: CGFloat = 0.5
        for prefix in ["legacyOblique", "legacyPerspective", "oblique", "isometric", "perspective", "orthographic"]
        where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            length = switch prefix {
            case "isometric": 0.6
            case "perspective", "legacyPerspective": 0.4
            default: 0.5
            }
            break
        }
        var x: CGFloat = 0, y: CGFloat = 0
        switch name {
        // A shape turned to face one way, seen from above or below.
        case "AboveLeftFacing": (x, y) = (0.7, -0.7)
        case "AboveRightFacing": (x, y) = (-0.7, -0.7)
        case "ContrastingLeftFacing": (x, y) = (1, -0.35)
        case "ContrastingRightFacing": (x, y) = (-1, -0.35)
        case "HeroicLeftFacing": (x, y) = (0.8, 0.6)
        case "HeroicRightFacing": (x, y) = (-0.8, 0.6)
        case "HeroicExtremeLeftFacing": (x, y) = (1, 0.8)
        case "HeroicExtremeRightFacing": (x, y) = (-1, 0.8)
        // Leaning back, seen from a little above.
        case "Relaxed": (x, y) = (0, -0.9)
        case "RelaxedModerately": (x, y) = (0, -0.6)
        case "Front": (x, y) = (0, 0)
        default:
            // Where the camera is: TopLeft, Below, LeftDown, OffAxis1Right and the like.
            if name.contains("Left") { x = -1 } else if name.contains("Right") { x = 1 }
            if name.contains("Top") || name.contains("Above") || name.contains("OffAxis1") || name.contains("OffAxis2") {
                y = -1
            } else if name.contains("Bottom") || name.contains("Below") || name.contains("OffAxis3") || name.contains("OffAxis4") {
                y = 1
            }
            if name.hasPrefix("OffAxis"), !name.hasSuffix("Top"), !name.hasSuffix("Bottom") { y *= 0.6 }
            if x != 0, y != 0, !name.hasPrefix("OffAxis") { (x, y) = (x * 0.75, y * 0.75) }
        }
        // A camera turned of its own sees the side it turns towards.
        if let turn = scene.cameraRotation {
            x -= CGFloat(sin(turn.longitude * .pi / 180))
            y += CGFloat(sin(turn.latitude * .pi / 180))
        }
        return CGSize(width: x * length, height: y * length)
    }

    /// A unit vector from the shape towards the light, y pointing down.
    static func lightDirection(of scene: Scene3D) -> CGSize {
        let (x, y): (Double, Double) = switch scene.lightDirection {
        case "tl": (-1, -1)
        case "tr": (1, -1)
        case "l": (-1, 0)
        case "r": (1, 0)
        case "bl": (-1, 1)
        case "br": (1, 1)
        case "b": (0, 1)
        default: (0, -1)
        }
        // The rig turned about the line of sight, clockwise.
        let turn = (scene.lightRotation?.revolution ?? 0) * .pi / 180
        let length = hypot(x, y)
        return CGSize(
            width: (x * cos(turn) - y * sin(turn)) / length, height: (x * sin(turn) + y * cos(turn)) / length
        )
    }

    /// How much light and shade a material shows, against a matte one.
    static func material(_ name: String) -> (light: Double, shade: Double) {
        switch name {
        case "matte", "legacyMatte": (0.7, 1)
        case "plastic", "legacyPlastic": (1.15, 1)
        case "metal", "legacyMetal": (1.3, 1.25)
        case "softmetal": (1.1, 1)
        case "dkEdge": (0.8, 1.4)
        case "softEdge": (0.8, 0.7)
        case "flat": (0.25, 0.25)
        case "powder": (0.6, 0.7)
        case "translucentPowder": (0.55, 0.6)
        case "clear": (1, 0.6)
        case "legacyWireframe": (0, 0)
        default: (0.8, 0.9) // warmMatte
        }
    }

    /// How strongly a light rig picks out the bevel's slopes.
    static func lightStrength(_ rig: String) -> Double {
        switch rig {
        case "harsh": 1.3
        case "contrasting": 1.25
        case "balanced": 0.9
        case "soft": 0.75
        case "flood", "glow": 0.8
        case "brightRoom": 0.7
        case "flat": 0.35
        default: 1 // threePt, twoPt, morning, sunrise, sunset, chilly, freezing and the legacy rigs
        }
    }

    /// The bevel's profile, from its outer edge in, `bandCount` bands of it:
    /// how much each faces the light, -1…1, negative where it turns away.
    static func profile(_ preset: String) -> [Double] {
        switch preset {
        case "relaxedInset": [0.45, 0.6, 0.55, 0.4, 0.25, 0.1]
        case "slope": [0.7, 0.7, 0.7, 0.7, 0.7, 0.7]
        case "angle": [1, 1, 1, 1, 1, 1]
        case "softRound": [0.8, 0.7, 0.6, 0.45, 0.3, 0.15]
        case "convex": [0.25, 0.45, 0.6, 0.6, 0.45, 0.25]
        case "coolSlant": [1, 0.9, 0.8, 0.7, 0.6, 0.5]
        case "cross": [0.8, 0.8, 0.8, -0.6, -0.6, -0.6]
        case "divot": [-0.6, -0.45, -0.25, 0.25, 0.45, 0.6]
        case "riblet": [0.8, -0.5, 0.8, -0.5, 0.8, -0.5]
        case "hardEdge": [1, 1, 1, 0.9, 0.8, 0.6]
        case "artDeco": [1, 1, -0.4, 0.8, 0.8, -0.3]
        default: [1, 0.85, 0.65, 0.45, 0.25, 0.1] // circle
        }
    }
}

extension RGBAColor {
    /// The colour with its red, green and blue scaled by `factor`, its alpha kept.
    func scaled(by factor: Double) -> RGBAColor {
        RGBAColor(red: red * factor, green: green * factor, blue: blue * factor, alpha: alpha)
    }
}
