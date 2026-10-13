import Foundation
import Testing
@testable import Dazzle

@Suite("Keynote archives written back")
struct KeynoteArchiveWritingTests {
    private let entries: [String: Data]

    init() throws {
        entries = try ZipArchive.entries(in: KeynoteFixture.deck())
    }

    @Test("Files nothing was changed in are written back as they were read")
    func unchanged() throws {
        let archive = try KeynoteArchive(entries: entries)
        #expect(archive.changedFiles.isEmpty)
        for (path, contents) in entries where path.hasSuffix(".iwa") {
            let written = try #require(archive.iwaData(path))
            #expect(try Snappy.iwaStream(written) == Snappy.iwaStream(contents))
        }
    }

    @Test("A changed object reads back changed, and its neighbours don't")
    func changed() throws {
        var archive = try KeynoteArchive(entries: entries)
        let slide = try #require(archive.objects.values.first { $0.type == KeynoteType.slide })
        let others = archive.objects.filter { $0.key != slide.identifier }.mapValues(\.message)
        var fields = try #require(archive.fields(slide.identifier))
        fields.setVarint(9_999, 42)
        try archive.replace(slide.identifier, with: fields)
        let file = try #require(archive.locations[slide.identifier]?.file)
        #expect(archive.changedFiles == [file])

        var written = entries
        written[file] = archive.iwaData(file)
        let reread = try KeynoteArchive(entries: written)
        #expect(reread.objects[slide.identifier]?.message.uint(9_999) == 42)
        #expect(reread.objects[slide.identifier]?.message.reference(17) == slide.message.reference(17))
        for (identifier, message) in others {
            #expect(reread.objects[identifier]?.message.fields.keys.sorted() == message.fields.keys.sorted())
        }
    }
}

@Suite("Stored ZIP archives")
struct StoredArchiveTests {
    @Test("Entries can be stored as they are, and read back in their order")
    func stored() throws {
        let text = Data(String(repeating: "Keynote ", count: 100).utf8)
        let entries = [("b.txt", text), ("a/Ünïcode.txt", Data("x".utf8)), ("c.txt", text)]
        let archive = try ZipArchive.archive(entries: entries, compresses: false)
        // Stored, the text is in the archive as it is.
        #expect(archive.range(of: text) != nil)
        let read = try ZipArchive.orderedEntries(in: archive)
        #expect(read.map(\.path) == entries.map(\.0))
        #expect(read.map(\.data) == entries.map(\.1))
    }
}

@Suite("Keynote documents written back")
struct KeynoteDocumentWritingTests {
    /// The fixture deck with the properties Keynote keeps beside the index.
    static func deck() throws -> Data {
        var entries = try ZipArchive.orderedEntries(in: KeynoteFixture.deck())
        let properties: [String: Any] = [
            "versionUUID": "AAAA", "revision": "0::AAAA", "documentUUID": "DOC", "fileFormatVersion": "14.0.1",
        ]
        entries.append(("Metadata/Properties.plist", try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)))
        entries.append(("preview.jpg", Data([0xFF, 0xD8])))
        return try ZipArchive.archive(entries: entries, compresses: false)
    }

    @Test("A deck nothing was changed in keeps every file, stored, with a new version")
    func unchanged() throws {
        let original = try Self.deck()
        let presentation = try KeynoteImporter.presentation(from: original)
        let wrapper = try KeynoteWriter.fileWrapper(for: presentation)
        let written = try #require(wrapper.regularFileContents)
        let before = try ZipArchive.orderedEntries(in: original)
        let after = try ZipArchive.orderedEntries(in: written)
        #expect(after.map(\.path) == before.map(\.path))
        for (old, new) in zip(before, after) where old.path != "Metadata/Properties.plist" {
            #expect(old.data == new.data, "\(old.path)")
        }
        let properties = try #require(
            PropertyListSerialization.propertyList(from: after.first { $0.path == "Metadata/Properties.plist" }!.data, format: nil)
                as? [String: Any]
        )
        let version = try #require(properties["versionUUID"] as? String)
        #expect(version != "AAAA")
        #expect(properties["revision"] as? String == "0::" + version)
        #expect(properties["documentUUID"] as? String == "DOC")
        #expect(try KeynoteImporter.presentation(from: written).slides.count == presentation.slides.count)
    }

    @Test("A package deck is written back as a package")
    func package() throws {
        let entries = try ZipArchive.orderedEntries(in: Self.deck())
        var children: [String: FileWrapper] = [:]
        var index: [String: FileWrapper] = [:]
        for (path, data) in entries {
            if path.hasPrefix("Index/") {
                index[String(path.dropFirst(6))] = FileWrapper(regularFileWithContents: data)
            } else if !path.contains("/") {
                children[path] = FileWrapper(regularFileWithContents: data)
            }
        }
        children["Index"] = FileWrapper(directoryWithFileWrappers: index)
        let presentation = try KeynoteImporter.presentation(from: FileWrapper(directoryWithFileWrappers: children))
        let written = try KeynoteWriter.fileWrapper(for: presentation)
        #expect(written.isDirectory)
        #expect(Set((written.fileWrappers?["Index"]?.fileWrappers ?? [:]).keys) == Set(index.keys))
        #expect(try KeynoteImporter.presentation(from: written).slides.count == presentation.slides.count)
    }
}
