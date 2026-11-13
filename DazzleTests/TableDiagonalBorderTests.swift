import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

/// A cell's `lnTlToBr` and `lnBlToTr`: lines across it from corner to corner.
@Suite("Table diagonal borders")
struct TableDiagonalBorderTests {
    /// The widescreen slide, 960 × 540 points, drawn at a fifth of its size.
    private let size = CGSize(width: 192, height: 108)

    private func table(_ cells: [String], style: String = "") throws -> SlideShape {
        let width = 12_192_000 / cells.count
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
            <p:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="6858000"/></p:xfrm>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr>\(style)</a:tblPr>\
            <a:tblGrid>\(String(repeating: "<a:gridCol w=\"\(width)\"/>", count: cells.count))</a:tblGrid><a:tr h="6858000">\
            \(cells.map { "<a:tc><a:txBody><a:bodyPr/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></a:txBody><a:tcPr>\($0)</a:tcPr></a:tc>" }.joined())\
            </a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame></p:spTree>
            """.utf8))
        return try #require(ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                                        parts: [:], capturesSource: true).shapes(in: root).first)
    }

    private func line(_ name: String, width: Int, color: String) -> String {
        "<a:\(name) w=\"\(width)\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill></a:\(name)>"
    }

    private func render(_ shape: SlideShape) throws -> (pixels: Data, bytesPerRow: Int) {
        var presentation = Presentation.blank
        presentation.slideSize = .widescreen
        presentation.slides[0].shapes = [shape]
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Drawn top-down, as on screen, so the first row of pixels is the top of the slide.
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: size)
        return (try #require(canvas.makeImage()?.dataProvider?.data as Data?), canvas.bytesPerRow)
    }

    private func pixel(_ image: (pixels: Data, bytesPerRow: Int), x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = y * image.bytesPerRow + x * 4
        return (image.pixels[offset], image.pixels[offset + 1], image.pixels[offset + 2], image.pixels[offset + 3])
    }

    @Test("Both diagonals are read from the cell")
    func reads() throws {
        let shape = try table([line("lnTlToBr", width: 12_700, color: "FF0000") + line("lnBlToTr", width: 38_100, color: "0000FF")])
        guard case .table(let table) = shape.kind else { Issue.record("not a table"); return }
        let cell = table.rows[0].cells[0]
        #expect(cell.borderDiagonalDown?.fill == .solid(.rgb(0xFF0000)))
        #expect(cell.borderDiagonalDown?.width == 12_700)
        #expect(cell.borderDiagonalUp?.fill == .solid(.rgb(0x0000FF)))
        #expect(cell.borderDiagonalUp?.width == 38_100)
    }

    @Test("Each diagonal is drawn corner to corner, and only the ones the cell has")
    func draws() throws {
        // Two cells, each 96 × 108 pixels: a red line down the left, a blue one up the right.
        let image = try render(table([
            line("lnTlToBr", width: 254_000, color: "FF0000"),
            line("lnBlToTr", width: 254_000, color: "0000FF"),
        ]))
        let down = pixel(image, x: 48, y: 54)
        #expect(down.a == 255 && down.r > 200 && down.b < 50)
        let up = pixel(image, x: 144, y: 54)
        #expect(up.a == 255 && up.b > 200 && up.r < 50)
        #expect(pixel(image, x: 24, y: 81).a == 0) // No line up the left cell,
        #expect(pixel(image, x: 120, y: 27).a == 0) // nor down the right one.
    }

    @Test("A table in PowerPoint's built-in look gets no diagonals of its own")
    func builtInLook() throws {
        let image = try render(table([""], style: "<a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId>"))
        let middle = pixel(image, x: 96, y: 54)
        #expect(!(middle.r > 240 && middle.g > 240 && middle.b > 240))
    }

    @Test("A table style's tl2br and tr2bl are read")
    func styleDiagonals() throws {
        let style = TableStyle(element: try XMLLite.parse(Data("""
            <a:tblStyle xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" styleId="x"><a:wholeTbl><a:tcStyle><a:tcBdr>\
            <a:tl2br><a:ln w="12700"><a:solidFill><a:srgbClr val="00FF00"/></a:solidFill></a:ln></a:tl2br>\
            <a:tr2bl><a:lnRef idx="1"><a:schemeClr val="accent2"/></a:lnRef></a:tr2bl></a:tcBdr></a:tcStyle></a:wholeTbl></a:tblStyle>
            """.utf8)))
        #expect(style.whole.borders["tl2br"]?.fill == .solid(.rgb(0x00FF00)))
        #expect(style.whole.borders["tr2bl"]?.fill == .solid(.scheme("accent2")))
    }

    @Test("Diagonals survive saving an edited table")
    func saves() throws {
        var shape = try table([line("lnTlToBr", width: 25_400, color: "FF0000") + line("lnBlToTr", width: 25_400, color: "00AA00")])
        guard case .table(var table) = shape.kind else { Issue.record("not a table"); return }
        table.rows[0].cells[0].text = TextBody(paragraphs: [Paragraph(runs: [TextRun(text: "Edited")])])
        shape.kind = .table(table)
        shape.edits.insert(.table)
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [shape]
        presentation.slides[0].isModified = true
        let saved = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        guard case .table(let reread) = try #require(saved.slides[0].shapes.first).kind else { Issue.record("not a table"); return }
        #expect(reread.rows[0].cells[0].borderDiagonalDown?.fill == .solid(.rgb(0xFF0000)))
        #expect(reread.rows[0].cells[0].borderDiagonalUp?.fill == .solid(.rgb(0x00AA00)))
        #expect(reread.rows[0].cells[0].text?.plainText == "Edited")
    }
}
