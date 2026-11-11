@testable import DazzleEngine
import Foundation
import Testing

/// SmartArt saved without a drawing of itself, as other apps and older
/// files leave it, laid out from its data.
@Suite("SmartArt layout")
struct SmartArtLayoutTests {
    private static let diagramNamespace = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    private static let frame = EMURect(x: 838_200, y: 1_143_000, width: 10_515_600, height: 5_257_800)

    /// A point's text and the points below it.
    private struct Point {
        var text: String
        var children: [Point] = []
    }

    private static func dataModel(_ layout: String, _ points: [Point], drawing: Bool = false, ownFill: String? = nil) -> String {
        var id = 0
        var elements = [
            #"<dgm:pt modelId="{doc}" type="doc"><dgm:prSet loTypeId="urn:microsoft.com/office/officeart/2005/8/layout/\#(layout)"/>"#
                + "<dgm:spPr/><dgm:t><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></dgm:t></dgm:pt>",
        ]
        var connections: [String] = []
        func add(_ points: [Point], under parent: String) {
            for (order, point) in points.enumerated() {
                id += 1
                let me = "{n\(id)}"
                let fill = id == 1 ? ownFill.map { "<a:solidFill><a:srgbClr val=\"\($0)\"/></a:solidFill>" } ?? "" : ""
                elements.append(
                    "<dgm:pt modelId=\"\(me)\"><dgm:prSet/><dgm:spPr>\(fill)</dgm:spPr><dgm:t><a:bodyPr/><a:lstStyle/><a:p><a:r>"
                        + "<a:rPr lang=\"en-US\"/><a:t>\(point.text)</a:t></a:r></a:p></dgm:t></dgm:pt>"
                )
                elements.append("<dgm:pt modelId=\"{p\(id)}\" type=\"parTrans\" cxnId=\"{c\(id)}\"><dgm:prSet/><dgm:spPr/></dgm:pt>")
                elements.append("<dgm:pt modelId=\"{s\(id)}\" type=\"sibTrans\" cxnId=\"{c\(id)}\"><dgm:prSet/><dgm:spPr/></dgm:pt>")
                // Presentation points and their connections are the layout's, and are not content.
                elements.append("<dgm:pt modelId=\"{pres\(id)}\" type=\"pres\"><dgm:prSet presAssocID=\"\(me)\" presName=\"node\"/><dgm:spPr/></dgm:pt>")
                connections.append(
                    "<dgm:cxn modelId=\"{c\(id)}\" srcId=\"\(parent)\" destId=\"\(me)\" srcOrd=\"\(order)\" destOrd=\"0\" "
                        + "parTransId=\"{p\(id)}\" sibTransId=\"{s\(id)}\"/>"
                )
                connections.append("<dgm:cxn modelId=\"{x\(id)}\" type=\"presOf\" srcId=\"\(me)\" destId=\"{pres\(id)}\" srcOrd=\"0\" destOrd=\"0\"/>")
                add(point.children, under: me)
            }
        }
        add(points, under: "{doc}")
        let ext = drawing
            ? "<dgm:extLst><a:ext uri=\"http://schemas.microsoft.com/office/drawing/2008/diagram\"><dsp:dataModelExt "
                + "xmlns:dsp=\"http://schemas.microsoft.com/office/drawing/2008/diagram\" relId=\"rIdDr\"/></a:ext></dgm:extLst>"
            : ""
        return "<dgm:dataModel xmlns:dgm=\"\(diagramNamespace)\" xmlns:a=\"\(OOXML.drawingML)\"><dgm:ptLst>\(elements.joined())</dgm:ptLst>"
            + "<dgm:cxnLst>\(connections.joined())</dgm:cxnLst><dgm:bg/><dgm:whole/>\(ext)</dgm:dataModel>"
    }

    private static func colors(_ nodeFills: [String]) -> String {
        let fills = nodeFills.map { "<a:schemeClr val=\"\($0)\"/>" }.joined()
        return "<dgm:colorsDef xmlns:dgm=\"\(diagramNamespace)\" xmlns:a=\"\(OOXML.drawingML)\" uniqueId=\"urn:test/colors\">"
            + "<dgm:styleLbl name=\"node1\"><dgm:fillClrLst meth=\"repeat\">\(fills)</dgm:fillClrLst>"
            + "<dgm:linClrLst meth=\"repeat\"><a:schemeClr val=\"lt1\"/></dgm:linClrLst><dgm:txFillClrLst/></dgm:styleLbl>"
            + "</dgm:colorsDef>"
    }

    private static let style = """
        <dgm:styleDef xmlns:dgm="\(diagramNamespace)" xmlns:a="\(OOXML.drawingML)" uniqueId="urn:test/style">\
        <dgm:styleLbl name="node1"><dgm:style><a:lnRef idx="2"><a:scrgbClr r="0" g="0" b="0"/></a:lnRef>\
        <a:fillRef idx="1"><a:scrgbClr r="0" g="0" b="0"/></a:fillRef><a:effectRef idx="0"><a:scrgbClr r="0" g="0" b="0"/></a:effectRef>\
        <a:fontRef idx="minor"><a:schemeClr val="lt2"/></a:fontRef></dgm:style></dgm:styleLbl></dgm:styleDef>
        """

    private static let drawing = """
        <dsp:drawing xmlns:dsp="http://schemas.microsoft.com/office/drawing/2008/diagram" xmlns:a="\(OOXML.drawingML)"><dsp:spTree>\
        <dsp:nvGrpSpPr><dsp:cNvPr id="0" name=""/><dsp:cNvGrpSpPr/></dsp:nvGrpSpPr><dsp:grpSpPr/>\
        <dsp:sp modelId="{d}"><dsp:nvSpPr><dsp:cNvPr id="0" name=""/><dsp:cNvSpPr/></dsp:nvSpPr><dsp:spPr><a:xfrm><a:off x="0" y="0"/>\
        <a:ext cx="100" cy="100"/></a:xfrm><a:prstGeom prst="snip1Rect"><a:avLst/></a:prstGeom></dsp:spPr><dsp:txBody><a:bodyPr/>\
        <a:p><a:r><a:t>Drawn</a:t></a:r></a:p></dsp:txBody></dsp:sp></dsp:spTree></dsp:drawing>
        """

    /// The template deck with one SmartArt on its slide, and the parts that make it.
    private static func parts(
        _ layout: String, _ points: [Point], nodeFills: [String] = ["accent1"], drawing: Bool = false,
        ownFill: String? = nil, layoutPart: Bool = true
    ) -> [String: Data] {
        var parts = PresentationTemplate.parts()
        let slide = "ppt/slides/slide1.xml"
        let frame = """
            <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="91" name="Diagram"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
            <p:xfrm><a:off x="\(Self.frame.x)" y="\(Self.frame.y)"/><a:ext cx="\(Self.frame.width)" cy="\(Self.frame.height)"/></p:xfrm>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram"><dgm:relIds \
            xmlns:dgm="\(diagramNamespace)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            r:dm="rIdDm" r:lo="rIdLo" r:qs="rIdQs" r:cs="rIdCs"/></a:graphicData></a:graphic></p:graphicFrame>
            """
        parts[slide] = Data(String(decoding: parts[slide]!, as: UTF8.self).replacingOccurrences(of: "</p:spTree>", with: frame + "</p:spTree>").utf8)
        let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let slideRels = "ppt/slides/_rels/slide1.xml.rels"
        var relationships = Relationship.parse(parts[slideRels])
        relationships += [
            Relationship(id: "rIdDm", type: base + "diagramData", target: "../diagrams/data1.xml"),
            Relationship(id: "rIdLo", type: base + "diagramLayout", target: "../diagrams/layout1.xml"),
            Relationship(id: "rIdQs", type: base + "diagramQuickStyle", target: "../diagrams/quickStyle1.xml"),
            Relationship(id: "rIdCs", type: base + "diagramColors", target: "../diagrams/colors1.xml"),
        ]
        if drawing {
            relationships.append(Relationship(id: "rIdDr", type: OOXML.RelationshipType.diagramDrawing, target: "../diagrams/drawing1.xml"))
            parts["ppt/diagrams/drawing1.xml"] = Data(Self.drawing.utf8)
        }
        parts[slideRels] = Relationship.xml(relationships)
        parts["ppt/diagrams/data1.xml"] = Data(dataModel(layout, points, drawing: drawing, ownFill: ownFill).utf8)
        if layoutPart {
            parts["ppt/diagrams/layout1.xml"] = Data("""
                <dgm:layoutDef xmlns:dgm="\(diagramNamespace)" uniqueId="urn:microsoft.com/office/officeart/2005/8/layout/\(layout)"/>
                """.utf8)
        }
        parts["ppt/diagrams/quickStyle1.xml"] = Data(style.utf8)
        parts["ppt/diagrams/colors1.xml"] = Data(colors(nodeFills).utf8)
        return parts
    }

    private static func members(_ presentation: Presentation) throws -> [SlideShape] {
        let shape = try #require(presentation.slides[0].shapes.first { $0.name == "Diagram" })
        guard case .diagram(let members) = shape.kind else {
            Issue.record("Expected a diagram, got \(shape.kind)")
            return []
        }
        return members
    }

    private static func texts(_ members: [SlideShape]) -> [String] {
        members.compactMap { $0.text?.plainText }.flatMap { $0.components(separatedBy: "\n") }
    }

    private static let three = [Point(text: "One"), Point(text: "Two"), Point(text: "Three")]

    @Test("Layout ids choose their family")
    func families() {
        let prefix = "urn:microsoft.com/office/officeart/2005/8/layout/"
        let expected: [String: DiagramLayout.Family] = [
            "default": .blockList, "vList2": .verticalList, "hList1": .horizontalList, "process1": .process(vertical: false),
            "process2": .process(vertical: true), "hProcess9": .continuousProcess, "chevron1": .chevron, "hChevron3": .chevron,
            "cycle2": .cycle, "cycle1": .cycle, "hierarchy1": .hierarchy, "orgChart1": .hierarchy, "pyramid1": .pyramid,
            "radial1": .radial, "venn1": .venn(linear: false), "venn3": .venn(linear: true), "matrix3": .matrix, "gear1": .blockList,
        ]
        for (name, family) in expected {
            #expect(DiagramLayout.Family(layoutID: prefix + name) == family, "\(name)")
        }
        #expect(DiagramLayout.Family(layoutID: "urn:microsoft.com/office/officeart/2008/layout/NameandTitleOrganizationalChart") == .hierarchy)
        #expect(DiagramLayout.Family(layoutID: nil) == .blockList)
    }

    @Test("A basic process is laid out as boxes in order with arrows between them, in the colours part's colours")
    func process() throws {
        let presentation = try PPTXReader.presentation(fromParts: Self.parts("process1", Self.three))
        let members = try Self.members(presentation)
        let boxes = members.filter { $0.text != nil }
        let arrows = members.filter { $0.geometry.presetName == "rightArrow" }
        #expect(boxes.map { $0.text?.plainText } == ["One", "Two", "Three"])
        #expect(arrows.count == 2)
        #expect(boxes.map(\.frame.x) == boxes.map(\.frame.x).sorted())
        #expect(boxes.allSatisfy { $0.fill == .solid(.scheme("accent1")) })
        #expect(boxes.allSatisfy { $0.line?.fill == .solid(.scheme("lt1")) })
        // Text takes the style part's font colour, the colours part leaving it unsaid, and is set at one size.
        #expect(boxes.allSatisfy { $0.style?.fontColor == .scheme("lt2") })
        #expect(Set(boxes.compactMap { $0.text?.paragraphs.first?.runs.first?.properties.size }).count == 1)
        #expect(members.allSatisfy { Self.frame.contains($0.frame) })
    }

    @Test("Every family lays out every point inside the frame")
    func everyFamily() throws {
        let nested = [Point(text: "Top", children: [Point(text: "Left", children: [Point(text: "Leaf")]), Point(text: "Right")])]
        let bulleted = [Point(text: "One", children: [Point(text: "Sub one")]), Point(text: "Two", children: [Point(text: "Sub two")])]
        let cases: [(String, [Point], [String])] = [
            ("default", Self.three, ["One", "Two", "Three"]), ("vList2", bulleted, ["One", "Sub one", "Two", "Sub two"]),
            ("hList1", bulleted, ["One", "Sub one", "Two", "Sub two"]), ("process2", Self.three, ["One", "Two", "Three"]),
            ("hProcess9", Self.three, ["One", "Two", "Three"]), ("chevron1", Self.three, ["One", "Two", "Three"]),
            ("cycle2", Self.three, ["One", "Two", "Three"]), ("hierarchy1", nested, ["Top", "Left", "Leaf", "Right"]),
            ("orgChart1", nested, ["Top", "Left", "Leaf", "Right"]), ("pyramid1", Self.three, ["One", "Two", "Three"]),
            ("radial1", nested, ["Top", "Left", "Leaf", "Right"]), ("venn1", Self.three, ["One", "Two", "Three"]),
            ("venn3", Self.three, ["One", "Two", "Three"]), ("matrix3", Self.three, ["One", "Two", "Three"]),
            ("gear1", Self.three, ["One", "Two", "Three"]),
        ]
        for (layout, points, expected) in cases {
            let presentation = try PPTXReader.presentation(fromParts: Self.parts(layout, points))
            let members = try Self.members(presentation)
            #expect(Set(Self.texts(members)) == Set(expected), "\(layout)")
            for member in members where member.rotation == 0 {
                // A little room for rounding.
                #expect(Self.frame.insetBy(-2).contains(member.frame), "\(layout): \(member.frame)")
            }
        }
    }

    @Test("Hierarchies join each point to the points below it, and cycles point round the ring")
    func connections() throws {
        let tree = [Point(text: "Top", children: [Point(text: "A"), Point(text: "B"), Point(text: "C")])]
        let hierarchy = try Self.members(PPTXReader.presentation(fromParts: Self.parts("hierarchy1", tree)))
        let lines = hierarchy.filter { $0.kind == .connector }
        // Down from the top, across, and down to each of three.
        #expect(lines.count == 5)
        let top = try #require(hierarchy.first { $0.text?.plainText == "Top" })
        #expect(hierarchy.filter { $0.text != nil && $0.text?.plainText != "Top" }.allSatisfy { $0.frame.y > top.frame.y + top.frame.height })

        let cycle = try Self.members(PPTXReader.presentation(fromParts: Self.parts("cycle2", Self.three)))
        let arrows = cycle.filter { $0.geometry.presetName == "rightArrow" }
        #expect(arrows.count == 3)
        #expect(arrows.map { Int($0.rotation.rounded()) } == [60, 180, 300])
    }

    @Test("A colourful colour set paints points in turn, and a point's own fill wins")
    func colours() throws {
        let points = [Point(text: "A"), Point(text: "B"), Point(text: "C")]
        let colourful = try Self.members(PPTXReader.presentation(fromParts: Self.parts("default", points, nodeFills: ["accent2", "accent3"])))
        #expect(colourful.map(\.fill) == [.solid(.scheme("accent2")), .solid(.scheme("accent3")), .solid(.scheme("accent2"))])

        let own = try Self.members(PPTXReader.presentation(fromParts: Self.parts("default", points, ownFill: "FF0000")))
        #expect(own.map(\.fill) == [.solid(.rgb(0xFF0000)), .solid(.scheme("accent1")), .solid(.scheme("accent1"))])
    }

    @Test("Without a layout part, the data model's layout id chooses")
    func layoutFromData() throws {
        let members = try Self.members(PPTXReader.presentation(fromParts: Self.parts("cycle2", Self.three, layoutPart: false)))
        #expect(members.filter { $0.geometry.presetName == "ellipse" }.count == 3)
    }

    @Test("PowerPoint's own drawing is shown when there is one")
    func drawing() throws {
        let members = try Self.members(PPTXReader.presentation(fromParts: Self.parts("process1", Self.three, drawing: true)))
        #expect(members.count == 1)
        #expect(members.first?.geometry.presetName == "snip1Rect")
        #expect(members.first?.text?.plainText == "Drawn")
    }

    @Test("SmartArt with no points is a stand-in")
    func empty() throws {
        let presentation = try PPTXReader.presentation(fromParts: Self.parts("default", []))
        let shape = try #require(presentation.slides[0].shapes.first { $0.name == "Diagram" })
        guard case .unsupported = shape.kind else {
            Issue.record("Expected a stand-in")
            return
        }
    }

    @Test("Laid-out SmartArt saves back its parts unchanged, and is laid out again when reopened")
    func saving() throws {
        let parts = Self.parts("hierarchy1", [Point(text: "Top", children: [Point(text: "A")])])
        var presentation = try PPTXReader.presentation(fromParts: parts)
        // An edit elsewhere on the slide makes it be written anew.
        let title = try #require(presentation.slides[0].shapes.firstIndex { $0.placeholder != nil })
        presentation.slides[0].shapes[title].frame.x += 12_700
        presentation.slides[0].shapes[title].edits.insert(.transform)
        presentation.slides[0].isModified = true

        let saved = try ZipArchive.entries(in: PPTXWriter.data(from: presentation))
        for name in ["data1", "layout1", "quickStyle1", "colors1"] {
            #expect(saved["ppt/diagrams/\(name).xml"] == parts["ppt/diagrams/\(name).xml"], "\(name)")
        }
        #expect(saved["ppt/diagrams/drawing1.xml"] == nil, "no drawing is made up")
        let slide = String(decoding: try #require(saved["ppt/slides/slide1.xml"]), as: UTF8.self)
        #expect(slide.components(separatedBy: "<p:graphicFrame>").count == 2, "just the one frame, and no laid-out shapes")
        #expect(slide.contains("r:dm=\"rIdDm\""))
        #expect(!slide.contains(">Top<"))

        let reopened = try PPTXReader.presentation(fromParts: saved)
        #expect(Set(Self.texts(try Self.members(reopened))) == ["Top", "A"])
    }
}

private extension EMURect {
    func contains(_ other: EMURect) -> Bool {
        other.x >= x && other.y >= y && other.x + other.width <= x + width && other.y + other.height <= y + height
    }

    func insetBy(_ amount: Int) -> EMURect {
        EMURect(x: x + amount, y: y + amount, width: width - 2 * amount, height: height - 2 * amount)
    }
}
