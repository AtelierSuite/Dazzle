import Foundation

/// How the inside of a shape, or a background, is painted.
public enum Fill: Equatable, Hashable, Sendable {
    case none
    case solid(DrawingColor)
    case gradient(Gradient)
    /// A picture, by its path inside the package, stretched over the area.
    case picture(path: String, effects: BlipEffects = BlipEffects())
    /// A picture repeated across the area, laid out as `tile` says.
    case tiledPicture(path: String, effects: BlipEffects = BlipEffects(), tile: Tile = Tile())
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

    /// `a:tile`: how a tiled picture is scaled, placed and mirrored.
    public struct Tile: Equatable, Hashable, Sendable {
        /// Which tiles are mirrored: every other one across, down, or both.
        public enum Flip: String, Sendable, CaseIterable {
            case none, x, y, xy
        }

        /// The point of the area the first tile is laid against.
        public enum Alignment: String, Sendable, CaseIterable {
            case topLeft = "tl", top = "t", topRight = "tr"
            case left = "l", center = "ctr", right = "r"
            case bottomLeft = "bl", bottom = "b", bottomRight = "br"

            /// 0, 0.5 or 1 across and down the area.
            public var fractions: (x: Double, y: Double) {
                switch self {
                case .topLeft: (0, 0)
                case .top: (0.5, 0)
                case .topRight: (1, 0)
                case .left: (0, 0.5)
                case .center: (0.5, 0.5)
                case .right: (1, 0.5)
                case .bottomLeft: (0, 1)
                case .bottom: (0.5, 1)
                case .bottomRight: (1, 1)
                }
            }
        }

        /// EMU the tiles are moved by, after alignment.
        public var offsetX = 0
        public var offsetY = 0
        /// The tile's size as a fraction of the picture's own.
        public var scaleX = 1.0
        public var scaleY = 1.0
        public var flip = Flip.none
        public var alignment = Alignment.topLeft

        public init(
            offsetX: Int = 0, offsetY: Int = 0, scaleX: Double = 1, scaleY: Double = 1,
            flip: Flip = .none, alignment: Alignment = .topLeft
        ) {
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.scaleX = scaleX
            self.scaleY = scaleY
            self.flip = flip
            self.alignment = alignment
        }

        public init(element: XMLElement?) {
            guard let element else { return }
            // Percentages come as thousandths of a percent, or in strict files as "50%".
            func percentage(_ key: String) -> Double? {
                guard let value = element.attribute(key) else { return nil }
                if value.hasSuffix("%") { return Double(value.dropLast()).map { $0 / 100 } }
                return Double(value).map { $0 / 100_000 }
            }
            offsetX = element.attribute("tx").flatMap(Int.init) ?? 0
            offsetY = element.attribute("ty").flatMap(Int.init) ?? 0
            scaleX = percentage("sx") ?? 1
            scaleY = percentage("sy") ?? 1
            flip = element.attribute("flip").flatMap(Flip.init(rawValue:)) ?? .none
            alignment = element.attribute("algn").flatMap(Alignment.init(rawValue:)) ?? .topLeft
        }

        public var xml: String {
            "<a:tile tx=\"\(offsetX)\" ty=\"\(offsetY)\" sx=\"\(Int((scaleX * 100_000).rounded()))\" "
                + "sy=\"\(Int((scaleY * 100_000).rounded()))\" flip=\"\(flip.rawValue)\" algn=\"\(alignment.rawValue)\"/>"
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
            if let tile = element.firstChild(named: "tile") {
                return .tiledPicture(path: path, effects: effects, tile: Tile(element: tile))
            }
            return .picture(path: path, effects: effects)
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
    /// `clrChange`: one colour of the picture swapped for another, most
    /// often for transparency ("Set Transparent Colour").
    public struct ColorChange: Equatable, Hashable, Sendable {
        public var from: DrawingColor
        public var to: DrawingColor
        /// `useA`: whether a pixel's alpha has to match `from`'s too.
        public var usesAlpha = true

        public init(from: DrawingColor, to: DrawingColor, usesAlpha: Bool = true) {
            self.from = from
            self.to = to
            self.usesAlpha = usesAlpha
        }

        /// How far a pixel may be from `from` and still be changed: the sum
        /// of its channels' differences, 0…3. The file gives no tolerance,
        /// but PowerPoint takes near colours too, without which a JPEG's
        /// compression would leave a speckled fringe where the colour was.
        public static let tolerance = 0.1

        var xml: String {
            "<a:clrChange\(usesAlpha ? "" : " useA=\"0\"")><a:clrFrom>\(from.xml)</a:clrFrom><a:clrTo>\(to.xml)</a:clrTo></a:clrChange>"
        }
    }

    /// `alphaModFix`: the whole picture partly transparent.
    public var opacity = 1.0
    public var colorChange: ColorChange?
    /// `biLevel`: black or white either side of this luminance, 0…1.
    public var biLevelThreshold: Double?
    /// `grayscl`.
    public var isGreyscale = false
    /// `duotone`: dark to light mapped onto these two colours.
    public var duotone: [DrawingColor] = []
    /// `hsl`: hue turned by degrees; saturation and luminance moved by −1…1.
    public var hueShift = 0.0
    public var saturationShift = 0.0
    public var luminanceShift = 0.0
    /// `tint`: colours pulled towards a hue in degrees, by −1…1.
    public var tintHue = 0.0
    public var tintAmount = 0.0
    /// `lum`: picture brightness and contrast, distinct from its alpha.
    public var brightness = 0.0
    public var contrast = 0.0
    /// `a14:imgEffect`s: the artistic effects and picture corrections of
    /// Office 2010 and later, in the order they were applied.
    public var artistic: [ArtisticEffect] = []
    /// Whether `a14:imgLayer` keeps the original picture apart (`r:embed`).
    /// It does when Office wrote it, and then the blip's own picture is the
    /// original with `artistic` already applied, to be shown as it is.
    public var hasOriginalLayer = false

    public init() {
        // No effects: the picture as it is.
    }

    public init(blip: XMLElement?) {
        guard let blip else { return }
        func fraction(_ element: XMLElement?, _ key: String) -> Double? {
            element?.attribute(key).flatMap(Double.init).map { $0 / 100_000 }
        }
        opacity = fraction(blip.firstChild(named: "alphaModFix"), "amt") ?? 1
        if let change = blip.firstChild(named: "clrChange"),
           let from = DrawingColor.first(in: change.firstChild(named: "clrFrom")),
           let to = DrawingColor.first(in: change.firstChild(named: "clrTo")) {
            colorChange = ColorChange(from: from, to: to, usesAlpha: !["0", "false"].contains(change.attribute("useA") ?? ""))
        }
        if let biLevel = blip.firstChild(named: "biLevel") {
            biLevelThreshold = fraction(biLevel, "thresh") ?? 0
        }
        isGreyscale = blip.firstChild(named: "grayscl") != nil
        let tones = blip.firstChild(named: "duotone")?.children.compactMap(DrawingColor.init(element:)) ?? []
        if tones.count == 2 { duotone = tones }
        if let hsl = blip.firstChild(named: "hsl") {
            hueShift = (hsl.attribute("hue").flatMap(Double.init) ?? 0) / 60_000
            saturationShift = fraction(hsl, "sat") ?? 0
            luminanceShift = fraction(hsl, "lum") ?? 0
        }
        if let tint = blip.firstChild(named: "tint") {
            tintHue = (tint.attribute("hue").flatMap(Double.init) ?? 0) / 60_000
            tintAmount = fraction(tint, "amt") ?? 0
        }
        if let lum = blip.firstChild(named: "lum") {
            brightness = fraction(lum, "bright") ?? 0
            contrast = fraction(lum, "contrast") ?? 0
        }
        // `a:extLst/a:ext/a14:imgProps/a14:imgLayer/a14:imgEffect/…`
        let layer = blip.firstChild(named: "extLst")?.children(named: "ext")
            .lazy.compactMap { $0.firstChild(named: "imgProps")?.firstChild(named: "imgLayer") }.first
        if let layer {
            hasOriginalLayer = !(layer.attribute("embed") ?? "").isEmpty
            artistic = layer.children(named: "imgEffect").compactMap { $0.children.first.map(ArtisticEffect.init(element:)) }
        }
    }

    /// The artistic effects still to be applied when the picture is drawn:
    /// none when the blip's picture already has them.
    public var pendingArtistic: [ArtisticEffect] {
        hasOriginalLayer ? [] : artistic.filter { $0.isVisible && $0.look != nil }
    }

    /// Whether the picture's colours change at all.
    public var altersColor: Bool {
        colorChange != nil || biLevelThreshold != nil || isGreyscale || !duotone.isEmpty
            || hueShift != 0 || saturationShift != 0 || luminanceShift != 0 || tintAmount != 0
            || brightness != 0 || contrast != 0 || !pendingArtistic.isEmpty
    }

    /// The effects' colours resolved, as a renderer applies them.
    public func resolved(_ color: (DrawingColor) -> RGBAColor) -> ResolvedPictureEffects {
        var resolved = ResolvedPictureEffects()
        resolved.colorChange = colorChange.map { (color($0.from), color($0.to), $0.usesAlpha) }
            .map { ResolvedPictureEffects.ColorChange(from: $0.0, to: $0.1, usesAlpha: $0.2) }
        resolved.biLevelThreshold = biLevelThreshold
        resolved.isGreyscale = isGreyscale
        resolved.duotone = duotone.count == 2 ? duotone.map(color) : []
        if hueShift != 0 || saturationShift != 0 || luminanceShift != 0 {
            resolved.hsl = ColorMatrix.hueRotation(hueShift)
                .then(.saturation(1 + saturationShift))
                .then(luminanceShift >= 0 ? .linear(slope: 1 - luminanceShift, intercept: luminanceShift)
                    : .linear(slope: 1 + luminanceShift, intercept: 0))
        }
        if tintAmount != 0 {
            let turn = (tintHue / 360).truncatingRemainder(dividingBy: 1)
            resolved.tint = ResolvedPictureEffects.Tint(
                color: RGBAColor(hue: turn < 0 ? turn + 1 : turn, saturation: 1, luminance: 0.5),
                amount: min(max(tintAmount, -1), 1)
            )
        }
        if brightness != 0 || contrast != 0 { resolved.luminance = .brightnessContrast(brightness, contrast) }
        resolved.artistic = pendingArtistic.compactMap { effect in effect.look.map { ($0, effect.transparency) } }
            .map { ResolvedPictureEffects.Artistic(look: $0.0, transparency: $0.1) }
        return resolved
    }

    /// The effects as the children of an `a:blip`. Artistic effects are
    /// written only while they are still to be applied: a picture they were
    /// applied to is already what they make it, and the original it came
    /// from is a part only the XML it was read with can point to.
    public var xml: String { colorXML + artisticXML }

    /// The colour effects alone, each named in `colorElementNames`.
    public var colorXML: String {
        let alpha = opacity < 1 ? "<a:alphaModFix amt=\"\(Int((opacity * 100_000).rounded()))\"/>" : ""
        let change = colorChange?.xml ?? ""
        let biLevel = biLevelThreshold.map { "<a:biLevel thresh=\"\(Int(($0 * 100_000).rounded()))\"/>" } ?? ""
        let grey = isGreyscale ? "<a:grayscl/>" : ""
        let tones = duotone.count == 2 ? "<a:duotone>\(duotone.map(\.xml).joined())</a:duotone>" : ""
        let hsl = hueShift != 0 || saturationShift != 0 || luminanceShift != 0
            ? "<a:hsl hue=\"\(Int((hueShift * 60_000).rounded()))\" sat=\"\(Int((saturationShift * 100_000).rounded()))\""
                + " lum=\"\(Int((luminanceShift * 100_000).rounded()))\"/>" : ""
        let lum = brightness != 0 || contrast != 0
            ? "<a:lum bright=\"\(Int((brightness * 100_000).rounded()))\" contrast=\"\(Int((contrast * 100_000).rounded()))\"/>" : ""
        let tint = tintAmount != 0
            ? "<a:tint hue=\"\(Int((tintHue * 60_000).rounded()))\" amt=\"\(Int((tintAmount * 100_000).rounded()))\"/>" : ""
        return alpha + change + biLevel + grey + tones + hsl + lum + tint
    }

    /// The colour effects' element names, which `colorXML` writes in place of any the blip has.
    public static let colorElementNames: Set<String> = [
        "alphaModFix", "clrChange", "biLevel", "grayscl", "duotone", "hsl", "lum", "tint",
    ]

    /// The `a:extLst` carrying artistic effects still to be applied, or nothing.
    public var artisticXML: String {
        let effects = hasOriginalLayer ? [] : artistic
        guard !effects.isEmpty else { return "" }
        return "<a:extLst><a:ext uri=\"{BEBA8EAE-BF5A-486C-A8C5-ECC9F3942E4B}\">"
            + "<a14:imgProps xmlns:a14=\"\(ArtisticEffect.namespace)\"><a14:imgLayer>"
            + effects.map { "<a14:imgEffect>\($0.xml)</a14:imgEffect>" }.joined()
            + "</a14:imgLayer></a14:imgProps></a:ext></a:extLst>"
    }
}

/// The outline of a shape.
public struct LineStyle: Equatable, Hashable, Sendable {
    /// How the outline turns its corners: `a:round`, `a:bevel` or `a:miter`.
    public enum Join: Equatable, Hashable, Sendable {
        case round
        case bevel
        /// `lim`: how far a corner may reach, in thousandths of a percent of
        /// the line's width; `nil` when the file does not say.
        case miter(limit: Int?)

        public init?(element: XMLElement) {
            if element.firstChild(named: "round") != nil {
                self = .round
            } else if element.firstChild(named: "bevel") != nil {
                self = .bevel
            } else if let miter = element.firstChild(named: "miter") {
                self = .miter(limit: miter.attribute("lim").flatMap(Int.init))
            } else {
                return nil
            }
        }

        public var xml: String {
            switch self {
            case .round: "<a:round/>"
            case .bevel: "<a:bevel/>"
            case .miter(let limit): limit.map { "<a:miter lim=\"\($0)\"/>" } ?? "<a:miter/>"
            }
        }
    }

    /// `nil` when the line does not say, leaving it to the shape's style.
    public var fill: Fill?
    /// EMU; `nil` when the line does not say.
    public var width: Int?
    /// A preset dash name, such as `dash` or `sysDot`.
    public var dash: String?
    /// Arrowhead types at either end, such as `triangle`.
    public var head: String?
    public var tail: String?
    /// `cmpd`: `sng`, `dbl`, `thickThin`, `thinThick` or `tri`.
    public var compound: String?
    /// `cap`: `rnd`, `sq` or `flat`.
    public var cap: String?
    public var join: Join?

    public init(
        fill: Fill? = nil, width: Int? = nil, dash: String? = nil, head: String? = nil, tail: String? = nil,
        compound: String? = nil, cap: String? = nil, join: Join? = nil
    ) {
        self.fill = fill
        self.width = width
        self.dash = dash
        self.head = head
        self.tail = tail
        self.compound = compound
        self.cap = cap
        self.join = join
    }

    public init(element: XMLElement) {
        fill = Fill.parse(in: element) { _ in nil }
        width = element.attribute("w").flatMap(Int.init)
        dash = element.firstChild(named: "prstDash")?.attribute("val")
        head = element.firstChild(named: "headEnd")?.attribute("type").flatMap { $0 == "none" ? nil : $0 }
        tail = element.firstChild(named: "tailEnd")?.attribute("type").flatMap { $0 == "none" ? nil : $0 }
        compound = element.attribute("cmpd")
        cap = element.attribute("cap")
        join = Join(element: element)
    }

    /// The parallel strokes a compound line is drawn as, across its width
    /// from the outer side to the inner: each one's start and end as
    /// fractions of the width. A single line is one stroke, 0 to 1.
    public var compoundBands: [(start: Double, end: Double)] {
        // Strokes and gaps in turn, in proportion to one another.
        let parts: [Double] = switch compound {
        case "dbl": [1, 1, 1]
        case "thickThin": [2, 1, 1]
        case "thinThick": [1, 1, 2]
        case "tri": [1, 1, 2, 1, 1]
        default: [1]
        }
        let total = parts.reduce(0, +)
        var bands: [(start: Double, end: Double)] = []
        var position = 0.0
        for (index, part) in parts.enumerated() {
            if index.isMultiple(of: 2) { bands.append((position / total, (position + part) / total)) }
            position += part
        }
        return bands
    }

    /// Values this line leaves unsaid are taken from `base`.
    public func merged(over base: LineStyle?) -> LineStyle {
        guard let base else { return self }
        return LineStyle(
            fill: fill ?? base.fill, width: width ?? base.width, dash: dash ?? base.dash,
            head: head ?? base.head, tail: tail ?? base.tail,
            compound: compound ?? base.compound, cap: cap ?? base.cap, join: join ?? base.join
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

