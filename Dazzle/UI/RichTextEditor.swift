import DazzleEngine
import SwiftUI
import UIKit

/// Typing into a shape over the slide: a text view laid exactly where the
/// shape's text goes, drawn as the slide draws it, with a bar of
/// formatting buttons above the keyboard.
struct InPlaceTextEditor: UIViewRepresentable {
    var body: TextBody
    var shape: SlideShape
    var sources: [SlideShape]
    var style: SlideStyleContext
    var slideNumber: Int
    /// View points per slide point.
    var scale: CGFloat
    var fontScale: Double
    var anchor: BodyProperties.Anchor
    var selection: NSRange?
    var onChange: (TextBody) -> Void
    var onSelectionChange: (NSRange) -> Void
    var toolbar: Toolbar

    /// What the buttons above the keyboard do.
    struct Toolbar {
        var bold: () -> Void
        var italic: () -> Void
        var underline: () -> Void
        var bullets: () -> Void
        var numbers: () -> Void
        var outdent: () -> Void
        var indent: () -> Void
        var format: () -> Void
        var done: () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AnchoredTextView {
        let view = AnchoredTextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.clipsToBounds = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.anchor = anchor
        view.inputAccessoryView = context.coordinator.makeToolbar()
        context.coordinator.load(into: view)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: AnchoredTextView, context: Context) {
        let coordinator = context.coordinator
        let needsReload = body != coordinator.lastBody || scale != coordinator.parent.scale
            || fontScale != coordinator.parent.fontScale
        coordinator.parent = self
        view.anchor = anchor
        if needsReload { coordinator.load(into: view) }
    }

    static func dismantleUIView(_ view: AnchoredTextView, coordinator: Coordinator) {
        view.resignFirstResponder()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InPlaceTextEditor
        var lastBody: TextBody?
        private var isLoading = false

        init(_ parent: InPlaceTextEditor) { self.parent = parent }

        func load(into view: UITextView) {
            isLoading = true
            defer { isLoading = false }
            let parent = parent
            view.attributedText = EditableText.attributedString(
                parent.body, shape: parent.shape, sources: parent.sources, style: parent.style, scale: parent.scale,
                fontScale: parent.fontScale, slideNumber: parent.slideNumber
            )
            if view.attributedText.length == 0 {
                view.typingAttributes = EditableText.typingAttributes(
                    for: parent.body, shape: parent.shape, sources: parent.sources, style: parent.style,
                    scale: parent.scale, fontScale: parent.fontScale
                )
            }
            if let selection = parent.selection {
                let length = view.attributedText.length
                let location = min(selection.location, length)
                view.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            } else {
                view.selectedRange = NSRange(location: view.attributedText.length, length: 0)
            }
            lastBody = parent.body
            view.setNeedsLayout()
        }

        func textViewDidChange(_ view: UITextView) {
            guard !isLoading else { return }
            let body = EditableText.body(from: view.attributedText, template: lastBody ?? parent.body)
            lastBody = body
            parent.onChange(body)
            view.setNeedsLayout()
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !isLoading else { return }
            parent.onSelectionChange(view.selectedRange)
        }

        func makeToolbar() -> UIToolbar {
            let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            func item(_ symbol: String, _ label: String.LocalizationValue, _ action: @escaping (InPlaceTextEditor.Toolbar) -> Void) -> UIBarButtonItem {
                let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    action(self.parent.toolbar)
                })
                item.accessibilityLabel = String(localized: label)
                return item
            }
            toolbar.items = [
                item("bold", "Format.Bold") { $0.bold() },
                item("italic", "Format.Italic") { $0.italic() },
                item("underline", "Format.Underline") { $0.underline() },
                .flexibleSpace(),
                item("list.bullet", "Format.List.Bullets") { $0.bullets() },
                item("list.number", "Format.List.Numbers") { $0.numbers() },
                item("decrease.indent", "Format.Outdent") { $0.outdent() },
                item("increase.indent", "Format.Indent") { $0.indent() },
                .flexibleSpace(),
                item("textformat", "Format.MoreText") { $0.format() },
                item("keyboard.chevron.compact.down", "Format.DoneEditing") { $0.done() },
            ]
            toolbar.sizeToFit()
            return toolbar
        }
    }
}

/// A text view that sits its text at the top, middle or bottom of its
/// frame, as a shape's anchor says.
final class AnchoredTextView: UITextView {
    var anchor: BodyProperties.Anchor = .top {
        didSet { if anchor != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
            - textContainerInset.top - textContainerInset.bottom
        let room = max(bounds.height - fitting, 0)
        let top: CGFloat = switch anchor {
        case .top: 0
        case .center: room / 2
        case .bottom: room
        }
        if abs(textContainerInset.top - top) > 0.5 {
            textContainerInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        }
    }
}
