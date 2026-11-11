#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// Drawing a preset pattern fill: its eight-by-eight cells, in its two
/// colours, repeated from the top left of the area.
enum PatternFill {
    /// Paints `pattern` over the context's clip, its first cell at the top
    /// left of `bounds`. The context's space runs downwards, as a slide's does.
    static func draw(
        _ pattern: Fill.Pattern, foreground: RGBAColor, background: RGBAColor, in bounds: CGRect, context: CGContext
    ) {
        guard let tile = tile(pattern, foreground: foreground, background: background) else { return }
        let size = CGFloat(Fill.Pattern.cellSize) * 8
        // Tiled drawing follows the current transform, so the pattern scales
        // and turns with the slide and the shape. (A CGPattern of our own
        // would be laid out in the context's base space instead, which in a
        // view on a Retina screen is not the slide's.) Images run upwards:
        // flipped, the tile's top row lies at the top of the area.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.minY + bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        // Cells are sharp-edged blocks, not a picture to smooth.
        context.interpolationQuality = .none
        context.draw(tile, in: CGRect(x: bounds.minX, y: bounds.maxY - size, width: size, height: size), byTiling: true)
        context.restoreGState()
    }

    /// The pattern's eight-by-eight pixels, the top row first.
    static func tile(_ pattern: Fill.Pattern, foreground: RGBAColor, background: RGBAColor) -> CGImage? {
        func premultiplied(_ color: RGBAColor) -> [UInt8] {
            let alpha = min(max(color.alpha, 0), 1)
            return [color.red, color.green, color.blue].map { UInt8((min(max($0, 0), 1) * alpha * 255).rounded()) }
                + [UInt8((alpha * 255).rounded())]
        }
        let ink = premultiplied(foreground), paper = premultiplied(background)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(8 * 8 * 4)
        for row in 0..<8 {
            for column in 0..<8 {
                pixels += pattern.isForeground(column: column, row: row) ? ink : paper
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
#endif
