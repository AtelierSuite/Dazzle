import AppKit
import DazzleEngine
import PDFKit
import UniformTypeIdentifiers

/// The app's document: one presentation, opened from PowerPoint or Keynote
/// and saved back as what it was.
final class PresentationDocument: NSDocument {
    /// Filled in once the file is read, or with the built-in template for a
    /// new document.
    private var opened: Presentation?
    private var _deck: Deck?

    override class var autosavesInPlace: Bool { true }

    /// The presentation and its editing session.
    @MainActor
    var deck: Deck {
        if let _deck { return _deck }
        let deck = Deck(presentation: opened ?? .blank)
        opened = nil
        deck.attachHistory(to: undoManager)
        _deck = deck
        return deck
    }

    /// The file's name, without its extension, which exports are named after.
    @MainActor
    var name: String {
        (displayName as NSString).deletingPathExtension
    }

    override func makeWindowControllers() {
        MainActor.assumeIsolated {
            addWindowController(DocumentWindowController(document: self))
        }
    }

    // MARK: - Reading

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let type = UTType(typeName) ?? .openXMLPresentation
        let presentation: Presentation
        if Self.isKeynote(type) {
            presentation = try KeynoteImporter.presentation(from: fileWrapper)
        } else {
            guard let data = fileWrapper.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            presentation = try PPTXReader.presentation(from: data)
        }
        MainActor.assumeIsolated {
            if let _deck {
                // Reverting: the window stays, showing the file as saved.
                _deck.presentation = presentation
                _deck.state.reconcile(with: presentation)
                undoManager?.removeAllActions()
            } else {
                opened = presentation
            }
        }
    }

    // MARK: - Writing

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let presentation = MainActor.assumeIsolated { deck.presentation }
        // A Keynote file is written back as Keynote, never as PowerPoint.
        if Self.isKeynote(UTType(typeName) ?? .data) {
            return try KeynoteWriter.fileWrapper(for: presentation)
        }
        return FileWrapper(regularFileWithContents: try PPTXWriter.data(from: presentation))
    }

    /// Keynote is only offered for a presentation that came from Keynote,
    /// as Dazzle writes Keynote by changing the document it read.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        let types = super.writableTypes(for: saveOperation)
        let fromKeynote = MainActor.assumeIsolated { (_deck?.presentation ?? opened)?.keynoteSource != nil }
        guard !fromKeynote else { return types }
        return types.filter { !Self.isKeynote(UTType($0) ?? .data) }
    }

    nonisolated static func isKeynote(_ type: UTType) -> Bool {
        type.conforms(to: .keynote) || type.conforms(to: .keynotePackage)
    }

    // MARK: - Printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        try MainActor.assumeIsolated {
            let presentation = deck.presentation
            let slides = presentation.visibleSlideIndices.map { presentation.slides[$0] }
            let data = SlideExporter.pdf(of: slides, in: presentation, title: name, layout: .slides)
            guard let pdf = PDFDocument(data: data) else { throw CocoaError(.fileWriteUnknown) }
            let info = printInfo.copy() as? NSPrintInfo ?? printInfo
            info.dictionary().addEntries(from: printSettings)
            info.orientation = presentation.slideSize.aspectRatio >= 1 ? .landscape : .portrait
            guard let operation = pdf.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
                throw CocoaError(.fileWriteUnknown)
            }
            operation.jobTitle = name
            return operation
        }
    }
}
