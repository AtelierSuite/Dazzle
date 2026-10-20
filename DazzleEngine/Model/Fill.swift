import Foundation

/// How the inside of a shape, or a background, is painted.
public enum Fill: Equatable, Hashable, Sendable {
    case none
    case solid(DrawingColor)
    case gradient(Gradient)
    /// A picture, by its path inside the package, stretched over the area.
    case picture(path: String, effects: BlipEffects = BlipEffects())
    /// A picture repeated at its own size across the area.
    case tiledPicture(path: String, effects: BlipEffects = BlipEffects())
    /// Whatever the enclosing group is filled with.
    case group

    public struct Gradient: Equatable, Hashable, Sendable {
        public struct Stop: Equatable, Hashable, Sendable {
            /// 0…1 along the gradient.
            public var position: Double
            public var color: DrawingColor

            public init(position: Double, color: DrawingColor) {
                self.position = position
                self.color = color
            }
        }

        public var stops: [Stop]
        /// Degrees clockwise from left-to-right, for a linear gradient.
        public var angle: Double
        public var isRadial: Bool
        /// Where a radial gradient starts, as fractions of the area.
        public var focusX = 0.5
        public var focusY = 0.5

        public init(stops: [Stop], angle: Double, isRadial: Bool, focusX: Double = 0.5, focusY: Double = 0.5) {
            self.stops = stops
            self.angle = angle
            self.isRadial = isRadial
            self.focusX = focusX
            self.focusY = focusY
        }
    }

    /// Names of the elements a fill can be written as; finding one of these
    /// among an element's children means that element states its own fill.
    public static let elementNames: Set<String> = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]

    /// Reads the fill element among `parent`'s children, if it has one.
    /// `image` turns a relationship id into a package path.
    public static func parse(in parent: XMLElement?, image: (String) -> String?) -> Fill? {
        guard let parent else { return nil }
        for child in parent.children {
            if let fill = parse(element: child, image: image) { return fill }
        }
        return nil
    }

    public static func parse(element: XMLElement, image: (String) -> String?) -> Fill? {
        switch element.name {
        case "noFill":
            return Fill.none
        case "solidFill":
            return DrawingColor.first(in: element).map(Fill.solid) ?? Fill.none
        case "gradFill":
            let stops = (element.firstChild(named: "gsLst")?.children(named: "gs") ?? []).compactMap { stop in
                DrawingColor.first(in: stop).map {
                    Gradient.Stop(position: Double(stop.attribute("pos").flatMap(Int.init) ?? 0) / 100_000, color: $0)
                }
            }.sorted { $0.position < $1.position }
            guard !stops.isEmpty else { return Fill.none }
            let angle = Double(element.firstChild(named: "lin")?.attribute("ang").flatMap(Int.init) ?? 0) / 60_000
            var gradient = Gradient(stops: stops, angle: angle, isRadial: element.firstChild(named: "path") != nil)
            // `fillToRect` insets the focus from each edge; its centre is where the gradient starts.
            if let focus = element.firstChild(named: "path")?.firstChild(named: "fillToRect") {
                func inset(_ key: String) -> Double { Double(focus.attribute(key).flatMap(Int.init) ?? 0) / 100_000 }
                gradient.focusX = (inset("l") + 1 - inset("r")) / 2
                gradient.focusY = (inset("t") + 1 - inset("b")) / 2
            }
            return .gradient(gradient)
        case "blipFill":
            guard let reference = element.firstChild(named: "blip")?.attribute("embed"),
                  let path = image(reference) else { return Fill.none }
            let effects = BlipEffects(blip: element.firstChild(named: "blip"))
            return element.firstChild(named: "tile") != nil
                ? .tiledPicture(path: path, effects: effects) : .picture(path: path, effects: effects)
        case "pattFill":
            // A pattern is drawn as its foreground, which is what it reads as at a distance.
            return DrawingColor.first(in: element.firstChild(named: "fgClr")).map(Fill.solid) ?? Fill.none
        case "grpFill":
            return .group
        default:
            return nil
        }
    }

    /// The fill as DrawingML. Picture fills are never written by Dazzle, so
    /// they come back as nothing rather than as a dangling reference.
    public var xml: String {
        switch self {
        case .none, .picture, .tiledPicture: return "<a:noFill/>"
        case .group: return "<a:grpFill/>"
        case .solid(let color): return "<a:solidFill>\(color.xml)</a:solidFill>"
        case .gradient(let gradient):
            let stops = gradient.stops.map { "<a:gs pos=\"\(Int($0.position * 100_000))\">\($0.color.xml)</a:gs>" }
            let shade = gradient.isRadial
                ? "<a:path path=\"circle\"><a:fillToRect l=\"50000\" t=\"50000\" r=\"50000\" b=\"50000\"/></a:path>"
                : "<a:lin ang=\"\(Int(gradient.angle * 60_000))\" scaled=\"0\"/>"
            return "<a:gradFill rotWithShape=\"1\"><a:gsLst>\(stops.joined())</a:gsLst>\(shade)</a:gradFill>"
        }
    }
}

/// What a picture's `a:blip` does to its colours.
public struct BlipEffects: Equatable, Hashable, Sendable {
    /// `alphaModFix`: the whole picture partly transparent.
    public var opacity = 1.0
    /// `grayscl`.
    public var isGreyscale = false
    /// `duotone`: dark to light mapped onto these two colours.
    public var duotone: [DrawingColor] = []
    /// `lum`: picture brightness and contrast, distinct from its alpha.
    public var brightness = 0.0
    public var contrast = 0.0

    public init() {
        // No effects: the picture as it is.
    }

    public init(blip: XMLElement?) {
        guard let blip else { return }
        opacity = blip.firstChild(named: "alphaModFix")?.attribute("amt").flatMap(Double.init).map { $0 / 100_000 } ?? 1
        isGreyscale = blip.firstChild(named: "grayscl") != nil
        let tones = blip.firstChild(named: "duotone")?.children.compactMap(DrawingColor.init(element:)) ?? []
        if tones.count == 2 { duotone = tones }
        if let lum = blip.firstChild(named: "lum") {
            brightness = (lum.attribute("bright").flatMap(Double.init) ?? 0) / 100_000
            contrast = (lum.attribute("contrast").flatMap(Double.init) ?? 0) / 100_000
        }
    }

    /// Whether the picture's colours change at all.
    public var altersColor: Bool { isGreyscale || !duotone.isEmpty || brightness != 0 || contrast != 0 }

    public var xml: String {
        let alpha = opacity < 1 ? "<a:alphaModFix amt=\"\(Int((opacity * 100_000).rounded()))\"/>" : ""
        let grey = isGreyscale ? "<a:grayscl/>" : ""
        let tones = duotone.count == 2 ? "<a:duotone>\(duotone.map(\.xml).joined())</a:duotone>" : ""
        let lum = brightness != 0 || contrast != 0
            ? "<a:lum bright=\"\(Int((brightness * 100_000).rounded()))\" contrast=\"\(Int((contrast * 100_000).rounded()))\"/>" : ""
        return alpha + grey + tones + lum
    }
}

/// The outline of a shape.
public struct LineStyle: Equatable, Hashable, Sendable {
    /// `nil` when the line does not say, leaving it to the shape's style.
    public var fill: Fill?
    /// EMU; `nil` when the line does not say.
    public var width: Int?
    /// A preset dash name, such as `dash` or `sysDot`.
    public var dash: String?
    /// Arrowhead types at either end, such as `triangle`.
    public var head: String?
    public var tail: String?

    public init(fill: Fill? = nil, width: Int? = nil, dash: String? = nil, head: String? = nil, tail: String? = nil) {
        self.fill = fill
        self.width = width
        self.dash = dash
        self.head = head
        self.tail = tail
    }

    public init(element: XMLElement) {
        fill = Fill.parse(in: element) { _ in nil }
        width = element.attribute("w").flatMap(Int.init)
        dash = element.firstChild(named: "prstDash")?.attribute("val")
        head = element.firstChild(named: "headEnd")?.attribute("type").flatMap { $0 == "none" ? nil : $0 }
        tail = element.firstChild(named: "tailEnd")?.attribute("type").flatMap { $0 == "none" ? nil : $0 }
    }

    /// Values this line leaves unsaid are taken from `base`.
    public func merged(over base: LineStyle?) -> LineStyle {
        guard let base else { return self }
        return LineStyle(
            fill: fill ?? base.fill, width: width ?? base.width, dash: dash ?? base.dash,
            head: head ?? base.head, tail: tail ?? base.tail
        )
    }
}

/// A shape's `p:style`: which of the theme's fill, line and font styles it
/// uses, and the colour each is drawn in.
public struct StyleReferences: Equatable, Hashable, Sendable {
    public struct Reference: Equatable, Hashable, Sendable {
        public var index: Int
        public var color: DrawingColor?
    }

    public var fill: Reference?
    public var line: Reference?
    /// The font reference only ever matters for its colour.
    public var fontColor: DrawingColor?

    public init?(element: XMLElement?) {
        guard let element else { return nil }
        func reference(_ name: String) -> Reference? {
            element.firstChild(named: name).map { child in
                Reference(index: child.attribute("idx").flatMap(Int.init) ?? 0, color: DrawingColor.first(in: child))
            }
        }
        fill = reference("fillRef")
        line = reference("lnRef")
        fontColor = DrawingColor.first(in: element.firstChild(named: "fontRef"))
    }
}

/// A slide, layout or master background.
public enum Background: Equatable, Hashable, Sendable {
    case fill(Fill)
    /// One of the theme's background fills, painted in the given colour.
    case reference(index: Int, color: DrawingColor?)

    public init?(element: XMLElement?, image: (String) -> String?) {
        guard let element else { return nil }
        if let properties = element.firstChild(named: "bgPr") {
            self = .fill(Fill.parse(in: properties, image: image) ?? .none)
        } else if let reference = element.firstChild(named: "bgRef") {
            self = .reference(
                index: reference.attribute("idx").flatMap(Int.init) ?? 0,
                color: DrawingColor.first(in: reference)
            )
        } else {
            return nil
        }
    }
}

/// `a:outerShdw`: a shadow cast behind a shape.
public struct Shadow: Equatable, Hashable, Sendable {
    /// EMU.
    public var blur: Int
    /// EMU, from the shape to the shadow.
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

    public var xml: String {
        "<a:outerShdw blurRad=\"\(blur)\" dist=\"\(distance)\" dir=\"\(Int((direction * 60_000).rounded()))\" "
            + "algn=\"ctr\" rotWithShape=\"0\">\(color.xml)</a:outerShdw>"
    }

    /// Black at a given opacity.
    public static func black(opacity: Double) -> DrawingColor {
        DrawingColor(base: .rgb(0x000000), transforms: [.init(name: "alpha", value: Int(opacity * 100_000))])
    }
}

/// `a:reflection`: the shape mirrored below its bottom edge, fading as it goes.
public struct Reflection: Equatable, Hashable, Sendable {
    /// Opacity where the reflection meets the shape.
    public var startOpacity: Double
    /// Opacity where the fade ends, and beyond.
    public var endOpacity: Double
    /// Where the fade ends, as a fraction of the shape's height.
    public var endPosition: Double
    /// EMU between the shape and its reflection.
    public var distance: Int
    /// EMU the reflection is blurred by.
    public var blur: Int
    /// Whether the reflection turns with the shape, along its bottom edge,
    /// rather than lying upright below the space the turned shape covers.
    public var rotatesWithShape: Bool

    public init(
        startOpacity: Double, endOpacity: Double = 0, endPosition: Double, distance: Int = 0, blur: Int = 0,
        rotatesWithShape: Bool = true
    ) {
        self.startOpacity = startOpacity
        self.endOpacity = endOpacity
        self.endPosition = endPosition
        self.distance = distance
        self.blur = blur
        self.rotatesWithShape = rotatesWithShape
    }

    public init?(element: XMLElement?) {
        guard let element else { return nil }
        func fraction(_ key: String, _ fallback: Int) -> Double {
            Double(element.attribute(key).flatMap(Int.init) ?? fallback) / 100_000
        }
        startOpacity = fraction("stA", 100_000)
        endOpacity = fraction("endA", 0)
        endPosition = fraction("endPos", 100_000)
        distance = element.attribute("dist").flatMap(Int.init) ?? 0
        blur = element.attribute("blurRad").flatMap(Int.init) ?? 0
        rotatesWithShape = element.attribute("rotWithShape").map { $0 == "1" || $0 == "true" } ?? true
    }

    public var xml: String {
        func value(_ fraction: Double) -> Int { Int((min(max(fraction, 0), 1) * 100_000).rounded()) }
        return "<a:reflection blurRad=\"\(blur)\" stA=\"\(value(startOpacity))\" endA=\"\(value(endOpacity))\" "
            + "endPos=\"\(value(endPosition))\" dist=\"\(distance)\" dir=\"5400000\" sy=\"-100000\" algn=\"bl\" "
            + "rotWithShape=\"\(rotatesWithShape ? 1 : 0)\"/>"
    }
}

