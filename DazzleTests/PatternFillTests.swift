import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Pattern fills")
@MainActor
struct PatternFillTests {
    private let stripes = Fill.Pattern(preset: "dkUpDiag", foreground: .scheme("accent2"), background: .rgb(0xFFEECC))

    @Test("A pattern fill is read with its preset and both colours, and written back the same")
    func parsing() throws {
        let element = try XMLLite.parse(Data("""
            <pattFill prst="ltDnDiag"><fgClr><srgbClr val="FF0000"/></fgClr><bgClr><schemeClr val="bg1"/></bgClr></pattFill>
            """.utf8))
        let fill = Fill.parse(element: element, image: { _ in nil })
        #expect(fill == .pattern(Fill.Pattern(preset: "ltDnDiag", foreground: .rgb(0xFF0000), background: .scheme("bg1"))))
        let xml = try #require(fill).xml
        let written = try #require(XMLLite.fragment(xml, namespaces: OOXML.namespaces))
        #expect(Fill.parse(element: written, image: { _ in nil }) == fill)

        // Without colours, black on white; an unknown preset is kept as it is.
        let bare = try XMLLite.parse(Data("<pattFill prst=\"newThing\"/>".utf8))
        #expect(Fill.parse(element: bare, image: { _ in nil })
            == .pattern(Fill.Pattern(preset: "newThing", foreground: .rgb(0x000000), background: .rgb(0xFFFFFF))))
    }

    @Test("Every DrawingML preset has its eight rows, and the percentages darken in turn")
    func presets() {
        #expect(Fill.Pattern.presetNames.count == 54)
        #expect(Set(Fill.Pattern.presetNames).count == 54)
        #expect(Set(Fill.Pattern.presetNames) == Set(Fill.Pattern.presets.keys))
        for name in Fill.Pattern.presetNames {
            #expect(Fill.Pattern.presets[name]?.count == 8, "\(name)")
        }
        func coverage(_ name: String) -> Int { Fill.Pattern(preset: name).rows.reduce(0) { $0 + $1.nonzeroBitCount } }
        let percentages = [5, 10, 20, 25, 30, 40, 50, 60, 70, 75, 80, 90]
        let covered = percentages.map { coverage("pct\($0)") }
        #expect(covered == covered.sorted() && Set(covered).count == covered.count)
        for (percentage, cells) in zip(percentages, covered) {
            // Windows' own cells, which these follow, are only roughly their names.
            #expect(abs(Double(cells) / 64 - Double(percentage) / 100) < 0.15, "pct\(percentage)")
        }
        // A downward diagonal runs from the top left; an upward one from the bottom left.
        #expect(Fill.Pattern(preset: "dnDiag").isForeground(column: 0, row: 0))
        #expect(Fill.Pattern(preset: "upDiag").isForeground(column: 0, row: 7))
        #expect(Fill.Pattern(preset: "unknown").rows == Fill.Pattern(preset: "pct50").rows)
    }

    @Test("A pattern is drawn cell by cell from the top left of its area, in its two colours")
    func drawing() throws {
        // Four pixels to a cell, the area starting a cell across and two down.
        let scale = 4 / CGFloat(Fill.Pattern.cellSize)
        let size = 80
        let canvas = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(size))
        canvas.scaleBy(x: scale, y: -scale)
        let cell = CGFloat(Fill.Pattern.cellSize)
        let bounds = CGRect(x: cell, y: cell * 2, width: cell * 18, height: cell * 18)
        canvas.clip(to: bounds)
        for preset in ["wave", "lgCheck", "dnDiag", "shingle"] {
            let pattern = Fill.Pattern(preset: preset)
            PatternFill.draw(pattern, foreground: RGBAColor(red: 1, green: 0, blue: 0),
                             background: RGBAColor(red: 0, green: 0, blue: 1), in: bounds, context: canvas)
            let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
            for row in 0..<18 {
                for column in 0..<18 {
                    // The middle of the cell, in pixels from the top left.
                    let x = (column + 1) * 4 + 2, y = (row + 2) * 4 + 2
                    let offset = y * canvas.bytesPerRow + x * 4
                    let isRed = pixels[offset] > 200 && pixels[offset + 2] < 50
                    let isBlue = pixels[offset + 2] > 200 && pixels[offset] < 50
                    #expect(pattern.isForeground(column: column, row: row) ? isRed : isBlue, "\(preset) \(column), \(row)")
                }
            }
        }
    }

    @Test("Pattern fills on a shape, a table cell and the background survive saving")
    func saving() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertShape("rect", in: &presentation)
        state.setFill(.pattern(stripes), in: &presentation)
        let checks = Fill.Pattern(preset: "smCheck", foreground: .rgb(0x112233), background: .scheme("accent1"))
        state.setBackground(.pattern(checks), in: &presentation)
        state.insertTable(rows: 2, columns: 2, in: &presentation)
        state.selectCell(TableCellPosition(row: 1, column: 1))
        let grid = Fill.Pattern(preset: "smGrid", foreground: .rgb(0x00AA00), background: .rgb(0xFFFFFF))
        state.setCellFill(.pattern(grid), in: &presentation)

        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let shapes = copy.slides[0].shapes
        #expect(shapes.contains { $0.fill == .pattern(stripes) })
        #expect(copy.slides[0].background == .fill(.pattern(checks)))
        guard case .table(let table) = try #require(shapes.last).kind else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.rows[1].cells[1].fill == .pattern(grid))

        // Editing something else in a cell read from the file keeps its pattern.
        var reread = copy
        let reopened = EditorState()
        reopened.selectSlide(reread.slides[0].id)
        reopened.selectedShapeID = reread.slides[0].shapes.last?.id
        reopened.selectCell(TableCellPosition(row: 0, column: 0))
        reopened.setCellFill(.solid(.rgb(0xFF0000)), in: &reread)
        let final = try PPTXReader.presentation(from: PPTXWriter.data(from: reread))
        guard case .table(let finalTable) = try #require(final.slides[0].shapes.last).kind else {
            Issue.record("Expected a table")
            return
        }
        #expect(finalTable.rows[1].cells[1].fill == .pattern(grid))
        #expect(final.slides[0].shapes.contains { $0.fill == .pattern(stripes) })
    }

    @Test("A shape with a pattern fill is drawn in both of its colours")
    func rendering() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertShape("rect", in: &presentation)
        state.setFill(.pattern(Fill.Pattern(preset: "pct50", foreground: .rgb(0xFF0000), background: .rgb(0x0000FF))), in: &presentation)
        let shape = try #require(presentation.slides[0].shapes.last)
        // Drawn at more than full size, so each cell covers two whole pixels.
        let slide = presentation.slideSize
        let scale = 2 / CGFloat(Fill.Pattern.cellSize)
        let width = Int(EMU.points(slide.width) * scale), height = Int(EMU.points(slide.height) * scale)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: CGSize(width: width, height: height))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        let left = Int(EMU.points(shape.frame.x) * scale), top = Int(EMU.points(shape.frame.y) * scale)
        var colors = Set<String>()
        for row in 2..<10 {
            for column in 2..<10 {
                let x = left + column * 2 + 1, y = top + row * 2 + 1
                let offset = y * canvas.bytesPerRow + x * 4
                colors.insert(pixels[offset] > 200 && pixels[offset + 2] < 50 ? "red" : pixels[offset + 2] > 200 && pixels[offset] < 50 ? "blue" : "other")
            }
        }
        #expect(colors == ["red", "blue"])
    }
}
