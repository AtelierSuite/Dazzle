import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

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

    @Test("Hidden reference artwork stays stored but is neither drawn nor linked") @MainActor
    func hiddenArtwork() throws {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <p:sp><p:nvSpPr><p:cNvPr id="23" name="Reference" hidden="1"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="127000" cy="127000"/></a:xfrm>
            <a:prstGeom prst="rect"/><a:solidFill><a:srgbClr val="000000"/></a:solidFill></p:spPr></p:sp>
            </p:spTree>
            """.utf8))
        let shape = try #require(ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                                           parts: [:], capturesSource: true).shapes(in: root).first)
        #expect(shape.isHidden)
        var presentation = Presentation.blank
        var hidden = shape
        hidden.source = nil // Also preserved when reconstructed, not just when source XML is retained.
        hidden.link = .url("https://example.com")
        presentation.slides[0].shapes = [hidden]
        presentation.slides[0].isModified = true
        let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(read.slides[0].shapes[0].isHidden)
        let state = EditorState()
        state.selectAllShapes(in: read)
        #expect(state.selectedShapeIDs.isEmpty)
        #expect(SlideRenderer(presentation: read, slide: read.slides[0]).linkAreas().isEmpty)
        let canvas = try context(width: 10)
        SlideRenderer(presentation: read, slide: read.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: CGSize(width: 10, height: 1))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        #expect(pixels.allSatisfy { $0 == 0 })
    }
}
