import AppKit
import DazzleEngine

/// The presenter's window, while the audience watches another display:
/// the slide now and next, the notes, the time, and the controls.
@MainActor
enum PresenterWindowController {
    static func makeWindow(session: PresentationSession, screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.visibleFrame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = session.title
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = PresenterView(session: session)
        window.setFrame(screen.visibleFrame, display: true)
        window.setAccessibilityIdentifier("presenterView")
        return window
    }
}

@MainActor
final class PresenterView: NSView {
    private let session: PresentationSession
    private let current: SlideshowView
    private let next = SlideThumbnailView()
    private let endOfShow = NSTextField(labelWithString: String(localized: "Presenter.End"))
    private let notes = NSTextView()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let position = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let blankButton = NSButton()
    private let nextButton = NSButton()
    private var observing: Observing?
    private var timer: Timer?

    init(session: PresentationSession) {
        self.session = session
        current = SlideshowView(session: session, role: .presenter)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        build()
        observing = Observing { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
        updateElapsed()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate() } else { window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        if !SlideshowKeys.handle(event, in: session) { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        session.end()
    }

    // MARK: - Keeping current

    private func refresh() {
        let presentation = session.presentation
        position.stringValue = String(format: String(localized: "Slideshow.Position"), session.position + 1, session.slideCount)
        if let presentation, let slide = session.nextSlide {
            next.show(slide, in: presentation)
            next.isHidden = false
            endOfShow.isHidden = true
        } else {
            next.isHidden = true
            endOfShow.isHidden = false
        }
        let text = session.currentSlide?.notes ?? ""
        notes.string = text.isEmpty ? String(localized: "Presenter.NoNotes") : text
        notes.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        previousButton.isEnabled = session.position > 0
        blankButton.title = String(localized: session.isBlanked ? "Slideshow.Unblank" : "Slideshow.Blank")
        blankButton.image = NSImage(systemSymbolName: session.isBlanked ? "eye" : "eye.slash", accessibilityDescription: nil)
        if let aspect = presentation?.slideSize.aspectRatio, aspect > 0 {
            nextAspect?.isActive = false
            nextAspect = next.heightAnchor.constraint(equalTo: next.widthAnchor, multiplier: 1 / aspect)
            nextAspect?.isActive = true
        }
    }

    private var nextAspect: NSLayoutConstraint?

    private func updateElapsed() {
        guard let started = session.startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(started))
        elapsed.stringValue = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Building

    private func build() {
        elapsed.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        elapsed.textColor = .white
        elapsed.setAccessibilityLabel(String(localized: "Presenter.Elapsed"))
        position.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        position.textColor = .white
        let end = NSButton(title: String(localized: "Slideshow.End"), target: self, action: #selector(end(_:)))
        end.bezelStyle = .push
        end.refusesFirstResponder = true
        end.setAccessibilityIdentifier("endSlideshow")
        let header = NSStackView(views: [elapsed, NSView(), end])

        func caption(_ key: String.LocalizationValue) -> NSTextField {
            let label = NSTextField(labelWithString: String(localized: key))
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        endOfShow.textColor = .secondaryLabelColor
        notes.isEditable = false
        notes.isSelectable = true
        notes.drawsBackground = false
        notes.font = .systemFont(ofSize: 20)
        notes.textContainerInset = .zero
        notes.isVerticallyResizable = true
        notes.autoresizingMask = [.width]
        let notesScroll = NSScrollView()
        notesScroll.documentView = notes
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notes.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        notes.textContainer?.widthTracksTextView = true

        let side = NSStackView(views: [caption("Presenter.Next"), next, endOfShow, caption("Presenter.Notes"), notesScroll])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 8
        side.setCustomSpacing(16, after: endOfShow)
        side.setCustomSpacing(16, after: next)
        for view in [next, notesScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true
        }
        notesScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        for (button, key, symbol, action) in [
            (previousButton, "Slideshow.Previous", "chevron.backward", #selector(previous(_:))),
            (blankButton, "Slideshow.Blank", "eye.slash", #selector(blank(_:))),
            (nextButton, "Slideshow.Next", "chevron.forward", #selector(advance(_:))),
        ] as [(NSButton, String.LocalizationValue, String, Selector)] {
            button.title = String(localized: key)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = .push
            button.controlSize = .large
            button.target = self
            button.action = action
            button.refusesFirstResponder = true
        }
        nextButton.keyEquivalent = ""
        nextButton.bezelColor = .controlAccentColor
        nextButton.setAccessibilityIdentifier("nextSlide")
        let controls = NSStackView(views: [previousButton, position, blankButton, nextButton])
        controls.spacing = 16

        for view in [header, current, side, controls] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            current.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            current.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            current.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -16),
            side.topAnchor.constraint(equalTo: current.topAnchor),
            side.leadingAnchor.constraint(equalTo: current.trailingAnchor, constant: 24),
            side.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            side.bottomAnchor.constraint(equalTo: current.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 340),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    @objc private func end(_ sender: Any?) { session.end() }
    @objc private func previous(_ sender: Any?) { session.previous() }
    @objc private func blank(_ sender: Any?) { session.toggleBlank() }
    @objc private func advance(_ sender: Any?) { session.next() }
}
