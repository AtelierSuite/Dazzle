import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Character spacing")
struct CharacterSpacingTests {
    private func shape(_ runAttributes: String, listStyle: String = "") throws -> SlideShape {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="2540000" cy="1270000"/></a:xfrm>
            <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
            <p:txBody><a:bodyPr wrap="none"/><a:lstStyle>\(listStyle)</a:lstStyle>\
            <a:p><a:r><a:rPr lang="en-US" sz="2400" \(runAttributes)/><a:t>Character spacing</a:t></a:r></a:p></p:txBody></p:sp>
            </p:spTree>
            """.utf8))
        let shapes = ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                                 parts: [:], capturesSource: true).shapes(in: root)
        return try #require(shapes.first)
    }

    private func width(of shape: SlideShape) throws -> CGFloat {
        let presentation = Presentation.blank
        let renderer = TextRenderer(style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]), slideNumber: 1)
        return renderer.unwrappedWidth(of: try #require(shape.text), shape: shape)
    }

    @Test("Spacing is read from runs and inherited from list styles")
    func read() throws {
        #expect(try shape("spc=\"300\"").text?.paragraphs.first?.runs.first?.properties.spacing == 300)
        #expect(try shape("").text?.paragraphs.first?.runs.first?.properties.spacing == nil)

        var base = RunProperties()
        base.spacing = -150
        var run = RunProperties()
        #expect(run.merged(over: base).spacing == -150)
        run.spacing = 0
        #expect(run.merged(over: base).spacing == 0)
    }

    @Test("Expanded text lays out wider and condensed text narrower")
    func drawn() throws {
        let plain = try width(of: shape(""))
        let expanded = try width(of: shape("spc=\"300\""))
        let condensed = try width(of: shape("spc=\"-150\""))
        // Seventeen letters, three points apart (the last letter's spacing may trail).
        #expect(expanded - plain > 3 * 15)
        #expect(plain - condensed > 1.5 * 15)
        // Spacing from the shape's list style reaches runs that say nothing.
        let inherited = try width(of: shape("", listStyle: "<a:lvl1pPr><a:defRPr spc=\"300\"/></a:lvl1pPr>"))
        #expect(abs(inherited - expanded) < 1)
    }

    @Test("Spacing is written and read back, and taken away when set to none")
    func roundTrip() throws {
        func reread(_ shape: SlideShape) throws -> RunProperties? {
            var presentation = Presentation.blank
            presentation.slides[0].shapes = [shape]
            presentation.slides[0].isModified = true
            let read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
            return read.slides[0].shapes.first?.text?.paragraphs.first?.runs.first?.properties
        }
        // Runs made in Dazzle, with no XML of their own.
        var made = try shape("")
        made.source = nil
        made.text?.paragraphs[0].runs[0].sourceProperties = nil
        made.text?.paragraphs[0].runs[0].properties.spacing = -200
        #expect(try reread(made)?.spacing == -200)

        // Runs read from a file, with the spacing changed.
        var edited = try shape("spc=\"300\"")
        edited.edits.insert(.text)
        edited.text?.paragraphs[0].runs[0].properties.spacing = 0
        #expect(try reread(edited)?.spacing == nil)
        edited.text?.paragraphs[0].runs[0].properties.spacing = 450
        #expect(try reread(edited)?.spacing == 450)
    }
}
