@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

/// A Keynote deck of movies and sounds, built object by object.
///
/// Slide one: a movie that starts by itself, at half volume and looping,
/// beside a shape that dissolves in on a tap. Slide two: a sound a Start
/// Movie build starts on a tap, a movie an older Keynote saved as starting
/// on a tap, and a movie whose file is missing.
enum KeynoteMovieFixture {
    static let movieBytes = Data("not really a movie".utf8)
    static let soundBytes = Data("not really a sound".utf8)

    static func deck(movie: Data = movieBytes, movieName: String = "clip.mov", sound: Data = soundBytes) throws -> Data {
        var objects: [(id: UInt64, type: UInt32, message: ProtoWriter)] = []
        func add(_ id: UInt64, _ type: UInt32, _ build: (inout ProtoWriter) -> Void) {
            var writer = ProtoWriter()
            build(&writer)
            objects.append((id, type, writer))
        }
        func movieObject(_ id: UInt64, x: Float, _ build: (inout ProtoWriter) -> Void) {
            add(id, KeynoteType.movie) { movie in
                movie.message(1) { $0.message(1) { $0.geometry(x: x, y: 100, width: 320, height: 180) } }
                build(&movie)
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
            }
            show.message(4) { $0.size(1_024, 768) }
        }

        add(10, KeynoteType.slideNode) { $0.reference(2, 11) }
        add(11, KeynoteType.slide) { slide in
            slide.reference(1, 12)
            slide.reference(42, 13)
            slide.reference(42, 14)
            slide.reference(43, 80)
        }
        add(12, KeynoteType.slideStyle) { style in
            style.message(11) { $0.message(1) { $0.message(1) { $0.color(1, 1, 1) } } }
        }
        movieObject(13, x: 100) { movie in
            movie.reference(14, 901)
            movie.reference(15, 900)
            movie.float(7, 0.5)
            movie.varint(24, 1)
        }
        add(14, KeynoteType.shape) { shape in
            shape.message(1) { $0.message(1) { $0.geometry(x: 600, y: 400, width: 200, height: 100) } }
            shape.reference(2, 15)
        }
        add(15, KeynoteType.shapeStyle) { style in
            style.message(11) { $0.message(1) { $0.message(1) { $0.color(1, 0, 0) } } }
        }
        add(80, 153) { $0.reference(1, 81) }
        add(81, 8) { build in
            build.reference(1, 14)
            build.string(2, "All at Once")
            build.message(4) { $0.message(18) { $0.string(1, "In"); $0.string(2, "apple:dissolve") } }
        }

        add(20, KeynoteType.slideNode) { $0.reference(2, 21) }
        add(21, KeynoteType.slide) { slide in
            slide.reference(1, 12)
            slide.reference(42, 23)
            slide.reference(42, 24)
            slide.reference(42, 25)
            slide.reference(43, 84)
        }
        movieObject(23, x: 50) { sound in
            sound.reference(14, 902)
            sound.reference(16, 900)
            sound.varint(9, 1)
        }
        movieObject(24, x: 400) { movie in
            movie.reference(14, 901)
            movie.reference(15, 900)
            movie.varint(8, 0)
        }
        movieObject(25, x: 700) { movie in
            movie.reference(14, 999)
            movie.reference(15, 900)
        }
        add(84, 153) { $0.reference(1, 85) }
        add(85, 8) { build in
            build.reference(1, 23)
            build.string(2, "All at Once")
            build.message(4) { $0.message(18) { $0.string(1, "In"); $0.string(2, "apple:movie-start") } }
        }

        let files: [(UInt64, String)] = [(900, "poster.png"), (901, movieName), (902, "sound.wav")]
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
            ("Data/poster.png", KeynoteFixture.png),
            ("Data/\(movieName)", movie),
            ("Data/sound.wav", sound),
        ])
    }

    /// A second of quiet, as a WAV file any player opens.
    static func wav() -> Data {
        let samples = 8_000
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }
}

@Suite("Keynote movies")
struct KeynoteMovieTests {
    private let presentation: Presentation

    init() throws {
        presentation = try KeynoteImporter.presentation(from: KeynoteMovieFixture.deck())
    }

    private func media(_ slide: Int, at index: Int) throws -> (shape: SlideShape, picture: SlideShape.Picture) {
        let shape = presentation.slides[slide].shapes[index]
        guard case .picture(let picture) = shape.kind else { throw Failure("Expected a picture") }
        return (shape, picture)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @Test("A movie keeps its poster frame and carries its file, as it was, into the package")
    func movie() throws {
        let (_, picture) = try media(0, at: 0)
        let media = try #require(picture.media)
        #expect(media.kind == .video)
        let path = try #require(media.path)
        #expect(path.hasSuffix(".mov"))
        #expect(presentation.data(at: path) == KeynoteMovieFixture.movieBytes)
        let poster = try #require(picture.imagePath)
        #expect(presentation.data(at: poster) == KeynoteFixture.png)
    }

    @Test("A sound carries its file and shows its icon")
    func sound() throws {
        let (_, picture) = try media(1, at: 0)
        let media = try #require(picture.media)
        #expect(media.kind == .audio)
        let path = try #require(media.path)
        #expect(presentation.data(at: path) == KeynoteMovieFixture.soundBytes)
        let icon = try #require(picture.imagePath)
        #expect(presentation.data(at: icon) == KeynoteFixture.png)
    }

    @Test("A movie that starts by itself plays as the slide appears, before the slide's builds")
    func automatic() throws {
        let (shape, picture) = try media(0, at: 0)
        #expect(picture.media?.playsAutomatically == true)
        let animations = presentation.slides[0].animations
        #expect(animations.count == 2)
        #expect(animations[0].playsMedia)
        #expect(animations[0].shapeID == shape.shapeID)
        #expect(animations[0].trigger == .afterPrevious)
        #expect(animations[1].effect == .fade)
        #expect(animations[1].trigger == .onClick)
        #expect(presentation.slides[0].animationTimeline.tapCount == 1)
    }

    @Test("A Start Movie build plays the movie on its tap; a movie saved as starting on a tap waits for one")
    func startedByBuild() throws {
        let (sound, soundPicture) = try media(1, at: 0)
        #expect(soundPicture.media?.playsAutomatically == false)
        let animations = presentation.slides[1].animations
        #expect(animations.count == 1)
        #expect(animations[0].playsMedia)
        #expect(animations[0].shapeID == sound.shapeID)
        #expect(animations[0].trigger == .onClick)

        let (_, onTap) = try media(1, at: 1)
        #expect(onTap.media != nil)
        #expect(onTap.media?.playsAutomatically == false)
    }

    @Test("A movie whose file is missing shows its poster frame, and says so")
    func missing() throws {
        let (_, picture) = try media(1, at: 2)
        #expect(picture.media == nil)
        #expect(picture.imagePath != nil)
        #expect(presentation.unsupportedFeatures.omissions == [.movies])
    }

    @Test("PowerPoint's timing keeps each movie's volume and looping")
    func timing() throws {
        let part = try #require(presentation.slides[0].sourcePart)
        let xml = String(decoding: try #require(presentation.package.parts[part]), as: UTF8.self)
        #expect(xml.contains("<p:video><p:cMediaNode vol=\"50000\">"))
        #expect(xml.contains("repeatCount=\"indefinite\""))
        let soundPart = try #require(presentation.slides[1].sourcePart)
        let soundXML = String(decoding: try #require(presentation.package.parts[soundPart]), as: UTF8.self)
        #expect(soundXML.contains("<p:audio><p:cMediaNode vol=\"100000\">"))
    }

    @Test("Saved as PowerPoint, movies are embedded and play as they did")
    func powerPoint() throws {
        let data = try PPTXWriter.data(from: presentation)
        let copy = try PPTXReader.presentation(from: data)
        guard case .picture(let movie) = copy.slides[0].shapes[0].kind, let media = movie.media,
              case .picture(let sound) = copy.slides[1].shapes[0].kind, let soundMedia = sound.media else {
            Issue.record("Expected the movie and the sound")
            return
        }
        let moviePath = try #require(media.path)
        #expect(copy.data(at: moviePath) == KeynoteMovieFixture.movieBytes)
        #expect(media.playsAutomatically)
        #expect(soundMedia.kind == .audio)
        let soundPath = try #require(soundMedia.path)
        #expect(copy.data(at: soundPath) == KeynoteMovieFixture.soundBytes)
        #expect(!soundMedia.playsAutomatically)
        #expect(copy.slides[0].animations.first?.playsMedia == true)
        #expect(copy.slides[1].animations.first?.playsMedia == true)
        #expect(copy.slides[1].animations.first?.trigger == .onClick)

        let entries = try ZipArchive.entries(in: data)
        let partName = try #require(copy.slides[0].partName)
        let slide = String(decoding: try #require(entries[partName]), as: UTF8.self)
        #expect(slide.contains("p14:media"))
        #expect(slide.contains("cMediaNode vol=\"50000\""))
        let types = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
        #expect(types.contains("Extension=\"mov\""))
    }

    @Test("Saved back to Keynote, a deck of movies keeps every file as it was")
    func keynote() throws {
        let original = try KeynoteMovieFixture.deck()
        let opened = try KeynoteImporter.presentation(from: original)
        let written = try #require(try KeynoteWriter.fileWrapper(for: opened).regularFileContents)
        let before = try ZipArchive.orderedEntries(in: original)
        let after = try ZipArchive.orderedEntries(in: written)
        #expect(after.map(\.path) == before.map(\.path))
        for (old, new) in zip(before, after) {
            #expect(old.data == new.data, "\(old.path)")
        }
        let reopened = try KeynoteImporter.presentation(from: written)
        guard case .picture(let picture) = reopened.slides[0].shapes[0].kind else { return }
        #expect(picture.media?.kind == .video)
    }

    @Test("A movie moved is moved in Keynote, still playing its file")
    func moved() throws {
        var edited = presentation
        let old = edited.slides[0].shapes[0].frame
        edited.slides[0].shapes[0].frame.x = old.x + 12_700 * 20
        edited.slides[0].shapes[0].edits.insert(.transform)
        edited.slides[0].isModified = true
        let written = try KeynoteWriter.fileWrapper(for: edited)
        let reread = try KeynoteImporter.presentation(from: written)
        #expect(reread.slides[0].shapes[0].frame == edited.slides[0].shapes[0].frame)
        guard case .picture(let picture) = reread.slides[0].shapes[0].kind, let path = picture.media?.path else {
            Issue.record("Expected the movie")
            return
        }
        #expect(reread.data(at: path) == KeynoteMovieFixture.movieBytes)
    }
}

@Suite("Keynote movies in the slideshow")
@MainActor
struct KeynoteMoviePlaybackTests {
    @Test("A real movie and sound from Keynote play: the movie by itself, the sound on its tap")
    func plays() async throws {
        let blank = Presentation.blank
        let source = FileManager.default.temporaryDirectory.appending(path: "dazzle-keynote-movie.mp4")
        try await VideoExporter.export(blank.slides, of: blank, width: 320, durations: [1], to: source) { _ in }
        let deck = try KeynoteMovieFixture.deck(
            movie: try Data(contentsOf: source), movieName: "clip.mp4", sound: KeynoteMovieFixture.wav()
        )
        try? FileManager.default.removeItem(at: source)
        let presentation = try KeynoteImporter.presentation(from: deck)

        let session = PresentationSession()
        session.start(presentation, title: "Movies", fromSlide: 0, owner: UUID())
        let movie = presentation.slides[0].shapes[0]
        #expect(session.media.players[movie.id] != nil)
        #expect(session.media.isPlaying(movie.id))

        session.next()
        session.next()
        #expect(session.position == 1)
        let sound = presentation.slides[1].shapes[0]
        #expect(session.media.players[sound.id] != nil)
        #expect(!session.media.isPlaying(sound.id))
        session.next()
        #expect(session.media.isPlaying(sound.id))
        session.end()
    }
}
