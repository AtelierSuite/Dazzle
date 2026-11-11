import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Line rendering")
struct LineRenderingTests {
    /// The widescreen slide, 960 × 540 points, drawn at a fifth of its size.
    private let size = CGSize(width: 192, height: 108)

    private func render(_ shapeXML: String) throws -> (pixels: Data, bytesPerRow: Int) {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            \(shapeXML)
            </p:spTree>
            """.utf8))
        let shape = try #require(ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                                           parts: [:], capturesSource: false).shapes(in: root).first)
        var presentation = Presentation.blank
        presentation.slideSize = .widescreen
        presentation.slides[0].shapes = [shape]
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: size)
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        return (pixels, canvas.bytesPerRow)
    }

    private func pixel(_ image: (pixels: Data, bytesPerRow: Int), x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = y * image.bytesPerRow + x * 4
        return (image.pixels[offset], image.pixels[offset + 1], image.pixels[offset + 2], image.pixels[offset + 3])
    }

    private let redToBlue = """
        <a:gradFill><a:gsLst>
        <a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs><a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs>
        </a:gsLst><a:lin ang="0" scaled="0"/></a:gradFill>
        """

    @Test("A gradient outline is drawn, running along the gradient")
    func gradientOutline() throws {
        // A rectangle from 100 to 860 points across, 135 to 405 down, with a
        // 20-point red-to-blue outline and no fill.
        let image = try render("""
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="1270000" y="1714500"/><a:ext cx="9652000" cy="3429000"/></a:xfrm>
            <a:prstGeom prst="rect"/><a:noFill/><a:ln w="254000">\(redToBlue)</a:ln></p:spPr></p:sp>
            """)
        let left = pixel(image, x: 20, y: 54)
        let right = pixel(image, x: 172, y: 54)
        #expect(left.a == 255 && left.r > 200 && left.b < 50)
        #expect(right.a == 255 && right.b > 200 && right.r < 50)
        #expect(pixel(image, x: 96, y: 54).a == 0) // The inside is left unfilled.
    }

    @Test("A dashed gradient line keeps its dashes and arrowhead")
    func gradientArrow() throws {
        // A line across the middle, 100 to 860 points, 10 points thick and
        // dashed, ending in a triangle 40 points long.
        let image = try render("""
            <p:sp><p:nvSpPr><p:cNvPr id="3" name="Arrow"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="1270000" y="3429000"/><a:ext cx="9652000" cy="0"/></a:xfrm>
            <a:prstGeom prst="line"/><a:ln w="127000">\(redToBlue)<a:prstDash val="sysDash"/><a:tailEnd type="triangle"/></a:ln>
            </p:spPr></p:sp>
            """)
        let row = (0..<Int(size.width)).map { pixel(image, x: $0, y: 53).a }
        // Dashes: 40 points on, 30 off, from the start of the line.
        #expect(row[22] == 255 && row[33] == 0 && row[36] == 255)
        #expect(pixel(image, x: 22, y: 53).r > 200)
        // The arrowhead is wider than the line, and the gradient's blue end.
        let head = [pixel(image, x: 165, y: 51), pixel(image, x: 165, y: 56)]
        #expect(head.allSatisfy { $0.a > 100 && $0.b > $0.r })
        // Where the arrowhead and the line overlap, neither cancels the other.
        #expect(pixel(image, x: 165, y: 53).a == 255 && pixel(image, x: 165, y: 54).a == 255)
        #expect(pixel(image, x: 100, y: 51).a == 0 && pixel(image, x: 100, y: 56).a == 0)
    }
}
