import AppKit
import DazzleEngine

/// The speaker notes for the slide being edited.
@MainActor
final class NotesViewController: NSViewController, NSTextViewDelegate {
    private let deck: Deck
    private let placeholder = NSTextField(labelWithString: String(localized: "Mac.Notes.Placeholder"))
    private var observing: Observing?
    private var shownSlideID: Slide.ID?
    /// The notes as last loaded or typed.
    private var lastWritten = ""

    init(deck: Deck) {
        self.deck = deck
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override func loadView() {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            view = scrollView
            return
        }
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.delegate = self
        textView.setAccessibilityLabel(String(localized: "Panel.Notes.Title"))
        placeholder.textColor = .placeholderTextColor
        placeholder.font = textView.font
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 17),
            placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 10),
        ])
        notesView = textView
        view = scrollView
    }

    private var notesView: NSTextView?

    override func viewDidLoad() {
        super.viewDidLoad()
        observing = Observing { [weak self] in self?.refresh() }
    }

    func focus() {
        view.window?.makeFirstResponder(notesView)
    }

    private func refresh() {
        guard let notesView else { return }
        let slide = deck.selectedSlide
        let notes = slide?.notes ?? ""
        // What was typed here is already shown; anything else is loaded.
        if slide?.id != shownSlideID || notes != lastWritten {
            notesView.string = notes
            lastWritten = notes
            shownSlideID = slide?.id
        }
        notesView.isEditable = slide != nil
        placeholder.isHidden = !notes.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        guard let notesView else { return }
        let notes = notesView.string
        lastWritten = notes
        let state = deck.state
        deck.edit { state.setNotes(notes, in: &$0) }
        placeholder.isHidden = !notes.isEmpty
    }
}
