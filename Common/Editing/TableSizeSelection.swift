import Foundation

/// The rows and columns picked for a new table, and the grid of cells the
/// picker shows them on. The grid starts small and grows to keep a spare row
/// and column past the selection, up to its largest; sizes past the grid are
/// reached with the steppers.
struct TableSizeSelection: Equatable, Sendable {
    static let rowLimit = 1...50
    static let columnLimit = 1...30
    /// The grid's size when the picker opens.
    static let initialGrid = (rows: 5, columns: 6)
    /// The most cells the grid grows to.
    static let largestGrid = (rows: 10, columns: 10)

    private(set) var rows: Int
    private(set) var columns: Int
    /// How many rows and columns of cells the grid shows. It only grows while
    /// the picker is open, so it doesn't jump about under the pointer.
    private(set) var gridRows = Self.initialGrid.rows
    private(set) var gridColumns = Self.initialGrid.columns

    init(rows: Int = 3, columns: Int = 3) {
        self.rows = Self.rowLimit.clamp(rows)
        self.columns = Self.columnLimit.clamp(columns)
        grow()
    }

    /// Sets the size, keeping it within the limits.
    mutating func set(rows: Int? = nil, columns: Int? = nil) {
        if let rows { self.rows = Self.rowLimit.clamp(rows) }
        if let columns { self.columns = Self.columnLimit.clamp(columns) }
        grow()
    }

    /// Picks the size that ends at a cell of the grid, counted from zero.
    mutating func select(row: Int, column: Int) {
        set(rows: min(row, Self.largestGrid.rows - 1) + 1, columns: min(column, Self.largestGrid.columns - 1) + 1)
    }

    /// The cell under a point, for a grid whose cells are `pitch` apart, or nil
    /// when the point is before the first cell.
    static func cell(at point: CGPoint, pitch: CGFloat) -> (row: Int, column: Int)? {
        guard pitch > 0, point.x >= 0, point.y >= 0 else { return nil }
        return (
            min(Int(point.y / pitch), largestGrid.rows - 1),
            min(Int(point.x / pitch), largestGrid.columns - 1)
        )
    }

    enum Direction {
        case up, down, left, right
    }

    /// Grows or shrinks the selection by a row or a column, as the arrow keys do.
    mutating func move(_ direction: Direction) {
        switch direction {
        case .up: set(rows: rows - 1)
        case .down: set(rows: rows + 1)
        case .left: set(columns: columns - 1)
        case .right: set(columns: columns + 1)
        }
    }

    /// Whether a cell of the grid, counted from zero, is within the selection.
    func contains(row: Int, column: Int) -> Bool {
        row < rows && column < columns
    }

    /// "columns × rows", as menus show table sizes.
    var label: String {
        String(format: String(localized: "Table.Size"), columns, rows)
    }

    /// The size as VoiceOver reads it.
    var spokenLabel: String {
        String(format: String(localized: "Table.Size.Spoken"), columns, rows)
    }

    private mutating func grow() {
        gridRows = min(max(gridRows, rows + 1), Self.largestGrid.rows)
        gridColumns = min(max(gridColumns, columns + 1), Self.largestGrid.columns)
    }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
