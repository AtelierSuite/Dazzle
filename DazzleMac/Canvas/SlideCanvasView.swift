import AppKit
import DazzleEngine
import QuartzCore
import UniformTypeIdentifiers

/// The slide being edited, with the selected shapes' frames, and a lone
/// selected shape's handles, drawn over it.
///
/// The view is the slide in slide points with a margin round it, so the
/// scroll view's magnification is the zoom. Click a shape to select it,
/// drag it to move it, drag a handle to resize it, drag the handle above
/// it to turn it, and double-click one with text to edit the text. Shift-
/// or Command-click adds to the selection, and dragging across empty
/// space selects what it crosses. Moves, resizes and turns are previewed
/// live and written to the document once, when the mouse is let go, so
/// each is a single undo step.
@MainActor
final class SlideCanvasView: NSView {
    let deck: Deck
    private var state: EditorState { deck.state }

    /// A move, resize or turn in progress, in slide points and degrees.
    private var interaction: Interaction?
    /// A crop being adjusted.
    private var cropDraft: CropDraft?
    /// The lines a moved or resized shape has settled on.
    private var guides: [Snapping.Guide] = []
    /// The rectangle being dragged out to select what it crosses.
    private var marquee: CGRect?
    /// A comment's pin being dragged to another place.
    private var commentDrag: (id: String, position: CGPoint)?
    /// Typing into a shape or a table cell, over the slide.
    private var textEditor: InPlaceTextEditor?
    private var displayLink: CADisplayLink?
    private var slideSize = CGSize(width: 960, height: 540)

    private struct Placement: Equatable {
        var frame: CGRect
        var rotation: Double
    }

    private struct Interaction: Equatable {
        var originals: [SlideShape.ID: Placement]
        var current: [SlideShape.ID: Placement]

        init(shapes: [SlideShape]) {
            originals = Dictionary(uniqueKeysWithValues: shapes.map {
                ($0.id, Placement(frame: $0.frame.points, rotation: $0.rotation))
            })
            current = originals
        }

        var isChange: Bool { current != originals }
    }

    private struct CropDraft: Equatable {
        var shapeID: SlideShape.ID
        var frame: CGRect
        var picture: SlideShape.Picture
    }

    /// How near a line a shape has to come to settle on it, in screen points.
    private static let snapDistance: CGFloat = 6
    /// How far above a shape its rotation handle sits, in screen points.
    private static let rotationHandleDistance: CGFloat = 24
    /// How far from a handle a click still takes it, in screen points.
    private static let handleReach: CGFloat = 7
    /// How far the mouse moves before a click becomes a drag, in screen points.
    private static let dragThreshold: CGFloat = 3

    init(deck: Deck) {
        self.deck = deck
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Mac.Canvas.Accessibility"))
        setAccessibilityIdentifier("slideCanvas")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not built from a nib") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    /// The space round the slide on screen, enough for the rotation handle
    /// above a shape at the slide's top edge.
    static let screenMargin: CGFloat = 32

    /// The space round the slide, in slide points, which handles reach into
    /// and clicks in which select nothing. It stays `screenMargin` on screen
    /// at whatever zoom, so a fitted slide has the window to itself.
    private(set) var margin: CGFloat = SlideCanvasView.screenMargin

    /// Keeps the space round the slide the same on screen at a new zoom.
    func keepMargin(at magnification: CGFloat) {
        let margin = Self.screenMargin / max(magnification, 0.01)
        guard abs(margin - self.margin) > 0.01 else { return }
        self.margin = margin
        refresh()
    }

    /// Screen points per slide point.
    private var scale: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.01) }

    /// A length on screen, in slide points.
    private func onScreen(_ length: CGFloat) -> CGFloat { length / scale }

    private func slidePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - margin, y: point.y - margin)
    }

    private func viewRect(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: margin, dy: margin) }

    // MARK: - Keeping current

    /// Takes up the presentation and the editor's state, as they are now.
    func refresh() {
        let presentation = deck.presentation
        slideSize = presentation.slideSize.points
        let size = CGSize(width: slideSize.width + 2 * margin, height: slideSize.height + 2 * margin)
        if frame.size != size { setFrameSize(size) }
        // Read so that a change to any of them redraws.
        _ = (state.selectedSlideID, state.selectedShapeIDs, state.croppingShapeID, state.selectedCell, state.isEditingCell)
        if !state.selectedShapeIDs.contains(where: { interaction?.originals[$0] != nil }) { interaction = nil }
        if cropDraft?.shapeID != state.croppingShapeID { cropDraft = nil }
        syncTextEditor()
        syncAnimationPreview()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let slide = deck.selectedSlide else { return }
        let displayed = preview(of: slide)
        let slideRect = viewRect(CGRect(origin: .zero, size: slideSize))

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: onScreen(2)), blur: onScreen(10),
                          color: NSColor.black.withAlphaComponent(0.25).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(slideRect)
        context.restoreGState()

        context.saveGState()
        context.translateBy(x: margin, y: margin)
        SlideRenderer(presentation: deck.presentation, slide: displayed, options: renderOptions(for: displayed, at: Date()))
            .draw(in: context, size: slideSize)
        drawGuides(in: context)
        drawSelection(of: displayed, in: context)
        drawCommentPins(on: displayed, in: context)
        if let marquee {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            context.fill(marquee)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(onScreen(1))
            context.stroke(marquee)
        }
        context.restoreGState()
    }

    private func renderOptions(for slide: Slide, at date: Date) -> SlideRenderer.Options {
        var options = SlideRenderer.Options.editing
        options.bulletsOnlyShapeID = state.editingTextShapeID
        if state.isEditingCell, let id = state.selectedShapeID, let position = state.selectedCell {
            options.editingCell = TableEditingCell(shapeID: id, position: position)
        }
        if let started = state.animationPreviewStartedAt {
            options.animation = slide.animationTimeline.playingThrough(
                at: date.timeIntervalSince(started), shapes: slide.shapes, slideSize: slideSize
            )
        }
        return options
    }

    /// The slide with the move, resize, turn or crop in progress applied.
    private func preview(of slide: Slide) -> Slide {
        var slide = slide
        if let commentDrag, let index = slide.comments.firstIndex(where: { $0.id == commentDrag.id }) {
            slide.comments[index].position = commentDrag.position
        }
        if let cropDraft, let index = slide.shapes.firstIndex(where: { $0.id == cropDraft.shapeID }) {
            slide.shapes[index].frame = EMURect(points: cropDraft.frame)
            slide.shapes[index].kind = .picture(cropDraft.picture)
        }
        guard let interaction else { return slide }
        for index in slide.shapes.indices {
            guard let placement = interaction.current[slide.shapes[index].id] else { continue }
            slide.shapes[index].frame = EMURect(points: placement.frame)
            slide.shapes[index].rotation = placement.rotation
        }
        return slide
    }

    private func drawGuides(in context: CGContext) {
        guard !guides.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.systemPink.cgColor)
        context.setLineWidth(onScreen(1))
        context.setLineDash(phase: 0, lengths: [onScreen(4), onScreen(3)])
        for guide in guides {
            switch guide.axis {
            case .vertical:
                context.move(to: CGPoint(x: guide.position, y: 0))
                context.addLine(to: CGPoint(x: guide.position, y: slideSize.height))
            case .horizontal:
                context.move(to: CGPoint(x: 0, y: guide.position))
                context.addLine(to: CGPoint(x: slideSize.width, y: guide.position))
            }
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawSelection(of slide: Slide, in context: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let selected = slide.shapes.filter { state.isSelected($0.id) }
        if selected.count == 1, let shape = selected.first {
            if shape.id == state.croppingShapeID, case .picture(let picture) = shape.kind {
                drawCrop(of: shape, picture: picture, in: context)
                return
            }
            withRotation(of: shape, in: context) {
                let frame = shape.frame.points
                context.setStrokeColor(accent)
                context.setLineWidth(onScreen(1.5))
                context.stroke(frame)
                if shape.isEditable, slide.canEditShapes {
                    if shape.canRotate {
                        let top = CGPoint(x: frame.midX, y: frame.minY - onScreen(Self.rotationHandleDistance))
                        context.move(to: CGPoint(x: frame.midX, y: frame.minY))
                        context.addLine(to: top)
                        context.strokePath()
                        drawHandle(at: top, in: context, radius: onScreen(5.5))
                    }
                    for handle in handles(for: frame) {
                        drawHandle(at: position(of: handle, in: frame), in: context, radius: onScreen(4.5))
                    }
                } else if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) {
                    let size = onScreen(14)
                    let rect = CGRect(x: frame.maxX - size / 2, y: frame.minY - size / 2, width: size, height: size)
                    lock.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            if case .table(let table) = shape.kind, let position = state.selectedCell, interaction == nil,
               let layout = tableLayout(table, shape: shape, on: slide) {
                context.setStrokeColor(accent)
                context.setLineWidth(onScreen(2.5))
                context.stroke(layout.rect(of: position))
            }
        } else {
            for shape in selected {
                withRotation(of: shape, in: context) {
                    context.setStrokeColor(accent)
                    context.setLineWidth(onScreen(1.5))
                    context.setLineDash(phase: 0, lengths: [onScreen(5), onScreen(3)])
                    context.stroke(shape.frame.points)
                    context.setLineDash(phase: 0, lengths: [])
                }
            }
        }
    }

    // MARK: - Comments

    /// Comment threads left at a place on the slide, still open.
    private func pinnedComments(on slide: Slide) -> [SlideComment] {
        slide.comments.filter { $0.position != nil && !$0.isResolved }
    }

    /// Where a thread's pin sits, in slide points.
    private func pinRect(of comment: SlideComment) -> CGRect {
        let size = onScreen(24)
        let position = comment.position ?? .zero
        return CGRect(x: position.x, y: position.y, width: size, height: size)
    }

    /// The author's initials in a circle of a colour of their own.
    private func drawCommentPins(on slide: Slide, in context: CGContext) {
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemIndigo,
                                 .systemBrown]
        for comment in pinnedComments(on: slide) {
            let rect = pinRect(of: comment)
            let hash = comment.author.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: onScreen(1)), blur: onScreen(3),
                              color: NSColor.black.withAlphaComponent(0.3).cgColor)
            context.setFillColor(colors[hash % colors.count].cgColor)
            context.fillEllipse(in: rect)
            context.restoreGState()
            let initials = NSAttributedString(string: comment.initials.nilIfEmpty ?? "?", attributes: [
                .font: NSFont.systemFont(ofSize: onScreen(10), weight: .bold), .foregroundColor: NSColor.white,
            ])
            let size = initials.size()
            NSGraphicsContext.saveGraphicsState()
            initials.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Opens the comments on a click, or moves the pin on a drag.
    private func trackCommentPin(_ comment: SlideComment, from event: NSEvent) {
        let start = slidePoint(event)
        let origin = comment.position ?? .zero
        var moved: CGPoint?
        let dragged = track(from: event, threshold: Self.dragThreshold) { point, _ in
            moved = CGPoint(
                x: min(max(origin.x + point.x - start.x, 0), slideSize.width),
                y: min(max(origin.y + point.y - start.y, 0), slideSize.height)
            )
            commentDrag = (comment.id, moved ?? origin)
        }
        commentDrag = nil
        if dragged, let moved {
            deck.edit { state.moveComment(comment.id, to: moved, in: &$0) }
        } else {
            state.presentedPanel = .comments
        }
    }

    private func drawHandle(at point: CGPoint, in context: CGContext, radius: CGFloat) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(onScreen(1.5))
        context.strokeEllipse(in: rect)
    }

    /// The whole image, faded, round the part the crop keeps, with bars on
    /// the kept part's edges to cut more or less of it away.
    private func drawCrop(of shape: SlideShape, picture: SlideShape.Picture, in context: CGContext) {
        let frame = shape.frame.points
        let image = SlideShape.Picture.imageRect(frame: frame, picture: picture)
        if let path = picture.imagePath, let data = deck.presentation.data(at: path),
           let cgImage = ImageCache.shared.image(for: data, path: path) {
            context.saveGState()
            context.setAlpha(0.35)
            // The context is flipped; draw the image upright.
            context.translateBy(x: image.minX, y: image.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(origin: .zero, size: image.size))
            context.restoreGState()
        }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(onScreen(2))
        context.stroke(frame)
        context.setFillColor(NSColor.controlAccentColor.cgColor)
        for handle in Handle.allCases {
            let point = position(of: handle, in: frame)
            let long = onScreen(16)
            let short = onScreen(4)
            let width = handle.unit.x == 0 ? long : short
            let height = handle.unit.y == 0 ? long : short
            context.fill(CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height))
        }
    }

    private func withRotation(of shape: SlideShape, in context: CGContext, _ draw: () -> Void) {
        let frame = shape.frame.points
        context.saveGState()
        if shape.rotation != 0 {
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: shape.rotation * .pi / 180)
            context.translateBy(x: -frame.midX, y: -frame.midY)
        }
        draw()
        context.restoreGState()
    }

    // MARK: - Handles

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// Which edges the handle moves: -1 the leading or top, 1 the trailing or bottom.
        var unit: (x: CGFloat, y: CGFloat) {
            switch self {
            case .topLeft: (-1, -1)
            case .top: (0, -1)
            case .topRight: (1, -1)
            case .right: (1, 0)
            case .bottomRight: (1, 1)
            case .bottom: (0, 1)
            case .bottomLeft: (-1, 1)
            case .left: (-1, 0)
            }
        }

        var isCorner: Bool { unit.x != 0 && unit.y != 0 }

        var cursorPosition: NSCursor.FrameResizePosition {
            switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
        }
    }

    /// Lines have no height or no width; their edge handles would sit on
    /// top of their corner handles.
    private func handles(for rect: CGRect) -> [Handle] {
        if rect.height < 4 { return [.left, .right] }
        if rect.width < 4 { return [.top, .bottom] }
        return Handle.allCases
    }

    private func position(of handle: Handle, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX + handle.unit.x * rect.width / 2, y: rect.midY + handle.unit.y * rect.height / 2)
    }

    /// `point` in `shape`'s own unturned space.
    private func local(_ point: CGPoint, in shape: SlideShape) -> CGPoint {
        let frame = shape.frame.points
        return Self.rotate(point, around: CGPoint(x: frame.midX, y: frame.midY), by: -shape.rotation)
    }

    private enum HandleHit {
        case resize(Handle)
        case rotate
        case crop(Handle)
    }

    /// The handle of the lone selected shape under a point, in slide points.
    private func handle(at point: CGPoint) -> (HandleHit, SlideShape)? {
        guard state.selectedShapeIDs.count == 1, let shape = deck.selectedShape, shape.isEditable, deck.canEditShapes else {
            return nil
        }
        let frame = shape.frame.points
        let local = local(point, in: shape)
        let reach = onScreen(Self.handleReach)
        func near(_ target: CGPoint) -> Bool { hypot(local.x - target.x, local.y - target.y) <= reach }
        if shape.id == state.croppingShapeID {
            return Handle.allCases.first { near(position(of: $0, in: frame)) }.map { (.crop($0), shape) }
        }
        if shape.canRotate, near(CGPoint(x: frame.midX, y: frame.minY - onScreen(Self.rotationHandleDistance))) {
            return (.rotate, shape)
        }
        return handles(for: frame).first { near(position(of: $0, in: frame)) }.map { (.resize($0), shape) }
    }

    override func resetCursorRects() {
        guard state.selectedShapeIDs.count == 1, let shape = deck.selectedShape, shape.isEditable, shape.rotation == 0,
              state.croppingShapeID != shape.id, state.editingTextShapeID == nil else { return }
        let frame = shape.frame.points
        let reach = onScreen(Self.handleReach)
        for handle in handles(for: frame) {
            let point = position(of: handle, in: frame)
            let rect = viewRect(CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2))
            addCursorRect(rect, cursor: .frameResize(position: handle.cursorPosition, directions: .all))
        }
    }

    // MARK: - Hit testing

    /// The topmost shape under a point, in slide points.
    private func shape(at point: CGPoint, on slide: Slide) -> SlideShape? {
        // A line has no area; give it some.
        let slop = onScreen(6)
        return slide.shapes.reversed().first { shape in
            guard !shape.isHidden else { return false }
            let frame = shape.frame.points
            let local = local(point, in: shape)
            return frame.insetBy(dx: frame.width < slop ? -slop : 0, dy: frame.height < slop ? -slop : 0).contains(local)
        }
    }

    private func tableLayout(_ table: SlideTable, shape: SlideShape, on slide: Slide) -> TableLayout? {
        TableLayout(
            table: table, frame: shape.frame.points, style: SlideStyleContext(presentation: deck.presentation, slide: slide),
            presentation: deck.presentation, slideNumber: (deck.presentation.index(of: slide.id) ?? 0) + 1
        )
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let slide = deck.selectedSlide else { return }
        window?.makeFirstResponder(self)
        let point = slidePoint(event)

        if let comment = pinnedComments(on: slide).last(where: { pinRect(of: $0).contains(point) }) {
            trackCommentPin(comment, from: event)
            return
        }

        if let (hit, shape) = handle(at: point) {
            switch hit {
            case .resize(let handle): trackResize(handle, of: shape, from: event)
            case .rotate: trackRotation(of: shape, from: event)
            case .crop(let handle): trackCrop(handle, of: shape, from: event)
            }
            return
        }

        let hit = shape(at: point, on: slide)
        if event.clickCount >= 2 {
            doubleClick(hit, at: point, on: slide)
            return
        }
        // A click in the shape being typed into, outside its text, keeps it.
        if let editing = state.editingTextShapeID, hit?.id == editing { return }
        if state.croppingShapeID != nil, hit?.id != state.croppingShapeID { state.croppingShapeID = nil }

        let extends = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        if extends {
            if let hit { state.toggleSelection(hit.id) }
            return
        }
        // A click in a selected table picks a cell.
        if let hit, hit.id == state.selectedShapeID, case .table(let table) = hit.kind,
           let layout = tableLayout(table, shape: hit, on: slide) {
            let cell = layout.cell(at: point)
            if cell != state.selectedCell { state.selectCell(cell, editing: false) }
        } else if let hit, !state.isSelected(hit.id) {
            state.selectedShapeID = hit.id
        } else if hit == nil {
            state.selectedShapeID = nil
        }

        if let hit, hit.isEditable, slide.canEditShapes, state.isSelected(hit.id) {
            trackMove(on: slide, from: event)
        } else if hit == nil {
            trackMarquee(on: slide, from: event)
        }
    }

    private func doubleClick(_ hit: SlideShape?, at point: CGPoint, on slide: Slide) {
        guard let hit else { return }
        if case .table(let table) = hit.kind, hit.isEditable, slide.canEditShapes,
           let layout = tableLayout(table, shape: hit, on: slide) {
            state.selectedShapeID = hit.id
            state.selectCell(layout.cell(at: point), editing: true)
        } else if hit.canHoldText, hit.isEditable, slide.canEditShapes {
            state.beginEditingText(hit.id)
        } else if hit.isPicture, hit.isEditable, slide.canEditShapes, hit.rotation == 0 {
            state.selectedShapeID = hit.id
            state.croppingShapeID = hit.id
        } else {
            state.selectedShapeID = hit.id
        }
    }

    /// Follows the mouse until it is let go, giving `drag` each new place in
    /// slide points, once it has moved far enough to count as a drag.
    private func track(from event: NSEvent, threshold: CGFloat = 0, _ drag: (CGPoint, NSEvent) -> Void) -> Bool {
        let start = slidePoint(event)
        var isDragging = threshold == 0
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = slidePoint(next)
            if !isDragging, hypot(point.x - start.x, point.y - start.y) * scale >= threshold { isDragging = true }
            guard isDragging else { continue }
            autoscroll(with: next)
            drag(point, next)
            needsDisplay = true
            displayIfNeeded()
        }
        return isDragging
    }

    private func trackMove(on slide: Slide, from event: NSEvent) {
        let start = slidePoint(event)
        let moving = slide.shapes.filter { state.isSelected($0.id) && $0.isEditable }
        guard !moving.isEmpty else { return }
        var current = Interaction(shapes: moving)
        let snapping = snapping(on: slide, excluding: Set(current.originals.keys))
        let bounds = moving.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        let moved = track(from: event, threshold: Self.dragThreshold) { point, _ in
            var translation = CGSize(width: point.x - start.x, height: point.y - start.y)
            // The selection as a whole settles onto nearby lines.
            let (offset, settled) = snapping.adjustment(for: bounds.offsetBy(dx: translation.width, dy: translation.height))
            translation.width += offset.width
            translation.height += offset.height
            guides = settled
            for (id, original) in current.originals {
                current.current[id]?.frame = original.frame.offsetBy(dx: translation.width, dy: translation.height)
            }
            interaction = current
        }
        finish(moved ? current : nil)
    }

    private func trackResize(_ handle: Handle, of shape: SlideShape, from event: NSEvent) {
        var current = Interaction(shapes: [shape])
        let original = shape.frame.points
        let start = slidePoint(event)
        let snapping = snapping(on: deck.selectedSlide, excluding: [shape.id])
        let moved = track(from: event) { point, next in
            // The drag, turned into the shape's own unturned space.
            let drag = Self.rotate(CGPoint(x: point.x - start.x, y: point.y - start.y), around: .zero, by: -shape.rotation)
            let keepsAspect = handle.isCorner && (shape.isPicture != next.modifierFlags.contains(.shift))
            var local = Self.resized(original, by: handle, dx: drag.x, dy: drag.y, keepsAspect: keepsAspect)
            // A square-on shape's moving edges settle onto nearby lines.
            if shape.rotation == 0, !keepsAspect {
                let (offset, settled) = snapping.adjustment(for: local, x: Self.lines(handle.unit.x), y: Self.lines(handle.unit.y))
                local = Self.resized(original, by: handle, dx: drag.x + offset.width, dy: drag.y + offset.height, keepsAspect: false)
                guides = settled
            }
            // The side opposite the handle stays put on the slide: the
            // centre moves by the size change, turned back onto the slide.
            let shift = Self.rotate(
                CGPoint(x: local.midX - original.midX, y: local.midY - original.midY), around: .zero, by: shape.rotation
            )
            current.current[shape.id]?.frame = CGRect(
                x: original.midX + shift.x - local.width / 2, y: original.midY + shift.y - local.height / 2,
                width: local.width, height: local.height
            )
            interaction = current
        }
        finish(moved ? current : nil)
    }

    /// Turns the shape to face the mouse. Within a few degrees of a multiple
    /// of 15 it settles on the multiple; with Shift held, it always does.
    private func trackRotation(of shape: SlideShape, from event: NSEvent) {
        var current = Interaction(shapes: [shape])
        let frame = shape.frame.points
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let moved = track(from: event) { point, next in
            let angle = atan2(point.x - center.x, center.y - point.y) * 180 / .pi
            var degrees = (angle + 360).truncatingRemainder(dividingBy: 360)
            let nearest = (degrees / 15).rounded() * 15
            if abs(degrees - nearest) < 4 || next.modifierFlags.contains(.shift) {
                degrees = nearest.truncatingRemainder(dividingBy: 360)
            }
            current.current[shape.id]?.rotation = degrees
            interaction = current
        }
        finish(moved ? current : nil)
    }

    /// Moves the kept part's edges, never past the edges of the image.
    private func trackCrop(_ handle: Handle, of shape: SlideShape, from event: NSEvent) {
        guard case .picture(let picture) = shape.kind else { return }
        let original = shape.frame.points
        let image = SlideShape.Picture.imageRect(frame: original, picture: picture)
        let start = slidePoint(event)
        _ = track(from: event) { point, _ in
            let dx = point.x - start.x
            let dy = point.y - start.y
            var minX = original.minX
            var maxX = original.maxX
            var minY = original.minY
            var maxY = original.maxY
            if handle.unit.x < 0 { minX = min(max(minX + dx, image.minX), maxX - 4) }
            if handle.unit.x > 0 { maxX = max(min(maxX + dx, image.maxX), minX + 4) }
            if handle.unit.y < 0 { minY = min(max(minY + dy, image.minY), maxY - 4) }
            if handle.unit.y > 0 { maxY = max(min(maxY + dy, image.maxY), minY + 4) }
            var cropped = picture
            cropped.cropLeft = (minX - image.minX) / image.width
            cropped.cropRight = (image.maxX - maxX) / image.width
            cropped.cropTop = (minY - image.minY) / image.height
            cropped.cropBottom = (image.maxY - maxY) / image.height
            cropDraft = CropDraft(
                shapeID: shape.id, frame: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), picture: cropped
            )
        }
        if let cropDraft, cropDraft.picture != picture {
            let crop = cropDraft.picture
            deck.edit {
                state.setCrop(frame: cropDraft.frame, left: crop.cropLeft, top: crop.cropTop, right: crop.cropRight,
                              bottom: crop.cropBottom, of: shape.id, in: &$0)
            }
        }
        cropDraft = nil
        needsDisplay = true
    }

    /// Selects every shape the dragged-out rectangle touches.
    private func trackMarquee(on slide: Slide, from event: NSEvent) {
        let start = slidePoint(event)
        let before = state.selectedShapeIDs
        _ = track(from: event, threshold: Self.dragThreshold) { point, next in
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            marquee = rect
            let crossed = slide.shapes.filter { !$0.isHidden && $0.boundingBox.intersects(rect) }.map(\.id)
            let ids = next.modifierFlags.contains(.shift) ? before + crossed.filter { !before.contains($0) } : crossed
            if ids != state.selectedShapeIDs {
                state.endEditingText()
                state.selectedShapeIDs = ids
            }
        }
        marquee = nil
        needsDisplay = true
    }

    /// Writes a finished move, resize or turn to the document.
    private func finish(_ finished: Interaction?) {
        guides = []
        interaction = nil
        if let finished, finished.isChange {
            if finished.current.count == 1, let (id, placement) = finished.current.first {
                deck.edit { state.setTransform(frame: placement.frame, rotation: placement.rotation, of: id, in: &$0) }
            } else {
                deck.edit { state.setFrames(finished.current.mapValues(\.frame), in: &$0) }
            }
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func snapping(on slide: Slide?, excluding ids: Set<SlideShape.ID>) -> Snapping {
        Snapping(
            slide: slideSize, others: slide?.shapes.filter { !ids.contains($0.id) }.map(\.boundingBox) ?? [],
            threshold: onScreen(Self.snapDistance)
        )
    }

    /// The edge a handle moves along one axis, for snapping.
    private static func lines(_ unit: CGFloat) -> Snapping.Lines {
        unit < 0 ? .minimum : (unit > 0 ? .maximum : [])
    }

    /// `rect` with the edges `handle` moves moved, kept at least a little
    /// size, and pulled by a corner with `keepsAspect`, kept in proportion.
    private static func resized(_ original: CGRect, by handle: Handle, dx: CGFloat, dy: CGFloat, keepsAspect: Bool) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        if handle.unit.x < 0 { minX += dx }
        if handle.unit.x > 0 { maxX += dx }
        if handle.unit.y < 0 { minY += dy }
        if handle.unit.y > 0 { maxY += dy }
        let minimum: CGFloat = 4
        // A line keeps its zero thickness; anything else keeps some size.
        if original.width >= minimum { maxX = max(maxX, minX + minimum) }
        if original.height >= minimum { maxY = max(maxY, minY + minimum) }
        var frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if keepsAspect, original.width > 0, original.height > 0 {
            let ratio = max(frame.width / original.width, frame.height / original.height)
            let width = original.width * ratio
            let height = original.height * ratio
            frame = CGRect(
                x: handle.unit.x < 0 ? original.maxX - width : original.minX,
                y: handle.unit.y < 0 ? original.maxY - height : original.minY,
                width: width, height: height
            )
        }
        return frame
    }

    /// `point` turned `degrees` clockwise round `center`, in a y-down space.
    static func rotate(_ point: CGPoint, around center: CGPoint, by degrees: Double) -> CGPoint {
        guard degrees != 0 else { return point }
        let radians = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(radians) - dy * sin(radians), y: center.y + dx * sin(radians) + dy * cos(radians))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let presentation = deck.presentation
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var offset = CGSize.zero
        switch event.specialKey {
        case .delete?, .deleteForward?:
            if !state.selectedShapeIDs.isEmpty { deck.edit { state.deleteSelectedShape(in: &$0) } }
            return
        case .carriageReturn?, .enter?:
            if let shape = deck.selectedShape, shape.canHoldText, shape.isEditable, deck.canEditShapes, !state.hasMultipleSelection {
                state.beginEditingText(shape.id)
            }
            return
        case .tab?, .backTab?:
            selectNextShape(backwards: event.specialKey == .backTab || event.modifierFlags.contains(.shift))
            return
        case .upArrow?: offset.height = -step
        case .downArrow?: offset.height = step
        case .leftArrow?: offset.width = -step
        case .rightArrow?: offset.width = step
        case .pageUp?, .home?:
            stepSlide(forward: false)
            return
        case .pageDown?, .end?:
            stepSlide(forward: true)
            return
        default:
            super.keyDown(with: event)
            return
        }
        let shapes = state.selectedShapes(in: presentation).filter(\.isEditable)
        guard !shapes.isEmpty, deck.canEditShapes else {
            // With nothing selected, the arrows go from slide to slide.
            if state.selectedShapeIDs.isEmpty { stepSlide(forward: offset.width > 0 || offset.height > 0) }
            return
        }
        let frames = Dictionary(uniqueKeysWithValues: shapes.map {
            ($0.id, $0.frame.points.offsetBy(dx: offset.width, dy: offset.height))
        })
        deck.edit { state.setFrames(frames, in: &$0) }
    }

    override func cancelOperation(_ sender: Any?) {
        if state.croppingShapeID != nil {
            state.croppingShapeID = nil
        } else if state.selectedCell != nil {
            state.selectCell(nil)
        } else {
            state.selectedShapeID = nil
        }
    }

    private func stepSlide(forward: Bool) {
        let slides = deck.presentation.slides
        let index = deck.selectedIndex + (forward ? 1 : -1)
        guard slides.indices.contains(index) else { return }
        state.selectSlide(slides[index].id)
    }

    private func selectNextShape(backwards: Bool) {
        let shapes = deck.selectedSlide?.shapes.filter { !$0.isHidden } ?? []
        guard !shapes.isEmpty else { return }
        let current = state.selectedShapeID.flatMap { id in shapes.firstIndex { $0.id == id } }
        let next = current.map { ($0 + (backwards ? shapes.count - 1 : 1)) % shapes.count } ?? (backwards ? shapes.count - 1 : 0)
        state.selectedShapeID = shapes[next].id
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if let slide = deck.selectedSlide {
            let point = slidePoint(event)
            let hit = shape(at: point, on: slide)
            if let hit, !state.isSelected(hit.id) { state.selectedShapeID = hit.id }
            if hit == nil { state.selectedShapeID = nil }
        }
        let menu = NSMenu()
        func add(_ key: String.LocalizationValue, _ action: Selector) {
            menu.addItem(NSMenuItem(title: String(localized: key), action: action, keyEquivalent: ""))
        }
        if state.selectedShapeIDs.isEmpty {
            add("Edit.Paste", #selector(NSText.paste(_:)))
            menu.addItem(.separator())
            add("Slide.New", #selector(DocumentWindowController.newSlide(_:)))
            add("Slide.Menu.Hide", #selector(DocumentWindowController.toggleSlideHidden(_:)))
            return menu
        }
        if let shape = deck.selectedShape, shape.canHoldText, !state.hasMultipleSelection {
            add("ActionBar.EditText", #selector(DocumentWindowController.editText(_:)))
            menu.addItem(.separator())
        }
        add("Edit.Cut", #selector(NSText.cut(_:)))
        add("Edit.Copy", #selector(NSText.copy(_:)))
        add("Edit.Paste", #selector(NSText.paste(_:)))
        add("ActionBar.Duplicate", #selector(DocumentWindowController.duplicateSelection(_:)))
        add("ActionBar.Delete", #selector(NSText.delete(_:)))
        menu.addItem(.separator())
        add("Arrange.Front", #selector(DocumentWindowController.bringToFront(_:)))
        add("Arrange.Forward", #selector(DocumentWindowController.bringForward(_:)))
        add("Arrange.Backward", #selector(DocumentWindowController.sendBackward(_:)))
        add("Arrange.Back", #selector(DocumentWindowController.sendToBack(_:)))
        menu.addItem(.separator())
        add("Arrange.Group", #selector(DocumentWindowController.groupShapes(_:)))
        add("Arrange.Ungroup", #selector(DocumentWindowController.ungroupShapes(_:)))
        return menu
    }

    // MARK: - Typing

    /// Puts the text editor over the shape or cell being typed into, takes
    /// it away when typing ends, and keeps it in step with the document.
    private func syncTextEditor() {
        guard let target = editingTarget() else {
            if let textEditor {
                let hadFocus = textEditor.hasFocus
                textEditor.removeFromSuperview()
                self.textEditor = nil
                if hadFocus { window?.makeFirstResponder(self) }
            }
            return
        }
        if let textEditor, textEditor.target.id == target.id {
            textEditor.update(target, origin: CGPoint(x: margin, y: margin))
            return
        }
        textEditor?.removeFromSuperview()
        let editor = InPlaceTextEditor(target: target, deck: deck)
        editor.update(target, origin: CGPoint(x: margin, y: margin))
        addSubview(editor)
        textEditor = editor
        DispatchQueue.main.async { editor.focus() }
    }

    /// What is being typed into, laid out as the slide draws it.
    private func editingTarget() -> InPlaceTextEditor.Target? {
        guard let slide = deck.selectedSlide else { return nil }
        let presentation = deck.presentation
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let slideNumber = (presentation.index(of: slide.id) ?? 0) + 1
        if let id = state.editingTextShapeID, let shape = slide.shapes.first(where: { $0.id == id }), shape.canHoldText {
            let sources = style.sources(for: shape)
            let (area, properties) = TextRenderer(style: style, slideNumber: slideNumber).textArea(of: shape, sources: sources)
            var fontScale = 1.0
            if case .normal(let scale, _) = properties.autofit { fontScale = scale }
            return InPlaceTextEditor.Target(
                id: .shape(shape.id), body: shape.text ?? TextBody(paragraphs: [Paragraph(runs: [])]), shape: shape,
                sources: sources, style: style, slideNumber: slideNumber, fontScale: fontScale,
                anchor: properties.anchor ?? .top, frame: shape.frame.points, area: area, rotation: shape.rotation
            )
        }
        if state.isEditingCell, let shape = deck.selectedShape, case .table(let table) = shape.kind,
           let position = state.selectedCell, let cell = table.cell(at: position),
           let layout = tableLayout(table, shape: shape, on: slide) {
            let rect = layout.rect(of: position)
            let body = cell.text ?? TextBody(paragraphs: [Paragraph(runs: [])])
            let area = CGRect(
                x: rect.minX + EMU.points(cell.marginLeft ?? 91_440), y: rect.minY + EMU.points(cell.marginTop ?? 45_720),
                width: rect.width - EMU.points((cell.marginLeft ?? 91_440) + (cell.marginRight ?? 91_440)),
                height: rect.height - EMU.points((cell.marginTop ?? 45_720) + (cell.marginBottom ?? 45_720))
            )
            return InPlaceTextEditor.Target(
                id: .cell(shape.id, position), body: body, shape: TableLayout.cellShape(body, rect),
                sources: [layout.styleSource(forRow: position.row)], style: layout.style, slideNumber: slideNumber,
                fontScale: 1, anchor: cell.anchor ?? .top, frame: area, area: area, rotation: 0
            )
        }
        return nil
    }

    // MARK: - Animation preview

    private func syncAnimationPreview() {
        if state.animationPreviewStartedAt != nil {
            guard displayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(animationFrame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func animationFrame(_ link: CADisplayLink) {
        needsDisplay = true
    }

    // MARK: - Dropping

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        deck.canEditShapes && Self.canRead(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard deck.canEditShapes else { return false }
        let pasteboard = sender.draggingPasteboard
        let location = convert(sender.draggingLocation, from: nil)
        let point = CGPoint(x: location.x - margin, y: location.y - margin)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            MediaImporter.insert(urls, into: deck, at: point)
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), let media = PreparedMedia(data: data) {
            MediaImporter.insert(media, into: deck, at: point)
            return true
        }
        return false
    }

    private static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier, UTType.movie.identifier],
        ]) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }
}
