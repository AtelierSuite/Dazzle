import Foundation
import Testing
@testable import Dazzle

@Suite("Keynote containers")
struct KeynoteContainerTests {
    @Test("Snappy literals and overlapping copies expand")
    func snappy() throws {
        // "abcd", then copy 8 bytes from 4 back: the copy reads what it writes.
        let block: [UInt8] = [12, 3 << 2, 0x61, 0x62, 0x63, 0x64, 0x01 | (4 << 2), 4]
        var output: [UInt8] = []
        try Snappy.decompress(block[...], into: &output)
        #expect(String(decoding: output, as: UTF8.self) == "abcdabcdabcd")
    }

    @Test("Chunks that claim more than they hold are rejected")
    func snappyTruncated() {
        #expect(throws: (any Error).self) {
            _ = try Snappy.iwaStream(Data([0, 10, 0, 0, 1]))
        }
    }

    @Test("Repeated numbers read whether packed or not")
    func packedFields() throws {
        var writer = ProtoWriter()
        writer.varint(1, 7)
        writer.varint(1, 8)
        writer.data(2, [1, 2, 0x96, 0x01])
        let message = try ProtoMessage(writer.bytes)
        #expect(message.uints(1) == [7, 8])
        #expect(message.uints(2) == [1, 2, 150])
    }

    @Test("A ZIP without an index is not a Keynote file")
    func rejectsOtherArchives() throws {
        let archive = try ZipArchive.archive(entries: [("readme.txt", Data("hello".utf8))])
        #expect(throws: (any Error).self) {
            _ = try KeynoteImporter.presentation(from: archive)
        }
    }

    @Test("Keynote files open but are never written to")
    func documentTypes() {
        #expect(DazzleDocument.readableContentTypes.contains(.keynote))
        #expect(DazzleDocument.readableContentTypes.contains(.keynotePackage))
        #expect(!DazzleDocument.writableContentTypes.contains(.keynote))
        #expect(!DazzleDocument.writableContentTypes.contains(.keynotePackage))
    }
}

@Suite("Keynote conversion")
struct KeynoteConversionTests {
    private let presentation: Presentation

    init() throws {
        presentation = try KeynoteImporter.presentation(from: KeynoteFixture.deck())
    }

    @Test("Slides keep their size, order and visibility")
    func slides() {
        #expect(presentation.slideSize == EMUSize(width: 1_024 * 12_700, height: 768 * 12_700))
        #expect(presentation.slides.count == 2)
        #expect(presentation.slides[0].isHidden == false)
        #expect(presentation.slides[1].isHidden)
    }

    @Test("The slide style's fill becomes the background")
    func background() throws {
        let background = try #require(presentation.slides[0].background)
        guard case .fill(.solid(let color)) = background else {
            Issue.record("Expected a solid background, got \(background)")
            return
        }
        #expect(color.base == .rgb(0x336699))
    }

    @Test("Placeholder text keeps its paragraph style")
    func title() throws {
        let title = try #require(presentation.slides[0].shapes.first { $0.text?.plainText == "Hello Keynote" })
        #expect(title.frame == EMURect(x: 50 * 12_700, y: 40 * 12_700, width: 900 * 12_700, height: 120 * 12_700))
        let paragraph = try #require(title.text?.paragraphs.first)
        #expect(paragraph.properties.alignment == .center)
        let run = try #require(paragraph.runs.first)
        #expect(run.properties.size == 5_400)
        #expect(run.properties.isBold == true)
        #expect(run.properties.latinFont == "Helvetica")
    }

    @Test("Shapes keep their fill and turn the same way")
    func shape() throws {
        let shape = try #require(presentation.slides[0].shapes.first { $0.fill != nil && $0.text == nil })
        guard case .solid(let color)? = shape.fill else {
            Issue.record("Expected a solid fill")
            return
        }
        #expect(color.base == .rgb(0xFF0000))
        // Thirty degrees anticlockwise in Keynote.
        #expect(abs(shape.rotation - 330) < 0.01)
        #expect(shape.frame == EMURect(x: 100 * 12_700, y: 400 * 12_700, width: 200 * 12_700, height: 100 * 12_700))
    }

    @Test("Pictures carry their image into the package")
    func picture() throws {
        let picture = try #require(presentation.slides[0].shapes.first { $0.isPicture })
        guard case .picture(let details) = picture.kind, let path = details.imagePath else {
            Issue.record("Expected an embedded picture")
            return
        }
        #expect(presentation.package.parts[path] == KeynoteFixture.png)
    }

    @Test("Speaker notes come across and are saved")
    func notes() throws {
        #expect(presentation.slides[0].notes == "Speaker notes")
        let reread = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(reread.slides[0].notes == "Speaker notes")
        #expect(reread.slides[1].isHidden)
    }

    @Test("Lists keep their bullets and indents, measured in ems")
    func bullets() throws {
        let box = try #require(presentation.slides[1].shapes.first)
        let paragraphs = try #require(box.text?.paragraphs)
        #expect(paragraphs.map { $0.runs.map(\.text).joined() } == ["First", "Second"])
        for paragraph in paragraphs {
            #expect(paragraph.properties.bullet == .character("•"))
            #expect(paragraph.properties.marginLeft == 20 * 12_700)
            #expect(paragraph.properties.indent == -20 * 12_700)
        }
    }

    @Test("Text that sets its own height is measured")
    func growingText() throws {
        let box = try #require(presentation.slides[1].shapes.first)
        #expect(box.frame.height > 0)
        #expect(box.text?.properties.autofit == .shape)
    }

    @Test("Groups place their children in their own space, growing text included")
    func groups() throws {
        let shape = try #require(presentation.slides[1].shapes.last)
        guard case .group(let group) = shape.kind, let child = group.children.first else {
            Issue.record("Expected a group with a child")
            return
        }
        #expect(group.childFrame == EMURect(x: 0, y: 0, width: 300 * 12_700, height: 200 * 12_700))
        #expect(child.frame.x == 10 * 12_700)
        #expect(child.frame.y == 20 * 12_700)
        #expect(child.frame.height > 0)
    }
}

/// Builds a small Keynote document object by object, so what each test
/// expects can be read here rather than dug out of a binary file.
enum KeynoteFixture {
    /// A one-pixel PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    static func deck() throws -> Data {
        var objects: [(id: UInt64, type: UInt32, message: ProtoWriter)] = []
        func add(_ id: UInt64, _ type: UInt32, _ build: (inout ProtoWriter) -> Void) {
            var writer = ProtoWriter()
            build(&writer)
            objects.append((id, type, writer))
        }

        add(1, KeynoteType.document) { $0.reference(2, 2) }
        add(2, KeynoteType.show) { show in
            show.message(3) { tree in
                tree.reference(2, 10)
                tree.reference(2, 20)
            }
            show.message(4) { $0.size(1_024, 768) }
        }

        // Slide one: a title, a turned red shape and a picture.
        add(10, KeynoteType.slideNode) { node in
            node.reference(2, 11)
            node.varint(4, 0)
        }
        add(11, KeynoteType.slide) { slide in
            slide.reference(1, 12)
            slide.reference(5, 13)
            slide.reference(27, 16)
            for drawable: UInt64 in [13, 14, 15] { slide.reference(42, drawable) }
        }
        add(12, KeynoteType.slideStyle) { style in
            style.message(11) { $0.message(1) { $0.message(1) { $0.color(0.2, 0.4, 0.6) } } }
        }
        add(13, KeynoteType.placeholder) { placeholder in
            placeholder.message(1) { info in
                info.message(1) { $0.message(1) { $0.message(1) { $0.geometry(x: 50, y: 40, width: 900, height: 120) } } }
                info.reference(4, 30)
            }
            placeholder.varint(2, 2)
        }
        add(30, KeynoteType.storage) { storage in
            storage.string(3, "Hello Keynote")
            storage.message(5) { $0.message(1) { entry in
                entry.varint(1, 0)
                entry.reference(2, 40)
            } }
        }
        add(40, KeynoteType.paragraphStyle) { style in
            style.message(1) { $0.string(1, "Title") }
            style.message(11) { characters in
                characters.varint(1, 1)
                characters.float(3, 54)
                characters.string(5, "Helvetica")
            }
            style.message(12) { $0.varint(1, 2) }
        }
        add(14, KeynoteType.shape) { shape in
            shape.message(1) { $0.message(1) { $0.geometry(x: 100, y: 400, width: 200, height: 100, angle: 30) } }
            shape.reference(2, 41)
        }
        add(41, KeynoteType.shapeStyle) { style in
            style.message(11) { $0.message(1) { $0.message(1) { $0.color(1, 0, 0) } } }
        }
        add(15, KeynoteType.image) { image in
            image.message(1) { $0.message(1) { $0.geometry(x: 600, y: 300, width: 160, height: 120) } }
            image.reference(11, 900)
        }
        add(16, KeynoteType.note) { $0.reference(1, 31) }
        add(31, KeynoteType.storage) { $0.string(3, "Speaker notes") }

        // Slide two, skipped: a bulleted text box whose height follows its text.
        add(20, KeynoteType.slideNode) { node in
            node.reference(2, 21)
            node.varint(4, 1)
        }
        add(21, KeynoteType.slide) { slide in
            slide.reference(1, 12)
            slide.reference(42, 22)
            slide.reference(42, 23)
        }
        add(23, KeynoteType.group) { group in
            group.message(1) { $0.message(1) { $0.geometry(x: 500, y: 500, width: 300, height: 200) } }
            group.reference(2, 24)
        }
        add(24, KeynoteType.shapeInfo) { info in
            info.message(1) { $0.message(1) { $0.message(1) { $0.geometry(x: 10, y: 20, width: 280, height: 0, flags: 1) } } }
            info.reference(4, 33)
            info.varint(6, 1)
        }
        add(33, KeynoteType.storage) { $0.string(3, "Grouped") }
        add(22, KeynoteType.shapeInfo) { info in
            info.message(1) { $0.message(1) { $0.message(1) { $0.geometry(x: 100, y: 200, width: 400, height: 0, flags: 1) } } }
            info.reference(4, 32)
            info.varint(6, 1)
        }
        add(32, KeynoteType.storage) { storage in
            storage.string(3, "First\nSecond")
            storage.message(5) { $0.message(1) { entry in
                entry.varint(1, 0)
                entry.reference(2, 43)
            } }
            storage.message(7) { $0.message(1) { entry in
                entry.varint(1, 0)
                entry.reference(2, 42)
            } }
        }
        add(42, KeynoteType.listStyle) { list in
            list.varint(11, 2)
            list.string(16, "•")
            list.float(12, 1)
            list.float(13, 0)
        }
        add(43, KeynoteType.paragraphStyle) { $0.message(11) { $0.float(3, 20) } }

        add(50, KeynoteType.packageMetadata) { metadata in
            metadata.varint(1, 900)
            metadata.message(4) { data in
                data.varint(1, 900)
                data.data(2, [0])
                data.string(3, "pixel.png")
                data.string(4, "pixel-900.png")
            }
        }

        return try ZipArchive.archive(entries: [
            ("Index/Document.iwa", iwa(objects.filter { $0.id != 50 })),
            ("Index/Metadata.iwa", iwa(objects.filter { $0.id == 50 })),
            ("Data/pixel-900.png", png),
        ])
    }

    /// Objects as an `.iwa`: each behind its `TSP.ArchiveInfo`, the lot
    /// compressed as Snappy literals.
    private static func iwa(_ objects: [(id: UInt64, type: UInt32, message: ProtoWriter)]) -> Data {
        var stream: [UInt8] = []
        for object in objects {
            var info = ProtoWriter()
            info.varint(1, object.id)
            info.message(2) { messageInfo in
                messageInfo.varint(1, UInt64(object.type))
                messageInfo.varint(3, UInt64(object.message.bytes.count))
            }
            stream += ProtoWriter.varint(UInt64(info.bytes.count)) + info.bytes + object.message.bytes
        }
        var block = ProtoWriter.varint(UInt64(stream.count))
        var offset = 0
        while offset < stream.count {
            let length = min(65_536, stream.count - offset)
            block += [61 << 2, UInt8((length - 1) & 0xFF), UInt8((length - 1) >> 8)]
            block += stream[offset..<offset + length]
            offset += length
        }
        let size = block.count
        return Data([0, UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size >> 16)] + block)
    }
}

/// Writes protocol buffer fields, for building fixtures.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        bytes += Self.varint(UInt64(field << 3)) + Self.varint(value)
    }

    mutating func float(_ field: Int, _ value: Float) {
        bytes += Self.varint(UInt64(field << 3 | 5))
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes += $0 }
    }

    mutating func data(_ field: Int, _ value: [UInt8]) {
        bytes += Self.varint(UInt64(field << 3 | 2)) + Self.varint(UInt64(value.count)) + value
    }

    mutating func string(_ field: Int, _ value: String) { data(field, Array(value.utf8)) }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        data(field, nested.bytes)
    }

    mutating func reference(_ field: Int, _ identifier: UInt64) {
        message(field) { $0.varint(1, identifier) }
    }

    mutating func size(_ width: Float, _ height: Float) {
        float(1, width)
        float(2, height)
    }

    mutating func color(_ red: Float, _ green: Float, _ blue: Float) {
        varint(1, 1)
        float(3, red)
        float(4, green)
        float(5, blue)
        float(6, 1)
    }

    /// A `TSD.GeometryArchive`.
    mutating func geometry(x: Float, y: Float, width: Float, height: Float, angle: Float = 0, flags: UInt64 = 3) {
        message(1) { $0.size(x, y) }
        message(2) { $0.size(width, height) }
        varint(3, flags)
        float(4, angle)
    }
}
