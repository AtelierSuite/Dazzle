import AppKit
import DazzleEngine

/// Plays a presentation: the slides fill a screen for the audience, and
/// with a second display connected, the presenter gets the slide now and
/// next, the notes and the time on the screen the editor is on.
///
/// The show itself — where it is, what has been built, the media — is the
/// shared `PresentationSession`; this puts it on screen.
@MainActor
final class SlideshowController {
    static let shared = SlideshowController()

    private let session = PresentationSession.shared
    private var audienceWindow: NSWindow?
    private var presenterWindow: NSWindow?
    private weak var editorWindow: NSWindow?
    private weak var deck: Deck?
    private var observing: Observing?
    private var previousOptions: NSApplication.PresentationOptions = []

    var isPresenting: Bool { session.isPresenting }
    var ownerID: UUID? { session.ownerID }

    func start(deck: Deck, title: String, from index: Int, editorWindow: NSWindow?) {
        guard !session.isPresenting else { return }
        session.start(deck.presentation, title: title, fromSlide: index, owner: deck.id)
        guard session.isPresenting else { return }
        self.deck = deck
        self.editorWindow = editorWindow

        let editorScreen = editorWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let audienceScreen = NSScreen.screens.first { $0 != editorScreen } ?? editorScreen
        guard let audienceScreen else { return }

        let audience = SlideshowWindow(screen: audienceScreen)
        audience.contentView = SlideshowView(session: session, role: .audience)
        audienceWindow = audience

        if audienceScreen != editorScreen, let editorScreen {
            let presenter = PresenterWindowController.makeWindow(session: session, screen: editorScreen)
            presenterWindow = presenter
            presenter.makeKeyAndOrderFront(nil)
            audience.orderFront(nil)
        } else {
            audience.makeKeyAndOrderFront(nil)
        }
        // The screen with the menu bar shows nothing but the slides.
        if audienceScreen == NSScreen.screens.first || presenterWindow != nil {
            previousOptions = NSApp.presentationOptions
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableAppleMenu]
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        observing = Observing { [weak self] in
            guard let self, !self.session.isPresenting else { return }
            self.tearDown()
        }
    }

    func end() {
        session.end()
    }

    private func tearDown() {
        observing?.cancel()
        observing = nil
        audienceWindow?.orderOut(nil)
        presenterWindow?.orderOut(nil)
        audienceWindow = nil
        presenterWindow = nil
        NSApp.presentationOptions = previousOptions
        previousOptions = []
        // The editor picks up where the presenter left off.
        if let deck, let id = session.lastShownSlideID, deck.presentation.index(of: id) != nil {
            deck.state.selectSlide(id)
        }
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}

/// A borderless window covering a screen.
final class SlideshowWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: true)
        backgroundColor = .black
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        level = .mainMenu + 1
        acceptsMouseMovedEvents = true
        setAccessibilityIdentifier("slideshow")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// What a key does in a slideshow: arrows, space and return step through,
/// as presentation clickers send; B and . black the screen; Escape ends.
@MainActor
enum SlideshowKeys {
    static func handle(_ event: NSEvent, in session: PresentationSession) -> Bool {
        switch event.specialKey {
        case .rightArrow?, .downArrow?, .carriageReturn?, .enter?, .pageDown?:
            session.next()
        case .leftArrow?, .upArrow?, .pageUp?, .delete?:
            session.previous()
        case .home?:
            session.go(toPosition: 0)
        case .end?:
            session.go(toPosition: session.slideCount - 1)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ", "n": session.next()
            case "p": session.previous()
            case "b", ".", "w": session.toggleBlank()
            case "\u{1b}", "q": session.end()
            default: return false
            }
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        return true
    }
}
