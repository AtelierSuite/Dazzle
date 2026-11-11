@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing
import UIKit

/// What the editor's quick Paste button offers, which is told without reading
/// the pasteboard, and that pasting from it brings that in.
@MainActor
@Suite("Quick paste", .serialized)
struct QuickPasteTests {
    @Test("Dazzle's own content comes before a picture, a picture before text, text before a link")
    func precedence() {
        let presentation = Presentation.blank
        let slide = presentation.slides[0]
        #expect(PasteKind.of(.slides([slide, slide], presentation: presentation), hasImages: true, hasStrings: true, hasURLs: true) == .slides(count: 2))
        #expect(PasteKind.of(.shapes([], slide: slide, presentation: presentation), hasImages: true, hasStrings: true, hasURLs: false) == .shapes(count: 0))
        #expect(PasteKind.of(nil, hasImages: true, hasStrings: true, hasURLs: true) == .image)
        #expect(PasteKind.of(nil, hasImages: false, hasStrings: true, hasURLs: true) == .text)
        #expect(PasteKind.of(nil, hasImages: false, hasStrings: false, hasURLs: true) == .link)
        #expect(PasteKind.of(nil, hasImages: false, hasStrings: false, hasURLs: false) == nil)
    }

    @Test("An empty pasteboard offers nothing")
    func emptyPasteboard() {
        UIPasteboard.general.items = []
        #expect(DeckClipboard.shared.pasteKind == nil)
    }

    @Test("Another app's text is offered as text, and pastes as a text box")
    func systemText() {
        UIPasteboard.general.string = "Hello from elsewhere"
        defer { UIPasteboard.general.items = [] }
        #expect(DeckClipboard.shared.pasteKind == .text)

        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        let before = presentation.slides[0].shapes.count
        state.paste(in: &presentation)
        #expect(presentation.slides[0].shapes.count == before + 1)
        #expect(presentation.slides[0].shapes.last?.text?.plainText == "Hello from elsewhere")
    }

    @Test("A copied link pastes its address")
    func systemLink() {
        UIPasteboard.general.url = URL(string: "https://example.com/deck")
        defer { UIPasteboard.general.items = [] }
        #expect(DeckClipboard.shared.pasteKind != nil)

        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        state.paste(in: &presentation)
        #expect(presentation.slides[0].shapes.last?.text?.plainText == "https://example.com/deck")
    }

    @Test("Copying a slide in Dazzle offers it, and says so once it is on the clipboard")
    func ownCopy() async {
        defer { UIPasteboard.general.items = [] }
        let presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)

        var offered: PasteKind?
        let observer = NotificationCenter.default.addObserver(forName: DeckClipboard.didCopy, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { offered = DeckClipboard.shared.pasteKind }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        state.copySelection(in: presentation)
        #expect(offered == .slides(count: 1))

        // Once another app copies, Dazzle's own content no longer pastes.
        UIPasteboard.general.string = "Newer"
        #expect(DeckClipboard.shared.pasteKind == .text)
    }
}
