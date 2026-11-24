@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Chart workbooks")
@MainActor
struct ChartWorkbookTests {
    private let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private let relationshipBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    private func chart(in presentation: Presentation) throws -> Chart {
        guard case .chart(let chart?) = try #require(presentation.slides[0].shapes.last).kind else {
            throw Failure("Expected a chart")
        }
        return chart
    }

    struct Failure: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// A workbook as PowerPoint might keep one: the first series in column F
    /// with a formula in one of its cells, a helper column of formulas in B, a
    /// table over the data, a calculation chain and a second sheet.
    private func workbook(for chart: Chart, sharedStrings: Bool) throws -> Data {
        var strings: [String] = []
        func text(_ reference: String, _ value: String) -> String {
            guard sharedStrings else { return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(XMLLite.escape(value))</t></is></c>" }
            strings.append(value)
            return "<c r=\"\(reference)\" t=\"s\"><v>\(strings.count - 1)</v></c>"
        }
        let series = chart.allSeries
        var rows = ["<row r=\"1\" spans=\"1:6\">" + text("A1", " ") + text("B1", "Helper") + text("C1", series[1].name)
            + text("D1", series[2].name) + text("F1", series[0].name) + "</row>"]
        for (index, category) in chart.categories.enumerated() {
            let row = index + 2
            let first = series[0].values[index] ?? 0
            let value = row == 3 ? "<c r=\"F3\" s=\"1\"><f>1+1.5</f><v>\(Chart.number(first))</v></c>"
                : "<c r=\"F\(row)\" s=\"1\"><v>\(Chart.number(first))</v></c>"
            rows.append("<row r=\"\(row)\">" + text("A\(row)", category) + "<c r=\"B\(row)\"><f>F\(row)*10</f><v>\(Chart.number(first * 10))</v></c>"
                + "<c r=\"C\(row)\"><v>\(Chart.number(series[1].values[index] ?? 0))</v></c>"
                + "<c r=\"D\(row)\"><v>\(Chart.number(series[2].values[index] ?? 0))</v></c>" + value + "</row>")
        }
        let last = chart.categories.count + 1
        let sharedStringsXML = "<sst xmlns=\"\(main)\" count=\"\(strings.count)\" uniqueCount=\"\(strings.count)\">"
            + strings.map { "<si><t>\(XMLLite.escape($0))</t></si>" }.joined() + "</sst>"
        let chain = "<calcChain xmlns=\"\(main)\">" + (2...last).map { "<c r=\"B\($0)\" i=\"1\"/>" }.joined() + "<c r=\"F3\"/></calcChain>"
        var parts: [(path: String, data: String)] = [
            ("[Content_Types].xml", """
                <Types xmlns="\(OOXML.contentTypesNS)"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                <Override PartName="/xl/tables/table1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>\
                <Override PartName="/xl/calcChain.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/>\
                <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>
                """),
            ("_rels/.rels", """
                <Relationships xmlns="\(OOXML.packageRelationships)"><Relationship Id="rId1" \
                Type="\(OOXML.RelationshipType.officeDocument)" Target="xl/workbook.xml"/></Relationships>
                """),
            ("xl/workbook.xml", """
                <workbook xmlns="\(main)" xmlns:r="\(OOXML.relationshipsNS)"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/>\
                <sheet name="Notes" sheetId="2" r:id="rId2"/></sheets><calcPr calcId="191029"/></workbook>
                """),
            ("xl/_rels/workbook.xml.rels", """
                <Relationships xmlns="\(OOXML.packageRelationships)">\
                <Relationship Id="rId1" Type="\(relationshipBase)/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId2" Type="\(relationshipBase)/worksheet" Target="worksheets/sheet2.xml"/>\
                <Relationship Id="rId3" Type="\(relationshipBase)/calcChain" Target="calcChain.xml"/>\
                \(sharedStrings ? "<Relationship Id=\"rId4\" Type=\"\(relationshipBase)/sharedStrings\" Target=\"sharedStrings.xml\"/>" : "")\
                </Relationships>
                """),
            ("xl/worksheets/sheet1.xml", """
                <worksheet xmlns="\(main)" xmlns:r="\(OOXML.relationshipsNS)"><dimension ref="A1:F\(last)"/><sheetData>\(rows.joined())</sheetData>\
                <tableParts count="1"><tablePart r:id="rId1"/></tableParts></worksheet>
                """),
            ("xl/worksheets/_rels/sheet1.xml.rels", """
                <Relationships xmlns="\(OOXML.packageRelationships)">\
                <Relationship Id="rId1" Type="\(relationshipBase)/table" Target="../tables/table1.xml"/></Relationships>
                """),
            ("xl/tables/table1.xml", """
                <table xmlns="\(main)" id="1" name="Table1" displayName="Table1" ref="A1:F\(last)" totalsRowShown="0">\
                <tableColumns count="6"><tableColumn id="1" name=" "/><tableColumn id="2" name="Helper"/>\
                <tableColumn id="3" name="\(XMLLite.escape(series[1].name))"/><tableColumn id="4" name="\(XMLLite.escape(series[2].name))"/>\
                <tableColumn id="5" name="Spare"/><tableColumn id="6" name="\(XMLLite.escape(series[0].name))"/></tableColumns></table>
                """),
            ("xl/worksheets/sheet2.xml", """
                <worksheet xmlns="\(main)"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Keep me</t></is></c>\
                <c r="B1"><f>SUM(Sheet1!C2:C\(last))</f><v>0</v></c></row></sheetData></worksheet>
                """),
            ("xl/calcChain.xml", chain),
        ]
        if sharedStrings { parts.append(("xl/sharedStrings.xml", sharedStringsXML)) }
        return try ZipArchive.archive(entries: parts.map { ($0.path, Data((PackagePath.declaration + $0.data).utf8)) })
    }

    /// A chart PowerPoint saved, whose first series reads column F of a workbook with more in it than the chart shows.
    private func presentation(sharedStrings: Bool) throws -> (Presentation, workbook: String) {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertChart(.column, in: &presentation)
        let chart = try chart(in: presentation)
        let part = String(decoding: try #require(presentation.data(at: chart.path)), as: UTF8.self)
        presentation.addedParts[chart.path] = Data(part.replacingOccurrences(of: "$B$", with: "$F$").utf8)
        let path = try #require(ChartWriter.workbookPath(of: chart, in: presentation))
        presentation.addedParts[path] = try workbook(for: chart, sharedStrings: sharedStrings)
        return (try reread(presentation), path)
    }

    private func edit(_ presentation: inout Presentation, _ change: (inout Chart) -> Void) throws {
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.selectedShapeID = presentation.slides[0].shapes.last?.id
        state.updateChart(in: &presentation, change)
        presentation = try reread(presentation)
    }

    private func cell(_ reference: String, in sheet: Data?) throws -> XMLElement {
        let root = try XMLLite.parse(try #require(sheet))
        let cells = root.firstChild(named: "sheetData")?.children(named: "row").flatMap { $0.children(named: "c") } ?? []
        return try #require(cells.first { $0.attribute("r") == reference })
    }

    @Test("Editing a value patches only its cell, keeping other sheets, formulas, tables and the series' references",
          arguments: [true, false])
    func patchesCells(sharedStrings: Bool) throws {
        var (presentation, path) = try presentation(sharedStrings: sharedStrings)
        try edit(&presentation) { chart in
            chart.plots[0].series[0].values[1] = 7
            chart.plots[0].series[1].name = "Renamed"
        }

        let chart = try chart(in: presentation)
        #expect(chart.allSeries[0].values[1] == 7)
        #expect(chart.allSeries[1].name == "Renamed")
        let part = String(decoding: try #require(presentation.data(at: chart.path)), as: UTF8.self)
        #expect(part.contains("<c:f>Sheet1!$F$2:$F$5</c:f>"))
        #expect(part.contains("<c:f>Sheet1!$F$1</c:f>"))
        #expect(part.contains("<c:f>Sheet1!$C$1</c:f>"))
        #expect(!part.contains("Sheet1!$B$"))

        let entries = try ZipArchive.entries(in: try #require(presentation.data(at: path)))
        let sheet = entries["xl/worksheets/sheet1.xml"]
        let edited = try cell("F3", in: sheet)
        #expect(edited.firstChild(named: "f") == nil)
        #expect(edited.firstChild(named: "v")?.text == "7")
        #expect(edited.attribute("s") == "1")
        #expect(edited.attribute("t") == nil)
        #expect(try cell("B2", in: sheet).firstChild(named: "f")?.text == "F2*10")
        #expect(try cell("F2", in: sheet).firstChild(named: "v")?.text == "4.3")

        let name = try cell("C1", in: sheet)
        if sharedStrings {
            #expect(name.attribute("t") == "s")
            let strings = try XMLLite.parse(try #require(entries["xl/sharedStrings.xml"])).children(named: "si")
            let index = try #require(name.firstChild(named: "v").flatMap { Int($0.text) })
            #expect(strings[index].firstChild(named: "t")?.text == "Renamed")
            #expect(try cell("A1", in: sheet).attribute("t") == "s")
        } else {
            #expect(name.attribute("t") == "inlineStr")
            #expect(name.firstDescendant(atPath: "is/t")?.text == "Renamed")
        }
        let table = String(decoding: try #require(entries["xl/tables/table1.xml"]), as: UTF8.self)
        #expect(table.contains("name=\"Renamed\""))

        let notes = String(decoding: try #require(entries["xl/worksheets/sheet2.xml"]), as: UTF8.self)
        #expect(notes.contains("Keep me"))
        #expect(notes.contains("SUM(Sheet1!C2:C5)"))
        let workbook = String(decoding: try #require(entries["xl/workbook.xml"]), as: UTF8.self)
        #expect(workbook.contains("name=\"Notes\""))
        #expect(workbook.contains("fullCalcOnLoad=\"1\""))
        #expect(entries["xl/calcChain.xml"] == nil)
        let types = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
        #expect(!types.contains("calcChain"))
    }

    @Test("A chart whose data changed shape gets a workbook of its own, with references to match")
    func rebuildsWhenShapeChanges() throws {
        var (presentation, path) = try presentation(sharedStrings: true)
        try edit(&presentation) { chart in
            chart.categories.append("Extra")
            for index in chart.plots[0].series.indices { chart.plots[0].series[index].values.append(1) }
        }
        let chart = try chart(in: presentation)
        let part = String(decoding: try #require(presentation.data(at: chart.path)), as: UTF8.self)
        #expect(part.contains("<c:f>Sheet1!$B$2:$B$6</c:f>"))
        let entries = try ZipArchive.entries(in: try #require(presentation.data(at: path)))
        #expect(try cell("B6", in: entries["xl/worksheets/sheet1.xml"]).firstChild(named: "v")?.text == "1")
    }

    @Test("Editing only the title leaves the workbook as it was")
    func untouchedWorkbook() throws {
        var (presentation, path) = try presentation(sharedStrings: true)
        let before = presentation.data(at: path)
        try edit(&presentation) { $0.title = "New title" }
        #expect(presentation.data(at: path) == before)
    }
}
