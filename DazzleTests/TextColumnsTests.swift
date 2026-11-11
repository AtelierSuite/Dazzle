import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Text columns")
struct TextColumnsTests {
    /// The text box's frame, in points: 400 wide, 100 tall, 100 in from the corner.
    private let box = CGRect(x: 100, y: 100, width: 400, height: 100)

    private func shapes(_ xml: String) throws -> [SlideShape] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(xml)</p:spTree>
            """.utf8))
        return ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                           parts: [:], capturesSource: true).shapes(in: root)
    }

    /// A text box with `bodyPr`'s attributes and children, holding `lines` short paragraphs of 18 point text.
    private func textBox(_ attributes: String, fit: String = "", lines: Int) throws -> SlideShape {
        let paragraphs = (1...lines).map { "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"1800\"/><a:t>Line \($0)</a:t></a:r></a:p>" }
        return try #require(shapes("""
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="5080000" cy="1270000"/></a:xfrm>
            <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
            <p:txBody><a:bodyPr wrap="square" \(attributes)>\(fit)</a:bodyPr><a:lstStyle/>\(paragraphs.joined())</p:txBody></p:sp>
            """).first)
    }

    /// Where the shape's text leaves ink, a pixel to the point.
    private struct Ink {
        var width: Int
        var height: Int
        var pixels: Data

        func count(in rect: CGRect) -> Int {
            var count = 0
            for y in max(Int(rect.minY), 0)..<min(Int(rect.maxY), height) {
                for x in max(Int(rect.minX), 0)..<min(Int(rect.maxX), width) where pixels[(y * width + x) * 4 + 3] > 128 {
                    count += 1
                }
            }
            return count
        }

        /// The topmost row with ink inside `rect`.
        func topRow(in rect: CGRect) -> CGFloat? {
            for y in max(Int(rect.minY), 0)..<min(Int(rect.maxY), height) {
                for x in max(Int(rect.minX), 0)..<min(Int(rect.maxX), width) where pixels[(y * width + x) * 4 + 3] > 128 {
                    return CGFloat(y)
                }
            }
            return nil
        }

        var bounds: CGRect {
            var (minX, minY, maxX, maxY) = (width, height, -1, -1)
            for y in 0..<height {
                for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return maxX < minX ? .null : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    private func ink(_ shape: SlideShape) throws -> Ink {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [shape]
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
        return Ink(width: width, height: height, pixels: pixels)
    }

    private var leftHalf: CGRect { CGRect(x: box.minX, y: 0, width: box.width / 2, height: 10_000) }
    private var rightHalf: CGRect { CGRect(x: box.midX, y: 0, width: box.width / 2, height: 10_000) }

    @Test("Columns, their spacing and their direction are read, and inherited when unsaid")
    func read() throws {
        let properties = try #require(textBox("numCol=\"3\" spcCol=\"457200\" rtlCol=\"1\"", lines: 1).text?.properties)
        #expect(properties.columnCount == 3)
        #expect(properties.columnSpacing == 457_200)
        #expect(properties.columnsRightToLeft == true)

        let unsaid = try #require(textBox("", lines: 1).text?.properties)
        #expect(unsaid.columnCount == nil)
        #expect(unsaid.columnSpacing == nil)
        #expect(unsaid.columnsRightToLeft == nil)
        let inherited = unsaid.merged(over: properties)
        #expect(inherited.columnCount == 3)
        #expect(inherited.columnSpacing == 457_200)
        #expect(inherited.columnsRightToLeft == true)

        let leftToRight = try #require(textBox("numCol=\"2\" rtlCol=\"0\"", lines: 1).text?.properties)
        #expect(leftToRight.columnsRightToLeft == false)
        #expect(leftToRight.merged(over: properties).columnCount == 2)
    }

    @Test("Text in two columns fills the first, then flows into the second, staying in the box")
    func flowsIntoTheNextColumn() throws {
        let single = try ink(textBox("", lines: 6))
        #expect(single.bounds.maxY > box.maxY + 10, "One column overflows the box")
        #expect(single.count(in: rightHalf) == 0)

        let columned = try ink(textBox("numCol=\"2\" spcCol=\"228600\"", lines: 6))
        #expect(columned.bounds.maxY <= box.maxY)
        #expect(columned.count(in: leftHalf) > 0)
        #expect(columned.count(in: rightHalf) > 0)
        // The second column starts at the top, level with the first.
        let first = CGRect(x: box.minX, y: box.minY, width: box.width / 2, height: box.height)
        let second = CGRect(x: box.midX, y: box.minY, width: box.width / 2, height: box.height)
        let firstTop = try #require(columned.topRow(in: first))
        let secondTop = try #require(columned.topRow(in: second))
        #expect(abs(firstTop - secondTop) <= 2)
    }

    @Test("Three columns spread the text across the box")
    func threeColumns() throws {
        let columned = try ink(textBox("numCol=\"3\"", lines: 9))
        #expect(columned.bounds.maxY <= box.maxY)
        let third = box.width / 3
        for index in 0..<3 {
            let column = CGRect(x: box.minX + CGFloat(index) * third, y: 0, width: third, height: 10_000)
            #expect(columned.count(in: column) > 0, "Column \(index + 1)")
        }
    }

    @Test("Columns running right to left start at the right")
    func rightToLeft() throws {
        let leftToRight = try ink(textBox("numCol=\"2\"", lines: 1))
        #expect(leftToRight.count(in: leftHalf) > 0)
        #expect(leftToRight.count(in: rightHalf) == 0)

        let rightToLeft = try ink(textBox("numCol=\"2\" rtlCol=\"1\"", lines: 1))
        #expect(rightToLeft.count(in: leftHalf) == 0)
        #expect(rightToLeft.count(in: rightHalf) > 0)
    }

    @Test("Shrinking to fit counts the room every column gives")
    func shrinksOnlyWhenColumnsOverflow() throws {
        // Fits in two columns: drawn as large as without fitting.
        let fits = try ink(textBox("numCol=\"2\"", fit: "<a:normAutofit/>", lines: 6))
        let unfitted = try ink(textBox("numCol=\"2\"", lines: 6))
        #expect(abs(fits.bounds.height - unfitted.bounds.height) <= 1)

        // Overflows even two columns: shrunk until it fits.
        let overflowing = try ink(textBox("numCol=\"2\"", lines: 14))
        #expect(overflowing.bounds.maxY > box.maxY + 10)
        let shrunk = try ink(textBox("numCol=\"2\"", fit: "<a:normAutofit/>", lines: 14))
        #expect(shrunk.bounds.maxY <= box.maxY + 1)
        #expect(shrunk.count(in: rightHalf) > 0)
    }

    @Test("Text in columns measures as tall as its balanced columns")
    func measuredHeight() throws {
        let presentation = Presentation.blank
        let renderer = TextRenderer(style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]), slideNumber: 1)
        let single = try textBox("", lines: 8)
        let double = try textBox("numCol=\"2\"", lines: 8)
        let oneColumn = renderer.height(of: try #require(single.text), shape: single, width: box.width)
        let twoColumns = renderer.height(of: try #require(double.text), shape: double, width: box.width)
        // Eight lines stand four to a column: half as tall, give or take the insets.
        #expect(twoColumns < oneColumn * 0.6)
        #expect(twoColumns > oneColumn * 0.4)
    }

    @Test("Columns are saved, whether the file said them or they were set in Dazzle")
    func roundTrip() throws {
        func reread(_ shape: SlideShape) throws -> BodyProperties? {
            var presentation = Presentation.blank
            presentation.slides[0].shapes = [shape]
            presentation.slides[0].isModified = true
            let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
            return read.slides[0].shapes.first?.text?.properties
        }
        // Read from a file, its text edited.
        var edited = try textBox("numCol=\"2\" spcCol=\"228600\" rtlCol=\"1\"", lines: 3)
        edited.edits.insert(.text)
        edited.text?.setPlainText("Edited\nText")
        let saved = try #require(try reread(edited))
        #expect(saved.columnCount == 2)
        #expect(saved.columnSpacing == 228_600)
        #expect(saved.columnsRightToLeft == true)

        // Made in Dazzle, with no XML of its own.
        var made = try textBox("", lines: 3)
        made.source = nil
        made.text?.properties.columnCount = 3
        made.text?.properties.columnSpacing = 91_440
        let written = try #require(try reread(made))
        #expect(written.columnCount == 3)
        #expect(written.columnSpacing == 91_440)
    }
}
