import Foundation

/// A chart, as much of it as Dazzle draws and edits: its plots and their
/// series, its categories, its title and legend. Everything else in the
/// chart's part is kept as it was.
public struct Chart: Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case column
        case bar
        case line
        case area
        case pie
        case doughnut
        case scatter
        case radar
        /// High, low and close, or open, high, low and close.
        case stock
        /// Scatter points sized by a third value.
        case bubble
        /// A grid of values coloured by band, categories across and series down.
        case surface
        /// A pie whose smallest slices are pulled out into a second, smaller pie.
        case pieOfPie
        /// A pie whose smallest slices are pulled out into a stacked bar.
        case barOfPie

        /// The kinds a new chart can be made as, and a chart changed to.
        public static let insertable: [Kind] = [.column, .bar, .line, .area, .pie, .doughnut, .scatter]

        /// The kinds to offer for a chart of this kind: those a chart can be
        /// made as, and this one if it isn't among them.
        public var choices: [Kind] { Self.insertable.contains(self) ? Self.insertable : Self.insertable + [self] }

        /// Whether the plot has axes: everything but the pies.
        public var hasAxes: Bool { !colorsByPoint }
        /// Whether its points are coloured one by one rather than series by series.
        public var colorsByPoint: Bool { [.pie, .doughnut, .pieOfPie, .barOfPie].contains(self) }
        /// Whether its series can be side by side, stacked or stacked to 100%.
        public var hasGrouping: Bool { [.column, .bar, .line, .area].contains(self) }
        /// Whether it can be drawn in 3D: as a `bar3DChart` and the like.
        public var hasThreeD: Bool { [.column, .bar, .line, .area, .pie, .surface].contains(self) }
        /// Whether its points sit along two value axes rather than by category.
        public var isXY: Bool { self == .scatter || self == .bubble }
    }

    /// How a radar chart draws its series.
    public enum RadarStyle: String, CaseIterable, Sendable {
        /// Lines, with markers where the series has them.
        case standard
        case marker
        /// Each series a filled shape.
        case filled
    }

    /// Which of an of-pie chart's points go to its second plot.
    public enum SplitType: String, CaseIterable, Sendable {
        /// The last few, as Office picks them.
        case auto
        /// The last `splitPos`.
        case pos
        /// Those whose value is under `splitPos`.
        case val
        /// Those under `splitPos` percent of the whole.
        case percent
        /// Those listed in `custSplit`.
        case cust
    }

    /// The angle a 3D chart is seen from, as `c:view3D` gives it.
    public struct View3D: Equatable, Hashable, Sendable {
        /// Tilt, in degrees: how far the chart is seen from above.
        public var rotX = 15
        /// Turn, in degrees: how far it is seen from the side.
        public var rotY = 20
        /// Depth, as a percentage of the chart's width.
        public var depthPercent = 100

        public init(rotX: Int = 15, rotY: Int = 20, depthPercent: Int = 100) {
            self.rotX = rotX
            self.rotY = rotY
            self.depthPercent = depthPercent
        }
    }

    public enum Grouping: String, CaseIterable, Sendable {
        /// Side by side, or for lines and areas, each from zero.
        case standard
        case stacked
        case percentStacked
    }

    public struct Series: Equatable, Hashable, Sendable {
        public var name: String
        /// One per category; `nil` where there is no value.
        public var values: [Double?]
        /// For a scatter or bubble chart, where each value sits along the x axis.
        public var xValues: [Double?] = []
        /// For a bubble chart, each bubble's size.
        public var sizes: [Double?] = []
        /// The marker symbol the series names, `none` for none.
        public var marker: String?
        /// Whether the series' line is drawn, where its outline says.
        public var hasLine: Bool?
        public var color: DrawingColor?
        /// Colours given to single points, by index: a pie's slices.
        public var pointColors: [Int: DrawingColor] = [:]
        /// Lines fitted to its points.
        public var trendlines: [Trendline] = []
        /// Bars showing each point's margin of error, at most one a direction.
        public var errorBars: [ErrorBars] = []
        /// The series' `c:ser` as the file wrote it.
        public var source: String?

        public init(
            name: String, values: [Double?], xValues: [Double?] = [], color: DrawingColor? = nil,
            pointColors: [Int: DrawingColor] = [:], source: String? = nil
        ) {
            self.name = name
            self.values = values
            self.xValues = xValues
            self.color = color
            self.pointColors = pointColors
            self.source = source
        }
    }

    public struct Plot: Equatable, Hashable, Sendable {
        public var kind: Kind
        public var grouping: Grouping = .standard
        public var series: [Series]
        /// The plot's element — `c:barChart` and the like — as the file wrote it.
        public var source: String?
        /// A doughnut's hole, as a percentage of its size.
        public var holeSize = 50
        /// Drawn with depth: a `bar3DChart`, `pie3DChart` and the like.
        public var isThreeD = false
        /// A radar chart's look.
        public var radarStyle = RadarStyle.marker
        /// A stock chart's lines from each high to low, and its bars from open to close.
        public var hasHighLowLines = false
        public var hasUpDownBars = false
        /// A bubble chart's largest bubble, as a percentage of the default size.
        public var bubbleScale = 100
        /// Whether a bubble's size is its width rather than its area.
        public var sizeIsWidth = false
        /// Whether bubbles of negative size are drawn, as outlines.
        public var showsNegativeBubbles = false
        /// A surface chart drawn as lines only.
        public var isWireframe = false
        /// An of-pie chart's split: which points its second plot shows.
        public var splitType = SplitType.auto
        public var splitPosition: Double?
        /// The points `SplitType.cust` puts in the second plot.
        public var customSplit: [Int] = []
        /// The second plot's size, as a percentage of the first.
        public var secondPieSize = 75
        /// The gap between bars, or between an of-pie chart's two plots, as a percentage.
        public var gapWidth = 150
        /// Whether an of-pie chart draws lines joining its two plots.
        public var hasSeriesLines = false

        public init(
            kind: Kind, grouping: Grouping = .standard, series: [Series], source: String? = nil, holeSize: Int = 50,
            isThreeD: Bool = false
        ) {
            self.kind = kind
            self.grouping = grouping
            self.series = series
            self.source = source
            self.holeSize = holeSize
            self.isThreeD = isThreeD
            if kind == .stock {
                hasHighLowLines = true
                hasUpDownBars = series.count >= 4
            }
            if kind == .pieOfPie || kind == .barOfPie { hasSeriesLines = true }
        }

        /// For an of-pie chart, the indices of the points its second plot shows.
        public func secondPlotPoints(count: Int) -> [Int] {
            let values = (series.first?.values ?? []).prefix(count).map { max($0 ?? 0, 0) }
            switch splitType {
            case .val:
                let limit = splitPosition ?? 0
                return values.indices.filter { values[$0] < limit }
            case .percent:
                let total = values.reduce(0, +)
                let limit = splitPosition ?? 0
                return total > 0 ? values.indices.filter { values[$0] / total * 100 < limit } : []
            case .cust:
                return customSplit.filter { $0 >= 0 && $0 < count }.sorted()
            case .pos, .auto:
                let last = max(0, min(Int(splitPosition ?? Double(max(1, count / 3))), count - 1))
                return Array((count - last)..<count)
            }
        }
    }

    /// The chart's part in the package.
    public var path: String
    public var plots: [Plot]
    public var categories: [String]
    public var title: String?
    public var hasLegend = true
    /// `r`, `b`, `t`, `l` or `tr`.
    public var legendPosition = "r"
    public var showsGridlines = true
    public var showsValueLabels = false
    /// The value axis's limits, where the file fixes them.
    public var minimum: Double?
    public var maximum: Double?
    /// The sheet the chart's data comes from, as its formulas name it.
    public var sheetName = "Sheet1"
    /// Text size, in hundredths of a point, from the chart's text properties.
    public var fontSize: Int?
    /// The number format of categories the file gives as numbers, such as a stock chart's dates.
    public var categoryFormat: String?
    /// The angle a 3D plot is seen from.
    public var view3D: View3D?

    /// The angle 3D plots are seen from: the file's, or PowerPoint's default for the kind.
    public var effectiveView3D: View3D {
        view3D ?? (kind == .pie ? View3D(rotX: 30, rotY: 0) : View3D())
    }

    public var kind: Kind { plots.first?.kind ?? .column }

    /// Every series, in plot order.
    public var allSeries: [Series] { plots.flatMap(\.series) }
}

extension Chart {
    /// Reads a chart part, `c:chartSpace`.
    public init?(path: String, data: Data?) {
        guard let data, let root = try? XMLLite.parse(data), let chart = root.firstChild(named: "chart"),
              let area = chart.firstChild(named: "plotArea") else { return nil }
        self.path = path
        plots = area.children.compactMap(Self.plot)
        categories = []
        guard !plots.isEmpty else { return nil }

        // Categories are given per series; the first that has any speaks for all.
        for element in area.children {
            for series in element.children(named: "ser") {
                let labels = Self.labels(in: series.firstChild(named: "cat"))
                if !labels.isEmpty, categories.isEmpty { categories = labels }
                if let formula = Self.formulas(in: series).first, let sheet = Self.sheetName(in: formula) {
                    sheetName = sheet
                }
            }
        }
        // An x-y chart's first column is the first series' x values.
        if plots.contains(where: { $0.kind.isXY }), categories.isEmpty,
           let xValues = allSeries.first?.xValues, !xValues.isEmpty, xValues.allSatisfy({ $0 != nil }) {
            categories = xValues.map { Self.number($0 ?? 0) }
        }
        categoryFormat = area.children.lazy.flatMap { $0.children(named: "ser") }
            .compactMap { $0.firstChild(named: "cat")?.firstChild(named: "numRef")?.firstChild(named: "numCache") }
            .first.map { $0.firstChild(named: "formatCode")?.text ?? "General" }
        let count = max(categories.count, allSeries.map(\.values.count).max() ?? 0)
        if categories.count < count {
            categories += (categories.count..<count).map { String($0 + 1) }
        }

        if let titleElement = chart.firstChild(named: "title") {
            let text = Self.richText(in: titleElement)
            title = text.isEmpty ? Self.cachedText(in: titleElement.firstChild(named: "tx")) : text
            if title?.isEmpty ?? true {
                // A title with no text of its own shows the series' name, as PowerPoint does for one series.
                title = allSeries.count == 1 ? allSeries[0].name : nil
            }
        }
        if chart.firstChild(named: "autoTitleDeleted")?.attribute("val") == "1", chart.firstChild(named: "title") == nil {
            title = nil
        }
        if let legend = chart.firstChild(named: "legend") {
            hasLegend = true
            legendPosition = legend.firstChild(named: "legendPos")?.attribute("val") ?? "r"
        } else {
            hasLegend = false
        }
        let valueAxis = area.firstChild(named: "valAx")
        showsGridlines = valueAxis?.firstChild(named: "majorGridlines") != nil
        minimum = valueAxis?.firstChild(named: "scaling")?.firstChild(named: "min")?.attribute("val").flatMap(Double.init)
        maximum = valueAxis?.firstChild(named: "scaling")?.firstChild(named: "max")?.attribute("val").flatMap(Double.init)
        showsValueLabels = area.children.contains { plot in
            plot.firstChild(named: "dLbls")?.firstChild(named: "showVal")?.attribute("val") == "1"
        }
        if let view = chart.firstChild(named: "view3D") {
            var view3D = View3D()
            if let rotX = view.firstChild(named: "rotX")?.attribute("val").flatMap(Int.init) { view3D.rotX = rotX }
            if let rotY = view.firstChild(named: "rotY")?.attribute("val").flatMap(Int.init) { view3D.rotY = rotY }
            if let depth = view.firstChild(named: "depthPercent")?.attribute("val").flatMap(Int.init) { view3D.depthPercent = depth }
            self.view3D = view3D
        }
        fontSize = root.firstChild(named: "txPr")?.firstDescendant(atPath: "p/pPr/defRPr")?.attribute("sz").flatMap(Int.init)
    }

    private static func plot(_ element: XMLElement) -> Plot? {
        let kind: Kind
        switch element.name {
        case "barChart", "bar3DChart":
            kind = element.firstChild(named: "barDir")?.attribute("val") == "bar" ? .bar : .column
        case "lineChart", "line3DChart": kind = .line
        case "areaChart", "area3DChart": kind = .area
        case "pieChart", "pie3DChart": kind = .pie
        case "ofPieChart": kind = element.firstChild(named: "ofPieType")?.attribute("val") == "bar" ? .barOfPie : .pieOfPie
        case "doughnutChart": kind = .doughnut
        case "scatterChart": kind = .scatter
        case "bubbleChart": kind = .bubble
        case "radarChart": kind = .radar
        case "stockChart": kind = .stock
        case "surfaceChart", "surface3DChart": kind = .surface
        default: return nil
        }
        let grouping: Grouping = switch element.firstChild(named: "grouping")?.attribute("val") {
        case "stacked": .stacked
        case "percentStacked": .percentStacked
        default: .standard
        }
        func value(_ name: String) -> String? { element.firstChild(named: name)?.attribute("val") }
        func flag(_ name: String) -> Bool? { value(name).map { $0 == "1" || $0 == "true" } ?? element.firstChild(named: name).map { _ in true } }
        var plot = Plot(kind: kind, grouping: grouping, series: element.children(named: "ser").map { Self.series($0, kind: kind) })
        plot.source = XMLLite.serialize(element)
        plot.holeSize = value("holeSize").flatMap(Int.init) ?? 50
        plot.isThreeD = element.name.hasSuffix("3DChart")
        plot.radarStyle = value("radarStyle").flatMap(RadarStyle.init(rawValue:)) ?? .marker
        plot.hasHighLowLines = element.firstChild(named: "hiLowLines") != nil
        plot.hasUpDownBars = element.firstChild(named: "upDownBars") != nil
        plot.bubbleScale = value("bubbleScale").flatMap(Int.init) ?? 100
        plot.sizeIsWidth = value("sizeRepresents") == "w"
        plot.showsNegativeBubbles = flag("showNegBubbles") ?? false
        plot.isWireframe = flag("wireframe") ?? false
        plot.splitType = value("splitType").flatMap(SplitType.init(rawValue:)) ?? .auto
        plot.splitPosition = value("splitPos").flatMap(Double.init)
        plot.customSplit = element.firstChild(named: "custSplit")?.children(named: "secondPiePt")
            .compactMap { $0.attribute("val").flatMap(Int.init) } ?? []
        plot.secondPieSize = value("secondPieSize").flatMap(Int.init) ?? 75
        plot.gapWidth = value("gapWidth").flatMap(Int.init) ?? 150
        plot.hasSeriesLines = element.firstChild(named: "serLines") != nil
        return plot
    }

    private static func series(_ element: XMLElement, kind: Kind) -> Series {
        let name = cachedText(in: element.firstChild(named: "tx")) ?? ""
        let values = numbers(in: element.firstChild(named: kind.isXY ? "yVal" : "val"))
        var series = Series(name: name, values: values)
        if kind.isXY { series.xValues = numbers(in: element.firstChild(named: "xVal")) }
        if kind == .bubble { series.sizes = numbers(in: element.firstChild(named: "bubbleSize")) }
        series.color = color(in: element.firstChild(named: "spPr"), kind: kind)
        series.marker = element.firstChild(named: "marker")?.firstChild(named: "symbol")?.attribute("val")
        if let line = element.firstChild(named: "spPr")?.firstChild(named: "ln") {
            if line.firstChild(named: "noFill") != nil {
                series.hasLine = false
            } else if line.firstChild(named: "solidFill") != nil || line.firstChild(named: "gradFill") != nil {
                series.hasLine = true
            }
        }
        for point in element.children(named: "dPt") {
            if let index = point.firstChild(named: "idx")?.attribute("val").flatMap(Int.init),
               let color = color(in: point.firstChild(named: "spPr"), kind: kind) {
                series.pointColors[index] = color
            }
        }
        series.trendlines = element.children(named: "trendline").map(Trendline.init(element:))
        series.errorBars = element.children(named: "errBars").map { ErrorBars(element: $0, numbers: numbers) }
        series.source = XMLLite.serialize(element)
        return series
    }

    /// A series' colour: its fill, or for a line, its outline.
    private static func color(in properties: XMLElement?, kind: Kind) -> DrawingColor? {
        guard let properties else { return nil }
        if [.line, .scatter, .radar, .stock].contains(kind), let line = properties.firstChild(named: "ln"),
           let color = DrawingColor.first(in: line.firstChild(named: "solidFill")) {
            return color
        }
        return DrawingColor.first(in: properties.firstChild(named: "solidFill"))
            ?? DrawingColor.first(in: properties.firstChild(named: "gradFill")?.firstChild(named: "gsLst")?.firstChild(named: "gs"))
    }

    /// The cached values of a `c:val`, `c:xVal` or `c:yVal`, by point index.
    private static func numbers(in element: XMLElement?) -> [Double?] {
        guard let element else { return [] }
        let cache = element.firstChild(named: "numRef")?.firstChild(named: "numCache") ?? element.firstChild(named: "numLit")
            ?? element.firstChild(named: "strRef")?.firstChild(named: "strCache")
        guard let cache else { return [] }
        let count = cache.firstChild(named: "ptCount")?.attribute("val").flatMap(Int.init) ?? 0
        var values = [Double?](repeating: nil, count: count)
        for point in cache.children(named: "pt") {
            guard let index = point.attribute("idx").flatMap(Int.init) else { continue }
            if index >= values.count { values += [Double?](repeating: nil, count: index - values.count + 1) }
            values[index] = point.firstChild(named: "v").flatMap { Double($0.text.trimmed) }
        }
        return values
    }

    /// The cached labels of a `c:cat`, by point index.
    private static func labels(in element: XMLElement?) -> [String] {
        guard let element else { return [] }
        let cache = element.firstChild(named: "strRef")?.firstChild(named: "strCache")
            ?? element.firstChild(named: "numRef")?.firstChild(named: "numCache")
            ?? element.firstChild(named: "strLit") ?? element.firstChild(named: "numLit")
            ?? element.firstChild(named: "multiLvlStrRef")?.firstChild(named: "multiLvlStrCache")?.firstChild(named: "lvl")
        guard let cache else { return [] }
        let count = cache.firstChild(named: "ptCount")?.attribute("val").flatMap(Int.init) ?? 0
        var labels = [String](repeating: "", count: count)
        for point in cache.children(named: "pt") {
            guard let index = point.attribute("idx").flatMap(Int.init) else { continue }
            if index >= labels.count { labels += [String](repeating: "", count: index - labels.count + 1) }
            labels[index] = point.firstChild(named: "v")?.text ?? ""
        }
        return labels
    }

    /// A number as a chart's first column writes it: whole numbers without a point.
    public static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func cachedText(in element: XMLElement?) -> String? {
        guard let element else { return nil }
        if let cache = element.firstChild(named: "strRef")?.firstChild(named: "strCache") {
            return cache.children(named: "pt").compactMap { $0.firstChild(named: "v")?.text }.joined(separator: " ")
        }
        if let value = element.firstChild(named: "v") { return value.text }
        let rich = richText(in: element)
        return rich.isEmpty ? nil : rich
    }

    /// The text of a title's rich text, paragraph by paragraph.
    private static func richText(in element: XMLElement) -> String {
        guard let rich = element.firstChild(named: "tx")?.firstChild(named: "rich") ?? element.firstChild(named: "rich") else { return "" }
        return rich.children(named: "p").map { paragraph in
            paragraph.children.filter { $0.name == "r" || $0.name == "fld" }.compactMap { $0.firstChild(named: "t")?.text }.joined()
        }.joined(separator: "\n")
    }

    public static func formulas(in element: XMLElement) -> [String] {
        var result: [String] = []
        func visit(_ element: XMLElement) {
            if element.name == "f" { result.append(element.text) }
            element.children.forEach(visit)
        }
        visit(element)
        return result
    }

    /// `Sheet1` from `Sheet1!$B$1`, or `My Sheet` from `'My Sheet'!$B$1`.
    public static func sheetName(in formula: String) -> String? {
        guard let bang = formula.lastIndex(of: "!") else { return nil }
        var name = String(formula[..<bang])
        if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return name.nilIfEmpty
    }
}

extension Chart {
    /// A new chart with the sample data PowerPoint starts one with.
    public static func sample(_ kind: Kind, path: String) -> Chart {
        if kind.colorsByPoint {
            return Chart(
                path: path,
                plots: [Plot(kind: kind, series: [Series(name: String(localized: "Chart.Sample.Sales", bundle: .engine), values: [8.2, 3.2, 1.4, 1.2])])],
                categories: (1...4).map { String(format: String(localized: "Chart.Sample.Quarter", bundle: .engine), $0) },
                title: String(localized: "Chart.Sample.Sales", bundle: .engine), legendPosition: "b"
            )
        }
        if kind == .stock {
            let names = [
                String(localized: "Chart.Sample.High", bundle: .engine), String(localized: "Chart.Sample.Low", bundle: .engine),
                String(localized: "Chart.Sample.Close", bundle: .engine),
            ]
            let values: [[Double?]] = [[55, 57, 57, 58, 58], [11, 12, 13, 11, 25], [25, 38, 50, 35, 43]]
            return Chart(
                path: path,
                plots: [Plot(kind: .stock, series: zip(names, values).map { name, values in
                    var series = Series(name: name, values: values)
                    series.hasLine = false
                    return series
                })],
                categories: (1...5).map { String(format: String(localized: "Chart.Sample.Category", bundle: .engine), $0) },
                title: nil, legendPosition: "b"
            )
        }
        let values: [[Double?]] = [[4.3, 2.5, 3.5, 4.5], [2.4, 4.4, 1.8, 2.8], [2, 2, 3, 5]]
        let categories = kind.isXY
            ? ["0.7", "1.8", "2.6", "3.4"]
            : (1...4).map { String(format: String(localized: "Chart.Sample.Category", bundle: .engine), $0) }
        return Chart(
            path: path,
            plots: [Plot(kind: kind, series: values.enumerated().map { index, values in
                var series = Series(name: String(format: String(localized: "Chart.Sample.Series", bundle: .engine), index + 1), values: values)
                if kind == .bubble { series.sizes = [10, 4, 6, 8].map { $0 + Double(index) } }
                return series
            })],
            categories: categories, title: nil, legendPosition: "b"
        )
    }
}

