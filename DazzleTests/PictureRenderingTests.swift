import CoreGraphics
import Foundation
import Testing
@testable import Dazzle

@Suite("Picture rendering regressions")
struct PictureRenderingTests {
    private func context(width: Int = 4) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    @Test("The warning picture reads and preserves its pale brightness/contrast adjustment")
    func warningLuminance() throws {
        let blip = try XMLLite.parse(Data("<blip><lum bright=\"70000\" contrast=\"-70000\"/></blip>".utf8))
        let effects = BlipEffects(blip: blip)
        #expect(effects.brightness == 0.7)
        #expect(effects.contrast == -0.7)
        #expect(effects.opacity == 1)
        #expect(effects.altersColor)
        let restored = BlipEffects(blip: try #require(XMLLite.fragment("<a:blip>\(effects.xml)</a:blip>", namespaces: OOXML.namespaces)))
        #expect(restored == effects)
        let canvas = try context()
        canvas.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        canvas.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        canvas.fill(CGRect(x: 2, y: 0, width: 1, height: 1))
        let image = try #require(canvas.makeImage())
        let altered = try #require(ImageCache.shared.recolored(image, key: "luminance-regression", isGreyscale: false,
                                                               duotone: [], brightness: effects.brightness, contrast: effects.contrast))
        let pixels = try #require(altered.dataProvider?.data as Data?)
        #expect(abs(Int(pixels[0]) - 205) <= 1)
        #expect(pixels[0] == pixels[1] && pixels[1] == pixels[2])
        #expect(pixels[4] == 255 && pixels[5] == 255 && pixels[6] == 255)
        #expect(pixels[11] == 128) // Colour adjustments leave alpha intact.
        #expect(pixels[8] > pixels[9]) // It has not been converted to grey.
        #expect(pixels[15] == 0) // Transparent pixels stay transparent.
        let plain = try #require(ImageCache.shared.recolored(image, key: "luminance-regression", isGreyscale: false, duotone: []))
        let unchanged = try #require(plain.dataProvider?.data as Data?)
        #expect(unchanged[0] == 0) // Distinct effects cannot collide in the cache.
    }
}
