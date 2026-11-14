@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Slide sections")
@MainActor
struct SlideSectionTests {
    /// A blank deck with `count` slides.
    private func deck(_ count: Int) -> (Presentation, EditorState) {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let layout = presentation.resources.orderedLayouts[0]
        for _ in 1..<count { state.addSlide(using: layout, in: &presentation) }
        return (presentation, state)
    }

    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    /// Each section's slides, as positions in the deck.
    private func layout(_ presentation: Presentation) -> [[Int]] {
        presentation.sections.map { $0.slideIDs.compactMap(presentation.index(of:)) }
    }

    @Test("Adding a section splits the slides there, with a default section before")
    func adding() throws {
        var (presentation, state) = deck(5)
        state.selectSlide(presentation.slides[2].id)
        let id = try #require(state.addSection(in: &presentation))
        #expect(layout(presentation) == [[0, 1], [2, 3, 4]])
        #expect(presentation.sections[0].name == SlideSection.defaultName)
        #expect(presentation.sections[1].id == id)
        state.selectSlide(presentation.slides[3].id)
        state.addSection(in: &presentation)
        #expect(layout(presentation) == [[0, 1], [2], [3, 4]])
        // At the first slide with no sections yet, every slide goes in one.
        var (other, otherState) = deck(3)
        otherState.selectSlide(other.slides[0].id)
        otherState.addSection(in: &other)
        #expect(layout(other) == [[0, 1, 2]])
    }

    @Test("New, duplicated, deleted and pasted slides keep the sections whole")
    func slideEdits() throws {
        var (presentation, state) = deck(4)
        state.selectSlide(presentation.slides[2].id)
        state.addSection(in: &presentation)
        state.selectSlide(presentation.slides[1].id)
        state.duplicateSlide(presentation.slides[1].id, in: &presentation)
        #expect(layout(presentation) == [[0, 1, 2], [3, 4]])
        state.deleteSlide(presentation.slides[0].id, in: &presentation)
        #expect(layout(presentation) == [[0, 1], [2, 3]])
        state.selectSlide(presentation.slides[3].id)
        state.addSlide(using: presentation.resources.orderedLayouts[0], in: &presentation)
        #expect(layout(presentation) == [[0, 1], [2, 3, 4]])
    }

    @Test("A moved slide joins the section of the slide it takes the place of")
    func movingSlides() throws {
        var (presentation, state) = deck(4)
        state.selectSlide(presentation.slides[2].id)
        state.addSection(in: &presentation)
        let first = presentation.slides[0].id
        // Down onto the third slide: into the second section.
        state.moveSlide(first, to: 2, in: &presentation)
        #expect(presentation.section(of: first)?.id == presentation.sections[1].id)
        #expect(layout(presentation) == [[0], [1, 2, 3]])
        // Back up onto the first: into the first section again.
        state.moveSlide(first, to: 0, in: &presentation)
        #expect(presentation.section(of: first)?.id == presentation.sections[0].id)
        #expect(layout(presentation) == [[0, 1], [2, 3]])
        // Straight into a section, at its end.
        let last = presentation.slides[3].id
        state.moveSlides([last], toSection: presentation.sections[0].id, in: &presentation)
        #expect(presentation.slides[2].id == last)
        #expect(layout(presentation) == [[0, 1, 2], [3]])
    }

    @Test("Slides out of order settle into as few section changes as possible")
    func settling() {
        var (presentation, _) = deck(4)
        let ids = presentation.slides.map(\.id)
        presentation.sections = [
            SlideSection(name: "A", slideIDs: [ids[0], ids[1]]), SlideSection(name: "B", slideIDs: [ids[2], ids[3]]),
        ]
        // The last slide moved to the front, with nothing saying where it belongs.
        presentation.slides.insert(presentation.slides.remove(at: 3), at: 0)
        presentation.settleSections()
        #expect(presentation.sections.map(\.slideIDs) == [[ids[3], ids[0], ids[1]], [ids[2]]])
    }

    @Test("Sections are renamed, moved with their slides and removed")
    func editingSections() throws {
        var (presentation, state) = deck(5)
        state.selectSlide(presentation.slides[2].id)
        state.addSection(in: &presentation)
        state.selectSlide(presentation.slides[4].id)
        state.addSection(in: &presentation)
        let ids = presentation.slides.map(\.id)
        let last = presentation.sections[2].id
        state.renameSection(last, to: "  Wrap-up ", in: &presentation)
        #expect(presentation.sections[2].name == "Wrap-up")
        state.renameSection(last, to: "", in: &presentation)
        #expect(presentation.sections[2].name == SlideSection.untitledName)

        state.moveSection(last, to: 0, in: &presentation)
        #expect(presentation.slides.map(\.id) == [ids[4], ids[0], ids[1], ids[2], ids[3]])
        #expect(presentation.isStructureModified)
        #expect(layout(presentation) == [[0], [1, 2], [3, 4]])

        // A removed section's slides join the one before, or after for the first.
        state.removeSection(presentation.sections[1].id, in: &presentation)
        #expect(layout(presentation) == [[0, 1, 2], [3, 4]])
        state.removeSection(presentation.sections[0].id, in: &presentation)
        #expect(layout(presentation) == [[0, 1, 2, 3, 4]])
        state.removeAllSections(in: &presentation)
        #expect(presentation.sections.isEmpty)
    }

    @Test("Sections are saved as p14:sectionLst and read back")
    func roundTrip() throws {
        var (presentation, state) = deck(4)
        state.selectSlide(presentation.slides[1].id)
        let id = try #require(state.addSection(in: &presentation))
        state.renameSection(id, to: "Results & <Next>", in: &presentation)
        state.selectSlide(presentation.slides[3].id)
        state.addSection(in: &presentation)
        let saved = try reread(presentation)
        #expect(saved.sections.map(\.name) == [SlideSection.defaultName, "Results & <Next>", SlideSection.untitledName])
        #expect(saved.sections.map(\.id) == presentation.sections.map(\.id))
        #expect(layout(saved) == [[0], [1, 2], [3]])
        let xml = try #require(saved.package.parts[saved.package.mainPart].flatMap { String(data: $0, encoding: .utf8) })
        #expect(xml.contains("{521415D9-36F7-43E2-AB2F-B90AF26B5E84}"))

        // Untouched, they stay; after a slide is removed, they still cover every slide.
        var edited = saved
        let editor = EditorState()
        editor.deleteSlide(edited.slides[2].id, in: &edited)
        let again = try reread(edited)
        #expect(layout(again) == [[0], [1], [2]])

        // With every section removed, the list goes too.
        var cleared = again
        cleared.removeAllSections()
        let none = try reread(cleared)
        #expect(none.sections.isEmpty)
        let noneXML = try #require(none.package.parts[none.package.mainPart].flatMap { String(data: $0, encoding: .utf8) })
        #expect(!noneXML.contains("sectionLst"))
    }

    @Test("A section list naming missing slides, or missing some, is made whole on reading")
    func reading() throws {
        var (presentation, _) = deck(3)
        let ids = presentation.slides.map(\.id)
        presentation.sections = [SlideSection(name: "Only", slideIDs: [ids[1]])]
        presentation.areSectionsModified = true
        let saved = try reread(presentation)
        #expect(saved.sections.count == 1)
        #expect(saved.sections[0].slideIDs.count == 3)
    }
}
