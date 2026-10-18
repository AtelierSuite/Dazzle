import AppKit
import DazzleEngine

/// Header & Footer: the date, the slide number and a footer along the
/// bottom of the slides, put on the slide being edited or on all of them.
@MainActor
final class HeaderFooterSheet: NSObject {
    private let deck: Deck
    private var settings: HeaderFooterSettings
    private var window: NSWindow?

    private let showsDate = NSButton(checkboxWithTitle: String(localized: "HeaderFooter.Date"), target: nil, action: nil)
    private let dateKind = NSSegmentedControl(
        labels: [String(localized: "HeaderFooter.Automatic"), String(localized: "HeaderFooter.Fixed")],
        trackingMode: .selectOne, target: nil, action: nil
    )
    private let dateFormat = NSPopUpButton()
    private let fixedDate = NSTextField()
    private let showsNumber = NSButton(checkboxWithTitle: String(localized: "HeaderFooter.SlideNumber"), target: nil, action: nil)
    private let showsFooter = NSButton(checkboxWithTitle: String(localized: "HeaderFooter.Footer"), target: nil, action: nil)
    private let footer = NSTextField()
    private let hidesOnTitle = NSButton(checkboxWithTitle: String(localized: "HeaderFooter.HideOnTitle"), target: nil, action: nil)

    init(deck: Deck) {
        self.deck = deck
        settings = deck.state.headerFooter(in: deck.presentation)
        super.init()
    }

    func present(over parent: NSWindow) {
        for control in [showsDate, dateKind, dateFormat, showsNumber, showsFooter, hidesOnTitle] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        dateFormat.addItems(withTitles: DateField.allCases.map { $0.string(for: Date()) })
        fixedDate.placeholderString = String(localized: "HeaderFooter.FixedDate")
        footer.placeholderString = String(localized: "HeaderFooter.FooterText")
        for field in [fixedDate, footer] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        showsDate.state = settings.showsDate ? .on : .off
        dateKind.selectedSegment = settings.updatesDate ? 0 : 1
        dateFormat.selectItem(at: DateField.allCases.firstIndex(of: settings.dateFormat) ?? 0)
        fixedDate.stringValue = settings.fixedDate
        showsNumber.state = settings.showsSlideNumber ? .on : .off
        showsFooter.state = settings.showsFooter ? .on : .off
        footer.stringValue = settings.footer
        hidesOnTitle.state = settings.hidesOnTitleSlide ? .on : .off

        let note = NSTextField(wrappingLabelWithString: String(localized: "HeaderFooter.Footer.Note"))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 320
        let cancel = NSButton(title: String(localized: "Common.Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let applyToSlide = NSButton(title: String(localized: "HeaderFooter.Apply"), target: self, action: #selector(applyToSlide(_:)))
        let applyToAll = NSButton(title: String(localized: "HeaderFooter.ApplyToAll"), target: self, action: #selector(applyToAll(_:)))
        applyToAll.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, NSView(), applyToSlide, applyToAll])
        let indented = { (view: NSView) -> NSView in
            let row = NSStackView(views: [view])
            row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            return row
        }
        let stack = NSStackView(views: [
            showsDate, indented(dateKind), indented(dateFormat), indented(fixedDate), showsNumber, showsFooter, indented(footer),
            hidesOnTitle, note, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: note)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = String(localized: "Panel.HeaderFooter.Title")
        window.contentView = stack
        self.window = window
        updateEnabling()
        window.setContentSize(stack.fittingSize)
        parent.beginSheet(window)
    }

    @objc private func changed(_ sender: Any?) {
        updateEnabling()
    }

    private func updateEnabling() {
        let date = showsDate.state == .on
        dateKind.isEnabled = date
        dateFormat.isEnabled = date
        dateFormat.superview?.isHidden = dateKind.selectedSegment != 0
        fixedDate.superview?.isHidden = dateKind.selectedSegment == 0
        fixedDate.isEnabled = date
        footer.isEnabled = showsFooter.state == .on
    }

    private func read() -> HeaderFooterSettings {
        var settings = settings
        settings.showsDate = showsDate.state == .on
        settings.updatesDate = dateKind.selectedSegment == 0
        let formats = DateField.allCases
        if formats.indices.contains(dateFormat.indexOfSelectedItem) { settings.dateFormat = formats[dateFormat.indexOfSelectedItem] }
        settings.fixedDate = fixedDate.stringValue
        settings.showsSlideNumber = showsNumber.state == .on
        settings.showsFooter = showsFooter.state == .on
        settings.footer = footer.stringValue
        settings.hidesOnTitleSlide = hidesOnTitle.state == .on
        return settings
    }

    private func apply(toAll: Bool) {
        window?.makeFirstResponder(nil)
        let settings = read()
        let state = deck.state
        deck.edit { state.applyHeaderFooter(settings, toAll: toAll, in: &$0) }
        dismiss()
    }

    @objc private func applyToSlide(_ sender: Any?) { apply(toAll: false) }
    @objc private func applyToAll(_ sender: Any?) { apply(toAll: true) }
    @objc private func cancel(_ sender: Any?) { dismiss() }

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        self.window = nil
    }
}
