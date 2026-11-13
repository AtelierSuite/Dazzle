import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

/// Chart parts of Office 2016's kinds, as PowerPoint writes them, and a deck
/// that shows one of each the way PowerPoint does: in an `mc:AlternateContent`
/// beside something for readers that don't know them.
enum ChartExFixture {
    static let namespace = "http://schemas.microsoft.com/office/drawing/2014/chartex"
    static let relationshipType = "http://schemas.microsoft.com/office/2014/relationships/chartEx"
    static let contentType = "application/vnd.ms-office.chartex+xml"

    /// A level of labels; an empty one is a point with no label there.
    static func level(_ labels: [String]) -> String {
        "<cx:lvl ptCount=\"\(labels.count)\">" + labels.enumerated().compactMap { index, label in
            label.isEmpty ? nil : "<cx:pt idx=\"\(index)\">\(label)</cx:pt>"
        }.joined() + "</cx:lvl>"
    }

    /// A block of data: labels level by level, the innermost first, and numbers of a `type`.
    static func data(_ id: Int, levels: [[String]] = [], _ values: [Double], type: String = "val") -> String {
        let labels = levels.isEmpty ? "" : "<cx:strDim type=\"cat\"><cx:f>Sheet1!$A$2:$A$\(values.count + 1)</cx:f>"
            + levels.map(level).joined() + "</cx:strDim>"
        return "<cx:data id=\"\(id)\">\(labels)<cx:numDim type=\"\(type)\"><cx:f>Sheet1!$B$2:$B$\(values.count + 1)</cx:f>"
            + "<cx:lvl ptCount=\"\(values.count)\" formatCode=\"General\">"
            + values.enumerated().map { "<cx:pt idx=\"\($0)\">\(Chart.number($1))</cx:pt>" }.joined() + "</cx:lvl></cx:numDim></cx:data>"
    }

    static func series(_ layout: String, _ name: String, data: Int = 0, attributes: String = "", labels: Bool = false, layoutProperties: String = "") -> String {
        "<cx:series layoutId=\"\(layout)\"\(attributes)><cx:tx><cx:txData><cx:f>Sheet1!$B$1</cx:f><cx:v>\(name)</cx:v></cx:txData></cx:tx>"
            + (labels ? "<cx:dataLabels><cx:visibility seriesName=\"0\" categoryName=\"0\" value=\"1\"/></cx:dataLabels>" : "")
            + "<cx:dataId val=\"\(data)\"/>" + (layoutProperties.isEmpty ? "" : "<cx:layoutPr>\(layoutProperties)</cx:layoutPr>") + "</cx:series>"
    }

    static let axes = """
        <cx:axis id="0"><cx:catScaling gapWidth="0.5"/><cx:tickLabels/></cx:axis>\
        <cx:axis id="1"><cx:valScaling/><cx:majorGridlines/><cx:tickLabels/></cx:axis>
        """

    static func part(data: String, series: String, axes: String = axes, title: String? = nil, legend: String? = "t") -> Data {
        let titleText = title.map { "<cx:tx><cx:txData><cx:v>\($0)</cx:v></cx:txData></cx:tx>" } ?? ""
        return Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cx:chartSpace xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:cx="\(namespace)">\
            <cx:chartData>\(data)</cx:chartData><cx:chart><cx:title pos="t" align="ctr" overlay="0">\(titleText)</cx:title>\
            <cx:plotArea><cx:plotAreaRegion>\(series)</cx:plotAreaRegion>\(axes)</cx:plotArea>\
            \(legend.map { "<cx:legend pos=\"\($0)\" align=\"ctr\" overlay=\"0\"/>" } ?? "")</cx:chart></cx:chartSpace>
            """.utf8)
    }

    static let waterfall = part(
        data: data(0, levels: [["Start", "Sales", "Returns", "Services", "Costs", "End"]], [120, 80, -30, 45, -60, 155]),
        series: series("waterfall", "Cash", labels: true, layoutProperties: "<cx:subtotals><cx:idx val=\"0\"/><cx:idx val=\"5\"/></cx:subtotals>"),
        title: "Cash flow"
    )

    static let funnel = part(
        data: data(0, levels: [["Leads", "Qualified", "Proposals", "Negotiation", "Won"]], [500, 420, 260, 140, 90]),
        series: series("funnel", "Pipeline", labels: true),
        axes: "<cx:axis id=\"0\"><cx:catScaling gapWidth=\"0.06\"/><cx:tickLabels/></cx:axis>", title: "Sales pipeline", legend: nil
    )

    static let leaves = ["Apples", "Pears", "Plums", "Carrots", "Leeks", "Peas", "Rice", "Oats"]
    static let branches = ["Fruit", "Fruit", "Fruit", "Vegetables", "Vegetables", "Vegetables", "Grains", "Grains"]

    static func treemap(parentLabels: String = "overlapping") -> Data {
        part(
            data: data(0, levels: [leaves, branches], [30, 12, 8, 25, 20, 15, 18, 6], type: "size"),
            series: series("treemap", "Stock", layoutProperties: "<cx:parentLabelLayout val=\"\(parentLabels)\"/>"), axes: "", title: "Stock by kind"
        )
    }

    /// Three levels, with two points that stop at the second.
    static let sunburst = part(
        data: data(0, levels: [
            ["Tokyo", "Osaka", "", "Seoul", "Busan", "Paris", "Lyon", ""],
            ["Japan", "Japan", "Taiwan", "Korea", "Korea", "France", "France", "Spain"],
            ["Asia", "Asia", "Asia", "Asia", "Asia", "Europe", "Europe", "Europe"],
        ], [40, 22, 18, 26, 9, 30, 12, 20], type: "size"),
        series: series("sunburst", "Visitors"), axes: "", title: "Visitors by place"
    )

    static let measurements: [Double] = [
        12, 15, 17, 18, 19, 21, 22, 22, 23, 24, 25, 25, 26, 26, 27, 27, 28, 28, 28, 29,
        29, 30, 30, 31, 31, 32, 33, 33, 34, 35, 36, 37, 38, 40, 41, 43, 45, 48, 52, 58,
    ]

    static func histogram(binning: String = "<cx:binning intervalClosed=\"r\"/>") -> Data {
        part(data: data(0, measurements), series: series("clusteredColumn", "Minutes", layoutProperties: binning),
             axes: axes.replacingOccurrences(of: "gapWidth=\"0.5\"", with: "gapWidth=\"0\""), title: "Time to finish", legend: nil)
    }

    /// Columns that add up each category's values, and the line a Pareto chart draws over them.
    static let pareto = part(
        data: data(0, levels: [["Late", "Damaged", "Wrong item", "Late", "Billing", "Damaged", "Late", "Other"]], [14, 9, 6, 21, 4, 8, 12, 3]),
        series: series("clusteredColumn", "Complaints", layoutProperties: "<cx:aggregation/>")
            + "<cx:series layoutId=\"paretoLine\" ownerIdx=\"0\"><cx:axisId val=\"2\"/></cx:series>",
        axes: axes + "<cx:axis id=\"2\"><cx:valScaling max=\"1\" min=\"0\"/><cx:units unit=\"percentage\"/><cx:tickLabels/></cx:axis>",
        title: "Complaints", legend: nil
    )

    static let boxWhisker: Data = {
        let classes = ["Maths", "Maths", "Maths", "Maths", "Maths", "Maths", "Art", "Art", "Art", "Art", "Art", "Art", "Music", "Music", "Music", "Music", "Music", "Music"]
        let layout = "<cx:visibility meanLine=\"0\" meanMarker=\"1\" nonoutliers=\"0\" outliers=\"1\"/><cx:statistics quartileMethod=\"exclusive\"/>"
        return part(
            data: data(0, levels: [classes], [52, 61, 64, 68, 73, 98, 70, 74, 77, 80, 84, 88, 45, 58, 63, 66, 71, 79])
                + data(1, levels: [classes], [48, 55, 60, 66, 70, 75, 62, 68, 72, 79, 85, 91, 20, 60, 64, 69, 72, 76]),
            series: series("boxWhisker", "Class A", layoutProperties: layout) + series("boxWhisker", "Class B", data: 1, layoutProperties: layout),
            title: "Marks by subject"
        )
    }()

    static var all: [(kind: Chart.Kind, data: Data)] {
        [(.waterfall, waterfall), (.funnel, funnel), (.treemap, treemap()), (.sunburst, sunburst), (.histogram, histogram()),
         (.pareto, pareto), (.boxWhisker, boxWhisker)]
    }

    /// A slide holding the chart at `relationship`, with the text box PowerPoint leaves for older readers.
    static func slide(relationship: String) -> String {
        let frame = "<a:off x=\"838200\" y=\"457200\"/><a:ext cx=\"10515600\" cy=\"5943600\"/>"
        return """
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/>\
            <p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\
            <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice \
            xmlns:cx1="http://schemas.microsoft.com/office/drawing/2015/9/8/chartex" Requires="cx1"><p:graphicFrame><p:nvGraphicFramePr>\
            <p:cNvPr id="4" name="Chart 3"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm>\(frame)</p:xfrm><a:graphic>\
            <a:graphicData uri="\(namespace)"><cx:chart xmlns:cx="\(namespace)" r:id="\(relationship)"/></a:graphicData></a:graphic>\
            </p:graphicFrame></mc:Choice><mc:Fallback><p:sp><p:nvSpPr><p:cNvPr id="4" name="Chart 3"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>\
            <p:spPr><a:xfrm>\(frame)</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>\
            <a:p><a:r><a:rPr lang="en-US"/><a:t>This chart isn't available in your version of PowerPoint.</a:t></a:r></a:p></p:txBody>\
            </p:sp></mc:Fallback></mc:AlternateContent></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
    }

    /// A deck with a slide for each of `charts`.
    static func deck(_ charts: [Data] = all.map(\.data)) throws -> Data {
        var media: [String: Data] = [:]
        var types: [String: String] = [:]
        let slides = charts.enumerated().map { index, chart in
            let path = "ppt/charts/chartEx\(index + 1).xml"
            media[path] = chart
            types[path] = contentType
            return PresentationTemplate.SlidePart(xml: slide(relationship: "rId2"), relationships: [
                Relationship(id: "rId1", type: OOXML.RelationshipType.slideLayout,
                             target: PresentationTemplate.relativeLayout(from: "ppt/slides/slide\(index + 1).xml")),
                Relationship(id: "rId2", type: relationshipType, target: "../charts/chartEx\(index + 1).xml"),
            ])
        }
        let parts = PresentationTemplate.parts(size: .widescreen, slides: slides, media: media, mediaTypes: types)
        return try ZipArchive.archive(entries: parts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }
}

@Suite("Office 2016 charts")
@MainActor
struct ChartExTests {
    private func chart(_ data: Data) throws -> Chart {
        try #require(Chart(path: "ppt/charts/chartEx1.xml", data: data))
    }

    private func draw(_ chart: Chart) -> RecordingCanvas {
        let canvas = RecordingCanvas()
        let presentation = Presentation.blank
        ChartPainter(chart: chart, style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]))
            .draw(in: CGRect(x: 0, y: 0, width: 600, height: 400), on: canvas)
        return canvas
    }

    private func legend(_ chart: Chart) -> [String] {
        let presentation = Presentation.blank
        return ChartPainter(chart: chart, style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]))
            .legendEntries().map(\.0)
    }

    @Test("Each kind is read as itself, with its title and legend")
    func kinds() throws {
        for (kind, data) in ChartExFixture.all {
            let chart = try chart(data)
            #expect(chart.kind == kind)
            #expect(kind.isExtended && !kind.label.isEmpty)
            #expect(chart.title?.isEmpty == false)
            #expect(chart.hasLegend == ![.funnel, .histogram, .pareto].contains(kind))
        }
        #expect(try chart(ChartExFixture.waterfall).legendPosition == "t")
        #expect(!Chart.Kind.insertable.contains { $0.isExtended })
    }

    @Test("A title with no text reads as Office's own")
    func defaultTitle() throws {
        let data = ChartExFixture.part(data: ChartExFixture.data(0, levels: [["A", "B"]], [1, 2]), series: ChartExFixture.series("funnel", "S"))
        #expect(try chart(data).title == String(localized: "Chart.Title.Default", bundle: .engine))
    }

    @Test("A kind Dazzle doesn't draw isn't read")
    func unknownKind() {
        let data = ChartExFixture.part(data: ChartExFixture.data(0, levels: [["A", "B"]], [1, 2]), series: ChartExFixture.series("regionMap", "S"))
        #expect(Chart(path: "ppt/charts/chartEx1.xml", data: data) == nil)
    }

    @Test("A waterfall's columns start where the last ended, and its totals stand from zero")
    func waterfall() throws {
        let chart = try chart(ChartExFixture.waterfall)
        #expect(chart.categories == ["Start", "Sales", "Returns", "Services", "Costs", "End"])
        #expect(chart.plots[0].extended.subtotals == [0, 5])
        #expect(chart.showsValueLabels && chart.showsGridlines)
        let bars = chart.waterfallBars().compactMap(\.self)
        #expect(bars.map(\.from) == [0, 120, 200, 170, 215, 0])
        #expect(bars.map(\.to) == [120, 200, 170, 215, 155, 155])
        #expect(bars.map(\.isTotal) == [true, false, false, false, false, true])
        #expect(legend(chart).count == 3)

        let canvas = draw(chart)
        // Three legend swatches and six columns, in three colours.
        #expect(canvas.rects.count == 9)
        #expect(Set(canvas.rects.suffix(6).map { "\($0.1)" }).count == 3)
        #expect(canvas.texts.contains("Returns") && canvas.texts.contains("-30"))
    }

    @Test("A funnel's bars are centred and as wide as their values")
    func funnel() throws {
        let chart = try chart(ChartExFixture.funnel)
        #expect(!chart.kind.hasAxes)
        #expect(legend(chart).isEmpty)
        let canvas = draw(chart)
        #expect(canvas.rects.count == 5)
        let widths = canvas.rects.map(\.0.width)
        #expect(widths == widths.sorted(by: >))
        #expect(abs(widths[4] / widths[0] - 90.0 / 500) < 0.001)
        #expect(Set(canvas.rects.map { ($0.0.midX * 100).rounded() }).count == 1)
        #expect(canvas.texts.contains("Negotiation") && canvas.texts.contains("420"))
    }

    @Test("A treemap gathers its leaves under their branches, the largest first")
    func treemap() throws {
        let chart = try chart(ChartExFixture.treemap())
        #expect(chart.categoryLevels == [ChartExFixture.branches, ChartExFixture.leaves])
        #expect(chart.categories == ChartExFixture.leaves)
        let roots = chart.hierarchy()
        #expect(roots.map(\.name) == ["Vegetables", "Fruit", "Grains"])
        #expect(roots.map(\.value) == [60, 50, 24])
        #expect(roots.map(\.colorIndex) == [1, 0, 2])
        #expect(roots[1].children.map(\.name) == ["Apples", "Pears", "Plums"])
        #expect(legend(chart) == ["Fruit", "Vegetables", "Grains"])

        let canvas = draw(chart)
        // A rectangle per leaf, each as large as its share, in its branch's colour.
        let leaves = canvas.paths.filter { $0.1 != nil }
        #expect(leaves.count == 8)
        #expect(Set(leaves.map { "\($0.1!)" }).count == 3)
        let areas = leaves.map { $0.0.boundingBox.width * $0.0.boundingBox.height }
        #expect(abs((areas.max() ?? 0) / areas.reduce(0, +) - 30.0 / 134) < 0.001)
        // A branch is named in the legend and over its own corner.
        #expect(canvas.texts.contains("Carrots") && canvas.texts.filter { $0 == "Vegetables" }.count == 2)

        #expect(try self.chart(ChartExFixture.treemap(parentLabels: "banner")).plots[0].extended.parentLabels == .banner)
        // A banner is a strip of its own above each branch.
        #expect(draw(try self.chart(ChartExFixture.treemap(parentLabels: "banner"))).paths.filter { $0.1 != nil }.count == 11)
        #expect(draw(try self.chart(ChartExFixture.treemap(parentLabels: "none"))).texts.filter { $0 == "Vegetables" }.count == 1)
    }

    @Test("Rectangles are laid out to fill their room, each its share of it")
    func squarify() {
        let room = CGRect(x: 10, y: 20, width: 300, height: 200)
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = ChartPainter.squarify(values, in: room)
        #expect(rects.count == values.count)
        for (value, rect) in zip(values, rects) {
            #expect(abs(rect.width * rect.height - CGFloat(value / 24) * 60_000) < 0.01)
            #expect(room.insetBy(dx: -0.01, dy: -0.01).contains(rect))
            #expect(max(rect.width / rect.height, rect.height / rect.width) < 3)
        }
        #expect(ChartPainter.squarify([], in: room).isEmpty)
        #expect(ChartPainter.squarify([0, 0], in: room) == [.zero, .zero])
    }

    @Test("A sunburst puts each branch's leaves in the rings outside it, and stops where a point has no label")
    func sunburst() throws {
        let chart = try chart(ChartExFixture.sunburst)
        #expect(chart.categoryLevels.count == 3)
        #expect(chart.categories == ["Tokyo", "Osaka", "Taiwan", "Seoul", "Busan", "Paris", "Lyon", "Spain"])
        let roots = chart.hierarchy()
        #expect(roots.map(\.name) == ["Asia", "Europe"])
        #expect(roots.map(\.value) == [115, 62])
        #expect(roots[0].children.map(\.name) == ["Japan", "Korea", "Taiwan"])
        #expect(roots[0].children[2].children.isEmpty)
        #expect(roots[0].depth == 3)
        // Two regions, five countries and six cities.
        let canvas = draw(chart)
        #expect(canvas.paths.filter { $0.1 != nil }.count == 13)
        #expect(canvas.texts.contains("Asia") && canvas.texts.contains("Japan"))
    }

    @Test("A histogram sorts its values into bins of one width")
    func histogram() throws {
        let chart = try chart(ChartExFixture.histogram())
        #expect(chart.categories.isEmpty)
        let bins = chart.bins()
        #expect(bins.map(\.count).reduce(0, +) == 40)
        // Scott's rule: 3.49 standard deviations over the cube root of forty.
        #expect(bins.count == 5)
        #expect(bins[0].label.hasPrefix("[12, ") && bins[1].label.hasPrefix("("))
        let canvas = draw(chart)
        #expect(canvas.rects.count == bins.count)
        #expect(canvas.texts.contains(bins[0].label))

        var layout = Chart.Extended()
        layout.binSize = 3
        let values = (1...10).map(Double.init)
        #expect(Chart.bins(of: values, layout: layout) == [
            Chart.Bin(label: "[1, 4]", count: 4), Chart.Bin(label: "(4, 7]", count: 3), Chart.Bin(label: "(7, 10]", count: 3),
        ])
        layout.underflow = 2
        layout.overflow = 8
        #expect(Chart.bins(of: values, layout: layout) == [
            Chart.Bin(label: "≤ 2", count: 2), Chart.Bin(label: "(2, 5]", count: 3), Chart.Bin(label: "(5, 8]", count: 3),
            Chart.Bin(label: "> 8", count: 2),
        ])
        layout = Chart.Extended()
        layout.binCount = 2
        layout.binsCloseLeft = true
        #expect(Chart.bins(of: [0, 5, 10], layout: layout) == [Chart.Bin(label: "[0, 5)", count: 1), Chart.Bin(label: "[5, 10]", count: 2)])
        #expect(Chart.bins(of: [], layout: layout).isEmpty)
        #expect(Chart.bins(of: [4, 4], layout: Chart.Extended()) == [Chart.Bin(label: "[4, 4]", count: 2)])

        let fixed = try self.chart(ChartExFixture.histogram(binning: "<cx:binning intervalClosed=\"r\" underflow=\"20\" overflow=\"50\"><cx:binSize val=\"10\"/></cx:binning>"))
        #expect(fixed.plots[0].extended.binSize == 10)
        #expect(fixed.bins().map(\.label) == ["≤ 20", "(20, 30]", "(30, 40]", "(40, 50]", "> 50"])
    }

    @Test("A Pareto chart runs from its tallest column down, under a line of the running share")
    func pareto() throws {
        let chart = try chart(ChartExFixture.pareto)
        #expect(chart.kind == .pareto)
        #expect(chart.allSeries.count == 1)
        #expect(chart.plots[0].extended.aggregatesByCategory)
        #expect(chart.bins() == [
            Chart.Bin(label: "Late", count: 47), Chart.Bin(label: "Damaged", count: 17), Chart.Bin(label: "Wrong item", count: 6),
            Chart.Bin(label: "Billing", count: 4), Chart.Bin(label: "Other", count: 3),
        ])
        let canvas = draw(chart)
        #expect(canvas.rects.count == 5)
        #expect(canvas.texts.contains("100%") && canvas.texts.contains("Damaged"))
        // The line ends at the top right of the plot, above the last column.
        let line = try #require(canvas.paths.last { $0.1 == nil && $0.0.boundingBox.width > 100 && $0.0.boundingBox.height > 50 })
        #expect(abs(line.0.boundingBox.maxX - (canvas.rects.last?.0.midX ?? 0)) < 0.01)
    }

    @Test("A box runs from quartile to quartile, with whiskers to the values that aren't outliers")
    func boxWhisker() throws {
        let odd = (1...9).map(Double.init)
        let exclusive = try #require(Chart.boxStatistics(odd, includingMedian: false))
        #expect(exclusive.firstQuartile == 2.5 && exclusive.median == 5 && exclusive.thirdQuartile == 7.5)
        let inclusive = try #require(Chart.boxStatistics(odd, includingMedian: true))
        #expect(inclusive.firstQuartile == 3 && inclusive.thirdQuartile == 7)
        let skewed = try #require(Chart.boxStatistics([52, 61, 64, 68, 73, 98], includingMedian: false))
        #expect(skewed.firstQuartile == 61 && skewed.median == 66 && skewed.thirdQuartile == 73)
        #expect(skewed.outliers == [98] && skewed.low == 52 && skewed.high == 73)
        #expect(abs(skewed.mean - 416.0 / 6) < 1e-9)
        #expect(Chart.boxStatistics([], includingMedian: false) == nil)
        #expect(Chart.boxStatistics([7], includingMedian: false)?.median == 7)

        let chart = try chart(ChartExFixture.boxWhisker)
        #expect(chart.allSeries.map(\.name) == ["Class A", "Class B"])
        #expect(chart.boxCategories == ["Maths", "Art", "Music"])
        #expect(chart.boxValues(of: chart.allSeries[1]).map(\.count) == [6, 6, 6])
        #expect(chart.plots[0].extended.showsMeanMarker && !chart.plots[0].extended.showsMeanLine)
        let canvas = draw(chart)
        // Six boxes, and a dot for each of the two outliers.
        #expect(canvas.paths.filter { $0.1 != nil && $0.2 != nil }.count == 6)
        #expect(canvas.paths.filter { $0.1 != nil && $0.2 == nil }.count == 2)
        #expect(canvas.texts.contains("Music") && canvas.texts.contains("Class B"))
    }

    @Test("A deck's charts are drawn as themselves rather than as what is kept for older readers, and saved as they were")
    func deck() throws {
        let data = try ChartExFixture.deck()
        let presentation = try PPTXReader.presentation(from: data)
        #expect(presentation.slides.count == 7)
        for (slide, expected) in zip(presentation.slides, ChartExFixture.all) {
            #expect(slide.shapes.count == 1)
            guard case .chart(let chart?) = slide.shapes[0].kind else {
                Issue.record("\(expected.kind) was not read as a chart")
                continue
            }
            #expect(chart.kind == expected.kind)
            #expect(slide.shapes[0].isLocked && !slide.shapes[0].isEditable)
            #expect(slide.shapes[0].frame.width > 100)
        }
        #expect(!presentation.unsupportedFeatures.features.contains(.charts))

        let written = try PPTXWriter.data(from: presentation)
        let before = try ZipArchive.entries(in: data)
        let after = try ZipArchive.entries(in: written)
        for index in 1...7 {
            #expect(after["ppt/charts/chartEx\(index).xml"] == before["ppt/charts/chartEx\(index).xml"])
            #expect(String(decoding: try #require(after["ppt/slides/slide\(index).xml"]), as: UTF8.self).contains("mc:Fallback"))
        }
        let reread = try PPTXReader.presentation(from: written)
        #expect(reread.slides.compactMap { slide -> Chart.Kind? in
            if case .chart(let chart?) = slide.shapes.first?.kind { return chart.kind }
            return nil
        } == ChartExFixture.all.map(\.kind))
    }

    @Test("A chart of a kind Dazzle doesn't draw shows what is kept for older readers")
    func fallback() throws {
        let map = ChartExFixture.part(data: ChartExFixture.data(0, levels: [["A", "B"]], [1, 2]), series: ChartExFixture.series("regionMap", "S"))
        let presentation = try PPTXReader.presentation(from: ChartExFixture.deck([map]))
        let shape = try #require(presentation.slides[0].shapes.first)
        guard case .shape = shape.kind else {
            Issue.record("Expected the fallback's text box")
            return
        }
        #expect(shape.isLocked)
    }

    @Test("Editing leaves a chart of these kinds as it was")
    func uneditable() throws {
        var chart = try chart(ChartExFixture.waterfall)
        #expect(ChartWriter.data(for: chart, original: ChartExFixture.waterfall) == nil)
        chart.title = "Changed"
        #expect(ChartWriter.data(for: chart, original: nil) == nil)
    }
}
