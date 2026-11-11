import CoreGraphics
import CoreText
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing
import UIKit

@Suite("Tab stops")
struct TabStopTests {
    private func shape(_ paragraphs: String, listStyle: String = "") throws -> SlideShape {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="6350000" cy="1270000"/></a:xfrm>
            <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
            <p:txBody><a:bodyPr wrap="square"/><a:lstStyle>\(listStyle)</a:lstStyle>\(paragraphs)</p:txBody></p:sp>
            </p:spTree>
            """.utf8))
        let shapes = ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                                 parts: [:], capturesSource: true).shapes(in: root)
        return try #require(shapes.first)
    }

    private func paragraph(_ text: String, properties: String = "") -> String {
        "<a:p>\(properties)<a:r><a:rPr lang=\"en-US\" sz=\"1800\"/><a:t>\(text)</a:t></a:r></a:p>"
    }

    private var style: SlideStyleContext {
        let presentation = Presentation.blank
        return SlideStyleContext(presentation: presentation, slide: presentation.slides[0])
    }

    /// Where each of `characters` in the first line of `shape`'s text begins, in points from the left of the text.
    private func offsets(_ shape: SlideShape, of characters: [String]) throws -> [CGFloat] {
        let renderer = TextRenderer(style: style, slideNumber: 1)
        let string = renderer.attributedString(try #require(shape.text), shape: shape, sources: [], scale: 1, spacingReduction: 0, colorOverride: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: 480, height: 400), transform: nil), nil)
        let line = try #require((CTFrameGetLines(frame) as? [CTLine])?.first)
        let text = string.string as NSString
        return characters.map { CTLineGetOffsetForStringIndex(line, text.range(of: $0).location, nil) }
    }

    @Test("Stops and the default tab size are read, in order, and inherited")
    func read() throws {
        let read = try shape(paragraph("a", properties: """
            <a:pPr defTabSz="457200"><a:tabLst><a:tab pos="1828800" algn="dec"/><a:tab pos="914400" algn="ctr"/>\
            <a:tab pos="2743200"/></a:tabLst></a:pPr>
            """))
        let properties = try #require(read.text?.paragraphs.first?.properties)
        #expect(properties.tabStops == [
            TabStop(position: 914_400, alignment: .center), TabStop(position: 1_828_800, alignment: .decimal), TabStop(position: 2_743_200),
        ])
        #expect(properties.defaultTabSize == 457_200)

        // From the shape's list style, beneath a paragraph that says nothing.
        let inherited = try shape(paragraph("a"), listStyle: """
            <a:lvl1pPr defTabSz="228600"><a:tabLst><a:tab pos="914400" algn="r"/></a:tabLst></a:lvl1pPr>
            """)
        let base = style.paragraphBase(for: inherited, sources: [], level: 0)
        let merged = try #require(inherited.text?.paragraphs.first?.properties).merged(over: base)
        #expect(merged.tabStops == [TabStop(position: 914_400, alignment: .right)])
        #expect(merged.defaultTabSize == 228_600)

        // A paragraph's own list takes the place of the inherited one.
        var own = ParagraphProperties()
        own.tabStops = [TabStop(position: 100)]
        #expect(own.merged(over: base).tabStops == [TabStop(position: 100)])
        // With nothing said anywhere, the default stops are an inch apart.
        #expect(TabLayout.defaultInterval(ParagraphProperties()) == 72)
    }

    @Test("Text after a tab lines up on left, centre, right and decimal stops")
    func aligned() throws {
        func stop(_ alignment: String) -> String {
            "<a:pPr><a:tabLst><a:tab pos=\"2540000\" algn=\"\(alignment)\"/></a:tabLst></a:pPr>"
        }
        // 2,540,000 EMU is 200 points.
        let left = try offsets(shape(paragraph("A\tLeft", properties: stop("l"))), of: ["L", "\t"])
        #expect(abs(left[0] - 200) < 0.5)

        let right = try shape(paragraph("A\tRight", properties: stop("r")))
        let rightEnd = try offsets(right, of: ["R"])[0] + width(of: "Right", in: right)
        #expect(abs(rightEnd - 200) < 0.5)

        let center = try shape(paragraph("A\tCentre", properties: stop("ctr")))
        let centerMiddle = try offsets(center, of: ["C"])[0] + width(of: "Centre", in: center) / 2
        #expect(abs(centerMiddle - 200) < 0.5)

        // The decimal point sits on the stop, however many digits come before it.
        for number in ["1234.56", "7.5"] { // Each with a 5 just after the point.
            let point = try offsets(shape(paragraph("A\t\(number)", properties: stop("dec"))), of: [".", "5"])
            #expect(point[0] <= 200 && point[1] >= 200)
            #expect(abs((point[0] + point[1]) / 2 - 200) < 0.5)
        }
    }

    @Test("Past the last stop, tabs fall every default tab size")
    func defaults() throws {
        let half = try offsets(shape(paragraph("A\tB\tC", properties: "<a:pPr defTabSz=\"457200\"/>")), of: ["B", "C"])
        #expect(abs(half[0] - 36) < 0.5)
        #expect(abs(half[1] - 72) < 0.5)
        let inch = try offsets(shape(paragraph("A\tB")), of: ["B"])
        #expect(abs(inch[0] - 72) < 0.5)
        let after = try offsets(shape(paragraph("A\tB\tC", properties: """
            <a:pPr defTabSz="457200"><a:tabLst><a:tab pos="1270000"/></a:tabLst></a:pPr>
            """)), of: ["B", "C"])
        // Past the stop at 100 points, the next default one is at 144, not 136: they fall on the grid.
        #expect(abs(after[0] - 100) < 0.5)
        #expect(abs(after[1] - 144) < 0.5)
    }

    @Test("A bullet's text still hangs at the margin, and later tabs reach the paragraph's stops")
    func bullets() throws {
        let bulleted = try shape(paragraph("Item\tNote", properties: """
            <a:pPr marL="342900" indent="-342900"><a:buChar char="•"/>\
            <a:tabLst><a:tab pos="114300"/><a:tab pos="2540000"/></a:tabLst></a:pPr>
            """))
        let places = try offsets(bulleted, of: ["I", "N"])
        // 342,900 EMU is 27 points; the stop at 9 points is short of it.
        #expect(abs(places[0] - 27) < 0.5)
        #expect(abs(places[1] - 200) < 0.5)
    }

    @Test("Stops are written and read back")
    func roundTrip() throws {
        func reread(_ shape: SlideShape) throws -> ParagraphProperties? {
            var presentation = Presentation.blank
            presentation.slides[0].shapes = [shape]
            presentation.slides[0].isModified = true
            let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
            return read.slides[0].shapes.first?.text?.paragraphs.first?.properties
        }
        let stops = [TabStop(position: 914_400, alignment: .center), TabStop(position: 1_828_800, alignment: .decimal)]

        // As read from a file, with the text edited.
        var edited = try shape(paragraph("A\tB", properties: """
            <a:pPr defTabSz="457200"><a:tabLst><a:tab pos="914400" algn="ctr"/><a:tab pos="1828800" algn="dec"/></a:tabLst></a:pPr>
            """))
        edited.edits.insert(.text)
        edited.text?.paragraphs[0].runs[0].text = "C\tD"
        let kept = try reread(edited)
        #expect(kept?.tabStops == stops)
        #expect(kept?.defaultTabSize == 457_200)

        // Made in Dazzle, with no XML of their own.
        var made = try shape(paragraph("A\tB"))
        made.source = nil
        made.text?.paragraphs[0].sourceProperties = nil
        made.text?.paragraphs[0].properties.tabStops = stops
        made.text?.paragraphs[0].properties.defaultTabSize = 228_600
        let written = try reread(made)
        #expect(written?.tabStops == stops)
        #expect(written?.defaultTabSize == 228_600)
    }

    @Test("The editor stops tabs where the slide does")
    func editor() throws {
        let shape = try shape(paragraph("A\tB", properties: """
            <a:pPr defTabSz="457200"><a:tabLst><a:tab pos="1270000" algn="r"/><a:tab pos="2540000" algn="dec"/></a:tabLst></a:pPr>
            """))
        let string = EditableText.attributedString(try #require(shape.text), shape: shape, sources: [], style: style, scale: 2, fontScale: 1, slideNumber: 1)
        let paragraphStyle = try #require(string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let stops = Array(paragraphStyle.tabStops.filter { $0.location > 0 }.prefix(3))
        // Doubled in the editor, and the default stops after on the grid.
        #expect(stops.map(\.location) == [200, 400, 432])
        #expect(stops.map(\.alignment) == [.right, .right, .left])
        #expect(stops[0].options[.columnTerminators] == nil)
        #expect((stops[1].options[.columnTerminators] as? CharacterSet)?.contains(".") == true)
        #expect(paragraphStyle.defaultTabInterval == 72)
    }

    private func width(of text: String, in shape: SlideShape) -> CGFloat {
        var run = shape.text?.paragraphs.first?.runs.first?.properties ?? RunProperties()
        run.size = run.size ?? 1_800
        let font = FontResolver.shared.font(family: style.theme.minorFont, size: CGFloat(run.size ?? 1_800) / 100, bold: false, italic: false, embedded: style.resources.embeddedFonts)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
