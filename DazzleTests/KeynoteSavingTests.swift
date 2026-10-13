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

@Suite("Keynote edits written back")
struct KeynoteEditWritingTests {
    private let presentation: Presentation

    init() throws {
        presentation = try KeynoteImporter.presentation(from: KeynoteDocumentWritingTests.deck())
    }

    @Test("A shape moved, sized and turned is moved, sized and turned in Keynote")
    func transform() throws {
        var edited = presentation
        let shape = try index(edited.slides[0], Self.isTurned)
        let old = edited.slides[0].shapes[shape].frame
        edited.slides[0].shapes[shape].frame = EMURect(
            x: old.x + 12_700 * 10, y: old.y - 12_700 * 5, width: old.width + 12_700 * 100, height: old.height
        )
        edited.slides[0].shapes[shape].rotation = 45
        edited.slides[0].shapes[shape].edits.insert(.transform)
        edited.slides[0].isModified = true
        let reread = try reread(edited)
        let turned = try #require(reread.slides[0].shapes.first(where: Self.isTurned))
        #expect(turned.frame == edited.slides[0].shapes[shape].frame)
        #expect(abs(turned.rotation - 45) < 0.001)
    }

    @Test("A picture can be moved, but not a group sized")
    func transformLimits() throws {
        var moved = presentation
        let picture = try index(moved.slides[0], \.isPicture)
        moved.slides[0].shapes[picture].frame.x += 12_700 * 20
        #expect(try reread(moved).slides[0].shapes.first(where: \.isPicture)?.frame == moved.slides[0].shapes[picture].frame)

        var sized = presentation
        let group = try index(sized.slides[1]) { if case .group = $0.kind { true } else { false } }
        sized.slides[1].shapes[group].frame.width += 12_700
        #expect(!KeynoteEditor.canSave(sized))
    }

    @Test("Text typed in a shape is written to its storage, keeping its style")
    func text() throws {
        var edited = presentation
        let title = try index(edited.slides[0], Self.isTitle)
        var body = try #require(edited.slides[0].shapes[title].text)
        body.paragraphs[0] = body.paragraphs[0].replacingText("Hello, Keynote!")
        edited.slides[0].shapes[title].text = body
        let reread = try reread(edited)
        let shape = try #require(reread.slides[0].shapes.first { $0.text?.plainText == "Hello, Keynote!" })
        #expect(shape.text?.paragraphs[0].runs.first?.properties == presentation.slides[0].shapes[title].text?.paragraphs[0].runs.first?.properties)
    }

    @Test("A paragraph added to a list takes the formatting of the one it was broken from")
    func paragraph() throws {
        var edited = presentation
        let list = try index(edited.slides[1]) { $0.text?.plainText == "First\nSecond" }
        var body = try #require(edited.slides[1].shapes[list].text)
        body.paragraphs.append(body.paragraphs[1].replacingText("Third"))
        body.paragraphs[0] = body.paragraphs[0].replacingText("Firsts")
        edited.slides[1].shapes[list].text = body
        let reread = try reread(edited)
        let shape = try #require(reread.slides[1].shapes.first { $0.text?.plainText == "Firsts\nSecond\nThird" })
        let paragraphs = try #require(shape.text?.paragraphs)
        #expect(paragraphs[2].properties == paragraphs[1].properties)
    }

    @Test("Text in a style Keynote has nowhere can't be saved")
    func restyledText() throws {
        var edited = presentation
        let title = try index(edited.slides[0], Self.isTitle)
        edited.slides[0].shapes[title].text?.paragraphs[0].runs[0].properties.isItalic = true
        #expect(!KeynoteEditor.canSave(edited))
    }

    @Test("Changes Keynote's objects can't be given can't be saved")
    func unsupported() throws {
        #expect(KeynoteEditor.canSave(presentation))
        var removed = presentation
        removed.slides.remove(at: 1)
        removed.isStructureModified = true
        #expect(!KeynoteEditor.canSave(removed))

        var filled = presentation
        let shape = try index(filled.slides[0], Self.isTurned)
        filled.slides[0].shapes[shape].fill = nil
        filled.slides[0].shapes[shape].edits.insert(.fill)
        #expect(!KeynoteEditor.canSave(filled))
        #expect(throws: KeynoteSaveError.self) { try KeynoteWriter.fileWrapper(for: filled) }
    }

    /// The presentation written to Keynote and read back again.
    private func reread(_ edited: Presentation) throws -> Presentation {
        let written = try #require(KeynoteWriter.fileWrapper(for: edited).regularFileContents)
        return try KeynoteImporter.presentation(from: written)
    }

    private func index(_ slide: Slide, _ matches: (SlideShape) -> Bool) throws -> Int {
        let found = slide.shapes.firstIndex(where: matches)
        return try #require(found)
    }

    private static func isTurned(_ shape: SlideShape) -> Bool { shape.rotation != 0 }
    private static func isTitle(_ shape: SlideShape) -> Bool { shape.text?.plainText == "Hello Keynote" }
}
