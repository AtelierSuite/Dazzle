import CoreGraphics
import Foundation
import Testing
@testable import Dazzle

@Suite("Text outlines, shadows and reflections")
struct TextEffectsTests {
    private func shapes(_ xml: String) throws -> [SlideShape] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(xml)</p:spTree>
            """.utf8))
        return ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                           parts: [:], capturesSource: true).shapes(in: root)
    }

    private func textBox(_ runProperties: String, size: Int = 7_200, text: String = "I") -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="2540000" cy="1270000"/></a:xfrm>
        <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
        <p:txBody><a:bodyPr wrap="none"/><a:p><a:r><a:rPr lang="en-US" sz="\(size)">\(runProperties)</a:rPr>\
        <a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>
        """
    }

    private func rectangle(effects: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="1270000" cy="1270000"/></a:xfrm>
        <a:prstGeom prst="rect"/><a:solidFill><a:srgbClr val="000000"/></a:solidFill>\(effects)</p:spPr></p:sp>
        """
    }

    /// The slide drawn without its background, a pixel to the point, top row first.
    private func render(_ shapes: [SlideShape]) throws -> (alpha: [UInt8], width: Int) {
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
        return (stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }, width)
    }

    private func coverage(_ alpha: [UInt8]) -> Int { alpha.reduce(0) { $0 + Int($1) } }

    @Test("Run outlines and shadows are read, and written for runs that carry no XML of their own")
    func runEffectsRoundTrip() throws {
        let box = try #require(shapes(textBox("""
            <a:ln w="25400"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></a:ln>\
            <a:solidFill><a:srgbClr val="000000"/></a:solidFill>\
            <a:effectLst><a:outerShdw blurRad="38100" dist="50800" dir="2700000"><a:srgbClr val="000000"/></a:outerShdw></a:effectLst>
            """)).first)
        let properties = try #require(box.text?.paragraphs.first?.runs.first?.properties)
        #expect(properties.outline == .line(width: 25_400, color: .rgb(0xFF0000)))
        #expect(properties.shadow == .shadow(Shadow(blur: 38_100, distance: 50_800, direction: 45, color: .rgb(0x000000))))

        var made = box
        made.source = nil
        made.text?.paragraphs[0].runs[0].sourceProperties = nil
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [made]
        presentation.slides[0].isModified = true
        let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let written = try #require(read.slides[0].shapes.first?.text?.paragraphs.first?.runs.first?.properties)
        #expect(written.outline == properties.outline)
        #expect(written.shadow == properties.shadow)
    }

    @Test("An outline with no fill and an empty effect list take inherited ones away")
    func runEffectsRemoved() throws {
        let box = try #require(shapes(textBox("<a:ln><a:noFill/></a:ln><a:effectLst/>")).first)
        let properties = try #require(box.text?.paragraphs.first?.runs.first?.properties)
        #expect(properties.outline == TextOutline.none)
        #expect(properties.shadow == TextShadow.none)
        var inherited = RunProperties()
        inherited.outline = .line(width: 12_700, color: .rgb(0))
        #expect(properties.merged(over: inherited).outline == TextOutline.none)
    }

    @Test("An outline thickens the letters it is drawn around")
    func outlineDrawn() throws {
        let plain = try render(shapes(textBox("<a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill>")))
        let outlined = try render(shapes(textBox(
            "<a:ln w=\"50800\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill></a:ln><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill>"
        )))
        #expect(coverage(outlined.alpha) > coverage(plain.alpha) * 5 / 4)
    }

    @Test("Letters cast their shadow where it falls")
    func shadowDrawn() throws {
        let plain = try render(shapes(textBox("<a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill>")))
        // Straight down, well clear of the letter.
        let shadowed = try render(shapes(textBox("""
            <a:solidFill><a:srgbClr val="000000"/></a:solidFill>\
            <a:effectLst><a:outerShdw dist="1270000" dir="5400000"><a:srgbClr val="000000"/></a:outerShdw></a:effectLst>
            """)))
        func below(_ alpha: [UInt8], _ width: Int) -> Int {
            // Rows 200 to 260 points down, under the letter's box.
            coverage(Array(alpha[(200 * width)..<(260 * width)]))
        }
        #expect(below(plain.alpha, plain.width) == 0)
        #expect(below(shadowed.alpha, shadowed.width) > 0)
    }

    @Test("A reflection is read, drawn fading below the shape, and kept when the shadow changes")
    func reflection() throws {
        let effects = "<a:effectLst><a:reflection stA=\"80000\" endA=\"0\" endPos=\"100000\" dist=\"0\" dir=\"5400000\" sy=\"-100000\"/></a:effectLst>"
        var box = try #require(shapes(rectangle(effects: effects)).first)
        #expect(box.reflection == Reflection(startOpacity: 0.8, endPosition: 1))

        // The box spans 100 to 200 points down; its reflection 200 to 300.
        let (alpha, width) = try render([box])
        let near = alpha[205 * width + 150], far = alpha[290 * width + 150]
        #expect(near > 150 && near < 230)
        #expect(far < near)
        #expect(alpha[310 * width + 150] == 0)

        box.shadow = Shadow(blur: 0, distance: 12_700, direction: 45, color: .rgb(0))
        box.edits.insert(.effects)
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [box]
        presentation.slides[0].isModified = true
        let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(read.slides[0].shapes.first?.reflection == box.reflection)
        #expect(read.slides[0].shapes.first?.shadow == box.shadow)
    }
}
