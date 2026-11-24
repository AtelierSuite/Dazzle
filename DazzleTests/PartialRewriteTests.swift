@testable import DazzleEngine
import Foundation
import Testing

/// Editing part of a line or a table leaves the rest of its XML as the file had it.
@Suite("Partial rewrites")
struct PartialRewriteTests {
    private static let header = """
        <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        """

    private func shape(_ xml: String) throws -> SlideShape {
        let root = try XMLLite.parse(Data((Self.header + xml + "</p:spTree>").utf8))
        return try #require(ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                                        parts: [:], capturesSource: true).shapes(in: root).first)
    }

    private func saved(_ shape: SlideShape) throws -> SlideShape {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [shape]
        presentation.slides[0].isModified = true
        let reread = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        return try #require(reread.slides[0].shapes.first)
    }

    private func element(of shape: SlideShape) throws -> XMLElement {
        try XMLLite.parse(Data(try #require(shape.source).utf8))
    }

    /// An element's name, attributes and children, independent of attribute order.
    private func canonical(_ element: XMLElement?) -> String {
        guard let element else { return "" }
        let attributes = element.qualifiedAttributes.filter { !$0.key.hasPrefix("xmlns") }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "<\(element.name) \(attributes.joined(separator: " "))>"
            + element.children.map(canonical).joined() + element.text + "</\(element.name)>"
    }

    // MARK: - Outlines

    private static let gradientOutline = """
        <a:gradFill flip="x" rotWithShape="0"><a:gsLst><a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs>\
        <a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill>
        """

    private func outlined(_ fill: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\
        <a:xfrm><a:off x="0" y="0"/><a:ext cx="1000000" cy="1000000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
        <a:ln w="12700">\(fill)<a:prstDash val="solid"/></a:ln></p:spPr></p:sp>
        """
    }

    @Test("Changing an outline's width keeps its gradient as the file had it")
    func outlineGradient() throws {
        var shape = try shape(outlined(Self.gradientOutline))
        let before = try element(of: shape).firstDescendant(atPath: "spPr/ln/gradFill")
        shape.line?.width = 38_100
        shape.edits.insert(.line)
        let after = try element(of: saved(shape))
        #expect(after.firstDescendant(atPath: "spPr/ln")?.attribute("w") == "38100")
        let gradient = try #require(after.firstDescendant(atPath: "spPr/ln/gradFill"))
        #expect(gradient.attribute("flip") == "x")
        #expect(gradient.attribute("rotWithShape") == "0")
        #expect(canonical(gradient) == canonical(before))
    }

    @Test("Changing an outline's gradient keeps its flip and rotWithShape")
    func editedOutlineGradient() throws {
        var shape = try shape(outlined(Self.gradientOutline))
        guard case .gradient(var gradient) = shape.line?.fill else { Issue.record("not a gradient"); return }
        gradient.angle = 45
        shape.line?.fill = .gradient(gradient)
        shape.edits.insert(.line)
        let written = try #require(try element(of: saved(shape)).firstDescendant(atPath: "spPr/ln/gradFill"))
        #expect(written.attribute("flip") == "x")
        #expect(written.attribute("rotWithShape") == "0")
        #expect(written.firstChild(named: "lin")?.attribute("ang") == "2700000")
    }

    @Test("Changing a picture-filled outline's dash keeps its picture")
    func outlinePicture() throws {
        var shape = try shape(outlined("<a:blipFill><a:blip r:embed=\"rId9\"/><a:stretch><a:fillRect/></a:stretch></a:blipFill>"))
        shape.line?.dash = "dash"
        shape.edits.insert(.line)
        let outline = try #require(try element(of: saved(shape)).firstDescendant(atPath: "spPr/ln"))
        #expect(outline.firstChild(named: "blipFill") != nil)
        #expect(outline.firstChild(named: "noFill") == nil)
        #expect(outline.firstChild(named: "prstDash")?.attribute("val") == "dash")
    }
}
