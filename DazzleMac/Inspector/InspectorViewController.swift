import AppKit
import DazzleEngine

/// The inspector beside the slide.
@MainActor
final class InspectorViewController: NSViewController {
    private let deck: Deck

    init(deck: Deck) {
        self.deck = deck
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override func loadView() {
        view = NSView()
    }
}
