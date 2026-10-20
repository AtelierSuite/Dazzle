import DazzleEngine
import SwiftUI

/// The selected chart's type, data, title and legend.
struct ChartPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    private var chart: Chart? { state.selectedChart(in: presentation) }

    var body: some View {
        Form {
            if let chart {
                typeSection(chart)
                Section("Chart.Section.Data") {
                    ChartDataGrid(chart: chart) { change in
                        state.updateChart(in: &presentation, change)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                labelSection(chart)
            }
        }
    }

    private func typeSection(_ chart: Chart) -> some View {
        Section("Chart.Section.Type") {
            Picker("Chart.Type", selection: Binding(get: { chart.kind }, set: { state.setChartKind($0, in: &presentation) })) {
                ForEach(Chart.Kind.allCases, id: \.self) { kind in
                    Label(kind.label, systemImage: kind.symbol).tag(kind)
                }
            }
            .accessibilityIdentifier("chartType")
            if chart.kind.hasAxes, chart.kind != .scatter {
                Picker("Chart.Grouping", selection: Binding(
                    get: { chart.plots.first?.grouping ?? .standard },
                    set: { grouping in state.updateChart(in: &presentation) { chart in
                        for index in chart.plots.indices { chart.plots[index].grouping = grouping }
                    } }
                )) {
                    Text(chart.kind == .line || chart.kind == .area ? "Chart.Grouping.Standard" : "Chart.Grouping.Clustered")
                        .tag(Chart.Grouping.standard)
                    Text("Chart.Grouping.Stacked").tag(Chart.Grouping.stacked)
                    Text("Chart.Grouping.Percent").tag(Chart.Grouping.percentStacked)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func labelSection(_ chart: Chart) -> some View {
        Section("Chart.Section.Labels") {
            Toggle("Chart.ShowTitle", isOn: Binding(
                get: { chart.title != nil },
                set: { isOn in state.updateChart(in: &presentation) {
                    $0.title = isOn ? ($0.allSeries.count == 1 ? $0.allSeries[0].name : String(localized: "Chart.DefaultTitle")) : nil
                } }
            ))
            if let title = chart.title {
                CommitTextField("Chart.Title", text: title) { text in
                    state.updateChart(in: &presentation) { $0.title = text }
                }
            }
            Picker("Chart.Legend", selection: Binding(
                get: { chart.hasLegend ? chart.legendPosition : "none" },
                set: { position in state.updateChart(in: &presentation) { chart in
                    chart.hasLegend = position != "none"
                    if position != "none" { chart.legendPosition = position }
                } }
            )) {
                Text("Chart.Legend.None").tag("none")
                Text("Chart.Legend.Right").tag("r")
                Text("Chart.Legend.Bottom").tag("b")
                Text("Chart.Legend.Top").tag("t")
                Text("Chart.Legend.Left").tag("l")
            }
            if chart.kind.hasAxes {
                Toggle("Chart.Gridlines", isOn: Binding(
                    get: { chart.showsGridlines },
                    set: { isOn in state.updateChart(in: &presentation) { $0.showsGridlines = isOn } }
                ))
            }
            Toggle("Chart.ValueLabels", isOn: Binding(
                get: { chart.showsValueLabels },
                set: { isOn in state.updateChart(in: &presentation) { $0.showsValueLabels = isOn } }
            ))
        }
    }
}

/// The chart's data as a table: categories down the side, a column for
/// each series. Changes are made when a field is left, not as it is typed.
struct ChartDataGrid: View {
    let chart: Chart
    let change: ((inout Chart) -> Void) -> Void

    private static let columnWidth: CGFloat = 96

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text(chart.kind == .scatter ? "Chart.Data.X" : "Chart.Data.Category")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.columnWidth, alignment: .leading)
                    ForEach(Array(chart.allSeries.enumerated()), id: \.offset) { index, series in
                        CommitTextField("Chart.Data.SeriesName", text: series.name) { name in
                            change { $0.updateSeries(at: index) { $0.name = name } }
                        }
                        .font(.caption.weight(.semibold))
                        .frame(width: Self.columnWidth)
                        .contextMenu {
                            Button("Chart.Data.DeleteSeries", systemImage: "trash", role: .destructive) {
                                change { $0.removeSeries(at: index) }
                            }
                            .disabled(chart.allSeries.count < 2)
                        }
                    }
                    Button("Chart.Data.AddSeries", systemImage: "plus") {
                        change { $0.addSeries() }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("addSeries")
                }
                ForEach(Array(chart.categories.enumerated()), id: \.offset) { row, category in
                    GridRow {
                        CommitTextField("Chart.Data.Category", text: category) { name in
                            change { $0.categories[row] = name }
                        }
                        .frame(width: Self.columnWidth)
                        .contextMenu {
                            Button("Chart.Data.DeleteCategory", systemImage: "trash", role: .destructive) {
                                change { $0.removeCategory(at: row) }
                            }
                            .disabled(chart.categories.count < 2)
                        }
                        ForEach(Array(chart.allSeries.enumerated()), id: \.offset) { column, series in
                            let value = series.values.indices.contains(row) ? series.values[row] : nil
                            CommitTextField("", text: value.map(ChartValues.format) ?? "", isNumber: true) { text in
                                let number = ChartValues.parse(text)
                                change { $0.updateSeries(at: column) { series in
                                    while series.values.count <= row { series.values.append(nil) }
                                    series.values[row] = number
                                } }
                            }
                            .frame(width: Self.columnWidth)
                        }
                    }
                }
                GridRow {
                    Button("Chart.Data.AddCategory", systemImage: "plus") {
                        change { $0.addCategory() }
                    }
                    .font(.callout)
                    .accessibilityIdentifier("addCategory")
                    .gridCellColumns(2)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}

/// A text field that hands its text back when it is left or submitted,
/// rather than on every keystroke.
struct CommitTextField: View {
    let label: LocalizedStringKey
    let text: String
    var isNumber = false
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    init(_ label: LocalizedStringKey, text: String, isNumber: Bool = false, commit: @escaping (String) -> Void) {
        self.label = label
        self.text = text
        self.isNumber = isNumber
        self.commit = commit
    }

    var body: some View {
        TextField(label, text: $draft)
            .focused($isFocused)
            .keyboardType(isNumber ? .decimalPad : .default)
            .multilineTextAlignment(isNumber ? .trailing : .leading)
            .onAppear { draft = text }
            .onChange(of: text) { _, new in if !isFocused { draft = new } }
            .onChange(of: isFocused) { _, focused in
                if !focused, draft != text { commit(draft) }
            }
            .onSubmit { if draft != text { commit(draft) } }
    }
}
