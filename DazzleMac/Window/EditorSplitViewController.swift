import AppKit

/// The window's layout: the slides down the side, the slide being edited
/// with its speaker notes below, and the inspector on the other side.
@MainActor
final class EditorSplitViewController: NSSplitViewController {
    let deck: Deck
    let navigator: NavigatorViewController
    let editor: EditorAreaViewController
    let inspector: InspectorViewController

    init(deck: Deck) {
        self.deck = deck
        navigator = NavigatorViewController(deck: deck)
        editor = EditorAreaViewController(deck: deck)
        inspector = InspectorViewController(deck: deck)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebar = NSSplitViewItem(sidebarWithViewController: navigator)
        sidebar.minimumThickness = 170
        sidebar.maximumThickness = 320
        sidebar.preferredThicknessFraction = 0.15
        addSplitViewItem(sidebar)

        let content = NSSplitViewItem(viewController: editor)
        content.minimumThickness = 360
        addSplitViewItem(content)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 360
        addSplitViewItem(inspectorItem)

        splitView.autosaveName = "EditorSplit"
    }
}

/// The slide being edited above its speaker notes, which can be hidden.
@MainActor
final class EditorAreaViewController: NSSplitViewController {
    let canvas: CanvasViewController
    let notes: NotesViewController
    private var notesItem: NSSplitViewItem?

    init(deck: Deck) {
        canvas = CanvasViewController(deck: deck)
        notes = NotesViewController(deck: deck)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        let canvasItem = NSSplitViewItem(viewController: canvas)
        canvasItem.minimumThickness = 200
        addSplitViewItem(canvasItem)
        let notesItem = NSSplitViewItem(viewController: notes)
        notesItem.canCollapse = true
        notesItem.minimumThickness = 60
        notesItem.preferredThicknessFraction = 0.2
        notesItem.holdingPriority = .defaultLow + 1
        notesItem.isCollapsed = true
        addSplitViewItem(notesItem)
        self.notesItem = notesItem
        splitView.autosaveName = "EditorNotesSplit"
    }

    var areNotesShown: Bool { !(notesItem?.isCollapsed ?? true) }

    func toggleNotes() {
        guard let notesItem else { return }
        notesItem.animator().isCollapsed.toggle()
        if !notesItem.isCollapsed { notes.focus() }
    }
}
