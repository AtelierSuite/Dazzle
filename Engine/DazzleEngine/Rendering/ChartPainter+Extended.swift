#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Office 2016's charts, drawn in the look PowerPoint gives a new one.
extension ChartPainter {
    func extended(in area: CGRect, canvas: ChartCanvas) {
        switch chart.kind {
        case .waterfall: waterfall(in: area, canvas: canvas)
        case .funnel: funnel(in: area, canvas: canvas)
        case .treemap: treemap(in: area, canvas: canvas)
        case .sunburst: sunburst(in: area, canvas: canvas)
        case .histogram, .pareto: histogram(in: area, canvas: canvas)
        case .boxWhisker: boxWhisker(in: area, canvas: canvas)
        default: break
        }
    }

    /// What the legend lists: a waterfall's kinds of column, a treemap's or
    /// sunburst's outermost branches, and series otherwise. A funnel has none.
    func extendedLegendEntries() -> [(String, RGBAColor)] {
        switch chart.kind {
        case .waterfall:
            let bars = chart.waterfallBars().compactMap(\.self)
            var entries: [(String, RGBAColor)] = []
            if bars.contains(where: { !$0.isTotal && $0.value >= 0 }) {
                entries.append((String(localized: "Chart.Waterfall.Increase", bundle: .engine), color(at: 0)))
            }
            if bars.contains(where: { !$0.isTotal && $0.value < 0 }) {
                entries.append((String(localized: "Chart.Waterfall.Decrease", bundle: .engine), color(at: 1)))
            }
            if bars.contains(where: \.isTotal) {
                entries.append((String(localized: "Chart.Waterfall.Total", bundle: .engine), color(at: 2)))
            }
            return entries
        case .funnel:
            return []
        case .treemap, .sunburst:
            return chart.hierarchy().sorted { $0.colorIndex < $1.colorIndex }.map { ($0.name, color(at: $0.colorIndex)) }
        default:
            return chart.allSeries.enumerated().map { ($1.name, seriesColor($1, index: $0)) }
        }
    }

    private var outlineColor: RGBAColor {
        style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 75_000)).applying(.init(name: "lumOff", value: 25_000))
    }

    // MARK: - Axes

    /// A plot with categories along the bottom and values up the side.
    private struct Axes {
        var plot: CGRect
        var band: CGFloat
        var scale: Scale

        func y(_ value: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(scale.fraction(value)) }
        func x(_ index: Int) -> CGFloat { plot.minX + band * (CGFloat(index) + 0.5) }
    }

    /// Draws gridlines, the values up the left, the categories along the
    /// bottom and, for a Pareto chart, percentages up the right.
    private func axes(in area: CGRect, categories: [String], scale: Scale, percentages: Bool = false, canvas: ChartCanvas) -> Axes? {
        let labels = scale.ticks.map { format($0, percent: false) }
        let labelWidth = (labels.map { canvas.measure($0, size: fontSize) }.max() ?? 0) + fontSize * 0.5
        let percentWidth = percentages ? canvas.measure(format(1, percent: true), size: fontSize) + fontSize * 0.5 : 0
        var plot = area
        plot.origin.x += labelWidth
        plot.size.width -= labelWidth + percentWidth
        plot.size.height -= fontSize * 1.6
        guard plot.width > 4, plot.height > 4 else { return nil }
        let axes = Axes(plot: plot, band: plot.width / CGFloat(max(categories.count, 1)), scale: scale)
        for (index, tick) in scale.ticks.enumerated() {
            let at = axes.y(tick)
            if chart.showsGridlines {
                line(from: CGPoint(x: plot.minX, y: at), to: CGPoint(x: plot.maxX, y: at), color: gridColor, width: 0.75, canvas: canvas)
            }
            text(labels[index], in: CGRect(x: area.minX, y: at - fontSize * 0.7, width: labelWidth - fontSize * 0.4, height: fontSize * 1.4),
                 size: fontSize, alignment: .right, canvas: canvas)
        }
        if percentages {
            for step in 0...5 {
                let share = Double(step) / 5
                text(format(share, percent: true),
                     in: CGRect(x: plot.maxX + fontSize * 0.4, y: plot.maxY - plot.height * CGFloat(share) - fontSize * 0.7, width: percentWidth, height: fontSize * 1.4),
                     size: fontSize, alignment: .left, canvas: canvas)
            }
        }
        // Category labels, skipping some where they would collide.
        let widest = categories.map { canvas.measure($0, size: fontSize) }.max() ?? 0
        let every = max(Int(ceil((widest + fontSize) / max(axes.band, 1))), 1)
        for (index, name) in categories.enumerated() where index % every == 0 && !name.isEmpty {
            text(name, in: CGRect(x: axes.x(index) - axes.band * CGFloat(every) / 2, y: plot.maxY + fontSize * 0.2,
                                  width: axes.band * CGFloat(every), height: fontSize * 1.4),
                 size: fontSize, alignment: .center, canvas: canvas)
        }
        return axes
    }

    /// The line along the categories, at zero.
    private func baseline(_ axes: Axes, canvas: ChartCanvas) {
        let zero = axes.y(max(min(0, axes.scale.maximum), axes.scale.minimum))
        line(from: CGPoint(x: axes.plot.minX, y: zero), to: CGPoint(x: axes.plot.maxX, y: zero), color: axisColor, width: 1, canvas: canvas)
    }

    private func valueLabel(_ value: Double, above rect: CGRect, below: Bool = false, canvas: ChartCanvas) {
        let y = below ? rect.maxY + fontSize * 0.1 : rect.minY - fontSize * 1.3
        text(format(value, percent: false), in: CGRect(x: rect.midX - 40, y: y, width: 80, height: fontSize * 1.2),
             size: fontSize * 0.85, alignment: .center, canvas: canvas)
    }

    /// As much of `text` as sets in `width`, ending in an ellipsis if it was cut; nothing if hardly any does.
    private func fitted(_ text: String, width: CGFloat, size: CGFloat, canvas: ChartCanvas) -> String? {
        guard !text.isEmpty, width > size else { return nil }
        if canvas.measure(text, size: size) <= width { return text }
        var cut = text
        while cut.count > 1 {
            cut.removeLast()
            if canvas.measure(cut + "…", size: size) <= width { return cut.count >= 2 ? cut + "…" : nil }
        }
        return nil
    }

    // MARK: - Waterfall

    /// Columns stepping up and down from one to the next, joined by thin
    /// lines, with totals standing on the axis in a colour of their own.
    private func waterfall(in area: CGRect, canvas: ChartCanvas) {
        guard let series = chart.plots.first?.series.first else { return }
        let bars = chart.waterfallBars()
        let levels = bars.compactMap(\.self).flatMap { [$0.from, $0.to] }
        let scale = Scale.nice(low: levels.min() ?? 0, high: levels.max() ?? 1, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
        guard let axes = axes(in: area, categories: chart.categories.map(formatCategory), scale: scale, canvas: canvas) else { return }
        // Office's gap: half a column's width between columns.
        let width = axes.band / 1.5
        var previous: (level: Double, right: CGFloat)?
        for (index, bar) in bars.enumerated() {
            guard let bar else { continue }
            let rect = CGRect(x: axes.x(index) - width / 2, y: min(axes.y(bar.from), axes.y(bar.to)), width: width,
                              height: abs(axes.y(bar.to) - axes.y(bar.from)))
            if let previous {
                let y = axes.y(previous.level)
                line(from: CGPoint(x: previous.right, y: y), to: CGPoint(x: rect.minX, y: y), color: axisColor, width: 0.75, canvas: canvas)
            }
            let fallback = color(at: bar.isTotal ? 2 : (bar.value < 0 ? 1 : 0))
            canvas.fill(rect, color: series.pointColors[index].map { style.color($0) } ?? fallback)
            if chart.showsValueLabels { valueLabel(bar.value, above: rect, below: !bar.isTotal && bar.value < 0, canvas: canvas) }
            previous = (bar.to, rect.maxX)
        }
        baseline(axes, canvas: canvas)
    }

    // MARK: - Funnel

    /// Bars one under another, centred, each as wide as its value against the largest.
    private func funnel(in area: CGRect, canvas: ChartCanvas) {
        guard let series = chart.plots.first?.series.first else { return }
        let names = chart.categories.map(formatCategory)
        let count = max(names.count, 1)
        let values = (0..<count).map { series.values.indices.contains($0) ? max(series.values[$0] ?? 0, 0) : 0 }
        guard let largest = values.max(), largest > 0 else { return }
        let labelWidth = min((names.map { canvas.measure($0, size: fontSize) }.max() ?? 0) + fontSize * 0.8, area.width * 0.35)
        var plot = area
        plot.origin.x += labelWidth
        plot.size.width -= labelWidth
        guard plot.width > 4 else { return }
        let row = plot.height / CGFloat(count)
        for (index, value) in values.enumerated() {
            let center = plot.minY + row * (CGFloat(index) + 0.5)
            if let name = fitted(names.indices.contains(index) ? names[index] : "", width: labelWidth - fontSize * 0.5, size: fontSize, canvas: canvas) {
                text(name, in: CGRect(x: area.minX, y: center - fontSize * 0.7, width: labelWidth - fontSize * 0.5, height: fontSize * 1.4),
                     size: fontSize, alignment: .right, canvas: canvas)
            }
            guard value > 0 else { continue }
            let width = plot.width * CGFloat(value / largest)
            let bar = CGRect(x: plot.midX - width / 2, y: center - row * 0.47, width: width, height: row * 0.94)
            canvas.fill(bar, color: series.pointColors[index].map { style.color($0) } ?? seriesColor(series, index: 0))
            if chart.showsValueLabels {
                let label = format(value, percent: false)
                // On the bar where it fits, in the plot's own colour where the bar is too narrow.
                let fits = canvas.measure(label, size: fontSize * 0.9) + 4 <= width
                text(label, in: CGRect(x: plot.midX - 60, y: center - fontSize * 0.6, width: 120, height: fontSize * 1.2),
                     size: fontSize * 0.9, alignment: .center, canvas: canvas, color: fits ? .white : nil)
            }
        }
    }

    // MARK: - Treemap

    /// Rectangles as near square as they can be made, each `values` of the
    /// whole, laid in rows along the shorter side of what room is left.
    /// `values` come largest first.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let areas = values.map { CGFloat($0 / total) * rect.width * rect.height }
        var rects = [CGRect](repeating: .zero, count: values.count)
        var free = rect
        var start = 0
        while start < areas.count {
            let side = min(free.width, free.height)
            guard side > 0 else { break }
            // Take pieces into the row for as long as the worst of their shapes gets no worse.
            var end = start
            var sum: CGFloat = 0
            var best = CGFloat.infinity
            while end < areas.count {
                let next = sum + areas[end]
                guard areas[end] > 0 else { end += 1; continue }
                let worst = max(side * side * areas[start] / (next * next), next * next / (side * side * areas[end]))
                if worst > best { break }
                best = worst
                sum = next
                end += 1
            }
            guard sum > 0 else { break }
            let thickness = sum / side
            let alongHeight = free.width >= free.height
            var offset: CGFloat = 0
            for index in start..<end {
                let length = areas[index] / thickness
                rects[index] = alongHeight
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                offset += length
            }
            if alongHeight {
                free.origin.x += thickness
                free.size.width -= thickness
            } else {
                free.origin.y += thickness
                free.size.height -= thickness
            }
            start = end
        }
        return rects
    }

    /// Each outermost branch in a colour of its own, its leaves inside it,
    /// named in their top left corners.
    private func treemap(in area: CGRect, canvas: ChartCanvas) {
        let roots = chart.hierarchy()
        guard !roots.isEmpty else { return }
        let layout = chart.plots.first?.extended.parentLabels ?? .overlapping
        let labelSize = fontSize * 0.9
        let inset = fontSize * 0.35

        func label(_ text: String, in rect: CGRect, size: CGFloat, dropped: CGFloat = 0) {
            guard rect.height >= size * 1.3 + dropped + inset,
                  let fitted = fitted(text, width: rect.width - inset * 2, size: size, canvas: canvas) else { return }
            self.text(fitted, in: CGRect(x: rect.minX + inset, y: rect.minY + inset + dropped, width: rect.width - inset * 2, height: size * 1.3),
                      size: size, alignment: .left, canvas: canvas, color: .white)
        }
        func leaf(_ node: Chart.Node, in rect: CGRect, color: RGBAColor, dropped: CGFloat = 0) {
            let path = CGMutablePath()
            path.addRect(rect)
            canvas.draw(path, fill: color, stroke: background, lineWidth: 1, round: false)
            label(chart.showsValueLabels ? "\(node.name), \(format(node.value, percent: false))" : node.name, in: rect, size: labelSize, dropped: dropped)
        }
        /// A branch's leaves, however deep; `corner` is where its own name is, which a leaf there makes room for.
        func branch(_ nodes: [Chart.Node], in rect: CGRect, color: RGBAColor, corner: CGPoint?, dropped: CGFloat) {
            for (node, rect) in zip(nodes, Self.squarify(nodes.map(\.value), in: rect)) where rect.width > 0 && rect.height > 0 {
                let atCorner = corner.map { abs(rect.minX - $0.x) < 0.5 && abs(rect.minY - $0.y) < 0.5 } ?? false
                if node.children.isEmpty {
                    leaf(node, in: rect, color: color, dropped: atCorner ? dropped : 0)
                } else {
                    branch(node.children, in: rect, color: color, corner: atCorner ? corner : nil, dropped: dropped)
                }
            }
        }

        for (root, rect) in zip(roots, Self.squarify(roots.map(\.value), in: area)) where rect.width > 0 && rect.height > 0 {
            let color = color(at: root.colorIndex)
            guard !root.children.isEmpty else {
                leaf(root, in: rect, color: color)
                continue
            }
            switch layout {
            case .banner:
                let banner = min(fontSize * 1.7, rect.height / 2)
                let strip = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: banner)
                let path = CGMutablePath()
                path.addRect(strip)
                canvas.draw(path, fill: color.applying(.init(name: "lumMod", value: 75_000)), stroke: background, lineWidth: 1, round: false)
                if let name = fitted(root.name, width: strip.width - inset * 2, size: fontSize, canvas: canvas), strip.height >= fontSize * 1.2 {
                    text(name, in: strip.insetBy(dx: inset, dy: 0), size: fontSize, alignment: .left, canvas: canvas, color: .white)
                }
                branch(root.children, in: CGRect(x: rect.minX, y: rect.maxY - (rect.height - banner), width: rect.width, height: rect.height - banner),
                       color: color, corner: nil, dropped: 0)
            case .overlapping:
                let size = fontSize * 1.15
                let shows = rect.height >= size * 2.8 && rect.width >= size * 3
                branch(root.children, in: rect, color: color, corner: shows ? rect.origin : nil, dropped: size * 1.3)
                if shows { label(root.name, in: rect, size: size) }
            case .none:
                branch(root.children, in: rect, color: color, corner: nil, dropped: 0)
            }
        }
    }

    // MARK: - Sunburst

    /// Rings round a small hole: the outermost branches innermost, from the
    /// top and clockwise, each with its leaves in the rings outside it.
    private func sunburst(in area: CGRect, canvas: ChartCanvas) {
        let roots = chart.hierarchy()
        let total = roots.map(\.value).reduce(0, +)
        guard total > 0 else { return }
        let rings = roots.map(\.depth).max() ?? 1
        let radius = min(area.width, area.height) / 2 * 0.96
        let hole = radius * 0.16
        let thickness = (radius - hole) / CGFloat(rings)
        let center = CGPoint(x: area.midX, y: area.midY)
        let labelSize = fontSize * 0.85

        func segment(_ node: Chart.Node, from: CGFloat, to: CGFloat, ring: Int, color: RGBAColor) {
            let inner = hole + thickness * CGFloat(ring)
            let outer = inner + thickness
            let path = CGMutablePath()
            path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
            path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
            path.closeSubpath()
            canvas.draw(path, fill: color, stroke: background, lineWidth: 1, round: false)

            // The name, level, where the piece of ring has room for it.
            let middle = (from + to) / 2
            let arc = (to - from) * (inner + outer) / 2
            let across = thickness * abs(cos(middle)) + min(arc, thickness * 3) * abs(sin(middle))
            let down = thickness * abs(sin(middle)) + arc * abs(cos(middle))
            let name = chart.showsValueLabels ? "\(node.name), \(format(node.value, percent: false))" : node.name
            if down >= labelSize * 1.2, arc >= labelSize * 1.2, let fitted = fitted(name, width: across - labelSize * 0.4, size: labelSize, canvas: canvas) {
                let at = CGPoint(x: center.x + cos(middle) * (inner + outer) / 2, y: center.y + sin(middle) * (inner + outer) / 2)
                text(fitted, in: CGRect(x: at.x - across / 2, y: at.y - labelSize * 0.65, width: across, height: labelSize * 1.3),
                     size: labelSize, alignment: .center, canvas: canvas, color: .white)
            }

            var angle = from
            for child in node.children where node.value > 0 {
                let sweep = (to - from) * CGFloat(child.value / node.value)
                segment(child, from: angle, to: angle + sweep, ring: ring + 1, color: color)
                angle += sweep
            }
        }

        var angle = -CGFloat.pi / 2
        for root in roots {
            let sweep = CGFloat(root.value / total) * .pi * 2
            segment(root, from: angle, to: angle + sweep, ring: 0, color: color(at: root.colorIndex))
            angle += sweep
        }
    }

    // MARK: - Histogram and Pareto

    /// Columns side by side with no gap, one per bin; for a Pareto chart, from
    /// the tallest down, under a line of how much of the whole they make so far.
    private func histogram(in area: CGRect, canvas: ChartCanvas) {
        guard let series = chart.plots.first?.series.first else { return }
        let bins = chart.bins()
        guard !bins.isEmpty else { return }
        let isPareto = chart.kind == .pareto
        let scale = Scale.nice(low: 0, high: bins.map(\.count).max() ?? 1, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
        guard let axes = axes(in: area, categories: bins.map(\.label), scale: scale, percentages: isPareto, canvas: canvas) else { return }
        let color = seriesColor(series, index: 0)
        let gap = min(axes.band * 0.04, 2)
        for (index, bin) in bins.enumerated() {
            let top = axes.y(bin.count)
            let rect = CGRect(x: axes.x(index) - axes.band / 2 + gap / 2, y: min(top, axes.y(0)), width: axes.band - gap, height: abs(axes.y(0) - top))
            canvas.fill(rect, color: color)
            if chart.showsValueLabels { valueLabel(bin.count, above: rect, canvas: canvas) }
        }
        baseline(axes, canvas: canvas)
        let total = bins.map(\.count).reduce(0, +)
        if isPareto, total > 0 {
            var running = 0.0
            let points = bins.enumerated().map { index, bin in
                running += bin.count
                return CGPoint(x: axes.x(index), y: axes.plot.maxY - axes.plot.height * CGFloat(running / total))
            }
            polyline(points, color: self.color(at: 1), canvas: canvas)
        }
    }

    // MARK: - Box and whisker

    /// A box from the first quartile to the third, with a line at the median,
    /// whiskers to the furthest values that aren't outliers, a cross at the
    /// mean and a dot for each outlier; one box per series in each category.
    private func boxWhisker(in area: CGRect, canvas: ChartCanvas) {
        guard let plot = chart.plots.first else { return }
        let names = chart.boxCategories
        let values = plot.series.flatMap { $0.values.compactMap(\.self) }
        let scale = Scale.nice(low: values.min() ?? 0, high: values.max() ?? 1, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
        guard let axes = axes(in: area, categories: names.map(formatCategory), scale: scale, canvas: canvas) else { return }
        baseline(axes, canvas: canvas)
        let slot = axes.band * 0.8 / CGFloat(max(plot.series.count, 1))
        let width = slot * 0.7
        let dot = max(fontSize * 0.4, 3)
        let layout = plot.extended
        func dots(_ values: [Double], x: CGFloat, color: RGBAColor) {
            for value in values {
                let path = CGMutablePath()
                path.addEllipse(in: CGRect(x: x - dot / 2, y: axes.y(value) - dot / 2, width: dot, height: dot))
                canvas.draw(path, fill: color, stroke: nil, lineWidth: 0, round: false)
            }
        }
        for (seriesIndex, series) in plot.series.enumerated() {
            let color = seriesColor(series, index: seriesIndex)
            var means: [CGPoint] = []
            for (category, group) in chart.boxValues(of: series).enumerated() {
                guard let statistics = Chart.boxStatistics(group, includingMedian: layout.quartilesIncludeMedian) else { continue }
                let x = axes.x(category) - axes.band * 0.4 + slot * (CGFloat(seriesIndex) + 0.5)
                let box = CGRect(x: x - width / 2, y: axes.y(statistics.thirdQuartile), width: width,
                                 height: max(axes.y(statistics.firstQuartile) - axes.y(statistics.thirdQuartile), 1))
                // Whiskers, each with a cap half the box's width.
                for (from, to) in [(statistics.thirdQuartile, statistics.high), (statistics.firstQuartile, statistics.low)] where from != to {
                    line(from: CGPoint(x: x, y: axes.y(from)), to: CGPoint(x: x, y: axes.y(to)), color: outlineColor, width: 1, canvas: canvas)
                    line(from: CGPoint(x: x - width / 4, y: axes.y(to)), to: CGPoint(x: x + width / 4, y: axes.y(to)), color: outlineColor, width: 1, canvas: canvas)
                }
                let path = CGMutablePath()
                path.addRect(box)
                canvas.draw(path, fill: color, stroke: outlineColor, lineWidth: 1, round: false)
                let median = axes.y(statistics.median)
                line(from: CGPoint(x: box.minX, y: median), to: CGPoint(x: box.maxX, y: median), color: outlineColor, width: 1, canvas: canvas)
                if layout.showsInnerPoints { dots(statistics.inner, x: x, color: outlineColor) }
                if layout.showsOutliers { dots(statistics.outliers, x: x, color: color) }
                let mean = CGPoint(x: x, y: axes.y(statistics.mean))
                means.append(mean)
                if layout.showsMeanMarker {
                    let arm = dot * 0.6
                    line(from: CGPoint(x: mean.x - arm, y: mean.y - arm), to: CGPoint(x: mean.x + arm, y: mean.y + arm), color: outlineColor, width: 1, canvas: canvas)
                    line(from: CGPoint(x: mean.x - arm, y: mean.y + arm), to: CGPoint(x: mean.x + arm, y: mean.y - arm), color: outlineColor, width: 1, canvas: canvas)
                }
                if chart.showsValueLabels {
                    text(format(statistics.median, percent: false), in: CGRect(x: box.maxX + 2, y: median - fontSize * 0.6, width: 80, height: fontSize * 1.2),
                         size: fontSize * 0.85, alignment: .left, canvas: canvas)
                }
            }
            if layout.showsMeanLine, means.count > 1 { polyline(means, color: color, canvas: canvas) }
        }
    }
}
