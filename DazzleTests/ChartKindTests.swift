import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

/// Chart parts of the kinds PowerPoint makes beyond columns, lines and pies,
/// written as Dazzle writes them back, so that reading and writing one
/// unchanged gives the same XML.
enum ChartKindFixture {
    static let categories = ["North", "East", "South", "West", "Middle"]

    static func text(_ formula: String, _ value: String) -> String {
        "<c:tx><c:strRef><c:f>\(formula)</c:f><c:strCache><c:ptCount val=\"1\"/><c:pt idx=\"0\"><c:v>\(value)</c:v></c:pt>"
            + "</c:strCache></c:strRef></c:tx>"
    }

    static func numbers(_ formula: String, _ values: [Double], format: String = "General") -> String {
        "<c:numRef><c:f>\(formula)</c:f><c:numCache><c:formatCode>\(format)</c:formatCode><c:ptCount val=\"\(values.count)\"/>"
            + values.enumerated().map { "<c:pt idx=\"\($0)\"><c:v>\(Chart.number($1))</c:v></c:pt>" }.joined()
            + "</c:numCache></c:numRef>"
    }

    static func categoryLabels(_ labels: [String]) -> String {
        "<c:cat><c:strRef><c:f>Sheet1!$A$2:$A$\(labels.count + 1)</c:f><c:strCache><c:ptCount val=\"\(labels.count)\"/>"
            + labels.enumerated().map { "<c:pt idx=\"\($0)\"><c:v>\($1)</c:v></c:pt>" }.joined() + "</c:strCache></c:strRef></c:cat>"
    }

    /// A series of a category chart, in the `index`th column after the categories.
    static func series(
        _ index: Int, _ name: String, _ values: [Double], properties: String = "", labels: [String] = categories, dates: [Double]? = nil
    ) -> String {
        let letter = ChartWriter.columnLetter(index + 2)
        let last = values.count + 1
        let category = dates.map { "<c:cat>" + numbers("Sheet1!$A$2:$A$\(last)", $0, format: "m/d/yyyy") + "</c:cat>" }
            ?? categoryLabels(labels)
        return "<c:ser><c:idx val=\"\(index)\"/><c:order val=\"\(index)\"/>" + text("Sheet1!$\(letter)$1", name) + properties
            + category + "<c:val>" + numbers("Sheet1!$\(letter)$2:$\(letter)$\(last)", values) + "</c:val></c:ser>"
    }

    static let categoryAxes = """
        <c:catAx><c:axId val="1"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/>\
        <c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="none"/><c:minorTickMark val="none"/>\
        <c:tickLblPos val="nextTo"/><c:crossAx val="2"/><c:crosses val="autoZero"/><c:auto val="1"/><c:lblAlgn val="ctr"/>\
        <c:lblOffset val="100"/><c:noMultiLvlLbl val="0"/></c:catAx><c:valAx><c:axId val="2"/><c:scaling><c:orientation \
        val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/><c:numFmt formatCode="General" \
        sourceLinked="1"/><c:majorTickMark val="none"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/><c:crossAx \
        val="1"/><c:crosses val="autoZero"/><c:crossBetween val="between"/></c:valAx>
        """

    static let seriesAxis = """
        <c:serAx><c:axId val="3"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/>\
        <c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/><c:crossAx val="2"/>\
        <c:crosses val="autoZero"/></c:serAx>
        """

    static let valueAxes = """
        <c:valAx><c:axId val="1"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/>\
        <c:majorGridlines/><c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="none"/><c:minorTickMark \
        val="none"/><c:tickLblPos val="nextTo"/><c:crossAx val="2"/><c:crosses val="autoZero"/><c:crossBetween val="midCat"/>\
        </c:valAx><c:valAx><c:axId val="2"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/>\
        <c:axPos val="l"/><c:majorGridlines/><c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="none"/>\
        <c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/><c:crossAx val="1"/><c:crosses val="autoZero"/>\
        <c:crossBetween val="midCat"/></c:valAx>
        """

    static func part(_ plots: String, axes: String = categoryAxes, view3D: String = "") -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:chart>\
            <c:autoTitleDeleted val="1"/>\(view3D)<c:plotArea><c:layout/>\(plots)\(axes)</c:plotArea><c:legend><c:legendPos \
            val="b"/><c:overlay val="0"/></c:legend><c:plotVisOnly val="1"/></c:chart></c:chartSpace>
            """.utf8)
    }

    static let threeSeries: [(String, [Double])] = [
        ("Apples", [4.3, 2.5, 3.5, 4.5, 3]), ("Pears", [2.4, 4.4, 1.8, 2.8, 3.6]), ("Plums", [2, 2, 3, 5, 1.5]),
    ]

    static func radar(_ style: String) -> Data {
        let marker = style == "standard" ? "<c:marker><c:symbol val=\"none\"/></c:marker>" : ""
        let series = threeSeries.enumerated().map { series($0, $1.0, $1.1, properties: marker) }.joined()
        return part("<c:radarChart><c:radarStyle val=\"\(style)\"/><c:varyColors val=\"0\"/>\(series)"
            + "<c:axId val=\"1\"/><c:axId val=\"2\"/></c:radarChart>")
    }

    static let stockSeriesLine = "<c:spPr><a:ln w=\"19050\" cap=\"rnd\"><a:noFill/><a:round/></a:ln></c:spPr>"
    static let days: [Double] = [45_292, 45_293, 45_294, 45_295, 45_296]
    static let prices: [(String, [Double])] = [
        ("Open", [44, 25, 38, 50, 36]), ("High", [55, 57, 57, 58, 58]), ("Low", [11, 12, 13, 11, 25]), ("Close", [25, 38, 50, 35, 43]),
    ]

    /// High, low and close; open too with up and down bars; and either with volume, on an axis of its own.
    static func stock(open: Bool, volume: Bool) -> Data {
        let priceSeries = (open ? prices : Array(prices.dropFirst()))
        let first = volume ? 1 : 0
        let lines = priceSeries.enumerated().map { offset, entry in
            let marker = entry.0 == "Close" || entry.0 == "Open" ? "" : "<c:marker><c:symbol val=\"none\"/></c:marker>"
            return series(first + offset, entry.0, entry.1, properties: stockSeriesLine + marker, dates: days)
        }.joined()
        let bars = open ? "<c:upDownBars><c:gapWidth val=\"150\"/><c:upBars/><c:downBars/></c:upDownBars>" : ""
        let stockAxes = volume ? "<c:axId val=\"3\"/><c:axId val=\"4\"/>" : "<c:axId val=\"1\"/><c:axId val=\"2\"/>"
        var plots = "<c:stockChart>\(lines)<c:hiLowLines/>\(bars)\(stockAxes)</c:stockChart>"
        var axes = categoryAxes
        if volume {
            plots = "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>"
                + series(0, "Volume", [70, 120, 150, 135, 148], dates: days)
                + "<c:gapWidth val=\"150\"/><c:axId val=\"1\"/><c:axId val=\"2\"/></c:barChart>" + plots
            axes += """
                <c:catAx><c:axId val="3"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="1"/>\
                <c:axPos val="b"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/>\
                <c:crossAx val="4"/><c:crosses val="autoZero"/><c:auto val="1"/><c:lblAlgn val="ctr"/><c:lblOffset val="100"/>\
                <c:noMultiLvlLbl val="0"/></c:catAx><c:valAx><c:axId val="4"/><c:scaling><c:orientation val="minMax"/>\
                </c:scaling><c:delete val="0"/><c:axPos val="r"/><c:numFmt formatCode="General" sourceLinked="1"/>\
                <c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/><c:crossAx val="3"/>\
                <c:crosses val="max"/><c:crossBetween val="between"/></c:valAx>
                """
        }
        return part(plots, axes: axes)
    }

    static func bubble(scale: Int = 100, width: Bool = false) -> Data {
        let xs: [Double] = [0.7, 1.8, 2.6, 3.4]
        let series = [("Sales", [2.7, 3.2, 0.8, 1.5], [10.0, 4, 8, 2]), ("Costs", [1.5, 2.2, 2.9, 0.6], [3.0, 7, 5, 12])]
            .enumerated().map { index, entry in
                let y = ChartWriter.columnLetter(index * 2 + 2)
                let size = ChartWriter.columnLetter(index * 2 + 3)
                return "<c:ser><c:idx val=\"\(index)\"/><c:order val=\"\(index)\"/>" + text("Sheet1!$\(y)$1", entry.0)
                    + "<c:invertIfNegative val=\"0\"/><c:xVal>" + numbers("Sheet1!$A$2:$A$5", xs) + "</c:xVal><c:yVal>"
                    + numbers("Sheet1!$\(y)$2:$\(y)$5", entry.1) + "</c:yVal><c:bubbleSize>" + numbers("Sheet1!$\(size)$2:$\(size)$5", entry.2)
                    + "</c:bubbleSize><c:bubble3D val=\"0\"/></c:ser>"
            }.joined()
        return part("<c:bubbleChart><c:varyColors val=\"0\"/>\(series)<c:bubbleScale val=\"\(scale)\"/><c:showNegBubbles val=\"0\"/>"
            + (width ? "<c:sizeRepresents val=\"w\"/>" : "") + "<c:axId val=\"1\"/><c:axId val=\"2\"/></c:bubbleChart>", axes: valueAxes)
    }

    static let shares: [Double] = [42, 25, 15, 8, 6, 4]
    static let shareNames = ["Tea", "Coffee", "Juice", "Water", "Milk", "Soda"]

    static func ofPie(bar: Bool, split: String = "<c:splitType val=\"pos\"/><c:splitPos val=\"3\"/>") -> Data {
        let series = series(0, "Drinks", shares, labels: shareNames)
        return part("<c:ofPieChart><c:ofPieType val=\"\(bar ? "bar" : "pie")\"/><c:varyColors val=\"1\"/>\(series)"
            + "<c:gapWidth val=\"100\"/>\(split)<c:secondPieSize val=\"75\"/><c:serLines/></c:ofPieChart>", axes: "")
    }

    static let view3D = "<c:view3D><c:rotX val=\"15\"/><c:rotY val=\"20\"/><c:depthPercent val=\"100\"/><c:rAngAx val=\"1\"/></c:view3D>"
    static let pieView3D = "<c:view3D><c:rotX val=\"30\"/><c:rotY val=\"0\"/><c:rAngAx val=\"0\"/></c:view3D>"

    static func bar3D(horizontal: Bool, grouping: String = "clustered") -> Data {
        let series = threeSeries.enumerated().map { series($0, $1.0, $1.1) }.joined()
        let rows = grouping == "standard"
        return part("<c:bar3DChart><c:barDir val=\"\(horizontal ? "bar" : "col")\"/><c:grouping val=\"\(grouping)\"/>"
            + "<c:varyColors val=\"0\"/>\(series)<c:gapWidth val=\"150\"/><c:shape val=\"box\"/><c:axId val=\"1\"/><c:axId val=\"2\"/>"
            + (rows ? "<c:axId val=\"3\"/>" : "") + "</c:bar3DChart>",
            axes: (horizontal ? categoryAxes.replacingOccurrences(of: "<c:axPos val=\"b\"/>", with: "<c:axPos val=\"X\"/>")
                .replacingOccurrences(of: "<c:axPos val=\"l\"/>", with: "<c:axPos val=\"b\"/>")
                .replacingOccurrences(of: "<c:axPos val=\"X\"/>", with: "<c:axPos val=\"l\"/>") : categoryAxes) + (rows ? seriesAxis : ""),
            view3D: view3D)
    }

    static var line3D: Data {
        let series = threeSeries.enumerated().map { series($0, $1.0, $1.1) }.joined()
        return part("<c:line3DChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(series)<c:gapDepth val=\"150\"/>"
            + "<c:axId val=\"1\"/><c:axId val=\"2\"/><c:axId val=\"3\"/></c:line3DChart>", axes: categoryAxes + seriesAxis, view3D: view3D)
    }

    static var area3D: Data {
        let series = threeSeries.enumerated().map { series($0, $1.0, $1.1) }.joined()
        return part("<c:area3DChart><c:grouping val=\"stacked\"/><c:varyColors val=\"0\"/>\(series)"
            + "<c:axId val=\"1\"/><c:axId val=\"2\"/></c:area3DChart>", axes: categoryAxes, view3D: view3D)
    }

    static var pie3D: Data {
        part("<c:pie3DChart><c:varyColors val=\"1\"/>\(series(0, "Drinks", shares, labels: shareNames))</c:pie3DChart>", axes: "", view3D: pieView3D)
    }

    static func surface(threeD: Bool, wireframe: Bool = false) -> Data {
        let rows: [(String, [Double])] = [
            ("Morning", [10, 20, 30, 25, 15]), ("Noon", [20, 40, 55, 45, 25]), ("Evening", [15, 30, 40, 35, 20]), ("Night", [5, 10, 15, 12, 8]),
        ]
        let series = rows.enumerated().map { series($0, $1.0, $1.1) }.joined()
        let name = threeD ? "surface3DChart" : "surfaceChart"
        return part("<c:\(name)><c:wireframe val=\"\(wireframe ? 1 : 0)\"/>\(series)<c:axId val=\"1\"/><c:axId val=\"2\"/>"
            + "<c:axId val=\"3\"/></c:\(name)>", axes: categoryAxes + seriesAxis, view3D: threeD ? view3D : "")
    }

    /// Every kind, one per slide of the test deck, with what to call it.
    static var all: [(name: String, data: Data)] {
        [
            ("Radar", radar("standard")), ("Radar with markers", radar("marker")), ("Filled radar", radar("filled")),
            ("High-low-close", stock(open: false, volume: false)), ("Open-high-low-close", stock(open: true, volume: false)),
            ("Volume-high-low-close", stock(open: false, volume: true)), ("Volume-open-high-low-close", stock(open: true, volume: true)),
            ("Bubble", bubble()), ("Bubble by width", bubble(scale: 60, width: true)),
            ("Pie of pie", ofPie(bar: false)), ("Bar of pie", ofPie(bar: true, split: "<c:splitType val=\"val\"/><c:splitPos val=\"10\"/>")),
            ("3D column", bar3D(horizontal: false)), ("3D bar", bar3D(horizontal: true, grouping: "stacked")),
            ("3D column in rows", bar3D(horizontal: false, grouping: "standard")),
            ("3D pie", pie3D), ("3D line", line3D), ("3D area", area3D),
            ("Contour", surface(threeD: false)), ("3D surface", surface(threeD: true)), ("Wireframe contour", surface(threeD: false, wireframe: true)),
        ]
    }
}

/// Records what a chart draws, by kind of primitive.
final class RecordingCanvas: ChartCanvas {
    var rects: [(CGRect, RGBAColor)] = []
    var paths: [(CGPath, RGBAColor?, RGBAColor?)] = []
    var texts: [String] = []

    func fill(_ rect: CGRect, color: RGBAColor) { rects.append((rect, color)) }
    func draw(_ path: CGPath, fill: RGBAColor?, stroke: RGBAColor?, lineWidth: CGFloat, round: Bool) { paths.append((path, fill, stroke)) }
    func text(_ text: String, in rect: CGRect, size: CGFloat, alignment: ChartTextAlignment, color: RGBAColor) { texts.append(text) }
    func measure(_ text: String, size: CGFloat) -> CGFloat { CGFloat(text.count) * size * 0.5 }
    func lineHeight(size: CGFloat) -> CGFloat { size * 1.25 }
}

@Suite("Chart kinds")
@MainActor
struct ChartKindTests {
    private func chart(_ data: Data) throws -> Chart {
        try #require(Chart(path: "ppt/charts/chart1.xml", data: data))
    }

    private func canonical(_ data: Data?) throws -> String {
        let data = try #require(data)
        return try #require(XMLLite.serialize(try XMLLite.parse(data)))
    }

    private func draw(_ chart: Chart) -> RecordingCanvas {
        let canvas = RecordingCanvas()
        let presentation = Presentation.blank
        ChartPainter(chart: chart, style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]))
            .draw(in: CGRect(x: 0, y: 0, width: 600, height: 400), on: canvas)
        return canvas
    }

    @Test("Radar charts are read with their style")
    func radar() throws {
        for style in Chart.RadarStyle.allCases {
            let chart = try chart(ChartKindFixture.radar(style.rawValue))
            #expect(chart.kind == .radar)
            #expect(chart.plots[0].radarStyle == style)
            #expect(chart.categories == ChartKindFixture.categories)
            #expect(chart.allSeries.map(\.values.count) == [5, 5, 5])
        }
        #expect(try chart(ChartKindFixture.radar("standard")).allSeries[0].marker == "none")
    }

    @Test("Radar charts draw a web of polygon gridlines and their categories round the outside")
    func radarDrawing() throws {
        let filled = draw(try chart(ChartKindFixture.radar("filled")))
        // Gridlines are outlines; filled series are filled shapes, one per series.
        #expect(filled.paths.filter { $0.1 == nil && $0.2 != nil }.count >= 5)
        #expect(filled.paths.filter { $0.1 != nil }.count == 3)
        for category in ChartKindFixture.categories { #expect(filled.texts.contains(category)) }

        let markers = draw(try chart(ChartKindFixture.radar("marker")))
        let lines = draw(try chart(ChartKindFixture.radar("standard")))
        // Markers: a dot per point, which the standard style leaves off.
        #expect(markers.paths.filter { $0.1 != nil }.count == 15)
        #expect(lines.paths.filter { $0.1 != nil }.isEmpty)
    }

    @Test("Stock charts are read with their lines, bars, dates and volume")
    func stock() throws {
        let hlc = try chart(ChartKindFixture.stock(open: false, volume: false))
        #expect(hlc.kind == .stock)
        #expect(hlc.plots[0].hasHighLowLines && !hlc.plots[0].hasUpDownBars)
        #expect(hlc.allSeries.map(\.name) == ["High", "Low", "Close"])
        #expect(hlc.allSeries.allSatisfy { $0.hasLine == false })
        #expect(hlc.categoryFormat == "m/d/yyyy")
        #expect(hlc.categories.first == "45292")

        let ohlc = try chart(ChartKindFixture.stock(open: true, volume: false))
        #expect(ohlc.plots[0].hasUpDownBars)
        #expect(ohlc.allSeries.count == 4)

        let volume = try chart(ChartKindFixture.stock(open: true, volume: true))
        #expect(volume.plots.map(\.kind) == [.column, .stock])
        #expect(volume.allSeries.map(\.name) == ["Volume", "Open", "High", "Low", "Close"])
    }

    @Test("Stock charts draw high-low lines, up and down bars, close ticks and dates")
    func stockDrawing() throws {
        let hlc = draw(try chart(ChartKindFixture.stock(open: false, volume: false)))
        // A high-low line and a close tick per day, and no bars.
        #expect(hlc.paths.filter { $0.1 == nil && $0.2 != nil }.count >= 10)
        #expect(hlc.paths.filter { $0.1 != nil }.isEmpty)
        #expect(hlc.texts.contains("1/1/2024"))

        let ohlc = draw(try chart(ChartKindFixture.stock(open: true, volume: false)))
        let bars = ohlc.paths.filter { $0.1 != nil }
        #expect(bars.count == 5)
        // Rising days are hollow, falling ones dark.
        #expect(Set(bars.compactMap(\.1)).count == 2)

        // Volume as columns on the left axis, prices on their own axis to the right.
        let volume = draw(try chart(ChartKindFixture.stock(open: true, volume: true)))
        #expect(volume.rects.count >= 5)
        #expect(volume.texts.contains("150") && volume.texts.contains("60"))
    }

    @Test("Day numbers in a date format read as dates")
    func dates() {
        #expect(ChartPainter.date(45_292, format: "m/d/yyyy") == "1/1/2024")
        #expect(ChartPainter.date(45_351, format: "d-mmm") == "29-Feb")
        #expect(ChartPainter.date(1, format: "yyyy-mm-dd") == "1900-01-01")
        #expect(ChartPainter.date(44_197, format: "[$-409]mmm d, yyyy") == "Jan 1, 2021")
        #expect(ChartPainter.date(12, format: "General") == nil)
    }

    @Test("Bubble charts are read with each bubble's size and how sizes show")
    func bubble() throws {
        let chart = try chart(ChartKindFixture.bubble(scale: 60, width: true))
        #expect(chart.kind == .bubble)
        #expect(chart.categories == ["0.7", "1.8", "2.6", "3.4"])
        #expect(chart.allSeries.map(\.sizes) == [[10, 4, 8, 2], [3, 7, 5, 12]])
        #expect(chart.allSeries.map(\.xValues) == [[0.7, 1.8, 2.6, 3.4], [0.7, 1.8, 2.6, 3.4]])
        #expect(chart.plots[0].bubbleScale == 60)
        #expect(chart.plots[0].sizeIsWidth)
    }

    @Test("Bubbles are sized by area, or by width, and scaled")
    func bubbleDrawing() throws {
        func diameters(_ data: Data) throws -> [CGFloat] {
            draw(try chart(data)).paths.filter { $0.1 != nil }.map(\.0.boundingBox.width).sorted()
        }
        let area = try diameters(ChartKindFixture.bubble())
        let width = try diameters(ChartKindFixture.bubble(width: true))
        let small = try diameters(ChartKindFixture.bubble(scale: 50))
        #expect(area.count == 8)
        // The largest, 12, against the smallest, 2: by area √6 times as wide, by width 6 times.
        #expect(abs(area.last! / area.first! - 6.0.squareRoot()) < 0.01)
        #expect(abs(width.last! / width.first! - 6) < 0.01)
        #expect(abs(small.last! * 2 - area.last!) < 0.01)
    }

    @Test("Of-pie charts are read with their split, and split their points")
    func ofPie() throws {
        let pie = try chart(ChartKindFixture.ofPie(bar: false))
        #expect(pie.kind == .pieOfPie)
        #expect(pie.plots[0].splitType == .pos && pie.plots[0].splitPosition == 3)
        #expect(pie.plots[0].secondPlotPoints(count: 6) == [3, 4, 5])
        #expect(pie.plots[0].hasSeriesLines && pie.plots[0].gapWidth == 100 && pie.plots[0].secondPieSize == 75)

        let bar = try chart(ChartKindFixture.ofPie(bar: true, split: "<c:splitType val=\"val\"/><c:splitPos val=\"10\"/>"))
        #expect(bar.kind == .barOfPie)
        #expect(bar.plots[0].secondPlotPoints(count: 6) == [3, 4, 5])

        var plot = bar.plots[0]
        plot.splitType = .percent
        plot.splitPosition = 10
        #expect(plot.secondPlotPoints(count: 6) == [3, 4, 5])
        plot.splitType = .cust
        plot.customSplit = [1, 5, 9]
        #expect(plot.secondPlotPoints(count: 6) == [1, 5])
    }

    @Test("Of-pie charts draw the rest of the pie as one slice, the split points beside it, and lines between")
    func ofPieDrawing() throws {
        let pie = draw(try chart(ChartKindFixture.ofPie(bar: false)))
        // Three slices and "Other" in the first pie, three in the second, two series lines.
        #expect(pie.paths.filter { $0.1 != nil }.count == 7)
        #expect(pie.paths.filter { $0.1 == nil }.count == 2)
        #expect(pie.texts.contains(String(localized: "Chart.Other", bundle: .engine)))
        let bar = draw(try chart(ChartKindFixture.ofPie(bar: true)))
        #expect(bar.paths.filter { $0.1 != nil }.count == 7)
    }

    @Test("3D charts are read as 3D, with the angle they are seen from")
    func threeD() throws {
        let column = try chart(ChartKindFixture.bar3D(horizontal: false))
        #expect(column.kind == .column && column.plots[0].isThreeD)
        #expect(column.view3D == Chart.View3D(rotX: 15, rotY: 20, depthPercent: 100))
        let bar = try chart(ChartKindFixture.bar3D(horizontal: true, grouping: "stacked"))
        #expect(bar.kind == .bar && bar.plots[0].isThreeD && bar.plots[0].grouping == .stacked)
        let pie = try chart(ChartKindFixture.pie3D)
        #expect(pie.kind == .pie && pie.plots[0].isThreeD && pie.effectiveView3D.rotX == 30)
        #expect(try chart(ChartKindFixture.line3D).plots[0].isThreeD)
        #expect(try chart(ChartKindFixture.area3D).plots[0].isThreeD)
    }

    @Test("3D columns are drawn as boxes, their tops and sides shaded")
    func threeDDrawing() throws {
        let flat = try chart(ChartKindFixture.bar3D(horizontal: false))
        var plain = flat
        plain.plots[0].isThreeD = false
        let boxes = draw(flat)
        // Fifteen bars, each a front, a top and a side.
        #expect(boxes.rects.count == draw(plain).rects.count)
        #expect(boxes.paths.filter { $0.1 != nil }.count == 30)

        let pie = draw(try chart(ChartKindFixture.pie3D))
        // Six tops, and the rim of those facing forward.
        #expect(pie.paths.filter { $0.1 != nil }.count > 6)
        let line = draw(try chart(ChartKindFixture.line3D))
        // Each series a ribbon of four segments.
        #expect(line.paths.filter { $0.1 != nil }.count == 12)
    }

    @Test("Surface charts are read, and drawn as a map coloured by value band")
    func surface() throws {
        let contour = try chart(ChartKindFixture.surface(threeD: false))
        #expect(contour.kind == .surface && !contour.plots[0].isThreeD)
        #expect(try chart(ChartKindFixture.surface(threeD: true)).plots[0].isThreeD)
        #expect(try chart(ChartKindFixture.surface(threeD: false, wireframe: true)).plots[0].isWireframe)

        let canvas = draw(contour)
        // Bands of 10 from 0 to 60: the legend lists them, each in its own colour.
        let painter = ChartPainter(chart: contour, style: SlideStyleContext(presentation: .blank, slide: Presentation.blank.slides[0]))
        #expect(painter.legendEntries().map(\.0) == ["0-10", "10-20", "20-30", "30-40", "40-50", "50-60"])
        let colours = Set(canvas.rects.map { "\($0.1)" })
        #expect(colours.count == 6)
        #expect(canvas.rects.count > 50)
        for name in ["Morning", "Noon", "Evening", "Night"] { #expect(canvas.texts.contains(name)) }

        let wireframe = draw(try chart(ChartKindFixture.surface(threeD: false, wireframe: true)))
        #expect(wireframe.paths.count >= 31)
    }

    @Test("Every kind writes back as the XML it was read from", arguments: ChartKindFixture.all.map(\.name))
    func roundTrip(name: String) throws {
        let data = try #require(ChartKindFixture.all.first { $0.name == name }?.data)
        let chart = try chart(data)
        let written = ChartWriter.data(for: chart, original: data)
        #expect(try canonical(written) == canonical(data))
    }

    @Test("Editing the data keeps the kind, its look and its sizes", arguments: ChartKindFixture.all.map(\.name))
    func edit(name: String) throws {
        let data = try #require(ChartKindFixture.all.first { $0.name == name }?.data)
        let before = try chart(data)
        var edited = before
        edited.updateSeries(at: 0) { $0.values[0] = 9 }
        edited.addCategory()
        edited.updateSeries(at: 0) { $0.values[$0.values.count - 1] = 7 }
        let written = try #require(ChartWriter.data(for: edited, original: data))
        let after = try chart(written)
        #expect(after.plots.map(\.kind) == before.plots.map(\.kind))
        #expect(after.plots.map(\.isThreeD) == before.plots.map(\.isThreeD))
        #expect(after.plots.map(\.radarStyle) == before.plots.map(\.radarStyle))
        #expect(after.plots.map(\.hasUpDownBars) == before.plots.map(\.hasUpDownBars))
        #expect(after.plots.map(\.splitType) == before.plots.map(\.splitType))
        #expect(after.plots.map(\.isWireframe) == before.plots.map(\.isWireframe))
        #expect(after.view3D == before.view3D)
        #expect(after.allSeries[0].values.first == 9)
        #expect(after.allSeries[0].values.last == 7)
        #expect(after.categories.count == before.categories.count + 1)
        if before.kind == .bubble {
            #expect(after.allSeries.map { Array($0.sizes.prefix(4)) } == before.allSeries.map(\.sizes))
            #expect(after.allSeries.allSatisfy { $0.sizes.count == 5 && $0.sizes[4] != nil })
        }
        // The axes a plot names are all there.
        let root = try XMLLite.parse(written)
        let area = try #require(root.firstChild(named: "chart")?.firstChild(named: "plotArea"))
        let axes = Set(area.children.compactMap { ["catAx", "valAx", "dateAx", "serAx"].contains($0.name) ? $0.firstChild(named: "axId")?.attribute("val") : nil })
        for plot in area.children where plot.name.hasSuffix("Chart") {
            #expect(plot.children(named: "axId").allSatisfy { axes.contains($0.attribute("val") ?? "") })
        }
    }

    @Test("A 3D chart made another kind stays 3D where that kind can be")
    func changeKind() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertChart(.column, in: &presentation)
        state.selectedShapeID = presentation.slides[0].shapes.last?.id
        state.updateChart(in: &presentation) { $0.plots[0].isThreeD = true }
        state.setChartKind(.line, in: &presentation)
        let line = try #require(state.selectedChart(in: presentation))
        #expect(line.kind == .line && line.plots[0].isThreeD)
        // A 3D line names a series axis, which is made for it.
        let part = try #require(presentation.data(at: line.path))
        #expect(String(decoding: part, as: UTF8.self).contains("<c:serAx>"))
        #expect(String(decoding: part, as: UTF8.self).contains("<c:view3D>"))
        state.setChartKind(.doughnut, in: &presentation)
        #expect(state.selectedChart(in: presentation)?.plots[0].isThreeD == false)
    }

    @Test("New charts of every kind write series formulas to their own columns of the workbook")
    func columns() throws {
        var chart = Chart.sample(.bubble, path: "ppt/charts/chart1.xml")
        chart.title = nil
        let written = String(decoding: try #require(ChartWriter.data(for: chart, original: nil)), as: UTF8.self)
        #expect(written.contains("Sheet1!$B$2:$B$5") && written.contains("Sheet1!$C$2:$C$5") && written.contains("Sheet1!$D$1"))
        let reread = try #require(Chart(path: chart.path, data: Data(written.utf8)))
        #expect(reread.kind == .bubble)
        #expect(reread.allSeries.map(\.sizes) == chart.allSeries.map(\.sizes))
    }

    @Test("Only the kinds a chart can be made as are offered, and a chart's own besides")
    func choices() {
        #expect(Chart.Kind.insertable.count == 7)
        #expect(Chart.Kind.column.choices == Chart.Kind.insertable)
        #expect(Chart.Kind.radar.choices.last == .radar)
        for kind in Chart.Kind.allCases { #expect(!kind.label.isEmpty) }
    }

    @Test("Charts of every kind render in a slide", arguments: ChartKindFixture.all.map(\.name))
    func render(name: String) throws {
        let data = try #require(ChartKindFixture.all.first { $0.name == name }?.data)
        let chart = try chart(data)
        let canvas = draw(chart)
        #expect(!canvas.paths.isEmpty || !canvas.rects.isEmpty)
    }
}
