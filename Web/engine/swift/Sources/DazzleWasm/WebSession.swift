import DazzleEngine
import Foundation

/// The presentation open in the page, with the editor state the Apple apps
/// edit it through (Shared/EditorState.swift, the same file), its undo
/// history, and how it was opened and is saved.
@MainActor
final class WebSession {
    enum Format: String {
        case pptx, pptm, ppsx, key

        init?(fileName: String) {
            let lower = fileName.lowercased()
            guard let dot = lower.lastIndex(of: ".") else { return nil }
            self.init(rawValue: String(lower[lower.index(after: dot)...]))
        }

        var mimeType: String {
            switch self {
            case .pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            case .pptm: "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
            case .ppsx: "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
            case .key: "application/vnd.apple.keynote"
            }
        }
    }

    /// What undo goes back to: the presentation and what was selected in it.
    private struct Snapshot {
        var presentation: Presentation
        var slideID: Slide.ID?
        var shapeIDs: [SlideShape.ID]
    }

    private(set) var presentation: Presentation
    let state = EditorState()
    var fileName: String
    /// The format it was opened in, which saving keeps.
    private(set) var format: Format

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// Typing into one shape is one step to undo, however many edits it takes.
    private var coalescing: String?
    /// Counts changes, so the page knows when to draw again.
    private(set) var contentVersion = 0
    private var savedVersion = 0
    /// Each slide's own count of changes, so the page draws again only the
    /// slides that changed, and its thumbnails.
    private(set) var revisions: [Slide.ID: Int] = [:]
    private var nextRevision = 1

    init(presentation: Presentation, fileName: String, format: Format) {
        self.presentation = presentation
        self.fileName = fileName
        self.format = format
        state.selectSlide(presentation.slides.first?.id)
        markRevisions(from: nil)
    }

    convenience init(data: Data, fileName: String) throws {
        let format = Format(fileName: fileName) ?? .pptx
        let presentation: Presentation
        if format == .key {
            presentation = try KeynoteImporter.presentation(from: data)
        } else {
            presentation = try PPTXReader.presentation(from: data)
        }
        self.init(presentation: presentation, fileName: fileName, format: format)
    }

    var isEdited: Bool { contentVersion != savedVersion }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Editing

    /// Makes one change through the editor state, as one step to undo.
    /// `coalesce` names a run of edits (typing into one shape) that undo takes back together.
    func edit(coalesce key: String? = nil, _ change: (EditorState, inout Presentation) -> Void) {
        let before = Snapshot(presentation: presentation, slideID: state.selectedSlideID, shapeIDs: state.selectedShapeIDs)
        var edited = presentation
        change(state, &edited)
        state.reconcile(with: edited)
        guard edited != presentation else { return }
        if key == nil || key != coalescing {
            undoStack.append(before)
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        coalescing = key
        redoStack.removeAll()
        let previous = presentation
        presentation = edited
        contentVersion += 1
        markRevisions(from: previous)
    }

    /// Changes only what is selected, which undo doesn't record.
    func select(_ change: (EditorState) -> Void) {
        change(state)
        state.reconcile(with: presentation)
        coalescing = nil
    }

    /// Ends a run of typing, so the next edit is a step of its own.
    func endCoalescing() {
        coalescing = nil
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(presentation: presentation, slideID: state.selectedSlideID, shapeIDs: state.selectedShapeIDs))
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(presentation: presentation, slideID: state.selectedSlideID, shapeIDs: state.selectedShapeIDs))
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        coalescing = nil
        let previous = presentation
        presentation = snapshot.presentation
        state.endEditingText()
        state.selectSlide(snapshot.slideID)
        state.selectedShapeIDs = snapshot.shapeIDs
        state.reconcile(with: presentation)
        contentVersion += 1
        markRevisions(from: previous)
    }

    /// Gives each slide that changed, or is new, a revision of its own.
    private func markRevisions(from previous: Presentation?) {
        let old = Dictionary((previous?.slides ?? []).map { ($0.id, $0) }) { first, _ in first }
        var next: [Slide.ID: Int] = [:]
        // A change to a master or layout, or the slide size, shows on every slide.
        let everything = previous.map { $0.resources != presentation.resources || $0.slideSize != presentation.slideSize } ?? true
        for (index, slide) in presentation.slides.enumerated() {
            let numberMoved = previous.map { $0.slides.indices.contains(index) ? $0.slides[index].id != slide.id : true } ?? true
            if !everything, !numberMoved, let before = old[slide.id], before == slide, let revision = revisions[slide.id] {
                next[slide.id] = revision
            } else {
                next[slide.id] = nextRevision
                nextRevision += 1
            }
        }
        revisions = next
    }

    // MARK: - Saving

    /// The formats it can be saved in: Keynote only when it came from Keynote,
    /// as Dazzle writes Keynote by changing the document it read.
    var saveFormats: [Format] {
        switch format {
        case .key: presentation.keynoteSource != nil ? [.key, .pptx] : [.pptx]
        case .pptm: [.pptm, .pptx]
        case .ppsx: [.ppsx, .pptx]
        case .pptx: [.pptx]
        }
    }

    func data(as format: Format) throws -> Data {
        if format == .key {
            let wrapper = try KeynoteWriter.fileWrapper(for: presentation)
            guard let contents = wrapper.regularFileContents else { throw Bridge.Failure(message: "A Keynote package can't be saved here.") }
            return contents
        }
        return try PPTXWriter.data(from: presentation)
    }

    func fileName(for format: Format) -> String {
        let base = fileName.lastIndex(of: ".").map { String(fileName[..<$0]) } ?? fileName
        return "\(base).\(format.rawValue)"
    }

    func markSaved(as format: Format) {
        savedVersion = contentVersion
        if format != self.format {
            self.format = format
            fileName = fileName(for: format)
        }
    }
}
