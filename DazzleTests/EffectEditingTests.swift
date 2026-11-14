@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Editing glow, soft edges, inner shadow, bevel, depth, text warp and patterns")
@MainActor struct EffectEditingTests {
    /// A blank deck with one rectangle of Dazzle's, selected, holding `text`.
    private func deckWithShape(text: String = "WordArt") -> (Presentation, EditorState) {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertShape("rect", in: &presentation)
        let index = presentation.slides[0].shapes.count - 1
        if presentation.slides[0].shapes[index].text == nil { presentation.slides[0].shapes[index].text = TextBody(paragraphs: []) }
        presentation.slides[0].shapes[index].text?.setPlainText(text)
        state.selectedShapeID = presentation.slides[0].shapes[index].id
        return (presentation, state)
    }

    private func saved(_ presentation: Presentation) throws -> (presentation: Presentation, slide: String) {
        let data = try PPTXWriter.data(from: presentation)
        let entries = try ZipArchive.entries(in: data)
        let slide = try #require(entries["ppt/slides/slide1.xml"].flatMap { String(data: $0, encoding: .utf8) })
        return (try PPTXReader.presentation(fromParts: entries), slide)
    }

    @Test("Glow, soft edges and an inner shadow are written, read back, and taken off again")
    func effects() throws {
        var (presentation, state) = deckWithShape()
        state.setGlow(Glow(radius: EMU.from(points: 8), color: FormatChoices.glowColor(.scheme("accent2"))), in: &presentation)
        state.setGlowColor(.rgb(0x00FF00), in: &presentation)
        state.setSoftEdge(EMU.from(points: 5), in: &presentation)
        state.setInnerShadow(FormatChoices.innerShadows[1].shadow, in: &presentation)

        var (read, xml) = try saved(presentation)
        let shape = try #require(read.slides[0].shapes.last)
        #expect(shape.effects.glow == Glow(radius: 101_600, color: DrawingColor(
            base: .rgb(0x00FF00), transforms: [.init(name: "alpha", value: 40_000)])))
        #expect(shape.effects.softEdge == 63_500)
        #expect(shape.effects.innerShadow == FormatChoices.innerShadows[1].shadow)
        // In the schema's order: glow, inner shadow, then soft edges.
        let glow = try #require(xml.range(of: "<a:glow"))
        let inner = try #require(xml.range(of: "<a:innerShdw"))
        let soft = try #require(xml.range(of: "<a:softEdge"))
        #expect(glow.lowerBound < inner.lowerBound && inner.lowerBound < soft.lowerBound)

        state.setGlow(nil, in: &presentation)
        state.setSoftEdge(nil, in: &presentation)
        state.setInnerShadow(nil, in: &presentation)
        (read, xml) = try saved(presentation)
        #expect(read.slides[0].shapes.last?.effects.isEmpty == true)
        #expect(!xml.contains("<a:glow") && !xml.contains("<a:softEdge") && !xml.contains("<a:innerShdw"))
    }

    @Test("Effects edited on a shape from a file replace only what changed")
    func editingFileEffects() throws {
        let (presentation, state) = deckWithShape()
        var file = try saved(presentation).presentation
        state.reconcile(with: file)
        state.selectSlide(file.slides[0].id)
        state.selectedShapeID = try #require(file.slides[0].shapes.last).id
        state.setGlow(Glow(radius: 63_500, color: .rgb(0xFF0000)), in: &file)
        state.setSoftEdge(12_700, in: &file)
        file = try saved(file).presentation
        state.reconcile(with: file)
        state.selectSlide(file.slides[0].id)
        state.selectedShapeID = try #require(file.slides[0].shapes.last).id
        state.setSoftEdge(25_400, in: &file)
        #expect(file.slides[0].shapes.last?.source?.contains("<a:glow") == true, "Read from the file")
        let (read, xml) = try saved(file)
        #expect(read.slides[0].shapes.last?.effects.glow == Glow(radius: 63_500, color: .rgb(0xFF0000)))
        #expect(read.slides[0].shapes.last?.effects.softEdge == 25_400)
        #expect(xml.components(separatedBy: "<a:softEdge").count == 2, "Written once")
    }

    @Test("A bevel, depth and camera are written as scene3d and sp3d, and go when taken off")
    func threeD() throws {
        var (presentation, state) = deckWithShape()
        state.setBevel(Shape3D.Bevel(preset: "artDeco"), in: &presentation)
        state.setDepth(EMU.from(points: 18), in: &presentation)
        state.setCamera("obliqueTopLeft", in: &presentation)
        var (read, xml) = try saved(presentation)
        let shape = try #require(read.slides[0].shapes.last)
        #expect(shape.shape3D?.topBevel == Shape3D.Bevel(width: 76_200, height: 76_200, preset: "artDeco"))
        #expect(shape.shape3D?.extrusionHeight == 228_600)
        #expect(shape.scene3D?.camera == "obliqueTopLeft")
        let scene = try #require(xml.range(of: "<a:scene3d>"))
        let body = try #require(xml.range(of: "<a:sp3d"))
        #expect(scene.lowerBound < body.lowerBound)

        state.setBevel(nil, in: &presentation)
        state.setDepth(0, in: &presentation)
        state.setCamera("orthographicFront", in: &presentation)
        #expect(presentation.slides[0].shapes.last?.shape3D == nil)
        (read, xml) = try saved(presentation)
        #expect(read.slides[0].shapes.last?.shape3D == nil)
        #expect(!xml.contains("<a:sp3d") && !xml.contains("<a:scene3d"))
    }

    @Test("A text warp is written, changed and taken off")
    func textWarp() throws {
        var (presentation, state) = deckWithShape()
        state.setTextWarp(TextWarp(preset: "textArchUp"), in: &presentation)
        var (read, xml) = try saved(presentation)
        #expect(read.slides[0].shapes.last?.text?.properties.warp?.preset == "textArchUp")

        read.slides[0].isModified = true
        state.reconcile(with: read)
        state.selectSlide(read.slides[0].id)
        state.selectedShapeID = try #require(read.slides[0].shapes.last).id
        state.setTextWarp(TextWarp(preset: "textWave1"), in: &read)
        (presentation, xml) = try saved(read)
        #expect(presentation.slides[0].shapes.last?.text?.properties.warp?.preset == "textWave1")
        #expect(xml.components(separatedBy: "<a:prstTxWarp").count == 2, "Written once")

        state.setTextWarp(nil, in: &read)
        (presentation, xml) = try saved(read)
        #expect(presentation.slides[0].shapes.last?.text?.properties.warp == nil)
        #expect(!xml.contains("prstTxWarp"))
    }

    @Test("Pattern choices name every pattern PowerPoint offers")
    func patternChoices() {
        let patterns = FormatChoices.patterns
        #expect(patterns.count == 48)
        #expect(patterns.first?.0 == "pct5" && patterns.first?.1 == "5%")
        #expect(patterns.allSatisfy { $0.0 != $0.1 }, "Each has a name of its own")
        #expect(Set(FormatChoices.textWarps.map(\.0)).isSubset(of: Set(PresetShapeDefinition.encodedTextWarps.keys)))
    }
}
