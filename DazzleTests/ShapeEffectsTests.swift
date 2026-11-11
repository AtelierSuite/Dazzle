import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Glow, soft edges, inner and preset shadows, and blur")
struct ShapeEffectsTests {
    /// A 100 × 100 point square at (100, 100), filled `fill`, with `effects`
    /// in its properties and `style` after them.
    private func square(id: Int, fill: String = "FF0000", effects: String = "", style: String = "") -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Square \(id)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="1270000" cy="1270000"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(fill)"/></a:solidFill>\
        \(effects)</p:spPr>\(style)</p:sp>
        """
    }

    /// The built-in template holding one slide of `shapes`, its theme's
    /// second effect style replaced by `effectStyle`, if given.
    private func deck(_ shapes: String, effectStyle: String? = nil) throws -> Presentation {
        let slide = """
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>\
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\
            \(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
        var parts = PresentationTemplate.parts(size: .widescreen, slides: [
            PresentationTemplate.SlidePart(xml: slide, relationships: [
                Relationship(id: "rId1", type: OOXML.RelationshipType.slideLayout, target: "../slideLayouts/slideLayout1.xml"),
            ]),
        ])
        if let effectStyle {
            let empty = "<a:effectStyle><a:effectLst/></a:effectStyle>"
            var theme = try #require(parts["ppt/theme/theme1.xml"].flatMap { String(data: $0, encoding: .utf8) })
            let first = try #require(theme.range(of: empty))
            let second = try #require(theme.range(of: empty, range: first.upperBound..<theme.endIndex))
            theme.replaceSubrange(second, with: effectStyle)
            parts["ppt/theme/theme1.xml"] = Data(theme.utf8)
        }
        return try PPTXReader.presentation(fromParts: parts)
    }

    /// The slide drawn one pixel to the point, as red, green, blue and alpha at each point asked for.
    private func pixels(_ presentation: Presentation, at points: [(Int, Int)]) throws -> [[Int]] {
        let size = presentation.slideSize.points
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0]).draw(in: canvas, size: CGSize(width: width, height: height))
        let data = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        return points.map { x, y in
            let offset = (y * width + x) * 4
            return (0..<4).map { Int(data[offset + $0]) }
        }
    }

    @Test("Each effect reads from a shape's effect list")
    func reading() throws {
        let presentation = try deck(square(id: 2, effects: """
            <a:effectLst><a:blur rad="63500" grow="0"/><a:glow rad="127000"><a:schemeClr val="accent2">\
            <a:alpha val="40000"/></a:schemeClr></a:glow><a:innerShdw blurRad="63500" dist="50800" dir="2700000">\
            <a:prstClr val="black"/></a:innerShdw><a:prstShdw prst="shdw17" dist="38100" dir="13500000">\
            <a:srgbClr val="808080"/></a:prstShdw><a:softEdge rad="31750"/></a:effectLst>
            """))
        let shape = presentation.slides[0].shapes[0]
        #expect(shape.hasOwnEffects)
        #expect(shape.effects.glow == Glow(radius: 127_000, color: DrawingColor(
            base: .scheme("accent2"), transforms: [.init(name: "alpha", value: 40_000)])))
        #expect(shape.effects.softEdge == 31_750)
        #expect(shape.effects.innerShadow?.distance == 50_800)
        #expect(shape.effects.innerShadow?.direction == 45)
        #expect(shape.effects.presetShadow?.preset == 17)
        #expect(shape.effects.presetShadow?.direction == 225)
        #expect(shape.effects.blur == Blur(radius: 63_500, grows: false))
        #expect(shape.effects.presetShadow?.cast.isExtruded == true)
    }

    @Test("A shape without effects of its own takes its theme effect style, in its reference's colour")
    func themeStyles() throws {
        let glow = """
            <a:effectStyle><a:effectLst><a:glow rad="101600"><a:schemeClr val="phClr"><a:alpha val="60000"/>\
            </a:schemeClr></a:glow><a:softEdge rad="12700"/></a:effectLst></a:effectStyle>
            """
        func style(_ index: Int) -> String {
            """
            <p:style><a:lnRef idx="0"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef>\
            <a:effectRef idx="\(index)"><a:schemeClr val="accent2"/></a:effectRef><a:fontRef idx="minor"/></p:style>
            """
        }
        let presentation = try deck(
            square(id: 2, style: style(2)) + square(id: 3, effects: "<a:effectLst/>", style: style(2))
                + square(id: 4, style: style(3)) + square(id: 5, style: style(0)),
            effectStyle: glow
        )
        let context = SlideStyleContext(presentation: presentation, slide: presentation.slides[0])
        let shapes = presentation.slides[0].shapes
        let themed = context.effects(for: shapes[0])
        #expect(themed.effects.glow == Glow(radius: 101_600, color: DrawingColor(
            base: .scheme("accent2"), transforms: [.init(name: "alpha", value: 60_000)])))
        #expect(themed.effects.softEdge == 12_700)
        // An empty list of its own outranks the style.
        #expect(context.effects(for: shapes[1]) == EffectStyle())
        // The template's third style casts a shadow.
        #expect(context.effects(for: shapes[2]).shadow?.distance == 19_050)
        #expect(context.effects(for: shapes[3]) == EffectStyle())

        // The themed glow shows round its square, until it is given effects of its own.
        var edited = presentation
        edited.slides[0].shapes = [shapes[0]]
        let colors = try pixels(edited, at: [(97, 150)])
        #expect(colors[0][2] < 200 && colors[0][0] > 200) // Orange-tinted, not white.
        edited.slides[0].shapes[0].edits.insert(.effects)
        #expect(try pixels(edited, at: [(97, 150)])[0] == [255, 255, 255, 255])
    }

    @Test("Saving keeps the effects Dazzle does not edit, and a new shadow replaces a preset one") @MainActor
    func saving() throws {
        let list = """
            <a:effectLst><a:glow rad="127000"><a:srgbClr val="00FF00"/></a:glow><a:innerShdw blurRad="0" dist="50800" \
            dir="2700000"><a:srgbClr val="0000FF"/></a:innerShdw><a:prstShdw prst="shdw6" dist="38100" dir="2700000">\
            <a:srgbClr val="000000"/></a:prstShdw><a:softEdge rad="31750"/></a:effectLst>
            """
        var presentation = try deck(square(id: 2, effects: list))
        let original = presentation.slides[0].shapes[0].effects
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.selectAllShapes(in: presentation)
        state.setReflection(FormatChoices.reflections[1].reflection, in: &presentation)
        var read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(read.slides[0].shapes[0].effects == original)
        #expect(read.slides[0].shapes[0].reflection != nil)

        state.setShadow(Shadow(blur: 0, distance: 12_700, direction: 45, color: .rgb(0)), in: &presentation)
        #expect(presentation.slides[0].shapes[0].effects.presetShadow == nil)
        read = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        var expected = original
        expected.presetShadow = nil
        #expect(read.slides[0].shapes[0].effects == expected)
        #expect(read.slides[0].shapes[0].shadow?.distance == 12_700)
    }

    @Test("Each effect draws where PowerPoint puts it")
    func drawing() throws {
        // Glow: green just outside the square.
        var colors = try pixels(deck(square(id: 2, effects: """
            <a:effectLst><a:glow rad="127000"><a:srgbClr val="00FF00"/></a:glow></a:effectLst>
            """)), at: [(96, 150), (150, 150), (80, 150)])
        #expect(colors[0][1] > 200 && colors[0][0] < 100)
        #expect(colors[1] == [255, 0, 0, 255])
        #expect(colors[2] == [255, 255, 255, 255])

        // Soft edges: faded at the edge, solid in the middle.
        colors = try pixels(deck(square(id: 2, effects: "<a:effectLst><a:softEdge rad=\"254000\"/></a:effectLst>")),
                            at: [(101, 150), (150, 150)])
        #expect(colors[0][1] > 180)
        #expect(colors[1] == [255, 0, 0, 255])

        // Inner shadow: falling from the top left edges, inside only.
        colors = try pixels(deck(square(id: 2, effects: """
            <a:effectLst><a:innerShdw dist="127000" dir="2700000"><a:srgbClr val="0000FF"/></a:innerShdw></a:effectLst>
            """)), at: [(103, 103), (150, 150), (197, 197), (97, 103)])
        #expect(colors[0][2] > 200 && colors[0][0] < 60)
        #expect(colors[1] == [255, 0, 0, 255])
        #expect(colors[2] == [255, 0, 0, 255])
        #expect(colors[3] == [255, 255, 255, 255])

        // Preset drop shadow: hard-edged, down and to the right.
        colors = try pixels(deck(square(id: 2, effects: """
            <a:effectLst><a:prstShdw prst="shdw6" dist="127000" dir="2700000"><a:srgbClr val="000000"/></a:prstShdw></a:effectLst>
            """)), at: [(205, 205), (150, 205), (95, 150)])
        #expect(colors[0] == [0, 0, 0, 255])
        #expect(colors[1] == [0, 0, 0, 255])
        #expect(colors[2] == [255, 255, 255, 255])

        // Blur: the square's colour spreads past its edge, unless it may not grow.
        colors = try pixels(deck(square(id: 2, effects: "<a:effectLst><a:blur rad=\"127000\"/></a:effectLst>")),
                            at: [(97, 150), (150, 150)])
        #expect(colors[0][1] < 230)
        #expect(colors[1] == [255, 0, 0, 255])
        colors = try pixels(deck(square(id: 2, effects: "<a:effectLst><a:blur rad=\"127000\" grow=\"0\"/></a:effectLst>")),
                            at: [(97, 150)])
        #expect(colors[0] == [255, 255, 255, 255])
    }

    @Test("Perspective preset shadows lean and fold from the shape's bottom edge")
    func presetCasts() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        func cast(_ preset: Int) -> CGAffineTransform {
            PresetShadow(preset: preset, distance: 0, direction: 0, color: .rgb(0)).transform(in: bounds)
        }
        // Back left: the top edge stands half as high, leaning left.
        let backLeft = CGPoint(x: 50, y: 0).applying(cast(3))
        #expect(abs(backLeft.y - 50) < 0.001 && backLeft.x < 50)
        // Front right: folded down below the bottom edge, leaning right.
        let frontRight = CGPoint(x: 50, y: 0).applying(cast(8))
        #expect(frontRight.y > 100 && frontRight.x > 50)
        // The bottom edge stays put.
        #expect(CGPoint(x: 20, y: 100).applying(cast(15)) == CGPoint(x: 20, y: 100))
        // Large drop shadows grow from the middle.
        let corner = CGPoint(x: 0, y: 0).applying(cast(10))
        #expect(abs(corner.x + 5) < 0.001 && abs(corner.y + 5) < 0.001)
    }
}
