@testable import Dazzle
@testable import DazzleEngine
import CoreGraphics
import Foundation
import Testing

/// A Keynote deck of the objects beyond shapes, pictures, movies, charts
/// and tables, built object by object.
///
/// Slide one: a connection line, a freehand drawing at half opacity, and a
/// sound with no icon. Slide two: an equation typeset into a picture, one
/// whose picture can't be drawn, a 3D object with a still of itself and one
/// without. Slide three: an object of a kind Keynote may add later, a sticky
/// comment with a reply, an object with no frame, and a chart from before 2013.
enum KeynoteObjectFixture {
    static let soundBytes = Data("not really a sound".utf8)

    static func deck() throws -> Data {
        var objects: [(id: UInt64, type: UInt32, message: ProtoWriter)] = []
        func add(_ id: UInt64, _ type: UInt32, _ build: (inout ProtoWriter) -> Void) {
            var writer = ProtoWriter()
            build(&writer)
            objects.append((id, type, writer))
        }
        /// A `TSD.DrawableArchive` at field 1.
        func drawable(_ message: inout ProtoWriter, x: Float, y: Float, width: Float, height: Float) {
            message.message(1) { $0.message(1) { $0.geometry(x: x, y: y, width: width, height: height) } }
        }
        /// A `TSD.PathSourceArchive` of a Bézier path from the first point through the rest.
        func path(_ points: [(Float, Float)], natural: (Float, Float), connection: Bool) -> (inout ProtoWriter) -> Void {
            { source in
                let bezier: (inout ProtoWriter) -> Void = { bezier in
                    bezier.message(2) { $0.size(natural.0, natural.1) }
                    bezier.message(3) { path in
                        for (index, point) in points.enumerated() {
                            path.message(1) { element in
                                element.varint(1, index == 0 ? 1 : 2)
                                element.message(2) { $0.size(point.0, point.1) }
                            }
                        }
                    }
                }
                if connection {
                    source.message(7) { $0.message(1, bezier) }
                } else {
                    source.message(5, bezier)
                }
            }
        }

        add(1, KeynoteType.document) { document in
            document.reference(2, 2)
            document.message(3) { $0.message(1) { $0.string(4, "en_US") } }
        }
        add(2, KeynoteType.show) { show in
            show.message(3) { tree in
                tree.reference(2, 10)
                tree.reference(2, 20)
                tree.reference(2, 30)
            }
            show.message(4) { $0.size(1_024, 768) }
        }
        add(12, KeynoteType.slideStyle) { style in
            style.message(11) { $0.message(1) { $0.message(1) { $0.color(1, 1, 1) } } }
        }
        add(15, KeynoteType.shapeStyle) { style in
            style.message(11) { properties in
                properties.message(1) { $0.message(1) { $0.color(1, 0, 0) } }
                properties.message(2) { stroke in
                    stroke.message(1) { $0.color(0, 0, 1) }
                    stroke.float(2, 3)
                }
            }
        }

        // Slide one.
        add(10, KeynoteType.slideNode) { $0.reference(2, 11) }
        add(11, KeynoteType.slide) { slide in
            slide.reference(1, 12)
            for drawable in [13, 14, 18] as [UInt64] { slide.reference(42, drawable) }
        }
        add(13, KeynoteType.connectionLine) { line in
            line.message(1) { shape in
                drawable(&shape, x: 100, y: 100, width: 300, height: 100)
                shape.reference(2, 15)
                shape.message(3, path([(0, 0), (150, 100), (300, 0)], natural: (300, 100), connection: true))
            }
            line.reference(2, 14)
            line.reference(3, 18)
        }
        add(14, KeynoteType.group) { group in
            drawable(&group, x: 500, y: 100, width: 200, height: 200)
            group.reference(2, 16)
            group.message(100) { $0.double(2, 0.5) }
        }
        add(16, KeynoteType.shape) { stroke in
            drawable(&stroke, x: 0, y: 0, width: 200, height: 200)
            stroke.reference(2, 15)
            stroke.message(3, path([(0, 0), (200, 50), (20, 200)], natural: (200, 200), connection: false))
        }
        add(18, KeynoteType.movie) { sound in
            drawable(&sound, x: 50, y: 500, width: 64, height: 64)
            sound.reference(14, 902)
            sound.varint(9, 1)
        }

        // Slide two.
        add(20, KeynoteType.slideNode) { $0.reference(2, 21) }
        add(21, KeynoteType.slide) { slide in
            slide.reference(1, 12)
            for drawable in [23, 24, 25, 26] as [UInt64] { slide.reference(42, drawable) }
        }
        add(23, KeynoteType.image) { equation in
            drawable(&equation, x: 50, y: 50, width: 200, height: 60)
            equation.reference(11, 903)
            equation.string(103, "x^2 + y^2 = z^2")
        }
        add(24, KeynoteType.image) { equation in
            drawable(&equation, x: 50, y: 200, width: 200, height: 60)
            equation.reference(11, 904)
            equation.string(103, "e^{i\\pi} = -1")
        }
        add(25, KeynoteType.movie) { object in
            drawable(&object, x: 400, y: 50, width: 300, height: 300)
            object.message(200) { info in
                info.reference(1, 905)
                info.reference(5, 900)
            }
        }
        add(26, KeynoteType.movie) { object in
            drawable(&object, x: 400, y: 400, width: 300, height: 300)
            object.message(200) { $0.reference(1, 905) }
        }

        // Slide three.
        add(30, KeynoteType.slideNode) { $0.reference(2, 31) }
        add(31, KeynoteType.slide) { slide in
            slide.reference(1, 12)
            for drawable in [33, 34, 35, 39] as [UInt64] { slide.reference(42, drawable) }
        }
        // A kind Dazzle doesn't know, extending a shape as most drawables do.
        add(33, 3_999) { object in
            object.message(1) { shape in drawable(&shape, x: 100, y: 100, width: 400, height: 200) }
        }
        add(34, KeynoteType.commentInfo) { comment in
            comment.message(1) { info in
                info.message(1) { shape in drawable(&shape, x: 40, y: 60, width: 150, height: 150) }
            }
            comment.reference(2, 36)
        }
        add(36, 3_056) { storage in
            storage.string(1, "Check these figures")
            storage.message(2) { $0.double(1, 700_000_000) }
            storage.reference(3, 37)
            storage.reference(4, 38)
        }
        add(37, 212) { $0.string(1, "Ada Lovelace") }
        add(38, 3_056) { reply in
            reply.string(1, "Done")
            reply.reference(3, 37)
        }
        add(35, 3_998) { $0.message(1) { $0.varint(1, 7) } }
        add(39, KeynoteType.olderChart) { chart in
            drawable(&chart, x: 500, y: 300, width: 400, height: 300)
        }

        let files: [(UInt64, String)] = [
            (900, "still.png"), (902, "sound.m4a"), (903, "equation.png"), (904, "equation.pdf"), (905, "model.usdz"),
        ]
        add(50, KeynoteType.packageMetadata) { metadata in
            for (id, name) in files {
                metadata.message(4) { data in
                    data.varint(1, id)
                    data.string(3, name)
                    data.string(4, name)
                }
            }
        }

        return try ZipArchive.archive(entries: [
            ("Index/Document.iwa", KeynoteFixture.iwa(objects.filter { $0.id != 50 })),
            ("Index/Metadata.iwa", KeynoteFixture.iwa(objects.filter { $0.id == 50 })),
            ("Data/still.png", KeynoteFixture.png),
            ("Data/sound.m4a", soundBytes),
            ("Data/equation.png", KeynoteFixture.png),
            // Not a picture any platform draws.
            ("Data/equation.pdf", Data("not really a PDF".utf8)),
            ("Data/model.usdz", Data("not really a model".utf8)),
        ])
    }
}

@Suite("Keynote objects beyond shapes, pictures, movies, charts and tables")
struct KeynoteObjectTests {
    private let presentation: Presentation

    init() throws {
        presentation = try KeynoteImporter.presentation(from: KeynoteObjectFixture.deck())
    }

    private func label(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .engine) }

    private func points(_ value: Double) -> Int { Int((value * 12_700).rounded()) }

    @Test("A connection line is a connector, placed and drawn as Keynote has it")
    func connectionLine() throws {
        let line = presentation.slides[0].shapes[0]
        #expect(line.kind == .connector)
        #expect(line.frame == EMURect(x: points(100), y: points(100), width: points(300), height: points(100)))
        let width = try #require(line.line?.width)
        #expect(width == points(3))
        guard case .custom = line.geometry else {
            Issue.record("Expected the line's own path, got \(String(describing: line.geometry))")
            return
        }
    }

    @Test("A freehand drawing is a group of its strokes, each as opaque as the drawing")
    func freehandDrawing() throws {
        let drawing = presentation.slides[0].shapes[1]
        guard case .group(let group) = drawing.kind else {
            Issue.record("Expected a group")
            return
        }
        #expect(group.children.count == 1)
        #expect(group.children.first?.kind == .shape)
        #expect(drawing.frame.width == points(200))
        let archive = try KeynoteArchive(entries: ZipArchive.entries(in: KeynoteObjectFixture.deck()))
        let parts = try KeynoteImporter.convert(archive, media: KeynoteMedia(archive: archive)).parts
        let slide = String(decoding: try #require(parts["ppt/slides/slide1.xml"]), as: UTF8.self)
        #expect(slide.contains("name=\"Drawing"))
        #expect(slide.contains("<a:srgbClr val=\"FF0000\"><a:alpha val=\"50000\"/></a:srgbClr>"))
    }

    @Test("A sound with no icon plays, and says it is a sound where its icon would be")
    func soundWithoutIcon() throws {
        guard case .picture(let picture) = presentation.slides[0].shapes[2].kind else {
            Issue.record("Expected the sound")
            return
        }
        #expect(picture.imagePath == nil)
        #expect(picture.media?.kind == .audio)
        let path = try #require(picture.media?.path)
        #expect(presentation.data(at: path) == KeynoteObjectFixture.soundBytes)
        #expect(picture.standInLabel == label("Object.Audio"))
        #expect(SlideShape.Picture(media: SlideShape.Media(kind: .video)).standInLabel == label("Object.Movie"))
        #expect(SlideShape.Picture().standInLabel == label("Object.Picture"))
    }

    @Test("An equation shows its picture, or a stand-in where it can't")
    func equations() throws {
        let shapes = presentation.slides[1].shapes
        guard case .picture(let typeset) = shapes[0].kind else {
            Issue.record("Expected the equation's picture")
            return
        }
        #expect(presentation.data(at: try #require(typeset.imagePath)) == KeynoteFixture.png)
        #expect(shapes[1].kind == .unsupported(label("Object.Equation")))
        #expect(shapes[1].frame == EMURect(x: points(50), y: points(200), width: points(200), height: points(60)))
    }

    @Test("A 3D object shows its still picture, or a stand-in when it has none")
    func objects3D() throws {
        let shapes = presentation.slides[1].shapes
        guard case .picture(let still) = shapes[2].kind else {
            Issue.record("Expected the 3D object's still")
            return
        }
        #expect(still.media == nil)
        #expect(presentation.data(at: try #require(still.imagePath)) == KeynoteFixture.png)
        #expect(shapes[3].kind == .unsupported(label("Object.3D")))
        #expect(shapes.count == 4)
    }

    @Test("Objects of kinds Dazzle doesn't know, and charts from before 2013, keep their place as stand-ins")
    func standIns() throws {
        let shapes = presentation.slides[2].shapes
        #expect(shapes.count == 2)
        #expect(shapes[0].kind == .unsupported(label("Object.Other")))
        #expect(shapes[0].frame == EMURect(x: points(100), y: points(100), width: points(400), height: points(200)))
        #expect(shapes[1].kind == .chart(nil))
        #expect(presentation.unsupportedFeatures.omissions == [
            .chartStandIns, .objects3D, .equationStandIns, .objectStandIns, .otherObjects,
        ])
        #expect(presentation.unsupportedFeatures.features.isEmpty)
        for omission in [UnsupportedFeatureReport.Omission.objects3D, .equationStandIns, .objectStandIns] {
            #expect(!omission.message.hasPrefix("Notice."), "\(omission) is worded")
        }
    }

    @Test("A sticky comment is one of the slide's comments, with who wrote it, when, and its replies")
    func stickyComment() throws {
        let comments = presentation.slides[2].comments
        #expect(comments.count == 1)
        let comment = try #require(comments.first)
        #expect(comment.text == "Check these figures")
        #expect(comment.author == "Ada Lovelace")
        #expect(comment.initials == "AL")
        #expect(comment.date == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(comment.position == CGPoint(x: 40, y: 60))
        #expect(comment.replies.map(\.text) == ["Done"])
        #expect(presentation.slides[0].comments.isEmpty)
    }

    @Test("Saved as PowerPoint, every object, stand-in and comment comes back as it was")
    func powerPoint() throws {
        let data = try PPTXWriter.data(from: presentation)
        let copy = try PPTXReader.presentation(from: data)
        #expect(copy.slides.count == 3)
        #expect(copy.slides[0].shapes[0].kind == .connector)
        if case .group(let group) = copy.slides[0].shapes[1].kind {
            #expect(group.children.count == 1)
        } else {
            Issue.record("Expected the drawing")
        }
        #expect(copy.slides[1].shapes[1].kind == .unsupported(label("Object.Equation")))
        #expect(copy.slides[1].shapes[3].kind == .unsupported(label("Object.3D")))
        #expect(copy.slides[2].shapes[0].kind == .unsupported(label("Object.Other")))
        #expect(copy.slides[2].shapes[0].frame == presentation.slides[2].shapes[0].frame)
        #expect(copy.slides[2].comments.map(\.text) == ["Check these figures"])
        #expect(copy.slides[2].comments.first?.replies.map(\.text) == ["Done"])
        #expect(copy.slides[2].comments.first?.author == "Ada Lovelace")

        // PowerPoint, which doesn't know the stand-in's extension, sees a box naming the object.
        let entries = try ZipArchive.entries(in: data)
        let partName = try #require(copy.slides[2].partName)
        let slide = String(decoding: try #require(entries[partName]), as: UTF8.self)
        let root = try XMLLite.parse(Data(slide.utf8))
        let standIn = try #require(root.firstDescendant(atPath: "cSld/spTree/sp"))
        #expect(standIn.firstDescendant(atPath: "txBody/p/r/t")?.text == label("Object.Other"))
        #expect(standIn.firstDescendant(atPath: "spPr/ln/prstDash")?.attribute("val") == "dash")
        #expect(StandIn.label(in: standIn.firstDescendant(atPath: "nvSpPr/nvPr")) == label("Object.Other"))
        let types = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
        #expect(types.contains("comments+xml"))
    }

    @Test("Saved back to Keynote, a deck of these objects keeps every file as it was")
    func keynote() throws {
        let original = try KeynoteObjectFixture.deck()
        let opened = try KeynoteImporter.presentation(from: original)
        let written = try #require(try KeynoteWriter.fileWrapper(for: opened).regularFileContents)
        let before = try ZipArchive.orderedEntries(in: original)
        let after = try ZipArchive.orderedEntries(in: written)
        #expect(after.map(\.path) == before.map(\.path))
        for (old, new) in zip(before, after) {
            #expect(old.data == new.data, "\(old.path)")
        }
        let reopened = try KeynoteImporter.presentation(from: written)
        #expect(reopened.slides[2].comments.count == 1)
        #expect(reopened.slides[2].shapes[0].kind == .unsupported(label("Object.Other")))
    }
}
