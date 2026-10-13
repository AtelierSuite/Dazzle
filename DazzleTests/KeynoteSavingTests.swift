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
