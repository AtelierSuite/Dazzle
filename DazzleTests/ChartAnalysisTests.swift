import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

/// Charts with trendlines and error bars, as PowerPoint writes them.
enum ChartAnalysisFixture {
    static func trendline(_ type: String, extra: String = "", name: String? = nil) -> String {
        "<c:trendline>" + (name.map { "<c:name>\($0)</c:name>" } ?? "")
            + "<c:spPr><a:ln w=\"19050\" cap=\"rnd\"><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill><a:prstDash val=\"sysDot\"/></a:ln></c:spPr>"
            + "<c:trendlineType val=\"\(type)\"/>\(extra)<c:dispRSqr val=\"0\"/><c:dispEq val=\"0\"/></c:trendline>"
    }

    static func errorBars(_ valueType: String, type: String = "both", direction: String? = nil, value: Double? = 1, custom: String = "") -> String {
        "<c:errBars>" + (direction.map { "<c:errDir val=\"\($0)\"/>" } ?? "")
            + "<c:errBarType val=\"\(type)\"/><c:errValType val=\"\(valueType)\"/><c:noEndCap val=\"0\"/>\(custom)"
            + (value.map { "<c:val val=\"\(Chart.number($0))\"/>" } ?? "")
            + "<c:spPr><a:ln w=\"9525\"><a:solidFill><a:srgbClr val=\"0000FF\"/></a:solidFill></a:ln></c:spPr></c:errBars>"
    }

    static let custom = "<c:plus>" + ChartKindFixture.numbers("Sheet1!$C$2:$C$6", [1, 2, 3, 4, 5]) + "</c:plus><c:minus>"
        + ChartKindFixture.numbers("Sheet1!$D$2:$D$6", [0.5, 0.5, 0.5, 0.5, 0.5]) + "</c:minus>"

    /// A line chart whose one series carries `analysis`.
    static func line(_ analysis: String, values: [Double] = [2, 3, 5, 4, 6]) -> Data {
        let marker = "<c:marker><c:symbol val=\"none\"/></c:marker>"
        return ChartKindFixture.part("<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>"
            + ChartKindFixture.series(0, "Apples", values, properties: marker + analysis)
            + "<c:marker val=\"1\"/><c:axId val=\"1\"/><c:axId val=\"2\"/></c:lineChart>")
    }

    /// A column chart of two series, the first carrying `analysis`.
    static func column(_ analysis: String) -> Data {
        ChartKindFixture.part("<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>"
            + ChartKindFixture.series(0, "Apples", [4.3, 2.5, 3.5, 4.5, 3], properties: "<c:invertIfNegative val=\"0\"/>" + analysis)
            + ChartKindFixture.series(1, "Pears", [2.4, 4.4, 1.8, 2.8, 3.6], properties: "<c:invertIfNegative val=\"0\"/>")
            + "<c:gapWidth val=\"219\"/><c:axId val=\"1\"/><c:axId val=\"2\"/></c:barChart>")
    }

    /// A scatter chart whose one series carries `analysis`.
    static func scatter(_ analysis: String) -> Data {
        let xs: [Double] = [1, 2, 3, 4, 5]
        let series = "<c:ser><c:idx val=\"0\"/><c:order val=\"0\"/>" + ChartKindFixture.text("Sheet1!$B$1", "Growth")
            + "<c:spPr><a:ln w=\"19050\"><a:noFill/></a:ln></c:spPr><c:marker><c:symbol val=\"circle\"/></c:marker>" + analysis
            + "<c:xVal>" + ChartKindFixture.numbers("Sheet1!$A$2:$A$6", xs) + "</c:xVal><c:yVal>"
            + ChartKindFixture.numbers("Sheet1!$B$2:$B$6", [1.5, 3.2, 6.1, 12.4, 24.8]) + "</c:yVal><c:smooth val=\"0\"/></c:ser>"
        return ChartKindFixture.part("<c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>\(series)"
            + "<c:axId val=\"1\"/><c:axId val=\"2\"/></c:scatterChart>", axes: ChartKindFixture.valueAxes)
    }

    static var all: [(name: String, data: Data)] {
        [
            ("Linear", line(trendline("linear", extra: "<c:forward val=\"1\"/>"))),
            ("Exponential", scatter(trendline("exp"))),
            ("Logarithmic", line(trendline("log"))),
            ("Polynomial", line(trendline("poly", extra: "<c:order val=\"3\"/>"))),
            ("Power", scatter(trendline("power"))),
            ("Moving average", line(trendline("movingAvg", extra: "<c:period val=\"3\"/>"))),
            ("Fixed error bars", column(errorBars("fixedVal"))),
            ("Percentage error bars", column(errorBars("percentage", value: 10))),
            ("Standard deviation error bars", line(errorBars("stdDev"))),
            ("Standard error bars", column(errorBars("stdErr", type: "plus", value: nil))),
            ("Custom error bars", column(errorBars("cust", value: nil, custom: custom))),
            ("X and y error bars", scatter(errorBars("fixedVal", direction: "x", value: 0.3) + errorBars("percentage", direction: "y", value: 15))),
        ]
    }
}

@Suite("Chart trendlines and error bars")
@MainActor
struct ChartAnalysisTests {
    private func chart(_ data: Data) throws -> Chart {
        try #require(Chart(path: "ppt/charts/chart1.xml", data: data))
    }

    private func draw(_ chart: Chart) -> RecordingCanvas {
        let canvas = RecordingCanvas()
        let presentation = Presentation.blank
        ChartPainter(chart: chart, style: SlideStyleContext(presentation: presentation, slide: presentation.slides[0]))
            .draw(in: CGRect(x: 0, y: 0, width: 600, height: 400), on: canvas)
        return canvas
    }

    private let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)

    @Test("Trendlines are read with their kind and settings")
    func readTrendlines() throws {
        let series = try chart(ChartAnalysisFixture.line(
            ChartAnalysisFixture.trendline("poly", extra: "<c:order val=\"4\"/><c:forward val=\"1.5\"/><c:backward val=\"0.5\"/><c:intercept val=\"2\"/>",
                                           name: "Fit")
                + ChartAnalysisFixture.trendline("movingAvg", extra: "<c:period val=\"3\"/>")
        )).allSeries[0]
        #expect(series.trendlines.map(\.kind) == [.poly, .movingAvg])
        let poly = series.trendlines[0]
        #expect(poly.order == 4)
        #expect(poly.forward == 1.5)
        #expect(poly.backward == 0.5)
        #expect(poly.intercept == 2)
        #expect(poly.name == "Fit")
        #expect(poly.line?.dash == "sysDot")
        #expect(series.trendlines[1].period == 3)
    }

    @Test("Error bars are read with their direction, type and amounts")
    func readErrorBars() throws {
        let bars = try chart(ChartAnalysisFixture.column(ChartAnalysisFixture.errorBars("cust", type: "minus", value: nil, custom: ChartAnalysisFixture.custom)))
            .allSeries[0].errorBars
        #expect(bars.count == 1)
        #expect(bars[0].direction == .y)
        #expect(bars[0].barType == .minus)
        #expect(bars[0].valueType == .cust)
        #expect(bars[0].plus == [1, 2, 3, 4, 5])
        #expect(bars[0].minus == [0.5, 0.5, 0.5, 0.5, 0.5])
        #expect(bars[0].hasEndCap)
        let xy = try chart(ChartAnalysisFixture.scatter(ChartAnalysisFixture.errorBars("fixedVal", direction: "x", value: 0.3))).allSeries[0].errorBars
        #expect(xy.map(\.direction) == [.x])
        #expect(xy[0].value == 0.3)
    }

    @Test("Each kind of trendline fits its form")
    func fits() throws {
        let xs: [Double] = [1, 2, 3, 4, 5]
        func points(_ f: (Double) -> Double) -> [(x: Double, y: Double)] { xs.map { ($0, f($0)) } }
        func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-6 } ?? false }

        let linear = try #require(Chart.Trendline(kind: .linear).fit(points { 2 * $0 + 1 }))
        #expect(close(linear.coefficients[0], 1) && close(linear.coefficients[1], 2))
        #expect(close(linear.rSquared, 1))
        #expect(linear.equation == "y = 2x + 1")

        let exp = try #require(Chart.Trendline(kind: .exp).fit(points { 3 * Foundation.exp(0.5 * $0) }))
        #expect(close(exp.value(at: 6), 3 * Foundation.exp(3)))

        let log = try #require(Chart.Trendline(kind: .log).fit(points { 4 * Foundation.log($0) - 1 }))
        #expect(close(log.value(at: 10), 4 * Foundation.log(10) - 1))

        let power = try #require(Chart.Trendline(kind: .power).fit(points { 2 * pow($0, 1.5) }))
        #expect(close(power.value(at: 9), 54))

        let poly = try #require(Chart.Trendline(kind: .poly, order: 2).fit(points { $0 * $0 - 3 * $0 + 2 }))
        #expect(close(poly.value(at: 10), 72))
        #expect(poly.equation == "y = x² - 3x + 2")

        var fixed = Chart.Trendline(kind: .linear)
        fixed.intercept = 0
        let through = try #require(fixed.fit([(1, 2), (2, 4), (3, 7)]))
        #expect(close(through.value(at: 0), 0))

        let average = Chart.Trendline(kind: .movingAvg, period: 3).movingAverage(points { $0 })
        #expect(average.map(\.x) == [3, 4, 5])
        #expect(average.map(\.y) == [2, 3, 4])

        // Too few points, or none a form can take, give no line.
        #expect(Chart.Trendline(kind: .linear).fit([(1, 1)]) == nil)
        #expect(Chart.Trendline(kind: .power).fit([(-1, 2), (-2, 3)]) == nil)
    }

    @Test("Error bars run as far as their kind says")
    func extents() {
        let values: [Double?] = [2, 4, nil, 6]
        func spans(_ bars: Chart.ErrorBars) -> [[Double]?] {
            bars.extents(of: values).map { $0.map { [$0.center ?? .nan, $0.minus, $0.plus] } }
        }
        let fixed = Chart.ErrorBars(valueType: .fixedVal, value: 1.5).extents(of: values)
        #expect(fixed.compactMap { $0?.plus } == [1.5, 1.5, 1.5])
        #expect(fixed[2] == nil)

        let percent = Chart.ErrorBars(barType: .plus, valueType: .percentage, value: 50).extents(of: values)
        #expect(percent.compactMap { $0?.plus } == [1, 2, 3])
        #expect(percent.compactMap { $0?.minus } == [0, 0, 0])

        // Standard deviation: about the series' mean, 4, by two deviations of 2.
        let deviation = Chart.ErrorBars(valueType: .stdDev, value: 2).extents(of: values)
        #expect(deviation.compactMap { $0?.center } == [4, 4, 4])
        #expect(deviation.compactMap { $0?.plus } == [4, 4, 4])

        let error = Chart.ErrorBars(barType: .minus, valueType: .stdErr).extents(of: values)
        let expected = ((4 + 16 + 36) / 6.0).squareRoot()
        #expect(error.compactMap { $0?.minus }.allSatisfy { abs($0 - expected) < 1e-9 })
        #expect(error.compactMap { $0?.plus } == [0, 0, 0])

        var custom = Chart.ErrorBars(valueType: .cust)
        custom.plus = [1, 2]
        custom.minus = [0.5]
        let own = custom.extents(of: values)
        #expect(own.compactMap { $0?.plus } == [1, 2, 0])
        #expect(own.compactMap { $0?.minus } == [0.5, 0, 0])
    }

    @Test("Every trendline and error bar is drawn in its own colour", arguments: ChartAnalysisFixture.all.map(\.name))
    func drawing(name: String) throws {
        let data = try #require(ChartAnalysisFixture.all.first { $0.name == name }?.data)
        let chart = try chart(data)
        let canvas = draw(chart)
        let isTrendline = !chart.allSeries[0].trendlines.isEmpty
        let strokes = canvas.paths.filter { $0.2 == (isTrendline ? red : blue) }
        // A trendline also shows as a line in the legend.
        #expect(strokes.count == (isTrendline || name == "X and y error bars" ? 2 : 1))
        #expect(strokes.allSatisfy { !$0.0.isEmpty })
        if isTrendline {
            // The legend lists the line by its kind and series.
            #expect(canvas.texts.contains { $0.contains("(Apples)") || $0.contains("(Growth)") })
        }
    }

    @Test("Error bars widen the value axis to take them in")
    func axisReach() throws {
        let plain = draw(try chart(ChartAnalysisFixture.column("")))
        let barred = draw(try chart(ChartAnalysisFixture.column(ChartAnalysisFixture.errorBars("fixedVal", value: 4))))
        #expect(!plain.texts.contains("8"))
        #expect(barred.texts.contains("8"))
    }

    @Test("A trendline can label its equation and R²")
    func equationLabel() throws {
        let trendline = "<c:trendline><c:trendlineType val=\"linear\"/><c:dispRSqr val=\"1\"/><c:dispEq val=\"1\"/></c:trendline>"
        let canvas = draw(try chart(ChartAnalysisFixture.line(trendline, values: [3, 5, 7, 9, 11])))
        #expect(canvas.texts.contains("y = 2x + 1"))
        #expect(canvas.texts.contains("R² = 1"))
    }

    @Test("Trendlines and error bars are written back as they were", arguments: ChartAnalysisFixture.all.map(\.name))
    func roundTrip(name: String) throws {
        let data = try #require(ChartAnalysisFixture.all.first { $0.name == name }?.data)
        var edited = try chart(data)
        edited.updateSeries(at: 0) { $0.values[0] = 3 }
        let written = try #require(ChartWriter.data(for: edited, original: data))
        let after = try chart(written)
        #expect(after.allSeries[0].trendlines == edited.allSeries[0].trendlines)
        #expect(after.allSeries[0].errorBars == edited.allSeries[0].errorBars)
    }
}
