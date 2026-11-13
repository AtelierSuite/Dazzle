@testable import Dazzle
@testable import DazzleEngine
import SwiftUI
import Testing

/// What the canvas's edit menu, and the matching VoiceOver actions, offer
/// for a shape, several, or the slide, and that its actions change the deck
/// as the toolbar's do.
@MainActor
@Suite("Canvas menu")
struct CanvasMenuTests {
    private func actions(_ menu: CanvasMenu) -> [CanvasMenu.Action] { menu.allItems.map(\.action) }

    /// A blank deck with two text boxes of its own on the first slide, the
    /// second selected.
    private func deckWithTextBoxes() -> (Presentation, EditorState) {
        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        state.insertTextBox(in: &presentation)
        state.endEditingText()
        state.insertTextBox(in: &presentation)
        state.endEditingText()
        return (presentation, state)
    }

    @Test("A shape offers the clipboard, duplicate, delete and arranging")
    func singleShape() throws {
        let (presentation, state) = deckWithTextBoxes()
        let menu = try #require(state.canvasMenu(in: presentation, canPaste: true))
        #expect(actions(menu) == [.cut, .copy, .paste, .duplicate, .delete, .editText, .bringForward, .sendBackward])
        #expect(menu.items.first { $0.action == .delete }?.isDestructive == true)
    }

    @Test("Paste is offered only when there is something to paste")
    func pasteOnlyWhenAvailable() throws {
        let (presentation, state) = deckWithTextBoxes()
        let menu = try #require(state.canvasMenu(in: presentation, canPaste: false))
        #expect(!actions(menu).contains(.paste))
    }

    @Test("A locked shape can only be copied")
    func lockedShape() throws {
        var (presentation, state) = deckWithTextBoxes()
        let id = try #require(state.selectedShapeID)
        let index = try #require(presentation.slides[0].shapes.firstIndex { $0.id == id })
        presentation.slides[0].shapes[index].isLocked = true
        let menu = try #require(state.canvasMenu(in: presentation, canPaste: true))
        #expect(actions(menu) == [.copy, .paste])
    }

    @Test("On a slide whose shapes can't be edited, nothing changes a shape")
    func uneditableSlide() throws {
        var (presentation, state) = deckWithTextBoxes()
        presentation.slides[0].canEditShapes = false
        let menu = try #require(state.canvasMenu(in: presentation, canPaste: false))
        #expect(actions(menu) == [.copy])
    }

    @Test("Several shapes can be grouped; placeholders can't")
    func multipleShapes() throws {
        let (presentation, state) = deckWithTextBoxes()
        state.selectAllShapes(in: presentation)
        let all = try #require(state.canvasMenu(in: presentation, canPaste: false))
        #expect(actions(all).contains(.group))
        #expect(!actions(all).contains(.editText))

        let placeholders = presentation.slides[0].shapes.filter { $0.placeholder != nil }
        try #require(placeholders.count > 1)
        let menu = CanvasMenu(selection: placeholders, on: presentation.slides[0], canPaste: false)
        #expect(!actions(menu).contains(.group))
    }

    @Test("Empty slide offers paste, select all, skip and duplicate")
    func emptySlide() throws {
        let (presentation, state) = deckWithTextBoxes()
        state.selectedShapeID = nil
        let menu = try #require(state.canvasMenu(in: presentation, canPaste: true))
        #expect(actions(menu) == [.paste, .selectAll, .skipSlide, .duplicateSlide])

        var hidden = presentation
        hidden.slides[0].isHidden = true
        let shown = CanvasMenu(selection: [], on: hidden.slides[0], canPaste: false)
        #expect(shown.items.first { $0.action == .skipSlide }?.title == String(localized: "Slide.Menu.Show"))
    }

    @Test("A table adds its rows, columns and styling in a submenu")
    func table() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        state.insertTable(rows: 1, columns: 2, in: &presentation)
        let menu = try #require(state.canvasMenu(in: presentation, canPaste: false))
        #expect(menu.tableItems.map(\.action) == [
            .table(.rowAbove), .table(.rowBelow), .table(.columnLeft), .table(.columnRight), .table(.deleteColumn),
        ] + SlideTable.StyleOption.allCases.map { .tableOption($0) })
        #expect(menu.tableItems.first { $0.action == .tableOption(.headerRow) }?.isOn == true)
        #expect(menu.tableItems.first { $0.action == .tableOption(.totalRow) }?.isOn == false)

        state.perform(.table(.rowBelow), in: &presentation)
        #expect(state.selectedTable(in: presentation)?.rows.count == 2)
    }

    @Test("A chart offers its data")
    func chart() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        state.insertChart(.bar, in: &presentation)
        let menu = try #require(state.canvasMenu(in: presentation, canPaste: false))
        #expect(actions(menu).contains(.editChart))
        state.perform(.editChart, in: &presentation)
        #expect(state.presentedPanel == .chart)
    }

    @Test("Actions change the deck as the toolbar's do")
    func performs() throws {
        var (presentation, state) = deckWithTextBoxes()
        let count = presentation.slides[0].shapes.count
        state.perform(.duplicate, in: &presentation)
        #expect(presentation.slides[0].shapes.count == count + 1)
        state.perform(.delete, in: &presentation)
        #expect(presentation.slides[0].shapes.count == count)

        state.selectedShapeID = nil
        state.perform(.duplicateSlide, in: &presentation)
        #expect(presentation.slides.count == 2)
        state.perform(.skipSlide, in: &presentation)
        #expect(state.selectedSlide(in: presentation)?.isHidden == true)
    }

    @Test("Actions that leave the deck alone don't write it, so leave nothing to undo")
    func nothingToUndo() throws {
        let (initial, state) = deckWithTextBoxes()
        var presentation = initial
        var writes = 0
        let binding = Binding(get: { presentation }, set: { presentation = $0; writes += 1 })
        state.perform(.copy, in: binding)
        state.perform(.selectAll, in: binding)
        #expect(writes == 0)
        #expect(state.hasMultipleSelection)
        state.perform(.bringForward, in: binding)
        #expect(writes == 1)
    }
}
