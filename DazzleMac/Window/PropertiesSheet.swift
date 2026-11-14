import AppKit
import DazzleEngine

/// File ▸ Properties: the presentation's title, author and the rest, and
/// when it was created and last saved.
@MainActor
final class PropertiesSheet: NSObject {
    private let deck: Deck
    private var window: NSWindow?
    private var fields: [DocumentProperties.Field: NSTextField] = [:]

    init(deck: Deck) {
        self.deck = deck
        super.init()
    }

    func present(over parent: NSWindow) {
        let properties = deck.presentation.properties
        let labels: [(DocumentProperties.Field, String)] = [
            (.title, "Properties.Title"), (.subject, "Properties.Subject"), (.author, "Properties.Author"),
            (.company, "Properties.Company"), (.keywords, "Properties.Keywords"), (.category, "Properties.Category"),
            (.comments, "Properties.Comments"),
        ]
        var rows: [[NSView]] = []
        for (field, key) in labels {
            let label = String(localized: String.LocalizationValue(key))
            let control = NSTextField(string: properties[field])
            control.placeholderString = label
            control.setAccessibilityIdentifier("property.\(field.rawValue)")
            if field == .comments {
                control.usesSingleLineMode = false
                control.cell?.wraps = true
                control.cell?.isScrollable = false
                control.heightAnchor.constraint(equalToConstant: 64).isActive = true
            }
            control.widthAnchor.constraint(equalToConstant: 300).isActive = true
            fields[field] = control
            rows.append([Self.label(label), control])
        }
        let history: [(String, String)] = [
            ("Properties.Created", Self.date(properties.created)),
            ("Properties.Modified", Self.date(properties.modified)),
            ("Properties.LastModifiedBy", properties.lastModifiedBy.nilIfEmpty ?? "—"),
        ] + (properties.revision.map { [("Properties.Revision", String($0))] } ?? [])
            + (properties.applicationDescription.nilIfEmpty.map { [("Properties.Application", $0)] } ?? [])
        for (key, value) in history {
            let text = NSTextField(labelWithString: value)
            text.textColor = .secondaryLabelColor
            text.isSelectable = true
            rows.append([Self.label(String(localized: String.LocalizationValue(key))), text])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.row(at: labels.count).topPadding = 10

        let cancel = NSButton(title: String(localized: "Common.Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: String(localized: "Common.OK"), target: self, action: #selector(apply(_:)))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        var views: [NSView] = [grid]
        if deck.presentation.keynoteSource != nil {
            let note = NSTextField(wrappingLabelWithString: String(localized: "Properties.Keynote.Footer"))
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.preferredMaxLayoutWidth = 380
            views.append(note)
        }
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = String(localized: "Panel.Properties.Title")
        window.contentView = stack
        self.window = window
        window.setContentSize(stack.fittingSize)
        parent.beginSheet(window)
    }

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private static func date(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    @objc private func apply(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        let values = fields.mapValues(\.stringValue)
        let state = deck.state
        if values.contains(where: { deck.presentation.properties[$0.key] != $0.value }) {
            deck.edit { presentation in
                for (field, value) in values { state.setProperty(field, to: value, in: &presentation) }
            }
        }
        dismiss()
    }

    @objc private func cancel(_ sender: Any?) { dismiss() }

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        self.window = nil
    }
}
