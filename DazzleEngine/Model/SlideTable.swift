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
    /// Whether the first row and the bands get the table style's emphasis.
    public var hasHeaderRow: Bool
    public var hasBandedRows: Bool
    /// `a:tableStyleId`; a table without one has no style at all.
    public var styleID: String?
    /// `a:tblPr` as the file wrote it.
    public var sourceProperties: String?
}

/// The parts of a table style Dazzle draws: fills, text colour and weight,
/// and borders, for the whole table, its banded rows and its header row.
public struct TableStyle: Equatable, Hashable, Sendable {
    public struct Part: Equatable, Hashable, Sendable {
        public var fill: Fill?
        public var textColor: DrawingColor?
        public var isBold: Bool?
        /// By edge: `left`, `right`, `top`, `bottom`, and `insideH`/`insideV`
        /// for the lines between cells.
        public var borders: [String: LineStyle] = [:]
    }

    public var whole = Part()
    public var bandedRow = Part()
    public var headerRow = Part()

    public init() {
        // An empty style: nothing filled.
    }

    public init(element: XMLElement) {
        whole = Self.part(element.firstChild(named: "wholeTbl"))
        bandedRow = Self.part(element.firstChild(named: "band1H"))
        headerRow = Self.part(element.firstChild(named: "firstRow"))
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
