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

    @Test("Tables keep their sizes, merges, values and fills")
    func table() throws {
        let shape = try #require(presentation.slides[1].shapes.first { if case .table = $0.kind { true } else { false } })
        guard case .table(let table) = shape.kind else { return }
        #expect(shape.frame == EMURect(x: 20 * 12_700, y: 600 * 12_700, width: 350 * 12_700, height: 80 * 12_700))
        #expect(table.columnWidths == [100, 100, 150].map { $0 * 12_700 })
        #expect(table.rows.map(\.height) == [30, 50].map { $0 * 12_700 })
        let header = table.rows[0].cells
        #expect(header[0].text?.plainText == "Fruit")
        #expect(header[0].columnSpan == 2)
        #expect(header[1].isHorizontalMerge)
        guard case .solid(let color)? = header[2].fill else {
            Issue.record("Expected the header row's fill")
            return
        }
        #expect(color.base == .rgb(0x0000FF))
        #expect(table.rows[1].cells.map { $0.text?.plainText ?? "" } == ["Apples", "7.5", ""])
    }

    @Test("Charts keep their kind, data and series colours")
    func chart() throws {
        let shape = try #require(presentation.slides[1].shapes.first { if case .chart = $0.kind { true } else { false } })
        guard case .chart(let chart?) = shape.kind else {
            Issue.record("Expected a chart Dazzle can read")
            return
        }
        #expect(chart.kind == .column)
        #expect(chart.categories == ["2025", "2026"])
        #expect(chart.allSeries.map(\.name) == ["Apples", "Pears"])
        #expect(chart.allSeries.map(\.values) == [[12, 30], [7, 18]])
        #expect(chart.allSeries.map(\.color) == [.rgb(0x0000FF), .rgb(0x00FF00)])
        #expect(!chart.hasLegend)
    }

    @Test("What could not be brought across is reported")
    func omissions() {
        #expect(presentation.unsupportedFeatures.omissions == [.otherObjects, .builds])
    }

    @Test("Builds become animations on the shapes they build")
    func builds() throws {
        let shape = try #require(presentation.slides[0].shapes.first { $0.fill != nil && $0.text == nil })
        let dissolve = try #require(presentation.slides[0].animations.first)
        #expect(presentation.slides[0].animations.count == 1)
        #expect(dissolve.shapeID == shape.shapeID)
        #expect(dissolve.category == .entrance)
        #expect(dissolve.effect == .fade)
        #expect(dissolve.trigger == .onClick)
        #expect(dissolve.duration == 0.75)

        let box = try #require(presentation.slides[1].shapes.first)
        let paragraphs = presentation.slides[1].animations
        #expect(paragraphs.map(\.shapeID) == [box.shapeID, box.shapeID])
        #expect(paragraphs.map(\.paragraphs) == [0...0, 1...1])
        #expect(paragraphs.allSatisfy { $0.effect == .appear && $0.trigger == .afterPrevious && $0.delay == 0.5 })

        let reread = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(reread.slides[1].animations.map(\.paragraphs) == [0...0, 1...1])
    }

    @Test("Transitions are kept as PowerPoint's nearest, and automatic ones move on by themselves")
    func transitions() {
        #expect(presentation.unsupportedFeatures.features == [.transitions])
        #expect(presentation.slides[0].autoAdvanceAfter == 2)
        #expect(!presentation.slides[0].advancesOnClick)
        #expect(presentation.slides[1].autoAdvanceAfter == nil)
    }

    @Test("Text that sets its own height is measured")
    func growingText() throws {
        let box = try #require(presentation.slides[1].shapes.first)
        #expect(box.frame.height > 0)
        #expect(box.text?.properties.autofit == .shape)
    }

    @Test("Groups place their children in their own space, growing text included")
    func groups() throws {
        let shape = try #require(presentation.slides[1].shapes.first { if case .group = $0.kind { true } else { false } })
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

        // In `en_US`, so numbers are written the way the tests expect.
        add(1, KeynoteType.document) { document in
            document.reference(2, 2)
            document.message(3) { $0.message(1) { $0.string(4, "en_US") } }
        }
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
            for drawable: UInt64 in [13, 14, 15, 17] { slide.reference(42, drawable) }
            // The red shape dissolves in on a tap; a motion path has no match.
            slide.reference(43, 80)
            slide.reference(43, 82)
            slide.message(4) { $0.message(2) { $0.message(8) { attributes in
                attributes.string(2, "apple:dissolve")
                attributes.double(3, 1.5)
                attributes.double(5, 2)
                attributes.varint(6, 1)
            } } }
        }
        add(80, 153) { chunk in
            chunk.reference(1, 81)
            chunk.double(4, 0.75)
        }
        add(81, 8) { build in
            build.reference(1, 14)
            build.string(2, "All at Once")
            build.message(4) { $0.message(18) { $0.string(1, "In"); $0.string(2, "apple:dissolve") } }
        }
        add(82, 153) { $0.reference(1, 83) }
        add(83, 8) { build in
            build.reference(1, 14)
            build.string(2, "All at Once")
            build.message(4) { $0.message(18) { $0.string(1, "Action"); $0.string(2, "apple:action-motion-path") } }
        }
        // An equation, which Dazzle cannot convert.
        add(17, 2015) { equation in
            equation.message(1) { $0.message(1) { $0.message(1) { $0.geometry(x: 0, y: 0, width: 10, height: 10) } } }
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
            slide.reference(42, 60)
            slide.reference(42, 70)
            // The bulleted text builds in a paragraph at a time, by itself.
            slide.reference(43, 84)
            slide.reference(43, 85)
        }
        for chunk: UInt64 in [84, 85] {
            add(chunk, 153) { chunk in
                chunk.reference(1, 86)
                chunk.varint(5, 1)
                chunk.double(3, 0.5)
            }
        }
        add(86, 8) { build in
            build.reference(1, 22)
            build.string(2, "By Paragraph")
            build.message(4) { $0.message(18) { $0.string(1, "In"); $0.string(2, "apple:appear") } }
        }
        // A column chart of two series, one per column, the second in green.
        add(70, KeynoteType.chart) { chart in
            chart.message(1) { $0.message(1) { $0.geometry(x: 500, y: 100, width: 400, height: 300) } }
            chart.message(10_000) { info in
                info.varint(1, 1)
                info.varint(5, 2)
                info.message(7) { grid in
                    grid.string(1, "2025")
                    grid.string(1, "2026")
                    grid.string(2, "Apples")
                    grid.string(2, "Pears")
                    for row in [[12.0, 7], [30, 18]] {
                        grid.message(3) { gridRow in
                            for value in row { gridRow.message(1) { $0.double(1, value) } }
                        }
                    }
                }
                info.reference(17, 71)
                info.reference(17, 72)
            }
        }
        add(71, 5028) { style in
            style.message(10_000) { $0.message(13) { $0.message(1) { $0.color(0, 0, 1) } } }
        }
        add(72, 5028) { style in
            style.message(10_000) { $0.message(13) { $0.message(1) { $0.color(0, 1, 0) } } }
        }
        addTable(add)
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

    /// A 2 × 3 table: a header row whose first two cells are merged, then
    /// a text cell, a number and an empty cell.
    private static func addTable(_ add: (UInt64, UInt32, (inout ProtoWriter) -> Void) -> Void) {
        add(60, KeynoteType.table) { info in
            info.message(1) { $0.message(1) { $0.geometry(x: 20, y: 600, width: 1, height: 1) } }
            info.reference(2, 61)
        }
        add(61, KeynoteType.tableModel) { model in
            model.message(4) { store in
                store.message(1) { $0.reference(2, 62) }
                store.reference(2, 63)
                store.message(3) { tiles in
                    tiles.message(1) { tile in
                        tile.varint(1, 0)
                        tile.reference(2, 64)
                    }
                }
                store.reference(4, 65)
            }
            model.varint(6, 2)
            model.varint(7, 3)
            model.varint(9, 1)
            model.double(16, 30)
            model.double(17, 100)
            model.reference(19, 66)
            // Merge A1:B1, as a formula naming the range.
            model.message(47) { $0.message(2) { $0.message(3) { pair in
                pair.message(2) { $0.message(1) { $0.message(1) { node in
                    node.varint(1, 67)
                    node.message(40) { tract in
                        tract.message(3) { $0.varint(1, 0); $0.varint(2, 1) }
                        tract.message(4) { $0.varint(1, 0) }
                    }
                } } }
            } } }
        }
        add(62, 6006) { bucket in
            bucket.message(2) { header in
                header.varint(1, 1)
                header.float(2, 50)
            }
        }
        add(63, 6006) { bucket in
            bucket.message(2) { header in
                header.varint(1, 2)
                header.float(2, 150)
            }
        }
        add(64, 6002) { tile in
            tile.message(5) { row in
                row.varint(1, 0)
                row.data(6, cell(type: 3, flags: 0x8, keys: [1]))
                row.data(7, offsets([0]))
            }
            tile.message(5) { row in
                row.varint(1, 1)
                let text = cell(type: 3, flags: 0x8, keys: [2])
                // 7.5: a coefficient of 75 and an exponent of -1.
                var number = cell(type: 2, flags: 0x1, keys: [])
                var decimal = [UInt8](repeating: 0, count: 16)
                decimal[0] = 75
                let exponent = 0x1820 - 1
                decimal[14] = UInt8((exponent << 1) & 0xFF)
                decimal[15] = UInt8(exponent >> 7)
                number += decimal
                row.data(6, text + number)
                row.data(7, offsets([0, text.count]))
            }
        }
        add(65, 6005) { list in
            list.message(3) { $0.varint(1, 1); $0.string(3, "Fruit") }
            list.message(3) { $0.varint(1, 2); $0.string(3, "Apples") }
        }
        add(66, KeynoteType.cellStyle) { style in
            style.message(11) { $0.message(1) { $0.message(1) { $0.color(0, 0, 1) } } }
        }
    }

    /// A packed table cell: its header, then four-byte keys after any value.
    private static func cell(type: UInt8, flags: UInt32, keys: [UInt32]) -> [UInt8] {
        var bytes: [UInt8] = [5, type, 0, 0, 0, 0, 0, 0]
        withUnsafeBytes(of: flags.littleEndian) { bytes += $0 }
        for key in keys { withUnsafeBytes(of: key.littleEndian) { bytes += $0 } }
        return bytes
    }

    /// A row's offsets: one per column, 0xFFFF for an empty cell.
    private static func offsets(_ values: [Int]) -> [UInt8] {
        var bytes: [UInt8] = []
        for column in 0..<256 {
            let value = column < values.count ? UInt16(values[column]) : 0xFFFF
            bytes += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        return bytes
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

    mutating func double(_ field: Int, _ value: Double) {
        bytes += Self.varint(UInt64(field << 3 | 1))
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes += $0 }
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
