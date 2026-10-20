import DazzleEngine
import Foundation

extension EditorState {
    /// Makes the selected chart another kind, keeping its data.
    func setChartKind(_ kind: Chart.Kind, in presentation: inout Presentation) {
        updateChart(in: &presentation) { chart in
            let grouping = kind.hasAxes && kind != .scatter ? chart.plots.first?.grouping ?? .standard : .standard
            chart.plots = [Chart.Plot(kind: kind, grouping: grouping, series: chart.allSeries)]
            // A scatter chart's first column is numbers along the x axis.
            if kind == .scatter, chart.categories.contains(where: { Double($0) == nil }) {
                chart.categories = chart.categories.indices.map { String($0 + 1) }
            }
        }
    }
}

/// A chart's values as they are typed and shown.
enum ChartValues {
    static func format(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
    }

    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (try? Double(trimmed, format: .number)) ?? Double(trimmed)
    }
}

extension Chart {
    /// The `index`th series counting through every plot.
    mutating func updateSeries(at index: Int, _ change: (inout Series) -> Void) {
        var remaining = index
        for plot in plots.indices {
            if remaining < plots[plot].series.count {
                change(&plots[plot].series[remaining])
                return
            }
            remaining -= plots[plot].series.count
        }
    }

    mutating func removeSeries(at index: Int) {
        var remaining = index
        for plot in plots.indices {
            if remaining < plots[plot].series.count {
                plots[plot].series.remove(at: remaining)
                plots.removeAll { $0.series.isEmpty }
                return
            }
            remaining -= plots[plot].series.count
        }
    }

    mutating func addSeries() {
        guard !plots.isEmpty else { return }
        let number = allSeries.count + 1
        plots[plots.count - 1].series.append(Series(
            name: String(format: String(localized: "Chart.Sample.Series"), number),
            values: Array(repeating: nil, count: categories.count)
        ))
    }

    mutating func addCategory() {
        let next = kind == .scatter
            ? String((Double(categories.last ?? "0") ?? 0) + 1).replacingOccurrences(of: ".0", with: "")
            : String(format: String(localized: "Chart.Sample.Category"), categories.count + 1)
        categories.append(next)
        for plot in plots.indices {
            for series in plots[plot].series.indices { plots[plot].series[series].values.append(nil) }
        }
    }

    mutating func removeCategory(at index: Int) {
        guard categories.indices.contains(index) else { return }
        categories.remove(at: index)
        for plot in plots.indices {
            for series in plots[plot].series.indices where plots[plot].series[series].values.indices.contains(index) {
                plots[plot].series[series].values.remove(at: index)
                // A slice's own colour belongs to the slice, which moves up.
                plots[plot].series[series].pointColors = Dictionary(uniqueKeysWithValues:
                    plots[plot].series[series].pointColors.compactMap { key, color in
                        key == index ? nil : (key > index ? key - 1 : key, color)
                    })
            }
        }
    }
}
