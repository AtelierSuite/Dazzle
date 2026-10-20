import DazzleEngine
import Foundation
import Observation

/// One open presentation and the editing session around it: what the
/// window shows, and the one way it is changed.
///
/// Every change goes through `edit(_:)`, which keeps Keynote documents
/// savable, registers the change for undo, and keeps the selection pointing
/// at something that still exists.
@MainActor
@Observable
final class Deck {
    var presentation: Presentation
    let state = EditorState()
    let history = DeckHistory()
    /// Tells this window's slideshow apart from another window's.
    let id = UUID()

    init(presentation: Presentation) {
        self.presentation = presentation
        state.reconcile(with: presentation)
    }

    /// Changes the presentation. `change` may change the editor's state too,
    /// such as selecting what it adds.
    func edit(_ change: (inout Presentation) -> Void) {
        let old = presentation
        var new = old
        change(&new)
        guard new != old else { return }
        // A Keynote document is saved into itself, so an edit Keynote can't
        // keep is refused at once rather than left to fail every save after it.
        if new.keynoteSource != nil, !KeynoteEditor.canSave(new) {
            state.errorMessage = String(localized: "Error.KeynoteChangeUndone")
            state.reconcile(with: old)
            return
        }
        presentation = new
        history.record(from: old, to: new)
        state.reconcile(with: new)
    }

    /// Hands undo and redo to the document's undo manager.
    func attachHistory(to undoManager: UndoManager?) {
        history.attach(
            to: undoManager,
            read: { [unowned self] in presentation },
            write: { [unowned self] in presentation = $0 },
            restored: { [unowned self] in state.reconcile(with: $0) }
        )
    }

    // MARK: - Shortcuts

    var selectedSlide: Slide? { state.selectedSlide(in: presentation) }
    var selectedIndex: Int { state.selectedIndex(in: presentation) }
    var selectedShape: SlideShape? { state.selectedShape(in: presentation) }
    var selectedShapes: [SlideShape] { state.selectedShapes(in: presentation) }
    var canEditShapes: Bool { selectedSlide?.canEditShapes ?? false }
}
