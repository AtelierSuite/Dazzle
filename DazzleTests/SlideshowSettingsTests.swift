@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Slideshow settings")
@MainActor
struct SlideshowSettingsTests {
    private func deck(slides count: Int) throws -> (Presentation, EditorState) {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let layout = try #require(presentation.resources.orderedLayouts.last)
        for _ in 1..<count { state.addSlide(using: layout, in: &presentation) }
        state.selectSlide(presentation.slides[0].id)
        return (presentation, state)
    }

    private func showSettings(_ xml: String) throws -> SlideshowSettings {
        let root = try XMLLite.parse(Data("<p:showPr xmlns:p=\"\(OOXML.presentationML)\" \(xml)".utf8))
        return PPTXReader.readShowSettings(root)
    }

    @Test("Every setting of p:showPr is read, with the schema's defaults")
    func reading() throws {
        let defaults = try showSettings("/>")
        #expect(defaults.range == .all && !defaults.loops && defaults.usesTimings && defaults.showsAnimations)
        #expect(!defaults.playsNarration && !defaults.isKiosk)
        let set = try showSettings("""
            loop="1" useTimings="0" showAnimation="0" showNarration="1"><p:kiosk restart="60000"/><p:sldRg st="2" end="4"/></p:showPr>
            """)
        #expect(set.loops && !set.usesTimings && !set.showsAnimations && set.playsNarration)
        #expect(set.isKiosk && set.kioskRestartAfter == 60)
        #expect(set.range == .slides(from: 2, to: 4))
        #expect(try showSettings("><p:present/><p:custShow id=\"3\"/></p:showPr>").range == .customShow(3))
    }

    @Test("Settings are written as PowerPoint writes them and read back")
    func roundTrip() throws {
        var (presentation, state) = try deck(slides: 3)
        let show = state.addCustomShow(slides: [presentation.slides[2].id], in: &presentation)
        state.updateShowSettings(in: &presentation) { settings in
            settings.range = .customShow(show)
            settings.isKiosk = true
            settings.kioskRestartAfter = 120
            settings.usesTimings = false
            settings.showsAnimations = false
            settings.playsNarration = false
        }
        let data = try PPTXWriter.data(from: presentation)
        let xml = try #require(try ZipArchive.entries(in: data)["ppt/presProps.xml"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(xml.contains("<p:kiosk restart=\"120000\"/><p:custShow id=\"\(show)\"/>"))
        #expect(xml.contains("useTimings=\"0\"") && xml.contains("showAnimation=\"0\"") && !xml.contains("showNarration"))
        let copy = try PPTXReader.presentation(from: data)
        #expect(copy.showSettings == presentation.showSettings)

        var plain = copy
        state.updateShowSettings(in: &plain) { settings in
            settings = SlideshowSettings()
            settings.range = .slides(from: 2, to: 3)
        }
        let again = try PPTXReader.presentation(from: PPTXWriter.data(from: plain))
        #expect(again.showSettings == plain.showSettings)
        // Deleting the show a slideshow was set to play plays every slide again.
        state.updateShowSettings(in: &plain) { $0.range = .customShow(show) }
        state.deleteCustomShow(show, in: &plain)
        #expect(plain.showSettings.range == .all)
    }

    @Test("The slide range chooses the slides the show plays, leaving out hidden ones")
    func range() throws {
        var (presentation, state) = try deck(slides: 5)
        presentation.slides[2].isHidden = true
        state.updateShowSettings(in: &presentation) { $0.range = .slides(from: 2, to: 4) }
        #expect(presentation.slideshowOrder() == [1, 3])
        let session = PresentationSession()
        session.start(presentation, title: "Range", fromSlide: 0, owner: UUID())
        #expect(session.slideCount == 2 && session.currentSlide?.id == presentation.slides[1].id)
        session.end()
    }

    @Test("Without timings slides wait for a tap, and without animations they show fully built")
    func timingsAndAnimations() async throws {
        var (presentation, state) = try deck(slides: 2)
        state.setAutoAdvance(0.1, toAll: true, in: &presentation)
        state.insertTextBox(in: &presentation)
        let shape = try #require(presentation.slides[0].shapes.last)
        presentation.slides[0].animations = [ShapeAnimation(shapeID: shape.shapeID, category: .entrance, effect: .appear)]
        state.updateShowSettings(in: &presentation) {
            $0.usesTimings = false
            $0.showsAnimations = false
        }
        let session = PresentationSession()
        session.start(presentation, title: "Manual", fromSlide: 0, owner: UUID())
        #expect(!session.hasStepsLeft)
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.position == 0)
        session.next()
        #expect(session.position == 1)
        session.end()
    }

    @Test("A kiosk show ignores taps and keys, loops by its timings and starts over when left alone")
    func kiosk() async throws {
        var (presentation, state) = try deck(slides: 3)
        state.updateShowSettings(in: &presentation) {
            $0.isKiosk = true
            $0.usesTimings = false
            $0.kioskRestartAfter = 1
        }
        let session = PresentationSession()
        session.start(presentation, title: "Kiosk", fromSlide: 0, owner: UUID())
        #expect(!session.advancesOnTap)
        session.next()
        session.go(toPosition: 2)
        #expect(session.position == 0)
        // Links still move it.
        _ = session.follow(.lastSlide)
        #expect(session.position == 2)
        let deadline = Date().addingTimeInterval(3)
        while session.position != 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(session.position == 0)
        session.end()

        // Kiosk shows follow their timings even when set not to, and loop.
        state.setAutoAdvance(0.1, toAll: true, in: &presentation)
        session.start(presentation, title: "Kiosk", fromSlide: 2, owner: UUID())
        let looped = Date().addingTimeInterval(2)
        while session.position != 0 && Date() < looped { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.position == 0 && session.isPresenting)
        session.end()
    }
}
