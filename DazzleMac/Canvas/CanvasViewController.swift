import AppKit
import DazzleEngine

/// The slide being edited, in a scroll view that fits it to the window
/// until it is zoomed.
@MainActor
final class CanvasViewController: NSViewController {
    let deck: Deck
    let canvas: SlideCanvasView
    private let scrollView = NSScrollView()
    /// Whether the slide follows the window's size, rather than staying at
    /// a zoom the user chose.
    private(set) var fitsToWindow = true
    private var observing: Observing?

    private static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    init(deck: Deck) {
        self.deck = deck
        canvas = SlideCanvasView(deck: deck)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override func loadView() {
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = true
        view = scrollView
        NotificationCenter.default.addObserver(
            self, selector: #selector(didMagnify(_:)), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observing = Observing { [weak self] in self?.canvas.refresh() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if fitsToWindow { fit() }
    }

    // MARK: - Zooming

    var magnification: CGFloat { scrollView.magnification }

    func zoomToFit() {
        fitsToWindow = true
        fit()
    }

    func zoom(to magnification: CGFloat) {
        fitsToWindow = false
        let center = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        scrollView.setMagnification(magnification, centeredAt: center)
        canvas.needsDisplay = true
    }

    func zoomIn() {
        zoom(to: Self.zoomSteps.first { $0 > scrollView.magnification + 0.01 } ?? scrollView.maxMagnification)
    }

    func zoomOut() {
        zoom(to: Self.zoomSteps.last { $0 < scrollView.magnification - 0.01 } ?? scrollView.minMagnification)
    }

    /// Fits the whole slide, with its margin, to the space the window gives it.
    private func fit() {
        let available = scrollView.contentSize
        let document = canvas.frame.size
        guard available.width > 0, available.height > 0, document.width > 0, document.height > 0 else { return }
        let scale = min(available.width / document.width, available.height / document.height)
        scrollView.magnification = min(max(scale, scrollView.minMagnification), scrollView.maxMagnification)
        canvas.needsDisplay = true
    }

    @objc private func didMagnify(_ notification: Notification) {
        fitsToWindow = false
        canvas.needsDisplay = true
    }
}
