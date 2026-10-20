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

    static let labelWidth: CGFloat = 92
    /// Sections the user has folded away, kept as they rebuild.
    private static var collapsed: Set<String> = []

    private struct Section {
        let title: String
        let disclosure: NSButton
        var views: [NSView] = []
    }

    private var sections: [Section] = []

    init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 20, right: 16)
    }

    func reset() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        updates = []
        targets = []
        sections = []
    }

    func update() {
        updates.forEach { $0() }
        applyCollapsing()
    }

    /// Controls at the size Mac inspectors use, so more fits without scrolling.
    @discardableResult
    func small<Control: NSControl>(_ control: Control) -> Control {
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return control
    }

    /// Runs `update` whenever the controls are brought up to date.
    func onUpdate(_ update: @escaping () -> Void) {
        updates.append(update)
    }

    // MARK: - Layout

    /// Starts a section under a heading that folds it away when clicked.
    func section(_ title: String) {
        if !stack.arrangedSubviews.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            stack.addArrangedSubview(separator)
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            stack.setCustomSpacing(10, after: separator)
        }
        let disclosure = NSButton(title: title, target: nil, action: nil)
        disclosure.isBordered = false
        disclosure.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        disclosure.imagePosition = .imageTrailing
        disclosure.imageHugsTitle = true
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.setAccessibilityLabel(title)
        stack.addArrangedSubview(disclosure)
        let index = sections.count
        sections.append(Section(title: title, disclosure: disclosure))
        bind(disclosure) { [unowned self] in
            if Self.collapsed.contains(title) { Self.collapsed.remove(title) } else { Self.collapsed.insert(title) }
            // Shown again, the section's rows take up what they should show.
            sections[index].views.forEach { $0.isHidden = false }
            update()
        }
    }

    /// Hides the rows of folded sections, and marks each heading's state.
    private func applyCollapsing() {
        for section in sections {
            let isCollapsed = Self.collapsed.contains(section.title)
            section.disclosure.image = NSImage(
                systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            section.disclosure.setAccessibilityExpanded(!isCollapsed)
            if isCollapsed { section.views.forEach { $0.isHidden = true } }
        }
    }

    func note(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        add(label, fill: true)
    }

    private func label(_ title: String?, width: CGFloat? = InspectorForm.labelWidth) -> NSTextField {
        let label = NSTextField(labelWithString: title ?? "")
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        if let width {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return label
    }

    /// A control with a label before it.
    func row(_ title: String?, _ control: NSView) {
        if let control = control as? NSControl, control.controlSize != .small, !(control is NSTextField) { small(control) }
        let row = NSStackView(views: [label(title), control])
        row.spacing = 8
        row.alignment = .firstBaseline
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add(row, fill: true)
    }

    /// Two controls on one row, such as X and Y, each with a short label.
    func pair(_ title: String?, _ first: (String, NSView), _ second: (String, NSView)) {
        let row = NSStackView(views: [label(title), label(first.0, width: nil), first.1, label(second.0, width: nil), second.1])
        row.spacing = 4
        row.setCustomSpacing(8, after: row.arrangedSubviews[0])
        row.setCustomSpacing(10, after: first.1)
        row.alignment = .firstBaseline
        add(row, fill: true)
        // The two halves share the room evenly.
        first.1.widthAnchor.constraint(equalTo: second.1.widthAnchor).isActive = true
    }

    func add(_ view: NSView, fill: Bool = false) {
        stack.addArrangedSubview(view)
        if !sections.isEmpty { sections[sections.count - 1].views.append(view) }
        if fill {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
    }

    // MARK: - Controls

    func checkbox(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let box = small(NSButton(checkboxWithTitle: title, target: nil, action: nil))
        bind(box) { set(box.state == .on) }
        updates.append { box.state = get() ? .on : .off }
        return box
    }

    func button(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> NSButton {
        let button = small(NSButton(title: title, target: nil, action: nil))
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
        let popup = small(NSPopUpButton())
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
        let field = small(NSTextField())
        field.alignment = .right
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let preferred = field.widthAnchor.constraint(equalToConstant: 58)
        preferred.priority = .defaultLow
        preferred.isActive = true
        let stepper = small(NSStepper())
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
        let unitLabel = label(unit, width: nil)
        unitLabel.alignment = .left
        let views: [NSView] = unit.isEmpty ? [field, stepper] : [field, unitLabel, stepper]
        let stack = NSStackView(views: views)
        stack.spacing = 2
        return stack
    }

    /// Text set when it is committed, by Return or by leaving the field.
    func text(placeholder: String, get: @escaping () -> String, set: @escaping (String) -> Void) -> NSTextField {
        let field = small(NSTextField())
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
        small(control)
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
        small(control)
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
        for (index, symbol) in symbols.enumerated() { control.setToolTip(symbol.1, forSegment: index) }
        bind(control) { perform(control.selectedSegment) }
        return control
    }

    /// A colour pop-up: the theme's colours, the system colours, and any
    /// other from the colour panel. With `noneTitle`, a first item for none.
    func color(
        choices: [ColorChoice], noneTitle: String? = nil, resolve: @escaping (DrawingColor) -> CGColor,
        get: @escaping () -> (color: DrawingColor?, isNone: Bool), set: @escaping (DrawingColor?) -> Void
    ) -> NSPopUpButton {
        let popup = NSPopUpButton()
        let menu = NSMenu()
        let custom = NSMenuItem(title: String(localized: "Mac.Inspector.CustomColour"), action: nil, keyEquivalent: "")
        menu.addItem(custom)
        if let noneTitle {
            let none = NSMenuItem(title: noneTitle, action: nil, keyEquivalent: "")
            none.image = Self.swatch(nil)
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
                custom.isHidden = false
                custom.title = String(localized: "Mac.Inspector.CustomColour")
                custom.image = Self.swatch(resolve(color))
                popup.select(custom)
            } else {
                // Nothing of its own: what the theme or layout gives.
                custom.isHidden = false
                custom.title = String(localized: "Fill.Automatic")
                custom.image = nil
                popup.select(custom)
            }
        }
        return popup
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
