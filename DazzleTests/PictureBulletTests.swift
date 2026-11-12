import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Picture bullets")
struct PictureBulletTests {
    private static let relationships = [
        Relationship(id: "rId9", type: OOXML.RelationshipType.image, target: "../media/bullet.png"),
    ]

    /// A small red square, as a PNG.
    private static func redSquare() throws -> Data {
        let canvas = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(canvas.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func bullet(_ id: String = "rId9") -> String {
        "<a:buBlip><a:blip r:embed=\"\(id)\"/></a:buBlip>"
    }

    private func shape(size: Int, listStyle: String = "", properties: String? = nil) throws -> SlideShape {
        let ownProperties = properties ?? "<a:pPr marL=\"457200\" indent=\"-457200\">\(Self.bullet())</a:pPr>"
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="1270000" y="1270000"/><a:ext cx="6350000" cy="2540000"/></a:xfrm>
            <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
            <p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0"/><a:lstStyle>\(listStyle)</a:lstStyle>
            <a:p>\(ownProperties)<a:r><a:rPr lang="en-US" sz="\(size)"/><a:t>Picture</a:t></a:r></a:p></p:txBody></p:sp>
            </p:spTree>
            """.utf8))
        let shapes = ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: Self.relationships, namespaces: OOXML.namespaces,
                                 parts: [:], capturesSource: true).shapes(in: root)
        return try #require(shapes.first)
    }

    @Test("a:buBlip is read as a picture from the package, from a paragraph or its list style")
    func read() throws {
        let own = try shape(size: 1_800)
        #expect(own.text?.paragraphs.first?.properties.bullet == .picture(path: "ppt/media/bullet.png"))

        let inherited = try shape(size: 1_800, listStyle: "<a:lvl1pPr>\(Self.bullet())</a:lvl1pPr>", properties: "")
        #expect(inherited.text?.listStyle.level(0).bullet == .picture(path: "ppt/media/bullet.png"))

        // A picture the package doesn't have says nothing, leaving the inherited bullet.
        let dangling = try shape(size: 1_800, properties: "<a:pPr>\(Self.bullet("rId404"))</a:pPr>")
        #expect(dangling.text?.paragraphs.first?.properties.bullet == nil)
    }

    /// Where the red picture is drawn, in slide points, when the slide is drawn a point a pixel.
    private func drawnBullet(size: Int) throws -> CGRect? {
        var presentation = Presentation.blank
        presentation.slideSize = .widescreen
        presentation.slides[0].shapes = [try shape(size: size)]
        presentation.addedParts["ppt/media/bullet.png"] = try Self.redSquare()
        let width = 960, height = 540
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: CGSize(width: width, height: height))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        var bounds = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * canvas.bytesPerRow + x * 4
                if pixels[offset] > 200, pixels[offset + 1] < 60, pixels[offset + 2] < 60, pixels[offset + 3] > 200 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds.isNull ? nil : bounds
    }

    @Test("The picture is drawn where the bullet hangs, as tall as the text at every size")
    func drawn() throws {
        // The text box's left edge is 100 points across and its top 100 down; the bullet hangs at the indent.
        for size in [1_800, 3_600, 6_000] {
            let bounds = try #require(try drawnBullet(size: size), "size \(size)")
            let points = CGFloat(size) / 100
            #expect(abs(bounds.minX - 100) <= 1, "size \(size): \(bounds)")
            #expect(abs(bounds.height - points) <= 2, "size \(size): \(bounds)")
            #expect(abs(bounds.width - points) <= 2, "size \(size): \(bounds)")
            // Within the first line.
            #expect(bounds.minY >= 100 && bounds.maxY <= 100 + points * 1.4, "size \(size): \(bounds)")
        }
    }

    @Test("Picture bullets are kept when the file is saved and read again")
    func saved() throws {
        let blank = try PPTXWriter.data(from: Presentation.blank)
        var entries = try ZipArchive.orderedEntries(in: blank)
        let slide = try #require(entries.firstIndex { $0.path == "ppt/slides/slide1.xml" })
        let source = try #require(String(data: entries[slide].data, encoding: .utf8))
        let tree = try shape(size: 2_400)
        let sp = try #require(tree.source)
        let marker = "</p:spTree>"
        let edited = source.replacingOccurrences(of: marker, with: sp + marker)
        #expect(edited != source)
        entries[slide].data = Data(edited.utf8)
        let rels = try #require(entries.firstIndex { $0.path == "ppt/slides/_rels/slide1.xml.rels" })
        let relsSource = try #require(String(data: entries[rels].data, encoding: .utf8))
        entries[rels].data = Data(relsSource.replacingOccurrences(of: "</Relationships>", with:
            "<Relationship Id=\"rId9\" Type=\"\(OOXML.RelationshipType.image)\" Target=\"../media/bullet.png\"/></Relationships>").utf8)
        entries.append(("ppt/media/bullet.png", try Self.redSquare()))
        let types = try #require(entries.firstIndex { $0.path == "[Content_Types].xml" })
        let typesSource = try #require(String(data: entries[types].data, encoding: .utf8))
        if !typesSource.contains("Extension=\"png\"") {
            entries[types].data = Data(typesSource.replacingOccurrences(of: "<Default ", with:
                "<Default Extension=\"png\" ContentType=\"image/png\"/><Default ").utf8)
        }
        let read = try PPTXReader.presentation(from: ZipArchive.archive(entries: entries))
        func bullet(_ presentation: Presentation) -> Bullet? {
            presentation.slides[0].shapes.last?.text?.paragraphs.first?.properties.bullet
        }
        #expect(bullet(read) == .picture(path: "ppt/media/bullet.png"))

        // Edited and saved, the paragraph keeps its picture.
        var edited2 = read
        let index = try #require(edited2.slides[0].shapes.indices.last)
        edited2.slides[0].shapes[index].text?.paragraphs[0].properties.marginLeft = 228_600
        let again = try PPTXReader.presentation(from: PPTXWriter.data(from: edited2))
        #expect(bullet(again) == .picture(path: "ppt/media/bullet.png"))
        #expect(again.data(at: "ppt/media/bullet.png") != nil)
    }
}
