import CoreGraphics
import CoreText
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing
import UIKit

@Suite("Complex-script fonts and right-to-left paragraphs")
struct RightToLeftTextTests {
    /// How wide the text is laid out, in points.
    private let width: CGFloat = 480

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

    private func paragraph(_ text: String, properties: String = "", fonts: String = "", run: String = "") -> String {
        "<a:p>\(properties)<a:r><a:rPr lang=\"ar-SA\" sz=\"1800\" \(run)>\(fonts)</a:rPr><a:t>\(text)</a:t></a:r></a:p>"
    }

    private var style: SlideStyleContext {
        let presentation = Presentation.blank
        return SlideStyleContext(presentation: presentation, slide: presentation.slides[0])
    }

    private func string(_ shape: SlideShape) throws -> NSAttributedString {
        TextRenderer(style: style, slideNumber: 1)
            .attributedString(try #require(shape.text), shape: shape, sources: [], scale: 1, spacingReduction: 0, colorOverride: nil)
    }

    /// The first line of `shape`'s text, and where it starts from the left of the text.
    private func firstLine(_ shape: SlideShape) throws -> (line: CTLine, x: CGFloat, text: NSString) {
        let string = try string(shape)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 400), transform: nil), nil)
        let line = try #require((CTFrameGetLines(frame) as? [CTLine])?.first)
        var origin = CGPoint.zero
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 1), &origin)
        return (line, origin.x, string.string as NSString)
    }

    /// Where each of `characters` in the first line begins, in points from the
    /// left of the text: its left edge when it reads left to right, its right edge when right to left.
    private func offsets(_ shape: SlideShape, of characters: [String]) throws -> [CGFloat] {
        let (line, x, text) = try firstLine(shape)
        return characters.map { x + CTLineGetOffsetForStringIndex(line, text.range(of: $0).location, nil) }
    }

    /// The left and right ends of the first line's letters, in points from the left of the text.
    private func ends(_ shape: SlideShape) throws -> (left: CGFloat, right: CGFloat) {
        let (line, x, _) = try firstLine(shape)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
        return (x, x + width)
    }

    private func family(_ string: NSAttributedString, at text: String) throws -> String {
        let index = (string.string as NSString).range(of: text).location
        let font = try #require(string.attribute(.init(kCTFontAttributeName as String), at: index, effectiveRange: nil))
        return CTFontCopyFamilyName(font as! CTFont) as String // swiftlint:disable:this force_cast
    }

    @Test("The complex-script typeface and the direction are read, and inherited when unsaid")
    func read() throws {
        let read = try shape(paragraph("مرحبا", properties: "<a:pPr algn=\"r\" rtl=\"1\"/>",
                                       fonts: "<a:latin typeface=\"Georgia\"/><a:cs typeface=\"Damascus\"/>"))
        let first = try #require(read.text?.paragraphs.first)
        #expect(first.properties.isRightToLeft == true)
        #expect(first.runs.first?.properties.complexScriptFont == "Damascus")
        #expect(first.runs.first?.properties.latinFont == "Georgia")

        let unsaid = try shape(paragraph("Hello"), listStyle: """
            <a:lvl1pPr rtl="1"><a:defRPr><a:cs typeface="Arial Hebrew"/></a:defRPr></a:lvl1pPr>
            """)
        let own = try #require(unsaid.text?.paragraphs.first?.properties)
        #expect(own.isRightToLeft == nil)
        #expect(unsaid.text?.paragraphs.first?.runs.first?.properties.complexScriptFont == nil)
        let merged = own.merged(over: style.paragraphBase(for: unsaid, sources: [], level: 0))
        #expect(merged.isRightToLeft == true)
        #expect(merged.defaultRun.complexScriptFont == "Arial Hebrew")

        let leftToRight = try #require(shape(paragraph("Hello", properties: "<a:pPr rtl=\"0\"/>")).text?.paragraphs.first?.properties)
        #expect(leftToRight.isRightToLeft == false)
        #expect(leftToRight.merged(over: merged).isRightToLeft == false)

        // Left and right are as the file names them whichever way the paragraph
        // reads; one that says nothing sits at the side it reads from.
        var properties = ParagraphProperties()
        #expect(properties.effectiveAlignment == .left)
        properties.isRightToLeft = true
        #expect(properties.effectiveAlignment == .right)
        properties.alignment = .left
        #expect(properties.effectiveAlignment == .left)
    }

    @Test("Complex-script letters are told from the rest, with the spaces and punctuation among them")
    func stretches() {
        #expect(ComplexScript.stretches(in: "Hello, world 123") == [])
        #expect(ComplexScript.stretches(in: "مرحبا بالعالم") == [.init(range: 0..<13, script: "Arab")])
        // Latin words and digits keep their own typeface; the space before them is theirs too.
        #expect(ComplexScript.stretches(in: "يعمل Dazzle مع 2024") == [
            .init(range: 0..<4, script: "Arab"), .init(range: 12..<14, script: "Arab"),
        ])
        // Punctuation ending the text goes with the letters before it.
        #expect(ComplexScript.stretches(in: "Dazzle: שלום עולם!") == [.init(range: 8..<18, script: "Hebr")])
        // One script after another, each its own.
        #expect(ComplexScript.stretches(in: "שלום مرحبا สวัสดี").map(\.script) == ["Hebr", "Arab", "Thai"])
        #expect(ComplexScript.isUsed(in: "abc ก") && !ComplexScript.isUsed(in: "abc 日本語"))
    }

    @Test("Arabic and Hebrew are set in the run's complex-script typeface, and Latin in its Latin one")
    func typefaces() throws {
        let fonts = "<a:latin typeface=\"Georgia\"/><a:cs typeface=\"Damascus\"/>"
        let mixed = try string(shape(paragraph("يعمل Dazzle مع Keynote", fonts: fonts)))
        #expect(try family(mixed, at: "يعمل") == "Damascus")
        #expect(try family(mixed, at: "مع") == "Damascus")
        #expect(try family(mixed, at: "Dazzle") == "Georgia")
        #expect(try family(mixed, at: "Keynote") == "Georgia")

        let hebrew = try string(shape(paragraph("שלום Dazzle", fonts: "<a:latin typeface=\"Georgia\"/><a:cs typeface=\"Arial Hebrew\"/>")))
        #expect(try family(hebrew, at: "שלום") == "Arial Hebrew")
        #expect(try family(hebrew, at: "Dazzle") == "Georgia")

        // The bullet's number and the text typed in the editor follow suit.
        let editing = try shape(paragraph("يعمل Dazzle", fonts: fonts))
        let edited = EditableText.attributedString(try #require(editing.text), shape: editing, sources: [], style: style,
                                                   scale: 1, fontScale: 1, slideNumber: 1)
        #expect((edited.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.familyName == "Damascus")
        #expect((edited.attribute(.font, at: 5, effectiveRange: nil) as? UIFont)?.familyName == "Georgia")
    }

    @Test("Theme references take the theme's complex-script font, or the one it names for the script")
    func themeFonts() {
        var theme = Theme.office
        // Nothing named: the text stays in its Latin typeface.
        #expect(theme.complexScriptTypeface("+mn-cs", script: "Arab") == nil)
        #expect(theme.complexScriptTypeface(nil, script: "Arab") == nil)
        theme.minorScriptFonts = ["Arab": "Arial", "Hebr": "Arial Hebrew"]
        theme.majorScriptFonts = ["Arab": "Times New Roman"]
        #expect(theme.complexScriptTypeface("+mn-cs", script: "Arab") == "Arial")
        #expect(theme.complexScriptTypeface("+mn-cs", script: "Hebr") == "Arial Hebrew")
        #expect(theme.complexScriptTypeface("+mj-cs", script: "Arab") == "Times New Roman")
        #expect(theme.complexScriptTypeface("+mj-cs", script: "Thai") == nil)
        theme.minorComplexScriptFont = "Damascus"
        #expect(theme.complexScriptTypeface("+mn-cs", script: "Hebr") == "Damascus")
        #expect(theme.typeface("+mn-cs") == "Damascus")
        // A typeface named outright is used as it is.
        #expect(theme.complexScriptTypeface("Geeza Pro", script: "Arab") == "Geeza Pro")
    }

    @Test("A right-to-left paragraph reads from the right, Latin words within it left to right")
    func mixedDirections() throws {
        let rightToLeft = try shape(paragraph("ابجد Dazzle هوز", properties: "<a:pPr algn=\"r\" rtl=\"1\"/>"))
        let places = try offsets(rightToLeft, of: ["ا", "D", "z", "ه"])
        // The first letter starts at the right edge, and the words follow leftwards.
        #expect(abs(places[0] - width) < 0.5)
        #expect(places[0] > places[2] && places[2] > places[1] && places[1] > places[3])

        // The same text in a left-to-right paragraph starts with its Arabic at the left.
        let leftToRight = try shape(paragraph("ابجد Dazzle هوز", properties: "<a:pPr algn=\"l\" rtl=\"0\"/>"))
        let others = try offsets(leftToRight, of: ["د", "D", "z", "ز"])
        #expect(abs(others[0]) < 0.5)
        #expect(others[0] < others[1] && others[1] < others[2] && others[2] < others[3])
    }

    @Test("Left and right alignment stay as named, whichever way the paragraph reads")
    func alignment() throws {
        let right = try ends(shape(paragraph("مرحبا بالعالم", properties: "<a:pPr algn=\"r\" rtl=\"1\"/>")))
        #expect(abs(right.right - width) < 0.5)
        let left = try ends(shape(paragraph("مرحبا بالعالم", properties: "<a:pPr algn=\"l\" rtl=\"1\"/>")))
        #expect(abs(left.left) < 0.5)
        #expect(left.right < width / 2)
        let center = try ends(shape(paragraph("مرحبا بالعالم", properties: "<a:pPr algn=\"ctr\" rtl=\"1\"/>")))
        #expect(abs((center.left + center.right) / 2 - width / 2) < 0.5)
    }

    @Test("The margin, indent, bullet and tab stops of a right-to-left paragraph are measured from the right")
    func marginsAndBullets() throws {
        // 457,200 EMU is 36 points.
        let bulleted = try shape(paragraph("مرحبا", properties: """
            <a:pPr marL="457200" indent="-457200" algn="r" rtl="1"><a:buChar char="•"/></a:pPr>
            """))
        let places = try offsets(bulleted, of: ["•", "م"])
        // The bullet hangs at the right edge; the text starts a margin in from it.
        #expect(abs(places[0] - width) < 0.5)
        #expect(abs(places[1] - (width - 36)) < 0.5)

        // A number's full stop follows it as it reads: to its left.
        let numbered = try shape(paragraph("مرحبا", properties: """
            <a:pPr marL="457200" indent="-457200" algn="r" rtl="1"><a:buAutoNum type="arabicPeriod"/></a:pPr>
            """))
        let number = try offsets(numbered, of: ["1", ".", "م"])
        #expect(number[1] < number[0])
        #expect(abs(number[2] - (width - 36)) < 0.5)

        let indented = try shape(paragraph("مرحبا", properties: "<a:pPr marL=\"914400\" algn=\"r\" rtl=\"1\"/>"))
        #expect(abs(try ends(indented).right - (width - 72)) < 0.5)

        // 2,540,000 EMU is 200 points: the text after the tab starts that far from the right.
        let tabbed = try shape(paragraph("اسم\tقيمة", properties: """
            <a:pPr algn="r" rtl="1"><a:tabLst><a:tab pos="2540000" algn="l"/></a:tabLst></a:pPr>
            """))
        #expect(abs(try offsets(tabbed, of: ["ق"])[0] - (width - 200)) < 0.5)
        // And ends there on a right stop.
        let ending = try shape(paragraph("اسم\tقيمة", properties: """
            <a:pPr algn="r" rtl="1"><a:tabLst><a:tab pos="2540000" algn="r"/></a:tabLst></a:pPr>
            """))
        #expect(try offsets(ending, of: ["ق"])[0] > width - 200 + 5)
        #expect(abs(try ends(ending).left - (width - 200)) < 0.5)
    }

    @Test("The direction and the complex-script typeface are written and read back")
    func roundTrip() throws {
        func reread(_ shape: SlideShape) throws -> Paragraph? {
            var presentation = Presentation.blank
            presentation.slides[0].shapes = [shape]
            presentation.slides[0].isModified = true
            let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
            return read.slides[0].shapes.first?.text?.paragraphs.first
        }

        // As read from a file, with the text edited.
        var edited = try shape(paragraph("مرحبا", properties: "<a:pPr algn=\"r\" rtl=\"1\"/>",
                                         fonts: "<a:latin typeface=\"Georgia\"/><a:cs typeface=\"Damascus\" pitchFamily=\"2\"/>"))
        edited.edits.insert(.text)
        edited.text?.paragraphs[0].runs[0].text = "أهلا"
        let kept = try reread(edited)
        #expect(kept?.properties.isRightToLeft == true)
        #expect(kept?.runs.first?.properties.complexScriptFont == "Damascus")
        #expect(kept?.runs.first?.sourceProperties?.contains("pitchFamily=\"2\"") == true)

        // Made in Dazzle, with no XML of their own, the typefaces in the schema's order.
        var made = try shape(paragraph("مرحبا"))
        made.source = nil
        made.edits.insert(.text)
        made.text?.paragraphs[0].sourceProperties = nil
        made.text?.paragraphs[0].properties.isRightToLeft = true
        made.text?.paragraphs[0].properties.alignment = .right
        made.text?.paragraphs[0].runs[0].sourceProperties = nil
        made.text?.paragraphs[0].runs[0].properties.latinFont = "Georgia"
        made.text?.paragraphs[0].runs[0].properties.complexScriptFont = "Arial Hebrew"
        let written = try reread(made)
        #expect(written?.properties.isRightToLeft == true)
        #expect(written?.properties.alignment == .right)
        #expect(written?.runs.first?.properties.complexScriptFont == "Arial Hebrew")
        let source = try #require(written?.runs.first?.sourceProperties)
        let latin = try #require(source.range(of: "<a:latin"))
        let complex = try #require(source.range(of: "<a:cs"))
        #expect(latin.lowerBound < complex.lowerBound)

        // Turned back left to right, it says so rather than inheriting.
        made.text?.paragraphs[0].properties.isRightToLeft = false
        #expect(try reread(made)?.properties.isRightToLeft == false)
    }

    @Test("Choosing a typeface sets it for complex-script text too") @MainActor
    func choosingATypeface() throws {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [try shape(paragraph("مرحبا Dazzle", fonts: "<a:cs typeface=\"Damascus\"/>"))]
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.selectAllShapes(in: presentation)
        state.setFontFamily("Arial Hebrew", in: &presentation)
        var run = try #require(presentation.slides[0].shapes[0].text?.paragraphs.first?.runs.first?.properties)
        #expect(run.latinFont == "Arial Hebrew")
        #expect(run.complexScriptFont == "Arial Hebrew")
        state.setFontFamily("+mj-lt", in: &presentation)
        run = try #require(presentation.slides[0].shapes[0].text?.paragraphs.first?.runs.first?.properties)
        #expect(run.latinFont == "+mj-lt")
        #expect(run.complexScriptFont == "+mj-cs")
    }

    @Test("The editor types a right-to-left paragraph from the right")
    func editor() throws {
        let rightToLeft = try shape(paragraph("مرحبا", properties: "<a:pPr marL=\"457200\" algn=\"r\" rtl=\"1\"/>"))
        let string = EditableText.attributedString(try #require(rightToLeft.text), shape: rightToLeft, sources: [], style: style,
                                                   scale: 2, fontScale: 1, slideNumber: 1)
        let paragraphStyle = try #require(string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraphStyle.baseWritingDirection == .rightToLeft)
        #expect(paragraphStyle.alignment == .right)
        #expect(paragraphStyle.headIndent == 72)

        let leftToRight = try shape(paragraph("مرحبا", properties: "<a:pPr rtl=\"0\"/>"))
        let other = EditableText.attributedString(try #require(leftToRight.text), shape: leftToRight, sources: [], style: style,
                                                  scale: 2, fontScale: 1, slideNumber: 1)
        let otherStyle = try #require(other.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(otherStyle.baseWritingDirection == .leftToRight)
        #expect(otherStyle.alignment == .left)
    }
}
