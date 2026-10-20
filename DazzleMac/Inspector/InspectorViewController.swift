import AppKit
import DazzleEngine

/// The inspector beside the slide: Format, for the selected objects and
/// their text, or with nothing selected, the slide; and Animate, for the
/// slide's animations.
@MainActor
final class InspectorViewController: NSViewController {
    let deck: Deck
    var state: EditorState { deck.state }
    let form = InspectorForm()
    private let tabs = NSSegmentedControl()
    private let scrollView = NSScrollView()
    /// The kind of thing the controls were last built for.
    private var builtForKind: [AnyHashable]?
    private var observing: Observing?
    /// What the controls were last built for; they are built again only when it changes.
    private var builtFor: [AnyHashable]?
    /// The animation picked in the Animate tab's list.
    var selectedAnimationID: ShapeAnimation.ID?
    let animationList = NSTableView()
    /// The sheet editing the selected chart's data, while it is open.
    var chartSheet: ChartDataSheet?

    enum Tab: Int {
        case format
        case animate
        case comments
    }

    var tab: Tab { Tab(rawValue: tabs.selectedSegment) ?? .format }

    init(deck: Deck) {
        self.deck = deck
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override func loadView() {
        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        tabs.segmentCount = 3
        tabs.setLabel(String(localized: "ActionBar.Format"), forSegment: 0)
        tabs.setLabel(String(localized: "ActionBar.Animations"), forSegment: 1)
        tabs.setLabel(String(localized: "ActionBar.Comments"), forSegment: 2)
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        form.stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form.stack)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(tabs)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
            tabs.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            scrollView.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            form.stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            form.stack.topAnchor.constraint(equalTo: document.topAnchor),
            form.stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observing = Observing { [weak self] in self?.refresh() }
    }

    @objc private func tabChanged(_ sender: Any?) {
        builtFor = nil
        refresh()
    }

    // MARK: - Keeping current

    func refresh() {
        // Something asked for a panel the inspector shows as a tab.
        switch state.presentedPanel {
        case .comments?: tabs.selectedSegment = Tab.comments.rawValue
        case .animations?: tabs.selectedSegment = Tab.animate.rawValue
        case .format?, .text?: tabs.selectedSegment = Tab.format.rawValue
        default: break
        }
        if state.presentedPanel != nil {
            state.presentedPanel = nil
            if let item = (parent as? NSSplitViewController)?.splitViewItem(for: self), item.isCollapsed {
                item.animator().isCollapsed = false
            }
        }
        let key = structure()
        if key != builtFor {
            builtFor = key
            // Another shape of the same kind keeps the place scrolled to.
            let kind = kindOfSelection()
            let scrolledTo = kind == builtForKind ? scrollView.contentView.bounds.origin : nil
            builtForKind = kind
            form.reset()
            switch tab {
            case .format: buildFormat()
            case .animate: buildAnimate()
            case .comments: buildComments()
            }
            form.update()
            if let scrolledTo {
                view.layoutSubtreeIfNeeded()
                let documentHeight = scrollView.documentView?.frame.height ?? 0
                let limit = max(documentHeight - scrollView.contentView.bounds.height, 0)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(scrolledTo.y, limit)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                scrollView.contentView.scroll(to: .zero)
            }
        }
        form.update()
        if tab == .animate { animationList.reloadData() }
    }

    /// What is selected, by kind rather than by which: the slide, or a
    /// picture, a table, text being typed, and so on.
    private func kindOfSelection() -> [AnyHashable] {
        var kind: [AnyHashable] = [tab.rawValue, state.isEditingCell, state.editingTextShapeID != nil, state.hasMultipleSelection]
        kind.append(deck.selectedShape.map(Self.kindName(of:)) ?? "slide")
        return kind
    }

    /// What decides which controls the inspector shows.
    private func structure() -> [AnyHashable] {
        let presentation = deck.presentation
        let slide = deck.selectedSlide
        var key: [AnyHashable] = [
            tab.rawValue, slide?.id, state.selectedShapeIDs, state.isEditingCell, state.selectedCell, state.editingTextShapeID,
        ]
        if let shape = deck.selectedShape {
            key += [Self.kindName(of: shape), shape.isEditable, shape.canHoldText, shape.canRotate, shape.geometry.presetName]
            if case .chart(let chart?) = shape.kind { key += [chart.kind, chart.title != nil] }
        }
        switch tab {
        case .format:
            key += [slide?.autoAdvanceAfter != nil, SlideSizeConverter.Preset.matching(presentation.slideSize)]
        case .comments:
            key += [slide?.comments.map { [$0.id, $0.isResolved, $0.replies.map(\.id)] as [AnyHashable] }]
        case .animate:
            let animation = slide?.animations.first { $0.id == selectedAnimationID }
            key += [selectedAnimationID, animation?.category, animation?.effect.direction != nil, animation?.effect.isMadeByDazzle]
        }
        return key
    }

    static func kindName(of shape: SlideShape) -> String {
        switch shape.kind {
        case .shape: "shape"
        case .connector: "connector"
        case .picture: "picture"
        case .group: "group"
        case .table: "table"
        case .chart: "chart"
        case .diagram: "diagram"
        case .unsupported: "unsupported"
        }
    }

    // MARK: - Shared

    func edit(_ change: (inout Presentation) -> Void) {
        deck.edit(change)
    }

    var style: SlideStyleContext? {
        deck.selectedSlide.map { SlideStyleContext(presentation: deck.presentation, slide: $0) }
    }

    var colorChoices: [ColorChoice] {
        (style.map(ColorChoice.themeChoices(in:)) ?? []) + ColorChoice.system
    }

    func resolve(_ color: DrawingColor) -> CGColor {
        (style?.color(color) ?? RGBAColor.black).cgColor
    }
}

/// A view whose subviews are laid out from the top, as a scroll view's document.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
