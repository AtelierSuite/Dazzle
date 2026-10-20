import AppKit
import DazzleEngine

/// The slides down the side of the window: click one to edit it, drag one
/// to move it, and with the list focused, copy, cut, paste and delete act
/// on slides.
@MainActor
final class NavigatorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSMenuItemValidation {
    private let deck: Deck
    private let tableView = SlideTableView()
    /// The slides the table was last loaded with.
    private var shownIDs: [Slide.ID] = []
    /// Set while the table's selection is being made to match the editor's,
    /// so that doing so isn't taken for the user picking a slide.
    private var isMatchingSelection = false
    private var observing: Observing?
    private var lastWidth: CGFloat = 0

    private static let rowType = NSPasteboard.PasteboardType("com.tsubuzaki.Dazzle.slide-row")
    private static let numberWidth: CGFloat = 28
    private static let rowPadding: CGFloat = 8

    init(deck: Deck) {
        self.deck = deck
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("slide"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        tableView.setAccessibilityLabel(String(localized: "Mac.Navigator.Accessibility"))
        tableView.setAccessibilityIdentifier("slideNavigator")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observing = Observing { [weak self] in self?.refresh() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }

    // MARK: - Keeping current

    private func refresh() {
        let presentation = deck.presentation
        let ids = presentation.slides.map(\.id)
        if ids != shownIDs {
            shownIDs = ids
            tableView.reloadData()
        } else {
            let visible = tableView.rows(in: tableView.visibleRect)
            for row in visible.lowerBound..<visible.upperBound where presentation.slides.indices.contains(row) {
                (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SlideRowView)?
                    .show(presentation.slides[row], number: row + 1, in: presentation)
            }
        }
        if let index = presentation.index(of: deck.state.selectedSlideID), tableView.selectedRow != index {
            isMatchingSelection = true
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
            isMatchingSelection = false
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { shownIDs.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard deck.presentation.slides.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let string = info.draggingPasteboard.string(forType: Self.rowType), let from = Int(string),
              deck.presentation.slides.indices.contains(from) else { return false }
        let id = deck.presentation.slides[from].id
        let destination = row > from ? row - 1 : row
        let state = deck.state
        deck.edit { state.moveSlide(id, to: destination, in: &$0) }
        state.selectSlide(id)
        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let presentation = deck.presentation
        guard presentation.slides.indices.contains(row) else { return nil }
        let view = tableView.makeView(withIdentifier: SlideRowView.identifier, owner: nil) as? SlideRowView ?? SlideRowView()
        view.show(presentation.slides[row], number: row + 1, in: presentation)
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = max(tableView.bounds.width - Self.numberWidth - Self.rowPadding * 3, 40)
        return width / max(deck.presentation.slideSize.aspectRatio, 0.1) + Self.rowPadding
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isMatchingSelection, deck.presentation.slides.indices.contains(tableView.selectedRow) else { return }
        deck.state.selectSlide(deck.presentation.slides[tableView.selectedRow].id)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard deck.presentation.slides.indices.contains(row) else { return }
        // The menu acts on the slide it was opened on.
        deck.state.selectSlide(deck.presentation.slides[row].id)
        let slide = deck.presentation.slides[row]
        func add(_ key: String.LocalizationValue, _ action: Selector) {
            menu.addItem(NSMenuItem(title: String(localized: key), action: action, keyEquivalent: ""))
        }
        add("Slide.Menu.Play", #selector(DocumentWindowController.playSlideshow(_:)))
        menu.addItem(.separator())
        add("Slide.New", #selector(DocumentWindowController.newSlide(_:)))
        add("Slide.Menu.Duplicate", #selector(DocumentWindowController.duplicateSlide(_:)))
        menu.addItem(.separator())
        add("Edit.Cut", #selector(cut(_:)))
        add("Edit.Copy", #selector(copy(_:)))
        add("Edit.PasteAfter", #selector(paste(_:)))
        menu.addItem(.separator())
        add(slide.isHidden ? "Slide.Menu.Show" : "Slide.Menu.Hide", #selector(DocumentWindowController.toggleSlideHidden(_:)))
        add("Slide.Menu.MoveUp", #selector(DocumentWindowController.moveSlideEarlier(_:)))
        add("Slide.Menu.MoveDown", #selector(DocumentWindowController.moveSlideLater(_:)))
        menu.addItem(.separator())
        add("Slide.Menu.Delete", #selector(DocumentWindowController.deleteSlide(_:)))
    }

    // MARK: - Editing slides

    private var selectedID: Slide.ID? { deck.selectedSlide?.id }

    @objc func copy(_ sender: Any?) {
        guard let selectedID else { return }
        deck.state.copySlides([selectedID], in: deck.presentation)
    }

    @objc func cut(_ sender: Any?) {
        guard let selectedID else { return }
        let state = deck.state
        deck.edit { state.cutSlide(selectedID, in: &$0) }
    }

    /// Pastes after the selected slide: slides as they are, or shapes and
    /// pictures onto the slide.
    @objc func paste(_ sender: Any?) {
        let state = deck.state
        deck.edit { state.paste(in: &$0) }
    }

    @objc func delete(_ sender: Any?) {
        guard let selectedID else { return }
        let state = deck.state
        deck.edit { state.deleteSlide(selectedID, in: &$0) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cut(_:)), #selector(delete(_:)):
            if menuItem.action == #selector(cut(_:)) { menuItem.title = String(localized: "Edit.CutSlide") }
            return deck.presentation.slides.count > 1
        case #selector(copy(_:)):
            menuItem.title = String(localized: "Edit.CopySlide")
            return selectedID != nil
        default:
            return true
        }
    }
}

/// The navigator's table, which sends Delete to its controller.
final class SlideTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.specialKey == .delete || event.specialKey == .deleteForward {
            NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: self)
            return
        }
        super.keyDown(with: event)
    }
}

/// One slide in the navigator: its number, and a picture of it.
final class SlideRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SlideRow")

    private let number = NSTextField(labelWithString: "")
    private let thumbnail = SlideThumbnailView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        number.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        number.textColor = .secondaryLabelColor
        number.alignment = .right
        number.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(number)
        addSubview(thumbnail)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor),
            number.widthAnchor.constraint(equalToConstant: 22),
            number.topAnchor.constraint(equalTo: thumbnail.topAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            thumbnail.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            thumbnail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    func show(_ slide: Slide, number: Int, in presentation: Presentation) {
        self.number.stringValue = String(number)
        thumbnail.show(slide, in: presentation)
        setAccessibilityLabel(String(
            format: String(localized: "Slide.Accessibility"), number, slide.title ?? String(localized: "Slide.Untitled")
        ))
    }
}

/// A slide, drawn small, redrawn only when it or what it is drawn from changes.
final class SlideThumbnailView: NSView {
    private var slide: Slide?
    private var presentation: Presentation?

    override var isFlipped: Bool { true }

    func show(_ slide: Slide, in presentation: Presentation) {
        let changed = slide != self.slide || presentation.slideSize != self.presentation?.slideSize
            || presentation.resources != self.presentation?.resources
        self.slide = slide
        self.presentation = presentation
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let slide, let presentation, let context = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        if slide.isHidden { context.setAlpha(0.45) }
        SlideRenderer(presentation: presentation, slide: slide).draw(in: context, size: bounds.size)
        context.restoreGState()
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        if slide.isHidden, let eye = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil) {
            let size: CGFloat = 14
            let rect = CGRect(x: bounds.maxX - size - 5, y: bounds.maxY - size - 5, width: size, height: size)
            eye.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
