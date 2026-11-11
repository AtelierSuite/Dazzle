import CoreGraphics
@testable import Dazzle
import Testing

@Suite("Table size picker")
struct TableSizeSelectionTests {
    @Test("Starts at three by three on a grid with room to grow")
    func initialSize() {
        let selection = TableSizeSelection()
        #expect(selection.rows == 3)
        #expect(selection.columns == 3)
        #expect(selection.gridRows == TableSizeSelection.initialGrid.rows)
        #expect(selection.gridColumns == TableSizeSelection.initialGrid.columns)
    }

    @Test("Sizes stay within the limits")
    func limits() {
        var selection = TableSizeSelection(rows: 0, columns: -4)
        #expect(selection.rows == 1)
        #expect(selection.columns == 1)
        selection.move(.up)
        selection.move(.left)
        #expect(selection.rows == 1)
        #expect(selection.columns == 1)
        selection.set(rows: 500, columns: 500)
        #expect(selection.rows == TableSizeSelection.rowLimit.upperBound)
        #expect(selection.columns == TableSizeSelection.columnLimit.upperBound)
        selection.move(.down)
        selection.move(.right)
        #expect(selection.rows == TableSizeSelection.rowLimit.upperBound)
        #expect(selection.columns == TableSizeSelection.columnLimit.upperBound)
    }

    @Test("Picking a cell selects up to it, and the steppers follow")
    func pickingCells() {
        var selection = TableSizeSelection()
        selection.select(row: 1, column: 3)
        #expect(selection.rows == 2)
        #expect(selection.columns == 4)
        #expect(selection.contains(row: 1, column: 3))
        #expect(!selection.contains(row: 2, column: 3))
        #expect(!selection.contains(row: 1, column: 4))
        selection.set(rows: 7)
        #expect(selection.rows == 7)
        #expect(selection.columns == 4)
    }

    @Test("The grid grows near its edge, up to its largest, and doesn't shrink back")
    func growth() {
        var selection = TableSizeSelection()
        selection.select(row: 4, column: 5)
        #expect(selection.gridRows == 6)
        #expect(selection.gridColumns == 7)
        selection.select(row: 0, column: 0)
        #expect(selection.gridRows == 6)
        #expect(selection.gridColumns == 7)
        selection.select(row: 40, column: 40)
        #expect(selection.rows == TableSizeSelection.largestGrid.rows)
        #expect(selection.columns == TableSizeSelection.largestGrid.columns)
        #expect(selection.gridRows == TableSizeSelection.largestGrid.rows)
        selection.set(rows: 30, columns: 20)
        #expect(selection.gridRows == TableSizeSelection.largestGrid.rows)
        #expect(selection.gridColumns == TableSizeSelection.largestGrid.columns)
    }

    @Test("Points map to the cells under them")
    func cells() throws {
        #expect(TableSizeSelection.cell(at: CGPoint(x: -1, y: 4), pitch: 20) == nil)
        let cell = try #require(TableSizeSelection.cell(at: CGPoint(x: 45, y: 5), pitch: 20))
        #expect(cell.row == 0)
        #expect(cell.column == 2)
        let far = try #require(TableSizeSelection.cell(at: CGPoint(x: 5_000, y: 5_000), pitch: 20))
        #expect(far.row == TableSizeSelection.largestGrid.rows - 1)
        #expect(far.column == TableSizeSelection.largestGrid.columns - 1)
    }

    @Test("Labels give columns before rows")
    func labels() {
        let selection = TableSizeSelection(rows: 2, columns: 5)
        #expect(selection.label == "5 × 2")
        #expect(selection.spokenLabel.contains("5"))
        #expect(selection.spokenLabel.contains("2"))
    }
}
