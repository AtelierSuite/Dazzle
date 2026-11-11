import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("WordArt text warps")
struct TextWarpTests {
    /// The text box's frame, in points: 400 wide, 100 tall, 100 in from the corner.
    private let box = CGRect(x: 100, y: 100, width: 400, height: 100)

    /// Every preset ECMA-376 defines, but `textNoShape`.
    static let presets = [
        "textArchDown", "textArchDownPour", "textArchUp", "textArchUpPour", "textButton", "textButtonPour",
        "textCanDown", "textCanUp", "textCascadeDown", "textCascadeUp", "textChevron", "textChevronInverted",
        "textCircle", "textCirclePour", "textCurveDown", "textCurveUp", "textDeflate", "textDeflateBottom",
        "textDeflateInflate", "textDeflateInflateDeflate", "textDeflateTop", "textDoubleWave1", "textFadeDown",
        "textFadeLeft", "textFadeRight", "textFadeUp", "textInflate", "textInflateBottom", "textInflateTop",
        "textPlain", "textRingInside", "textRingOutside", "textSlantDown", "textSlantUp", "textStop", "textTriangle",
        "textTriangleInverted", "textWave1", "textWave2", "textWave4",
    ]

    private func shapes(_ xml: String) throws -> [SlideShape] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(xml)</p:spTree>
            """.utf8))
        return ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                           parts: [:], capturesSource: true).shapes(in: root)
    }

    /// A text box warped by `warp` (an `a:prstTxWarp`, or nothing), holding
    /// `lines` paragraphs of 36 point text.
    private func wordArt(_ warp: String, lines: [String] = ["WordArt"]) throws -> SlideShape {
        let paragraphs = lines.map {
            "<a:p><a:pPr algn=\"ctr\"/><a:r><a:rPr lang=\"en-US\" sz=\"3600\" b=\"1\"/><a:t>\($0)</a:t></a:r></a:p>"
        }
        return try #require(shapes("""
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="WordArt"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="5080000" cy="1270000"/></a:xfrm>
            <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
            <p:txBody><a:bodyPr wrap="none" anchor="ctr">\(warp)</a:bodyPr><a:lstStyle/>\(paragraphs.joined())</p:txBody></p:sp>
            """).first)
    }

    private func warp(_ preset: String, _ adjustments: [String: Int] = [:]) -> String {
        TextWarp(preset: preset, adjustments: adjustments).xml
    }

    /// Where the shape's text leaves ink, a pixel to the point.
    private struct Ink: Equatable {
        var width: Int
        var height: Int
        var pixels: Data

        func count(in rect: CGRect) -> Int {
            var count = 0
            for y in max(Int(rect.minY), 0)..<min(Int(rect.maxY), height) {
                for x in max(Int(rect.minX), 0)..<min(Int(rect.maxX), width) where pixels[(y * width + x) * 4 + 3] > 128 {
                    count += 1
                }
            }
            return count
        }

        var total: Int { count(in: CGRect(x: 0, y: 0, width: width, height: height)) }
    }

    private func ink(_ shape: SlideShape, options: SlideRenderer.Options = .init(drawsBackground: false)) throws -> Ink {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [shape]
        let size = presentation.slideSize.points
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: options)
            .draw(in: canvas, size: CGSize(width: width, height: height))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        return Ink(width: width, height: height, pixels: pixels)
    }

    @Test("The warp and its adjust values are read, and inherited when unsaid")
    func read() throws {
        let shape = try wordArt("<a:prstTxWarp prst=\"textArchUp\"><a:avLst><a:gd name=\"adj\" fmla=\"val 12000000\"/></a:avLst></a:prstTxWarp>")
        let properties = try #require(shape.text?.properties)
        #expect(properties.warp == TextWarp(preset: "textArchUp", adjustments: ["adj": 12_000_000]))
        #expect(!TextWarpGeometry.isFlat(properties.warp))

        let unsaid = try #require(try wordArt("").text?.properties)
        #expect(unsaid.warp == nil)
        #expect(unsaid.merged(over: properties).warp?.preset == "textArchUp")

        let none = try #require(try wordArt("<a:prstTxWarp prst=\"textNoShape\"><a:avLst/></a:prstTxWarp>").text?.properties)
        #expect(none.warp?.preset == "textNoShape")
        #expect(TextWarpGeometry.isFlat(none.warp))
        #expect(TextWarpGeometry(none.warp, in: box) == nil)
    }

    @Test("Every preset lays its paths over the box", arguments: presets)
    func everyPreset(_ preset: String) throws {
        let geometry = try #require(TextWarpGeometry(TextWarp(preset: preset), in: box))
        #expect(!geometry.bands.isEmpty)
        for band in geometry.bands {
            let guides: [TextWarpGeometry.Guide] = switch band {
            case .between(let top, let bottom): [top, bottom]
            case .along(let guide): [guide]
            }
            for guide in guides {
                #expect(guide.length > 0)
                for point in guide.points {
                    #expect(box.insetBy(dx: -1, dy: -1).contains(point), "\(preset) reaches \(point)")
                }
            }
        }
    }

    @Test("Paths pair up top and bottom, and an odd number are each followed")
    func bands() throws {
        let plain = try #require(TextWarpGeometry(TextWarp(preset: "textPlain"), in: box))
        #expect(plain.bands.count == 1)
        guard case .between = plain.bands[0] else { Issue.record("textPlain stretches between its paths"); return }
        let button = try #require(TextWarpGeometry(TextWarp(preset: "textButton"), in: box))
        #expect(button.bands.count == 3)
        guard case .along = button.bands[0] else { Issue.record("textButton follows its paths"); return }
        #expect(try #require(TextWarpGeometry(TextWarp(preset: "textDeflateInflate"), in: box)).bands.count == 2)
        #expect(try #require(TextWarpGeometry(TextWarp(preset: "textButtonPour"), in: box)).bands.count == 3)

        // Lines are shared out in turn, the earlier bands taking any left over.
        #expect((0..<3).map { button.band(forLine: $0, of: 3) } == [0, 1, 2])
        #expect((0..<4).map { button.band(forLine: $0, of: 4) } == [0, 0, 1, 2])
        #expect(button.band(forLine: 0, of: 1) == 0)
        #expect((0..<2).map { plain.band(forLine: $0, of: 2) } == [0, 0])
    }

    @Test("Text between two paths is stretched from one to the other, across their whole length")
    func betweenPaths() throws {
        // textSlantUp: the left edge runs from part way down to the bottom, the right edge from the top to part way up.
        let geometry = try #require(TextWarpGeometry(TextWarp(preset: "textSlantUp"), in: box))
        let placement = TextWarpGeometry.Placement(band: 0, top: 10, height: 20)
        let topLeft = geometry.point(placement, x: 0, lineWidth: 50, y: 10)
        let bottomLeft = geometry.point(placement, x: 0, lineWidth: 50, y: 30)
        let topRight = geometry.point(placement, x: 50, lineWidth: 50, y: 10)
        let bottomRight = geometry.point(placement, x: 50, lineWidth: 50, y: 30)
        #expect(abs(topLeft.x - box.minX) < 0.5 && abs(bottomLeft.x - box.minX) < 0.5)
        #expect(abs(topRight.x - box.maxX) < 0.5 && abs(bottomRight.x - box.maxX) < 0.5)
        #expect(abs(bottomLeft.y - box.maxY) < 0.5)
        #expect(abs(topRight.y - box.minY) < 0.5)
        #expect(topLeft.y > box.minY + 10, "The left edge starts lower")
        #expect(bottomRight.y < box.maxY - 10, "The right edge ends higher")

        // A letter in the middle stands as tall as the band there, upright.
        let letter = geometry.letterTransform(placement, from: 20, to: 30, lineWidth: 50, baseline: 30, ascent: 20)
        let middleTop = geometry.point(placement, x: 25, lineWidth: 50, y: 10)
        let middleBottom = geometry.point(placement, x: 25, lineWidth: 50, y: 30)
        let up = CGPoint(x: letter.c * 20, y: letter.d * 20)
        #expect(abs(up.x - (middleTop.x - middleBottom.x)) < 0.01)
        #expect(abs(up.y - (middleTop.y - middleBottom.y)) < 0.01)
        #expect(letter.a > 0, "Letters still run left to right")
    }

    @Test("Text along a path sits on it, standing out from the arch")
    func alongAPath() throws {
        let geometry = try #require(TextWarpGeometry(TextWarp(preset: "textArchUp"), in: box))
        let placement = TextWarpGeometry.Placement(band: 0, baseline: 50)
        // The middle of the line is at the top of the arch, the ends at the box's sides half way down.
        let middle = geometry.point(placement, x: 50, lineWidth: 100, y: 50)
        #expect(abs(middle.x - box.midX) < 1 && abs(middle.y - box.minY) < 1)
        let start = geometry.point(placement, x: 0, lineWidth: 100, y: 50)
        #expect(abs(start.x - box.minX) < 1 && abs(start.y - box.midY) < 1)
        // Below the baseline is inside the arch; the letters' tops stand out of it.
        let below = geometry.point(placement, x: 50, lineWidth: 100, y: 60)
        #expect(abs(below.y - (box.minY + 10)) < 0.5)
        let letter = geometry.letterTransform(placement, from: 0, to: 10, lineWidth: 100, baseline: 50, ascent: 20)
        #expect(letter.c < 0, "At the left end, up the letter points out to the left")

        // The adjust value moves where the arch starts and ends: a quarter turn on, from the top.
        let quarter = try #require(TextWarpGeometry(TextWarp(preset: "textArchUp", adjustments: ["adj": 16_200_000]), in: box))
        let quarterStart = quarter.point(placement, x: 0, lineWidth: 100, y: 50)
        #expect(abs(quarterStart.x - box.midX) < 1 && abs(quarterStart.y - box.minY) < 1)
    }

    @Test("No warp, and textNoShape, draw just as text always has")
    func flatIsUnchanged() throws {
        let plain = try ink(wordArt(""))
        #expect(plain.total > 0)
        #expect(try ink(wordArt(warp("textNoShape"))) == plain)
        #expect(try ink(wordArt("<a:prstTxWarp prst=\"textUnknown\"/>")) == plain)
    }

    @Test("Every preset draws its text, warped", arguments: presets)
    func drawsEveryPreset(_ preset: String) throws {
        let plain = try ink(wordArt("", lines: ["WordArt", "Two"]))
        let warped = try ink(wordArt(warp(preset), lines: ["WordArt", "Two"]))
        #expect(warped.total > 100, "\(preset) draws its letters")
        #expect(warped != plain, "\(preset) changes how they lie")
        // Kept around the box: letters may stand out of an arch or ring a little, but no further.
        let outside = warped.total - warped.count(in: box.insetBy(dx: -40, dy: -40))
        #expect(outside == 0, "\(preset) leaves \(outside) pixels well outside the box")
    }

    @Test("Text stretched over textPlain fills the box from side to side and top to bottom")
    func fillsTheBox() throws {
        let plain = try ink(wordArt(""))
        let stretched = try ink(wordArt(warp("textPlain")))
        // Inside the insets: 7.2 points either side, 3.6 above and below.
        let inner = CGRect(x: box.minX + 7.2, y: box.minY + 3.6, width: box.width - 14.4, height: box.height - 7.2)
        let leftEdge = CGRect(x: inner.minX, y: inner.minY, width: 12, height: inner.height)
        let rightEdge = CGRect(x: inner.maxX - 12, y: inner.minY, width: 12, height: inner.height)
        let topEdge = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 6)
        #expect(plain.count(in: leftEdge) == 0 && plain.count(in: topEdge) == 0)
        #expect(stretched.count(in: leftEdge) > 0)
        #expect(stretched.count(in: rightEdge) > 0)
        #expect(stretched.count(in: topEdge) > 0)
    }

    @Test("The arch draws its middle letters at the top and its ends low down")
    func archUp() throws {
        let arched = try ink(wordArt(warp("textArchUp"), lines: ["ABCDEFGHIJKLMNOP"]))
        let topMiddle = CGRect(x: box.midX - 30, y: box.minY - 10, width: 60, height: 30)
        let lowLeft = CGRect(x: box.minX - 10, y: box.midY, width: 50, height: box.height / 2 + 10)
        let lowMiddle = CGRect(x: box.midX - 30, y: box.midY + 10, width: 60, height: box.height / 2 - 10)
        #expect(arched.count(in: topMiddle) > 0)
        #expect(arched.count(in: lowLeft) > 0)
        #expect(arched.count(in: lowMiddle) == 0, "Nothing hangs in the middle of the arch")
    }

    @Test("Text being typed is laid out flat, around the bullets the editor leaves drawn")
    func editingStaysFlat() throws {
        let shape = try wordArt(warp("textWave1"))
        let typing = SlideRenderer.Options(bulletsOnlyShapeID: shape.id, drawsBackground: false)
        let flat = try wordArt("")
        let flatTyping = try ink(flat, options: SlideRenderer.Options(bulletsOnlyShapeID: flat.id, drawsBackground: false))
        #expect(try ink(shape, options: typing) == flatTyping)
    }

    @Test("A warp is kept when the text is edited and saved, and written for text made in Dazzle")
    func roundTrip() throws {
        func reread(_ shape: SlideShape) throws -> (properties: BodyProperties?, xml: String) {
            var presentation = Presentation.blank
            presentation.slides[0].shapes = [shape]
            presentation.slides[0].isModified = true
            let data = try PPTXWriter.data(from: presentation)
            let read = try PPTXReader.presentation(from: data)
            let slide = try #require(try ZipArchive.entries(in: data)["ppt/slides/slide1.xml"])
            let xml = String(decoding: slide, as: UTF8.self)
            return (read.slides[0].shapes.first?.text?.properties, xml)
        }
        let said = "<a:prstTxWarp prst=\"textWave1\"><a:avLst><a:gd name=\"adj1\" fmla=\"val 20000\"/>"
            + "<a:gd name=\"adj2\" fmla=\"val -5000\"/></a:avLst></a:prstTxWarp>"
        var edited = try wordArt(said)
        edited.edits.insert(.text)
        edited.text?.setPlainText("Edited\nWordArt")
        let saved = try reread(edited)
        #expect(saved.properties?.warp == TextWarp(preset: "textWave1", adjustments: ["adj1": 20_000, "adj2": -5_000]))
        #expect(saved.xml.contains("prst=\"textWave1\""))
        #expect(saved.xml.components(separatedBy: "prstTxWarp prst").count == 2, "Written once")

        // Made in Dazzle, with no XML of its own.
        var made = try wordArt("")
        made.source = nil
        made.text?.properties.warp = TextWarp(preset: "textArchDown", adjustments: ["adj": 900_000])
        let written = try reread(made)
        #expect(written.properties?.warp == TextWarp(preset: "textArchDown", adjustments: ["adj": 900_000]))
    }
}
