import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("3D bevels, depth and contours")
struct ThreeDTests {
    /// A 100 × 100 point square at (100, 100), filled `fill`, with `extra`
    /// (a scene and shape in 3D) in its properties and `style` after them.
    private func square(id: Int = 2, fill: String = "4080C0", extra: String = "", style: String = "") -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Square \(id)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="1270000" cy="1270000"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(fill)"/></a:solidFill>\
        \(extra)</p:spPr>\(style)</p:sp>
        """
    }

    private func scene(camera: String = "orthographicFront", light: String = "t", rig: String = "threePt") -> String {
        "<a:scene3d><a:camera prst=\"\(camera)\"/><a:lightRig rig=\"\(rig)\" dir=\"\(light)\"/></a:scene3d>"
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

    /// The slide drawn one pixel to the point, as RGBA bytes, row by row.
    private func render(_ presentation: Presentation) throws -> (data: Data, width: Int) {
        let size = presentation.slideSize.points
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0]).draw(in: canvas, size: CGSize(width: width, height: height))
        return (try #require(canvas.makeImage()?.dataProvider?.data as Data?), width)
    }

    /// Red, green, blue and alpha at each point asked for.
    private func pixels(_ presentation: Presentation, at points: [(Int, Int)]) throws -> [[Int]] {
        let (data, width) = try render(presentation)
        return points.map { x, y in
            let offset = (y * width + x) * 4
            return (0..<4).map { Int(data[offset + $0]) }
        }
    }

    private func brightness(_ pixel: [Int]) -> Int { pixel[0] + pixel[1] + pixel[2] }

    @Test("The camera, lights, bevels, depth, contour and material read from a shape's properties")
    func reading() throws {
        let presentation = try deck(square(extra: """
            <a:scene3d><a:camera prst="perspectiveRelaxed"><a:rot lat="600000" lon="1200000" rev="0"/></a:camera>\
            <a:lightRig rig="harsh" dir="tl"><a:rot lat="0" lon="0" rev="1200000"/></a:lightRig></a:scene3d>\
            <a:sp3d extrusionH="254000" contourW="12700" prstMaterial="metal"><a:bevelT w="101600" h="50800" prst="artDeco"/>\
            <a:bevelB/><a:extrusionClr><a:srgbClr val="FF0000"/></a:extrusionClr>\
            <a:contourClr><a:schemeClr val="accent2"/></a:contourClr></a:sp3d>
            """) + square(id: 3, extra: "<a:sp3d/>"))
        let shapes = presentation.slides[0].shapes
        let scene = try #require(shapes[0].scene3D)
        #expect(scene.camera == "perspectiveRelaxed")
        #expect(scene.cameraRotation == Scene3D.Rotation(latitude: 10, longitude: 20))
        #expect(scene.lightRig == "harsh")
        #expect(scene.lightDirection == "tl")
        #expect(scene.lightRotation?.revolution == 20)
        let shape = try #require(shapes[0].shape3D)
        #expect(shape.topBevel == Shape3D.Bevel(width: 101_600, height: 50_800, preset: "artDeco"))
        #expect(shape.bottomBevel == Shape3D.Bevel())
        #expect(shape.extrusionHeight == 254_000)
        #expect(shape.extrusionColor == .rgb(0xFF0000))
        #expect(shape.contourWidth == 12_700)
        #expect(shape.contourColor == DrawingColor(base: .scheme("accent2")))
        #expect(shape.material == "metal")
        // Unsaid, as the specification has them.
        #expect(shapes[1].scene3D == nil)
        #expect(shapes[1].shape3D == Shape3D())
        #expect(Shape3D().material == "warmMatte" && Scene3D().lightRig == "threePt" && Scene3D().lightDirection == "t")
    }

    @Test("A shape without 3D of its own takes its theme effect style's, in its reference's colour")
    func themeStyles() throws {
        let style = """
            <a:effectStyle><a:effectLst/><a:scene3d><a:camera prst="orthographicFront"/>\
            <a:lightRig rig="threePt" dir="t"/></a:scene3d><a:sp3d contourW="12700"><a:bevelT w="63500" h="25400"/>\
            <a:contourClr><a:schemeClr val="phClr"/></a:contourClr></a:sp3d></a:effectStyle>
            """
        let reference = """
            <p:style><a:lnRef idx="0"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef>\
            <a:effectRef idx="2"><a:srgbClr val="00FF00"/></a:effectRef><a:fontRef idx="minor"/></p:style>
            """
        let presentation = try deck(
            square(style: reference) + square(id: 3, extra: "<a:sp3d prstMaterial=\"metal\"/>", style: reference),
            effectStyle: style
        )
        let context = SlideStyleContext(presentation: presentation, slide: presentation.slides[0])
        let shapes = presentation.slides[0].shapes
        let themed = context.resolvingEffects(of: shapes[0])
        #expect(themed.shape3D?.topBevel == Shape3D.Bevel(width: 63_500, height: 25_400))
        #expect(themed.shape3D?.contourColor == .rgb(0x00FF00))
        #expect(themed.scene3D?.camera == "orthographicFront")
        // Its own sp3d outranks the style's, while the scene still comes from it.
        let own = context.resolvingEffects(of: shapes[1])
        #expect(own.shape3D == Shape3D(material: "metal"))
        #expect(own.scene3D?.lightDirection == "t")
        // The effects themselves leave 3D out, as before.
        #expect(context.effects(for: shapes[0]) == EffectStyle())
    }

    @Test("A deck without 3D, or with 3D that shows nothing, draws exactly as before")
    func unchanged() throws {
        let plain = try render(deck(square()))
        #expect(try render(deck(square(extra: scene() + "<a:sp3d/>"))).data == plain.data)
        // A bevel with no height, and depth seen face on.
        #expect(try render(deck(square(extra: scene() + "<a:sp3d extrusionH=\"254000\"><a:bevelT h=\"0\"/></a:sp3d>"))).data
            == plain.data)
        #expect(Shape3DLook(scene: nil, shape: nil, bounds: CGRect(x: 0, y: 0, width: 10, height: 10), face: .black) { _ in .black }
            == nil)
    }

    @Test("A bevel lights the edge facing the light and shades the one opposite, leaving the middle as it was")
    func bevel() throws {
        let bevel = "<a:sp3d><a:bevelT w=\"127000\" h=\"127000\"/></a:sp3d>"
        let points = [(150, 102), (150, 198), (150, 150), (102, 150)]
        var colors = try pixels(deck(square(extra: scene(light: "t") + bevel)), at: points)
        let plain = try pixels(deck(square()), at: [(150, 150)])[0]
        #expect(brightness(colors[0]) > brightness(plain) + 60)
        #expect(brightness(colors[1]) < brightness(plain) - 40)
        #expect(colors[2] == plain)
        // Lit from the top, the sides face neither way.
        #expect(colors[3] == plain)

        // From the bottom left, the left edge is lit and the top shaded.
        colors = try pixels(deck(square(extra: scene(light: "bl") + bevel)), at: points)
        #expect(brightness(colors[3]) > brightness(plain) + 40)
        #expect(brightness(colors[0]) < brightness(plain) - 30)

        // The light stays where the slide has it when the shape turns: turned
        // upside down, its top edge (now at the bottom) is the shaded one.
        let turned = try deck(square(extra: scene(light: "t") + bevel).replacingOccurrences(of: "<a:xfrm>", with: "<a:xfrm rot=\"10800000\">"))
        colors = try pixels(turned, at: points)
        #expect(brightness(colors[0]) > brightness(plain) + 60)
        #expect(brightness(colors[1]) < brightness(plain) - 40)

        // A cross is lit at its outer edge and shaded further in.
        let cross = try pixels(deck(square(extra: scene() + "<a:sp3d><a:bevelT w=\"254000\" h=\"254000\" prst=\"cross\"/></a:sp3d>")),
                               at: [(150, 103), (150, 117)])
        #expect(brightness(cross[0]) > brightness(plain))
        #expect(brightness(cross[1]) < brightness(plain))
    }

    @Test("Harsher lights and shinier materials pick the bevel out more strongly")
    func strength() throws {
        func highlight(rig: String, material: String) throws -> Int {
            let extra = scene(rig: rig) + "<a:sp3d prstMaterial=\"\(material)\"><a:bevelT w=\"127000\" h=\"127000\"/></a:sp3d>"
            return try brightness(pixels(deck(square(extra: extra)), at: [(150, 102)])[0])
        }
        let plain = try highlight(rig: "threePt", material: "warmMatte")
        #expect(try highlight(rig: "harsh", material: "warmMatte") > plain)
        #expect(try highlight(rig: "flat", material: "warmMatte") < plain)
        #expect(try highlight(rig: "threePt", material: "metal") > plain)
        #expect(try highlight(rig: "threePt", material: "flat") < plain)
    }

    @Test("Depth shows as darker sides behind the shape when the camera looks from an angle")
    func depth() throws {
        let sp3d = "<a:sp3d extrusionH=\"508000\"><a:extrusionClr><a:srgbClr val=\"00FF00\"/></a:extrusionClr></a:sp3d>"
        // Seen from the top left, the sides stand out up and to the left.
        var colors = try pixels(deck(square(extra: scene(camera: "obliqueTopLeft") + sp3d)), at: [(95, 95), (205, 205), (150, 150)])
        #expect(colors[0][1] > 80 && colors[0][1] < 220 && colors[0][0] < 40 && colors[0][2] < 40)
        #expect(colors[1] == [255, 255, 255, 255])
        #expect(colors[2] == [0x40, 0x80, 0xC0, 255])
        // Seen from below on the right, the other way.
        colors = try pixels(deck(square(extra: scene(camera: "obliqueBottomRight") + sp3d)), at: [(95, 95), (205, 205)])
        #expect(colors[0] == [255, 255, 255, 255])
        #expect(colors[1][1] > 80 && colors[1][0] < 40)
        // Face on, none show.
        colors = try pixels(deck(square(extra: scene() + sp3d)), at: [(95, 95), (205, 205)])
        #expect(colors.allSatisfy { $0 == [255, 255, 255, 255] })

        // In the fill's colour unless they have their own, and smaller towards the back through a perspective camera.
        let look = try #require(Shape3DLook(
            scene: Scene3D(camera: "perspectiveAbove"), shape: Shape3D(extrusionHeight: 508_000),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100), face: RGBAColor(red: 1, green: 0, blue: 0)
        ) { _ in .black })
        let extrusion = try #require(look.extrusion)
        #expect(extrusion.colors.allSatisfy { $0.green == 0 && $0.blue == 0 && $0.red < 1 })
        #expect(extrusion.colors.first!.red < extrusion.colors.last!.red, "darker farther back")
        let back = try #require(extrusion.transforms.first)
        #expect(back.a < 1 && back.ty < 0, "smaller, and up behind the shape")
    }

    @Test("A contour bands the shape's edge in its colour")
    func contour() throws {
        let extra = scene() + "<a:sp3d contourW=\"76200\"><a:contourClr><a:srgbClr val=\"FF0000\"/></a:contourClr></a:sp3d>"
        let colors = try pixels(deck(square(extra: extra)), at: [(97, 150), (150, 150), (90, 150)])
        #expect(colors[0] == [255, 0, 0, 255])
        #expect(colors[1] == [0x40, 0x80, 0xC0, 255])
        #expect(colors[2] == [255, 255, 255, 255])
    }

    @Test("Saving keeps the scene and shape in 3D exactly as read, even once the shape is moved and recoloured")
    func saving() throws {
        // Attributes in the order the writer puts them, alphabetical.
        let scene3d = """
            <a:scene3d><a:camera prst="isometricOffAxis1Left"><a:rot lat="1200000" lon="600000" rev="0"/></a:camera>\
            <a:lightRig dir="tr" rig="sunrise"/></a:scene3d>
            """
        let sp3d = """
            <a:sp3d contourW="6350" extrusionH="76200" prstMaterial="dkEdge" z="12700"><a:bevelT h="19050" prst="riblet" w="38100"/>\
            <a:bevelB h="6350" prst="slope" w="12700"/><a:extrusionClr><a:srgbClr val="112233"/></a:extrusionClr>\
            <a:contourClr><a:schemeClr val="accent3"><a:lumMod val="75000"/></a:schemeClr></a:contourClr></a:sp3d>
            """
        var presentation = try deck(square(extra: scene3d + sp3d))
        presentation.slides[0].shapes[0].frame.x += 127_000
        presentation.slides[0].shapes[0].edits.insert(.transform)
        presentation.slides[0].shapes[0].fill = .solid(.rgb(0xABCDEF))
        presentation.slides[0].shapes[0].edits.insert(.fill)
        presentation.slides[0].isModified = true
        let entries = try ZipArchive.entries(in: PPTXWriter.data(from: presentation))
        let slide = try #require(entries["ppt/slides/slide1.xml"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(slide.contains(scene3d + sp3d))
        #expect(slide.contains("ABCDEF"))
        let read = try PPTXReader.presentation(fromParts: entries)
        #expect(read.slides[0].shapes[0].scene3D == presentation.slides[0].shapes[0].scene3D)
        #expect(read.slides[0].shapes[0].shape3D == presentation.slides[0].shapes[0].shape3D)
    }
}
