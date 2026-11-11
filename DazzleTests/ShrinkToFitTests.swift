import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

/// Text that shrinks on overflow (`normAutofit`) fitted as PowerPoint does:
/// its lines closed up, then its letters made smaller step by step, unless
/// the file says by how much.
@MainActor
@Suite("Shrink text on overflow")
struct ShrinkToFitTests {
    typealias Step = BodyProperties.Autofit.ShrinkStep

    /// The text box's frame, in points: 400 wide, 100 tall, 100 in from the corner.
    private let box = CGRect(x: 100, y: 100, width: 400, height: 100)

    private func shapes(_ xml: String) throws -> [SlideShape] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(xml)</p:spTree>
            """.utf8))
        return ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                           parts: [:], capturesSource: true).shapes(in: root)
    }

    /// A text box with `bodyPr`'s attributes and fit, holding `lines` short paragraphs of 18 point text.
    private func textBox(_ attributes: String = "", fit: String = "<a:normAutofit/>", lines: Int, bullets: Bool = false) throws -> SlideShape {
        let bullet = bullets ? "<a:pPr marL=\"342900\" indent=\"-342900\"><a:buChar char=\"•\"/></a:pPr>" : ""
        let paragraphs = (0..<lines).map { "<a:p>\(bullet)<a:r><a:rPr lang=\"en-US\" sz=\"1800\"/><a:t>Line \($0 + 1)</a:t></a:r></a:p>" }
        return try #require(shapes("""
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="5080000" cy="1270000"/></a:xfrm>
            <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
            <p:txBody><a:bodyPr wrap="square" \(attributes)>\(fit)</a:bodyPr><a:lstStyle/>\(paragraphs.joined())</p:txBody></p:sp>
            """).first)
    }

    private var renderer: TextRenderer {
        let presentation = Presentation.blank
        return TextRenderer(style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]), slideNumber: 1)
    }

    private func fit(_ shape: SlideShape) throws -> Step? {
        guard case .normal(let scale, let reduction)? = renderer.shrinkFit(of: try #require(shape.text), shape: shape, sources: []) else {
            return nil
        }
        return Step(fontScale: scale, lineSpacingReduction: reduction)
    }

    /// The lowest row the shape's text leaves ink on, a pixel to the point.
    private func inkBottom(_ shape: SlideShape) throws -> CGFloat {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [shape]
        let size = presentation.slideSize.points
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: CGSize(width: width, height: height))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 { return CGFloat(y) }
        }
        return 0
    }

    @Test("The steps are PowerPoint's: lines closed up first, then letters 7.5% smaller at a time, down to a quarter")
    func steps() {
        let steps = BodyProperties.Autofit.shrinkSteps
        #expect(steps.prefix(2) == [Step(fontScale: 1, lineSpacingReduction: 0.1), Step(fontScale: 1, lineSpacingReduction: 0.2)])
        var scales: [Double] = []
        for step in steps where scales.last != step.fontScale { scales.append(step.fontScale) }
        #expect(scales == [1, 0.925, 0.85, 0.775, 0.7, 0.625, 0.55, 0.475, 0.4, 0.25])
        #expect(Set(steps.map(\.lineSpacingReduction)) == [0.1, 0.2])
        #expect(steps.filter { $0.fontScale < 0.8 }.allSatisfy { $0.lineSpacingReduction == 0.2 })
        #expect(steps.last == Step(fontScale: 0.25, lineSpacingReduction: 0.2))
    }

    @Test("A file that says how far is drawn as it says; lines it only closed up go on from there")
    func stepsLeft() {
        #expect(BodyProperties.Autofit.normal(fontScale: 1, lineSpacingReduction: 0).shrinkStepsLeft == BodyProperties.Autofit.shrinkSteps)
        #expect(BodyProperties.Autofit.normal(fontScale: 0.625, lineSpacingReduction: 0.2).shrinkStepsLeft.isEmpty)
        #expect(BodyProperties.Autofit.normal(fontScale: 0.9, lineSpacingReduction: 0).shrinkStepsLeft.isEmpty)
        #expect(BodyProperties.Autofit.normal(fontScale: 1, lineSpacingReduction: 0.1).shrinkStepsLeft.first
            == Step(fontScale: 1, lineSpacingReduction: 0.2))
        #expect(BodyProperties.Autofit.shape.shrinkStepsLeft.isEmpty)
        #expect(BodyProperties.Autofit.none.shrinkStepsLeft.isEmpty)
    }

    @Test("Text that fits isn't shrunk, a little overflow closes the lines up, and more shrinks the letters too")
    func fitsByOverflow() throws {
        #expect(try fit(textBox(lines: 2)) == Step(fontScale: 1, lineSpacingReduction: 0))
        let little = try #require(try fit(textBox(lines: 5)))
        #expect(little.fontScale == 1)
        #expect(little.lineSpacingReduction > 0)
        // More text never takes a larger step, and every step is one of PowerPoint's.
        let steps = BodyProperties.Autofit.shrinkSteps
        var last = -1
        for lines in [6, 8, 10, 14, 20] {
            let step = try #require(try fit(textBox(lines: lines)))
            let index = try #require(steps.firstIndex(of: step), "\(lines) lines")
            #expect(index >= last, "\(lines) lines")
            last = index
        }
        #expect(try fit(textBox(lines: 200)) == steps.last, "a quarter is the least, even if the text still overflows")
        #expect(try fit(textBox(fit: "<a:spAutoFit/>", lines: 20)) == nil)
        #expect(try fit(textBox(fit: "", lines: 20)) == nil)
    }

    @Test("Shrunk text stays in its box, bulleted or set in columns")
    func staysInTheBox() throws {
        for shape in [try textBox(lines: 9), try textBox(lines: 9, bullets: true), try textBox("numCol=\"2\"", lines: 18)] {
            #expect(try inkBottom(shape) <= box.maxY + 1)
        }
        // Columns give more room, so the same text shrinks less.
        let single = try #require(try fit(textBox(lines: 18)))
        let columned = try #require(try fit(textBox("numCol=\"2\"", lines: 18)))
        #expect(columned.fontScale > single.fontScale)
    }

    @Test("Vertical text shrinks to the room across its box")
    func vertical() throws {
        // The box is 400 wide, so vertical lines have four times the room they have going down it.
        let across = try #require(try fit(textBox("vert=\"eaVert\"", lines: 5)))
        let down = try #require(try fit(textBox(lines: 5)))
        #expect(across == Step(fontScale: 1, lineSpacingReduction: 0))
        #expect(down != across)
        let crowded = try #require(try fit(textBox("vert=\"eaVert\"", lines: 40)))
        #expect(crowded.fontScale < 1)
    }

    @Test("A font scale the file gives is drawn as it is, even when the text still overflows")
    func explicitScale() throws {
        let said = try textBox(fit: "<a:normAutofit fontScale=\"62500\" lnSpcReduction=\"20000\"/>", lines: 12)
        #expect(try inkBottom(said) > box.maxY + 10)
        // Worked out afresh, as after an edit, it fits.
        let refit = try #require(try fit(said))
        #expect(refit.fontScale < 0.625)
    }

    @Test("Text in a table never shrinks: its row grows instead")
    func tables() throws {
        let frame = try #require(shapes("""
            <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
            <p:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="370332"/></p:xfrm>
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr/>
            <a:tblGrid><a:gridCol w="914400"/></a:tblGrid><a:tr h="370332"><a:tc><a:txBody>\
            <a:bodyPr><a:normAutofit fontScale="40000"/></a:bodyPr><a:p><a:r><a:rPr lang="en-US"/><a:t>Cell</a:t></a:r></a:p>\
            </a:txBody><a:tcPr/></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>
            """).first)
        guard case .table(let table) = frame.kind else { Issue.record("not a table"); return }
        let presentation = Presentation.blank
        let layout = TableLayout(table: table, frame: frame.frame.points,
                                 style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]),
                                 presentation: presentation, slideNumber: 1)
        let body = try #require(layout.body(for: table.rows[0].cells[0], row: 0))
        #expect(body.properties.autofit == nil)
    }
}
