import AppKit
import DazzleEngine

/// The selected chart's data as a table, in a sheet: categories down the
/// side, a column for each series, the series' names along the top.
/// Changes are made when a cell is left, not as it is typed.
@MainActor
final class ChartDataSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let deck: Deck
    private let table = NSTableView()
    private var window: NSWindow?
    private var observing: Observing?
    private var chart: Chart?
    private var columnCount = 0

    private static let columnWidth: CGFloat = 110

    init(deck: Deck) {
        self.deck = deck
        super.init()
    }

    func present(over parent: NSWindow) {
        table.headerView = nil
        table.style = .plain
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        let addSeries = button("Chart.Data.AddSeries", #selector(addSeries(_:)))
        let addRow = button("Chart.Data.AddCategory", #selector(addCategory(_:)))
        let deleteSeries = button("Chart.Data.DeleteSeries", #selector(deleteSeries(_:)))
        let deleteRow = button("Chart.Data.DeleteCategory", #selector(deleteCategory(_:)))
        let done = button("Format.DoneEditing", #selector(close(_:)))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [addSeries, addRow, deleteSeries, deleteRow, NSView(), done])
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.title = String(localized: "Chart.Section.Data")
        window.contentView = stack
        window.minSize = NSSize(width: 520, height: 320)
        self.window = window
        observing = Observing { [weak self] in self?.reload() }
        parent.beginSheet(window)
    }

    private func button(_ key: String.LocalizationValue, _ action: Selector) -> NSButton {
        let button = NSButton(title: String(localized: key), target: self, action: action)
        button.bezelStyle = .push
        return button
    }

    // MARK: - Keeping current

    private func reload() {
        let chart = deck.state.selectedChart(in: deck.presentation)
        guard chart != self.chart else { return }
        self.chart = chart
        guard let chart else { return close(nil) }
        let columns = chart.allSeries.count + 1
        if columns != columnCount {
            table.tableColumns.forEach(table.removeTableColumn)
            for index in 0..<columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.width = Self.columnWidth
                table.addTableColumn(column)
            }
            columnCount = columns
        }
        // A field being typed in keeps what is typed until it is left.
        if table.currentEditor() == nil { table.reloadData() }
    }

    // MARK: - NSTableViewDataSource

    /// The series' names, then a row for each category.
    func numberOfRows(in tableView: NSTableView) -> Int { (chart?.categories.count ?? 0) + 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let chart, let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }) else { return nil }
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = self
        field.tag = row * 1_000 + column
        let series = chart.allSeries
        switch (row, column) {
        case (0, 0):
            field.stringValue = String(localized: chart.kind == .scatter ? "Chart.Data.X" : "Chart.Data.Category")
            field.isEditable = false
            field.textColor = .secondaryLabelColor
            field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        case (0, _):
            field.stringValue = series.indices.contains(column - 1) ? series[column - 1].name : ""
            field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        case (_, 0):
            field.stringValue = chart.categories.indices.contains(row - 1) ? chart.categories[row - 1] : ""
        default:
            let values = series.indices.contains(column - 1) ? series[column - 1].values : []
            field.stringValue = values.indices.contains(row - 1) ? values[row - 1].map(ChartValues.format) ?? "" : ""
            field.alignment = .right
        }
        return field
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = field.tag / 1_000
        let column = field.tag % 1_000
        let text = field.stringValue
        let state = deck.state
        deck.edit { presentation in
            state.updateChart(in: &presentation) { chart in
                switch (row, column) {
                case (0, 0): break
                case (0, _): chart.updateSeries(at: column - 1) { $0.name = text }
                case (_, 0): if chart.categories.indices.contains(row - 1) { chart.categories[row - 1] = text }
                default:
                    let number = ChartValues.parse(text)
                    chart.updateSeries(at: column - 1) { series in
                        while series.values.count < row { series.values.append(nil) }
                        series.values[row - 1] = number
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func change(_ change: @escaping (inout Chart) -> Void) {
        let state = deck.state
        deck.edit { state.updateChart(in: &$0, change) }
    }

    @objc private func addSeries(_ sender: Any?) { change { $0.addSeries() } }
    @objc private func addCategory(_ sender: Any?) { change { $0.addCategory() } }

    /// Deletes the series whose column holds the selected cell.
    @objc private func deleteSeries(_ sender: Any?) {
        let column = table.column(for: table.window?.firstResponder as? NSView ?? table) - 1
        guard let chart, chart.allSeries.count > 1 else { return }
        let index = chart.allSeries.indices.contains(column) ? column : chart.allSeries.count - 1
        change { $0.removeSeries(at: index) }
    }

    /// Deletes the category whose row holds the selected cell.
    @objc private func deleteCategory(_ sender: Any?) {
        let row = table.row(for: table.window?.firstResponder as? NSView ?? table) - 1
        guard let chart, chart.categories.count > 1 else { return }
        let index = chart.categories.indices.contains(row) ? row : chart.categories.count - 1
        change { $0.removeCategory(at: index) }
    }

    @objc private func close(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        observing?.cancel()
        observing = nil
        if let window { window.sheetParent?.endSheet(window) }
        window = nil
    }
}
