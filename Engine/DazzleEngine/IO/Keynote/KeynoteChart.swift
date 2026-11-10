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
        let kind: Chart.Kind
        var grouping = Chart.Grouping.standard
        switch info.int(1) ?? 1 {
        case 1, 12, 20: kind = .column
        case 2, 13, 21: kind = .bar
        case 3, 14: kind = .line
        case 4, 15: kind = .area
        case 5, 16: kind = .pie
        case 6, 17: kind = .column; grouping = .stacked
        case 7, 18: kind = .bar; grouping = .stacked
        case 8, 19: kind = .area; grouping = .stacked
        case 9, 23: kind = .scatter
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
        let seriesNames = byRow ? rowNames : columnNames

        let themeStyles = info.references(17)
        var privateStyles: [Int: UInt64] = [:]
        for entry in info.message(18)?.messages(2) ?? [] {
            if let index = entry.int(1), let reference = entry.reference(2) { privateStyles[index] = reference }
        }
        let series = seriesNames.indices.map { index -> Chart.Series in
            let style = privateStyles[index] ?? (themeStyles.isEmpty ? nil : themeStyles[index % themeStyles.count])
            let values = categories.indices.map { byRow ? value(index, $0) : value($0, index) }
            var series = Chart.Series(name: seriesNames[index], values: values)
            series.color = color(style, kind: kind)
            return series
        }

        var chart = Chart(path: path, plots: [Chart.Plot(kind: kind, grouping: grouping, series: series)], categories: categories)
        let nonStyle = info.reference(10)
        if generated(nonStyle, 21) { $0.bool(21) } == true {
            chart.title = generated(nonStyle, 23) { $0.string(23) }
        }
        chart.hasLegend = generated(nonStyle, 20) { $0.bool(20) } ?? false
        chart.showsGridlines = generated(info.references(14).first, 28) { $0.bool(28) } ?? true
        return chart
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
        case .pie, .doughnut: [17, 14]
        case .line: [48]
        case .scatter: [59, 14]
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
