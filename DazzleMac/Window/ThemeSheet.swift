import AppKit
import DazzleEngine

/// Theme Colours & Fonts: the theme's twelve colours and its heading and
/// body fonts, which every slide that refers to them follows.
@MainActor
final class ThemeSheet: NSObject {
    private let deck: Deck
    private var theme: Theme
    private var window: NSWindow?

    private var wells: [String: NSColorWell] = [:]
    private let headingFont = NSPopUpButton()
    private let bodyFont = NSPopUpButton()

    init(deck: Deck) {
        self.deck = deck
        theme = deck.state.theme(in: deck.presentation)
        super.init()
    }

    func present(over parent: NSWindow) {
        // One grid for colours and fonts, so their labels share a column.
        let colorRows: [[NSView]] = ThemeColorSlot.all.map { slot, key in
            let well = NSColorWell(style: .minimal)
            well.color = NSColor(cgColor: RGBAColor(hex: theme.colors[slot] ?? 0).cgColor) ?? .black
            well.supportsAlpha = false
            well.setAccessibilityIdentifier("themeColor.\(slot)")
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            wells[slot] = well
            return [NSTextField(labelWithString: ThemeColorSlot.label(key)), well]
        }
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        let fontRows: [[NSView]] = [
            [NSTextField(labelWithString: String(localized: "Theme.HeadingFont")), fill(headingFont, families: families, selected: theme.majorFont)],
            [NSTextField(labelWithString: String(localized: "Theme.BodyFont")), fill(bodyFont, families: families, selected: theme.minorFont)],
        ]
        let grid = NSGridView(views: [[heading("Theme.Colors"), NSGridCell.emptyContentView]] + colorRows
            + [[heading("Theme.Fonts"), NSGridCell.emptyContentView]] + fontRows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.yPlacement = .center
        for index in [0, colorRows.count + 1] {
            let row = grid.row(at: index)
            row.mergeCells(in: NSRange(location: 0, length: 2))
            row.cell(at: 0).xPlacement = .leading
            row.topPadding = index == 0 ? 0 : 12
        }

        let note = NSTextField(wrappingLabelWithString: String(localized: "Theme.Footer"))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // As wide as the grid above it, so it wraps inside the sheet in any language.
        let width = grid.fittingSize.width
        note.preferredMaxLayoutWidth = width
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: width).isActive = true
        let cancel = NSButton(title: String(localized: "Common.Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: String(localized: "Common.OK"), target: self, action: #selector(apply(_:)))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, apply])

        let stack = NSStackView(views: [grid, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(12, after: grid)
        stack.setCustomSpacing(18, after: note)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = String(localized: "Panel.Theme.Title")
        window.contentView = stack
        self.window = window
        window.setContentSize(stack.fittingSize)
        parent.beginSheet(window)
    }

    private func heading(_ key: String.LocalizationValue) -> NSTextField {
        let label = NSTextField(labelWithString: String(localized: key))
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    /// Every family on the Mac, with the theme's own first if the Mac lacks it.
    private func fill(_ popUp: NSPopUpButton, families: [String], selected: String) -> NSPopUpButton {
        if !families.contains(selected) {
            popUp.addItem(withTitle: selected)
            popUp.menu?.addItem(.separator())
        }
        popUp.addItems(withTitles: families)
        popUp.selectItem(withTitle: selected)
        // A set width: left to itself, the popup grows to its longest family name.
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return popUp
    }

    @objc private func apply(_ sender: Any?) {
        var edited = theme
        for (slot, well) in wells {
            guard let color = well.color.usingColorSpace(.sRGB) else { continue }
            let rgb = RGBAColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
            // A colour picked again as it was keeps its exact value.
            if rgb.hexValue != RGBAColor(hex: theme.colors[slot] ?? 0).hexValue { edited.colors[slot] = rgb.hexValue }
        }
        if let family = headingFont.titleOfSelectedItem { edited.majorFont = family }
        if let family = bodyFont.titleOfSelectedItem { edited.minorFont = family }
        let state = deck.state
        if edited != theme {
            deck.edit { state.setTheme(edited, in: &$0) }
        }
        dismiss()
    }

    @objc private func cancel(_ sender: Any?) { dismiss() }

    private func dismiss() {
        NSColorPanel.shared.orderOut(nil)
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        self.window = nil
    }
}
