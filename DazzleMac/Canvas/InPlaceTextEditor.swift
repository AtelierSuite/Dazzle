import AppKit
import DazzleEngine

/// Typing into a shape, or a table cell, over the slide: a text view laid
/// exactly where the text goes, drawn as the slide draws it.
///
/// The canvas is in slide points and the scroll view zooms it, so the text
/// is laid out at the slide's own sizes and is zoomed along with the slide.
@MainActor
final class InPlaceTextEditor: NSView, NSTextViewDelegate {
    enum TargetID: Equatable {
        case shape(SlideShape.ID)
        case cell(SlideShape.ID, TableCellPosition)
    }

    /// What is being typed into, and where, in slide points.
    struct Target {
        var id: TargetID
        var body: TextBody
        var shape: SlideShape
        var sources: [SlideShape]
        var style: SlideStyleContext
        var slideNumber: Int
        var fontScale: Double
        var anchor: BodyProperties.Anchor
        /// The shape's frame, which the editor turns with.
        var frame: CGRect
        /// Where in it the text goes.
        var area: CGRect
        var rotation: Double
    }

    private(set) var target: Target
    private let deck: Deck
    private let textView = EditorTextView(usingTextLayoutManager: false)
    /// The body as last loaded or typed, which edits are measured against.
    private var lastBody: TextBody?
    private var isLoading = false

    init(target: Target, deck: Deck) {
        self.target = target
        self.deck = deck
        super.init(frame: .zero)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.delegate = self
        textView.setAccessibilityIdentifier("inPlaceTextEditor")
        addSubview(textView)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override var isFlipped: Bool { true }

    var hasFocus: Bool { window?.firstResponder === textView }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Takes up the document as it now is: where the text sits, and the
    /// text itself if it was changed other than by typing here.
    func update(_ target: Target, origin: CGPoint) {
        let needsReload = target.body != lastBody || target.fontScale != self.target.fontScale
        self.target = target
        frameCenterRotation = 0
        frame = target.frame.offsetBy(dx: origin.x, dy: origin.y)
        frameCenterRotation = -target.rotation
        if needsReload { load() }
        layoutText()
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let target = target
        let text = EditableText.attributedString(
            target.body, shape: target.shape, sources: target.sources, style: target.style, scale: 1,
            fontScale: target.fontScale, slideNumber: target.slideNumber
        )
        textView.textStorage?.setAttributedString(text)
        if text.length == 0 {
            textView.typingAttributes = EditableText.typingAttributes(
                for: target.body, shape: target.shape, sources: target.sources, style: target.style, scale: 1,
                fontScale: target.fontScale
            )
        }
        let length = text.length
        if let selection = deck.state.textSelection {
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        } else {
            textView.setSelectedRange(NSRange(location: length, length: 0))
        }
        lastBody = target.body
    }

    /// Sits the text at the top, middle or bottom of its area, as the
    /// shape's anchor says, letting it run past the area as the slide does.
    private func layoutText() {
        let area = target.area.offsetBy(dx: -target.frame.minX, dy: -target.frame.minY)
        textView.textContainer?.containerSize = NSSize(width: max(area.width, 1), height: .greatestFiniteMagnitude)
        var height: CGFloat = 0
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            height = layoutManager.usedRect(for: container).height
        }
        height = max(height, 1)
        let room = max(area.height - height, 0)
        let top: CGFloat = switch target.anchor {
        case .top: 0
        case .center: room / 2
        case .bottom: room
        }
        textView.frame = CGRect(x: area.minX, y: area.minY + top, width: max(area.width, 1), height: height)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isLoading, let text = textView.textStorage else { return }
        let body = EditableText.body(from: text, template: lastBody ?? target.body)
        lastBody = body
        let state = deck.state
        switch target.id {
        case .shape: deck.edit { state.setTextBody(body, in: &$0) }
        case .cell: deck.edit { state.setCellText(body, in: &$0) }
        }
        layoutText()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        deck.state.textSelection = textView.selectedRange()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            let state = deck.state
            if case .cell(_, let position) = target.id {
                state.selectCell(position, editing: false)
            } else {
                state.endEditingText()
            }
            return true
        }
        return false
    }
}

/// The text view typing goes into. What is pasted takes on the formatting
/// of where it lands, as the shape's text keeps its own runs.
final class EditorTextView: NSTextView {
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}
