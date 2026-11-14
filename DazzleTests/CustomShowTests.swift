@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Custom shows")
@MainActor
struct CustomShowTests {
    /// A blank deck with `count` slides, each with a text box, and an editor on its first.
    private func deck(slides count: Int) throws -> (Presentation, EditorState) {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let layout = try #require(presentation.resources.orderedLayouts.last)
        for _ in 1..<count { state.addSlide(using: layout, in: &presentation) }
        state.selectSlide(presentation.slides[0].id)
        return (presentation, state)
    }

    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    @Test("Custom shows are written into the presentation part and read back, in their order")
    func roundTrip() throws {
        var (presentation, state) = try deck(slides: 4)
        let ids = presentation.slides.map(\.id)
        let short = state.addCustomShow(slides: [ids[3], ids[1]], in: &presentation)
        state.renameCustomShow(short, to: "Short & sweet", in: &presentation)
        state.addCustomShow(slides: [ids[0]], in: &presentation)
        let data = try PPTXWriter.data(from: presentation)
        let xml = try #require(try ZipArchive.entries(in: data)["ppt/presentation.xml"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(xml.contains("<p:custShowLst>"))
        #expect(xml.contains("name=\"Short &amp; sweet\""))
        // After the slide size, as the schema orders it.
        let size = try #require(xml.range(of: "<p:sldSz"))
        #expect(try #require(xml.range(of: "<p:custShowLst")).lowerBound > size.lowerBound)

        let copy = try PPTXReader.presentation(from: data)
        #expect(copy.customShows.map(\.name) == ["Short & sweet", String(format: String(localized: "CustomShow.DefaultName"), 1)])
        let copyIDs = copy.slides.map(\.id)
        #expect(copy.customShows[0].slideIDs == [copyIDs[3], copyIDs[1]])
        #expect(copy.customShows[1].slideIDs == [copyIDs[0]])
    }

    @Test("Removing a slide drops it from the shows, and deleting a show removes it from the file")
    func editing() throws {
        var (presentation, state) = try deck(slides: 3)
        let ids = presentation.slides.map(\.id)
        let id = state.addCustomShow(slides: [ids[1], ids[2]], in: &presentation)
        var copy = try reread(presentation)
        state.selectSlide(copy.slides[1].id)
        state.deleteSlide(copy.slides[1].id, in: &copy)
        copy = try reread(copy)
        #expect(copy.customShows[0].slideIDs == [copy.slides[1].id])

        state.toggleSlide(copy.slides[0].id, inCustomShow: id, in: &copy)
        #expect(copy.customShows[0].slideIDs == [copy.slides[1].id, copy.slides[0].id])
        state.duplicateCustomShow(id, in: &copy)
        let first = String(format: String(localized: "CustomShow.DefaultName"), 1)
        #expect(copy.customShows.map(\.name) == [first, String(format: String(localized: "CustomShow.CopyName"), first)])
        state.deleteCustomShow(id, in: &copy)
        state.deleteCustomShow(copy.customShows[0].id, in: &copy)
        let emptied = try reread(copy)
        #expect(emptied.customShows.isEmpty)
        let xml = try ZipArchive.entries(in: PPTXWriter.data(from: copy))["ppt/presentation.xml"].flatMap { String(data: $0, encoding: .utf8) }
        #expect(xml?.contains("custShow") == false)
    }

    @Test("Links that start a custom show are read and written as PowerPoint writes them")
    func links() throws {
        let read = { (action: String) in
            let escaped = XMLLite.escape(action)
            return Hyperlink(element: try XMLLite.parse(Data(
                "<a:hlinkClick xmlns:a=\"\(OOXML.drawingML)\" xmlns:r=\"\(OOXML.relationshipsNS)\" r:id=\"\" action=\"\(escaped)\"/>".utf8
            ))) { _ in nil }
        }
        #expect(try read("ppaction://customshow?id=2&return=true") == .customShow(2, returns: true))
        #expect(try read("ppaction://customshow?id=0") == .customShow(0, returns: false))
        #expect(try read("ppaction://customshow?return=true") == .other)

        var (presentation, state) = try deck(slides: 2)
        let id = state.addCustomShow(slides: [presentation.slides[1].id], in: &presentation)
        state.insertTextBox(in: &presentation)
        state.setShapeLink(.customShow(id, returns: true), in: &presentation)
        let copy = try reread(presentation)
        #expect(copy.slides[0].shapes.contains { $0.link == .customShow(id, returns: true) })
    }

    @Test("A custom show plays its own slides, and one a link starts comes back to the link's slide")
    func playback() throws {
        var (presentation, state) = try deck(slides: 4)
        let ids = presentation.slides.map(\.id)
        presentation.slides[2].isHidden = true
        let show = state.addCustomShow(slides: [ids[3], ids[2], ids[0]], in: &presentation)
        #expect(presentation.slideshowOrder(customShow: show) == [3, 0])

        let session = PresentationSession()
        session.start(presentation, title: "Custom", fromSlide: 2, customShow: show, owner: UUID())
        #expect(session.currentSlide?.id == ids[3])
        #expect(session.slideCount == 2)
        session.next()
        #expect(session.currentSlide?.id == ids[0])
        session.next()
        #expect(!session.isPresenting)

        session.start(presentation, title: "Whole", fromSlide: 1, owner: UUID())
        #expect(session.currentSlide?.id == ids[1])
        _ = session.follow(.customShow(show, returns: true))
        #expect(session.currentSlide?.id == ids[3])
        session.next()
        session.next()
        // Back on the slide with the link, then on through the rest of the show.
        #expect(session.currentSlide?.id == ids[1])
        session.next()
        #expect(session.currentSlide?.id == ids[3])

        _ = session.follow(.customShow(show, returns: false))
        session.next()
        session.next()
        #expect(!session.isPresenting)
    }
}
