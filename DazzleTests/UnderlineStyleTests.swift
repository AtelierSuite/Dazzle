import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Underline and strikethrough styles")
struct UnderlineStyleTests {
    private func shapes(_ xml: String) throws -> [SlideShape] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(xml)</p:spTree>
            """.utf8))
        return ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                           parts: [:], capturesSource: true).shapes(in: root)
    }

    private func textBox(_ attributes: String, _ children: String = "", text: String = "HHHH") -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="5080000" cy="1270000"/></a:xfrm>
        <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
        <p:txBody><a:bodyPr wrap="none"/><a:p><a:r><a:rPr lang="en-US" sz="4800" \(attributes)>\
        <a:solidFill><a:srgbClr val="000000"/></a:solidFill>\(children)</a:rPr>\
        <a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>
        """
    }

    private func properties(_ attributes: String, _ children: String = "") throws -> RunProperties {
        try #require(shapes(textBox(attributes, children)).first?.text?.paragraphs.first?.runs.first?.properties)
    }

    /// The slide's RGBA pixels, drawn without its background, top row first.
    private func render(_ shapes: [SlideShape]) throws -> (pixels: [UInt8], width: Int) {
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
        return ([UInt8](try #require(canvas.makeImage()?.dataProvider?.data as Data?)), width)
    }

    private func coverage(_ attributes: String, _ children: String = "", text: String = "HHHH") throws -> Int {
        let (pixels, _) = try render(shapes(textBox(attributes, children, text: text)))
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }
    }

    @Test("Every underline and strikethrough style is read as itself")
    func readsStyles() throws {
        for style in UnderlineStyle.allCases {
            #expect(try properties("u=\"\(style.rawValue)\"").underline == style)
        }
        for style in StrikeStyle.allCases {
            #expect(try properties("strike=\"\(style.rawValue)\"").strike == style)
        }
        #expect(try properties("u=\"dbl\"").isUnderlined == true)
        #expect(try properties("u=\"none\"").isUnderlined == false)
        #expect(try properties("strike=\"dblStrike\"").isStruckThrough == true)
        #expect(try properties("").underline == nil)
    }

    @Test("The underline colour comes from uFill, or failing that from uLn")
    func readsUnderlineColor() throws {
        let filled = try properties("u=\"sng\"", "<a:uLn><a:solidFill><a:srgbClr val=\"00FF00\"/></a:solidFill></a:uLn>"
            + "<a:uFill><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></a:uFill>")
        #expect(filled.underlineColor == .rgb(0xFF0000))
        let lined = try properties("u=\"sng\"", "<a:uLn w=\"12700\"><a:solidFill><a:schemeClr val=\"accent2\"/></a:solidFill></a:uLn>")
        #expect(lined.underlineColor == .scheme("accent2"))
        #expect(try properties("u=\"sng\"", "<a:uLnTx/><a:uFillTx/>").underlineColor == nil)
    }

    @Test("Turning an underline or strikethrough on keeps its style, and off and on again makes it single")
    func togglingKeepsStyle() {
        var run = RunProperties()
        run.underline = .wavyHeavy
        run.isUnderlined = true
        #expect(run.underline == .wavyHeavy)
        run.isUnderlined = false
        #expect(run.underline == UnderlineStyle.none)
        run.isUnderlined = true
        #expect(run.underline == .single)
        run.strike = .double
        run.isStruckThrough = true
        #expect(run.strike == .double)
        run.isStruckThrough = nil
        #expect(run.strike == nil)
    }

    @Test("Editing a run writes its underline and strikethrough styles and colour back")
    func editingKeepsStyles() throws {
        let box = try #require(shapes(textBox(
            "u=\"dotDotDashHeavy\" strike=\"dblStrike\"", "<a:uFill><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></a:uFill>"
        )).first)
        for keepsSource in [true, false] {
            var edited = box
            edited.source = nil
            edited.text?.paragraphs[0].runs[0].text = "Edited"
            edited.text?.paragraphs[0].runs[0].properties.isBold = true
            if !keepsSource { edited.text?.paragraphs[0].runs[0].sourceProperties = nil }
            var presentation = Presentation.blank
            presentation.slides[0].shapes = [edited]
            presentation.slides[0].isModified = true
            let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
            let run = try #require(read.slides[0].shapes.first?.text?.paragraphs.first?.runs.first)
            #expect(run.text == "Edited")
            #expect(run.properties.isBold == true)
            #expect(run.properties.underline == .dotDotDashHeavy)
            #expect(run.properties.strike == .double)
            #expect(run.properties.underlineColor == .rgb(0xFF0000))
        }
    }

    @Test("Each underline style draws a line of its own")
    func drawsUnderlineStyles() throws {
        let plain = try coverage("")
        let single = try coverage("u=\"sng\"")
        #expect(single > plain)
        #expect(try coverage("u=\"heavy\"") > single)
        #expect(try coverage("u=\"dbl\"") > single)
        #expect(try coverage("u=\"dotted\"") < single)
        #expect(try coverage("u=\"dash\"") < single)
        #expect(try coverage("u=\"wavy\"") > single)
        #expect(try coverage("u=\"wavyDbl\"") > coverage("u=\"wavy\""))
        // Words underlined one by one leave the space between them bare.
        #expect(try coverage("u=\"words\"", text: "HH  HH") < coverage("u=\"sng\"", text: "HH  HH"))
    }

    @Test("A double strikethrough draws two lines")
    func drawsDoubleStrike() throws {
        let plain = try coverage("")
        let single = try coverage("strike=\"sngStrike\"")
        #expect(single > plain)
        #expect(try coverage("strike=\"dblStrike\"") > single)
    }

    @Test("A coloured underline is drawn in its own colour, the text in its")
    func drawsUnderlineColor() throws {
        let (pixels, _) = try render(shapes(textBox(
            "u=\"heavy\"", "<a:uFill><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></a:uFill>"
        )))
        var red = 0, black = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] == 255 {
            if pixels[index] > 200, pixels[index + 1] < 50 { red += 1 }
            if pixels[index] < 50, pixels[index + 1] < 50 { black += 1 }
        }
        #expect(red > 50)
        #expect(black > red)
    }
}
