import AppKit
import DazzleEngine

/// The slides down the side of the window: click one to edit it, drag one
/// to move it, and with the list focused, copy, cut, paste and delete act
/// on slides. Slides in sections are grouped under each section's name,
/// which folds them away and can be dragged to move the whole section.
@MainActor
final class NavigatorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSMenuItemValidation {
    private let deck: Deck
    private let tableView = SlideTableView()
    /// What a row of the table shows.
    private enum Row: Equatable {
        case section(SlideSection.ID)
        case slide(Int)
    }

    /// The rows the table was last loaded with, and what they were made from.
    private var rows: [Row] = []
    private var shownLayout: [String] = []
    /// Sections whose slides are folded away.
    private var collapsedSectionIDs: Set<SlideSection.ID> = []
    /// The slide selected when the table was last brought up to date.
    private var lastSelectedID: Slide.ID?
    /// Set while the table's selection is being made to match the editor's,
    /// so that doing so isn't taken for the user picking a slide.
    private var isMatchingSelection = false
    private var observing: Observing?
    private var lastWidth: CGFloat = 0

    private static let rowType = NSPasteboard.PasteboardType("com.tsubuzaki.Dazzle.slide-row")
    private static let sectionType = NSPasteboard.PasteboardType("com.tsubuzaki.Dazzle.section-row")
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
        tableView.registerForDraggedTypes([Self.rowType, Self.sectionType])
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
        // A slide picked from elsewhere shows, even in a folded section.
        if let id = deck.state.selectedSlideID, id != lastSelectedID, let section = presentation.section(of: id) {
            collapsedSectionIDs.remove(section.id)
        }
        lastSelectedID = deck.state.selectedSlideID
        let layout = presentation.slides.map(\.id.uuidString) + [presentation.isInMasterView ? "masters" : "slides"]
            + presentation.sections.flatMap { section in
            [section.id, section.name, collapsedSectionIDs.contains(section.id) ? "-" : "+"] + section.slideIDs.map(\.uuidString)
        }
        if layout != shownLayout {
            shownLayout = layout
            rows = Self.rows(for: presentation, collapsed: collapsedSectionIDs)
            // Reloading picks a row of its own, which is not the user picking a slide.
            isMatchingSelection = true
            tableView.reloadData()
            isMatchingSelection = false
            isMatchingSelection = false
        } else {
            let visible = tableView.rows(in: tableView.visibleRect)
            for row in visible.lowerBound..<visible.upperBound {
                guard let index = slideIndex(atRow: row) else { continue }
                (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SlideRowView)?
                    .show(presentation.slides[index], number: number(ofSlide: index, in: presentation), in: presentation)
            }
        }
        if let index = presentation.index(of: deck.state.selectedSlideID), let row = rows.firstIndex(of: .slide(index)),
           tableView.selectedRow != row {
            isMatchingSelection = true
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            isMatchingSelection = false
        }
    }

    private static func rows(for presentation: Presentation, collapsed: Set<SlideSection.ID>) -> [Row] {
        guard !presentation.sections.isEmpty, !presentation.isInMasterView else {
            return presentation.slides.indices.map(Row.slide)
        }
        return presentation.sections.flatMap { section -> [Row] in
            [.section(section.id)] + (collapsed.contains(section.id) ? [] : section.slideIDs.compactMap {
                presentation.index(of: $0).map(Row.slide)
            })
        }
    }

    private func slideIndex(atRow row: Int) -> Int? {
        guard rows.indices.contains(row), case .slide(let index) = rows[row],
              deck.presentation.slides.indices.contains(index) else { return nil }
        return index
    }

    private func section(atRow row: Int) -> SlideSection? {
        guard rows.indices.contains(row), case .section(let id) = rows[row] else { return nil }
        return deck.presentation.sections.first { $0.id == id }
    }

    private func toggleSection(_ id: SlideSection.ID) {
        if collapsedSectionIDs.contains(id) {
            collapsedSectionIDs.remove(id)
        } else {
            collapsedSectionIDs.insert(id)
        }
        refresh()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        if let index = slideIndex(atRow: row) {
            item.setString(String(index), forType: Self.rowType)
        } else if let section = section(atRow: row) {
            item.setString(section.id, forType: Self.sectionType)
        } else {
            return nil
        }
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        if info.draggingPasteboard.string(forType: Self.sectionType) != nil {
            // A section goes between sections: before a header, or at the end.
            let target = rows.indices.contains(row) ? rows[row...].firstIndex { if case .section = $0 { true } else { false } } : nil
            tableView.setDropRow(target ?? rows.count, dropOperation: .above)
            return .move
        }
        // A slide dropped on a section's name goes into it.
        if dropOperation == .on, section(atRow: row) == nil { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let state = deck.state
        let presentation = deck.presentation
        if let moving = info.draggingPasteboard.string(forType: Self.sectionType),
           let from = presentation.sectionIndex(of: moving) {
            let before = rows.indices.contains(row) ? section(atRow: row).flatMap { presentation.sectionIndex(of: $0.id) } : nil
            let target = before ?? presentation.sections.count
            deck.edit { state.moveSection(moving, to: target > from ? target - 1 : target, in: &$0) }
            return true
        }
        guard let string = info.draggingPasteboard.string(forType: Self.rowType), let from = Int(string),
              presentation.slides.indices.contains(from) else { return false }
        let id = presentation.slides[from].id
        if let section = section(atRow: row) {
            // On a section's name: to the end of it. Just above one: to the
            // end of the section before.
            let index = presentation.sectionIndex(of: section.id) ?? 0
            let target = dropOperation == .on ? section : presentation.sections[safe: index - 1]
            if let target {
                deck.edit { state.moveSlides([id], toSection: target.id, in: &$0) }
            } else {
                deck.edit { presentation in
                    state.moveSlide(id, to: 0, in: &presentation)
                    presentation.placeSlide(id, inSectionOf: presentation.slides[min(1, presentation.slides.count - 1)].id)
                }
            }
        } else {
            // Before the slide at the row, or after the last.
            let next = rows[row...].lazy.compactMap { row -> Int? in if case .slide(let index) = row { index } else { nil } }.first
            let destinationIndex = next ?? presentation.slides.count
            let destination = destinationIndex > from ? destinationIndex - 1 : destinationIndex
            deck.edit { state.moveSlide(id, to: destination, in: &$0) }
        }
        state.selectSlide(id)
        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let presentation = deck.presentation
        if let section = section(atRow: row) {
            let view = tableView.makeView(withIdentifier: SectionRowView.identifier, owner: nil) as? SectionRowView
                ?? SectionRowView()
            view.show(section, isCollapsed: collapsedSectionIDs.contains(section.id)) { [weak self] in
                self?.toggleSection(section.id)
            }
            return view
        }
        guard let index = slideIndex(atRow: row) else { return nil }
        let view = tableView.makeView(withIdentifier: SlideRowView.identifier, owner: nil) as? SlideRowView ?? SlideRowView()
        view.show(presentation.slides[index], number: number(ofSlide: index, in: presentation), in: presentation)
        return view
    }

    /// The number beside a slide: its place in the presentation, or in
    /// master view, a layout's place among its master's, a master having none.
    private func number(ofSlide index: Int, in presentation: Presentation) -> Int? {
        guard presentation.isInMasterView else { return index + 1 }
        guard presentation.slides[index].role != .master else { return nil }
        let master = presentation.slides[..<index].lastIndex { $0.role == .master } ?? -1
        return index - master
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if section(atRow: row) != nil { return SectionRowView.height }
        let width = max(tableView.bounds.width - Self.numberWidth - Self.rowPadding * 3, 40)
        return width / max(deck.presentation.slideSize.aspectRatio, 0.1) + Self.rowPadding
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { section(atRow: row) != nil }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { slideIndex(atRow: row) != nil }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isMatchingSelection, let index = slideIndex(atRow: tableView.selectedRow) else { return }
        deck.state.selectSlide(deck.presentation.slides[index].id)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        func add(_ key: String.LocalizationValue, _ action: Selector, target: AnyObject? = nil, object: Any? = nil) {
            let item = NSMenuItem(title: String(localized: key), action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = object
            menu.addItem(item)
        }
        if let section = section(atRow: row) {
            let index = deck.presentation.sectionIndex(of: section.id) ?? 0
            add("Section.Rename", #selector(renameSection(_:)), target: self, object: section.id)
            menu.addItem(.separator())
            add("Section.MoveUp", #selector(moveSectionEarlier(_:)), target: self, object: section.id)
            menu.items.last?.isEnabled = index > 0
            add("Section.MoveDown", #selector(moveSectionLater(_:)), target: self, object: section.id)
            menu.items.last?.isEnabled = index < deck.presentation.sections.count - 1
            menu.addItem(.separator())
            add("Section.Remove", #selector(removeSection(_:)), target: self, object: section.id)
            add("Section.RemoveAll", #selector(removeAllSections(_:)), target: self)
            return
        }
        guard let slideIndex = slideIndex(atRow: row) else { return }
        // The menu acts on the slide it was opened on.
        let slide = deck.presentation.slides[slideIndex]
        deck.state.selectSlide(slide.id)
        // A master offers a new layout; a layout, what can be done to it.
        if deck.presentation.isInMasterView {
            add("MasterView.NewLayout", #selector(DocumentWindowController.newSlide(_:)))
            guard slide.role != .master else { return }
            add("MasterView.Duplicate", #selector(DocumentWindowController.duplicateSlide(_:)))
            add("MasterView.Rename", #selector(DocumentWindowController.renameLayout(_:)))
            menu.addItem(.separator())
            add("MasterView.Delete", #selector(DocumentWindowController.deleteSlide(_:)))
            return
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
        add("Section.Add", #selector(addSection(_:)), target: self, object: slide.id)
        if deck.presentation.sections.count > 1 {
            let submenu = NSMenu()
            let current = deck.presentation.section(of: slide.id)?.id
            for section in deck.presentation.sections {
                let item = NSMenuItem(
                    title: section.name.isEmpty ? SlideSection.untitledName : section.name,
                    action: section.id == current ? nil : #selector(moveSlideToSection(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = [slide.id.uuidString, section.id]
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: String(localized: "Section.MoveSlideTo"), action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("Slide.Menu.Delete", #selector(DocumentWindowController.deleteSlide(_:)))
    }

    // MARK: - Sections

    @objc func addSection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Slide.ID else { return }
        let state = deck.state
        state.selectSlide(id)
        var added: SlideSection.ID?
        deck.edit { added = state.addSection(in: &$0) }
        if let added { askForName(of: added) }
    }

    @objc func renameSection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SlideSection.ID else { return }
        askForName(of: id)
    }

    private func askForName(of id: SlideSection.ID) {
        guard let section = deck.presentation.sections.first(where: { $0.id == id }), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Section.Rename")
        alert.addButton(withTitle: String(localized: "Section.Rename.Confirm"))
        alert.addButton(withTitle: String(localized: "Common.Cancel"))
        let field = NSTextField(string: section.name)
        field.placeholderString = String(localized: "Section.Name")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.setAccessibilityIdentifier("sectionNameField")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let state = self.deck.state
            self.deck.edit { state.renameSection(id, to: field.stringValue, in: &$0) }
        }
    }

    @objc func moveSectionEarlier(_ sender: NSMenuItem) { moveSection(sender, by: -1) }

    @objc func moveSectionLater(_ sender: NSMenuItem) { moveSection(sender, by: 1) }

    private func moveSection(_ sender: NSMenuItem, by offset: Int) {
        guard let id = sender.representedObject as? SlideSection.ID,
              let index = deck.presentation.sectionIndex(of: id) else { return }
        let state = deck.state
        deck.edit { state.moveSection(id, to: index + offset, in: &$0) }
    }

    @objc func removeSection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SlideSection.ID else { return }
        let state = deck.state
        deck.edit { state.removeSection(id, in: &$0) }
    }

    @objc func removeAllSections(_ sender: Any?) {
        let state = deck.state
        deck.edit { state.removeAllSections(in: &$0) }
    }

    @objc func moveSlideToSection(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, let slide = UUID(uuidString: pair[0]) else { return }
        let state = deck.state
        deck.edit { state.moveSlides([slide], toSection: pair[1], in: &$0) }
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
            if deck.presentation.isInMasterView {
                guard menuItem.action == #selector(delete(_:)), let selectedID else { return false }
                return deck.state.canDeleteLayout(selectedID, in: deck.presentation)
            }
            return deck.presentation.slides.count > 1
        case #selector(copy(_:)):
            menuItem.title = String(localized: "Edit.CopySlide")
            return selectedID != nil && !deck.presentation.isInMasterView
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

    func show(_ slide: Slide, number: Int?, in presentation: Presentation) {
        self.number.stringValue = number.map(String.init) ?? ""
        thumbnail.show(slide, in: presentation)
        // A master or layout goes by its name.
        if presentation.isInMasterView {
            let name = slide.role == .master ? String(localized: "MasterView.Master") : slide.layoutName ?? ""
            toolTip = name
            setAccessibilityLabel(name)
            return
        }
        toolTip = nil
        setAccessibilityLabel(String(
            format: String(localized: "Slide.Accessibility"), number ?? 0, slide.title ?? String(localized: "Slide.Untitled")
        ))
    }
}

/// A section's name over its slides, with a button that folds them away.
final class SectionRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SectionRow")
    static let height: CGFloat = 26

    private let disclosure = NSButton()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var toggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggled(_:))
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        for view in [disclosure, name, count] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    func show(_ section: SlideSection, isCollapsed: Bool, toggle: @escaping () -> Void) {
        self.toggle = toggle
        disclosure.state = isCollapsed ? .off : .on
        name.stringValue = section.name.isEmpty ? SlideSection.untitledName : section.name
        count.stringValue = String(section.slideIDs.count)
        setAccessibilityLabel(name.stringValue)
        setAccessibilityIdentifier("sectionHeader.\(section.name)")
    }

    @objc private func toggled(_ sender: Any?) { toggle?() }
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
