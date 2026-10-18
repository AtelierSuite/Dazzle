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
        tabs.segmentCount = 2
        tabs.setLabel(String(localized: "ActionBar.Format"), forSegment: 0)
        tabs.setLabel(String(localized: "ActionBar.Animations"), forSegment: 1)
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        form.stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form.stack)
        let scrollView = NSScrollView()
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
        let key = structure()
        if key != builtFor {
            builtFor = key
            form.reset()
            switch tab {
            case .format: buildFormat()
            case .animate: buildAnimate()
            }
        }
        form.update()
        if tab == .animate { animationList.reloadData() }
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
