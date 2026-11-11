import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Gradients")
struct GradientTests {
    private let redToBlue = """
        <a:gsLst><a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs><a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs></a:gsLst>
        """

    private func gradient(_ xml: String) throws -> Fill.Gradient {
        let element = try XMLLite.parse(Data(xml.utf8))
        guard case .gradient(let gradient) = Fill.parse(element: element, image: { _ in nil }) else {
            throw GradientTestError.notAGradient
        }
        return gradient
    }

    private enum GradientTestError: Error { case notAGradient }

    @Test("Path gradients keep their kind, fillToRect and tileRect, and linear ones whether they are scaled")
    func parsing() throws {
        let rect = try gradient("""
            <a:gradFill xmlns:a="a">\(redToBlue)<a:path path="rect"><a:fillToRect l="25000" t="10%" r="75000"/></a:path>\
            <a:tileRect l="-100000" t="-50000"/></a:gradFill>
            """)
        #expect(rect.path == .rect)
        #expect(rect.fillToRect == .init(left: 0.25, top: 0.1, right: 0.75, bottom: 0))
        #expect(rect.tileRect == .init(left: -1, top: -0.5, right: 0, bottom: 0))

        let shape = try gradient("<a:gradFill xmlns:a=\"a\">\(redToBlue)<a:path path=\"shape\"/></a:gradFill>")
        #expect(shape.path == .shape)
        #expect(shape.fillToRect == .center) // Without a fillToRect, it starts from the centre.

        let linear = try gradient("<a:gradFill xmlns:a=\"a\">\(redToBlue)<a:lin ang=\"2700000\" scaled=\"1\"/></a:gradFill>")
        #expect(linear.path == nil && linear.angle == 45 && linear.isScaled)
    }

    @Test("Path and scaled gradients are written as they were read")
    func roundTrip() throws {
        let originals = [
            Fill.Gradient(
                stops: [.init(position: 0, color: .rgb(0xFF0000)), .init(position: 1, color: .rgb(0x0000FF))], angle: 0,
                path: .rect, fillToRect: .init(left: 0, top: 0, right: 1, bottom: 1),
                tileRect: .init(left: -1, top: -1, right: 0, bottom: 0)
            ),
            Fill.Gradient(
                stops: [.init(position: 0, color: .scheme("accent1")), .init(position: 1, color: .scheme("bg1"))], angle: 0,
                path: .shape, fillToRect: .init(left: 0.5, top: 0.25, right: 0.5, bottom: 0.25)
            ),
            Fill.Gradient(
                stops: [.init(position: 0, color: .rgb(0xFFFFFF)), .init(position: 1, color: .rgb(0x000000))], angle: 45,
                path: .circle, fillToRect: .zero
            ),
            Fill.Gradient(
                stops: [.init(position: 0, color: .rgb(0xFFFFFF)), .init(position: 1, color: .rgb(0x000000))], angle: 30,
                isScaled: true, tileRect: .init(left: 0.1, top: 0, right: 0.1, bottom: 0)
            ),
        ]
        for original in originals {
            let xml = Fill.gradient(original).xml.replacingOccurrences(of: "<a:gradFill ", with: "<a:gradFill xmlns:a=\"a\" ")
            var read = try gradient(xml)
            // Angles only matter to linear gradients, and are not written for others.
            if original.path != nil { read.angle = original.angle }
            #expect(read == original)
        }
    }

    @Test("Turning a gradient radial and back keeps where it starts")
    func editing() {
        var gradient = Fill.Gradient(
            stops: [.init(position: 0, color: .rgb(0xFF0000))], angle: 0, path: .rect,
            fillToRect: .init(left: 0, top: 0, right: 1, bottom: 1)
        )
        gradient.isRadial = true
        #expect(gradient.path == .rect)
        gradient.isRadial = false
        gradient.isRadial = true
        #expect(gradient.path == .circle && gradient.fillToRect == .init(left: 0, top: 0, right: 1, bottom: 1))
    }

    // MARK: - Drawing

    /// A slide-filling `prst` shape filled with `fill`, drawn at a fifth of
    /// its size (192 × 108 pixels, one to every five points), as the
    /// fraction of the way from red to blue at each pixel asked for.
    private func blueness(_ fill: String, geometry: String = "rect", at points: [(Int, Int)]) throws -> [Double] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="6858000"/></a:xfrm>
            <a:prstGeom prst="\(geometry)"/>\(fill)<a:ln><a:noFill/></a:ln></p:spPr></p:sp>
            </p:spTree>
            """.utf8))
        let shape = try #require(ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                                           parts: [:], capturesSource: false).shapes(in: root).first)
        var presentation = Presentation.blank
        presentation.slideSize = .widescreen
        presentation.slides[0].shapes = [shape]
        let width = 192, height = 108
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: CGSize(width: width, height: height))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        return points.map { x, y in
            let offset = y * canvas.bytesPerRow + x * 4
            let red = Double(pixels[offset]), blue = Double(pixels[offset + 2])
            return red + blue > 0 ? blue / (red + blue) : -1
        }
    }

    @Test("A rectangular gradient grows in rectangles from fillToRect, which it fills with its first colour")
    func rectangle() throws {
        let fill = "<a:gradFill>\(redToBlue)<a:path path=\"rect\"><a:fillToRect l=\"25000\" t=\"25000\" r=\"25000\" b=\"25000\"/></a:path></a:gradFill>"
        let values = try blueness(fill, at: [(60, 35), (130, 70), (24, 54), (96, 13), (24, 14), (2, 54), (96, 1)])
        // Inside fillToRect, from 48 to 144 across and 27 to 81 down: red.
        #expect(values[0] < 0.05 && values[1] < 0.05)
        // Halfway out to the edges, straight across, down, and on the diagonal: all halfway.
        for value in values[2...4] { #expect(abs(value - 0.5) < 0.1, "\(values)") }
        // At the edges: blue.
        #expect(values[5] > 0.9 && values[6] > 0.9)
    }

    @Test("A circular gradient starts from fillToRect and reaches around its tile")
    func circle() throws {
        // From the top-left corner, with the tile reaching out past it as far
        // again: circles centred on the corner, blue at the far corner.
        let corner = "<a:gradFill>\(redToBlue)<a:path path=\"circle\"><a:fillToRect r=\"100000\" b=\"100000\"/></a:path>"
            + "<a:tileRect l=\"-100000\" t=\"-100000\"/></a:gradFill>"
        let values = try blueness(corner, at: [(1, 1), (190, 106), (96, 54), (190, 1)])
        #expect(values[0] < 0.05 && values[1] > 0.9, "\(values)")
        #expect(abs(values[2] - 0.5) < 0.1, "\(values)")
        // Circles, not rectangles: the top right corner is only as far along as its distance from the top left.
        #expect(values[3] > 0.8 && values[3] < 0.9, "\(values)")
    }

    @Test("A shape gradient follows the outline, from fillToRect out")
    func shape() throws {
        let fill = "<a:gradFill>\(redToBlue)<a:path path=\"shape\"><a:fillToRect l=\"50000\" t=\"50000\" r=\"50000\" b=\"50000\"/></a:path></a:gradFill>"
        // An ellipse: blue just inside its edge, all the way round, and halfway along the way out.
        let values = try blueness(fill, geometry: "ellipse", at: [(96, 54), (96, 2), (2, 54), (160, 88), (96, 28), (48, 54)])
        #expect(values[0] < 0.1, "\(values)")
        for value in values[1...3] { #expect(value > 0.85, "\(values)") }
        for value in values[4...5] { #expect(abs(value - 0.5) < 0.1, "\(values)") }
    }

    @Test("A scaled linear gradient's angle stretches with the shape")
    func scaled() throws {
        func fill(scaled: Bool) -> String {
            "<a:gradFill>\(redToBlue)<a:lin ang=\"2700000\" scaled=\"\(scaled ? 1 : 0)\"/></a:gradFill>"
        }
        // At 45°, scaled, the halfway line is the diagonal from bottom left to top right.
        let points = [(48, 81), (144, 27), (1, 1), (190, 106)]
        let scaled = try blueness(fill(scaled: true), at: points)
        for value in scaled[0...1] { #expect(abs(value - 0.5) < 0.05, "\(scaled)") }
        #expect(scaled[2] < 0.05 && scaled[3] > 0.95)
        // Unscaled, the same points are on either side of halfway.
        let unscaled = try blueness(fill(scaled: false), at: points)
        #expect(unscaled[0] < 0.46 && unscaled[1] > 0.54, "\(unscaled)")
    }
}
