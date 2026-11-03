import AppKit
import DazzleEngine

/// Builds the inspector's sections of labelled controls, each bound to
/// the document by a pair of closures, and keeps them showing the current
/// values as the document changes.
///
/// Controls are made once for what is selected; `update()` then only
/// refreshes their values, so one being used keeps its focus.
@MainActor
final class InspectorForm {
    let stack = NSStackView()
    private var updates: [() -> Void] = []
    private var targets: [ActionTarget] = []

    /// The space either side of the rows.
    static let inset: CGFloat = 14
    /// The share of a row a labelled control takes, so they line up down the pane.
    static let controlShare: CGFloat = 0.62

    /// The last row added, which a new section's heading leaves room after.
    private var lastRow: NSView?

    init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: Self.inset, right: Self.inset)
    }

    func reset() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        updates = []
        targets = []
        lastRow = nil
    }

    func update() {
        updates.forEach { $0() }
    }

    /// Controls at the size Mac inspectors use.
    @discardableResult
    func regular<Control: NSControl>(_ control: Control) -> Control {
        control.controlSize = .regular
        control.font = .systemFont(ofSize: NSFont.systemFontSize)
        return control
    }

    /// Runs `update` whenever the controls are brought up to date.
    func onUpdate(_ update: @escaping () -> Void) {
        updates.append(update)
    }

    // MARK: - Layout

    /// Starts a section under a heading, set apart from the one before by a line.
    func section(_ title: String) {
        if !stack.arrangedSubviews.isEmpty {
            if let lastRow { stack.setCustomSpacing(14, after: lastRow) }
            let separator = NSBox()
            separator.boxType = .separator
            add(separator, fill: true)
            stack.setCustomSpacing(12, after: separator)
        }
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.setAccessibilityRole(.staticText)
        add(heading)
    }

    func note(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        add(label, fill: true)
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A control with a label at the start of the row and the control at its
    /// end. Controls that fill take the same share of every row, so they line
    /// up down the pane; numbers keep their own size. With no label, the
    /// control takes the whole row.
    func row(_ title: String?, _ control: NSView) {
        if let control = control as? NSControl, !(control is NSTextField) { regular(control) }
        if let segments = control as? NSSegmentedControl { segments.segmentDistribution = .fillEqually }
        guard let title else { return add(control, fill: true) }
        let row = NSStackView()
        row.addView(label(title), in: .leading)
        row.addView(control, in: .trailing)
        if !(control is NumberView) {
            control.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: Self.controlShare).isActive = true
        }
        add(row, fill: true)
    }

    /// Two numbers on one row, such as X and Y, each with a short label.
    func pair(_ title: String?, _ first: (String, NSView), _ second: (String, NSView)) {
        let row = NSStackView()
        row.addView(label(title ?? ""), in: .leading)
        for (index, item) in [first, second].enumerated() {
            let short = NSTextField(labelWithString: item.0)
            short.textColor = .secondaryLabelColor
            row.addView(short, in: .trailing)
            row.addView(item.1, in: .trailing)
            if index == 0 { row.setCustomSpacing(10, after: item.1) }
        }
        add(row, fill: true)
    }

    func add(_ view: NSView, fill: Bool = false) {
        stack.addArrangedSubview(view)
        lastRow = view
        if fill {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
        }
    }

    // MARK: - Controls

    func checkbox(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let box = regular(NSButton(checkboxWithTitle: title, target: nil, action: nil))
        bind(box) { set(box.state == .on) }
        updates.append { box.state = get() ? .on : .off }
        return box
    }

    func button(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> NSButton {
        let button = regular(NSButton(title: title, target: nil, action: nil))
        button.bezelStyle = .push
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        bind(button, action)
        return button
    }

    /// A borderless button showing a symbol.
    func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: nil, action: nil)
        button.isBordered = false
        button.toolTip = label
        bind(button, action)
        return button
    }

    /// A pop-up of titles; `get` gives the index shown, or `nil` for none of them.
    func popup(_ titles: [String], get: @escaping () -> Int?, set: @escaping (Int) -> Void) -> NSPopUpButton {
        let popup = regular(NSPopUpButton())
        popup.addItems(withTitles: titles)
        bind(popup) { set(popup.indexOfSelectedItem) }
        updates.append {
            if let index = get(), titles.indices.contains(index) {
                popup.selectItem(at: index)
            } else {
                popup.select(nil)
            }
        }
        return popup
    }

    /// A number with a stepper beside it, and the unit it is in, if given.
    func number(
        get: @escaping () -> Double, set: @escaping (Double) -> Void, range: ClosedRange<Double>, step: Double,
        unit: String = ""
    ) -> NSView {
        let field = regular(NSTextField())
        field.alignment = .right
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        let preferred = field.widthAnchor.constraint(equalToConstant: 56)
        preferred.priority = .defaultLow
        preferred.isActive = true
        let stepper = regular(NSStepper())
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        bind(field) { set(min(max(field.doubleValue, range.lowerBound), range.upperBound)) }
        bind(stepper) { set(stepper.doubleValue) }
        updates.append {
            let value = get()
            stepper.doubleValue = value
            if field.currentEditor() == nil { field.doubleValue = value }
        }
        let views: [NSView] = [field, stepper]
        let stack = NumberView(views: views)
        if !unit.isEmpty {
            let unitLabel = NSTextField(labelWithString: unit)
            unitLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(unitLabel)
        }
        stack.spacing = 4
        return stack
    }

    /// Text set when it is committed, by Return or by leaving the field.
    func text(placeholder: String, get: @escaping () -> String, set: @escaping (String) -> Void) -> NSTextField {
        let field = regular(NSTextField())
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        bind(field) { set(field.stringValue) }
        updates.append { if field.currentEditor() == nil { field.stringValue = get() } }
        return field
    }

    /// Segments that each turn something on or off.
    func toggles(_ symbols: [(String, String)], get: @escaping () -> [Bool], toggle: @escaping (Int) -> Void) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            images: symbols.compactMap { NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1) },
            trackingMode: .selectAny, target: nil, action: nil
        )
        regular(control)
        for (index, symbol) in symbols.enumerated() { control.setToolTip(symbol.1, forSegment: index) }
        var shown: [Bool] = []
        bind(control) {
            for index in 0..<control.segmentCount where control.isSelected(forSegment: index) != shown[safe: index] {
                toggle(index)
            }
        }
        updates.append {
            shown = get()
            for (index, isOn) in shown.enumerated() where index < control.segmentCount {
                control.setSelected(isOn, forSegment: index)
            }
        }
        return control
    }

    /// Segments of which one is chosen.
    func choice(_ symbols: [(String, String)], get: @escaping () -> Int?, set: @escaping (Int) -> Void) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            images: symbols.compactMap { NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1) },
            trackingMode: .selectOne, target: nil, action: nil
        )
        regular(control)
        for (index, symbol) in symbols.enumerated() { control.setToolTip(symbol.1, forSegment: index) }
        bind(control) { set(control.selectedSegment) }
        updates.append { control.selectedSegment = get() ?? -1 }
        return control
    }

    /// Segments that each do something once.
    func actions(_ symbols: [(String, String)], perform: @escaping (Int) -> Void) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            images: symbols.compactMap { NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1) },
            trackingMode: .momentary, target: nil, action: nil
        )
        regular(control)
        for (index, symbol) in symbols.enumerated() { control.setToolTip(symbol.1, forSegment: index) }
        bind(control) { perform(control.selectedSegment) }
        return control
    }

    /// A colour pop-up: the theme's colours, the system colours, and any
    /// other from the colour panel. With `noneTitle`, a first item for none,
    /// which with `noneIsAutomatic` means what the layout gives rather than nothing.
    func color(
        choices: [ColorChoice], noneTitle: String? = nil, noneIsAutomatic: Bool = false,
        resolve: @escaping (DrawingColor) -> CGColor,
        get: @escaping () -> (color: DrawingColor?, isNone: Bool), set: @escaping (DrawingColor?) -> Void
    ) -> NSPopUpButton {
        let popup = NSPopUpButton()
        regular(popup)
        let menu = NSMenu()
        let custom = NSMenuItem(title: String(localized: "Mac.Inspector.CustomColour"), action: nil, keyEquivalent: "")
        menu.addItem(custom)
        if let noneTitle {
            let none = NSMenuItem(title: noneTitle, action: nil, keyEquivalent: "")
            none.image = noneIsAutomatic ? Self.automaticSwatch : Self.swatch(nil)
            menu.addItem(none)
        }
        for (index, choice) in choices.enumerated() {
            if index > 0, choice.id.hasPrefix("theme.") != choices[index - 1].id.hasPrefix("theme.") { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.label, action: nil, keyEquivalent: "")
            item.image = Self.swatch(choice.display)
            item.representedObject = choice.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let more = NSMenuItem(title: String(localized: "ColorSwatches.MoreColours"), action: nil, keyEquivalent: "")
        menu.addItem(more)
        popup.menu = menu
        let panelTarget = ActionTarget {
            let color = NSColorPanel.shared.color.usingColorSpace(.sRGB) ?? .black
            let hex = UInt32((color.redComponent * 255).rounded()) << 16 | UInt32((color.greenComponent * 255).rounded()) << 8
                | UInt32((color.blueComponent * 255).rounded())
            set(.rgb(hex))
        }
        targets.append(panelTarget)
        bind(popup) {
            guard let item = popup.selectedItem else { return }
            if item === more {
                let panel = NSColorPanel.shared
                panel.showsAlpha = false
                panel.isContinuous = false
                panel.setTarget(panelTarget)
                panel.setAction(#selector(ActionTarget.run(_:)))
                panel.orderFront(nil)
            } else if item.title == noneTitle, item.representedObject == nil, noneTitle != nil {
                set(nil)
            } else if let id = item.representedObject as? String, let choice = choices.first(where: { $0.id == id }) {
                set(choice.value)
            }
        }
        updates.append {
            let (color, isNone) = get()
            custom.isHidden = true
            if isNone, noneTitle != nil {
                popup.selectItem(at: 1)
            } else if let color, let choice = choices.first(where: { $0.value == color }),
                      let item = menu.items.first(where: { $0.representedObject as? String == choice.id }) {
                popup.select(item)
            } else if let color {
                // Named by its value, as the system colour panel shows it.
                let shown = resolve(color)
                custom.isHidden = false
                custom.title = Self.hex(shown)
                custom.image = Self.swatch(shown)
                popup.select(custom)
            } else {
                // Nothing of its own: what the theme or layout gives.
                custom.isHidden = false
                custom.title = String(localized: "Fill.Automatic")
                custom.image = Self.automaticSwatch
                popup.select(custom)
            }
        }
        return popup
    }

    /// A colour written as #RRGGBB.
    static func hex(_ color: CGColor) -> String {
        guard let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "#000000" }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(srgb.redComponent), channel(srgb.greenComponent), channel(srgb.blueComponent))
    }

    /// A square split light and dark across its diagonal: whatever the
    /// theme or layout gives, rather than a colour of its own.
    static let automaticSwatch = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
        let square = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: square, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.white.setFill()
        square.fill()
        let dark = NSBezierPath()
        dark.move(to: NSPoint(x: square.maxX, y: square.minY))
        dark.line(to: NSPoint(x: square.maxX, y: square.maxY))
        dark.line(to: NSPoint(x: square.minX, y: square.maxY))
        dark.close()
        NSColor.secondaryLabelColor.setFill()
        dark.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        return true
    }

    /// A small square of colour for a menu item; with none, a crossed-out square.
    static func swatch(_ color: CGColor?) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if let color {
                (NSColor(cgColor: color) ?? .black).setFill()
                path.fill()
            } else {
                NSColor.white.setFill()
                path.fill()
                NSColor.systemRed.setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 2))
                line.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
                line.lineWidth = 1.5
                line.stroke()
            }
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    // MARK: - Actions

    private func bind(_ control: NSControl, _ action: @escaping () -> Void) {
        let target = ActionTarget(action)
        targets.append(target)
        control.target = target
        control.action = #selector(ActionTarget.run(_:))
    }
}

/// A number field with its stepper and unit, which keeps its own size in a row.
final class NumberView: NSStackView {}

/// Calls a closure when a control acts.
@MainActor
final class ActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run(_ sender: Any?) {
        action()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
