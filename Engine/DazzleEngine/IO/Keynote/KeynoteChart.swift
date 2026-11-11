import Foundation

/// A Keynote chart (`TSCH.ChartDrawableArchive`) as Dazzle's chart model,
/// which `ChartWriter` turns into a DrawingML chart part.
///
/// The chart's data is a grid of named rows and columns; depending on its
/// series direction, either the rows or the columns are the series.
/// Most of what a chart looks like is in styles, as generated fields
/// numbered by property: only the series colours, the title, the legend and
/// gridlines are read here.
public struct KeynoteChart {
    public let archive: KeynoteArchive
    public let styles: KeynoteStyles

    public func chart(_ drawable: ProtoMessage, path: String) -> Chart? {
        guard let info = drawable.message(10_000), let grid = info.message(7) else { return nil }
        // 3D charts are drawn flat. Mixed and two-axis charts give each
        // series a kind of its own, all against the one value axis.
        let type = info.int(1) ?? 1
        let kind: Chart.Kind
        var grouping = Chart.Grouping.standard
        // Columns of the grid each scatter point takes: x and y, and a bubble's size.
        var pointWidth = 1
        switch type {
        case 1, 10, 11, 12, 20: kind = .column
        case 2, 13, 21: kind = .bar
        case 3, 14, 27: kind = .line
        case 4, 15: kind = .area
        case 5, 16: kind = .pie
        case 6, 17: kind = .column; grouping = .stacked
        case 7, 18: kind = .bar; grouping = .stacked
        case 8, 19: kind = .area; grouping = .stacked
        case 9, 23: kind = .scatter; pointWidth = 2
        case 22, 24: kind = .scatter; pointWidth = 3
        case 25, 26: kind = .doughnut
        default: return nil
        }

        let rowNames = grid.strings(1)
        let columnNames = grid.strings(2)
        let values = grid.messages(3).map { row in row.messages(1).map { $0.float(1) } }
        func value(_ row: Int, _ column: Int) -> Double? {
            values.indices.contains(row) && values[row].indices.contains(column) ? values[row][column] : nil
        }
        // Series run along rows (1) or down columns (2).
        let byRow = info.int(5) == 1
        let categories = byRow ? columnNames : rowNames
        let names = byRow ? rowNames : columnNames
        func cell(_ series: Int, _ category: Int) -> Double? {
            byRow ? value(series, category) : value(category, series)
        }

        let themeStyles = info.references(17)
        let privateStyles = Self.sparse(info.message(18))
        let nonStyles = Self.sparse(info.message(19))
        // A scatter series takes its x values from one name's data and its
        // y values from the next, unless every series shares the first's x
        // values (2); a bubble's size, after its y values, is not drawn.
        // Dazzle's charts share their x values, which are the first series' own.
        let sharesX = kind == .scatter && info.int(2) == 2
        let stride = sharesX ? pointWidth - 1 : pointWidth
        let seriesCount = switch (kind, sharesX) {
        case (.scatter, true): max(0, names.count - 1) / stride
        case (.scatter, false): names.count / stride
        default: names.count
        }
        var plots: [Chart.Plot] = []
        for index in 0..<seriesCount {
            let style = privateStyles[index] ?? (themeStyles.isEmpty ? nil : themeStyles[index % themeStyles.count])
            var seriesKind = kind
            if type == 10 || type == 11 {
                seriesKind = switch generated(nonStyles[index], 26, { $0.int(26) }) {
                case 3: .line
                case 4: .area
                default: .column
                }
            }
            // The name whose data are the series' values.
            let column = switch (kind, sharesX) {
            case (.scatter, true): 1 + index * stride
            case (.scatter, false): index * stride + 1
            default: index
            }
            var series = Chart.Series(name: names[column], values: categories.indices.map { cell(column, $0) })
            series.color = color(style, kind: seriesKind)
            if let last = plots.indices.last, plots[last].kind == seriesKind {
                plots[last].series.append(series)
            } else {
                plots.append(Chart.Plot(kind: seriesKind, grouping: grouping, series: [series]))
            }
        }
        if plots.isEmpty { plots = [Chart.Plot(kind: kind, grouping: grouping, series: [])] }

        let xValues = categories.indices.map { index in
            cell(0, index).map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int($0)) : String($0) } ?? String(index + 1)
        }
        var chart = Chart(path: path, plots: plots, categories: kind == .scatter ? xValues : categories)
        let nonStyle = info.reference(10)
        if generated(nonStyle, 21) { $0.bool(21) } == true {
            chart.title = generated(nonStyle, 23) { $0.string(23) }
        }
        chart.hasLegend = generated(nonStyle, 20) { $0.bool(20) } ?? false
        chart.showsGridlines = generated(info.references(14).first, 28) { $0.bool(28) } ?? true
        return chart
    }

    /// Style references by series index, from a `TSP.SparseReferenceArray`.
    private static func sparse(_ array: ProtoMessage?) -> [Int: UInt64] {
        var references: [Int: UInt64] = [:]
        for entry in array?.messages(2) ?? [] {
            if let index = entry.int(1), let reference = entry.reference(2) { references[index] = reference }
        }
        return references
    }

    /// A generated property, read through the style's parents.
    private func generated<Value>(_ style: UInt64?, _ field: Int, _ read: (ProtoMessage) -> Value?) -> Value? {
        styles.resolve(style) { object in
            object.message.message(10_000).flatMap { $0.has(field) ? read($0) : nil }
        }
    }

    /// The fill a series is drawn in for the chart's kind: lines by their
    /// stroke, scatter points by their symbol.
    private func color(_ style: UInt64?, kind: Chart.Kind) -> DrawingColor? {
        let fields: [Int] = switch kind {
        case .column: [13, 14]
        case .bar: [12, 14]
        case .area: [11, 14]
        case .pie, .doughnut, .pieOfPie, .barOfPie: [17, 14]
        case .line, .radar, .stock: [48]
        case .scatter: [59, 14]
        case .bubble: [14, 59]
        case .surface: [14]
        }
        for field in fields {
            let property = generated(style, field) { $0.message(field) }
            // Fills keep their colour at 1; strokes too.
            let colorMessage = property?.message(1) ?? property?.message(2)?.messages(2).first?.message(1)
            if let hex = KeynoteStyles.color(colorMessage)?.hex, let value = UInt32(hex, radix: 16) {
                return .rgb(value)
            }
        }
        return nil
    }
}
