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

/// The shadows, reflections and lines the format controls offer.
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
