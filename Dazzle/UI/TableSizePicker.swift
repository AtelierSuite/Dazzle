import SwiftUI

/// Picks how many columns and rows a new table has: drag across the grid and
/// let go to insert, or set the size with the steppers and tap Insert.
struct TableSizePicker: View {
    let insert: (_ rows: Int, _ columns: Int) -> Void

    @State private var selection = TableSizeSelection()

    private static let cellSize: CGFloat = 22
    private static let spacing: CGFloat = 4
    private static var pitch: CGFloat { cellSize + spacing }

    var body: some View {
        VStack(spacing: 12) {
            Text(selection.label)
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityHidden(true)
            grid
            VStack(spacing: 8) {
                Stepper(value: binding(\.columns), in: TableSizeSelection.columnLimit) {
                    LabeledContent("Table.Columns") { Text(verbatim: "\(selection.columns)").monospacedDigit() }
                }
                .accessibilityIdentifier("tableColumns")
                .accessibilityValue(Text(verbatim: "\(selection.columns)"))
                Stepper(value: binding(\.rows), in: TableSizeSelection.rowLimit) {
                    LabeledContent("Table.Rows") { Text(verbatim: "\(selection.rows)").monospacedDigit() }
                }
                .accessibilityIdentifier("tableRows")
                .accessibilityValue(Text(verbatim: "\(selection.rows)"))
            }
            Button {
                insert(selection.rows, selection.columns)
            } label: {
                Text("Table.Insert")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("insertTableSize")
        }
        .padding(16)
        .frame(width: CGFloat(TableSizeSelection.largestGrid.columns) * Self.pitch - Self.spacing + 32)
        .animation(.snappy(duration: 0.15), value: selection)
        .onChange(of: selection.spokenLabel) { _, spoken in
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    private var grid: some View {
        // Every cell the grid can grow to is laid out, so the popover keeps its
        // size and the cells stay under the finger; those past the grid so far
        // are only a faint hint of where it can grow.
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(0..<TableSizeSelection.largestGrid.rows, id: \.self) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(0..<TableSizeSelection.largestGrid.columns, id: \.self) { column in
                        cell(row: row, column: column)
                    }
                }
            }
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in pick(at: drag.location) }
                .onEnded { drag in
                    pick(at: drag.location)
                    insert(selection.rows, selection.columns)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Table.Picker.Grid")
        .accessibilityValue(selection.spokenLabel)
        .accessibilityHint("Table.Picker.Hint")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { insert(selection.rows, selection.columns) }
        .accessibilityIdentifier("tableSizeGrid")
    }

    @ViewBuilder
    private func cell(row: Int, column: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        if selection.contains(row: row, column: column) {
            shape.fill(Color.accentColor.opacity(0.35))
                .strokeBorder(Color.accentColor, lineWidth: 1)
                .frame(width: Self.cellSize, height: Self.cellSize)
        } else if row < selection.gridRows, column < selection.gridColumns {
            shape.fill(Color.secondary.opacity(0.12))
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                .frame(width: Self.cellSize, height: Self.cellSize)
        } else {
            shape.fill(Color.secondary.opacity(0.05))
                .frame(width: Self.cellSize, height: Self.cellSize)
        }
    }

    private func pick(at location: CGPoint) {
        let point = CGPoint(x: max(location.x, 0), y: max(location.y, 0))
        guard let cell = TableSizeSelection.cell(at: point, pitch: Self.pitch) else { return }
        selection.select(row: cell.row, column: cell.column)
    }

    private func binding(_ keyPath: KeyPath<TableSizeSelection, Int>) -> Binding<Int> {
        Binding(
            get: { selection[keyPath: keyPath] },
            set: { value in
                if keyPath == \TableSizeSelection.rows {
                    selection.set(rows: value)
                } else {
                    selection.set(columns: value)
                }
            }
        )
    }
}
