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

    // MARK: - Tables

    private static let rowIDs = ["1001", "1002"]
    private static let columnIDs = ["2001", "2002", "2003"]

    private func identified(_ name: String, _ value: String) -> String {
        let uri = name == "rowId" ? "{0D108BD9-81ED-4DB2-BD59-A6C34878D82A}" : "{9D8B030D-6E8A-4147-A177-3AD203B41FA5}"
        return "<a:extLst><a:ext uri=\"\(uri)\"><a16:\(name) xmlns:a16=\"http://schemas.microsoft.com/office/drawing/2014/main\" "
            + "val=\"\(value)\"/></a:ext></a:extLst>"
    }

    private func cell(_ text: String, fill: String) -> String {
        "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(text)</a:t></a:r></a:p></a:txBody>"
            + "<a:tcPr marL=\"91440\">\(fill)</a:tcPr></a:tc>"
    }

    private var tableXML: String {
        let gradient = """
            <a:gradFill flip="y" rotWithShape="0"><a:gsLst><a:gs pos="0"><a:srgbClr val="00FF00"/></a:gs>\
            <a:gs pos="100000"><a:srgbClr val="FFFF00"/></a:gs></a:gsLst><a:lin ang="0" scaled="1"/><a:tileRect/></a:gradFill>
            """
        let solid = "<a:solidFill><a:schemeClr val=\"accent2\"><a:lumMod val=\"60000\"/></a:schemeClr></a:solidFill>"
        let columns = Self.columnIDs.map { "<a:gridCol w=\"3000000\">\(identified("colId", $0))</a:gridCol>" }.joined()
        let rows = Self.rowIDs.enumerated().map { row, id in
            "<a:tr h=\"370840\">" + (0..<3).map { cell("R\(row)C\($0)", fill: $0 == 1 ? gradient : solid) }.joined()
                + identified("rowId", id) + "</a:tr>"
        }.joined()
        return """
            <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
            <p:xfrm><a:off x="0" y="0"/><a:ext cx="9000000" cy="741680"/></p:xfrm>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>\
            <a:tblPr firstRow="1"/><a:tblGrid>\(columns)</a:tblGrid>\(rows)</a:tbl></a:graphicData></a:graphic></p:graphicFrame>
            """
    }

    private func identifier(of element: XMLElement, _ name: String) -> String? {
        element.firstChild(named: "extLst")?.children(named: "ext").lazy.compactMap { $0.firstChild(named: name) }.first?.attribute("val")
    }

    private func grid(of shape: SlideShape) throws -> XMLElement {
        try #require(try element(of: shape).firstDescendant(atPath: "graphic/graphicData/tbl"))
    }

    @Test("Editing a table keeps its rows' and columns' IDs and its untouched cells' fills")
    func editedTable() throws {
        var shape = try shape(tableXML)
        let before = try grid(of: shape)
        guard case .table(var model) = shape.kind else { Issue.record("not a table"); return }
        model.rows[0].cells[0].text = TextBody(paragraphs: [Paragraph(runs: [TextRun(text: "Edited")])])
        model.insertRow(at: 1, copying: 0)
        model.deleteColumn(at: 2)
        shape.kind = .table(model)
        shape.edits.insert(.table)
        let after = try grid(of: saved(shape))

        let columns = try #require(after.firstChild(named: "tblGrid")).children(named: "gridCol")
        #expect(columns.map { identifier(of: $0, "colId") } == ["2001", "2002"])
        let rows = after.children(named: "tr")
        try #require(rows.count == 3)
        #expect(identifier(of: rows[0], "rowId") == "1001")
        #expect(identifier(of: rows[2], "rowId") == "1002")
        #expect(identifier(of: rows[1], "rowId").map { !Self.rowIDs.contains($0) } == true)

        let sourceRows = before.children(named: "tr")
        let edited = rows[0].children(named: "tc")
        #expect(edited.count == 2)
        #expect(edited.first?.firstChild(named: "txBody")?.firstChild(named: "p")?.firstChild(named: "r")?
            .firstChild(named: "t")?.text == "Edited")
        // The edited cell's fill, and every cell of the row left alone, are as the file had them.
        #expect(canonical(edited[0].firstChild(named: "tcPr")) == canonical(sourceRows[0].children(named: "tc")[0].firstChild(named: "tcPr")))
        #expect(canonical(edited[1]) == canonical(sourceRows[0].children(named: "tc")[1]))
        let untouched = rows[2].children(named: "tc")
        #expect(untouched.count == 2)
        for column in 0..<2 {
            #expect(canonical(untouched[column]) == canonical(sourceRows[1].children(named: "tc")[column]))
        }
        let gradient = try #require(untouched[1].firstDescendant(atPath: "tcPr/gradFill"))
        #expect(gradient.attribute("flip") == "y")
        #expect(gradient.attribute("rotWithShape") == "0")
    }

    @Test("A column added to a table with column IDs gets an ID of its own")
    func addedColumn() throws {
        var shape = try shape(tableXML)
        guard case .table(var model) = shape.kind else { Issue.record("not a table"); return }
        model.insertColumn(at: 0, copying: 0)
        shape.kind = .table(model)
        shape.edits.insert(.table)
        let columns = try #require(try grid(of: saved(shape)).firstChild(named: "tblGrid")).children(named: "gridCol")
        let ids = columns.map { identifier(of: $0, "colId") }
        #expect(Array(ids.dropFirst()) == Self.columnIDs)
        let added = try #require(ids.first ?? nil)
        #expect(!Self.columnIDs.contains(added))
    }
}
