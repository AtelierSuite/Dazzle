import Foundation

/// One of a picture's `a14:imgEffect`s: an artistic effect, such as
/// `artisticPencilSketch`, or a picture correction, such as `saturation`.
///
/// Kept as the file wrote it, so it is written back the same, with what it
/// looks like worked out in `look`.
public struct ArtisticEffect: Equatable, Hashable, Sendable {
    public static let namespace = "http://schemas.microsoft.com/office/drawing/2010/main"

    /// The element's name without its prefix, such as `artisticBlur`.
    public var name: String
    public var attributes: [String: String]

    public init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    public init(element: XMLElement) {
        self.init(name: element.name, attributes: element.attributes)
    }

    /// `visible="0"` keeps an effect in the file without applying it.
    public var isVisible: Bool { !["0", "false"].contains(attributes["visible"] ?? "") }

    /// `trans`: how much of the picture as it was shows through, 0…1.
    public var transparency: Double { min(max(Double(value("trans", 0)) / 100_000, 0), 1) }

    /// An attribute as a number, or `fallback`, the schema's default.
    public func value(_ key: String, _ fallback: Int) -> Int {
        attributes[key].flatMap(Int.init) ?? fallback
    }

    var xml: String {
        let attributes = attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(XMLLite.escape($0.value))\"" }.joined()
        return "<a14:\(name)\(attributes)/>"
    }

    /// What an effect does to a picture, in terms both renderers can draw.
    /// Sizes are fractions of the picture's longer side.
    public enum Look: Equatable, Hashable, Sendable {
        /// A colour adjustment, exactly as Office makes it.
        case matrix(ColorMatrix)
        /// A Gaussian blur of this standard deviation.
        case blur(Double)
        /// Edges strengthened, 0…1.
        case sharpen(Double)
        /// A pencil drawing: grey strokes from the picture's edges, as wide
        /// as `width`; `inverted` draws light strokes on dark, like chalk.
        case sketch(width: Double, inverted: Bool)
        /// Edges glowing on black, softened by `smoothness`.
        case edges(smoothness: Double)
        /// Flat areas of colour: softened, then cut down to `levels` per channel.
        case paint(levels: Int, softness: Double)
        /// Grain or texture over the picture, of this strength, 0…1.
        case grain(Double)
        /// The picture seen through rippled glass, as far as `scale`.
        case distort(Double)
        /// Highlights spread into a soft glow of this strength, 0…1.
        case glow(Double)
    }

    /// What the effect looks like; `nil` for one that cannot be drawn,
    /// such as `backgroundRemoval`. Only the colour corrections — brightness
    /// and contrast, saturation and colour temperature — and `artisticBlur`
    /// are Office's own; the other artistic effects are approximations,
    /// close in character rather than to the pixel.
    public var look: Look? {
        func scaled(_ key: String, _ fallback: Int, of range: Double) -> Double {
            min(max(Double(value(key, fallback)) / range, 0), 1)
        }
        switch name {
        case "brightnessContrast":
            return .matrix(.brightnessContrast(Double(value("bright", 0)) / 100_000, Double(value("contrast", 0)) / 100_000))
        case "saturation":
            return .matrix(.saturation(Double(value("sat", 100_000)) / 100_000))
        case "colorTemperature":
            return .matrix(.temperature(Double(value("colorTemp", 6_500))))
        case "sharpenSoften":
            let amount = min(max(Double(value("amount", 0)) / 100_000, -1), 1)
            return amount < 0 ? .blur(-amount * 0.004) : .sharpen(amount)
        case "artisticBlur":
            return .blur(scaled("radius", 10, of: 100) * 0.03)
        case "artisticPencilSketch":
            return .sketch(width: 0.004 + scaled("pressure", 22, of: 100) * 0.012, inverted: false)
        case "artisticPencilGrayscale", "artisticLineDrawing":
            return .sketch(width: 0.004 + scaled("pencilSize", name == "artisticLineDrawing" ? 0 : 27, of: 100) * 0.012, inverted: false)
        case "artisticCrisscrossEtching":
            return .sketch(width: 0.004 + scaled("pressure", 30, of: 100) * 0.012, inverted: false)
        case "artisticPhotocopy":
            return .sketch(width: 0.004 + scaled("detail", 3, of: 10) * 0.012, inverted: false)
        case "artisticChalkSketch":
            return .sketch(width: 0.004 + scaled("pressure", 0, of: 4) * 0.012, inverted: true)
        case "artisticGlowEdges":
            return .edges(smoothness: scaled("smoothness", 3, of: 10))
        case "artisticCutout":
            return .paint(levels: 2 + value("numberOfShades", 2), softness: 0.3)
        case "artisticWatercolorSponge", "artisticPaintBrush":
            return .paint(levels: 6, softness: 0.2 + scaled("brushSize", 2, of: 10) * 0.8)
        case "artisticPaintStrokes":
            return .paint(levels: 5, softness: 0.2 + scaled("intensity", 5, of: 10) * 0.6)
        case "artisticPastelsSmooth":
            return .paint(levels: 8, softness: 0.3 + scaled("scaling", 34, of: 100) * 0.7)
        case "artisticMarker":
            return .paint(levels: 4, softness: 0.2 + scaled("size", 97, of: 100) * 0.5)
        case "artisticFilmGrain":
            return .grain(0.05 + scaled("grainSize", 40, of: 100) * 0.25)
        case "artisticCement", "artisticTexturizer":
            return .grain(0.1 + scaled(name == "artisticCement" ? "crackSpacing" : "scaling", name == "artisticCement" ? 24 : 34, of: 100) * 0.2)
        case "artisticLightScreen":
            return .grain(0.1 + scaled("gridSize", 4, of: 10) * 0.2)
        case "artisticGlass", "artisticMosiaicBubbles":
            return .distort(0.01 + scaled(name == "artisticGlass" ? "scaling" : "pressure", name == "artisticGlass" ? 34 : 14, of: 100) * 0.04)
        case "artisticGlowDiffused":
            return .glow(scaled("intensity", 5, of: 10))
        case "artisticPlasticWrap":
            return .glow(0.3 + scaled("smoothness", 5, of: 10) * 0.5)
        default:
            return nil
        }
    }
}

/// A colour transform in the shape of SVG's `feColorMatrix`: four rows, for
/// red, green, blue and alpha, each of four channel weights and an offset,
/// on channels 0…1. Results are clamped to 0…1.
public struct ColorMatrix: Equatable, Hashable, Sendable {
    public var values: [Double]

    public init(_ values: [Double]) {
        precondition(values.count == 20)
        self.values = values
    }

    public static let identity = ColorMatrix([1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0])

    /// Each colour channel scaled by `slope` and moved by `intercept`.
    public static func linear(slope: Double, intercept: Double) -> ColorMatrix {
        gains(slope, slope, slope, offset: intercept)
    }

    public static func gains(_ red: Double, _ green: Double, _ blue: Double, offset: Double = 0) -> ColorMatrix {
        ColorMatrix([red, 0, 0, 0, offset, 0, green, 0, 0, offset, 0, 0, blue, 0, offset, 0, 0, 0, 1, 0])
    }

    /// SVG's `saturate`: 0 is grey, 1 unchanged, more is more vivid.
    public static func saturation(_ amount: Double) -> ColorMatrix {
        let s = max(amount, 0)
        return ColorMatrix([
            0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0,
            0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
            0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
            0, 0, 0, 1, 0,
        ])
    }

    /// SVG's `hueRotate`, by degrees.
    public static func hueRotation(_ degrees: Double) -> ColorMatrix {
        let radians = degrees * .pi / 180
        let c = cos(radians), s = sin(radians)
        return ColorMatrix([
            0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
            0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
            0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
            0, 0, 0, 1, 0,
        ])
    }

    /// Office's brightness and contrast, each −1…1: contrast centred on
    /// mid-grey, with half the brightness before it and half after.
    public static func brightnessContrast(_ brightness: Double, _ contrast: Double) -> ColorMatrix {
        let c = min(max(contrast, -1), 1)
        let slope = c >= 0 ? 128 / (128 - 127 * c) : (128 + 127 * c) / 128
        let shift = min(max(brightness, -1), 1) / 2
        return linear(slope: slope, intercept: shift * slope + 0.5 - 0.5 * slope + shift)
    }

    /// A picture shot in light of `kelvin` and balanced for daylight (6500 K):
    /// higher is warmer, lower cooler, as Office's colour temperature runs.
    /// Its brightness stays as it was.
    public static func temperature(_ kelvin: Double) -> ColorMatrix {
        // Tanner Helland's fit of the black-body colours, as 0…1.
        func light(_ kelvin: Double) -> (Double, Double, Double) {
            let t = min(max(kelvin, 1_000), 40_000) / 100
            let red = t <= 66 ? 255 : 329.698_727_446 * pow(t - 60, -0.133_204_759_2)
            let green = t <= 66 ? 99.470_802_586_1 * log(t) - 161.119_568_166_1 : 288.122_169_528_3 * pow(t - 60, -0.075_514_849_2)
            let blue = t >= 66 ? 255 : (t <= 19 ? 0 : 138.517_731_223_1 * log(t - 10) - 305.044_792_730_7)
            return (min(max(red, 12), 255) / 255, min(max(green, 12), 255) / 255, min(max(blue, 12), 255) / 255)
        }
        let daylight = light(6_500)
        let shot = light(kelvin)
        var gains = (daylight.0 / shot.0, daylight.1 / shot.1, daylight.2 / shot.2)
        let weight = 0.299 * gains.0 + 0.587 * gains.1 + 0.114 * gains.2
        gains = (min(gains.0 / weight, 3), min(gains.1 / weight, 3), min(gains.2 / weight, 3))
        return .gains(gains.0, gains.1, gains.2)
    }

    /// This transform, then `next`.
    public func then(_ next: ColorMatrix) -> ColorMatrix {
        var result = [Double](repeating: 0, count: 20)
        for row in 0..<4 {
            for column in 0..<5 {
                var sum = column == 4 ? next.values[row * 5 + 4] : 0
                for k in 0..<4 { sum += next.values[row * 5 + k] * values[k * 5 + column] }
                result[row * 5 + column] = sum
            }
        }
        return ColorMatrix(result)
    }

    /// The transform applied to a colour of unpremultiplied channels.
    public func apply(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> (Double, Double, Double, Double) {
        let input = [red, green, blue, alpha]
        func row(_ index: Int) -> Double {
            var sum = values[index * 5 + 4]
            for k in 0..<4 { sum += values[index * 5 + k] * input[k] }
            return min(max(sum, 0), 1)
        }
        return (row(0), row(1), row(2), row(3))
    }
}

/// A picture's effects with their colours resolved, ready to draw. Both the
/// Apple renderer and the web app apply them in this order: artistic
/// effects (on the original picture, as Office did to make its blip), the
/// colour change, then black and white, grey or duotone, hue, saturation and
/// luminance, tint, and brightness and contrast.
public struct ResolvedPictureEffects: Equatable, Hashable, Sendable, CustomStringConvertible {
    public struct ColorChange: Equatable, Hashable, Sendable {
        public var from: RGBAColor
        public var to: RGBAColor
        public var usesAlpha: Bool
    }

    public struct Tint: Equatable, Hashable, Sendable {
        /// The hue at full saturation and mid luminance.
        public var color: RGBAColor
        /// Towards it when positive; towards grey when negative.
        public var amount: Double
    }

    public struct Artistic: Equatable, Hashable, Sendable {
        public var look: ArtisticEffect.Look
        public var transparency: Double
    }

    public var artistic: [Artistic] = []
    public var colorChange: ColorChange?
    public var biLevelThreshold: Double?
    public var isGreyscale = false
    public var duotone: [RGBAColor] = []
    public var hsl: ColorMatrix?
    public var tint: Tint?
    public var luminance: ColorMatrix?

    public init() {
        // Nothing to change.
    }

    public var isEmpty: Bool { self == ResolvedPictureEffects() }

    /// Stable within a run, and distinct for distinct effects: a cache key.
    public var description: String {
        "\(artistic)|\(String(describing: colorChange))|\(String(describing: biLevelThreshold))|\(isGreyscale)|\(duotone)"
            + "|\(String(describing: hsl?.values))|\(String(describing: tint))|\(String(describing: luminance?.values))"
    }

    /// The colour effects applied to one pixel's unpremultiplied channels.
    public func apply(_ pixel: (Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
        var (red, green, blue, alpha) = pixel
        if let change = colorChange {
            var distance = abs(red - change.from.red) + abs(green - change.from.green) + abs(blue - change.from.blue)
            if change.usesAlpha { distance += abs(alpha - change.from.alpha) }
            if distance <= BlipEffects.ColorChange.tolerance {
                (red, green, blue, alpha) = (change.to.red, change.to.green, change.to.blue, alpha * change.to.alpha)
            }
        }
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        if let threshold = biLevelThreshold {
            let value: Double = luminance >= threshold ? 1 : 0
            (red, green, blue) = (value, value, value)
        } else if isGreyscale {
            (red, green, blue) = (luminance, luminance, luminance)
        } else if duotone.count == 2 {
            let (dark, light) = (duotone[0], duotone[1])
            red = dark.red + (light.red - dark.red) * luminance
            green = dark.green + (light.green - dark.green) * luminance
            blue = dark.blue + (light.blue - dark.blue) * luminance
        }
        if let hsl { (red, green, blue, alpha) = hsl.apply(red, green, blue, alpha) }
        if let tint {
            let grey = 0.299 * red + 0.587 * green + 0.114 * blue
            // Grey mapped from black through the hue to white, or grey itself.
            func toned(_ hue: Double) -> Double {
                tint.amount < 0 ? grey : (grey < 0.5 ? hue * grey * 2 : hue + (1 - hue) * (grey * 2 - 1))
            }
            let amount = abs(tint.amount)
            red += (toned(tint.color.red) - red) * amount
            green += (toned(tint.color.green) - green) * amount
            blue += (toned(tint.color.blue) - blue) * amount
        }
        if let luminance = self.luminance { (red, green, blue, alpha) = luminance.apply(red, green, blue, alpha) }
        return (min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1), alpha)
    }
}
