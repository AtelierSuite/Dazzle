import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@MainActor
@Suite("Master view")
struct MasterViewTests {
    private static let masterPath = PresentationTemplate.masterPath
    private static let contentLayout = "ppt/slideLayouts/slideLayout2.xml"

    /// A new presentation with a second slide on Title and Content, whose
    /// placeholders take their places from the master.
    private func deck() throws -> (Presentation, EditorState) {
        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        let layout = try #require(presentation.resources.layouts[Self.contentLayout])
        state.addSlide(using: layout, in: &presentation)
        return (presentation, state)
    }

    /// The presentation as another app would open what Dazzle saves.
    private func saved(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    /// The names Dazzle gives a new layout and a layout's copy, in the language the tests run in.
    private static let newName = String(localized: "MasterView.NewLayoutName")
    private static let copyName = String(localized: "MasterView.CopyName").replacingOccurrences(of: "%@", with: "Section Header")

    private func layout(named name: String, in presentation: Presentation) -> Slide? {
        presentation.slides.first { $0.layoutName == name }
    }

    private func part(_ path: String, in presentation: Presentation) throws -> String {
        String(decoding: try #require(presentation.data(at: path)), as: UTF8.self)
    }

    @Test("Going in shows each master followed by its layouts, opening on the slide's layout")
    func entering() throws {
        var (presentation, state) = try deck()
        let slides = presentation.slides
        state.enterMasterView(in: &presentation)

        #expect(presentation.isInMasterView)
        #expect(presentation.slides.map(\.role) == [.master] + Array(repeating: .layout(masterPath: Self.masterPath), count: 5))
        #expect(presentation.slides.dropFirst().map(\.layoutName) == ["Title Slide", "Title and Content", "Section Header", "Title Only", "Blank"])
        #expect(presentation.masterView?.slides == slides)
        #expect(state.selectedSlide(in: presentation)?.partName == Self.contentLayout)
        // Each is drawn with its own placeholders, over what it is built on.
        let content = try #require(layout(named: "Title and Content", in: presentation))
        #expect(content.shapes.count == 2)
        #expect(presentation.layout(for: content)?.shapes.isEmpty == true)
        #expect(presentation.master(for: content)?.shapes.isEmpty == false)
        let master = try #require(presentation.slides.first)
        #expect(presentation.master(for: master)?.shapes.isEmpty == true)
    }

    @Test("Coming out with nothing changed leaves the presentation as it was")
    func leavingUnchanged() throws {
        var (presentation, state) = try deck()
        let before = presentation
        let selected = state.selectedSlideID
        state.enterMasterView(in: &presentation)
        state.leaveMasterView(in: &presentation)
        #expect(presentation == before)
        #expect(state.selectedSlideID == selected)
    }

    @Test("A layout's placeholder moves, and the slides built on it follow")
    func movingPlaceholder() throws {
        var (presentation, state) = try deck()
        let slideID = try #require(state.selectedSlideID)
        state.enterMasterView(in: &presentation)
        let title = try #require(state.selectedSlide(in: presentation)?.shapes.first { $0.placeholder?.isTitle == true })
        let frame = CGRect(x: 60, y: 300, width: 500, height: 80)
        state.setFrame(frame, of: title.id, in: &presentation)
        state.leaveMasterView(in: &presentation)

        #expect(!presentation.isInMasterView)
        #expect(state.selectedSlideID == slideID)
        let slide = try #require(presentation.slides.last)
        let followed = try #require(slide.shapes.first { $0.placeholder?.isTitle == true })
        #expect(!followed.hasOwnFrame)
        #expect(followed.frame == EMURect(points: frame))
        // The first slide's layout was left alone, and so is its title.
        #expect(presentation.slides[0].shapes[0].frame == Presentation.blank.slides[0].shapes[0].frame)

        let reopened = try saved(presentation)
        let written = try #require(reopened.resources.layouts[Self.contentLayout]?.shapes.first { $0.placeholder?.isTitle == true })
        #expect(written.hasOwnFrame)
        #expect(written.frame == EMURect(points: frame))
        #expect(reopened.slides.last?.shapes.first { $0.placeholder?.isTitle == true }?.frame == EMURect(points: frame))
    }

    @Test("A master's placeholder moves, and its layouts and their slides follow")
    func movingMasterPlaceholder() throws {
        var (presentation, state) = try deck()
        state.enterMasterView(in: &presentation)
        let master = try #require(presentation.slides.first)
        state.selectSlide(master.id)
        let title = try #require(master.shapes.first { $0.placeholder?.type == "title" })
        let frame = CGRect(x: 40, y: 20, width: 700, height: 90)
        let resources = presentation.resources
        state.setFrame(frame, of: title.id, in: &presentation)

        // Layouts that take the title's place from the master follow at once.
        let content = try #require(layout(named: "Title and Content", in: presentation))
        #expect(content.shapes.first { $0.placeholder?.isTitle == true }?.frame == EMURect(points: frame))
        // One that places its own title stays where it is.
        let section = try #require(layout(named: "Section Header", in: presentation))
        #expect(section.shapes.first { $0.placeholder?.isTitle == true }?.frame != EMURect(points: frame))
        // Whatever draws from the masters is told to draw again.
        #expect(presentation.resources != resources)

        state.leaveMasterView(in: &presentation)
        #expect(presentation.slides.last?.shapes.first { $0.placeholder?.isTitle == true }?.frame == EMURect(points: frame))
        #expect(try saved(presentation).slides.last?.shapes.first { $0.placeholder?.isTitle == true }?.frame == EMURect(points: frame))
    }

    @Test("Formatting a placeholder's text sets the style slides take from it")
    func formattingPlaceholder() throws {
        var (presentation, state) = try deck()
        state.enterMasterView(in: &presentation)
        let title = try #require(state.selectedSlide(in: presentation)?.shapes.first { $0.placeholder?.isTitle == true })
        state.selectedShapeID = title.id
        state.toggleBold(in: &presentation)
        state.setTextColor(.rgb(0xC00000), in: &presentation)
        state.setAlignment(.center, in: &presentation)
        state.leaveMasterView(in: &presentation)

        let xml = try part(Self.contentLayout, in: presentation)
        #expect(xml.contains("<a:lvl1pPr algn=\"ctr\"><a:defRPr b=\"1\"><a:solidFill><a:srgbClr val=\"C00000\"/></a:solidFill></a:defRPr></a:lvl1pPr>"))

        for presentation in [presentation, try saved(presentation)] {
            state.selectSlide(presentation.slides.last?.id)
            state.selectedShapeID = presentation.slides.last?.shapes.first { $0.placeholder?.isTitle == true }?.id
            let run = state.effectiveRunProperties(in: presentation)
            #expect(run.isBold == true)
            #expect(run.color == .rgb(0xC00000))
            #expect(state.effectiveAlignment(in: presentation) == .center)
        }
        // A slide on another layout keeps the master's style.
        state.selectSlide(presentation.slides.first?.id)
        state.selectedShapeID = presentation.slides.first?.shapes.first?.id
        #expect(state.effectiveRunProperties(in: presentation).isBold != true)
    }

    @Test("A master's background changes, and layouts and slides without their own take it")
    func changingBackground() throws {
        var (presentation, state) = try deck()
        state.enterMasterView(in: &presentation)
        let master = try #require(presentation.slides.first)
        state.selectSlide(master.id)
        state.setBackground(.solid(.rgb(0x203864)), in: &presentation)

        let content = try #require(layout(named: "Title and Content", in: presentation))
        #expect(SlideStyleContext(presentation: presentation, slide: content).background(of: content).fill == .solid(.rgb(0x203864)))

        state.leaveMasterView(in: &presentation)
        for presentation in [presentation, try saved(presentation)] {
            let slide = try #require(presentation.slides.last)
            #expect(slide.background == nil)
            #expect(SlideStyleContext(presentation: presentation, slide: slide).background(of: slide).fill == .solid(.rgb(0x203864)))
        }
    }

    @Test("Layouts are added, copied, renamed and deleted, and saved that way")
    func changingLayouts() throws {
        var (presentation, state) = try deck()
        state.enterMasterView(in: &presentation)

        // A new layout goes after the one being edited, with the master's title.
        state.addLayout(in: &presentation)
        let added = try #require(state.selectedSlide(in: presentation))
        #expect(presentation.slides.map(\.layoutName)[1...3] == ["Title Slide", "Title and Content", Self.newName])
        #expect(added.shapes.first?.placeholder?.type == "title")
        state.renameLayout(added.id, to: "  Quote  ", in: &presentation)
        #expect(state.selectedSlide(in: presentation)?.layoutName == "Quote")

        let section = try #require(layout(named: "Section Header", in: presentation))
        state.duplicateSlide(section.id, in: &presentation)
        let copy = try #require(state.selectedSlide(in: presentation))
        #expect(copy.layoutName == Self.copyName)
        #expect(copy.shapes.map(\.frame) == section.shapes.map(\.frame))

        // A layout slides are built on stays; one none is built on can go.
        let content = try #require(layout(named: "Title and Content", in: presentation))
        #expect(!state.canDeleteLayout(content.id, in: presentation))
        state.deleteSlide(content.id, in: &presentation)
        #expect(layout(named: "Title and Content", in: presentation) != nil)
        let blank = try #require(layout(named: "Blank", in: presentation))
        #expect(state.canDeleteLayout(blank.id, in: presentation))
        state.deleteSlide(blank.id, in: &presentation)
        // The master itself is neither copied nor deleted.
        let master = try #require(presentation.slides.first)
        state.duplicateSlide(master.id, in: &presentation)
        state.deleteSlide(master.id, in: &presentation)
        #expect(presentation.slides.filter { $0.role == .master }.count == 1)

        state.leaveMasterView(in: &presentation)
        let names = ["Title Slide", "Title and Content", "Quote", "Section Header", Self.copyName, "Title Only"]
        #expect(presentation.resources.orderedLayouts.map(\.name) == names)
        #expect(presentation.data(at: "ppt/slideLayouts/slideLayout5.xml") == nil)

        let data = try PPTXWriter.data(from: presentation)
        let reopened = try PPTXReader.presentation(from: data)
        #expect(reopened.resources.orderedLayouts.map(\.name) == names)
        #expect(reopened.slides.map { reopened.layout(for: $0)?.name } == ["Title Slide", "Title and Content"])
        let parts = try ZipArchive.entries(in: data)
        #expect(parts["ppt/slideLayouts/slideLayout5.xml"] == nil)
        #expect(parts["ppt/slideLayouts/_rels/slideLayout5.xml.rels"] == nil)

        // The master lists each layout once, under an id no master or layout shares.
        let master1 = try XMLLite.parse(try #require(parts[Self.masterPath]))
        let entries = try #require(master1.firstChild(named: "sldLayoutIdLst")?.children(named: "sldLayoutId"))
        let ids = entries.compactMap { $0.qualifiedAttributes["id"].flatMap(Int.init) }
        #expect(ids.count == names.count)
        #expect(Set(ids).count == ids.count)
        // Layouts that were there keep the ids they had.
        #expect(ids.prefix(2) == [2_147_483_649, 2_147_483_650])
        #expect(ids.allSatisfy { $0 >= 2_147_483_648 })
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: Self.masterPath)])
        let listed = entries.compactMap { entry in relationships.first { $0.id == entry.relationshipID }?.target }
        #expect(listed.count == names.count)
        #expect(listed.allSatisfy { parts[PackagePath.resolve($0, from: Self.masterPath)] != nil })
        // Each new layout is declared as one, and points back at its master.
        let types = String(decoding: try #require(parts["[Content_Types].xml"]), as: UTF8.self)
        let new = try #require(reopened.resources.orderedLayouts.first { $0.name == "Quote" })
        #expect(types.contains("PartName=\"/\(new.path)\" ContentType=\"\(OOXML.ContentType.slideLayout)\""))
        #expect(!types.contains("slideLayout5.xml"))
        #expect(Relationship.parse(parts[PackagePath.relationships(of: new.path)])
            .contains { $0.type == OOXML.RelationshipType.slideMaster && PackagePath.resolve($0.target, from: new.path) == Self.masterPath })

        // A slide can be made on the new layout.
        var again = reopened
        let other = EditorState()
        other.reconcile(with: again)
        other.addSlide(using: new, in: &again)
        #expect(again.slides.count == 3)
        let third = try saved(again)
        #expect(third.slides.map { third.layout(for: $0)?.name } == ["Title Slide", "Quote", "Title and Content"])
    }

    @Test("What is only a slide's is left alone in master view, and a save from it keeps the slides")
    func slidesSetAside() throws {
        var (presentation, state) = try deck()
        state.enterMasterView(in: &presentation)
        let before = presentation
        let layout = try #require(presentation.masterView?.resources.orderedLayouts.first)
        state.addSlide(using: layout, in: &presentation)
        state.moveSlide(presentation.slides[1].id, to: 3, in: &presentation)
        state.toggleHidden(presentation.slides[1].id, in: &presentation)
        state.cutSlide(presentation.slides[1].id, in: &presentation)
        #expect(presentation == before)

        state.renameLayout(presentation.slides[1].id, to: "Opening", in: &presentation)
        let reopened = try saved(presentation)
        #expect(reopened.slides.count == 2)
        #expect(reopened.resources.orderedLayouts.first?.name == "Opening")
        #expect(presentation.outOfMasterView.slides.map(\.id) == before.masterView?.slides.map(\.id))
    }
}
