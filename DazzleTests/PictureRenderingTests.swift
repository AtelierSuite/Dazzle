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

@Suite("Picture recolouring and artistic effects")
struct PictureRecolourTests {
    private static let image = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

    /// A colour of the file's own, with its transforms.
    private static func rgb(_ color: DrawingColor) -> RGBAColor {
        guard case .rgb(let value) = color.base else { return .black }
        return color.transforms.reduce(RGBAColor(hex: value)) { $0.applying($1) }
    }

    private func blip(_ inner: String) throws -> BlipEffects {
        BlipEffects(blip: try #require(XMLLite.fragment(
            "<a:blip r:embed=\"rId1\">\(inner)</a:blip>", namespaces: PartImporter.commonNamespaces
        )))
    }

    /// Pixels of a `width` × 1 picture, as RGBA 0…255 in sRGB.
    private func picture(_ colors: [(Double, Double, Double, Double)]) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let canvas = try #require(CGContext(data: nil, width: colors.count, height: 1, bitsPerComponent: 8, bytesPerRow: colors.count * 4,
                                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, color) in colors.enumerated() {
            canvas.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: color.3))
            canvas.fill(CGRect(x: index, y: 0, width: 1, height: 1))
        }
        return try #require(canvas.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let canvas = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(try #require(canvas.makeImage()?.dataProvider?.data as Data?))
    }

    private func processed(_ effects: BlipEffects, _ colors: [(Double, Double, Double, Double)]) throws -> [UInt8] {
        let resolved = effects.resolved(Self.rgb)
        return try pixels(try #require(ImageCache.shared.processed(try picture(colors), key: UUID().uuidString, effects: resolved)))
    }

    @Test("Colour change, black and white, hue, saturation, luminance and tint are read and written back")
    func readsAndWrites() throws {
        let effects = try blip("""
            <a:clrChange><a:clrFrom><a:srgbClr val="FFFFFF"/></a:clrFrom><a:clrTo><a:srgbClr val="FFFFFF"><a:alpha val="0"/></a:srgbClr></a:clrTo></a:clrChange>\
            <a:biLevel thresh="25000"/><a:hsl hue="7200000" sat="-50000" lum="10000"/><a:tint hue="14400000" amt="40000"/>
            """)
        #expect(effects.colorChange == .init(from: .rgb(0xFFFFFF), to: DrawingColor(base: .rgb(0xFFFFFF), transforms: [.init(name: "alpha", value: 0)])))
        #expect(effects.biLevelThreshold == 0.25)
        #expect(effects.hueShift == 120 && effects.saturationShift == -0.5 && effects.luminanceShift == 0.1)
        #expect(effects.tintHue == 240 && effects.tintAmount == 0.4)
        #expect(effects.altersColor)
        #expect(try blip(effects.xml) == effects)
    }

    @Test("Artistic effects apply only when the blip is not already their result")
    func artisticLayers() throws {
        let effects = """
            <a:extLst><a:ext uri="{BEBA8EAE-BF5A-486C-A8C5-ECC9F3942E4B}"><a14:imgProps><a14:imgLayer%@>\
            <a14:imgEffect><a14:artisticPencilSketch trans="20000" pressure="40"/></a14:imgEffect>\
            <a14:imgEffect><a14:saturation sat="0"/></a14:imgEffect>\
            <a14:imgEffect><a14:backgroundRemoval t="0" b="100000" l="0" r="100000"/></a14:imgEffect>\
            </a14:imgLayer></a14:imgProps></a:ext></a:extLst>
            """
        // Office keeps the original apart and its blip is already drawn with the effects.
        let rendered = try blip(String(format: effects, " r:embed=\"rId2\""))
        #expect(rendered.hasOriginalLayer)
        #expect(rendered.artistic.map(\.name) == ["artisticPencilSketch", "saturation", "backgroundRemoval"])
        #expect(rendered.pendingArtistic.isEmpty && !rendered.altersColor)
        #expect(rendered.xml.isEmpty) // Without the original part, nothing is claimed of it.
        // Without the original, the blip is the original and the effects are still to be applied.
        let pending = try blip(String(format: effects, ""))
        #expect(pending.pendingArtistic.map(\.name) == ["artisticPencilSketch", "saturation"])
        #expect(pending.pendingArtistic[0].transparency == 0.2)
        #expect(pending.altersColor)
        #expect(try blip(pending.xml) == pending)
    }

    @Test("The colour change makes near colours transparent too, and nothing else")
    func colorChange() throws {
        let effects = try blip("""
            <a:clrChange><a:clrFrom><a:srgbClr val="FFFFFF"/></a:clrFrom><a:clrTo><a:srgbClr val="FFFFFF"><a:alpha val="0"/></a:srgbClr></a:clrTo></a:clrChange>
            """)
        let result = try processed(effects, [(1, 1, 1, 1), (0.98, 0.98, 0.99, 1), (1, 0, 0, 1), (0.8, 0.8, 0.8, 1)])
        #expect(result[3] == 0 && result[7] == 0) // White, and the near white of a JPEG, are gone.
        #expect(result[8] == 255 && result[11] == 255) // Red stays.
        #expect(result[15] == 255) // Light grey is too far from white.
    }

    @Test("Black and white, hue, tint and the picture corrections change colours as Office does")
    func colorEffects() throws {
        let biLevel = try processed(try blip("<a:biLevel thresh=\"50000\"/>"), [(0.6, 0.6, 0.6, 1), (0.4, 0.4, 0.4, 1)])
        #expect(Array(biLevel[0..<3]) == [255, 255, 255] && Array(biLevel[4..<7]) == [0, 0, 0])
        // A third of the way round turns red green.
        let hue = try processed(try blip("<a:hsl hue=\"7200000\" sat=\"0\" lum=\"0\"/>"), [(1, 0, 0, 1)])
        #expect(hue[1] > hue[0] && hue[1] > hue[2])
        // A full tint towards blue makes grey a mid blue.
        let tint = try processed(try blip("<a:tint hue=\"14400000\" amt=\"100000\"/>"), [(0.5, 0.5, 0.5, 1)])
        #expect(tint[2] > 200 && tint[0] < 60 && tint[1] < 60)
        // Saturation 0 is grey; a warm temperature makes white warmer.
        let corrections = """
            <a:extLst><a:ext uri="{BEBA8EAE-BF5A-486C-A8C5-ECC9F3942E4B}"><a14:imgProps><a14:imgLayer>\
            <a14:imgEffect><a14:%@/></a14:imgEffect></a14:imgLayer></a14:imgProps></a:ext></a:extLst>
            """
        let grey = try processed(try blip(String(format: corrections, "saturation sat=\"0\"")), [(1, 0, 0, 1)])
        #expect(abs(Int(grey[0]) - Int(grey[1])) <= 2 && abs(Int(grey[1]) - Int(grey[2])) <= 2)
        let warm = try processed(try blip(String(format: corrections, "colorTemperature colorTemp=\"11500\"")), [(0.7, 0.7, 0.7, 1)])
        #expect(warm[0] > warm[2] + 20)
        let cool = try processed(try blip(String(format: corrections, "colorTemperature colorTemp=\"3000\"")), [(0.7, 0.7, 0.7, 1)])
        #expect(cool[2] > cool[0] + 20)
        let brighter = try processed(try blip(String(format: corrections, "brightnessContrast bright=\"40000\"")), [(0.5, 0.5, 0.5, 1)])
        #expect(brighter[0] > 170)
    }

    @Test("Artistic effects change the picture's look", arguments: [
        "artisticBlur radius=\"60\"", "artisticPencilSketch", "artisticPencilGrayscale", "artisticLineDrawing",
        "artisticChalkSketch", "artisticPhotocopy", "artisticCrisscrossEtching", "artisticGlowEdges", "artisticCutout",
        "artisticWatercolorSponge", "artisticPaintBrush", "artisticPaintStrokes", "artisticPastelsSmooth", "artisticMarker",
        "artisticFilmGrain", "artisticCement", "artisticTexturizer", "artisticLightScreen", "artisticGlass",
        "artisticMosiaicBubbles", "artisticGlowDiffused", "artisticPlasticWrap", "sharpenSoften amount=\"-80000\"",
        "sharpenSoften amount=\"80000\"",
    ])
    func artistic(_ effect: String) throws {
        // A 200 pixel square in red, green and blue bands.
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let canvas = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, color) in [(1.0, 0.0, 0.0), (0, 0.6, 0.2), (0.2, 0.3, 1)].enumerated() {
            canvas.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            canvas.fill(CGRect(x: index * 67, y: 0, width: 67, height: 200))
        }
        let original = try #require(canvas.makeImage())
        let effects = try blip("""
            <a:extLst><a:ext uri="{BEBA8EAE-BF5A-486C-A8C5-ECC9F3942E4B}"><a14:imgProps><a14:imgLayer>\
            <a14:imgEffect><a14:\(effect)/></a14:imgEffect></a14:imgLayer></a14:imgProps></a:ext></a:extLst>
            """)
        #expect(effects.pendingArtistic.count == 1)
        let resolved = effects.resolved(Self.rgb)
        let result = try #require(ImageCache.shared.processed(original, key: "artistic-\(effect)", effects: resolved))
        #expect(result.width == 200 && result.height == 200)
        let before = try pixels(original)
        let after = try pixels(result)
        let changed = zip(before, after).filter { abs(Int($0) - Int($1)) > 8 }.count
        #expect(changed > 40, "\(effect) left the picture as it was")
    }

    @Test("Saving keeps every effect, and Office's original picture, as read") @MainActor
    func savesUnchanged() throws {
        let tree = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <p:pic><p:nvPicPr><p:cNvPr id="4" name="Logo"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
            <p:blipFill><a:blip r:embed="rId1"><a:clrChange><a:clrFrom><a:srgbClr val="FFFFFF"/></a:clrFrom>\
            <a:clrTo><a:srgbClr val="FFFFFF"><a:alpha val="0"/></a:srgbClr></a:clrTo></a:clrChange><a:biLevel thresh="50000"/>\
            <a:extLst><a:ext uri="{BEBA8EAE-BF5A-486C-A8C5-ECC9F3942E4B}">\
            <a14:imgProps xmlns:a14="http://schemas.microsoft.com/office/drawing/2010/main"><a14:imgLayer r:embed="rId2">\
            <a14:imgEffect><a14:artisticWatercolorSponge trans="10000" brushSize="4"/></a14:imgEffect></a14:imgLayer></a14:imgProps>\
            </a:ext></a:extLst></a:blip><a:stretch><a:fillRect/></a:stretch></p:blipFill>
            <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm><a:prstGeom prst="rect"/></p:spPr></p:pic>
            </p:spTree>
            """.utf8))
        let relationships = [
            Relationship(id: "rId1", type: Self.image, target: "../media/image1.png"),
            Relationship(id: "rId2", type: "http://schemas.microsoft.com/office/2007/relationships/hdphoto", target: "../media/hdphoto1.wdp"),
        ]
        var shape = try #require(ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: relationships,
                                             namespaces: OOXML.namespaces, parts: [:], capturesSource: true).shapes(in: tree).first)
        guard case .picture(var picture) = shape.kind else {
            Issue.record("Expected a picture")
            return
        }
        #expect(picture.effects.hasOriginalLayer && picture.effects.colorChange != nil)
        picture.cropLeft = 0.1
        shape.kind = .picture(picture)
        shape.edits = [.picture]
        var writer = ShapeWriter(partPath: "ppt/slides/slide1.xml", namespaces: OOXML.namespaces, relationships: relationships)
        let written = writer.xml(for: shape)
        let xml = try #require(written)
        #expect(xml.contains("r:embed=\"rId2\""))
        #expect(xml.contains("artisticWatercolorSponge"))
        #expect(xml.components(separatedBy: "clrChange").count == 3) // Opened and closed once.
        let reread = try #require(ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: relationships, namespaces: OOXML.namespaces,
                                              parts: [:]).shapes(in: try XMLLite.parse(Data((
            "<p:spTree xmlns:p=\"\(OOXML.presentationML)\" xmlns:a=\"\(OOXML.drawingML)\" xmlns:r=\"\(OOXML.relationshipsNS)\">\(xml)</p:spTree>"
        ).utf8))).first)
        guard case .picture(let restored) = reread.kind else {
            Issue.record("Expected a picture")
            return
        }
        #expect(restored.effects == picture.effects)
    }
}
