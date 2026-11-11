import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import ImageIO
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

    /// A 40 × 40 pixel picture in quarters: red, blue over green, white.
    private func quarters() throws -> Data {
        let canvas = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // The bitmap's origin is its bottom left.
        for (rect, rgb) in [(CGRect(x: 0, y: 20, width: 20, height: 20), (1.0, 0.0, 0.0)), (CGRect(x: 20, y: 20, width: 20, height: 20), (0, 0, 1)),
                            (CGRect(x: 0, y: 0, width: 20, height: 20), (0, 1, 0)), (CGRect(x: 20, y: 0, width: 20, height: 20), (1, 1, 1))] {
            canvas.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            canvas.fill(rect)
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(canvas.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The slide drawn one pixel to the point, with its background a tile of `quarters`, as the colour at each point asked for.
    @MainActor
    private func tiledBackground(_ tile: Fill.Tile, at points: [(Int, Int)]) throws -> [String] {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = []
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.setBackgroundPicture(PreparedMedia(png: try quarters(), size: CGSize(width: 40, height: 40)), tiled: true, in: &presentation)
        guard case .fill(.tiledPicture(let path, let effects, _))? = presentation.slides[0].background else {
            Issue.record("Expected a tiled background")
            return []
        }
        presentation.slides[0].background = .fill(.tiledPicture(path: path, effects: effects, tile: tile))
        let size = presentation.slideSize.points
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0]).draw(in: canvas, size: CGSize(width: width, height: height))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        return points.map { x, y in
            let offset = (y * width + x) * 4
            switch (pixels[offset] > 128, pixels[offset + 1] > 128, pixels[offset + 2] > 128) {
            case (true, false, false): return "red"
            case (false, false, true): return "blue"
            case (false, true, false): return "green"
            case (true, true, true): return "white"
            default: return "other"
            }
        }
    }

    @Test("Tiled picture fills honour their scale, offset, flip and alignment") @MainActor
    func tileLayout() throws {
        // At 100% the 40 pixel picture is a 30 point tile, laid from the top left.
        #expect(try tiledBackground(Fill.Tile(), at: [(5, 5), (25, 5), (5, 25), (35, 5), (5, 35)])
            == ["red", "blue", "green", "red", "red"])
        // Twice the size: 60 points.
        #expect(try tiledBackground(Fill.Tile(scaleX: 2, scaleY: 2), at: [(25, 25), (35, 5), (5, 35), (65, 5)])
            == ["red", "blue", "green", "red"])
        // Moved 10 points right and down: the corner shows the tile before's far side.
        #expect(try tiledBackground(Fill.Tile(offsetX: 127_000, offsetY: 127_000), at: [(5, 15), (15, 5), (15, 15), (5, 5)])
            == ["blue", "green", "red", "white"])
        // Every other tile mirrored across, down, or both.
        #expect(try tiledBackground(Fill.Tile(flip: .x), at: [(5, 5), (35, 5), (55, 5), (5, 35)]) == ["red", "blue", "red", "red"])
        #expect(try tiledBackground(Fill.Tile(flip: .y), at: [(5, 5), (35, 5), (5, 35), (5, 55)]) == ["red", "red", "green", "red"])
        #expect(try tiledBackground(Fill.Tile(flip: .xy), at: [(35, 35), (35, 5), (5, 35)]) == ["white", "blue", "green"])
        // Anchored elsewhere, a tile sits against that point of the area.
        let size = Presentation.blank.slideSize.points
        let right = Int(size.width), bottom = Int(size.height), middle = Int(size.width / 2), centre = Int(size.height / 2)
        // A 35 point tile, so the slide's far edges don't fall between tiles laid from the top left.
        let bottomRight = Fill.Tile(scaleX: 7.0 / 6, scaleY: 7.0 / 6, alignment: .bottomRight)
        #expect(try tiledBackground(bottomRight, at: [(right - 5, bottom - 5), (right - 25, bottom - 25)]) == ["white", "red"])
        #expect(try tiledBackground(Fill.Tile(alignment: .center), at: [(middle - 10, centre - 10), (middle + 10, centre + 10)])
            == ["red", "white"])
        #expect(try tiledBackground(Fill.Tile(alignment: .top), at: [(middle - 10, 5), (middle + 10, 25)]) == ["red", "white"])
    }
}
