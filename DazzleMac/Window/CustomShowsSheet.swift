import AppKit
import DazzleEngine

/// Custom Shows: the presentation's named selections of slides. Each is
/// made, renamed and removed on the left; on the right, its slides are
/// chosen from the presentation's and put in order. Changes are made as
/// they happen, each one undoable.
@MainActor
final class CustomShowsSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let deck: Deck
    private let play: (CustomShow.ID) -> Void
    private var window: NSWindow?
    private var observing: Observing?

    private let shows = NSTableView()
    private let available = NSTableView()
    private let chosen = NSTableView()
    private let name = NSTextField()
    private let addShow = NSButton()
    private let removeShow = NSButton()
    private let duplicateShow = NSButton()
    private let addSlides = NSButton()
    private let removeSlides = NSButton()
    private let moveUp = NSButton()
    private let moveDown = NSButton()
    private let playButton = NSButton()

    /// The show being edited.
    private var selectedID: CustomShow.ID?

    init(deck: Deck, play: @escaping (CustomShow.ID) -> Void) {
        self.deck = deck
        self.play = play
        selectedID = deck.presentation.customShows.first?.id
        super.init()
    }

    private var presentation: Presentation { deck.presentation }
    private var selectedShow: CustomShow? { presentation.customShow(withID: selectedID) }
    /// The selected show's slides still in the presentation, as indices into it.
    private var chosenIndices: [Int] { selectedShow.map { $0.slideIDs.compactMap(presentation.index(of:)) } ?? [] }

    func present(over parent: NSWindow) {
        configure(shows, column: "CustomShow.Title", identifier: "customShowList")
        configure(available, column: "CustomShow.AllSlides", identifier: "customShowAvailable")
        configure(chosen, column: "CustomShow.InShow", identifier: "customShowSlides")
        available.allowsMultipleSelection = true
        chosen.allowsMultipleSelection = true
        available.doubleAction = #selector(addChosenSlides(_:))
        chosen.doubleAction = #selector(removeChosenSlides(_:))

        symbolButton(addShow, "plus", "CustomShow.New", #selector(newShow(_:)))
        symbolButton(removeShow, "minus", "CustomShow.Delete", #selector(deleteShow(_:)))
        symbolButton(duplicateShow, "plus.square.on.square", "CustomShow.Duplicate", #selector(duplicate(_:)))
        symbolButton(addSlides, "chevron.right", "CustomShow.Add", #selector(addChosenSlides(_:)))
        symbolButton(removeSlides, "chevron.left", "CustomShow.Remove", #selector(removeChosenSlides(_:)))
        symbolButton(moveUp, "chevron.up", "CustomShow.MoveUp", #selector(moveEarlier(_:)))
        symbolButton(moveDown, "chevron.down", "CustomShow.MoveDown", #selector(moveLater(_:)))
        name.placeholderString = String(localized: "CustomShow.Name")
        name.delegate = self
        name.setAccessibilityIdentifier("customShowName")
        playButton.title = String(localized: "CustomShow.Play")
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.imagePosition = .imageLeading
        playButton.bezelStyle = .push
        playButton.target = self
        playButton.action = #selector(playShow(_:))
        let done = NSButton(title: String(localized: "Common.Done"), target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"

        let showButtons = NSStackView(views: [addShow, removeShow, duplicateShow])
        showButtons.spacing = 4
        let left = NSStackView(views: [scroll(shows, width: 200), showButtons])
        left.orientation = .vertical
        left.alignment = .leading

        let middle = NSStackView(views: [addSlides, removeSlides])
        middle.orientation = .vertical
        let order = NSStackView(views: [moveUp, moveDown])
        order.orientation = .vertical
        let slides = NSStackView(views: [scroll(available, width: 220), middle, scroll(chosen, width: 220), order])
        slides.alignment = .centerY
        let nameRow = NSStackView(views: [NSTextField(labelWithString: String(localized: "CustomShow.Name")), name])
        let right = NSStackView(views: [nameRow, slides])
        right.orientation = .vertical
        right.alignment = .leading
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let content = NSStackView(views: [left, right])
        content.alignment = .top
        content.spacing = 20
        let note = NSTextField(wrappingLabelWithString: String(localized: "CustomShow.Footer"))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 720
        let buttons = NSStackView(views: [playButton, NSView(), done])
        let stack = NSStackView(views: [content, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 420), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = String(localized: "CustomShow.Title")
        window.contentView = stack
        self.window = window
        // Undo, or an edit elsewhere, shows here at once.
        observing = Observing { [weak self] in
            guard let self else { return }
            _ = self.deck.presentation
            self.reload()
        }
        reload()
        window.setContentSize(stack.fittingSize)
        parent.beginSheet(window)
    }

    // MARK: - Building

    private func configure(_ table: NSTableView, column title: String.LocalizationValue, identifier: String) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.title = String(localized: title)
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityIdentifier(identifier)
    }

    private func scroll(_ table: NSTableView, width: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        return scroll
    }

    private func symbolButton(_ button: NSButton, _ symbol: String, _ label: String.LocalizationValue, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: String(localized: label))
        button.bezelStyle = .smallSquare
        button.toolTip = String(localized: label)
        button.target = self
        button.action = action
    }

    private func reload() {
        if selectedShow == nil { selectedID = presentation.customShows.first?.id }
        shows.reloadData()
        if let index = presentation.customShows.firstIndex(where: { $0.id == selectedID }) {
            shows.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            shows.deselectAll(nil)
        }
        available.reloadData()
        chosen.reloadData()
        if name.currentEditor() == nil { name.stringValue = selectedShow?.name ?? "" }
        updateEnabling()
    }

    private func updateEnabling() {
        let hasShow = selectedShow != nil
        name.isEnabled = hasShow
        removeShow.isEnabled = hasShow
        duplicateShow.isEnabled = hasShow
        addSlides.isEnabled = hasShow && !available.selectedRowIndexes.isEmpty
        removeSlides.isEnabled = hasShow && !chosen.selectedRowIndexes.isEmpty
        moveUp.isEnabled = hasShow && (chosen.selectedRowIndexes.first ?? 0) > 0
        moveDown.isEnabled = hasShow && (chosen.selectedRowIndexes.last.map { $0 < chosenIndices.count - 1 } ?? false)
        playButton.isEnabled = !chosenIndices.isEmpty
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case shows: presentation.customShows.count
        case available: presentation.slides.count
        default: chosenIndices.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        switch tableView {
        case shows:
            text = presentation.customShows[row].name
        case available:
            text = label(forSlideAt: row)
        default:
            text = label(forSlideAt: chosenIndices[row])
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    private func label(forSlideAt index: Int) -> String {
        let slide = presentation.slides[index]
        return "\(index + 1). \(slide.title ?? String(localized: "Slide.Untitled"))"
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === shows {
            let row = shows.selectedRow
            let id = presentation.customShows.indices.contains(row) ? presentation.customShows[row].id : nil
            if id != selectedID {
                selectedID = id
                chosen.deselectAll(nil)
                reload()
            }
        }
        updateEnabling()
    }

    // MARK: - Editing

    private func edit(_ change: (EditorState, inout Presentation) -> Void) {
        let state = deck.state
        deck.edit { change(state, &$0) }
        reload()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let id = selectedID else { return }
        let text = name.stringValue
        edit { state, presentation in state.renameCustomShow(id, to: text, in: &presentation) }
    }

    @objc private func newShow(_ sender: Any?) {
        let first = deck.selectedSlide.map { [$0.id] } ?? []
        edit { state, presentation in selectedID = state.addCustomShow(slides: first, in: &presentation) }
        window?.makeFirstResponder(name)
    }

    @objc private func deleteShow(_ sender: Any?) {
        guard let id = selectedID else { return }
        edit { state, presentation in state.deleteCustomShow(id, in: &presentation) }
    }

    @objc private func duplicate(_ sender: Any?) {
        guard let id = selectedID else { return }
        edit { state, presentation in
            state.duplicateCustomShow(id, in: &presentation)
            selectedID = presentation.customShows.last?.id
        }
    }

    @objc private func addChosenSlides(_ sender: Any?) {
        guard let id = selectedID, let show = selectedShow else { return }
        let added = available.selectedRowIndexes.map { presentation.slides[$0].id }
        guard !added.isEmpty else { return }
        let slides = show.slideIDs.filter { presentation.index(of: $0) != nil } + added
        edit { state, presentation in state.setCustomShowSlides(id, to: slides, in: &presentation) }
        chosen.selectRowIndexes(IndexSet((slides.count - added.count)..<slides.count), byExtendingSelection: false)
    }

    @objc private func removeChosenSlides(_ sender: Any?) {
        guard let id = selectedID else { return }
        let removed = chosen.selectedRowIndexes
        guard !removed.isEmpty else { return }
        let slides = chosenIndices.enumerated().filter { !removed.contains($0.offset) }.map { presentation.slides[$0.element].id }
        chosen.deselectAll(nil)
        edit { state, presentation in state.setCustomShowSlides(id, to: slides, in: &presentation) }
    }

    @objc private func moveEarlier(_ sender: Any?) { move(by: -1) }
    @objc private func moveLater(_ sender: Any?) { move(by: 1) }

    /// Moves the chosen slides of the show one place earlier or later, together.
    private func move(by offset: Int) {
        guard let id = selectedID else { return }
        let rows = chosen.selectedRowIndexes
        var slides = chosenIndices.map { presentation.slides[$0].id }
        guard let first = rows.first, let last = rows.last, first + offset >= 0, last + offset < slides.count else { return }
        let moving = rows.map { slides[$0] }
        slides = slides.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        slides.insert(contentsOf: moving, at: first + offset)
        edit { state, presentation in state.setCustomShowSlides(id, to: slides, in: &presentation) }
        chosen.selectRowIndexes(IndexSet((first + offset)..<(first + offset + moving.count)), byExtendingSelection: false)
        updateEnabling()
    }

    @objc private func playShow(_ sender: Any?) {
        guard let id = selectedID else { return }
        window?.makeFirstResponder(nil)
        dismiss()
        play(id)
    }

    @objc private func done(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        dismiss()
    }

    private func dismiss() {
        observing?.cancel()
        observing = nil
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        self.window = nil
    }
}
