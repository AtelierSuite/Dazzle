import DazzleEngine
import Foundation

extension ShapeAnimation.Category {
    var label: String {
        switch self {
        case .entrance: String(localized: "Animation.Category.Entrance")
        case .emphasis: String(localized: "Animation.Category.Emphasis")
        case .exit: String(localized: "Animation.Category.Exit")
        case .motionPath: String(localized: "Animation.Category.MotionPath")
        case .other: String(localized: "Animation.Category.Other")
        }
    }

    /// PowerPoint's stars: green coming in, yellow for attention, red going out.
    var symbol: String {
        switch self {
        case .entrance, .emphasis, .exit: "star.fill"
        case .motionPath: "point.topleft.down.to.point.bottomright.curvepath"
        case .other: "play.circle"
        }
    }
}

extension ShapeAnimation {
    var label: String {
        if let colorChange {
            return switch colorChange.target {
            case .fill: String(localized: "Animation.Effect.FillColor")
            case .stroke: String(localized: "Animation.Effect.LineColor")
            case .text: String(localized: "Animation.Effect.FontColor")
            }
        }
        if opacity != nil { return String(localized: "Animation.Effect.Transparency") }
        if case .preset = effect {
            if rotationBehavior != nil { return String(localized: "Animation.Effect.Spin") }
            if scaling != nil { return String(localized: "Animation.Effect.GrowShrink") }
        }
        return effect.label(in: category)
    }
}

extension ShapeAnimation.Effect {
    func label(in category: ShapeAnimation.Category) -> String {
        let exits = category == .exit
        return switch self {
        case .appear: exits ? String(localized: "Animation.Effect.Disappear") : String(localized: "Animation.Effect.Appear")
        case .fade: String(localized: "Animation.Effect.Fade")
        case .fly: exits ? String(localized: "Animation.Effect.FlyOut") : String(localized: "Animation.Effect.FlyIn")
        case .wipe: String(localized: "Animation.Effect.Wipe")
        case .zoom: String(localized: "Animation.Effect.Zoom")
        case .float: exits ? String(localized: "Animation.Effect.FloatOut") : String(localized: "Animation.Effect.FloatIn")
        case .pulse: String(localized: "Animation.Effect.Pulse")
        case .spin: String(localized: "Animation.Effect.Spin")
        case .growShrink: String(localized: "Animation.Effect.GrowShrink")
        case .teeter: String(localized: "Animation.Effect.Teeter")
        case .path: String(localized: "Animation.Effect.Path")
        case .filter(let filter, _, _):
            switch filter.kind {
            case "blinds": String(localized: "Animation.Effect.Blinds")
            case "box": String(localized: "Animation.Effect.Box")
            case "checkerboard": String(localized: "Animation.Effect.Checkerboard")
            case "circle": String(localized: "Animation.Effect.Circle")
            case "diamond": String(localized: "Animation.Effect.Diamond")
            case "dissolve": String(localized: "Animation.Effect.Dissolve")
            case "plus": String(localized: "Animation.Effect.Plus")
            case "barn": String(localized: "Animation.Effect.Split")
            case "randombar": String(localized: "Animation.Effect.RandomBars")
            case "strips": String(localized: "Animation.Effect.Strips")
            case "wedge": String(localized: "Animation.Effect.Wedge")
            default: String(localized: "Animation.Effect.Wheel")
            }
        case .preset:
            category == .other("mediacall") ? String(localized: "Animation.Effect.Media") : String(localized: "Animation.Effect.Custom")
        }
    }

    var symbol: String {
        switch self {
        case .appear: "eye"
        case .fade: "circle.lefthalf.filled"
        case .fly: "arrow.up.forward"
        case .wipe: "rectangle.righthalf.inset.filled"
        case .zoom: "plus.magnifyingglass"
        case .float: "arrow.up.and.down"
        case .pulse: "dot.radiowaves.left.and.right"
        case .spin: "arrow.clockwise"
        case .growShrink: "arrow.up.left.and.arrow.down.right"
        case .teeter: "metronome"
        case .path: "point.topleft.down.to.point.bottomright.curvepath"
        case .preset, .filter: "sparkles"
        }
    }
}

extension ShapeAnimation.Direction {
    var label: String {
        switch self {
        case .top: String(localized: "Animation.Direction.Top")
        case .right: String(localized: "Animation.Direction.Right")
        case .bottom: String(localized: "Animation.Direction.Bottom")
        case .left: String(localized: "Animation.Direction.Left")
        }
    }
}

extension ShapeAnimation.Trigger {
    var label: String {
        switch self {
        case .onClick: String(localized: "Animation.Trigger.OnTap")
        case .withPrevious: String(localized: "Animation.Trigger.WithPrevious")
        case .afterPrevious: String(localized: "Animation.Trigger.AfterPrevious")
        }
    }
}

extension ShapeAnimation {
    /// The shape it animates, and for text built a paragraph at a time, which.
    func targetLabel(shape: SlideShape?) -> String {
        let name = shape?.name.nilIfEmpty ?? String(localized: "Animation.UnnamedShape")
        guard let paragraphs else { return name }
        let which = paragraphs.count == 1
            ? String(format: String(localized: "Animation.Paragraph"), paragraphs.lowerBound + 1)
            : String(format: String(localized: "Animation.Paragraphs"), paragraphs.lowerBound + 1, paragraphs.upperBound + 1)
        return name + " · " + which
    }
}

extension Chart.Kind {
    var label: String {
        switch self {
        case .column: String(localized: "Chart.Kind.Column")
        case .bar: String(localized: "Chart.Kind.Bar")
        case .line: String(localized: "Chart.Kind.Line")
        case .area: String(localized: "Chart.Kind.Area")
        case .pie: String(localized: "Chart.Kind.Pie")
        case .doughnut: String(localized: "Chart.Kind.Doughnut")
        case .scatter: String(localized: "Chart.Kind.Scatter")
        case .radar: String(localized: "Chart.Kind.Radar")
        case .stock: String(localized: "Chart.Kind.Stock")
        case .bubble: String(localized: "Chart.Kind.Bubble")
        case .surface: String(localized: "Chart.Kind.Surface")
        case .pieOfPie: String(localized: "Chart.Kind.PieOfPie")
        case .barOfPie: String(localized: "Chart.Kind.BarOfPie")
        }
    }

    var symbol: String {
        switch self {
        case .column: "chart.bar"
        case .bar: "chart.bar.horizontal"
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .pie: "chart.pie"
        case .doughnut: "circle.circle"
        case .scatter: "chart.dots.scatter"
        case .radar: "hexagon"
        case .stock: "chart.line.uptrend.xyaxis"
        case .bubble: "circle.grid.2x2"
        case .surface: "square.grid.3x3.fill"
        case .pieOfPie: "chart.pie.fill"
        case .barOfPie: "chart.pie.fill"
        }
    }
}

/// The shapes the Shape menu offers, by DrawingML preset.
struct ShapeChoice: Identifiable {
    let preset: String
    let label: String
    let symbol: String

    var id: String { preset }

    static let all = [
        ShapeChoice(preset: "rect", label: String(localized: "Shape.Rectangle"), symbol: "rectangle"),
        ShapeChoice(preset: "roundRect", label: String(localized: "Shape.RoundedRectangle"), symbol: "rectangle.roundedtop"),
        ShapeChoice(preset: "ellipse", label: String(localized: "Shape.Oval"), symbol: "circle"),
        ShapeChoice(preset: "triangle", label: String(localized: "Shape.Triangle"), symbol: "triangle"),
        ShapeChoice(preset: "diamond", label: String(localized: "Shape.Diamond"), symbol: "diamond"),
        ShapeChoice(preset: "star5", label: String(localized: "Shape.Star"), symbol: "star"),
        ShapeChoice(preset: "rightArrow", label: String(localized: "Shape.Arrow"), symbol: "arrow.right"),
        ShapeChoice(preset: "wedgeRoundRectCallout", label: String(localized: "Shape.Callout"), symbol: "bubble.left"),
        ShapeChoice(preset: "line", label: String(localized: "Shape.Line"), symbol: "line.diagonal"),
    ]
}

/// The shadows, reflections, effects, warps, patterns and lines the format controls offer.
enum FormatChoices {
    struct ReflectionChoice {
        let id: String
        let label: String
        let reflection: Reflection?
    }

    /// PowerPoint's touching reflections.
    static let reflections = [
        ReflectionChoice(id: "none", label: String(localized: "Reflection.None"), reflection: nil),
        ReflectionChoice(id: "tight", label: String(localized: "Reflection.Tight"), reflection: Reflection(
            startOpacity: 0.52, endOpacity: 0.003, endPosition: 0.35, blur: 6_350, rotatesWithShape: false
        )),
        ReflectionChoice(id: "half", label: String(localized: "Reflection.Half"), reflection: Reflection(
            startOpacity: 0.52, endOpacity: 0.003, endPosition: 0.55, blur: 6_350, rotatesWithShape: false
        )),
        ReflectionChoice(id: "full", label: String(localized: "Reflection.Full"), reflection: Reflection(
            startOpacity: 0.52, endOpacity: 0.003, endPosition: 0.9, blur: 6_350, rotatesWithShape: false
        )),
    ]

    struct ShadowChoice {
        let id: String
        let label: String
        let shadow: Shadow?
    }

    /// PowerPoint's most used outer shadows.
    static let shadows = [
        ShadowChoice(id: "none", label: String(localized: "Shadow.None"), shadow: nil),
        ShadowChoice(id: "drop", label: String(localized: "Shadow.Drop"), shadow: Shadow(
            blur: 50_800, distance: 38_100, direction: 45, color: Shadow.black(opacity: 0.4)
        )),
        ShadowChoice(id: "soft", label: String(localized: "Shadow.Soft"), shadow: Shadow(
            blur: 152_400, distance: 50_800, direction: 90, color: Shadow.black(opacity: 0.35)
        )),
        ShadowChoice(id: "close", label: String(localized: "Shadow.Close"), shadow: Shadow(
            blur: 25_400, distance: 19_050, direction: 45, color: Shadow.black(opacity: 0.6)
        )),
        ShadowChoice(id: "below", label: String(localized: "Shadow.Below"), shadow: Shadow(
            blur: 76_200, distance: 76_200, direction: 90, color: Shadow.black(opacity: 0.3)
        )),
    ]

    /// Glows of PowerPoint's sizes, in points, in the accent colour until another is picked.
    static let glowSizes: [Double] = [5, 8, 11, 18]

    /// A glow's colour: the one picked, 60% see-through as PowerPoint's are.
    static func glowColor(_ color: DrawingColor) -> DrawingColor {
        var color = color
        color.transforms.removeAll { $0.name == "alpha" }
        color.transforms.append(.init(name: "alpha", value: 40_000))
        return color
    }

    /// PowerPoint's soft edges, in points.
    static let softEdgeSizes: [Double] = [1, 2.5, 5, 10, 25, 50]

    struct InnerShadowChoice {
        let id: String
        let label: String
        let shadow: InnerShadow?
    }

    /// PowerPoint's inner shadows, each falling from the edge it names.
    static let innerShadows: [InnerShadowChoice] = {
        func inside(_ id: String, _ key: String.LocalizationValue, blur: Int = 63_500, distance: Int = 50_800, direction: Double)
            -> InnerShadowChoice {
            InnerShadowChoice(id: id, label: String(localized: key), shadow: InnerShadow(
                blur: blur, distance: distance, direction: direction, color: Shadow.black(opacity: 0.5)
            ))
        }
        return [
            InnerShadowChoice(id: "none", label: String(localized: "Effect.None"), shadow: nil),
            inside("topLeft", "InnerShadow.TopLeft", direction: 225),
            inside("top", "InnerShadow.Top", direction: 270),
            inside("topRight", "InnerShadow.TopRight", direction: 315),
            inside("left", "InnerShadow.Left", direction: 180),
            inside("center", "InnerShadow.Center", blur: 114_300, distance: 0, direction: 0),
            inside("right", "InnerShadow.Right", direction: 0),
            inside("bottomLeft", "InnerShadow.BottomLeft", direction: 135),
            inside("bottom", "InnerShadow.Bottom", direction: 90),
            inside("bottomRight", "InnerShadow.BottomRight", direction: 45),
        ]
    }()

    /// The bevel profiles, as PowerPoint lists them; each is made 6 points wide and deep.
    static let bevels: [(String, String)] = [
        ("circle", String(localized: "Bevel.Circle")),
        ("relaxedInset", String(localized: "Bevel.RelaxedInset")),
        ("cross", String(localized: "Bevel.Cross")),
        ("coolSlant", String(localized: "Bevel.CoolSlant")),
        ("angle", String(localized: "Bevel.Angle")),
        ("softRound", String(localized: "Bevel.SoftRound")),
        ("convex", String(localized: "Bevel.Convex")),
        ("slope", String(localized: "Bevel.Slope")),
        ("divot", String(localized: "Bevel.Divot")),
        ("riblet", String(localized: "Bevel.Riblet")),
        ("hardEdge", String(localized: "Bevel.HardEdge")),
        ("artDeco", String(localized: "Bevel.ArtDeco")),
    ]

    /// How far a shape can stand out, in points.
    static let depthRange: ClosedRange<Double> = 0...200

    /// Cameras that show a shape's depth: the plain front view, then some
    /// of PowerPoint's oblique, perspective and isometric ones.
    static let cameras: [(String, String)] = [
        ("orthographicFront", String(localized: "Camera.OrthographicFront")),
        ("obliqueTopLeft", String(localized: "Camera.ObliqueTopLeft")),
        ("obliqueTopRight", String(localized: "Camera.ObliqueTopRight")),
        ("obliqueBottomLeft", String(localized: "Camera.ObliqueBottomLeft")),
        ("obliqueBottomRight", String(localized: "Camera.ObliqueBottomRight")),
        ("perspectiveRelaxed", String(localized: "Camera.PerspectiveRelaxed")),
        ("isometricOffAxis1Right", String(localized: "Camera.IsometricOffAxis1Right")),
        ("isometricOffAxis2Left", String(localized: "Camera.IsometricOffAxis2Left")),
    ]

    /// PowerPoint's WordArt warps, in the order it lists them.
    static let textWarps: [(String, String)] = [
        ("textPlain", String(localized: "TextWarp.Plain")),
        ("textStop", String(localized: "TextWarp.Stop")),
        ("textTriangle", String(localized: "TextWarp.Triangle")),
        ("textTriangleInverted", String(localized: "TextWarp.TriangleInverted")),
        ("textChevron", String(localized: "TextWarp.Chevron")),
        ("textChevronInverted", String(localized: "TextWarp.ChevronInverted")),
        ("textRingInside", String(localized: "TextWarp.RingInside")),
        ("textRingOutside", String(localized: "TextWarp.RingOutside")),
        ("textArchUp", String(localized: "TextWarp.ArchUp")),
        ("textArchDown", String(localized: "TextWarp.ArchDown")),
        ("textCircle", String(localized: "TextWarp.Circle")),
        ("textButton", String(localized: "TextWarp.Button")),
        ("textArchUpPour", String(localized: "TextWarp.ArchUpPour")),
        ("textArchDownPour", String(localized: "TextWarp.ArchDownPour")),
        ("textCirclePour", String(localized: "TextWarp.CirclePour")),
        ("textButtonPour", String(localized: "TextWarp.ButtonPour")),
        ("textCurveUp", String(localized: "TextWarp.CurveUp")),
        ("textCurveDown", String(localized: "TextWarp.CurveDown")),
        ("textCanUp", String(localized: "TextWarp.CanUp")),
        ("textCanDown", String(localized: "TextWarp.CanDown")),
        ("textWave1", String(localized: "TextWarp.Wave1")),
        ("textWave2", String(localized: "TextWarp.Wave2")),
        ("textDoubleWave1", String(localized: "TextWarp.DoubleWave1")),
        ("textWave4", String(localized: "TextWarp.Wave4")),
        ("textInflate", String(localized: "TextWarp.Inflate")),
        ("textDeflate", String(localized: "TextWarp.Deflate")),
        ("textInflateBottom", String(localized: "TextWarp.InflateBottom")),
        ("textDeflateBottom", String(localized: "TextWarp.DeflateBottom")),
        ("textInflateTop", String(localized: "TextWarp.InflateTop")),
        ("textDeflateTop", String(localized: "TextWarp.DeflateTop")),
        ("textDeflateInflate", String(localized: "TextWarp.DeflateInflate")),
        ("textDeflateInflateDeflate", String(localized: "TextWarp.DeflateInflateDeflate")),
        ("textFadeRight", String(localized: "TextWarp.FadeRight")),
        ("textFadeLeft", String(localized: "TextWarp.FadeLeft")),
        ("textFadeUp", String(localized: "TextWarp.FadeUp")),
        ("textFadeDown", String(localized: "TextWarp.FadeDown")),
        ("textSlantUp", String(localized: "TextWarp.SlantUp")),
        ("textSlantDown", String(localized: "TextWarp.SlantDown")),
        ("textCascadeUp", String(localized: "TextWarp.CascadeUp")),
        ("textCascadeDown", String(localized: "TextWarp.CascadeDown")),
    ]

    /// The patterns PowerPoint offers, in its order. The six older names
    /// at the end of the list duplicate others; a pattern using one keeps it.
    static var patterns: [(String, String)] {
        Fill.Pattern.presetNames.dropLast(6).map { ($0, patternLabel($0)) }
    }

    static func patternLabel(_ preset: String) -> String {
        switch preset {
        case let name where name.hasPrefix("pct"):
            // 5%, 10% and so on.
            "\(name.dropFirst(3))%"
        case "ltDnDiag": String(localized: "Pattern.LtDnDiag")
        case "ltUpDiag": String(localized: "Pattern.LtUpDiag")
        case "dkDnDiag": String(localized: "Pattern.DkDnDiag")
        case "dkUpDiag": String(localized: "Pattern.DkUpDiag")
        case "wdDnDiag": String(localized: "Pattern.WdDnDiag")
        case "wdUpDiag": String(localized: "Pattern.WdUpDiag")
        case "ltVert": String(localized: "Pattern.LtVert")
        case "ltHorz": String(localized: "Pattern.LtHorz")
        case "narVert": String(localized: "Pattern.NarVert")
        case "narHorz": String(localized: "Pattern.NarHorz")
        case "dkVert": String(localized: "Pattern.DkVert")
        case "dkHorz": String(localized: "Pattern.DkHorz")
        case "dashDnDiag": String(localized: "Pattern.DashDnDiag")
        case "dashUpDiag": String(localized: "Pattern.DashUpDiag")
        case "dashHorz": String(localized: "Pattern.DashHorz")
        case "dashVert": String(localized: "Pattern.DashVert")
        case "smConfetti": String(localized: "Pattern.SmConfetti")
        case "lgConfetti": String(localized: "Pattern.LgConfetti")
        case "zigZag": String(localized: "Pattern.ZigZag")
        case "wave": String(localized: "Pattern.Wave")
        case "diagBrick": String(localized: "Pattern.DiagBrick")
        case "horzBrick": String(localized: "Pattern.HorzBrick")
        case "weave": String(localized: "Pattern.Weave")
        case "plaid": String(localized: "Pattern.Plaid")
        case "divot": String(localized: "Pattern.Divot")
        case "dotGrid": String(localized: "Pattern.DotGrid")
        case "dotDmnd": String(localized: "Pattern.DotDmnd")
        case "shingle": String(localized: "Pattern.Shingle")
        case "trellis": String(localized: "Pattern.Trellis")
        case "sphere": String(localized: "Pattern.Sphere")
        case "smGrid": String(localized: "Pattern.SmGrid")
        case "lgGrid": String(localized: "Pattern.LgGrid")
        case "smCheck": String(localized: "Pattern.SmCheck")
        case "lgCheck": String(localized: "Pattern.LgCheck")
        case "openDmnd": String(localized: "Pattern.OpenDmnd")
        case "solidDmnd": String(localized: "Pattern.SolidDmnd")
        default: preset
        }
    }

    static let dashes: [(String, String)] = [
        ("solid", String(localized: "Line.Solid")), ("sysDash", String(localized: "Line.Dash")), ("sysDot", String(localized: "Line.Dot")),
        ("dashDot", String(localized: "Line.DashDot")), ("lgDash", String(localized: "Line.LongDash")),
    ]

    static let lineEnds: [(String, String)] = [
        ("none", String(localized: "Line.End.None")), ("triangle", String(localized: "Line.End.Triangle")), ("arrow", String(localized: "Line.End.Arrow")),
        ("stealth", String(localized: "Line.End.Stealth")), ("oval", String(localized: "Line.End.Oval")), ("diamond", String(localized: "Line.End.Diamond")),
    ]
}

extension SlideSizeConverter.Preset {
    var label: String {
        switch self {
        case .widescreen: String(localized: "SlideSize.Widescreen")
        case .standard: String(localized: "SlideSize.Standard")
        case .widescreen16x10: String(localized: "SlideSize.Widescreen16x10")
        case .a4: String(localized: "SlideSize.A4")
        }
    }
}
