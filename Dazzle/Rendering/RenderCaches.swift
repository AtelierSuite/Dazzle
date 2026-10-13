import CoreText
import Foundation
import ImageIO
import UIKit

/// Decoded pictures, kept so a slide is not decoded again on every redraw.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    // NSCache is thread-safe, which is what makes this class safe to share.
    private let cache = NSCache<NSString, CGImage>()

    private init() {
        cache.countLimit = 120
    }

    func image(for data: Data, path: String) -> CGImage? {
        let key = "\(path)#\(data.count)#\(data.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Pictures are drawn no larger than a slide on a big display, so
        // there is no use decoding a 50-megapixel photo at full size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 3_000,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// A picture in grey, or mapped from dark to light onto two colours.
    func recolored(_ image: CGImage, key: String, isGreyscale: Bool, duotone: [RGBAColor],
                   brightness: Double = 0, contrast: Double = 0) -> CGImage? {
        let cacheKey = "recolored#\(key)#\(isGreyscale)#\(duotone)#\(brightness)#\(contrast)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let dark = duotone.first
        let light = duotone.last
        // Office centers contrast on 128, with half the brightness shift
        // before contrast and half after it. Preserve alpha independently.
        let c = min(max(contrast, -1), 1)
        let slope = c >= 0 ? 128 / (128 - 127 * c) : (128 + 127 * c) / 128
        let shift = min(max(brightness, -1), 1) * 255 / 2
        func adjusted(_ channel: Double) -> Double {
            ((channel * 255 + shift - 128) * slope + 128 + shift) / 255
        }
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0 else { continue }
            // Channels are premultiplied; take the colour out of the alpha first.
            let luminance = (0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1])
                + 0.114 * Double(pixels[offset + 2])) / 255 / alpha
            var red = isGreyscale ? luminance : Double(pixels[offset]) / 255 / alpha
            var green = isGreyscale ? luminance : Double(pixels[offset + 1]) / 255 / alpha
            var blue = isGreyscale ? luminance : Double(pixels[offset + 2]) / 255 / alpha
            if let dark, let light, !isGreyscale {
                red = dark.red + (light.red - dark.red) * luminance
                green = dark.green + (light.green - dark.green) * luminance
                blue = dark.blue + (light.blue - dark.blue) * luminance
            }
            red = adjusted(red)
            green = adjusted(green)
            blue = adjusted(blue)
            pixels[offset] = UInt8(min(max(red, 0), 1) * alpha * 255)
            pixels[offset + 1] = UInt8(min(max(green, 0), 1) * alpha * 255)
            pixels[offset + 2] = UInt8(min(max(blue, 0), 1) * alpha * 255)
        }
        guard let recolored = context.makeImage() else { return image }
        cache.setObject(recolored, forKey: cacheKey)
        return recolored
    }
}

/// Fonts by family, size and style. A font the presentation carries comes
/// first; families iOS does not have — Calibri, Aptos and the other Office
/// faces — are drawn in the closest one it does, and any other in the kind
/// of face its name suggests.
final class FontResolver: @unchecked Sendable {
    static let shared = FontResolver()

    private let cache = NSCache<NSString, CTFont>()

    func font(family: String?, size: CGFloat, bold: Bool, italic: Bool, embedded: EmbeddedFonts = .none) -> CTFont {
        if let family, let descriptor = embedded.descriptor(family: family, bold: bold, italic: italic) {
            let key = "\(embedded.id)|\(family)|\(size)|\(bold)|\(italic)" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            cache.setObject(font, forKey: key)
            return font
        }

        let key = "\(family ?? "")|\(size)|\(bold)|\(italic)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var (font, isWeighted) = base(family: family, size: size)
        var traits: CTFontSymbolicTraits = []
        // A heavy face iOS does not have is closest in the bold of the substitute.
        let lowered = family?.lowercased() ?? ""
        let isHeavyFamily = lowered.contains("black") || lowered.contains("heavy")
        if bold || (isHeavyFamily && !isWeighted && (CTFontCopyFamilyName(font) as String).lowercased() != lowered) {
            traits.insert(.traitBold)
        }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty {
            font = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) ?? font
        }
        cache.setObject(font, forKey: key)
        return font
    }

    /// The face for `family`, and whether it already has the weight the name asks for.
    private func base(family: String?, size: CGFloat) -> (font: CTFont, isWeighted: Bool) {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard let family = family?.trimmed, !family.isEmpty else { return (system, false) }
        let lowered = family.lowercased()
        if let substitute = Self.substitutes.first(where: { lowered.hasPrefix($0.key) })?.value {
            return (substitute.isEmpty ? system : CTFontCreateWithName(substitute as CFString, size, nil), false)
        }
        let candidate = CTFontCreateWithName(family as CFString, size, nil)
        let found = (CTFontCopyFamilyName(candidate) as String).lowercased()
        // CoreText answers an unknown name with some other font rather than
        // nothing; only keep what came back if it is what was asked for.
        if found == lowered || (CTFontCopyFullName(candidate) as String).lowercased() == lowered {
            return (candidate, false)
        }
        return (Self.fallback(for: lowered, size: size), true)
    }

    /// A face for a family iOS doesn't have, going by its name: serifs in
    /// Times, fixed widths in the system's monospaced face, Japanese in
    /// Hiragino, and the rest in the system font, narrowed for a narrow
    /// family, each at the weight the name gives.
    static func fallback(for family: String, size: CGFloat) -> CTFont {
        let weight = weight(in: family)
        func named(_ name: String) -> CTFont {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            guard weight >= .semibold else { return font }
            return CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
        }
        switch category(of: family) {
        case .monospaced: return UIFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
        case .serif: return named("Times New Roman")
        case .mincho: return named("Hiragino Mincho ProN")
        case .gothic: return named("Hiragino Sans")
        case .sansSerif:
            let narrow = ["narrow", "condensed", "compressed", "compact"].contains { family.contains($0) }
            return UIFont.systemFont(ofSize: size, weight: weight, width: narrow ? .condensed : .standard) as CTFont
        }
    }

    enum Category: Equatable {
        case sansSerif, serif, monospaced, mincho, gothic
    }

    static func category(of family: String) -> Category {
        let name = family.lowercased()
        func mentions(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
        if mentions(["mono", "code", "courier", "consol", "typewriter", "terminal", "fixed", "monaco", "andale", "jetbrains"]) {
            return .monospaced
        }
        if mentions(["mincho", "明朝", "みんちょう"]) { return .mincho }
        if mentions(["ゴシック", "gothic"]) && name.unicodeScalars.contains(where: { $0.value > 0x2E80 }) { return .gothic }
        if mentions(["sans", "grotesk", "grotesque", "gothic"]) { return .sansSerif }
        if mentions(Self.serifWords) { return .serif }
        return .sansSerif
    }

    /// Words naming serif families, or common ones by name.
    private static let serifWords = [
        "serif", "times", "georgia", "garamond", "baskerville", "caslon", "bodoni", "didot", "minion", "playfair",
        "merriweather", "lora", "antiqua", "slab", "palatino", "charter", "crimson", "schoolbook", "goudy",
        "perpetua", "rockwell", "bookman", "clarendon", "cochin", "hoefler", "iowan", "literata", "spectral",
        "cormorant", "cardo", "sabon", "janson", "plantin", "utopia", "tiempos", "domine", "alegreya",
    ]

    /// The weight words in a family name such as `Open Sans Semibold` give.
    static func weight(in family: String) -> UIFont.Weight {
        let name = family.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let weights: [(String, UIFont.Weight)] = [
            ("hairline", .ultraLight), ("ultralight", .ultraLight), ("extralight", .ultraLight), ("thin", .thin),
            ("semibold", .semibold), ("demibold", .semibold), ("extrabold", .heavy), ("ultrabold", .heavy),
            ("light", .light), ("medium", .medium), ("heavy", .heavy), ("black", .black), ("bold", .bold),
        ]
        return weights.first { name.contains($0.0) }?.1 ?? .regular
    }

    /// Office typefaces mapped to what iOS ships. Empty means the system font.
    private static let substitutes: [String: String] = [
        "calibri": "", "aptos": "", "segoe": "", "arial nova": "", "tahoma": "", "candara": "",
        "corbel": "", "franklin gothic": "", "century gothic": "Avenir Next", "gill sans mt": "Gill Sans",
        "cambria": "Georgia", "constantia": "Georgia", "book antiqua": "Palatino", "garamond": "Baskerville",
        "consolas": "Menlo", "lucida console": "Menlo", "courier": "Courier New",
        "meiryo": "Hiragino Sans", "yu gothic": "Hiragino Sans", "ms gothic": "Hiragino Sans",
        "ms pgothic": "Hiragino Sans", "游ゴシック": "Hiragino Sans", "メイリオ": "Hiragino Sans",
        "ms mincho": "Hiragino Mincho ProN", "yu mincho": "Hiragino Mincho ProN",
    ]
}
