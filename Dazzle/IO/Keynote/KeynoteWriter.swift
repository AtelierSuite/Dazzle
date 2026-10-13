import Foundation

/// A Keynote document as it was opened: every entry, and its objects, kept
/// so that the presentation can be written back over it.
final class KeynoteSource: Equatable, Sendable {
    /// Every file, in the order the document has them.
    let entries: [(path: String, data: Data)]
    /// Whether the document is a package directory rather than one file.
    let isPackage: Bool
    let archive: KeynoteArchive
    /// The presentation as it was converted, which edits are measured against.
    let original: Presentation
    /// The objects each slide was converted from.
    let slides: [Slide.ID: KeynoteSlideOrigin]

    init(
        entries: [(path: String, data: Data)], isPackage: Bool, archive: KeynoteArchive,
        original: Presentation, slides: [Slide.ID: KeynoteSlideOrigin]
    ) {
        self.entries = entries
        self.isPackage = isPackage
        self.archive = archive
        self.original = original
        self.slides = slides
    }

    static func == (lhs: KeynoteSource, rhs: KeynoteSource) -> Bool { lhs === rhs }
}

/// The Keynote objects one slide was converted from.
struct KeynoteSlideOrigin: Sendable {
    /// The `KN.SlideNodeArchive` that places the slide in the show.
    let node: UInt64
    let slide: UInt64
    /// Each shape's drawable, by shape id.
    let drawables: [Int: UInt64]
    /// The storage each shape's text came from, by shape id.
    let textStorages: [Int: UInt64]
    /// The storage the speaker notes came from, if the slide has one.
    let notesStorage: UInt64?
}

/// Writes a presentation back into the Keynote document it was opened from.
///
/// Keynote's objects are changed where they are, field by field, and only
/// the index files holding a changed object are written again. Media,
/// styles and everything Dazzle doesn't read are written back untouched.
enum KeynoteWriter {
    static func fileWrapper(for presentation: Presentation) throws -> FileWrapper {
        guard let source = presentation.keynoteSource else { throw KeynoteSaveError.notFromKeynote }
        let archive = source.archive
        guard !archive.hasZippedIndex else { throw KeynoteSaveError.olderFormat }

        var entries = source.entries
        for index in entries.indices {
            let path = entries[index].path
            if archive.changedFiles.contains(path), let data = archive.iwaData(path) {
                entries[index].data = data
            } else if path == propertiesPath, let data = newVersion(of: entries[index].data) {
                entries[index].data = data
            }
        }
        return source.isPackage ? package(entries) : FileWrapper(regularFileWithContents: try ZipArchive.archive(entries: entries, compresses: false))
    }

    private static let propertiesPath = "Metadata/Properties.plist"

    /// The document's properties with a new version, as each save makes one.
    private static func newVersion(of data: Data) -> Data? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var properties = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        else { return nil }
        let version = UUID().uuidString
        properties["versionUUID"] = version
        if let revision = properties["revision"] as? String, let separator = revision.range(of: "::") {
            properties["revision"] = String(revision[..<separator.upperBound]) + version
        }
        return try? PropertyListSerialization.data(fromPropertyList: properties, format: format, options: 0)
    }

    private static func package(_ entries: [(path: String, data: Data)]) -> FileWrapper {
        final class Directory {
            var files: [String: Data] = [:]
            var directories: [String: Directory] = [:]
        }
        let root = Directory()
        for (path, data) in entries {
            var components = path.split(separator: "/").map(String.init)
            let name = components.removeLast()
            var directory = root
            for component in components {
                if let existing = directory.directories[component] {
                    directory = existing
                } else {
                    let created = Directory()
                    directory.directories[component] = created
                    directory = created
                }
            }
            directory.files[name] = data
        }
        func wrapper(_ directory: Directory) -> FileWrapper {
            var children = directory.files.mapValues { FileWrapper(regularFileWithContents: $0) }
            for (name, child) in directory.directories { children[name] = wrapper(child) }
            for (name, child) in children { child.preferredFilename = name }
            return FileWrapper(directoryWithFileWrappers: children)
        }
        return wrapper(root)
    }
}

enum KeynoteSaveError: LocalizedError {
    case notFromKeynote
    /// The document keeps its index the way versions before Keynote 6 did.
    case olderFormat

    var errorDescription: String? {
        String(localized: "Error.KeynoteNotWritable")
    }
}
