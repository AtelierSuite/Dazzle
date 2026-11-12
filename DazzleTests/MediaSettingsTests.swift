import AVFoundation
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Media settings")
@MainActor
struct MediaSettingsTests {
    /// A blank deck with a two-second video inserted on its first slide, saved.
    private func deckWithVideo() async throws -> (data: Data, video: PreparedVideo) {
        let blank = Presentation.blank
        let source = FileManager.default.temporaryDirectory.appending(path: "dazzle-settings-source.mp4")
        try? FileManager.default.removeItem(at: source)
        try await VideoExporter.export(blank.slides, of: blank, width: 320, durations: [2], to: source) { _ in }
        let video = try await PreparedVideo.prepare(from: source)
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertVideo(video, in: &presentation)
        return (try PPTXWriter.data(from: presentation), video)
    }

    private func media(of shape: SlideShape?) -> SlideShape.Media? {
        guard case .picture(let picture)? = shape?.kind else { return nil }
        return picture.media
    }

    @Test("Trim, fades and the timing's playback settings are read from PowerPoint's XML")
    func reads() async throws {
        let (data, _) = try await deckWithVideo()
        let copy = try PPTXReader.presentation(from: data)
        let shape = try #require(copy.slides[0].shapes.last)
        var parts = try ZipArchive.entries(in: data)
        let slidePath = try #require(copy.slides[0].partName)
        var xml = String(decoding: try #require(parts[slidePath]), as: UTF8.self)
        let element = try #require(xml.range(of: #"<p14:media [^>]*/>"#, options: .regularExpression))
        let opening = xml[element].dropLast(2)
        xml.replaceSubrange(element, with: "\(opening)><p14:trim st=\"1500\" end=\"250.5\"/><p14:fade in=\"500\" out=\"0:00:01.25\"/></p14:media>")
        xml = xml.replacingOccurrences(of: "</p:sld>", with: """
            <p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>\
            <p:video fullScrn="1"><p:cMediaNode vol="40000" mute="1" showWhenStopped="0"><p:cTn id="2" repeatCount="indefinite" \
            fill="remove" display="0"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst></p:cTn><p:tgtEl>\
            <p:spTgt spid="\(shape.shapeID)"/></p:tgtEl></p:cMediaNode></p:video></p:childTnLst></p:cTn></p:par></p:tnLst>\
            </p:timing></p:sld>
            """)
        parts[slidePath] = Data(xml.utf8)
        let read = try #require(media(of: try PPTXReader.presentation(fromParts: parts).slides[0].shapes.last))
        #expect(read.trimStart == 1.5)
        #expect(read.trimEnd == 0.2505)
        #expect(read.fadeIn == 0.5)
        #expect(read.fadeOut == 1.25)
        #expect(read.volume == 0.4)
        #expect(read.isMuted)
        #expect(read.effectiveVolume == 0)
        #expect(read.loops)
        #expect(read.rewinds)
        #expect(read.playsFullScreen)
        #expect(read.hidesWhenNotPlaying)
        #expect(!read.playsAcrossSlides)

        // With no node in the timing, it plays as PowerPoint's defaults have it.
        let plain = try #require(media(of: copy.slides[0].shapes.last))
        #expect(plain.volume == 1)
        #expect(!plain.loops && !plain.rewinds && !plain.playsFullScreen && !plain.hidesWhenNotPlaying)
        #expect(plain.trimStart == 0 && plain.trimEnd == 0 && plain.fadeIn == 0 && plain.fadeOut == 0)
    }

    @Test("Settings changed in Dazzle are saved where PowerPoint keeps them, and read back")
    func writes() async throws {
        let (data, _) = try await deckWithVideo()
        var presentation = try PPTXReader.presentation(from: data)
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let shape = try #require(presentation.slides[0].shapes.last)
        state.selectedShapeID = shape.id
        state.setMedia(in: &presentation) { media in
            media.trimStart = 0.5
            media.trimEnd = 0.25
            media.fadeIn = 1
            media.fadeOut = 0.75
            media.volume = 0.6
            media.loops = true
            media.rewinds = true
            media.playsFullScreen = true
            media.hidesWhenNotPlaying = true
            // Only a sound plays across slides.
            media.playsAcrossSlides = true
        }
        let saved = try PPTXWriter.data(from: presentation)
        let slidePath = try #require(presentation.slides[0].partName)
        let xml = String(decoding: try #require(try ZipArchive.entries(in: saved)[slidePath]), as: UTF8.self)
        #expect(xml.contains(#"<p14:trim st="500" end="250"/>"#))
        #expect(xml.contains(#"<p14:fade in="1000" out="750"/>"#))
        #expect(xml.contains(#"<p:video fullScrn="1">"#))
        #expect(xml.contains(#"vol="60000""#))
        #expect(xml.contains(#"showWhenStopped="0""#))
        #expect(xml.contains(#"repeatCount="indefinite""#))
        #expect(xml.contains(#"fill="remove""#))
        #expect(!xml.contains("numSld"))

        let read = try #require(media(of: try PPTXReader.presentation(from: saved).slides[0].shapes.last))
        #expect(read.trimStart == 0.5 && read.trimEnd == 0.25)
        #expect(read.fadeIn == 1 && read.fadeOut == 0.75)
        #expect(read.volume == 0.6 && !read.isMuted)
        #expect(read.loops && read.rewinds && read.playsFullScreen && read.hidesWhenNotPlaying)
        #expect(!read.playsAcrossSlides)

        // Back to the defaults: the node stays, saying so, and the trim and fades go.
        var reread = try PPTXReader.presentation(from: saved)
        state.selectSlide(reread.slides[0].id)
        state.selectedShapeID = try #require(reread.slides[0].shapes.last).id
        state.setMedia(in: &reread) { $0 = SlideShape.Media(kind: .video, path: $0.path) }
        let reset = try PPTXWriter.data(from: reread)
        let resetXML = String(decoding: try #require(try ZipArchive.entries(in: reset)[slidePath]), as: UTF8.self)
        #expect(!resetXML.contains("p14:trim") && !resetXML.contains("p14:fade"))
        #expect(!resetXML.contains("fullScrn") && !resetXML.contains("showWhenStopped") && !resetXML.contains("repeatCount"))
        #expect(resetXML.contains(#"vol="100000""#))
    }

    @Test("A sound set to play across slides is saved with the slides it plays across")
    func acrossSlides() throws {
        var media = SlideShape.Media(kind: .audio, path: "ppt/media/media1.m4a")
        media.playsAcrossSlides = true
        media.playsFullScreen = true
        var shape = SlideShape(shapeID: 4, name: "Sound", kind: .picture(SlideShape.Picture(media: media)), frame: .zero)
        shape.edits = [.media]
        let root = try XMLLite.parse(Data(#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld/></p:sld>"#.utf8))
        MediaXML.write([shape], changed: [4], into: root)
        let xml = try #require(XMLLite.serialize(root))
        #expect(xml.contains(#"<p:audio><p:cMediaNode vol="100000" numSld="999">"#))
        #expect(!xml.contains("fullScrn"))
        var read = [shape]
        MediaXML.read(try #require(root.firstChild(named: "timing")), into: &read)
        #expect(self.media(of: read.first)?.playsAcrossSlides == true)
    }

    @Test("The trimmed range and fades are worked out from the file's length")
    func ranges() {
        var media = SlideShape.Media(kind: .video)
        media.trimStart = 1
        media.trimEnd = 2
        media.fadeIn = 1
        media.fadeOut = 2
        #expect(media.playedRange(duration: 10) == 1...8)
        #expect(media.fadeLevel(at: 1, duration: 10) == 0)
        #expect(media.fadeLevel(at: 1.5, duration: 10) == 0.5)
        #expect(media.fadeLevel(at: 4, duration: 10) == 1)
        #expect(media.fadeLevel(at: 7, duration: 10) == 0.5)
        #expect(media.fadeLevel(at: 8, duration: 10) == 0)
        // Trimmed past its length, nothing plays.
        media.trimStart = 12
        #expect(media.playedRange(duration: 10) == 10...10)
    }

    @Test("In a slideshow, trimmed media starts at its trim, hidden media is not drawn or found, and volume is set")
    func playback() async throws {
        let (data, _) = try await deckWithVideo()
        var presentation = try PPTXReader.presentation(from: data)
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let shape = try #require(presentation.slides[0].shapes.last)
        state.selectedShapeID = shape.id
        state.setMedia(in: &presentation) { media in
            media.trimStart = 1
            media.volume = 0.3
            media.hidesWhenNotPlaying = true
        }
        let slide = presentation.slides[0]

        // Hidden in the show, drawn everywhere else.
        let shown = try #require(SlideExporter.cgImage(of: slide, in: presentation, width: 320, options: .presentation))
        let hidden = try #require(SlideExporter.cgImage(of: slide, in: presentation, width: 320, options: .slideshow))
        #expect(pixels(of: shown) != pixels(of: hidden))

        let playback = MediaPlayback()
        playback.show(slide, in: presentation)
        let player = try #require(playback.players[shape.id])
        #expect(abs(player.volume - 0.3) < 0.001)
        let deadline = Date().addingTimeInterval(3)
        while abs(player.currentTime().seconds - 1) > 0.05, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(player.currentTime().seconds - 1) <= 0.05)
        playback.stopAll()

        let session = PresentationSession()
        session.start(presentation, title: "Test", fromSlide: 0, owner: UUID())
        let point = CGPoint(x: shape.frame.points.midX, y: shape.frame.points.midY)
        #expect(session.mediaShape(at: point) == nil)
        session.media.play(shape.id)
        #expect(session.mediaShape(at: point) == shape.id)
        session.end()
    }

    @Test("A sound set to play across slides keeps playing as the show moves on")
    func keepsPlaying() async throws {
        let (data, _) = try await deckWithVideo()
        var presentation = try PPTXReader.presentation(from: data)
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let shape = try #require(presentation.slides[0].shapes.last)
        state.selectedShapeID = shape.id
        state.setMedia(in: &presentation) { $0.kind = .audio }
        state.setMedia(in: &presentation) { $0.playsAcrossSlides = true }
        let layout = try #require(presentation.resources.orderedLayouts.last)
        state.addSlide(using: layout, in: &presentation)

        let playback = MediaPlayback()
        playback.show(presentation.slides[0], in: presentation)
        playback.play(shape.id)
        playback.show(presentation.slides[1], in: presentation)
        #expect(playback.isPlaying(shape.id))
        playback.show(nil, in: presentation)
        #expect(!playback.isPlaying(shape.id))
        #expect(playback.players.isEmpty)
    }

    private func pixels(of image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
