#if canImport(CoreImage)
import CoreImage
import Foundation

/// Draws a picture's artistic effects with Core Image. The web app draws
/// the same looks with SVG filters (`effects()` in Web/app/slide.js).
enum ArtisticRenderer {
    /// Filters work on sRGB values, as Office's corrections and SVG's do,
    /// rather than in linear light.
    private static let context: CIContext = {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
    }()

    static func apply(_ effects: [ResolvedPictureEffects.Artistic], to image: CGImage) -> CGImage? {
        let original = CIImage(cgImage: image)
        let extent = original.extent
        let side = Double(max(extent.width, extent.height))
        var picture = original
        for effect in effects {
            guard let looked = look(effect.look, of: picture, side: side)?.cropped(to: extent) else { continue }
            if effect.transparency > 0 {
                // `trans`: the picture as it was showing through the effect.
                picture = filter("CIDissolveTransition", [
                    kCIInputImageKey: looked, kCIInputTargetImageKey: picture, kCIInputTimeKey: effect.transparency,
                ]) ?? looked
            } else {
                picture = looked
            }
        }
        return context.createCGImage(picture.cropped(to: extent), from: extent)
    }

    private static func filter(_ name: String, _ parameters: [String: Any]) -> CIImage? {
        CIFilter(name: name, parameters: parameters)?.outputImage
    }

    private static func blurred(_ image: CIImage, sigma: Double) -> CIImage {
        guard sigma > 0.1 else { return image }
        return image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: image.extent)
    }

    private static func matrix(_ matrix: ColorMatrix, _ image: CIImage) -> CIImage? {
        let v = matrix.values.map { CGFloat($0) }
        let mixed = filter("CIColorMatrix", [
            kCIInputImageKey: image,
            "inputRVector": CIVector(x: v[0], y: v[1], z: v[2], w: v[3]),
            "inputGVector": CIVector(x: v[5], y: v[6], z: v[7], w: v[8]),
            "inputBVector": CIVector(x: v[10], y: v[11], z: v[12], w: v[13]),
            "inputAVector": CIVector(x: v[15], y: v[16], z: v[17], w: v[18]),
            "inputBiasVector": CIVector(x: v[4], y: v[9], z: v[14], w: v[19]),
        ])
        return mixed.flatMap { filter("CIColorClamp", [kCIInputImageKey: $0]) }
    }

    /// Grey noise centred on mid-grey, as strong as `strength`, in grains
    /// about a 600th of the picture across.
    private static func noise(over extent: CGRect, side: Double, strength: Double) -> CIImage? {
        guard let random = filter("CIRandomGenerator", [:]) else { return nil }
        let grain = max(side / 600, 1)
        let coarse = random.transformed(by: CGAffineTransform(scaleX: grain, y: grain))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
        let s = CGFloat(strength)
        return filter("CIColorMatrix", [
            kCIInputImageKey: coarse,
            "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: s, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.5 - s / 2, y: 0.5 - s / 2, z: 0.5 - s / 2, w: 1),
        ])
    }

    private static func look(_ look: ArtisticEffect.Look, of image: CIImage, side: Double) -> CIImage? {
        switch look {
        case .matrix(let colors):
            return matrix(colors, image)
        case .blur(let sigma):
            return blurred(image, sigma: sigma * side)
        case .sharpen(let amount):
            return filter("CIUnsharpMask", [
                kCIInputImageKey: image.clampedToExtent(), kCIInputRadiusKey: max(side * 0.002, 1),
                kCIInputIntensityKey: amount * 1.5,
            ])
        case .sketch(let width, let inverted):
            // Grey, dodged by its own blurred negative: only edges stay dark.
            guard let grey = matrix(.saturation(0), image),
                  let negative = filter("CIColorInvert", [kCIInputImageKey: grey]),
                  let sketch = filter("CIColorDodgeBlendMode", [
                    kCIInputImageKey: blurred(negative, sigma: width * side), kCIInputBackgroundImageKey: grey,
                  ]) else { return nil }
            return inverted ? filter("CIColorInvert", [kCIInputImageKey: sketch]) : sketch
        case .edges(let smoothness):
            return filter("CIEdges", [kCIInputImageKey: blurred(image, sigma: smoothness * 0.003 * side), kCIInputIntensityKey: 4])
        case .paint(let levels, let softness):
            let soft = blurred(image, sigma: softness * 0.004 * side)
            let smooth = filter("CIMedianFilter", [kCIInputImageKey: soft]) ?? soft
            return filter("CIColorPosterize", [kCIInputImageKey: smooth, "inputLevels": max(levels, 2)])
        case .grain(let strength):
            guard let grain = noise(over: image.extent, side: side, strength: strength) else { return nil }
            return filter("CIOverlayBlendMode", [kCIInputImageKey: grain, kCIInputBackgroundImageKey: image])
        case .distort(let scale):
            guard let grain = noise(over: image.extent, side: side * 10, strength: 1) else { return nil }
            return filter("CIDisplacementDistortion", [
                kCIInputImageKey: image.clampedToExtent(), "inputDisplacementImage": blurred(grain, sigma: side * 0.004),
                kCIInputScaleKey: scale * side,
            ])
        case .glow(let strength):
            return filter("CIBloom", [
                kCIInputImageKey: image.clampedToExtent(), kCIInputRadiusKey: side * 0.01, kCIInputIntensityKey: strength * 1.5,
            ])
        }
    }
}
#endif
