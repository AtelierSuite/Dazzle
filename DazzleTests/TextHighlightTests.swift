import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Text highlight colour")
struct TextHighlightTests {
    private func shapes(_ xml: String) throws -> [SlideShape] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(xml)</p:spTree>
            """.utf8))
        return ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                           parts: [:], capturesSource: true).shapes(in: root)
    }

    private func textBox(_ runProperties: String, text: String = "IIII") -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="2540000" cy="1270000"/></a:xfrm>
        <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
        <p:txBody><a:bodyPr wrap="none"/><a:p><a:r><a:rPr lang="en-US" sz="4000">\(runProperties)</a:rPr>\
        <a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>
        """
    }

    private func reread(_ shape: SlideShape) throws -> RunProperties? {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [shape]
        presentation.slides[0].isModified = true
        let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        return read.slides[0].shapes.first?.text?.paragraphs.first?.runs.first?.properties
    }

    /// The slide's RGBA pixels, drawn without its background, top row first.
    private func render(_ shapes: [SlideShape]) throws -> (pixels: Data, width: Int) {
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
        return (try #require(canvas.makeImage()?.dataProvider?.data as Data?), width)
    }

    /// Pixels that are pure enough yellow to be the highlight, not the black letters.
    private func yellowPixels(_ shapes: [SlideShape]) throws -> Int {
        let (pixels, _) = try render(shapes)
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 230 && pixels[$0 + 1] > 230 && pixels[$0 + 2] < 30 && pixels[$0 + 3] > 230
        }.count
    }

    @Test("A run's highlight is read and inherited unless the run says otherwise")
    func read() throws {
        let box = try #require(shapes(textBox("<a:highlight><a:srgbClr val=\"FFFF00\"/></a:highlight>")).first)
        let properties = try #require(box.text?.paragraphs.first?.runs.first?.properties)
        #expect(properties.highlight == .color(.rgb(0xFFFF00)))
        #expect(RunProperties().merged(over: properties).highlight == .color(.rgb(0xFFFF00)))
        var none = RunProperties()
        none.highlight = TextHighlight.none
        #expect(none.merged(over: properties).highlight == TextHighlight.none)
    }

    @Test("Highlights are written back, in schema order, and taken away when removed")
    func roundTrip() throws {
        let box = try #require(shapes(textBox(
            "<a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill><a:latin typeface=\"Arial\"/>"
        )).first)
        var highlighted = box
        highlighted.text?.updateRuns { $0.highlight = .color(.scheme("accent2")) }
        highlighted.edits.insert(.text)
        var writer = ShapeWriter(partPath: "ppt/slides/slide1.xml", namespaces: OOXML.namespaces, relationships: [])
        let source = box.text?.paragraphs[0].runs[0].sourceProperties
        let xml = writer.runPropertiesXML(try #require(highlighted.text?.paragraphs[0].runs[0].properties), source: source, name: "rPr")
        let fill = try #require(xml.range(of: "solidFill"))
        let highlight = try #require(xml.range(of: "<a:highlight>"))
        let latin = try #require(xml.range(of: "<a:latin"))
        #expect(fill.lowerBound < highlight.lowerBound && highlight.lowerBound < latin.lowerBound)
        #expect(try reread(highlighted)?.highlight == .color(.scheme("accent2")))

        var made = highlighted
        made.source = nil
        made.text?.paragraphs[0].runs[0].sourceProperties = nil
        #expect(try reread(made)?.highlight == .color(.scheme("accent2")))

        let yellow = try #require(shapes(textBox("<a:highlight><a:srgbClr val=\"FFFF00\"/></a:highlight>")).first)
        var cleared = yellow
        cleared.text?.updateRuns { $0.highlight = TextHighlight.none }
        cleared.edits.insert(.text)
        #expect(try reread(cleared)?.highlight == nil)
    }

    @Test("Highlighted text is drawn on its colour; unhighlighted text is not")
    func drawn() throws {
        let plain = try #require(shapes(textBox("<a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill>")).first)
        let highlighted = try #require(shapes(textBox(
            "<a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill><a:highlight><a:srgbClr val=\"FFFF00\"/></a:highlight>"
        )).first)
        #expect(try yellowPixels([plain]) == 0)
        // Behind 40pt letters, the highlight spans the line's height.
        #expect(try yellowPixels([highlighted]) > 40 * 20)
    }

    @Test("The format panel sets and clears the highlight of the selected text") @MainActor
    func editing() throws {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = try shapes(textBox(""))
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.selectedShapeID = presentation.slides[0].shapes.first?.id
        state.setTextHighlight(.rgb(0x00FF00), in: &presentation)
        #expect(state.effectiveRunProperties(in: presentation).highlight == .color(.rgb(0x00FF00)))
        state.setTextHighlight(nil, in: &presentation)
        #expect(state.effectiveRunProperties(in: presentation).highlight?.color == nil)
    }
}
