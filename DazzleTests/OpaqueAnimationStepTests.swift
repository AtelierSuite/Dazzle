@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Animation steps Dazzle doesn't model")
@MainActor
struct OpaqueAnimationStepTests {
    private static let inkID = 40

    private static func effect(_ id: Int, shape: Int, nodeType: String) -> String {
        """
        <p:par><p:cTn id="\(id)" presetID="10" presetClass="entr" presetSubtype="0" fill="hold" nodeType="\(nodeType)">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:set><p:cBhvr><p:cTn id="\(id + 1)" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\
        <p:tgtEl><p:spTgt spid="\(shape)"/></p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr>\
        <p:to><p:strVal val="visible"/></p:to></p:set>\
        <p:animEffect transition="in" filter="fade"><p:cBhvr><p:cTn id="\(id + 2)" dur="500"/>\
        <p:tgtEl><p:spTgt spid="\(shape)"/></p:tgtEl></p:cBhvr></p:animEffect></p:childTnLst></p:cTn></p:par>
        """
    }

    private static func ink(_ id: Int, nodeType: String) -> String {
        """
        <p:par><p:cTn id="\(id)" presetID="37" presetClass="entr" presetSubtype="0" fill="hold" nodeType="\(nodeType)">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:animEffect transition="in" filter="wipe(right)"><p:cBhvr><p:cTn id="\(id + 1)" dur="1200"/>\
        <p:tgtEl><p:inkTgt spid="\(inkID)"/></p:tgtEl></p:cBhvr></p:animEffect></p:childTnLst></p:cTn></p:par>
        """
    }

    private static func sound(_ id: Int, nodeType: String) -> String {
        """
        <p:par><p:cTn id="\(id)" presetID="1" presetClass="mediacall" presetSubtype="0" fill="hold" nodeType="\(nodeType)">\
        <p:stCondLst><p:cond delay="250"/></p:stCondLst><p:childTnLst>\
        <p:audio><p:cMediaNode vol="80000"><p:cTn id="\(id + 1)" fill="hold" display="0">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\
        <p:tgtEl><p:sndTgt r:embed="rId9" name="chime.wav"/></p:tgtEl></p:cMediaNode></p:audio>\
        </p:childTnLst></p:cTn></p:par>
        """
    }

    private static func group(_ id: Int, runs: [(delay: Int, effects: String)]) -> String {
        var xml = "<p:par><p:cTn id=\"\(id)\" fill=\"hold\"><p:stCondLst><p:cond delay=\"indefinite\"/></p:stCondLst><p:childTnLst>"
        for (index, run) in runs.enumerated() {
            xml += "<p:par><p:cTn id=\"\(id + 1 + index)\" fill=\"hold\"><p:stCondLst><p:cond delay=\"\(run.delay)\"/></p:stCondLst>"
            xml += "<p:childTnLst>\(run.effects)</p:childTnLst></p:cTn></p:par>"
        }
        return xml + "</p:childTnLst></p:cTn></p:par>"
    }

    /// A click fades in A; the next plays the ink back, then fades in B;
    /// the last fades in C with a chime. Clicking A fades in B and plays
    /// the ink back again.
    private static func timing(a: Int, b: Int, c: Int) -> String {
        let main = group(3, runs: [(0, effect(10, shape: a, nodeType: "clickEffect"))])
            + group(4, runs: [(0, ink(20, nodeType: "clickEffect")), (1200, effect(30, shape: b, nodeType: "afterEffect"))])
            + group(6, runs: [(0, effect(40, shape: c, nodeType: "clickEffect") + sound(50, nodeType: "withEffect"))])
        let interactive = group(61, runs: [(0, effect(70, shape: b, nodeType: "clickEffect") + ink(80, nodeType: "withEffect"))])
        return """
            <p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>\
            <p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>\(main)\
            </p:childTnLst></p:cTn>\
            <p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>\
            <p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq>\
            <p:seq concurrent="1" nextAc="seek"><p:cTn id="60" restart="whenNotActive" fill="hold" evtFilter="cancelBubble" \
            nodeType="interactiveSeq"><p:stCondLst><p:cond evt="onClick" delay="0"><p:tgtEl><p:spTgt spid="\(a)"/></p:tgtEl>\
            </p:cond></p:stCondLst><p:endSync evt="end" delay="0"><p:rtn val="all"/></p:endSync><p:childTnLst>\(interactive)\
            </p:childTnLst></p:cTn><p:nextCondLst><p:cond evt="onClick" delay="0"><p:tgtEl><p:spTgt spid="\(a)"/></p:tgtEl>\
            </p:cond></p:nextCondLst></p:seq>\
            </p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>
            """
    }

    private static let inkShape = """
        <p:contentPart xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" p14:bwMode="auto" r:id="rId8">\
        <p14:nvContentPartPr><p14:cNvPr id="\(inkID)" name="Ink 39"/><p14:cNvContentPartPr/><p14:nvPr/></p14:nvContentPartPr>\
        <p14:xfrm><a:off x="1000000" y="1000000"/><a:ext cx="2000000" cy="500000"/></p14:xfrm></p:contentPart>
        """

    @Test("Ink and sound steps stay in place through a retimed effect, a reorder and a deleted shape")
    func keptThroughEdits() throws {
        var deck = try deck()
        let (a, b, c) = (deck.slides[0].shapes[0], deck.slides[0].shapes[1], deck.slides[0].shapes[2])
        #expect(deck.slides[0].animations.map(\.shapeID) == [a.shapeID, b.shapeID, c.shapeID])
        #expect(deck.slides[0].opaqueAnimationSteps.count == 2)
        let state = EditorState()
        state.reconcile(with: deck)
        state.selectSlide(deck.slides[0].id)

        state.updateAnimation(deck.slides[0].animations[0].id, in: &deck) { $0.duration = 1 }
        deck = try saved(deck)
        #expect(try steps(of: deck) == [[.shape(a.shapeID)], [.ink, .shape(b.shapeID)], [.shape(c.shapeID), .sound]])
        #expect(try interactiveSteps(of: deck) == [[.shape(b.shapeID), .ink]])
        #expect(deck.slides[0].animations.map(\.shapeID) == [a.shapeID, b.shapeID, c.shapeID])
        #expect(abs(deck.slides[0].animations[0].duration - 1) < 0.001)

        state.reconcile(with: deck)
        state.selectSlide(deck.slides[0].id)
        state.moveAnimations(from: IndexSet(integer: 2), to: 0, in: &deck)
        deck = try saved(deck)
        #expect(try steps(of: deck) == [[.shape(c.shapeID), .sound], [.shape(a.shapeID)], [.ink, .shape(b.shapeID)]])
        #expect(deck.slides[0].animations.map(\.shapeID) == [c.shapeID, a.shapeID, b.shapeID])

        state.reconcile(with: deck)
        state.selectSlide(deck.slides[0].id)
        state.selectedShapeIDs = [try #require(deck.slides[0].shapes.first { $0.shapeID == b.shapeID }).id]
        state.deleteSelectedShape(in: &deck)
        deck = try saved(deck)
        #expect(try steps(of: deck) == [[.shape(c.shapeID), .sound], [.shape(a.shapeID)], [.ink]])
        #expect(try interactiveSteps(of: deck) == [[.ink]])
        #expect(deck.slides[0].animations.map(\.shapeID) == [c.shapeID, a.shapeID])
        #expect(deck.slides[0].opaqueAnimationSteps.count == 2)
    }

    @Test("Adding an effect keeps the steps, and deleting the ink drawing takes its replay")
    func addingAndDeletingInk() throws {
        var deck = try deck()
        let (a, b, c) = (deck.slides[0].shapes[0], deck.slides[0].shapes[1], deck.slides[0].shapes[2])
        let state = EditorState()
        state.reconcile(with: deck)
        state.selectSlide(deck.slides[0].id)
        state.selectedShapeIDs = [a.id]
        _ = state.addAnimation(.spin, category: .emphasis, in: &deck)
        deck = try saved(deck)
        #expect(try steps(of: deck) == [
            [.shape(a.shapeID)], [.ink, .shape(b.shapeID)], [.shape(c.shapeID), .sound], [.shape(a.shapeID)],
        ])

        state.reconcile(with: deck)
        state.selectSlide(deck.slides[0].id)
        let ink = try #require(deck.slides[0].shapes.first { $0.shapeID == 0 })
        state.selectedShapeIDs = [ink.id]
        state.deleteSelectedShape(in: &deck)
        deck = try saved(deck)
        // B came after the replay, so now comes after A.
        #expect(try steps(of: deck) == [[.shape(a.shapeID), .shape(b.shapeID)], [.shape(c.shapeID), .sound], [.shape(a.shapeID)]])
        #expect(try interactiveSteps(of: deck) == [[.shape(b.shapeID)]])
    }

    // MARK: - Helpers

    private enum Step: Equatable {
        case shape(Int)
        case ink
        case sound
    }

    private func saved(_ deck: Presentation) throws -> Presentation {
        let data = try PPTXWriter.data(from: deck)
        let xml = try slideXML(data)
        let ids = xml.matches(of: #/<p:cTn [^>]*\bid="(\d+)"/#).map { String($0.1) }
        #expect(Set(ids).count == ids.count, "Repeated cTn ids: \(ids)")
        let read = try PPTXReader.presentation(from: data)
        try #require(read.slides.count == 1)
        return read
    }

    private func slideXML(_ data: Data) throws -> String {
        try #require(ZipArchive.entries(in: data)["ppt/slides/slide1.xml"].flatMap { String(data: $0, encoding: .utf8) })
    }

    private func timing(of deck: Presentation) throws -> XMLElement {
        let root = try XMLLite.parse(Data(slideXML(PPTXWriter.data(from: deck)).utf8))
        return try #require(root.firstChild(named: "timing"))
    }

    private func steps(of deck: Presentation) throws -> [[Step]] {
        try steps(in: #require(sequence(in: timing(of: deck), nodeType: "mainSeq")))
    }

    private func interactiveSteps(of deck: Presentation) throws -> [[Step]] {
        try steps(in: #require(sequence(in: timing(of: deck), nodeType: "interactiveSeq")))
    }

    private func sequence(in timing: XMLElement, nodeType: String) -> XMLElement? {
        timing.firstDescendant(atPath: "tnLst/par/cTn/childTnLst")?.children(named: "seq")
            .first { $0.firstChild(named: "cTn")?.attribute("nodeType") == nodeType }
    }

    private func steps(in sequence: XMLElement) -> [[Step]] {
        let groups = sequence.firstDescendant(atPath: "cTn/childTnLst")?.children(named: "par") ?? []
        return groups.map { group in
            (group.firstDescendant(atPath: "cTn/childTnLst")?.children(named: "par") ?? []).flatMap { run in
                (run.firstDescendant(atPath: "cTn/childTnLst")?.children(named: "par") ?? []).map { effect in
                    if let shape = first("spTgt", in: effect)?.attribute("spid").flatMap(Int.init) { return .shape(shape) }
                    return first("inkTgt", in: effect) != nil ? .ink : .sound
                }
            }
        }
    }

    private func first(_ name: String, in element: XMLElement) -> XMLElement? {
        for child in element.children {
            if child.name == name { return child }
            if let found = first(name, in: child) { return found }
        }
        return nil
    }

    /// A one-slide deck with shapes A, B and C, an ink drawing, and the timing above.
    private func deck() throws -> Presentation {
        var blank = Presentation.blank
        var third = SlideShape(copying: blank.slides[0].shapes[1])
        third.shapeID = blank.slides[0].nextShapeID
        third.frame.y += 182_880
        third.hasOwnFrame = true
        third.edits.formUnion([.transform, .identity])
        blank.slides[0].shapes.append(third)
        for index in blank.slides[0].shapes.indices {
            blank.slides[0].shapes[index].text?.setPlainText("Shape \(index)")
            blank.slides[0].shapes[index].edits.insert(.text)
        }
        blank.slides[0].isModified = true
        let ids = blank.slides[0].shapes.map(\.shapeID)

        var entries = try ZipArchive.entries(in: PPTXWriter.data(from: blank))
        let path = "ppt/slides/slide1.xml"
        var slide = try #require(entries[path].flatMap { String(data: $0, encoding: .utf8) })
        slide.insert(contentsOf: Self.inkShape, at: try #require(slide.range(of: "</p:spTree>")).lowerBound)
        slide.insert(contentsOf: Self.timing(a: ids[0], b: ids[1], c: ids[2]), at: try #require(slide.range(of: "</p:sld>")).lowerBound)
        if !slide.contains("xmlns:r=") {
            slide = slide.replacingOccurrences(
                of: "<p:sld ", with: "<p:sld xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            )
        }
        entries[path] = Data(slide.utf8)
        let rels = "ppt/slides/_rels/slide1.xml.rels"
        var relationships = Relationship.parse(entries[rels])
        relationships.append(Relationship(id: "rId8", type: "http://schemas.microsoft.com/office/2011/relationships/ink", target: "../ink/ink1.xml"))
        relationships.append(Relationship(id: "rId9", type: OOXML.RelationshipType.audio, target: "../media/chime1.wav"))
        entries[rels] = Relationship.xml(relationships)
        entries["ppt/ink/ink1.xml"] = Data("<inkml:ink xmlns:inkml=\"http://www.w3.org/2003/InkML\"/>".utf8)
        entries["ppt/media/chime1.wav"] = Data("RIFF-chime".utf8)
        let archive = try ZipArchive.archive(entries: entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        let presentation = try PPTXReader.presentation(from: archive)
        try #require(presentation.slides[0].shapes.count == 4)
        try #require(presentation.slides[0].canEditShapes)
        return presentation
    }
}
