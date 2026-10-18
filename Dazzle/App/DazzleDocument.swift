import DazzleEngine
import SwiftUI
import UniformTypeIdentifiers

/// The app's document: one presentation.
struct DazzleDocument: FileDocument {
    /// Keynote presentations open converted, and are saved by writing what
    /// was changed back into the Keynote document itself.
    static let readableContentTypes: [UTType] = [
        .openXMLPresentation, .macroEnabledPresentation, .openXMLSlideShow, .keynote, .keynotePackage,
    ]
    static let writableContentTypes: [UTType] = [
        .openXMLPresentation, .macroEnabledPresentation, .openXMLSlideShow, .keynote, .keynotePackage,
    ]

    var presentation: Presentation

    init() {
        presentation = .blank
    }

    init(presentation: Presentation) {
        self.presentation = presentation
    }

    init(configuration: ReadConfiguration) throws {
        if Self.isKeynote(configuration.contentType) {
            presentation = try KeynoteImporter.presentation(from: configuration.file)
            return
        }
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        presentation = try PPTXReader.presentation(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // A Keynote file is written back as Keynote, never as PowerPoint.
        if Self.isKeynote(configuration.contentType) {
            return try KeynoteWriter.fileWrapper(for: presentation)
        }
        return FileWrapper(regularFileWithContents: try PPTXWriter.data(from: presentation))
    }

    private static func isKeynote(_ type: UTType) -> Bool {
        type.conforms(to: .keynote) || type.conforms(to: .keynotePackage)
    }
}
