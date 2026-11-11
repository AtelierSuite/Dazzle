import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Vertical text")
struct VerticalTextTests {
    private func shapes(_ xml: String) throws -> [SlideShape] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(xml)</p:spTree>
            """.utf8))
        return ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                           parts: [:], capturesSource: true).shapes(in: root)
    }

    /// A tall text box running `vertical`, holding `text` in a Japanese face,
    /// 100 points wide unless it says otherwise.
    private func textBox(_ vertical: String, text: String, width: Int = 1_270_000, autofit: String = "") -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="1270000" y="635000"/><a:ext cx="\(width)" cy="3810000"/></a:xfrm>
        <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
        <p:txBody><a:bodyPr vert="\(vertical)">\(autofit)</a:bodyPr><a:p><a:r><a:rPr lang="ja-JP" sz="7200">\
        <a:latin typeface="Hiragino Sans"/><a:ea typeface="Hiragino Sans"/></a:rPr>\
        <a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>
        """
    }

    /// The width and height of the ink the slide's shapes leave, a pixel to the point.
    private func inkSize(_ shapes: [SlideShape]) throws -> CGSize {
        try ink(shapes).size
    }

    /// Where the ink the slide's shapes leave lies, a pixel to the point.
    private func ink(_ shapes: [SlideShape]) throws -> CGRect {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = shapes
        let size = presentation.slideSize.points
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: CGSize(width: width, height: height))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= minX, "Nothing was drawn")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test("Japanese set vertically stands upright, as one stroke across shows")
    func uprightInVerticalLines() throws {
        // 一 is a single stroke across: upright it is wide and flat.
        let ink = try inkSize(shapes(textBox("eaVert", text: "一")))
        #expect(ink.width > ink.height * 3)
    }

    @Test("Stacked text stands Japanese upright too")
    func uprightWhenStacked() throws {
        let ink = try inkSize(shapes(textBox("wordArtVert", text: "一")))
        #expect(ink.width > ink.height * 3)
    }

    @Test("Text turned a quarter turns every letter with it")
    func turnedWithTheLine() throws {
        for vertical in ["vert", "vert270"] {
            let ink = try inkSize(shapes(textBox(vertical, text: "一")))
            #expect(ink.height > ink.width * 3, "\(vertical)")
        }
    }

    @Test("Japanese set vertically reads down the box, a character below the one before")
    func readsDown() throws {
        let one = try inkSize(shapes(textBox("eaVert", text: "一")))
        let three = try inkSize(shapes(textBox("eaVert", text: "一一一")))
        #expect(three.height > one.width * 2)
        #expect(abs(three.width - one.width) <= 2)
    }

    @Test("Latin letters in Japanese set vertically lie on their side")
    func latinOnItsSide() throws {
        // A run of hyphens drawn sideways makes a tall, thin mark.
        let ink = try inkSize(shapes(textBox("eaVert", text: "----")))
        #expect(ink.height > ink.width * 3)
    }

    @Test("Mongolian set vertically stands Japanese upright too")
    func uprightInMongolianLines() throws {
        let ink = try inkSize(shapes(textBox("mongolianVert", text: "一")))
        #expect(ink.width > ink.height * 3)
    }

    @Test("Vertical lines start at the right, or at the left for Mongolian and stacked text")
    func lineDirection() throws {
        // A single line in a box 300 points wide, from 100 to 400, set from its first side.
        for (vertical, startsAtRight) in [("eaVert", true), ("wordArtVertRtl", true), ("vert", true),
                                          ("mongolianVert", false), ("wordArtVert", false), ("vert270", false)] {
            let ink = try ink(shapes(textBox(vertical, text: "一", width: 3_810_000)))
            if startsAtRight {
                #expect(ink.minX > 300, "\(vertical)")
            } else {
                #expect(ink.maxX < 200, "\(vertical)")
            }
        }
    }
}
