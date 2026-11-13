#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// How a line of chart text sits in its rectangle.
public enum ChartTextAlignment: Sendable {
    case left
    case center
    case right
}

/// Where a chart is drawn: Core Graphics on Apple platforms, SVG on the web.
/// Every chart is drawn from these few primitives, so it looks the same on both.
public protocol ChartCanvas: AnyObject {
    func fill(_ rect: CGRect, color: RGBAColor)
    func draw(_ path: CGPath, fill: RGBAColor?, stroke: RGBAColor?, lineWidth: CGFloat, round: Bool)
    /// One line of text, vertically centred in `rect`.
    func text(_ text: String, in rect: CGRect, size: CGFloat, alignment: ChartTextAlignment, color: RGBAColor)
    /// How wide a line of text sets.
    func measure(_ text: String, size: CGFloat) -> CGFloat
    /// How tall a line of text sets.
    func lineHeight(size: CGFloat) -> CGFloat
}

/// Draws a chart from its data, in the look PowerPoint gives a new chart:
/// theme accent colours, light gridlines, a legend, and the title above.
public struct ChartPainter {
    public let chart: Chart
    public let style: SlideStyleContext

    public init(chart: Chart, style: SlideStyleContext) {
        self.chart = chart
        self.style = style
    }

    var fontSize: CGFloat { CGFloat(chart.fontSize ?? 1_200) / 100 }
    var textColor: RGBAColor {
        style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 65_000)).applying(.init(name: "lumOff", value: 35_000))
    }
    var gridColor: RGBAColor {
        style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 15_000)).applying(.init(name: "lumOff", value: 85_000))
    }
    var axisColor: RGBAColor { gridColor.applying(.init(name: "lumMod", value: 75_000)) }
    var background: RGBAColor { style.color(.scheme("bg1")) }

    /// Draws the chart filling `frame`, in a space whose y axis points down.
    public func draw(in frame: CGRect, on canvas: ChartCanvas) {
        guard frame.width > 20, frame.height > 20 else { return }
        let padding = min(frame.width, frame.height) * 0.04 + 4
        var area = frame.insetBy(dx: padding, dy: padding)

        if let title = chart.title, !title.isEmpty {
            let size = fontSize * 1.55
            let height = canvas.lineHeight(size: size)
            text(title, in: CGRect(x: area.minX, y: area.minY, width: area.width, height: size * 1.4), size: size, alignment: .center, canvas: canvas)
            area.origin.y += height + padding / 2
            area.size.height -= height + padding / 2
        }
        if chart.hasLegend { area = legend(in: area, padding: padding, canvas: canvas) }
        guard area.width > 10, area.height > 10 else { return }

        switch chart.kind {
        case .pie, .doughnut:
            if chart.plots.first?.isThreeD == true, chart.kind == .pie {
                pie3D(in: area, canvas: canvas)
            } else {
                pie(in: area, canvas: canvas)
            }
        case .pieOfPie, .barOfPie: ofPie(in: area, canvas: canvas)
        case .scatter: scatter(in: area, canvas: canvas)
        case .bubble: bubbles(in: area, canvas: canvas)
        case .radar: radar(in: area, canvas: canvas)
        case .surface: surface(in: area, canvas: canvas)
        case .waterfall, .funnel, .treemap, .sunburst, .histogram, .pareto, .boxWhisker: extended(in: area, canvas: canvas)
        default: categoryPlots(in: area, canvas: canvas)
        }
    }

    // MARK: - Colours

    /// The colour of the `index`th series or slice: the theme's six accents,
    /// then the same again darker, then lighter.
    public func color(at index: Int) -> RGBAColor {
        var color = DrawingColor.scheme("accent\(index % 6 + 1)")
        switch (index / 6) % 3 {
        case 1: color.transforms = [.init(name: "lumMod", value: 60_000)]
        case 2: color.transforms = [.init(name: "lumMod", value: 80_000), .init(name: "lumOff", value: 20_000)]
        default: break
        }
        return style.color(color)
    }

    func seriesColor(_ series: Chart.Series, index: Int) -> RGBAColor {
        series.color.map { style.color($0) } ?? color(at: index)
    }

    func pointColor(_ series: Chart.Series, at index: Int) -> RGBAColor {
        series.pointColors[index].map { style.color($0) } ?? color(at: index)
    }

    /// A face of a 3D shape turned from the light: darker.
    private func shaded(_ color: RGBAColor, _ lumMod: Int) -> RGBAColor {
        color.applying(.init(name: "lumMod", value: lumMod))
    }

    /// A face of a 3D shape turned to the light: lighter.
    private func lit(_ color: RGBAColor) -> RGBAColor {
        color.applying(.init(name: "lumMod", value: 80_000)).applying(.init(name: "lumOff", value: 20_000))
    }

    // MARK: - Legend

    /// What the legend lists: categories for a pie, value bands for a surface, series otherwise.
    func legendEntries() -> [(String, RGBAColor)] {
        if chart.kind.isExtended { return extendedLegendEntries() }
        if chart.kind.colorsByPoint {
            guard let series = chart.plots.first?.series.first else { return [] }
            var entries = chart.categories.enumerated().map { index, name in (formatCategory(name), pointColor(series, at: index)) }
            if let plot = chart.plots.first, chart.kind == .pieOfPie || chart.kind == .barOfPie,
               !plot.secondPlotPoints(count: chart.categories.count).isEmpty {
                entries.append((String(localized: "Chart.Other", bundle: .engine), color(at: chart.categories.count)))
            }
            return entries
        }
        if chart.kind == .surface {
            let scale = surfaceScale()
            return zip(scale.ticks, scale.ticks.dropFirst()).enumerated().map { index, band in
                ("\(format(band.0, percent: false))-\(format(band.1, percent: false))", color(at: index))
            }
        }
        return chart.allSeries.enumerated().map { ($1.name, seriesColor($1, index: $0)) }
    }

    private func legend(in area: CGRect, padding: CGFloat, canvas: ChartCanvas) -> CGRect {
        let entries = legendEntries()
        guard !entries.isEmpty else { return area }
        let swatch = fontSize * 0.7
        let lineHeight = fontSize * 1.5
        let widths = entries.map { canvas.measure($0.0, size: fontSize) + swatch + fontSize * 0.5 }
        var plot = area
        switch chart.legendPosition {
        case "b", "t":
            let total = widths.reduce(0, +) + CGFloat(entries.count - 1) * fontSize
            var x = area.midX - min(total, area.width) / 2
            let y = chart.legendPosition == "b" ? area.maxY - lineHeight : area.minY
            for (index, entry) in entries.enumerated() {
                legendEntry(entry, at: CGPoint(x: x, y: y + (lineHeight - swatch) / 2), swatch: swatch, canvas: canvas)
                x += widths[index] + fontSize
            }
            plot.size.height -= lineHeight + padding / 2
            if chart.legendPosition == "t" { plot.origin.y += lineHeight + padding / 2 }
        default:
            let width = min((widths.max() ?? 0) + padding, area.width * 0.4)
            let total = CGFloat(entries.count) * lineHeight
            var y = area.midY - total / 2
            let x = chart.legendPosition == "l" ? area.minX : area.maxX - width + padding / 2
            for entry in entries {
                legendEntry(entry, at: CGPoint(x: x, y: y + (lineHeight - swatch) / 2), swatch: swatch, canvas: canvas)
                y += lineHeight
            }
            plot.size.width -= width
            if chart.legendPosition == "l" { plot.origin.x += width }
        }
        return plot
    }

    private func legendEntry(_ entry: (String, RGBAColor), at point: CGPoint, swatch: CGFloat, canvas: ChartCanvas) {
        canvas.fill(CGRect(x: point.x, y: point.y, width: swatch, height: swatch), color: entry.1)
        text(entry.0, in: CGRect(x: point.x + swatch + fontSize * 0.35, y: point.y + swatch / 2 - fontSize * 0.7, width: 1_000, height: fontSize * 1.4),
             size: fontSize, alignment: .left, canvas: canvas)
    }

    // MARK: - Scales

    /// Where a value axis runs, and its steps.
    public struct Scale: Equatable {
        public var minimum: Double
        public var maximum: Double
        public var step: Double

        /// A range from `low` to `high` rounded out to steps of 1, 2 or 5
        /// times a power of ten, about five of them. It takes in zero unless
        /// `fromZero` is off, as for prices that are all far above it.
        public static func nice(
            low: Double, high: Double, fixedMinimum: Double? = nil, fixedMaximum: Double? = nil, fromZero: Bool = true
        ) -> Scale {
            var low = fromZero ? min(low, 0) : low
            var high = fromZero ? max(high, 0) : high
            if let fixedMinimum { low = fixedMinimum }
            if let fixedMaximum { high = fixedMaximum }
            if high <= low { high = low + 1 }
            let rough = (high - low) / 5
            let magnitude = pow(10, floor(log10(rough)))
            let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? rough
            return Scale(
                minimum: fixedMinimum ?? floor(low / step) * step,
                maximum: fixedMaximum ?? ceil(high / step) * step, step: step
            )
        }

        public var ticks: [Double] {
            guard step > 0, maximum > minimum else { return [minimum] }
            return Array(stride(from: minimum, through: maximum + step / 1_000, by: step))
        }

        /// How far along the axis `value` is, from 0 to 1.
        public func fraction(_ value: Double) -> Double { (value - minimum) / (maximum - minimum) }
    }

    /// Whether a plot is drawn against an axis of its own, on the right: a
    /// stock chart's prices beside its volume.
    private func isSecondary(_ plot: Chart.Plot) -> Bool {
        plot.kind == .stock && chart.plots.contains { $0.kind != .stock }
    }

    private func valueScale(_ plots: [Chart.Plot], fixed: Bool) -> Scale {
        var low = Double.infinity
        var high = -Double.infinity
        for plot in plots {
            let count = chart.categories.count
            if plot.grouping == .percentStacked, plot.kind.hasGrouping {
                low = min(low, 0)
                high = max(high, 1)
                continue
            }
            if plot.grouping == .stacked, plot.kind.hasGrouping, plot.kind != .line {
                for index in 0..<count {
                    let values = plot.series.compactMap { $0.values.indices.contains(index) ? $0.values[index] : nil }
                    high = max(high, values.filter { $0 > 0 }.reduce(0, +))
                    low = min(low, values.filter { $0 < 0 }.reduce(0, +))
                }
            } else {
                let values = plot.series.flatMap { $0.values.prefix(max(count, 1)).compactMap(\.self) }
                high = max(high, values.max() ?? 0)
                low = min(low, values.min() ?? 0)
            }
        }
        if !low.isFinite { low = 0 }
        if !high.isFinite { high = 0 }
        // Prices all well above zero start from near the lowest, as Office's axes do.
        let fromZero = !(plots.allSatisfy { $0.kind == .stock } && low > 0 && low > high * 5 / 6)
        return .nice(
            low: low, high: high, fixedMinimum: fixed ? chart.minimum : nil, fixedMaximum: fixed ? chart.maximum : nil, fromZero: fromZero
        )
    }

    // MARK: - Columns, bars, lines, areas and stock

    /// How far back a 3D plot's depth runs, as an oblique offset.
    private func depthOffset(for size: CGSize) -> CGSize {
        let view = chart.effectiveView3D
        let depth = min(size.width, size.height) * 0.1 * CGFloat(min(max(view.depthPercent, 20), 300)) / 100
        let turn = CGFloat(view.rotY % 360 + (view.rotY < 0 ? 360 : 0))
        let side: CGFloat = turn > 180 ? -1 : 1
        let tilt = min(max(CGFloat(view.rotX) / 15, -2), 2)
        return CGSize(width: depth * 0.8 * side, height: -depth * 0.55 * tilt)
    }

    private func categoryPlots(in area: CGRect, canvas: ChartCanvas) {
        let horizontal = chart.kind == .bar
        let primaryPlots = chart.plots.filter { !isSecondary($0) }
        let secondaryPlots = chart.plots.filter(isSecondary)
        let scale = valueScale(primaryPlots.isEmpty ? chart.plots : primaryPlots, fixed: true)
        let secondary = secondaryPlots.isEmpty ? nil : valueScale(secondaryPlots, fixed: false)
        let isPercent = chart.plots.first?.grouping == .percentStacked && chart.kind.hasGrouping
        let labels = scale.ticks.map { format($0, percent: isPercent) }
        let labelWidth = (labels.map { canvas.measure($0, size: fontSize) }.max() ?? 0) + fontSize * 0.5
        let secondaryLabels = secondary?.ticks.map { format($0, percent: false) } ?? []
        let secondaryWidth = secondary == nil ? 0 : (secondaryLabels.map { canvas.measure($0, size: fontSize) }.max() ?? 0) + fontSize * 0.5
        let categoryHeight = fontSize * 1.6
        let categoryNames = chart.categories.map(formatCategory)
        var plot = area
        if horizontal {
            let widest = (categoryNames.map { canvas.measure($0, size: fontSize) }.max() ?? 0) + fontSize * 0.6
            plot.origin.x += min(widest, area.width * 0.3)
            plot.size.width -= min(widest, area.width * 0.3)
            plot.size.height -= categoryHeight
        } else {
            plot.origin.x += labelWidth
            plot.size.width -= labelWidth + secondaryWidth
            plot.size.height -= categoryHeight
        }
        guard plot.width > 4, plot.height > 4 else { return }

        // A 3D plot's front face, with room behind it for its depth.
        let isThreeD = chart.plots.contains { $0.isThreeD && $0.kind.hasThreeD }
        let depth = isThreeD ? depthOffset(for: plot.size) : .zero
        if isThreeD {
            if depth.width < 0 { plot.origin.x -= depth.width }
            if depth.height < 0 { plot.origin.y -= depth.height }
            plot.size.width -= abs(depth.width)
            plot.size.height -= abs(depth.height)
            guard plot.width > 4, plot.height > 4 else { return }
        }

        // A value's position along the value axis.
        func position(_ value: Double, on scale: Scale) -> CGFloat {
            let fraction = scale.fraction(value)
            return horizontal ? plot.minX + plot.width * fraction : plot.maxY - plot.height * fraction
        }

        // Gridlines and value labels: on a 3D plot's back wall, and across its side wall.
        for (index, tick) in scale.ticks.enumerated() {
            let at = position(tick, on: scale)
            if chart.showsGridlines {
                let from = horizontal ? CGPoint(x: at, y: plot.maxY) : CGPoint(x: plot.minX, y: at)
                let to = horizontal ? CGPoint(x: at, y: plot.minY) : CGPoint(x: plot.maxX, y: at)
                if isThreeD {
                    line(from: from, to: from.offset(depth), color: gridColor, width: 0.75, canvas: canvas)
                }
                line(from: from.offset(depth), to: to.offset(depth), color: gridColor, width: 0.75, canvas: canvas)
            }
            if horizontal {
                text(labels[index], in: CGRect(x: at - 40, y: plot.maxY + fontSize * 0.2, width: 80, height: fontSize * 1.4),
                     size: fontSize, alignment: .center, canvas: canvas)
            } else {
                text(labels[index], in: CGRect(x: area.minX, y: at - fontSize * 0.7, width: labelWidth - fontSize * 0.4, height: fontSize * 1.4),
                     size: fontSize, alignment: .right, canvas: canvas)
            }
        }
        if let secondary {
            for (index, tick) in secondary.ticks.enumerated() {
                let at = position(tick, on: secondary)
                text(secondaryLabels[index], in: CGRect(x: plot.maxX + abs(depth.width) + fontSize * 0.4, y: at - fontSize * 0.7,
                                                        width: secondaryWidth, height: fontSize * 1.4),
                     size: fontSize, alignment: .left, canvas: canvas)
            }
        }

        let count = max(chart.categories.count, 1)
        let band = (horizontal ? plot.height : plot.width) / CGFloat(count)
        // Category labels, skipping some where they would collide.
        let widest = categoryNames.map { canvas.measure($0, size: fontSize) }.max() ?? 0
        let every = horizontal ? 1 : max(Int(ceil((widest + fontSize) / max(band, 1))), 1)
        for (index, name) in categoryNames.enumerated() where index % every == 0 {
            // Bars list their categories from the bottom up, as PowerPoint does.
            let center = horizontal ? plot.maxY - band * (CGFloat(index) + 0.5) : plot.minX + band * (CGFloat(index) + 0.5)
            if horizontal {
                text(name, in: CGRect(x: area.minX, y: center - fontSize * 0.7, width: plot.minX - area.minX - fontSize * 0.3, height: fontSize * 1.4),
                     size: fontSize, alignment: .right, canvas: canvas)
            } else {
                text(name, in: CGRect(x: center - band * CGFloat(every) / 2, y: plot.maxY + fontSize * 0.2, width: band * CGFloat(every), height: fontSize * 1.4),
                     size: fontSize, alignment: .center, canvas: canvas)
            }
        }

        var seriesIndex = 0
        for plotData in chart.plots {
            let plotScale = isSecondary(plotData) ? secondary ?? scale : scale
            let place = { (value: Double) in position(value, on: plotScale) }
            let threeD = plotData.isThreeD ? depth : nil
            switch plotData.kind {
            case .column, .bar:
                bars(plotData, firstIndex: seriesIndex, band: band, plot: plot, horizontal: horizontal, depth: threeD, position: place, canvas: canvas)
            case .line:
                lines(plotData, firstIndex: seriesIndex, band: band, plot: plot, area: false, depth: threeD, position: place, canvas: canvas)
            case .area:
                lines(plotData, firstIndex: seriesIndex, band: band, plot: plot, area: true, depth: threeD, position: place, canvas: canvas)
            case .stock:
                stock(plotData, firstIndex: seriesIndex, band: band, plot: plot, position: place, canvas: canvas)
            default:
                break
            }
            seriesIndex += plotData.series.count
        }

        // The axis line along the categories, at zero.
        let zero = position(max(min(0, scale.maximum), scale.minimum), on: scale)
        line(from: horizontal ? CGPoint(x: zero, y: plot.minY) : CGPoint(x: plot.minX, y: zero),
             to: horizontal ? CGPoint(x: zero, y: plot.maxY) : CGPoint(x: plot.maxX, y: zero), color: axisColor, width: 1, canvas: canvas)
    }

    /// The value a series shows at a category: itself, or for a stacked
    /// plot, where its segment runs from and to.
    private func stackedRange(_ plot: Chart.Plot, series: Int, category: Int) -> (from: Double, to: Double)? {
        func value(_ series: Chart.Series) -> Double? {
            series.values.indices.contains(category) ? series.values[category] : nil
        }
        guard let own = value(plot.series[series]) else { return nil }
        guard plot.grouping != .standard, plot.kind.hasGrouping else { return (0, own) }
        let below = plot.series[..<series].compactMap(value).filter { ($0 >= 0) == (own >= 0) }.reduce(0, +)
        var range = (from: below, to: below + own)
        if plot.grouping == .percentStacked {
            let total = plot.series.compactMap(value).map(abs).reduce(0, +)
            if total > 0 { range = (range.from / total, range.to / total) }
        }
        return range
    }

    private func bars(
        _ plot: Chart.Plot, firstIndex: Int, band: CGFloat, plot rect: CGRect, horizontal: Bool, depth: CGSize?,
        position: (Double) -> CGFloat, canvas: ChartCanvas
    ) {
        let stacked = plot.grouping != .standard
        let slots = stacked ? 1 : max(plot.series.count, 1)
        // PowerPoint's default gap: one and a half bars' width between groups.
        let barWidth = band / (CGFloat(slots) + 1.5)
        var prisms: [(rect: CGRect, color: RGBAColor)] = []
        var labels: [(String, CGRect)] = []
        for category in 0..<chart.categories.count {
            let start = horizontal
                ? rect.maxY - band * CGFloat(category + 1) + barWidth * 0.75
                : rect.minX + band * CGFloat(category) + barWidth * 0.75
            for (index, series) in plot.series.enumerated() {
                guard let range = stackedRange(plot, series: index, category: category) else { continue }
                // Within a category too, the first series is lowest.
                let slot = stacked ? 0 : (horizontal ? slots - 1 - index : index)
                let from = position(range.from)
                let to = position(range.to)
                let bar = horizontal
                    ? CGRect(x: min(from, to), y: start + barWidth * CGFloat(slot), width: abs(to - from), height: barWidth)
                    : CGRect(x: start + barWidth * CGFloat(slot), y: min(from, to), width: barWidth, height: abs(to - from))
                let color = series.pointColors[category].map { style.color($0) } ?? seriesColor(series, index: firstIndex + index)
                prisms.append((bar, color))
                if chart.showsValueLabels, series.values.indices.contains(category), let value = series.values[category] {
                    let lift = depth.map { min($0.height, 0) } ?? 0
                    let labelRect = horizontal
                        ? CGRect(x: bar.maxX + 2 + max(depth?.width ?? 0, 0), y: bar.midY - fontSize * 0.6, width: 80, height: fontSize * 1.2)
                        : CGRect(x: bar.midX - 40, y: bar.minY - fontSize * 1.3 + lift, width: 80, height: fontSize * 1.2)
                    labels.append((format(value, percent: false), labelRect))
                }
            }
        }
        if let depth {
            // Back to front: away from the side the depth runs to, and from the bottom up.
            let ordered = prisms.sorted { first, second in
                if horizontal, first.rect.midY != second.rect.midY { return first.rect.midY > second.rect.midY }
                if first.rect.midX != second.rect.midX { return (first.rect.midX < second.rect.midX) == (depth.width >= 0) }
                return first.rect.midY > second.rect.midY
            }
            for prism in ordered { self.prism(prism.rect, depth: depth, color: prism.color, canvas: canvas) }
        } else {
            for prism in prisms { canvas.fill(prism.rect, color: prism.color) }
        }
        for (label, rect) in labels {
            text(label, in: rect, size: fontSize * 0.85, alignment: horizontal ? .left : .center, canvas: canvas)
        }
    }

    /// A box seen from the front, its top and one side drawn back along `depth`.
    private func prism(_ rect: CGRect, depth: CGSize, color: RGBAColor, canvas: ChartCanvas) {
        let top = depth.height <= 0 ? rect.minY : rect.maxY
        let side = depth.width >= 0 ? rect.maxX : rect.minX
        let topFace = polygon([
            CGPoint(x: rect.minX, y: top), CGPoint(x: rect.maxX, y: top),
            CGPoint(x: rect.maxX, y: top).offset(depth), CGPoint(x: rect.minX, y: top).offset(depth),
        ])
        let sideFace = polygon([
            CGPoint(x: side, y: rect.minY), CGPoint(x: side, y: rect.maxY),
            CGPoint(x: side, y: rect.maxY).offset(depth), CGPoint(x: side, y: rect.minY).offset(depth),
        ])
        canvas.draw(sideFace, fill: shaded(color, 70_000), stroke: nil, lineWidth: 0, round: false)
        canvas.draw(topFace, fill: lit(color), stroke: nil, lineWidth: 0, round: false)
        canvas.fill(rect, color: color)
    }

    private func lines(
        _ plot: Chart.Plot, firstIndex: Int, band: CGFloat, plot rect: CGRect, area: Bool, depth: CGSize?,
        position: (Double) -> CGFloat, canvas: ChartCanvas
    ) {
        // A 3D plot's series are ribbons or slabs, drawn from the back; stacked
        // ones from the bottom up, each hiding the top of the one below.
        let stacked = plot.grouping != .standard && area
        let order = depth == nil || stacked ? Array(plot.series.indices) : plot.series.indices.reversed()
        for index in order {
            let series = plot.series[index]
            let color = seriesColor(series, index: firstIndex + index)
            var points: [(CGPoint, Double)] = []
            var baseline: [CGPoint] = []
            for category in 0..<chart.categories.count {
                guard let range = stackedRange(plot, series: index, category: category) else { continue }
                let x = rect.minX + band * (CGFloat(category) + 0.5)
                points.append((CGPoint(x: x, y: position(range.to)), series.values[category] ?? 0))
                baseline.append(CGPoint(x: x, y: position(range.from)))
            }
            guard !points.isEmpty else { continue }
            if let depth {
                if area {
                    // The end wall, the top and the front.
                    if let last = points.last?.0, let bottom = baseline.last {
                        canvas.draw(polygon([last, bottom, bottom.offset(depth), last.offset(depth)]), fill: shaded(color, 70_000),
                                    stroke: nil, lineWidth: 0, round: false)
                    }
                    for (start, end) in zip(points, points.dropFirst()) {
                        canvas.draw(polygon([start.0, end.0, end.0.offset(depth), start.0.offset(depth)]), fill: lit(color),
                                    stroke: nil, lineWidth: 0, round: false)
                    }
                    canvas.draw(polygon(points.map(\.0) + baseline.reversed()), fill: color, stroke: nil, lineWidth: 0, round: false)
                } else {
                    let ribbon = max(abs(depth.width), abs(depth.height)) > 0 ? depth : CGSize(width: 4, height: -3)
                    for (start, end) in zip(points, points.dropFirst()) {
                        canvas.draw(polygon([start.0, end.0, end.0.offset(ribbon), start.0.offset(ribbon)]), fill: lit(color),
                                    stroke: shaded(color, 75_000), lineWidth: 0.5, round: true)
                    }
                    if points.count == 1 {
                        line(from: points[0].0, to: points[0].0.offset(ribbon), color: color, width: max(fontSize * 0.19, 1.5), canvas: canvas)
                    }
                }
            } else if area {
                canvas.draw(polygon(points.map(\.0) + baseline.reversed()), fill: color, stroke: nil, lineWidth: 0, round: false)
            } else {
                polyline(points.map(\.0), color: color, canvas: canvas)
                markers(points.map(\.0), color: color, canvas: canvas)
            }
            if chart.showsValueLabels {
                for point in points {
                    text(format(point.1, percent: false), in: CGRect(x: point.0.x - 40, y: point.0.y - fontSize * 1.5, width: 80, height: fontSize * 1.2),
                         size: fontSize * 0.85, alignment: .center, canvas: canvas)
                }
            }
        }
    }

    func polyline(_ points: [CGPoint], color: RGBAColor, closed: Bool = false, canvas: ChartCanvas) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        canvas.draw(path, fill: nil, stroke: color, lineWidth: max(fontSize * 0.19, 1.5), round: true)
    }

    func markers(_ points: [CGPoint], color: RGBAColor, canvas: ChartCanvas) {
        let marker = fontSize * 0.42
        for point in points {
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: point.x - marker / 2, y: point.y - marker / 2, width: marker, height: marker))
            canvas.draw(dot, fill: color, stroke: nil, lineWidth: 0, round: false)
        }
    }

    /// High-low lines, up and down bars, open and close ticks, and any lines the series draw.
    private func stock(
        _ plot: Chart.Plot, firstIndex: Int, band: CGFloat, plot rect: CGRect, position: (Double) -> CGFloat, canvas: ChartCanvas
    ) {
        let count = plot.series.count
        let lineColor = style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 75_000)).applying(.init(name: "lumOff", value: 25_000))
        func value(_ series: Int, _ category: Int) -> Double? {
            plot.series[series].values.indices.contains(category) ? plot.series[series].values[category] : nil
        }
        // Lines the series draw themselves, which a stock chart's usually don't.
        for (index, series) in plot.series.enumerated() where series.hasLine == true {
            let points = (0..<chart.categories.count).compactMap { category in
                value(index, category).map { CGPoint(x: rect.minX + band * (CGFloat(category) + 0.5), y: position($0)) }
            }
            polyline(points, color: seriesColor(series, index: firstIndex + index), canvas: canvas)
        }
        let barWidth = band / (1 + CGFloat(max(plot.gapWidth, 0)) / 100)
        let tick = min(band * 0.22, fontSize * 0.8)
        let hasBars = plot.hasUpDownBars && count >= 4
        for category in 0..<chart.categories.count {
            let x = rect.minX + band * (CGFloat(category) + 0.5)
            let values = (0..<count).compactMap { value($0, category) }
            if plot.hasHighLowLines, let high = values.max(), let low = values.min() {
                line(from: CGPoint(x: x, y: position(high)), to: CGPoint(x: x, y: position(low)), color: lineColor, width: 1, canvas: canvas)
            }
            if hasBars, let open = value(0, category), let close = value(count - 1, category) {
                let top = position(max(open, close))
                let bottom = position(min(open, close))
                let bar = CGRect(x: x - barWidth / 2, y: top, width: barWidth, height: max(bottom - top, 1))
                let path = CGMutablePath()
                path.addRect(bar)
                canvas.draw(path, fill: close >= open ? background : textColor, stroke: lineColor, lineWidth: 0.75, round: false)
            }
            // Open to the left, close to the right; other series marked where they say.
            for index in 0..<count {
                guard let at = value(index, category) else { continue }
                let series = plot.series[index]
                let color = seriesColor(series, index: firstIndex + index)
                let isOpen = count >= 4 && index == 0
                let isClose = index == count - 1
                let y = position(at)
                switch series.marker {
                case "none":
                    continue
                case nil, "dash":
                    guard !hasBars, isOpen || isClose else { continue }
                    line(from: CGPoint(x: x, y: y), to: CGPoint(x: isOpen ? x - tick : x + tick, y: y), color: series.marker == nil ? lineColor : color,
                         width: 1.5, canvas: canvas)
                default:
                    markers([CGPoint(x: x, y: y)], color: color, canvas: canvas)
                }
            }
        }
    }

    // MARK: - Pies

    private func pie(in area: CGRect, canvas: ChartCanvas) {
        guard let plot = chart.plots.first, let series = plot.series.first else { return }
        let values = series.values.map { max($0 ?? 0, 0) }
        let radius = min(area.width, area.height) / 2 * 0.92
        let hole = plot.kind == .doughnut ? radius * CGFloat(min(max(plot.holeSize, 10), 90)) / 100 : 0
        slices(values.enumerated().map { ($0, $1) }, center: CGPoint(x: area.midX, y: area.midY), radius: radius, hole: hole,
               start: -.pi / 2, series: series, canvas: canvas)
    }

    /// Slices of a pie or a doughnut from `start`, clockwise, each its point's colour.
    @discardableResult
    private func slices(
        _ points: [(index: Int, value: Double)], center: CGPoint, radius: CGFloat, hole: CGFloat, start: CGFloat,
        series: Chart.Series, canvas: ChartCanvas, colors: [Int: RGBAColor] = [:]
    ) -> CGFloat {
        let total = points.map(\.value).reduce(0, +)
        guard total > 0 else { return start }
        var angle = start
        for (index, value) in points where value > 0 {
            let sweep = CGFloat(value / total) * .pi * 2
            // A slice, or for a doughnut, a piece of the ring.
            let slice = CGMutablePath()
            if hole > 0 {
                slice.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
                slice.addArc(center: center, radius: hole, startAngle: angle + sweep, endAngle: angle, clockwise: true)
            } else {
                slice.move(to: center)
                slice.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
            }
            slice.closeSubpath()
            // A thin line of the background between slices.
            canvas.draw(slice, fill: colors[index] ?? pointColor(series, at: index), stroke: background, lineWidth: 1, round: false)
            if chart.showsValueLabels {
                let middle = angle + sweep / 2
                let distance = hole > 0 ? (radius + hole) / 2 : radius * 0.65
                let at = CGPoint(x: center.x + cos(middle) * distance, y: center.y + sin(middle) * distance)
                text(format(value, percent: false), in: CGRect(x: at.x - 40, y: at.y - fontSize * 0.6, width: 80, height: fontSize * 1.2),
                     size: fontSize * 0.9, alignment: .center, canvas: canvas, color: .white)
            }
            angle += sweep
        }
        return angle
    }

    /// A pie tilted back by the view's angle, with its rim showing below.
    private func pie3D(in area: CGRect, canvas: ChartCanvas) {
        guard let plot = chart.plots.first, let series = plot.series.first else { return }
        let values = series.values.map { max($0 ?? 0, 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let view = chart.effectiveView3D
        let tilt = CGFloat(min(max(view.rotX, 10), 90)) * .pi / 180
        let squash = sin(tilt)
        let thicknessRatio = 0.2 * cos(tilt) * CGFloat(min(max(view.depthPercent, 20), 200)) / 100
        let radius = min(area.width / 2, area.height / (2 * squash + thicknessRatio)) * 0.92
        let thickness = radius * thicknessRatio
        let center = CGPoint(x: area.midX, y: area.midY - thickness / 2)
        func point(_ angle: CGFloat, drop: CGFloat = 0) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * squash + drop)
        }
        func arc(_ from: CGFloat, _ to: CGFloat, drop: CGFloat = 0) -> [CGPoint] {
            let steps = max(2, Int(ceil((to - from) / (.pi / 36))))
            return (0...steps).map { point(from + (to - from) * CGFloat($0) / CGFloat(steps), drop: drop) }
        }
        var ranges: [(index: Int, from: CGFloat, to: CGFloat)] = []
        var angle = -CGFloat.pi / 2
        for (index, value) in values.enumerated() where value > 0 {
            let sweep = CGFloat(value / total) * .pi * 2
            ranges.append((index, angle, angle + sweep))
            angle += sweep
        }
        // The rim, where it faces the viewer: angles whose sine is positive.
        for range in ranges {
            for turn in [-2, 0, 2] as [CGFloat] {
                let from = max(range.from, turn * .pi)
                let to = min(range.to, turn * .pi + .pi)
                guard to > from else { continue }
                let rim = arc(from, to) + arc(from, to, drop: thickness).reversed()
                canvas.draw(polygon(rim), fill: shaded(pointColor(series, at: range.index), 70_000), stroke: nil, lineWidth: 0, round: false)
            }
        }
        for range in ranges {
            let top = [center] + arc(range.from, range.to)
            canvas.draw(polygon(top), fill: pointColor(series, at: range.index), stroke: background, lineWidth: 1, round: false)
            if chart.showsValueLabels {
                let at = CGPoint(x: center.x + cos((range.from + range.to) / 2) * radius * 0.65,
                                 y: center.y + sin((range.from + range.to) / 2) * radius * squash * 0.65)
                text(format(values[range.index], percent: false), in: CGRect(x: at.x - 40, y: at.y - fontSize * 0.6, width: 80, height: fontSize * 1.2),
                     size: fontSize * 0.9, alignment: .center, canvas: canvas, color: .white)
            }
        }
    }

    /// A pie with its smaller slices pulled out, together, into a second pie or a bar beside it.
    private func ofPie(in area: CGRect, canvas: ChartCanvas) {
        guard let plot = chart.plots.first, let series = plot.series.first else { return }
        let count = min(chart.categories.count, series.values.count)
        let values = series.values.prefix(count).map { max($0 ?? 0, 0) }
        let second = Set(plot.secondPlotPoints(count: count))
        guard !second.isEmpty, second.count < count else { return pie(in: area, canvas: canvas) }
        let isBar = plot.kind == .barOfPie
        let ratio = CGFloat(min(max(plot.secondPieSize, 5), 200)) / 100
        let gap = CGFloat(min(max(plot.gapWidth, 0), 500)) / 100
        // The first pie's radius r, the second's r × ratio, and the gap r × ratio × gap between them.
        let secondWidth: CGFloat = isBar ? ratio * 0.7 : ratio * 2
        let radius = min(area.height / 2 * 0.92, area.width * 0.92 / (2 + secondWidth + ratio * gap))
        let width = radius * (2 + secondWidth + ratio * gap)
        let center = CGPoint(x: area.midX - width / 2 + radius, y: area.midY)
        let secondRadius = radius * ratio
        let secondLeft = center.x + radius + secondRadius * gap

        let other = values.indices.filter(second.contains).map { values[$0] }.reduce(0, +)
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        // The first pie turns its "Other" slice to face the second plot.
        let otherSweep = CGFloat(other / total) * .pi * 2
        var points = values.indices.filter { !second.contains($0) }.map { (index: $0, value: values[$0]) }
        points.append((index: count, value: other))
        // Starting where "Other" ends, so that it runs from −sweep/2 to +sweep/2, facing right.
        slices(points, center: center, radius: radius, hole: 0, start: otherSweep / 2, series: series, canvas: canvas,
               colors: [count: color(at: count)])

        let secondPoints = values.indices.filter(second.contains).map { (index: $0, value: values[$0]) }
        let upper = CGPoint(x: center.x + cos(-otherSweep / 2) * radius, y: center.y + sin(-otherSweep / 2) * radius)
        let lower = CGPoint(x: center.x + cos(otherSweep / 2) * radius, y: center.y + sin(otherSweep / 2) * radius)
        let lineColor = style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 50_000)).applying(.init(name: "lumOff", value: 50_000))
        if isBar {
            let barHeight = min(secondRadius * 2.4, area.height * 0.92)
            let bar = CGRect(x: secondLeft, y: center.y - barHeight / 2, width: secondRadius * 0.7, height: barHeight)
            var bottom = bar.maxY
            for (index, value) in secondPoints where other > 0 {
                let height = bar.height * CGFloat(value / other)
                let piece = CGRect(x: bar.minX, y: bottom - height, width: bar.width, height: height)
                let path = CGMutablePath()
                path.addRect(piece)
                canvas.draw(path, fill: pointColor(series, at: index), stroke: background, lineWidth: 1, round: false)
                if chart.showsValueLabels {
                    text(format(value, percent: false), in: CGRect(x: piece.midX - 40, y: piece.midY - fontSize * 0.6, width: 80, height: fontSize * 1.2),
                         size: fontSize * 0.9, alignment: .center, canvas: canvas, color: .white)
                }
                bottom -= height
            }
            if plot.hasSeriesLines {
                line(from: upper, to: CGPoint(x: bar.minX, y: bar.minY), color: lineColor, width: 0.75, canvas: canvas)
                line(from: lower, to: CGPoint(x: bar.minX, y: bar.maxY), color: lineColor, width: 0.75, canvas: canvas)
            }
        } else {
            let secondCenter = CGPoint(x: secondLeft + secondRadius, y: center.y)
            slices(secondPoints, center: secondCenter, radius: secondRadius, hole: 0, start: -.pi / 2, series: series, canvas: canvas)
            if plot.hasSeriesLines {
                line(from: upper, to: CGPoint(x: secondCenter.x, y: secondCenter.y - secondRadius), color: lineColor, width: 0.75, canvas: canvas)
                line(from: lower, to: CGPoint(x: secondCenter.x, y: secondCenter.y + secondRadius), color: lineColor, width: 0.75, canvas: canvas)
            }
        }
    }

    // MARK: - Scatter and bubbles

    /// Where an x-y chart's points sit: its value axes, gridlines and labels.
    private struct XYPlot {
        var rect: CGRect
        var x: Scale
        var y: Scale

        func point(_ xValue: Double, _ yValue: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x.fraction(xValue), y: rect.maxY - rect.height * y.fraction(yValue))
        }
    }

    private func xValue(_ series: Chart.Series, at index: Int) -> Double {
        series.xValues.isEmpty ? Double(index + 1) : (series.xValues.indices.contains(index) ? series.xValues[index] ?? 0 : 0)
    }

    private func xyAxes(in area: CGRect, canvas: ChartCanvas) -> XYPlot? {
        let series = chart.allSeries
        let xs = series.flatMap { series in series.values.indices.map { xValue(series, at: $0) } }
        let ys = series.flatMap { $0.values.compactMap(\.self) }
        let xScale = Scale.nice(low: xs.min() ?? 0, high: xs.max() ?? 1)
        let yScale = Scale.nice(low: ys.min() ?? 0, high: ys.max() ?? 1, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
        let labelWidth = (yScale.ticks.map { canvas.measure(format($0, percent: false), size: fontSize) }.max() ?? 0) + fontSize * 0.5
        var rect = area
        rect.origin.x += labelWidth
        rect.size.width -= labelWidth
        rect.size.height -= fontSize * 1.6
        guard rect.width > 4, rect.height > 4 else { return nil }
        let plot = XYPlot(rect: rect, x: xScale, y: yScale)
        for tick in yScale.ticks {
            let at = plot.point(xScale.minimum, tick).y
            if chart.showsGridlines {
                line(from: CGPoint(x: rect.minX, y: at), to: CGPoint(x: rect.maxX, y: at), color: gridColor, width: 0.75, canvas: canvas)
            }
            text(format(tick, percent: false), in: CGRect(x: area.minX, y: at - fontSize * 0.7, width: labelWidth - fontSize * 0.4, height: fontSize * 1.4),
                 size: fontSize, alignment: .right, canvas: canvas)
        }
        for tick in xScale.ticks {
            let at = plot.point(tick, yScale.minimum).x
            text(format(tick, percent: false), in: CGRect(x: at - 40, y: rect.maxY + fontSize * 0.2, width: 80, height: fontSize * 1.4),
                 size: fontSize, alignment: .center, canvas: canvas)
        }
        return plot
    }

    private func scatter(in area: CGRect, canvas: ChartCanvas) {
        guard let plot = xyAxes(in: area, canvas: canvas) else { return }
        let marker = fontSize * 0.5
        for (index, series) in chart.allSeries.enumerated() {
            let color = seriesColor(series, index: index)
            for (pointIndex, value) in series.values.enumerated() {
                guard let value else { continue }
                let at = plot.point(xValue(series, at: pointIndex), value)
                let dot = CGMutablePath()
                dot.addEllipse(in: CGRect(x: at.x - marker / 2, y: at.y - marker / 2, width: marker, height: marker))
                canvas.draw(dot, fill: color, stroke: nil, lineWidth: 0, round: false)
            }
        }
    }

    /// Bubbles sized by each point's third value: by area, or by width, the
    /// largest a quarter of the plot across at a bubble scale of 100%.
    private func bubbles(in area: CGRect, canvas: ChartCanvas) {
        guard let plot = xyAxes(in: area, canvas: canvas) else { return }
        let settings = chart.plots.first { $0.kind == .bubble } ?? Chart.Plot(kind: .bubble, series: [])
        let largest = chart.allSeries.flatMap { $0.sizes.compactMap { $0.map(abs) } }.max() ?? 0
        guard largest > 0 else { return }
        let fullSize = min(plot.rect.width, plot.rect.height) * 0.25 * CGFloat(min(max(settings.bubbleScale, 0), 300)) / 100
        var bubbles: [(center: CGPoint, diameter: CGFloat, color: RGBAColor, negative: Bool, value: Double)] = []
        for (index, series) in chart.allSeries.enumerated() {
            let color = seriesColor(series, index: index)
            for (pointIndex, value) in series.values.enumerated() {
                guard let value, series.sizes.indices.contains(pointIndex), let size = series.sizes[pointIndex], size != 0 else { continue }
                if size < 0, !settings.showsNegativeBubbles { continue }
                let share = abs(size) / largest
                let diameter = fullSize * CGFloat(settings.sizeIsWidth ? share : share.squareRoot())
                bubbles.append((plot.point(xValue(series, at: pointIndex), value), diameter, color, size < 0, value))
            }
        }
        // The largest first, so the smaller ones show in front of them.
        for bubble in bubbles.sorted(by: { $0.diameter > $1.diameter }) {
            let circle = CGMutablePath()
            circle.addEllipse(in: CGRect(x: bubble.center.x - bubble.diameter / 2, y: bubble.center.y - bubble.diameter / 2,
                                         width: bubble.diameter, height: bubble.diameter))
            if bubble.negative {
                canvas.draw(circle, fill: nil, stroke: bubble.color, lineWidth: 1, round: false)
            } else {
                canvas.draw(circle, fill: bubble.color, stroke: background, lineWidth: 0.75, round: false)
            }
            if chart.showsValueLabels {
                text(format(bubble.value, percent: false), in: CGRect(x: bubble.center.x - 40, y: bubble.center.y - fontSize * 0.6, width: 80, height: fontSize * 1.2),
                     size: fontSize * 0.85, alignment: .center, canvas: canvas)
            }
        }
    }

    // MARK: - Radar

    /// Series round a centre, one spoke per category: polygon gridlines at
    /// each step of the value axis, and the categories round the outside.
    private func radar(in area: CGRect, canvas: ChartCanvas) {
        guard let plot = chart.plots.first else { return }
        let count = max(chart.categories.count, 1)
        let names = chart.categories.map(formatCategory)
        let widest = names.map { canvas.measure($0, size: fontSize) }.max() ?? 0
        let radius = min(area.width / 2 - widest - fontSize * 0.6, area.height / 2 - fontSize * 1.6)
        guard radius > 4 else { return }
        let center = CGPoint(x: area.midX, y: area.midY)
        let values = chart.allSeries.flatMap { $0.values.prefix(count).compactMap(\.self) }
        let scale = Scale.nice(low: values.min() ?? 0, high: values.max() ?? 1, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
        func angle(_ index: Int) -> CGFloat { -.pi / 2 + .pi * 2 * CGFloat(index) / CGFloat(count) }
        func point(_ index: Int, _ value: Double) -> CGPoint {
            let distance = radius * CGFloat(min(max(scale.fraction(value), 0), 1))
            return CGPoint(x: center.x + cos(angle(index)) * distance, y: center.y + sin(angle(index)) * distance)
        }

        // A web of gridlines: a polygon, or a circle where there are too few spokes to make one.
        for tick in scale.ticks where tick > scale.minimum {
            guard chart.showsGridlines || tick >= scale.maximum else { continue }
            let color = tick >= scale.maximum ? axisColor : gridColor
            if count >= 3 {
                polygonOutline((0..<count).map { point($0, tick) }, color: color, canvas: canvas)
            } else {
                let distance = radius * CGFloat(scale.fraction(tick))
                let circle = CGMutablePath()
                circle.addEllipse(in: CGRect(x: center.x - distance, y: center.y - distance, width: distance * 2, height: distance * 2))
                canvas.draw(circle, fill: nil, stroke: color, lineWidth: 0.75, round: false)
            }
        }
        for index in 0..<count {
            line(from: center, to: point(index, scale.maximum), color: gridColor, width: 0.75, canvas: canvas)
        }
        // Values up the first spoke, categories round the outside.
        for tick in scale.ticks {
            let at = point(0, tick)
            text(format(tick, percent: false), in: CGRect(x: at.x - 84, y: at.y - fontSize * 0.7, width: 80, height: fontSize * 1.4),
                 size: fontSize * 0.9, alignment: .right, canvas: canvas)
        }
        for (index, name) in names.enumerated() {
            let direction = CGPoint(x: cos(angle(index)), y: sin(angle(index)))
            let at = CGPoint(x: center.x + direction.x * (radius + fontSize * 0.5), y: center.y + direction.y * (radius + fontSize * 0.5))
            let alignment: ChartTextAlignment = direction.x > 0.3 ? .left : (direction.x < -0.3 ? .right : .center)
            let width = widest + fontSize
            let x: CGFloat = switch alignment {
            case .left: at.x
            case .right: at.x - width
            case .center: at.x - width / 2
            }
            let y = at.y + direction.y * fontSize * 0.6 - fontSize * 0.7
            text(name, in: CGRect(x: x, y: y, width: width, height: fontSize * 1.4), size: fontSize, alignment: alignment, canvas: canvas)
        }

        for (index, series) in plot.series.enumerated() {
            let color = seriesColor(series, index: index)
            let points = (0..<count).compactMap { category in
                series.values.indices.contains(category) ? series.values[category].map { point(category, $0) } : nil
            }
            guard !points.isEmpty else { continue }
            switch plot.radarStyle {
            case .filled:
                canvas.draw(polygon(points), fill: color, stroke: nil, lineWidth: 0, round: false)
            case .standard, .marker:
                if series.hasLine != false { polyline(points, color: color, closed: points.count == count, canvas: canvas) }
                let showsMarkers = plot.radarStyle == .marker ? series.marker != "none" : (series.marker.map { $0 != "none" } ?? false)
                if showsMarkers { markers(points, color: color, canvas: canvas) }
            }
            if chart.showsValueLabels {
                for category in 0..<count {
                    guard series.values.indices.contains(category), let value = series.values[category] else { continue }
                    let at = point(category, value)
                    text(format(value, percent: false), in: CGRect(x: at.x - 40, y: at.y - fontSize * 1.5, width: 80, height: fontSize * 1.2),
                         size: fontSize * 0.85, alignment: .center, canvas: canvas)
                }
            }
        }
    }

    // MARK: - Surface

    private func surfaceScale() -> Scale {
        let values = chart.allSeries.flatMap { $0.values.prefix(max(chart.categories.count, 1)).compactMap(\.self) }
        return .nice(low: values.min() ?? 0, high: values.max() ?? 1, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum, fromZero: false)
    }

    /// A surface seen from above: a contour map, categories across and
    /// series up, each value band in a colour of its own as the legend lists them.
    private func surface(in area: CGRect, canvas: ChartCanvas) {
        guard let plot = chart.plots.first, !plot.series.isEmpty else { return }
        let scale = surfaceScale()
        let bands = max(scale.ticks.count - 1, 1)
        let columns = max(chart.categories.count, 1)
        let rows = plot.series.count
        let names = chart.categories.map(formatCategory)
        let labelWidth = (plot.series.map { canvas.measure($0.name, size: fontSize) }.max() ?? 0) + fontSize * 0.6
        var rect = area
        rect.origin.x += labelWidth
        rect.size.width -= labelWidth
        rect.size.height -= fontSize * 1.6
        guard rect.width > 4, rect.height > 4 else { return }
        func value(_ row: Int, _ column: Int) -> Double {
            let series = plot.series[min(max(row, 0), rows - 1)]
            let column = min(max(column, 0), columns - 1)
            return series.values.indices.contains(column) ? series.values[column] ?? scale.minimum : scale.minimum
        }
        func band(_ value: Double) -> Int { min(max(Int(floor(scale.fraction(value) * Double(bands))), 0), bands - 1) }
        // Nodes sit at the grid's corners; with one row or column, across the whole of it.
        let spanX = rect.width / CGFloat(max(columns - 1, 1))
        let spanY = rect.height / CGFloat(max(rows - 1, 1))
        func node(_ row: Int, _ column: Int) -> CGPoint {
            CGPoint(x: columns > 1 ? rect.minX + spanX * CGFloat(column) : rect.midX, y: rows > 1 ? rect.maxY - spanY * CGFloat(row) : rect.midY)
        }

        if plot.isWireframe {
            for row in 0..<rows {
                for column in 0..<columns {
                    if column + 1 < columns {
                        line(from: node(row, column), to: node(row, column + 1),
                             color: color(at: band((value(row, column) + value(row, column + 1)) / 2)), width: 1.25, canvas: canvas)
                    }
                    if row + 1 < rows {
                        line(from: node(row, column), to: node(row + 1, column),
                             color: color(at: band((value(row, column) + value(row + 1, column)) / 2)), width: 1.25, canvas: canvas)
                    }
                }
            }
        } else {
            // Each cell split finely, its value found between its four corners,
            // with runs of one colour drawn as one rectangle.
            let steps = 8
            let cellsX = max(columns - 1, 1)
            let cellsY = max(rows - 1, 1)
            let width = rect.width / CGFloat(cellsX * steps)
            let height = rect.height / CGFloat(cellsY * steps)
            for y in 0..<(cellsY * steps) {
                let rowPosition = (Double(y) + 0.5) / Double(steps)
                var runStart = 0
                var runBand = -1
                for x in 0...(cellsX * steps) {
                    var current = -1
                    if x < cellsX * steps {
                        let columnPosition = (Double(x) + 0.5) / Double(steps)
                        let row = Int(rowPosition)
                        let column = Int(columnPosition)
                        let fx = columns > 1 ? columnPosition - Double(column) : 0
                        let fy = rows > 1 ? rowPosition - Double(row) : 0
                        let top = value(row, column) * (1 - fx) + value(row, column + 1) * fx
                        let bottom = value(row + 1, column) * (1 - fx) + value(row + 1, column + 1) * fx
                        current = band(top * (1 - fy) + bottom * fy)
                    }
                    if current != runBand {
                        if runBand >= 0 {
                            canvas.fill(CGRect(x: rect.minX + width * CGFloat(runStart), y: rect.maxY - height * CGFloat(y + 1),
                                               width: width * CGFloat(x - runStart) + 0.5, height: height + 0.5), color: color(at: runBand))
                        }
                        runStart = x
                        runBand = current
                    }
                }
            }
        }
        if chart.showsGridlines {
            for column in 0..<columns where columns > 1 {
                line(from: node(0, column), to: node(rows - 1, column).offset(CGSize(width: 0, height: rows > 1 ? 0 : -rect.height / 2)),
                     color: gridColor, width: 0.5, canvas: canvas)
            }
        }
        for (column, name) in names.enumerated() {
            let x = node(0, column).x
            text(name, in: CGRect(x: x - spanX / 2, y: rect.maxY + fontSize * 0.2, width: max(spanX, 40), height: fontSize * 1.4),
                 size: fontSize, alignment: .center, canvas: canvas)
        }
        for (row, series) in plot.series.enumerated() {
            let y = node(row, 0).y
            text(series.name, in: CGRect(x: area.minX, y: y - fontSize * 0.7, width: labelWidth - fontSize * 0.4, height: fontSize * 1.4),
                 size: fontSize, alignment: .right, canvas: canvas)
        }
        if chart.showsValueLabels {
            for row in 0..<rows {
                for column in 0..<columns {
                    let at = node(row, column)
                    text(format(value(row, column), percent: false), in: CGRect(x: at.x - 40, y: at.y - fontSize * 0.6, width: 80, height: fontSize * 1.2),
                         size: fontSize * 0.85, alignment: .center, canvas: canvas)
                }
            }
        }
    }

    // MARK: - Paths

    func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private func polygonOutline(_ points: [CGPoint], color: RGBAColor, canvas: ChartCanvas) {
        canvas.draw(polygon(points), fill: nil, stroke: color, lineWidth: 0.75, round: false)
    }

    func line(from: CGPoint, to: CGPoint, color: RGBAColor, width: CGFloat, canvas: ChartCanvas) {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        canvas.draw(path, fill: nil, stroke: color, lineWidth: width, round: false)
    }

    // MARK: - Text

    func format(_ value: Double, percent: Bool) -> String {
        if percent { return (value * 100).formatted(.number.precision(.fractionLength(0))) + "%" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// A category as its number format shows it: a date, for one the file
    /// gives as a day number with a date format, as stock charts' are.
    func formatCategory(_ category: String) -> String {
        guard let code = chart.categoryFormat, let serial = Double(category) else { return category }
        return Self.date(serial, format: code) ?? category
    }

    /// A spreadsheet day number in a date format such as `m/d/yyyy` or `d-mmm`.
    static func date(_ serial: Double, format code: String) -> String? {
        // The format's own text, without its locale and colour tags, quotes and escapes.
        var format = code.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        format = format.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let lower = format.lowercased()
        guard lower.contains("d") || lower.contains("y") || lower.contains("mmm"), !lower.contains("general"),
              serial > 0, serial < 2_958_466 else { return nil }
        // Days from 1 March 0000, to a year, month and day.
        // Day 1 is 1 January 1900, and day 60 the 29 February 1900 that Lotus 1-2-3 counted.
        let days = Int(serial.rounded(.down)) + (serial < 61 ? 693_900 : 693_899)
        let era = days / 146_097
        let dayOfEra = days - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
        var result = ""
        var index = lower.startIndex
        func run(of letter: Character) -> Int {
            var end = index
            while end < lower.endIndex, lower[end] == letter { end = lower.index(after: end) }
            return lower.distance(from: index, to: end)
        }
        while index < lower.endIndex {
            let letter = lower[index]
            let length = ["y", "m", "d"].contains(letter) ? run(of: letter) : 1
            switch (letter, length) {
            case ("y", 1...2): result += twoDigits(year % 100)
            case ("y", _): result += String(year)
            case ("m", 1): result += String(month)
            case ("m", 2): result += twoDigits(month)
            case ("m", 3): result += String(months[month - 1].prefix(3))
            case ("m", _): result += months[month - 1]
            case ("d", 1): result += String(day)
            case ("d", 2): result += twoDigits(day)
            case ("d", _): result += String(day)
            default: result.append(format[format.index(format.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: index))])
            }
            index = lower.index(index, offsetBy: length)
        }
        return result
    }

    func text(
        _ text: String, in rect: CGRect, size: CGFloat, alignment: ChartTextAlignment, canvas: ChartCanvas, color: RGBAColor? = nil
    ) {
        canvas.text(text, in: rect, size: size, alignment: alignment, color: color ?? textColor)
    }
}

private extension CGPoint {
    func offset(_ size: CGSize) -> CGPoint { CGPoint(x: x + size.width, y: y + size.height) }
}
