import AppKit
import AVFoundation
import DazzleEngine
import QuartzCore

/// The slide a slideshow is on, fitted and centred on black, its
/// animations playing as it is clicked through and its videos playing
/// where their pictures are.
@MainActor
final class SlideshowView: NSView {
    enum Role {
        /// Fills a screen; a click moves the show on.
        case audience
        /// The presenter's copy of the slide; a click only follows links and plays media.
        case presenter
    }

    private let session: PresentationSession
    private let role: Role
    private var observing: Observing?
    private var displayLink: CADisplayLink?
    private var playerViews: [SlideShape.ID: PlayerView] = [:]

    init(session: PresentationSession, role: Role) {
        self.session = session
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityRole(.image)
        observing = Observing { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if role == .audience { window?.makeFirstResponder(self) }
    }

    private var slideSize: CGSize { session.presentation?.slideSize.points ?? CGSize(width: 16, height: 9) }

    /// Where the slide sits in the view, fitted and centred.
    private var slideRect: CGRect {
        let size = slideSize
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2,
                      width: shown.width, height: shown.height)
    }

    // MARK: - Keeping current

    private func refresh() {
        _ = (session.position, session.builds, session.isBlanked, session.currentSlide)
        if session.isAnimating {
            if displayLink == nil {
                let link = displayLink(target: self, selector: #selector(frame(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
        updatePlayers()
        setAccessibilityLabel(session.currentSlide?.title ?? String(localized: "Slide.Untitled"))
        needsDisplay = true
    }

    @objc private func frame(_ link: CADisplayLink) {
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updatePlayers()
    }

    /// A view for each video on the slide, over its picture once it has played.
    private func updatePlayers() {
        let media = session.media
        let slide = session.isBlanked ? nil : session.currentSlide
        let videos = slide.map { MediaPlayback.media(on: $0).filter { $0.media.kind == .video } } ?? []
        let ids = Set(videos.map(\.shape.id))
        for (id, view) in playerViews where !ids.contains(id) || media.players[id] !== view.player {
            view.removeFromSuperview()
            playerViews[id] = nil
        }
        let rect = slideRect
        let scale = rect.width / max(slideSize.width, 1)
        for (shape, _) in videos {
            guard let player = media.players[shape.id] else { continue }
            let view = playerViews[shape.id] ?? {
                let view = PlayerView(player: player)
                addSubview(view)
                playerViews[shape.id] = view
                return view
            }()
            let frame = shape.frame.points
            view.frame = CGRect(x: rect.minX + frame.minX * scale, y: rect.minY + frame.minY * scale,
                                width: frame.width * scale, height: frame.height * scale)
            view.isHidden = !media.started.contains(shape.id)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)
        guard !session.isBlanked, let presentation = session.presentation, let slide = session.currentSlide else {
            if role == .presenter, session.isBlanked { drawBlankedNotice() }
            return
        }
        var options = SlideRenderer.Options.presentation
        options.animation = session.animationFrame(at: Date())
        let rect = slideRect
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        SlideRenderer(presentation: presentation, slide: slide, options: options).draw(in: context, size: rect.size)
        context.restoreGState()
        if role == .presenter { drawMediaButtons(on: slide, in: rect) }
    }

    private func drawBlankedNotice() {
        let text = NSAttributedString(string: String(localized: "Presenter.Blanked"), attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    /// A play button over each paused video or sound, for the presenter to click.
    private func drawMediaButtons(on slide: Slide, in rect: CGRect) {
        let scale = rect.width / max(slideSize.width, 1)
        for (shape, media) in MediaPlayback.media(on: slide) where !session.media.isPlaying(shape.id) {
            let frame = shape.frame.points
            let side = min(max(min(frame.width, frame.height) * scale * 0.3, 24), 64)
            let symbol = media.kind == .video ? "play.circle.fill" : "speaker.wave.2.circle.fill"
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.45)])) else { continue }
            let center = CGPoint(x: rect.minX + frame.midX * scale, y: rect.minY + frame.midY * scale)
            image.draw(in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        if !SlideshowKeys.handle(event, in: session) { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        session.end()
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let rect = slideRect
        if rect.contains(location), rect.width > 0 {
            let scale = slideSize.width / rect.width
            let point = CGPoint(x: (location.x - rect.minX) * scale, y: (location.y - rect.minY) * scale)
            // A video or sound plays or pauses.
            if let media = session.mediaShape(at: point) {
                session.media.toggle(media)
                return
            }
            // A link on the slide goes where it leads.
            if let link = session.link(at: point) {
                if let url = session.follow(link) { NSWorkspace.shared.open(url) }
                return
            }
        }
        guard role == .audience else { return }
        if session.advancesOnTap { session.next() }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard role == .audience else { return super.rightMouseUp(with: event) }
        session.previous()
    }
}

/// A player's picture, filling its frame as the shape's does. Clicks go
/// through it to the slide.
final class PlayerView: NSView {
    let player: AVPlayer

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
