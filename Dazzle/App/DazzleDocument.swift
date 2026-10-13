import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The Office Open XML presentation, declared by the system.
    static let openXMLPresentation = UTType("org.openxmlformats.presentationml.presentation") ?? .data
    /// The `.pptm` presentation, which may carry macros. Dazzle opens and
    /// saves these, keeping the macros, but never runs them.
    static let macroEnabledPresentation = UTType("org.openxmlformats.presentationml.presentation.macroenabled") ?? .data
    /// The `.ppsx` slide show: a presentation that opens straight into playing.
    static let openXMLSlideShow = UTType("org.openxmlformats.presentationml.slideshow") ?? .data
    /// A Keynote presentation saved as a single file, as iCloud Drive keeps them.
    static let keynote = UTType("com.apple.iwork.keynote.sffkey") ?? .data
    /// A Keynote presentation saved as a package directory.
    static let keynotePackage = UTType("com.apple.iwork.keynote.key") ?? .package
}

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

extension Presentation {
    /// A new presentation: one title slide on the built-in template.
    static var blank: Presentation {
        do {
            return try PPTXReader.presentation(fromParts: PresentationTemplate.parts())
        } catch {
            preconditionFailure("The built-in template must always read: \(error)")
        }
    }
}
