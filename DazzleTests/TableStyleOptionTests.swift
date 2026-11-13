@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

/// The table style's first column, total row, last column and banded column
/// options, beside its header row and banded rows: read, written, layered
/// as PowerPoint layers them, and turned on and off.
@MainActor
@Suite("Table style options")
struct TableStyleOptionTests {
    private let namespace = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""

    private func table(_ properties: String) throws -> SlideTable {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \(namespace)>\
            <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
            <p:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="740664"/></p:xfrm>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>\(properties)\
            <a:tblGrid><a:gridCol w="914400"/></a:tblGrid>\
            <a:tr h="370332"><a:tc><a:txBody><a:bodyPr/><a:p/></a:txBody><a:tcPr/></a:tc></a:tr>\
            </a:tbl></a:graphicData></a:graphic></p:graphicFrame></p:spTree>
            """.utf8))
        let shape = try #require(ShapeParser(
            partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces, parts: [:], capturesSource: true
        ).shapes(in: root).first)
        guard case .table(let table) = shape.kind else { throw CocoaError(.coderReadCorrupt) }
        return table
    }

    @Test("Every option on a:tblPr is read, and written back as it was")
    func readsAndWrites() throws {
        let read = try table("<a:tblPr firstRow=\"1\" lastRow=\"1\" firstCol=\"true\" lastCol=\"1\" bandCol=\"1\"/>")
        #expect(read.hasHeaderRow)
        #expect(read.hasTotalRow)
        #expect(read.hasFirstColumn)
        #expect(read.hasLastColumn)
        #expect(read.hasBandedColumns)
        #expect(!read.hasBandedRows)

        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertTable(rows: 3, columns: 3, in: &presentation)
        state.setTableOption(.totalRow, true, in: &presentation)
        state.setTableOption(.lastColumn, true, in: &presentation)
        state.setTableOption(.bandedRows, false, in: &presentation)
        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        guard case .table(let written) = try #require(copy.slides[0].shapes.last).kind else {
            Issue.record("Expected a table")
            return
        }
        #expect(written.hasHeaderRow && written.hasTotalRow && written.hasLastColumn)
        #expect(!written.hasBandedRows && !written.hasFirstColumn && !written.hasBandedColumns)
    }

    @Test("A table style's total row, edge columns, both bands and corners are read")
    func readsStyleParts() throws {
        func part(_ name: String, _ color: String) -> String {
            "<a:\(name)><a:tcStyle><a:fill><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill></a:fill></a:tcStyle></a:\(name)>"
        }
        let names = ["band1H", "band2H", "band1V", "band2V", "lastRow", "firstCol", "lastCol", "nwCell", "neCell", "swCell", "seCell"]
        let xml = "<a:tblStyle \(namespace) styleId=\"x\">"
            + names.enumerated().map { part($1, String(format: "0000%02X", $0)) }.joined() + "</a:tblStyle>"
        let style = TableStyle(element: try XMLLite.parse(Data(xml.utf8)))
        let parts = [style.bandedRow, style.evenBandedRow, style.bandedColumn, style.evenBandedColumn, style.totalRow,
                     style.firstColumn, style.lastColumn, style.topLeftCell, style.topRightCell,
                     style.bottomLeftCell, style.bottomRightCell]
        for (index, part) in parts.enumerated() {
            #expect(part.fill == .solid(.rgb(UInt32(index))))
        }
    }

    @Test("Which parts a cell falls in, with bands counted past the header row and first column")
    func regions() {
        var table = SlideTable.empty(rows: 5, columns: 5, width: 500, height: 500)
        for option in SlideTable.StyleOption.allCases { table[option] = true }
        let corner = table.regions(row: 0, column: 0)
        #expect(corner.isHeaderRow && corner.isFirstColumn && corner.rowBand == nil && corner.columnBand == nil)
        let total = table.regions(row: 4, column: 4)
        #expect(total.isTotalRow && total.isLastColumn)
        #expect(table.regions(row: 1, column: 1).rowBand == true)
        #expect(table.regions(row: 1, column: 1).columnBand == true)
        #expect(table.regions(row: 2, column: 2).rowBand == false)
        #expect(table.regions(row: 2, column: 2).columnBand == false)
        #expect(table.regions(row: 2, column: 2).builtInTint == 20_000)
        #expect(table.regions(row: 1, column: 2).builtInTint == 40_000)
        #expect(table.regions(row: 4, column: 2).builtInTint == nil)

        table.hasFirstColumn = false
        table.hasHeaderRow = false
        #expect(table.regions(row: 0, column: 0).rowBand == true)
        #expect(table.regions(row: 0, column: 0).columnBand == true)
        #expect(!table.regions(row: 0, column: 0).isEmphasised)
    }

    @Test("Parts layer as PowerPoint's do: corners, then the header and total rows, edge columns, bands, the table")
    func precedence() {
        var style = TableStyle()
        style.whole.fill = .solid(.rgb(0x000000))
        style.whole.textColor = .rgb(0x111111)
        style.bandedColumn.fill = .solid(.rgb(0xBBBBBB))
        style.bandedRow.fill = .solid(.rgb(0xAAAAAA))
        style.firstColumn.fill = .solid(.rgb(0xFC0000))
        style.firstColumn.isBold = true
        style.totalRow.fill = .solid(.rgb(0x707070))
        style.totalRow.borders["top"] = LineStyle(fill: .solid(.rgb(0x0000FF)), width: 38_100)
        style.headerRow.fill = .solid(.rgb(0xFFFFFF))
        style.bottomLeftCell.fill = .solid(.rgb(0xC0C0C0))

        var table = SlideTable.empty(rows: 4, columns: 4, width: 400, height: 400)
        for option in SlideTable.StyleOption.allCases { table[option] = true }
        #expect(style.fill(for: table.regions(row: 0, column: 0)) == .solid(.rgb(0xFFFFFF)))
        #expect(style.fill(for: table.regions(row: 3, column: 0)) == .solid(.rgb(0xC0C0C0)))
        #expect(style.fill(for: table.regions(row: 3, column: 2)) == .solid(.rgb(0x707070)))
        #expect(style.fill(for: table.regions(row: 1, column: 0)) == .solid(.rgb(0xFC0000)))
        #expect(style.isBold(for: table.regions(row: 1, column: 0)) == true)
        #expect(style.fill(for: table.regions(row: 1, column: 1)) == .solid(.rgb(0xAAAAAA)))
        #expect(style.fill(for: table.regions(row: 2, column: 1)) == .solid(.rgb(0xBBBBBB)))
        #expect(style.fill(for: table.regions(row: 2, column: 2)) == .solid(.rgb(0x000000)))
        #expect(style.textColor(for: table.regions(row: 2, column: 1)) == .rgb(0x111111))
        #expect(style.border("top", for: table.regions(row: 3, column: 1))?.width == 38_100)
        #expect(style.border("top", for: table.regions(row: 2, column: 1)) == nil)
    }

    @Test("A built-in style sets a first column's text bold and light, as it does its header's")
    func builtInText() {
        var table = SlideTable.empty(rows: 3, columns: 3, width: 914_400, height: 914_400)
        table.hasFirstColumn = true
        for row in table.rows.indices {
            table.rows[row].cells[0].text = TextBody(paragraphs: [Paragraph(runs: [TextRun(text: "A")])])
            table.rows[row].cells[1].text = TextBody(paragraphs: [Paragraph(runs: [TextRun(text: "B")])])
        }
        let presentation = Presentation.blank
        let layout = TableLayout(table: table, frame: CGRect(x: 0, y: 0, width: 72, height: 72),
                                 style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]),
                                 presentation: presentation, slideNumber: 1)
        let first = layout.body(for: table.rows[1].cells[0], row: 1, column: 0)?.paragraphs[0].runs[0].properties
        #expect(first?.isBold == true)
        #expect(first?.color == .scheme("lt1"))
        let second = layout.body(for: table.rows[1].cells[1], row: 1, column: 1)?.paragraphs[0].runs[0].properties
        #expect(second?.isBold == nil)
    }

    @Test("The canvas menu offers every option and toggles it")
    func menu() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        state.insertTable(rows: 2, columns: 2, in: &presentation)
        state.perform(.tableOption(.bandedColumns), in: &presentation)
        #expect(state.selectedTable(in: presentation)?.hasBandedColumns == true)
        let menu = try #require(state.canvasMenu(in: presentation, canPaste: false))
        #expect(menu.tableItems.first { $0.action == .tableOption(.bandedColumns) }?.isOn == true)
        #expect(menu.tableItems.first { $0.action == .tableOption(.firstColumn) }?.isOn == false)
    }
}
