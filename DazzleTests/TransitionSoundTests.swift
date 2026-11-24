@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Transition sounds")
@MainActor
struct TransitionSoundTests {
    private static let audioPath = "ppt/media/chime1.wav"
    private static let audio = Data("RIFF-chime".utf8)
    private static let sound = """
        <p:sndAc><p:stSnd loop="1"><p:snd r:embed="rId9" name="chime.wav"/></p:stSnd></p:sndAc>
        """

    private static let slideXML = """
        <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
        xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main">\
        <mc:Choice Requires="p14"><p:transition spd="slow" p14:dur="2000"><p14:vortex dir="r"/>\(sound)</p:transition></mc:Choice>\
        <mc:Fallback><p:transition spd="slow"><p:fade/>\(sound)</p:transition></mc:Fallback></mc:AlternateContent>
        """

    @Test("A transition's sound is read, with its audio part")
    func reading() throws {
        let slide = try deck().slides[0]
        #expect(slide.transitionSound == TransitionSound(relationshipID: "rId9", name: "chime.wav", loops: true))
        #expect(slide.transitionSoundPath == Self.audioPath)
        #expect(slide.transition?.effect == .preset(SlideTransition.Preset(.vortex, direction: .right)))
    }

    @Test("A transition's sound survives changing the slide's timing")
    func changingTiming() throws {
        var presentation = try deck()
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.setAutoAdvance(3, in: &presentation)
        state.setAdvancesOnClick(false, in: &presentation)
        try expectSoundKept(in: PPTXWriter.data(from: presentation), versions: 2)
    }

    @Test("A transition's sound survives changing or removing the effect")
    func changingEffect() throws {
        var presentation = try deck()
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.setTransition(SlideTransition(effect: .push(.up), duration: 1), in: &presentation)
        let saved = try PPTXWriter.data(from: presentation)
        try expectSoundKept(in: saved, versions: 2)
        #expect(try PPTXReader.presentation(from: saved).slides[0].transition?.effect == .push(.up))

        state.setTransition(nil, in: &presentation)
        let none = try PPTXWriter.data(from: presentation)
        try expectSoundKept(in: none, versions: 1)
        #expect(try PPTXReader.presentation(from: none).slides[0].transition == nil)
    }

    @Test("Stopping the sound is kept through a rewrite")
    func stopping() throws {
        var presentation = try deck(sound: "<p:sndAc><p:endSnd/></p:sndAc>")
        #expect(presentation.slides[0].transitionSound == .stop)
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.setTransition(SlideTransition(effect: .wipe(.left)), in: &presentation)
        let reread = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(reread.slides[0].transitionSound == .stop)
    }

    @Test("A copied slide keeps its sound, within a presentation and into another")
    func copying() throws {
        let source = try deck()
        let state = EditorState()
        state.selectSlide(source.slides[0].id)

        var same = source
        state.pasteSlides([source.slides[0]], from: source, into: &same)
        state.selectSlide(same.slides[1].id)
        state.setTransition(SlideTransition(effect: .fade(throughBlack: false)), in: &same)
        let duplicated = try PPTXReader.presentation(from: PPTXWriter.data(from: same))
        #expect(duplicated.slides.count == 2)
        for slide in duplicated.slides {
            #expect(slide.transitionSound?.loops == true)
            #expect(slide.transitionSoundPath.flatMap(duplicated.data(at:)) == Self.audio)
        }

        var other = try PPTXReader.presentation(from: PPTXWriter.data(from: .blank))
        let target = EditorState()
        target.selectSlide(other.slides[0].id)
        target.pasteSlides([source.slides[0]], from: source, into: &other)
        let imported = try PPTXReader.presentation(from: PPTXWriter.data(from: other))
        let slide = try #require(imported.slides.last)
        #expect(slide.transitionSound?.name == "chime.wav")
        let path = try #require(slide.transitionSoundPath)
        #expect(imported.data(at: path) == Self.audio)
    }

    // MARK: - Helpers

    private func expectSoundKept(in data: Data, versions: Int) throws {
        let entries = try ZipArchive.entries(in: data)
        let xml = try #require(entries["ppt/slides/slide1.xml"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(xml.components(separatedBy: "<p:sndAc").count - 1 == versions)
        let reread = try PPTXReader.presentation(from: data)
        let slide = reread.slides[0]
        #expect(slide.transitionSound == TransitionSound(relationshipID: "rId9", name: "chime.wav", loops: true))
        let relationships = Relationship.parse(entries["ppt/slides/_rels/slide1.xml.rels"])
        #expect(relationships.contains { $0.id == "rId9" && $0.type == OOXML.RelationshipType.audio })
        #expect(slide.transitionSoundPath == Self.audioPath)
        #expect(entries[Self.audioPath] == Self.audio)
    }

    /// A one-slide deck whose transition plays a sound in `ppt/media`.
    private func deck(sound: String = sound) throws -> Presentation {
        var entries = try ZipArchive.entries(in: PPTXWriter.data(from: .blank))
        let path = "ppt/slides/slide1.xml"
        var slide = try #require(entries[path].flatMap { String(data: $0, encoding: .utf8) })
        let anchor = slide.range(of: "</p:clrMapOvr>") ?? slide.range(of: "</p:cSld>")
        slide.insert(contentsOf: Self.slideXML.replacingOccurrences(of: Self.sound, with: sound), at: try #require(anchor).upperBound)
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
        entries[Self.audioPath] = Self.audio
        var types = try #require(entries["[Content_Types].xml"].flatMap { String(data: $0, encoding: .utf8) })
        types = types.replacingOccurrences(of: "<Default ", with: "<Default Extension=\"wav\" ContentType=\"audio/wav\"/><Default ", options: [], range: types.range(of: "<Default "))
        entries["[Content_Types].xml"] = Data(types.utf8)
        let archive = try ZipArchive.archive(entries: entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        return try PPTXReader.presentation(from: archive)
    }
}
