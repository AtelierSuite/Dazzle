#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A DrawingML colour as the file states it: a base colour, which may be a
/// theme slot rather than a value, and the adjustments stacked on top of it.
///
/// Kept unresolved so a colour that says "Accent 1, 40% lighter" is still
/// that when it is written back, and follows the theme if the theme changes.
public struct DrawingColor: Equatable, Hashable, Sendable {
    public enum Base: Equatable, Hashable, Sendable {
        /// `RRGGBB`.
        case rgb(UInt32)
        /// A theme slot or a colour-map alias: `accent1`, `tx1`, `bg2`, `phClr`…
        case scheme(String)
        /// A system colour, with the value the authoring machine last saw.
        case system(String, lastColor: UInt32?)
    }

    public struct Transform: Equatable, Hashable, Sendable {
        public var name: String
        public var value: Int

        public init(name: String, value: Int) {
            self.name = name
            self.value = value
        }
    }

    public var base: Base
    public var transforms: [Transform] = []

    public static func rgb(_ value: UInt32) -> DrawingColor { DrawingColor(base: .rgb(value)) }
    public static func scheme(_ name: String) -> DrawingColor { DrawingColor(base: .scheme(name)) }
}

extension DrawingColor {
    /// Reads a colour element: `srgbClr`, `schemeClr`, `sysClr`, `prstClr`,
    /// `scrgbClr` or `hslClr`.
    public init?(element: XMLElement) {
        switch element.name {
        case "srgbClr":
            guard let value = element.attribute("val").flatMap({ UInt32($0, radix: 16) }) else { return nil }
            base = .rgb(value)
        case "schemeClr":
            guard let value = element.attribute("val") else { return nil }
            base = .scheme(value)
        case "sysClr":
            base = .system(
                element.attribute("val") ?? "windowText",
                lastColor: element.attribute("lastClr").flatMap { UInt32($0, radix: 16) }
            )
        case "prstClr":
            base = .rgb(Self.presetColors[element.attribute("val") ?? ""] ?? 0)
        case "scrgbClr":
            // Linear percentages; near enough to store as sRGB once.
            func channel(_ key: String) -> UInt32 {
                let linear = Double(element.attribute(key).flatMap(Int.init) ?? 0) / 100_000
                let encoded = linear <= 0.003_130_8 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
                return UInt32((min(max(encoded, 0), 1) * 255).rounded())
            }
            base = .rgb(channel("r") << 16 | channel("g") << 8 | channel("b"))
        case "hslClr":
            let hue = Double(element.attribute("hue").flatMap(Int.init) ?? 0) / 21_600_000
            let saturation = Double(element.attribute("sat").flatMap(Int.init) ?? 0) / 100_000
            let luminance = Double(element.attribute("lum").flatMap(Int.init) ?? 0) / 100_000
            base = .rgb(RGBAColor(hue: hue, saturation: saturation, luminance: luminance).hexValue)
        default:
            return nil
        }
        transforms = element.children.compactMap { child in
            child.attribute("val").flatMap(Int.init).map { Transform(name: child.name, value: $0) }
                ?? (["inv", "gray", "comp"].contains(child.name) ? Transform(name: child.name, value: 0) : nil)
        }
    }

    /// The first colour among an element's children, if any.
    public static func first(in parent: XMLElement?) -> DrawingColor? {
        parent?.children.lazy.compactMap(DrawingColor.init(element:)).first
    }

    /// The colour written back as DrawingML.
    public var xml: String {
        let inner = transforms.map { transform in
            ["inv", "gray", "comp"].contains(transform.name)
                ? "<a:\(transform.name)/>"
                : "<a:\(transform.name) val=\"\(transform.value)\"/>"
        }.joined()
        let open: String
        let close: String
        switch base {
        case .rgb(let value):
            open = "<a:srgbClr val=\"\(String(format: "%06X", value))\""
            close = "</a:srgbClr>"
        case .scheme(let name):
            open = "<a:schemeClr val=\"\(XMLLite.escape(name))\""
            close = "</a:schemeClr>"
        case .system(let name, let last):
            let lastAttribute = last.map { " lastClr=\"\(String(format: "%06X", $0))\"" } ?? ""
            open = "<a:sysClr val=\"\(XMLLite.escape(name))\"\(lastAttribute)"
            close = "</a:sysClr>"
        }
        return inner.isEmpty ? open + "/>" : open + ">" + inner + close
    }

    /// Theme slots a `prstClr` may name, resolved to the default Office
    /// theme (a preset name has no theme of its own to follow).
    private static let presetSchemeColors: [String: UInt32] = [
        "phClr": 0x000000, "dk1": 0x000000, "lt1": 0xFFFFFF, "dk2": 0x44546A,
        "lt2": 0xE7E6E6, "accent1": 0x4472C4, "accent2": 0xED7D31, "accent3": 0xA5A5A5,
        "accent4": 0xFFC000, "accent5": 0x5B9BD5, "accent6": 0x70AD47, "hlink": 0x0563C1,
        "folHlink": 0x954F72,
    ]

    /// Every named preset colour — the ECMA-376 `ST_PresetColorVal` list
    /// (the CSS extended keywords, plus the grey-spelled variants) — so a
    /// name like `coral` no longer falls back to black.
    private static let presetColors: [String: UInt32] = presetSchemeColors.merging([
        "aliceBlue": 0xF0F8FF, "antiqueWhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4,
        "azure": 0xF0FFFF, "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000,
        "blanchedAlmond": 0xFFEBCD, "blue": 0x0000FF, "blueViolet": 0x8A2BE2, "brown": 0xA52A2A,
        "burlyWood": 0xDEB887, "cadetBlue": 0x5F9EA0, "chartreuse": 0x7FFF00, "chocolate": 0xD2691E,
        "coral": 0xFF7F50, "cornflowerBlue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
        "cyan": 0x00FFFF, "darkBlue": 0x00008B, "darkCyan": 0x008B8B, "darkGoldenrod": 0xB8860B,
        "darkGray": 0xA9A9A9, "darkGreen": 0x006400, "darkKhaki": 0xBDB76B, "darkMagenta": 0x8B008B,
        "darkOliveGreen": 0x556B2F, "darkOrange": 0xFF8C00, "darkOrchid": 0x9932CC, "darkRed": 0x8B0000,
        "darkSalmon": 0xE9967A, "darkSeaGreen": 0x8FBC8F, "darkSlateBlue": 0x483D8B, "darkSlateGray": 0x2F4F4F,
        "darkTurquoise": 0x00CED1, "darkViolet": 0x9400D3, "deepPink": 0xFF1493, "deepSkyBlue": 0x00BFFF,
        "dimGray": 0x696969, "dodgerBlue": 0x1E90FF, "firebrick": 0xB22222, "floralWhite": 0xFFFAF0,
        "forestGreen": 0x228B22, "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC, "ghostWhite": 0xF8F8FF,
        "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080, "green": 0x008000,
        "greenYellow": 0xADFF2F, "honeydew": 0xF0FFF0, "hotPink": 0xFF69B4, "indianRed": 0xCD5C5C,
        "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA,
        "lavenderBlush": 0xFFF0F5, "lawnGreen": 0x7CFC00, "lemonChiffon": 0xFFFACD, "lightBlue": 0xADD8E6,
        "lightCoral": 0xF08080, "lightCyan": 0xE0FFFF, "lightGoldenrodYellow": 0xFAFAD2, "lightGray": 0xD3D3D3,
        "lightGreen": 0x90EE90, "lightPink": 0xFFB6C1, "lightSalmon": 0xFFA07A, "lightSeaGreen": 0x20B2AA,
        "lightSkyBlue": 0x87CEFA, "lightSlateGray": 0x778899, "lightSteelBlue": 0xB0C4DE, "lightYellow": 0xFFFFE0,
        "lime": 0x00FF00, "limeGreen": 0x32CD32, "linen": 0xFAF0E6, "magenta": 0xFF00FF,
        "maroon": 0x800000, "mediumAquamarine": 0x66CDAA, "mediumBlue": 0x0000CD, "mediumOrchid": 0xBA55D3,
        "mediumPurple": 0x9370DB, "mediumSeaGreen": 0x3CB371, "mediumSlateBlue": 0x7B68EE, "mediumSpringGreen": 0x00FA9A,
        "mediumTurquoise": 0x48D1CC, "mediumVioletRed": 0xC71585, "midnightBlue": 0x191970, "mintCream": 0xF5FFFA,
        "mistyRose": 0xFFE4E1, "moccasin": 0xFFE4B5, "navajoWhite": 0xFFDEAD, "navy": 0x000080,
        "oldLace": 0xFDF5E6, "olive": 0x808000, "oliveDrab": 0x6B8E23, "orange": 0xFFA500,
        "orangeRed": 0xFF4500, "orchid": 0xDA70D6, "paleGoldenrod": 0xEEE8AA, "paleGreen": 0x98FB98,
        "paleTurquoise": 0xAFEEEE, "paleVioletRed": 0xDB7093, "papayaWhip": 0xFFEFD5, "peachPuff": 0xFFDAB9,
        "peru": 0xCD853F, "pink": 0xFFC0CB, "plum": 0xDDA0DD, "powderBlue": 0xB0E0E6,
        "purple": 0x800080, "red": 0xFF0000, "rosyBrown": 0xBC8F8F, "royalBlue": 0x4169E1,
        "saddleBrown": 0x8B4513, "salmon": 0xFA8072, "sandyBrown": 0xF4A460, "seaGreen": 0x2E8B57,
        "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0, "skyBlue": 0x87CEEB,
        "slateBlue": 0x6A5ACD, "slateGray": 0x708090, "snow": 0xFFFAFA, "springGreen": 0x00FF7F,
        "steelBlue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8,
        "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3,
        "white": 0xFFFFFF, "whiteSmoke": 0xF5F5F5, "yellow": 0xFFFF00, "yellowGreen": 0x9ACD32,
        "grey": 0x808080, "darkGrey": 0xA9A9A9, "lightGrey": 0xD3D3D3, "dimGrey": 0x696969,
        "slateGrey": 0x708090, "darkSlateGrey": 0x2F4F4F, "lightSlateGrey": 0x778899, "lightSteelGrey": 0xB0C4DE,
    ]) { _, new in new }
}

/// A colour with everything resolved, ready to draw with.
public struct RGBAColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double = 1

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    public init(hue: Double, saturation: Double, luminance: Double, alpha: Double = 1) {
        func component(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        guard saturation > 0 else {
            self.init(red: luminance, green: luminance, blue: luminance, alpha: alpha)
            return
        }
        let q = luminance < 0.5 ? luminance * (1 + saturation) : luminance + saturation - luminance * saturation
        let p = 2 * luminance - q
        self.init(
            red: component(p, q, hue + 1 / 3), green: component(p, q, hue),
            blue: component(p, q, hue - 1 / 3), alpha: alpha
        )
    }

    public var hexValue: UInt32 {
        func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    #if canImport(CoreGraphics)
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
    #endif

    /// Hue, saturation and luminance, each 0…1.
    public var hsl: (hue: Double, saturation: Double, luminance: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let luminance = (maximum + minimum) / 2
        guard maximum != minimum else { return (0, 0, luminance) }
        let delta = maximum - minimum
        let saturation = luminance > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
        var hue: Double
        switch maximum {
        case red: hue = (green - blue) / delta + (green < blue ? 6 : 0)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue /= 6
        return (hue, saturation, luminance)
    }

    /// Applies `change` to each channel in linear light.
    private func linearMix(_ change: (Double) -> Double) -> RGBAColor {
        func toLinear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func toEncoded(_ value: Double) -> Double {
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.003_130_8 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return RGBAColor(
            red: toEncoded(change(toLinear(red))), green: toEncoded(change(toLinear(green))),
            blue: toEncoded(change(toLinear(blue))), alpha: alpha
        )
    }

    /// Applies one DrawingML colour transform. Values are in thousandths of
    /// a percent, as the file stores them.
    public func applying(_ transform: DrawingColor.Transform) -> RGBAColor {
        let amount = Double(transform.value) / 100_000
        var result = self
        switch transform.name {
        case "alpha": result.alpha = amount
        case "alphaMod": result.alpha *= amount
        case "alphaOff": result.alpha = min(max(alpha + amount, 0), 1)
        case "lumMod", "lumOff", "satMod", "satOff", "hueMod", "hueOff":
            var (hue, saturation, luminance) = hsl
            switch transform.name {
            case "lumMod": luminance *= amount
            case "lumOff": luminance += amount
            case "satMod": saturation *= amount
            case "satOff": saturation += amount
            case "hueMod": hue *= amount
            default: hue += Double(transform.value) / 21_600_000
            }
            hue = hue.truncatingRemainder(dividingBy: 1)
            result = RGBAColor(
                hue: hue < 0 ? hue + 1 : hue, saturation: min(max(saturation, 0), 1),
                luminance: min(max(luminance, 0), 1), alpha: alpha
            )
        case "tint":
            // "A 10% tint is 10% of the input colour combined with 90% white",
            // mixed in linear light as Office does: black at a 75% tint is
            // #898989, not the #404040 mixing the encoded values would give.
            result = linearMix { $0 * amount + (1 - amount) }
        case "shade":
            result = linearMix { $0 * amount }
        case "inv":
            result = RGBAColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: alpha)
        case "gray":
            let grey = 0.299 * red + 0.587 * green + 0.114 * blue
            result = RGBAColor(red: grey, green: grey, blue: grey, alpha: alpha)
        case "comp":
            let (hue, saturation, luminance) = hsl
            result = RGBAColor(
                hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: saturation,
                luminance: luminance, alpha: alpha
            )
        default:
            break
        }
        return result
    }
}
