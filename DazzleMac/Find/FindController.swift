import AppKit
import DazzleEngine

/// Finding text on every slide, in tables and in the speaker notes, and
/// replacing it, in a panel beside the presentation's window.
@MainActor
final class FindController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let deck: Deck
    private var query = FindQuery(text: "")
    private var matches: [FindMatch] = []
    private var observing: Observing?

    private lazy var panel = makePanel()
    private let searchField = NSSearchField()
    private let replaceField = NSTextField()
    private let matchCase = NSButton(checkboxWithTitle: String(localized: "Find.MatchCase"), target: nil, action: nil)
    private let wholeWords = NSButton(checkboxWithTitle: String(localized: "Find.WholeWords"), target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let resultsTable = NSTableView()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()

    init(deck: Deck) {
        self.deck = deck
        super.init()
    }

    var hasQuery: Bool { !query.text.isEmpty }

    func show(attachedTo window: NSWindow?) {
        if !panel.isVisible, let window {
            let frame = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 80))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if observing == nil {
            observing = Observing { [weak self] in self?.search() }
        }
    }

    func close() {
        observing?.cancel()
        observing = nil
        panel.orderOut(nil)
    }

    /// Moves to the next or previous match after the selected one.
    func step(forward: Bool, attachedTo window: NSWindow?) {
        guard !matches.isEmpty else { return show(attachedTo: window) }
        let selected = resultsTable.selectedRow
        let next = selected < 0 ? (forward ? 0 : matches.count - 1) : (selected + (forward ? 1 : matches.count - 1)) % matches.count
        resultsTable.selectRowIndexes([next], byExtendingSelection: false)
        resultsTable.scrollRowToVisible(next)
    }

    // MARK: - Searching

    private func search() {
        let found = query.text.isEmpty ? [] : deck.presentation.matches(for: query)
        guard found != matches else { return }
        let selected = resultsTable.selectedRow >= 0 && resultsTable.selectedRow < matches.count
            ? matches[resultsTable.selectedRow].id : nil
        matches = found
        resultsTable.reloadData()
        if let selected, let row = matches.firstIndex(where: { $0.id == selected }) {
            resultsTable.selectRowIndexes([row], byExtendingSelection: false)
        }
        countLabel.stringValue = query.text.isEmpty ? "" : String.localizedStringWithFormat(String(localized: "Find.Count"), matches.count)
        replaceAllButton.isEnabled = !matches.isEmpty
        replaceButton.isEnabled = resultsTable.selectedRow >= 0
    }

    @objc private func queryChanged(_ sender: Any?) {
        query.text = searchField.stringValue
        query.matchesCase = matchCase.state == .on
        query.matchesWholeWords = wholeWords.state == .on
        search()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField { queryChanged(nil) }
    }

    @objc private func replaceSelected(_ sender: Any?) {
        guard matches.indices.contains(resultsTable.selectedRow) else { return }
        let match = matches[resultsTable.selectedRow]
        let replacement = replaceField.stringValue
        deck.edit { $0.replace([match], with: replacement) }
    }

    @objc private func replaceAll(_ sender: Any?) {
        let matches = matches
        let replacement = replaceField.stringValue
        deck.edit { $0.replace(matches, with: replacement) }
    }

    /// Goes to the slide a match is on, and picks out the shape it is in.
    private func showMatch(_ match: FindMatch) {
        let state = deck.state
        state.selectSlide(match.slideID)
        switch match.place {
        case .shape(let id):
            state.selectedShapeID = id
        case .cell(let id, let position):
            state.selectedShapeID = id
            state.selectCell(position)
        case .notes:
            break
        }
    }

    // MARK: - Results

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let match = matches[row]
        let place = NSTextField(labelWithString: location(of: match))
        place.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        place.textColor = .secondaryLabelColor
        let excerpt = NSTextField(labelWithAttributedString: highlighted(match))
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.maximumNumberOfLines = 2
        let stack = NSStackView(views: [place, excerpt])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        replaceButton.isEnabled = resultsTable.selectedRow >= 0
        guard matches.indices.contains(resultsTable.selectedRow) else { return }
        showMatch(matches[resultsTable.selectedRow])
    }

    /// The excerpt with the match in bold.
    private func highlighted(_ match: FindMatch) -> NSAttributedString {
        let result = NSMutableAttributedString(string: match.excerpt, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        if match.excerptRange.location + match.excerptRange.length <= result.length {
            result.addAttributes([
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.controlAccentColor,
            ], range: match.excerptRange)
        }
        return result
    }

    private func location(of match: FindMatch) -> String {
        let number = (deck.presentation.index(of: match.slideID) ?? 0) + 1
        let slide = String(format: String(localized: "Find.Slide"), number)
        switch match.place {
        case .notes: return slide + " · " + String(localized: "Find.Notes")
        case .cell: return slide + " · " + String(localized: "Find.Table")
        case .shape: return slide
        }
    }

    // MARK: - Building

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true
        )
        panel.title = String(localized: "Panel.Find.Title")
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 260)

        searchField.placeholderString = String(localized: "Find.Placeholder")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityIdentifier("findText")
        replaceField.placeholderString = String(localized: "Find.ReplacePlaceholder")
        replaceField.setAccessibilityIdentifier("replaceText")
        for box in [matchCase, wholeWords] {
            box.target = self
            box.action = #selector(queryChanged(_:))
        }
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.usesAutomaticRowHeights = true
        resultsTable.style = .inset
        resultsTable.dataSource = self
        resultsTable.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = resultsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        replaceButton.title = String(localized: "Find.Replace")
        replaceButton.bezelStyle = .push
        replaceButton.target = self
        replaceButton.action = #selector(replaceSelected(_:))
        replaceButton.isEnabled = false
        replaceAllButton.title = String(localized: "Find.ReplaceAll")
        replaceAllButton.bezelStyle = .push
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll(_:))
        replaceAllButton.isEnabled = false
        let options = NSStackView(views: [matchCase, wholeWords])
        options.spacing = 12
        let buttons = NSStackView(views: [countLabel, NSView(), replaceButton, replaceAllButton])

        let stack = NSStackView(views: [searchField, replaceField, options, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        for view in [searchField, replaceField, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        panel.contentView = stack
        return panel
    }
}
