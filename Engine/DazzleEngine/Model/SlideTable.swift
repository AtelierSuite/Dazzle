import Foundation

/// A DrawingML table, as much of it as Dazzle draws.
public struct SlideTable: Equatable, Hashable, Sendable {
    public struct Cell: Equatable, Hashable, Sendable {
        public var text: TextBody?
        public var fill: Fill?
        public var columnSpan = 1
        public var rowSpan = 1
        /// `hMerge`: covered by the span of the cell to its left.
        public var isHorizontalMerge = false
        /// `vMerge`: covered by the span of the cell above.
        public var isVerticalMerge = false
        /// Covered by a neighbour's span, so not drawn on its own.
        public var isMerged: Bool { isHorizontalMerge || isVerticalMerge }
        public var anchor: BodyProperties.Anchor?
        /// EMU; `nil` where the cell does not say.
        public var marginLeft: Int?
        public var marginRight: Int?
        public var marginTop: Int?
        public var marginBottom: Int?
        /// Borders the cell states itself.
        public var borderLeft: LineStyle?
        public var borderRight: LineStyle?
        public var borderTop: LineStyle?
        public var borderBottom: LineStyle?
        /// `lnTlToBr` and `lnBlToTr`: lines across the cell from corner to corner.
        public var borderDiagonalDown: LineStyle?
        public var borderDiagonalUp: LineStyle?
        /// The cell's `a:tcPr` and `a:txBody` as the file wrote them, so
        /// what Dazzle does not model survives a rewrite.
        public var sourceProperties: String?
        public var sourceBody: String?
    }

    public struct Row: Equatable, Hashable, Sendable {
        /// EMU.
        public var height: Int
        public var cells: [Cell]
    }

    /// EMU.
    public var columnWidths: [Int]
    public var rows: [Row]
    /// Which of the table style's parts are drawn: `firstRow`, `bandRow`,
    /// `lastRow`, `firstCol`, `lastCol` and `bandCol` on `a:tblPr`.
    public var hasHeaderRow: Bool
    public var hasBandedRows: Bool
    public var hasTotalRow = false
    public var hasFirstColumn = false
    public var hasLastColumn = false
    public var hasBandedColumns = false
    /// `a:tableStyleId`; a table without one has no style at all.
    public var styleID: String?
    /// `a:tblPr` as the file wrote it.
    public var sourceProperties: String?
}

public extension SlideTable {
    /// The table style options a table can turn on, in the order they are offered.
    enum StyleOption: String, CaseIterable, Hashable, Sendable {
        case headerRow, totalRow, bandedRows, firstColumn, lastColumn, bandedColumns

        public var keyPath: WritableKeyPath<SlideTable, Bool> {
            switch self {
            case .headerRow: \.hasHeaderRow
            case .totalRow: \.hasTotalRow
            case .bandedRows: \.hasBandedRows
            case .firstColumn: \.hasFirstColumn
            case .lastColumn: \.hasLastColumn
            case .bandedColumns: \.hasBandedColumns
            }
        }

        /// Its attribute on `a:tblPr`.
        public var attribute: String {
            switch self {
            case .headerRow: "firstRow"
            case .totalRow: "lastRow"
            case .bandedRows: "bandRow"
            case .firstColumn: "firstCol"
            case .lastColumn: "lastCol"
            case .bandedColumns: "bandCol"
            }
        }
    }

    subscript(option: StyleOption) -> Bool {
        get { self[keyPath: option.keyPath] }
        set { self[keyPath: option.keyPath] = newValue }
    }

    /// Which of the style's emphasised parts the cell anchored at a position
    /// falls in, with the options the table turns on.
    struct CellRegions: Equatable, Sendable {
        public var isHeaderRow = false
        public var isTotalRow = false
        public var isFirstColumn = false
        public var isLastColumn = false
        /// `band1H`/`band1V` when true; `band2H`/`band2V` when false and
        /// the bands are on; neither where a header or total line takes the cell.
        public var rowBand: Bool?
        public var columnBand: Bool?

        /// Shown with the accent of a built-in style: a header, total row or edge column.
        public var isEmphasised: Bool { isHeaderRow || isTotalRow || isFirstColumn || isLastColumn }

        /// How much a built-in style lightens its accent here: none where
        /// emphasised, less on a band than elsewhere.
        public var builtInTint: Int? {
            if isEmphasised { return nil }
            return rowBand == true || columnBand == true ? 40_000 : 20_000
        }
    }

    func regions(row: Int, column: Int) -> CellRegions {
        let span = cell(at: TableCellPosition(row: row, column: column)).map { ($0.rowSpan, $0.columnSpan) } ?? (1, 1)
        var regions = CellRegions()
        regions.isHeaderRow = hasHeaderRow && row == 0
        regions.isTotalRow = hasTotalRow && row + max(span.0, 1) >= rows.count
        regions.isFirstColumn = hasFirstColumn && column == 0
        regions.isLastColumn = hasLastColumn && column + max(span.1, 1) >= columnCount
        // Bands count from the first row and column past the header and first column.
        if hasBandedRows, !regions.isHeaderRow, !regions.isTotalRow {
            regions.rowBand = (row - (hasHeaderRow ? 1 : 0)).isMultiple(of: 2)
        }
        if hasBandedColumns, !regions.isFirstColumn, !regions.isLastColumn {
            regions.columnBand = (column - (hasFirstColumn ? 1 : 0)).isMultiple(of: 2)
        }
        return regions
    }
}

/// The parts of a table style Dazzle draws: fills, text colour and weight,
/// and borders, for the whole table, its bands, its header and total rows,
/// its first and last columns and its corner cells.
public struct TableStyle: Equatable, Hashable, Sendable {
    public struct Part: Equatable, Hashable, Sendable {
        public var fill: Fill?
        public var textColor: DrawingColor?
        public var isBold: Bool?
        /// By edge: `left`, `right`, `top`, `bottom`, and `insideH`/`insideV`
        /// for the lines between cells, and `tl2br`/`tr2bl` for the diagonals.
        public var borders: [String: LineStyle] = [:]
    }

    public var whole = Part()
    public var bandedRow = Part()
    public var evenBandedRow = Part()
    public var bandedColumn = Part()
    public var evenBandedColumn = Part()
    public var headerRow = Part()
    public var totalRow = Part()
    public var firstColumn = Part()
    public var lastColumn = Part()
    public var topLeftCell = Part()
    public var topRightCell = Part()
    public var bottomLeftCell = Part()
    public var bottomRightCell = Part()

    public init() {
        // An empty style: nothing filled.
    }

    public init(element: XMLElement) {
        whole = Self.part(element.firstChild(named: "wholeTbl"))
        bandedRow = Self.part(element.firstChild(named: "band1H"))
        evenBandedRow = Self.part(element.firstChild(named: "band2H"))
        bandedColumn = Self.part(element.firstChild(named: "band1V"))
        evenBandedColumn = Self.part(element.firstChild(named: "band2V"))
        headerRow = Self.part(element.firstChild(named: "firstRow"))
        totalRow = Self.part(element.firstChild(named: "lastRow"))
        firstColumn = Self.part(element.firstChild(named: "firstCol"))
        lastColumn = Self.part(element.firstChild(named: "lastCol"))
        topLeftCell = Self.part(element.firstChild(named: "nwCell"))
        topRightCell = Self.part(element.firstChild(named: "neCell"))
        bottomLeftCell = Self.part(element.firstChild(named: "swCell"))
        bottomRightCell = Self.part(element.firstChild(named: "seCell"))
    }

    /// The parts that style a cell, the one that wins first: the corner
    /// cells, then the header row, total row, first and last columns, row
    /// bands, column bands and the whole table, as PowerPoint layers them.
    public func parts(for regions: SlideTable.CellRegions) -> [Part] {
        var parts: [Part] = []
        if regions.isHeaderRow, regions.isFirstColumn { parts.append(topLeftCell) }
        if regions.isHeaderRow, regions.isLastColumn { parts.append(topRightCell) }
        if regions.isTotalRow, regions.isFirstColumn { parts.append(bottomLeftCell) }
        if regions.isTotalRow, regions.isLastColumn { parts.append(bottomRightCell) }
        if regions.isHeaderRow { parts.append(headerRow) }
        if regions.isTotalRow { parts.append(totalRow) }
        if regions.isFirstColumn { parts.append(firstColumn) }
        if regions.isLastColumn { parts.append(lastColumn) }
        if let band = regions.rowBand { parts.append(band ? bandedRow : evenBandedRow) }
        if let band = regions.columnBand { parts.append(band ? bandedColumn : evenBandedColumn) }
        parts.append(whole)
        return parts
    }

    /// What the winning parts give a cell: the first part that says wins.
    public func fill(for regions: SlideTable.CellRegions) -> Fill? {
        parts(for: regions).lazy.compactMap(\.fill).first
    }

    public func textColor(for regions: SlideTable.CellRegions) -> DrawingColor? {
        parts(for: regions).lazy.compactMap(\.textColor).first
    }

    public func isBold(for regions: SlideTable.CellRegions) -> Bool? {
        parts(for: regions).lazy.compactMap(\.isBold).first
    }

    public func border(_ edge: String, for regions: SlideTable.CellRegions) -> LineStyle? {
        parts(for: regions).lazy.compactMap { $0.borders[edge] }.first
    }

    private static func part(_ element: XMLElement?) -> Part {
        guard let element else { return Part() }
        let cell = element.firstChild(named: "tcStyle")
        let text = element.firstChild(named: "tcTxStyle")
        var part = Part()
        // A colour of the text style's own outranks its font reference's.
        part.textColor = DrawingColor.first(in: text) ?? DrawingColor.first(in: text?.firstChild(named: "fontRef"))
        part.isBold = text?.attribute("b").map { $0 == "on" }
        if let fill = Fill.parse(in: cell?.firstChild(named: "fill"), image: { _ in nil }) {
            part.fill = fill
        } else if let reference = cell?.firstChild(named: "fillRef"),
                  (reference.attribute("idx").flatMap(Int.init) ?? 0) > 0,
                  let color = DrawingColor.first(in: reference) {
            // A theme fill reference: drawn in its colour.
            part.fill = .solid(color)
        }
        for edge in cell?.firstChild(named: "tcBdr")?.children ?? [] {
            if let line = edge.firstChild(named: "ln") {
                part.borders[edge.name] = LineStyle(element: line)
            } else if let reference = edge.firstChild(named: "lnRef"), let color = DrawingColor.first(in: reference) {
                part.borders[edge.name] = LineStyle(fill: .solid(color), width: 12_700)
            }
        }
        return part
    }
}
