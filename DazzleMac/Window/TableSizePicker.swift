import AppKit

/// Picks how many columns and rows a new table has, in a popover: point at
/// the grid and click, use the arrow keys and Return, or set the size with
/// the steppers and click Insert.
final class TableSizePickerController: NSViewController {
    private let insert: (_ rows: Int, _ columns: Int) -> Void
    /// The size shown: the one under the pointer while it is over the grid.
    private var selection = TableSizeSelection()
    /// The size set by a click, the keyboard or the steppers, which the
    /// selection goes back to when the pointer leaves the grid.
    private var chosen = TableSizeSelection()

    private let label = NSTextField(labelWithString: "")
    private lazy var grid = TableSizeGridView(controller: self)
    private let columnsField = NSTextField()
    private let rowsField = NSTextField()
    private let columnsStepper = NSStepper()
    private let rowsStepper = NSStepper()

    init(insert: @escaping (_ rows: Int, _ columns: Int) -> Void) {
        self.insert = insert
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        label.alignment = .center
        label.setAccessibilityElement(false)

        let form = NSGridView(views: [
            row(String(localized: "Table.Columns"), columnsField, columnsStepper, TableSizeSelection.columnLimit),
            row(String(localized: "Table.Rows"), rowsField, rowsStepper, TableSizeSelection.rowLimit),
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline
        form.columnSpacing = 6
        form.rowSpacing = 8

        let insertButton = NSButton(title: String(localized: "Table.Insert"), target: self, action: #selector(insertChosen(_:)))
        insertButton.keyEquivalent = "\r"
        insertButton.setAccessibilityIdentifier("insertTableSize")

        let stack = NSStackView(views: [label, grid, form, insertButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view = stack
        update()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(grid)
    }

    private func row(_ title: String, _ field: NSTextField, _ stepper: NSStepper, _ limit: ClosedRange<Int>) -> [NSView] {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = limit.lowerBound as NSNumber
        formatter.maximum = limit.upperBound as NSNumber
        field.formatter = formatter
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.target = self
        field.action = #selector(fieldChanged(_:))
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        field.setAccessibilityLabel(title)
        stepper.minValue = Double(limit.lowerBound)
        stepper.maxValue = Double(limit.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        stepper.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        return [label, field, stepper]
    }

    // MARK: - Choosing

    /// Shows the size under the pointer without choosing it.
    func preview(row: Int, column: Int) {
        selection.select(row: row, column: column)
        update()
    }

    /// Goes back to the chosen size when the pointer leaves the grid.
    func endPreview() {
        selection.set(rows: chosen.rows, columns: chosen.columns)
        update()
    }

    func choose(row: Int, column: Int) {
        selection.select(row: row, column: column)
        chosen = selection
        update()
    }

    func move(_ direction: TableSizeSelection.Direction) {
        selection.set(rows: chosen.rows, columns: chosen.columns)
        selection.move(direction)
        chosen = selection
        update()
    }

    func insertSelection() {
        insert(selection.rows, selection.columns)
    }

    var shown: TableSizeSelection { selection }

    @objc private func insertChosen(_ sender: Any?) {
        // Ends typing in a field first, so a number just typed counts.
        view.window?.makeFirstResponder(nil)
        insertSelection()
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        set(sender === rowsStepper ? .rows : .columns, sender.integerValue)
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        set(sender === rowsField ? .rows : .columns, sender.integerValue)
    }

    private enum Dimension { case rows, columns }

    private func set(_ dimension: Dimension, _ value: Int) {
        switch dimension {
        case .rows: chosen.set(rows: value)
        case .columns: chosen.set(columns: value)
        }
        selection.set(rows: chosen.rows, columns: chosen.columns)
        update()
    }

    private func update() {
        let spoken = selection.spokenLabel
        let changed = grid.accessibilityValue() as? String != spoken
        label.stringValue = selection.label
        columnsField.integerValue = selection.columns
        rowsField.integerValue = selection.rows
        columnsStepper.integerValue = selection.columns
        rowsStepper.integerValue = selection.rows
        grid.setAccessibilityValue(spoken)
        grid.invalidateIntrinsicContentSize()
        grid.needsDisplay = true
        if changed, isViewLoaded, view.window != nil {
            NSAccessibility.post(element: grid, notification: .announcementRequested, userInfo: [
                .announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }
}

/// The grid of cells: the pointer previews a size, a click inserts it, and
/// with focus the arrow keys change it and Return inserts it.
final class TableSizeGridView: NSView {
    private unowned let controller: TableSizePickerController

    static let cellSize: CGFloat = 18
    static let spacing: CGFloat = 3
    static var pitch: CGFloat { cellSize + spacing }

    init(controller: TableSizePickerController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Table.Picker.Grid"))
        setAccessibilityHelp(String(localized: "Table.Picker.Hint"))
        setAccessibilityIdentifier("tableSizeGrid")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    /// Room for the largest grid, so the popover keeps its size as the grid grows.
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: CGFloat(TableSizeSelection.largestGrid.columns) * Self.pitch - Self.spacing,
            height: CGFloat(TableSizeSelection.largestGrid.rows) * Self.pitch - Self.spacing
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let selection = controller.shown
        // Cells past the grid so far are a faint hint of where it can grow.
        for row in 0..<TableSizeSelection.largestGrid.rows {
            for column in 0..<TableSizeSelection.largestGrid.columns {
                let rect = NSRect(x: CGFloat(column) * Self.pitch, y: CGFloat(row) * Self.pitch,
                                  width: Self.cellSize, height: Self.cellSize)
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                if selection.contains(row: row, column: column) {
                    NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                    NSColor.controlAccentColor.setStroke()
                } else if row < selection.gridRows, column < selection.gridColumns {
                    NSColor.quaternaryLabelColor.setFill()
                    NSColor.tertiaryLabelColor.setStroke()
                } else {
                    NSColor.quaternaryLabelColor.withAlphaComponent(0.03).setFill()
                    NSColor.clear.setStroke()
                }
                path.fill()
                path.stroke()
            }
        }
    }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func cell(for event: NSEvent) -> (row: Int, column: Int)? {
        let point = convert(event.locationInWindow, from: nil)
        return TableSizeSelection.cell(at: CGPoint(x: max(point.x, 0), y: max(point.y, 0)), pitch: Self.pitch)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let cell = cell(for: event) else { return }
        controller.preview(row: cell.row, column: cell.column)
    }

    override func mouseExited(with event: NSEvent) {
        controller.endPreview()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let cell = cell(for: event) else { return }
        controller.choose(row: cell.row, column: cell.column)
    }

    override func mouseUp(with event: NSEvent) {
        guard let cell = cell(for: event) else { return }
        controller.choose(row: cell.row, column: cell.column)
        controller.insertSelection()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow: controller.move(.up)
        case .downArrow: controller.move(.down)
        case .leftArrow: controller.move(.left)
        case .rightArrow: controller.move(.right)
        case .carriageReturn, .enter, .newline: controller.insertSelection()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        controller.insertSelection()
        return true
    }
}
