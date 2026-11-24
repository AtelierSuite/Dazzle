@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Copied slides' animations")
@MainActor
struct CopiedAnimationTests {
    private static let audioPath = "ppt/media/chime1.wav"
    private static let audio = Data("RIFF-chime".utf8)

    /// A click brings the title in with a barn door and a chime, then the
    /// body's second paragraph turns transparent; clicking the title
    /// spins the body. None of these is an effect Dazzle makes.
    private static func timing(title: Int, body: Int) -> String {
        """
        <p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>\
        <p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>\
        <p:par><p:cTn id="3" fill="hold"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="4" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="5" presetID="16" presetClass="entr" presetSubtype="21" fill="hold" grpId="0" nodeType="clickEffect">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:set><p:cBhvr><p:cTn id="6" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\
        <p:tgtEl><p:spTgt spid="\(title)"/></p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr>\
        <p:to><p:strVal val="visible"/></p:to></p:set>\
        <p:animEffect transition="in" filter="barn(inVertical)"><p:cBhvr><p:cTn id="7" dur="500"/>\
        <p:tgtEl><p:spTgt spid="\(title)"/></p:tgtEl></p:cBhvr></p:animEffect></p:childTnLst>\
        <p:subTnLst><p:audio><p:cMediaNode vol="80000"><p:cTn id="8" fill="hold" display="0">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:endCondLst><p:cond evt="onNext" delay="0">\
        <p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:endCondLst></p:cTn>\
        <p:tgtEl><p:sndTgt r:embed="rId9" name="chime.wav"/></p:tgtEl></p:cMediaNode></p:audio></p:subTnLst>\
        </p:cTn></p:par></p:childTnLst></p:cTn></p:par>\
        <p:par><p:cTn id="9" fill="hold"><p:stCondLst><p:cond delay="500"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="10" presetID="9" presetClass="emph" presetSubtype="0" fill="hold" grpId="1" nodeType="afterEffect">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:set><p:cBhvr><p:cTn id="11" dur="500" fill="hold"/>\
        <p:tgtEl><p:spTgt spid="\(body)"><p:txEl><p:pRg st="1" end="1"/></p:txEl></p:spTgt></p:tgtEl>\
        <p:attrNameLst><p:attrName>style.opacity</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val="0.5"/></p:to></p:set>\
        </p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>\
        </p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn>\
        <p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>\
        <p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq>\
        <p:seq concurrent="1" nextAc="seek"><p:cTn id="12" restart="whenNotActive" fill="hold" evtFilter="cancelBubble" nodeType="interactiveSeq">\
        <p:stCondLst><p:cond evt="onClick" delay="0"><p:tgtEl><p:spTgt spid="\(title)"/></p:tgtEl></p:cond></p:stCondLst>\
        <p:endSync evt="end" delay="0"><p:rtn val="all"/></p:endSync><p:childTnLst>\
        <p:par><p:cTn id="13" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="14" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="15" presetID="8" presetClass="emph" presetSubtype="0" fill="hold" grpId="2" nodeType="clickEffect">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:animRot by="21600000"><p:cBhvr><p:cTn id="16" dur="2000" fill="hold"/><p:tgtEl><p:spTgt spid="\(body)"/></p:tgtEl>\
        <p:attrNameLst><p:attrName>r</p:attrName></p:attrNameLst></p:cBhvr></p:animRot>\
        </p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>\
        </p:childTnLst></p:cTn><p:nextCondLst><p:cond evt="onClick" delay="0"><p:tgtEl><p:spTgt spid="\(title)"/></p:tgtEl>\
        </p:cond></p:nextCondLst></p:seq>\
        </p:childTnLst></p:cTn></p:par></p:tnLst>\
        <p:bldLst><p:bldP spid="\(title)" grpId="0" animBg="1"/><p:bldP spid="\(body)" grpId="1" build="p"/></p:bldLst></p:timing>
        """
    }

    @Test("A duplicated slide keeps every effect read from the file, its sound and its trigger")
    func duplicating() throws {
        var deck = try deck()
        let original = deck.slides[0]
        let state = EditorState()
        state.selectSlide(original.id)
        state.duplicateSlide(original.id, in: &deck)

        let data = try PPTXWriter.data(from: deck)
        let saved = try PPTXReader.presentation(from: data)
        #expect(saved.slides.count == 2)
        try expectAnimations(of: saved.slides[1], in: saved, data: data, like: original, keepsTrigger: true)
    }

    @Test("A slide pasted into its own presentation keeps every effect, also once its effects change")
    func pastingWithin() throws {
        let source = try deck()
        let original = source.slides[0]
        var same = source
        let state = EditorState()
        state.selectSlide(original.id)
        state.pasteSlides([original], from: source, into: &same)
        let copy = try #require(same.slides.last)
        state.selectSlide(copy.id)
        let index = try #require(same.index(of: copy.id))
        same.slides[index].animations[1].delay = 0.25
        same.slides[index].areAnimationsModified = true
        same.slides[index].isModified = true

        let data = try PPTXWriter.data(from: same)
        let saved = try PPTXReader.presentation(from: data)
        #expect(saved.slides.count == 2)
        try expectAnimations(of: saved.slides[1], in: saved, data: data, like: original, keepsTrigger: true)
        #expect(abs((saved.slides[1].animations.last?.delay ?? 0) - 0.25) < 0.001)
    }

    @Test("A slide pasted into another presentation keeps its effects and brings their sound")
    func pastingAcross() throws {
        let source = try deck()
        let original = source.slides[0]
        var other = try PPTXReader.presentation(from: PPTXWriter.data(from: .blank))
        let state = EditorState()
        state.selectSlide(other.slides[0].id)
        state.pasteSlides([original], from: source, into: &other)

        let data = try PPTXWriter.data(from: other)
        let saved = try PPTXReader.presentation(from: data)
        #expect(saved.slides.count == 2)
        try expectAnimations(of: saved.slides[1], in: saved, data: data, like: original, keepsTrigger: false)
    }

    @Test("An effect whose sound can't come across is left out, with no relationship for it")
    func missingSound() throws {
        let source = try deck(includesAudio: false)
        let original = source.slides[0]
        var other = try PPTXReader.presentation(from: PPTXWriter.data(from: .blank))
        let state = EditorState()
        state.selectSlide(other.slides[0].id)
        state.pasteSlides([original], from: source, into: &other)

        let data = try PPTXWriter.data(from: other)
        let saved = try PPTXReader.presentation(from: data)
        let slide = try #require(saved.slides.last)
        #expect(slide.animations.map(\.effect) == [original.animations[1].effect])
        #expect(slide.animations.first?.paragraphs == 1...1)
        #expect(!slide.relationships.contains { $0.type == OOXML.RelationshipType.audio })
        try expectUniqueNodeIDs(in: slideXML(of: slide, data: data))
    }

    // MARK: - Helpers

    private func expectAnimations(of copy: Slide, in presentation: Presentation, data: Data, like original: Slide, keepsTrigger: Bool) throws {
        try #require(copy.animations.count == 2)
        #expect(copy.animations.map(\.effect) == original.animations.map(\.effect))
        #expect(copy.animations.map(\.category) == [.entrance, .emphasis])
        #expect(copy.animations.allSatisfy { !$0.effect.isMadeByDazzle })
        #expect(copy.animations.map(\.shapeID) == original.animations.map(\.shapeID))
        let shapeIDs = Set(copy.shapes.map(\.shapeID))
        #expect(copy.animations.allSatisfy { shapeIDs.contains($0.shapeID) })
        #expect(copy.animations[1].paragraphs == 1...1)

        let xml = try slideXML(of: copy, data: data)
        try expectUniqueNodeIDs(in: xml)
        let embed = try #require(xml.firstMatch(of: #/<p:sndTgt [^>]*r:embed="([^"]+)"/#)?.1)
        let relationship = try #require(copy.relationships.first { $0.id == String(embed) })
        #expect(relationship.type == OOXML.RelationshipType.audio)
        let part = try #require(copy.partName)
        #expect(presentation.data(at: PackagePath.resolve(relationship.target, from: part)) == Self.audio)
        if keepsTrigger {
            #expect(xml.contains("nodeType=\"interactiveSeq\""))
            let title = try #require(copy.shapes.first?.shapeID)
            let triggers = xml.matches(of: #/<p:cond [^>]*evt="onClick"[^>]*><p:tgtEl><p:spTgt spid="(\d+)"/#).map { Int($0.1) }
            #expect(!triggers.isEmpty && triggers.allSatisfy { $0 == title })
        }
    }

    private func slideXML(of slide: Slide, data: Data) throws -> String {
        let part = try #require(slide.partName)
        return try #require(ZipArchive.entries(in: data)[part].flatMap { String(data: $0, encoding: .utf8) })
    }

    private func expectUniqueNodeIDs(in xml: String) throws {
        let ids = xml.matches(of: #/<p:cTn [^>]*\bid="(\d+)"/#).map { String($0.1) }
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count, "Repeated cTn ids: \(ids)")
    }

    /// A one-slide deck, its body in two paragraphs, whose timing is as
    /// PowerPoint wrote it, with a chime in `ppt/media`.
    private func deck(includesAudio: Bool = true) throws -> Presentation {
        var blank = Presentation.blank
        blank.slides[0].shapes[0].text?.setPlainText("Title")
        blank.slides[0].shapes[1].text?.setPlainText("One\nTwo")
        blank.slides[0].shapes[0].edits.insert(.text)
        blank.slides[0].shapes[1].edits.insert(.text)
        blank.slides[0].isModified = true
        let title = blank.slides[0].shapes[0].shapeID
        let body = blank.slides[0].shapes[1].shapeID

        var entries = try ZipArchive.entries(in: PPTXWriter.data(from: blank))
        let path = "ppt/slides/slide1.xml"
        var slide = try #require(entries[path].flatMap { String(data: $0, encoding: .utf8) })
        slide.insert(contentsOf: Self.timing(title: title, body: body), at: try #require(slide.range(of: "</p:sld>")).lowerBound)
        if !slide.contains("xmlns:r=") {
            slide = slide.replacingOccurrences(
                of: "<p:sld ", with: "<p:sld xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            )
        }
        entries[path] = Data(slide.utf8)
        let rels = "ppt/slides/_rels/slide1.xml.rels"
        var relationships = Relationship.parse(entries[rels])
        relationships.append(Relationship(id: "rId9", type: OOXML.RelationshipType.audio, target: "../media/chime1.wav"))
        entries[rels] = Relationship.xml(relationships)
        if includesAudio { entries[Self.audioPath] = Self.audio }
        var types = try #require(entries["[Content_Types].xml"].flatMap { String(data: $0, encoding: .utf8) })
        types = types.replacingOccurrences(
            of: "<Default ", with: "<Default Extension=\"wav\" ContentType=\"audio/wav\"/><Default ", options: [],
            range: types.range(of: "<Default ")
        )
        entries["[Content_Types].xml"] = Data(types.utf8)
        let archive = try ZipArchive.archive(entries: entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        let presentation = try PPTXReader.presentation(from: archive)
        #expect(presentation.slides[0].animations.count == 2)
        #expect(presentation.slides[0].shapes[1].text?.paragraphs.count == 2)
        return presentation
    }
}
