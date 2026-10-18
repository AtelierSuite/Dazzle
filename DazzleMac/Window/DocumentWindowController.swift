import AppKit
import DazzleEngine

/// A presentation's window: the navigator, the slide and its notes, the
/// inspector, and the toolbar. The editor's commands end here, from the
/// menu bar, the toolbar and the context menus.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let deck: Deck
    let split: EditorSplitViewController
    private var observing: [Observing] = []
    /// The alert on screen for the editor's error message, if any.
    private var isShowingError = false
    lazy var finder = FindController(deck: deck)
    /// The Header & Footer sheet, while it is open.
    var headerFooter: HeaderFooterSheet?

    var canvas: CanvasViewController { split.editor.canvas }
    var presentationDocument: PresentationDocument? { document as? PresentationDocument }

    /// What exports and the slideshow are named after.
    var name: String { presentationDocument?.name ?? String(localized: "Document.DefaultName") }

    init(document: PresentationDocument) {
        deck = document.deck
        split = EditorSplitViewController(deck: deck)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.minSize = NSSize(width: 720, height: 480)
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        window.setFrameAutosaveName("PresentationWindow")
        let toolbar = NSToolbar(identifier: "PresentationToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        observing.append(Observing { [weak self] in self?.showErrorIfAny() })
        observing.append(Observing { [weak self] in self?.updateToolbar() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    // MARK: - NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        observing.forEach { $0.cancel() }
        finder.close()
        if SlideshowController.shared.ownerID == deck.id { SlideshowController.shared.end() }
    }

    // MARK: - Errors

    private func showErrorIfAny() {
        guard let message = deck.state.errorMessage, !isShowingError, let window else { return }
        isShowingError = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Alert.Error.Title")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Common.OK"))
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.isShowingError = false
            self?.deck.state.errorMessage = nil
        }
    }

    // MARK: - Toolbar

    private var unsupportedItem: NSToolbarItem?

    private func updateToolbar() {
        unsupportedItem?.isHidden = deck.presentation.unsupportedFeatures.isEmpty
    }

    @objc func showUnsupportedFeatures(_ sender: Any?) {
        let report = deck.presentation.unsupportedFeatures
        var lines: [String] = []
        if !report.omissions.isEmpty { lines += [String(localized: "Notice.Omitted.Intro"), report.omissionMessage] }
        if !report.features.isEmpty { lines += [String(localized: "Notice.UnsupportedFeatures.Intro"), report.noticeMessage] }
        let label = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n\n"))
        label.textColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: String(localized: "Notice.UnsupportedFeatures.Title"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [title, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        label.preferredMaxLayoutWidth = 320
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        if let view = (sender as? NSToolbarItem)?.view ?? window?.contentView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        }
    }
}

// MARK: - NSToolbarDelegate

extension NSToolbarItem.Identifier {
    static let newSlide = Self("newSlide")
    static let play = Self("play")
    static let insertTextBox = Self("insertTextBox")
    static let insertShape = Self("insertShape")
    static let insertTable = Self("insertTable")
    static let insertChart = Self("insertChart")
    static let insertMedia = Self("insertMedia")
    static let unsupportedFeatures = Self("unsupportedFeatures")
    static let notes = Self("notes")
    static let zoom = Self("zoom")
}

extension DocumentWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator, .newSlide, .play, .flexibleSpace,
            .insertTextBox, .insertShape, .insertTable, .insertChart, .insertMedia, .flexibleSpace,
            .unsupportedFeatures, .notes, .inspectorTrackingSeparator, .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.zoom, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .newSlide:
            let item = menuItem(identifier, "Slide.New", "plus.rectangle.on.rectangle", #selector(newSlide(_:)))
            item.menu.delegate = LayoutMenuFiller.shared
            return item
        case .play:
            let item = menuItem(identifier, "Toolbar.Play", "play.fill", #selector(playSlideshow(_:)))
            item.menu.addItem(NSMenuItem(title: String(localized: "Toolbar.PlayFromCurrent"), action: #selector(playSlideshow(_:)),
                                         keyEquivalent: ""))
            item.menu.addItem(NSMenuItem(title: String(localized: "Toolbar.PlayFromStart"), action: #selector(playFromBeginning(_:)),
                                         keyEquivalent: ""))
            return item
        case .insertTextBox:
            return button(identifier, "Menu.Insert.TextBox", "character.textbox", #selector(insertTextBox(_:)))
        case .insertShape:
            let item = menuItem(identifier, "Menu.Insert.Shape", "square.on.circle", nil)
            for choice in ShapeChoice.all {
                let entry = NSMenuItem(title: choice.label, action: #selector(insertShape(_:)), keyEquivalent: "")
                entry.representedObject = choice.preset
                entry.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
                item.menu.addItem(entry)
            }
            return item
        case .insertTable:
            let item = menuItem(identifier, "Menu.Insert.Table", "tablecells", nil)
            for size in Self.tableSizes {
                let entry = NSMenuItem(title: String(format: String(localized: "Table.Size"), size.columns, size.rows),
                                       action: #selector(insertTable(_:)), keyEquivalent: "")
                entry.representedObject = [size.rows, size.columns]
                item.menu.addItem(entry)
            }
            return item
        case .insertChart:
            let item = menuItem(identifier, "Menu.Insert.Chart", "chart.bar", nil)
            for kind in Chart.Kind.allCases {
                let entry = NSMenuItem(title: kind.label, action: #selector(insertChart(_:)), keyEquivalent: "")
                entry.representedObject = kind.rawValue
                entry.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
                item.menu.addItem(entry)
            }
            return item
        case .insertMedia:
            return button(identifier, "Mac.Toolbar.Media", "photo", #selector(insertMedia(_:)))
        case .unsupportedFeatures:
            let item = button(identifier, "Toolbar.UnsupportedFeatures", "exclamationmark.triangle", #selector(showUnsupportedFeatures(_:)))
            item.isHidden = deck.presentation.unsupportedFeatures.isEmpty
            unsupportedItem = item
            return item
        case .notes:
            return button(identifier, "ActionBar.Notes", "note.text", #selector(toggleNotes(_:)))
        case .zoom:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: ["minus.magnifyingglass", "plus.magnifyingglass"].compactMap {
                    NSImage(systemSymbolName: $0, accessibilityDescription: nil)
                },
                selectionMode: .momentary,
                labels: [String(localized: "Menu.View.ZoomOut"), String(localized: "Menu.View.ZoomIn")],
                target: self, action: #selector(zoomGroup(_:))
            )
            group.label = String(localized: "Mac.Toolbar.Zoom")
            return group
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String.LocalizationValue, _ symbol: String,
                        _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: label)
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.action = action
        item.isBordered = true
        return item
    }

    private func menuItem(_ identifier: NSToolbarItem.Identifier, _ label: String.LocalizationValue, _ symbol: String,
                          _ action: Selector?) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: label)
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.menu = NSMenu()
        if let action {
            item.action = action
        } else {
            item.showsIndicator = true
        }
        return item
    }

    @objc private func zoomGroup(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { canvas.zoomOut() } else { canvas.zoomIn() }
    }
}
