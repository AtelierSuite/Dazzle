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
