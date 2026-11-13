import DazzleEngine
import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What Dazzle last copied, shared by every open presentation so shapes
/// and slides can be pasted from one into another.
///
/// The system pasteboard gets a picture and the text of what was copied,
/// for other apps. Its change count tells whether what is there is still
/// Dazzle's; once another app has copied something, that is what pastes.
@MainActor
final class DeckClipboard {
    static let shared = DeckClipboard()

    enum Content {
        case shapes([SlideShape], slide: Slide, presentation: Presentation)
        case slides([Slide], presentation: Presentation)
    }

    private var content: Content?
    private var changeCount = -1

    /// Dazzle's own content, if nothing has been copied since.
    var current: Content? {
        Self.systemChangeCount == changeCount ? content : nil
    }

    func copy(_ content: Content, image: Data?, text: String?) {
        #if canImport(UIKit)
        var item: [String: Any] = [:]
        if let image { item[UTType.png.identifier] = image }
        if let text, !text.isEmpty { item[UTType.utf8PlainText.identifier] = text }
        UIPasteboard.general.setItems(item.isEmpty ? [] : [item])
        #else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let image { item.setData(image, forType: .png) }
        if let text, !text.isEmpty { item.setString(text, forType: .string) }
        pasteboard.writeObjects([item])
        #endif
        self.content = content
        changeCount = Self.systemChangeCount
        NotificationCenter.default.post(name: Self.didCopy, object: self)
    }

    /// Posted once Dazzle has copied something and `current` holds it. The
    /// system's own change notification comes too early for that, while the
    /// pasteboard is being written.
    static let didCopy = Notification.Name("DeckClipboard.didCopy")

    private static var systemChangeCount: Int {
        #if canImport(UIKit)
        UIPasteboard.general.changeCount
        #else
        NSPasteboard.general.changeCount
        #endif
    }

    /// A picture another app put on the system pasteboard.
    static var systemImage: Data? {
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        return pasteboard.data(forPasteboardType: UTType.png.identifier)
            ?? pasteboard.data(forPasteboardType: UTType.jpeg.identifier)
            ?? pasteboard.image?.pngData()
        #else
        // TIFF is what most Mac apps copy; the picture is re-encoded as it is prepared.
        let pasteboard = NSPasteboard.general
        return pasteboard.data(forType: .png) ?? pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            ?? pasteboard.data(forType: .tiff)
        #endif
    }

    /// Text another app put on the system pasteboard, or the address of a
    /// link it copied.
    static var systemText: String? {
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        return pasteboard.string ?? pasteboard.url?.absoluteString
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

/// What a paste would bring in, told without reading the system pasteboard
/// (which would ask permission to): Dazzle's own shapes or slides, or what
/// kind of thing another app copied.
enum PasteKind: Equatable {
    case shapes(count: Int)
    case slides(count: Int)
    case image
    case text
    case link

    /// Mirrors the order `paste(in:)` tries things in: Dazzle's own content,
    /// then a picture, then text or a link's address.
    static func of(_ own: DeckClipboard.Content?, hasImages: Bool, hasStrings: Bool, hasURLs: Bool) -> PasteKind? {
        switch own {
        case .shapes(let shapes, _, _): return .shapes(count: shapes.count)
        case .slides(let slides, _): return .slides(count: slides.count)
        case nil: break
        }
        if hasImages { return .image }
        if hasStrings { return .text }
        if hasURLs { return .link }
        return nil
    }
}

#if canImport(UIKit)
extension DeckClipboard {
    /// What would paste now. The `has…` checks only look at the kinds of data
    /// on the pasteboard, so they never bring up the paste permission prompt.
    var pasteKind: PasteKind? {
        let pasteboard = UIPasteboard.general
        return PasteKind.of(current, hasImages: pasteboard.hasImages, hasStrings: pasteboard.hasStrings, hasURLs: pasteboard.hasURLs)
    }
}
#endif

extension EditorState {
    // MARK: - Copying

    /// Copies the selected shapes, or with none selected, the slide.
    func copySelection(in presentation: Presentation) {
        guard let slide = selectedSlide(in: presentation) else { return }
        let shapes = selectedShapes(in: presentation)
        guard !shapes.isEmpty else { return copySlides([slide.id], in: presentation) }
        let text = shapes.compactMap { $0.text?.plainText.nilIfEmpty }.joined(separator: "\n")
        DeckClipboard.shared.copy(
            .shapes(shapes, slide: slide, presentation: presentation),
            image: SlideExporter.png(of: shapes, on: slide, in: presentation), text: text
        )
    }

    func cutSelection(in presentation: inout Presentation) {
        guard !selectedShapeIDs.isEmpty else {
            if let id = selectedSlide(in: presentation)?.id { cutSlide(id, in: &presentation) }
            return
        }
        copySelection(in: presentation)
        deleteSelectedShape(in: &presentation)
    }

    func copySlides(_ ids: [Slide.ID], in presentation: Presentation) {
        // Masters and layouts are not slides to paste among slides.
        guard !presentation.isInMasterView else { return }
        let slides = presentation.slides.filter { ids.contains($0.id) }
        guard let first = slides.first else { return }
        DeckClipboard.shared.copy(
            .slides(slides, presentation: presentation),
            image: SlideExporter.image(of: first, in: presentation, width: 1_280, format: .png),
            text: slides.compactMap(\.title).joined(separator: "\n")
        )
    }

    func cutSlide(_ id: Slide.ID, in presentation: inout Presentation) {
        guard !presentation.isInMasterView else { return }
        guard presentation.slides.count > 1 else { return copySlides([id], in: presentation) }
        copySlides([id], in: presentation)
        deleteSlide(id, in: &presentation)
    }

    // MARK: - Pasting

    /// Pastes whatever is on the clipboard: Dazzle's shapes or slides, or
    /// another app's picture or text.
    func paste(in presentation: inout Presentation) {
        switch DeckClipboard.shared.current {
        case .shapes(let shapes, let slide, let source):
            pasteShapes(shapes, from: slide, of: source, into: &presentation)
        case .slides(let slides, let source):
            pasteSlides(slides, from: source, into: &presentation)
        case nil:
            pasteFromSystem(into: &presentation)
        }
    }

    private func pasteFromSystem(into presentation: inout Presentation) {
        if let data = DeckClipboard.systemImage, let media = PreparedMedia(data: data) {
            insertPicture(media, in: &presentation)
        } else if let text = DeckClipboard.systemText, !text.isEmpty {
            insertTextBox(in: &presentation)
            setText(text, in: &presentation)
            endEditingText()
        }
    }
}
