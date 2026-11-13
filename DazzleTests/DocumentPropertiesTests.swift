@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Document properties")
@MainActor
struct DocumentPropertiesTests {
    private static let core = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>Quarterly Review</dc:title><dc:subject>Numbers</dc:subject><dc:creator>Ada Lovelace</dc:creator>\
        <cp:keywords>plans, budget</cp:keywords><dc:description>First draft</dc:description>\
        <cp:lastModifiedBy>Charles Babbage</cp:lastModifiedBy><cp:revision>7</cp:revision>\
        <dcterms:created xsi:type="dcterms:W3CDTF">2024-03-01T09:30:00Z</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">2024-04-02T17:45:10Z</dcterms:modified>\
        <cp:category>Finance</cp:category><cp:contentStatus>Draft</cp:contentStatus></cp:coreProperties>
        """
    private static let app = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
        <TotalTime>12</TotalTime><Application>Microsoft Office PowerPoint</Application><Slides>9</Slides>\
        <Notes>0</Notes><HiddenSlides>0</HiddenSlides><Company>Analytical Engines</Company><AppVersion>16.0000</AppVersion></Properties>
        """

    /// The blank presentation, with `core.xml` and `app.xml` as PowerPoint writes them.
    private func deck() throws -> Presentation {
        var parts = try ZipArchive.entries(in: PPTXWriter.data(from: .blank))
        parts["docProps/core.xml"] = Data(Self.core.utf8)
        parts["docProps/app.xml"] = Data(Self.app.utf8)
        var relationships = Relationship.parse(parts["_rels/.rels"])
        relationships.append(Relationship(id: "rIdCore", type: DocumentPropertiesXML.coreRelationship, target: "docProps/core.xml"))
        relationships.append(Relationship(id: "rIdApp", type: DocumentPropertiesXML.extendedRelationship, target: "docProps/app.xml"))
        parts["_rels/.rels"] = Relationship.xml(relationships)
        return try PPTXReader.presentation(fromParts: parts)
    }

    private func text(_ data: Data, _ path: String) throws -> String {
        try String(decoding: #require(ZipArchive.entries(in: data)[path]), as: UTF8.self)
    }

    @Test("core.xml and app.xml are read")
    func reading() throws {
        let properties = try deck().properties
        #expect(properties.title == "Quarterly Review")
        #expect(properties.subject == "Numbers")
        #expect(properties.author == "Ada Lovelace")
        #expect(properties.keywords == "plans, budget")
        #expect(properties.category == "Finance")
        #expect(properties.comments == "First draft")
        #expect(properties.lastModifiedBy == "Charles Babbage")
        #expect(properties.revision == 7)
        #expect(properties.created == DocumentPropertiesXML.date("2024-03-01T09:30:00Z"))
        #expect(properties.modified.map(DocumentPropertiesXML.string) == "2024-04-02T17:45:10Z")
        #expect(properties.company == "Analytical Engines")
        #expect(properties.applicationDescription == "Microsoft Office PowerPoint 16.0000")
    }

    @Test("A file saved without changes keeps its properties byte for byte")
    func untouched() throws {
        let presentation = try deck()
        let saved = try PPTXWriter.data(from: presentation)
        #expect(try text(saved, "docProps/core.xml") == Self.core)
        #expect(try text(saved, "docProps/app.xml") == Self.app)
    }

    @Test("Edits are written, and saving moves on the date, the last author and the revision")
    func saving() throws {
        var presentation = try deck()
        let state = EditorState()
        state.setProperty(.title, to: "Annual <Review> & plans", in: &presentation)
        state.setProperty(.subject, to: "", in: &presentation)
        state.setProperty(.comments, to: "Line one\nLine two", in: &presentation)
        state.setProperty(.company, to: "Difference Ltd", in: &presentation)
        state.setProperty(.category, to: "Planning", in: &presentation)
        #expect(presentation.arePropertiesModified)
        let now = try #require(DocumentPropertiesXML.date("2026-11-13T08:00:00Z"))
        let saved = try PPTXWriter.data(from: presentation.stampedForSaving(by: "  Grace Hopper ", at: now))

        let core = try text(saved, "docProps/core.xml")
        #expect(core.contains("<dc:title>Annual &lt;Review&gt; &amp; plans</dc:title>"))
        #expect(!core.contains("subject"), "an emptied property is removed")
        #expect(core.contains("<cp:lastModifiedBy>Grace Hopper</cp:lastModifiedBy>"))
        #expect(core.contains("<cp:revision>8</cp:revision>"))
        #expect(core.contains("<dcterms:modified xsi:type=\"dcterms:W3CDTF\">2026-11-13T08:00:00Z</dcterms:modified>"))
        #expect(core.contains("<dcterms:created xsi:type=\"dcterms:W3CDTF\">2024-03-01T09:30:00Z</dcterms:created>"))
        #expect(core.contains("<cp:contentStatus>Draft</cp:contentStatus>"), "what Dazzle doesn't edit is kept")
        let app = try text(saved, "docProps/app.xml")
        #expect(app.contains("<Company>Difference Ltd</Company>"))
        #expect(app.contains("<Slides>1</Slides>"), "the slide count is brought up to date")
        #expect(app.contains("<TotalTime>12</TotalTime>"))

        let reopened = try PPTXReader.presentation(from: saved).properties
        #expect(reopened.title == "Annual <Review> & plans")
        #expect(reopened.subject.isEmpty)
        #expect(reopened.comments == "Line one\nLine two")
        #expect(reopened.category == "Planning")
        #expect(reopened.author == "Ada Lovelace")
        #expect(reopened.lastModifiedBy == "Grace Hopper")
        #expect(reopened.modified == now)
        #expect(reopened.revision == 8)
    }

    @Test("Each save moves the revision on, starting from a file that has none")
    func revisions() throws {
        var presentation = Presentation.blank
        #expect(presentation.properties.revision == nil)
        for expected in 1...3 {
            let saved = try PPTXWriter.data(from: presentation.stampedForSaving(by: "Grace"))
            presentation = try PPTXReader.presentation(from: saved)
            #expect(presentation.properties.revision == expected)
            #expect(try text(saved, "docProps/core.xml").contains("<cp:revision>\(expected)</cp:revision>"))
        }
    }

    @Test("Saving with no name keeps the last author")
    func anonymous() throws {
        let saved = try PPTXWriter.data(from: deck().stampedForSaving(by: nil))
        #expect(try PPTXReader.presentation(from: saved).properties.lastModifiedBy == "Charles Babbage")
    }

    @Test("A file without properties gets them on save")
    func created() throws {
        var presentation = Presentation.blank
        #expect(presentation.properties == DocumentProperties())
        EditorState().setProperty(.author, to: "Ada", in: &presentation)
        let saved = try PPTXWriter.data(from: presentation.stampedForSaving(by: "Grace"))
        let parts = try ZipArchive.entries(in: saved)
        let paths = DocumentPropertiesXML.paths(in: parts)
        #expect(paths.core == "docProps/core.xml")
        #expect(paths.app == nil, "no company, so no extended properties")
        #expect(try text(saved, "[Content_Types].xml").contains(DocumentPropertiesXML.coreContentType))
        let reopened = try PPTXReader.presentation(from: saved).properties
        #expect(reopened.author == "Ada")
        #expect(reopened.lastModifiedBy == "Grace")
        #expect(reopened.revision == 1)
        #expect(reopened.modified != nil)
    }
}
