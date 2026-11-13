import Foundation

/// Office 2016's charts — waterfall, funnel, treemap, sunburst, histogram,
/// Pareto, and box and whisker — which are kept in a `cx:chartSpace` part
/// rather than a `c:chartSpace`. Their data is read into the same `Chart`,
/// with what each kind works out from it: a histogram's bins, a box's
/// quartiles, a treemap's branches.
extension Chart {
    /// Where a treemap names its branches.
    public enum ParentLabels: String, CaseIterable, Sendable {
        /// Over the branch's top left corner.
        case overlapping
        /// In a strip of its own above the branch.
        case banner
        case none
    }

    /// What a `cx:series` says of its layout, in its `cx:layoutPr`.
    public struct Extended: Equatable, Hashable, Sendable {
        /// A waterfall's points that are totals, standing from zero.
        public var subtotals: [Int] = []
        /// A histogram's bins: how wide each is, or how many there are. Neither, and Office picks.
        public var binSize: Double?
        public var binCount: Int?
        /// The values at or under which, and over which, a histogram gathers the rest into one bin.
        public var underflow: Double?
        public var overflow: Double?
        /// Whether a bin takes in its lower limit rather than its upper.
        public var binsCloseLeft = false
        /// A histogram that adds up the values of each category instead of sorting them into bins.
        public var aggregatesByCategory = false
        public var parentLabels = ParentLabels.overlapping
        /// What a box and whisker chart shows besides its boxes.
        public var showsMeanLine = false
        public var showsMeanMarker = true
        public var showsInnerPoints = false
        public var showsOutliers = true
        /// Whether an odd number of values counts its median in both halves when finding the quartiles.
        public var quartilesIncludeMedian = false

        public init() {}
    }

    /// Reads a `cx:chartSpace`.
    init?(extendedPath path: String, root: XMLElement) {
        guard let chart = root.firstChild(named: "chart"), let area = chart.firstChild(named: "plotArea") else { return nil }
        let elements = (area.firstChild(named: "plotAreaRegion")?.children(named: "series") ?? [])
            .filter { $0.attribute("hidden") != "1" }
        // A Pareto chart is a histogram with a line beside it, which is worked out from the columns.
        let columns = elements.filter { $0.attribute("layoutId") != "paretoLine" }
        let kind: Kind
        switch columns.first?.attribute("layoutId") {
        case "waterfall": kind = .waterfall
        case "funnel": kind = .funnel
        case "treemap": kind = .treemap
        case "sunburst": kind = .sunburst
        case "boxWhisker": kind = .boxWhisker
        case "clusteredColumn": kind = columns.count < elements.count ? .pareto : .histogram
        default: return nil
        }

        var blocks: [String: XMLElement] = [:]
        for block in root.firstChild(named: "chartData")?.children(named: "data") ?? [] {
            blocks[block.attribute("id") ?? ""] = block
        }
        func block(of series: XMLElement) -> XMLElement? {
            blocks[series.firstChild(named: "dataId")?.attribute("val") ?? ""]
        }
        func dimension(_ block: XMLElement?, types: [String]) -> XMLElement? {
            let dimensions = block?.children.filter { $0.name == "numDim" || $0.name == "strDim" } ?? []
            return types.lazy.compactMap { type in dimensions.first { $0.attribute("type") == type } }.first
        }

        var plot = Plot(kind: kind, series: columns.map { element in
            let values = dimension(block(of: element), types: kind == .treemap || kind == .sunburst ? ["size", "val"] : ["val", "size"])
            var series = Series(
                name: element.firstChild(named: "tx")?.firstChild(named: "txData")?.firstChild(named: "v")?.text ?? "",
                values: Self.extendedPoints(in: values?.firstChild(named: "lvl")).map { Double($0.trimmed) }
            )
            series.color = Self.extendedColor(in: element.firstChild(named: "spPr"))
            for point in element.children(named: "dataPt") {
                if let index = point.attribute("idx").flatMap(Int.init), let color = Self.extendedColor(in: point.firstChild(named: "spPr")) {
                    series.pointColors[index] = color
                }
            }
            return series
        })
        guard !plot.series.isEmpty else { return nil }
        if let layout = columns.first?.firstChild(named: "layoutPr") {
            plot.extended = Self.extendedLayout(layout)
        }

        self.init(path: path, plots: [plot], categories: [])
        // Levels are given leaf first; a chart of one level has only its categories.
        let labels = dimension(columns.lazy.compactMap(block).first, types: ["cat"])
        let levels = (labels?.children(named: "lvl") ?? []).map(Self.extendedPoints)
        let count = max(levels.map(\.count).max() ?? 0, allSeries.map(\.values.count).max() ?? 0)
        let padded = levels.map { $0 + Array(repeating: "", count: count - $0.count) }
        if kind == .treemap || kind == .sunburst {
            categoryLevels = padded.reversed()
            // A point's own name is its innermost label.
            categories = (0..<count).map { index in padded.lazy.map { $0[index] }.first { !$0.isEmpty } ?? "" }
        } else {
            categories = padded.first ?? []
        }
        // A histogram of values alone has no categories; the others number theirs.
        if categories.isEmpty, kind != .histogram, kind != .pareto, kind != .boxWhisker {
            categories = (0..<count).map { String($0 + 1) }
        }
        if let formula = Self.formulas(in: root).first, let sheet = Self.sheetName(in: formula) { sheetName = sheet }

        if let titleElement = chart.firstChild(named: "title") {
            let text = titleElement.firstChild(named: "tx")
            let rich = (text?.firstChild(named: "rich")?.children(named: "p") ?? []).map { paragraph in
                paragraph.children.filter { $0.name == "r" || $0.name == "fld" }.compactMap { $0.firstChild(named: "t")?.text }.joined()
            }.joined(separator: "\n")
            // A title with no text of its own reads "Chart Title", as Office shows it.
            title = rich.nilIfEmpty ?? text?.firstChild(named: "txData")?.firstChild(named: "v")?.text.nilIfEmpty
                ?? String(localized: "Chart.Title.Default", bundle: .engine)
        }
        if let legend = chart.firstChild(named: "legend") {
            hasLegend = true
            legendPosition = legend.attribute("pos") ?? "r"
        } else {
            hasLegend = false
        }
        let valueAxis = area.children(named: "axis").first { $0.attribute("hidden") != "1" && $0.firstChild(named: "valScaling") != nil }
        showsGridlines = valueAxis?.firstChild(named: "majorGridlines") != nil
        minimum = valueAxis?.firstChild(named: "valScaling")?.attribute("min").flatMap(Double.init)
        maximum = valueAxis?.firstChild(named: "valScaling")?.attribute("max").flatMap(Double.init)
        showsValueLabels = columns.contains { series in
            guard let labels = series.firstChild(named: "dataLabels") else { return false }
            return labels.firstChild(named: "visibility")?.attribute("value") != "0"
        }
        fontSize = root.firstChild(named: "txPr")?.firstDescendant(atPath: "p/pPr/defRPr")?.attribute("sz").flatMap(Int.init)
    }

    /// The text of a `cx:lvl`'s points, by index.
    private static func extendedPoints(in level: XMLElement?) -> [String] {
        guard let level else { return [] }
        var points = [String](repeating: "", count: level.attribute("ptCount").flatMap(Int.init) ?? 0)
        for point in level.children(named: "pt") {
            guard let index = point.attribute("idx").flatMap(Int.init), index >= 0 else { continue }
            if index >= points.count { points += [String](repeating: "", count: index - points.count + 1) }
            points[index] = point.text
        }
        return points
    }

    private static func extendedColor(in properties: XMLElement?) -> DrawingColor? {
        DrawingColor.first(in: properties?.firstChild(named: "solidFill"))
            ?? DrawingColor.first(in: properties?.firstChild(named: "gradFill")?.firstChild(named: "gsLst")?.firstChild(named: "gs"))
    }

    private static func extendedLayout(_ layout: XMLElement) -> Extended {
        var extended = Extended()
        func flag(_ value: String?, default fallback: Bool) -> Bool { value.map { $0 == "1" || $0 == "true" } ?? fallback }
        extended.subtotals = layout.firstChild(named: "subtotals")?.children(named: "idx")
            .compactMap { $0.attribute("val").flatMap(Int.init) } ?? []
        if let binning = layout.firstChild(named: "binning") {
            extended.binSize = binning.firstChild(named: "binSize")?.attribute("val").flatMap(Double.init)
            extended.binCount = binning.firstChild(named: "binCount")?.attribute("val").flatMap(Int.init)
            extended.underflow = binning.attribute("underflow").flatMap(Double.init)
            extended.overflow = binning.attribute("overflow").flatMap(Double.init)
            extended.binsCloseLeft = binning.attribute("intervalClosed") == "l"
        }
        extended.aggregatesByCategory = layout.firstChild(named: "aggregation") != nil
        extended.parentLabels = layout.firstChild(named: "parentLabelLayout")?.attribute("val")
            .flatMap(ParentLabels.init(rawValue:)) ?? .overlapping
        if let visibility = layout.firstChild(named: "visibility") {
            extended.showsMeanLine = flag(visibility.attribute("meanLine"), default: false)
            extended.showsMeanMarker = flag(visibility.attribute("meanMarker"), default: true)
            extended.showsInnerPoints = flag(visibility.attribute("nonoutliers"), default: false)
            extended.showsOutliers = flag(visibility.attribute("outliers"), default: true)
        }
        extended.quartilesIncludeMedian = layout.firstChild(named: "statistics")?.attribute("quartileMethod") == "inclusive"
        return extended
    }
}

// MARK: - Waterfall

extension Chart {
    /// A waterfall's column: where it runs from and to, and whether it is a total.
    public struct WaterfallBar: Equatable, Sendable {
        public var from: Double
        public var to: Double
        public var isTotal: Bool
        /// The point's own value, as its label gives it.
        public var value: Double
    }

    /// A waterfall's columns, by category: each from where the last ended, a
    /// total from zero to its value. `nil` where a point has no value.
    public func waterfallBars() -> [WaterfallBar?] {
        guard let plot = plots.first, let series = plot.series.first else { return [] }
        let totals = Set(plot.extended.subtotals)
        var running = 0.0
        return (0..<max(categories.count, series.values.count)).map { index in
            guard series.values.indices.contains(index), let value = series.values[index] else { return nil }
            if totals.contains(index) {
                running = value
                return WaterfallBar(from: 0, to: value, isTotal: true, value: value)
            }
            defer { running += value }
            return WaterfallBar(from: running, to: running + value, isTotal: false, value: value)
        }
    }
}

// MARK: - Histogram and Pareto

extension Chart {
    /// One of a histogram's columns: its range, or its category, and how many values fall in it.
    public struct Bin: Equatable, Sendable {
        public var label: String
        public var count: Double
    }

    /// A histogram's columns, in order; a Pareto chart's from the tallest down.
    public func bins() -> [Bin] {
        guard let plot = plots.first, let series = plot.series.first else { return [] }
        var bins: [Bin]
        if plot.extended.aggregatesByCategory {
            // One column per category, the sum of its values, in the order they first come.
            var order: [String] = []
            var sums: [String: Double] = [:]
            for (index, category) in categories.enumerated() {
                if sums[category] == nil { order.append(category) }
                sums[category, default: 0] += series.values.indices.contains(index) ? series.values[index] ?? 0 : 1
            }
            bins = order.map { Bin(label: $0, count: sums[$0] ?? 0) }
        } else {
            bins = Self.bins(of: series.values.compactMap(\.self), layout: plot.extended)
        }
        if kind == .pareto {
            // Stable, so that columns of one height keep their order.
            bins = bins.enumerated().sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
                .map(\.element)
        }
        return bins
    }

    /// Values sorted into ranges of one width: Office's own, from Scott's
    /// rule, unless the chart gives a width or a count.
    public static func bins(of values: [Double], layout: Extended) -> [Bin] {
        guard let lowest = values.min(), let highest = values.max() else { return [] }
        func text(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
        var result: [Bin] = []
        var low = lowest
        var high = highest
        var inside = values
        if let underflow = layout.underflow, underflow > lowest {
            result.append(Bin(label: "≤ \(text(underflow))", count: Double(values.filter { $0 <= underflow }.count)))
            inside = inside.filter { $0 > underflow }
            low = underflow
        }
        var over: Bin?
        if let overflow = layout.overflow, overflow < highest {
            over = Bin(label: "> \(text(overflow))", count: Double(values.filter { $0 > overflow }.count))
            inside = inside.filter { $0 <= overflow }
            high = overflow
        }
        if high > low {
            var width: Double
            var count: Int
            if let size = layout.binSize, size > 0 {
                width = size
                count = Int(((high - low) / width - 1e-9).rounded(.up))
            } else if let wanted = layout.binCount, wanted > 0 {
                count = wanted
                width = (high - low) / Double(count)
            } else {
                // Scott's rule: 3.49 standard deviations over the cube root of how many there are.
                let mean = values.reduce(0, +) / Double(values.count)
                let variance = values.count > 1 ? values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1) : 0
                width = 3.49 * variance.squareRoot() / pow(Double(values.count), 1.0 / 3)
                if width <= 0 { width = high - low }
                count = Int(((high - low) / width - 1e-9).rounded(.up))
            }
            count = min(max(count, 1), 500)
            var counts = [Double](repeating: 0, count: count)
            for value in inside {
                let position = (value - low) / width
                let index = layout.binsCloseLeft ? Int(position.rounded(.down)) : Int((position - 1e-9).rounded(.up)) - 1
                counts[min(max(index, 0), count - 1)] += 1
            }
            for index in 0..<count {
                let from = text(low + width * Double(index))
                let to = text(low + width * Double(index + 1))
                // The first bin takes in both its limits, or the last where bins close on the left.
                let opens = layout.binsCloseLeft || (index == 0 && layout.underflow == nil) ? "[" : "("
                let closes = !layout.binsCloseLeft || (index == count - 1 && over == nil) ? "]" : ")"
                result.append(Bin(label: "\(opens)\(from), \(to)\(closes)", count: counts[index]))
            }
        } else if !inside.isEmpty {
            result.append(Bin(label: "[\(text(low)), \(text(high))]", count: Double(inside.count)))
        }
        if let over { result.append(over) }
        return result
    }
}

// MARK: - Box and whisker

extension Chart {
    /// What a box and whisker draws of a set of values.
    public struct BoxStatistics: Equatable, Sendable {
        /// The ends of the whiskers: the furthest values that aren't outliers.
        public var low: Double
        public var high: Double
        public var firstQuartile: Double
        public var median: Double
        public var thirdQuartile: Double
        public var mean: Double
        /// Values further than one and a half boxes from the box.
        public var outliers: [Double]
        /// The rest.
        public var inner: [Double]
    }

    public static func boxStatistics(_ values: [Double], includingMedian: Bool) -> BoxStatistics? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        func median(_ values: ArraySlice<Double>) -> Double {
            let middle = values.startIndex + values.count / 2
            return values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2
        }
        let count = sorted.count
        // Each half's median: an odd count's middle value is in both halves, or neither.
        let half = count == 1 ? 1 : (count % 2 == 1 && includingMedian ? count / 2 + 1 : count / 2)
        let first = median(sorted[..<half])
        let third = median(sorted[(count - half)...])
        let reach = (third - first) * 1.5
        let inner = sorted.filter { $0 >= first - reach && $0 <= third + reach }
        return BoxStatistics(
            low: inner.first ?? first, high: inner.last ?? third, firstQuartile: first, median: median(sorted[...]), thirdQuartile: third,
            mean: sorted.reduce(0, +) / Double(count), outliers: sorted.filter { $0 < first - reach || $0 > third + reach }, inner: inner
        )
    }

    /// A box and whisker chart's categories, each once, in the order they first come.
    public var boxCategories: [String] {
        var seen = Set<String>()
        let unique = categories.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [""] : unique
    }

    /// A series' values in each of `boxCategories`.
    public func boxValues(of series: Series) -> [[Double]] {
        let names = boxCategories
        var groups = [[Double]](repeating: [], count: names.count)
        for (index, value) in series.values.enumerated() {
            guard let value else { continue }
            let group = categories.indices.contains(index) ? names.firstIndex(of: categories[index]) ?? 0 : 0
            groups[group].append(value)
        }
        return groups
    }
}

// MARK: - Treemap and sunburst

extension Chart {
    /// A branch or a leaf of a treemap or sunburst.
    public struct Node: Equatable, Sendable {
        public var name: String
        /// A leaf's own value, or the sum of a branch's leaves.
        public var value: Double
        public var children: [Node] = []
        /// For the outermost, which of the chart's colours it and all under it take.
        public var colorIndex = 0

        public var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }
    }

    /// The chart's points gathered under their branches, the largest first at every level.
    public func hierarchy() -> [Node] {
        guard let series = plots.first?.series.first else { return [] }
        let levels = categoryLevels.isEmpty ? [categories] : categoryLevels
        var roots: [Node] = []
        func add(_ path: ArraySlice<String>, value: Double, to nodes: inout [Node]) {
            guard let name = path.first else { return }
            let index = nodes.firstIndex { $0.name == name } ?? {
                nodes.append(Node(name: name, value: 0))
                return nodes.count - 1
            }()
            nodes[index].value += value
            add(path.dropFirst(), value: value, to: &nodes[index].children)
        }
        for (index, value) in series.values.enumerated() {
            guard let value, value > 0 else { continue }
            // A point with no label at a level sits one ring further in.
            let path = levels.compactMap { $0.indices.contains(index) ? $0[index].nilIfEmpty : nil }
            add(path[...], value: value, to: &roots)
        }
        for index in roots.indices { roots[index].colorIndex = index }
        func sorted(_ nodes: [Node]) -> [Node] {
            nodes.map { node in
                var node = node
                node.children = sorted(node.children)
                return node
            }.enumerated().sorted { $0.element.value != $1.element.value ? $0.element.value > $1.element.value : $0.offset < $1.offset }
                .map(\.element)
        }
        return sorted(roots)
    }
}
