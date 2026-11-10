import DazzleEngine
import Foundation

/// A chart drawn as `ChartRenderer` draws it on Apple platforms, in the look
/// PowerPoint gives a new chart, as shapes and labels for the page to put in
/// SVG. Text is measured roughly here; the page draws it where it is anchored.
struct WebChart {
    let chart: Chart
    let style: SlideStyleContext

    private var fontSize: CGFloat { CGFloat(chart.fontSize ?? 1_200) / 100 }
    private var textColor: RGBAColor {
        style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 65_000)).applying(.init(name: "lumOff", value: 35_000))
    }
    private var gridColor: RGBAColor {
        style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 15_000)).applying(.init(name: "lumOff", value: 85_000))
    }

    /// Every rectangle, path and label, in order, in a frame at the origin.
    final class Canvas {
        var items: [[String: Any]] = []

        func rect(_ rect: CGRect, fill: RGBAColor) {
            items.append(["k": "rect", "x": n(rect.minX), "y": n(rect.minY), "w": n(rect.width), "h": n(rect.height), "fill": css(fill)])
        }

        func path(_ path: CGPath, fill: RGBAColor? = nil, stroke: RGBAColor? = nil, width: CGFloat = 1, round: Bool = false) {
            var item: [String: Any] = ["k": "path", "d": path.svgData]
            if let fill { item["fill"] = css(fill) }
            if let stroke {
                item["stroke"] = css(stroke)
                item["sw"] = n(width)
            }
            if round { item["round"] = true }
            items.append(item)
        }

        func line(from: CGPoint, to: CGPoint, color: RGBAColor, width: CGFloat) {
            let path = CGMutablePath()
            path.move(to: from)
            path.addLine(to: to)
            self.path(path, stroke: color, width: width)
        }

        /// One line of text, vertically centred in `rect`.
        func text(_ text: String, in rect: CGRect, size: CGFloat, alignment: String, color: RGBAColor, family: String) {
            let x: CGFloat = switch alignment {
            case "middle": rect.midX
            case "end": rect.maxX
            default: rect.minX
            }
            items.append([
                "k": "text", "t": text, "x": n(x), "y": n(rect.midY), "anchor": alignment, "sz": n(size),
                "fill": css(color), "f": family,
            ])
        }

        private func n(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
    }

    func primitives(in frame: CGRect) -> [[String: Any]] {
        let canvas = Canvas()
        guard frame.width > 20, frame.height > 20 else { return [] }
        let padding = min(frame.width, frame.height) * 0.04 + 4
        var area = frame.insetBy(dx: padding, dy: padding)

        if let title = chart.title, !title.isEmpty {
            let size = fontSize * 1.55
            let height = size * 1.25
            text(title, in: CGRect(x: area.minX, y: area.minY, width: area.width, height: size * 1.4), size: size, alignment: "middle", canvas: canvas)
            area.origin.y += height + padding / 2
            area.size.height -= height + padding / 2
        }
        if chart.hasLegend { area = legend(in: area, padding: padding, canvas: canvas) }
        guard area.width > 10, area.height > 10 else { return canvas.items }

        if chart.kind.colorsByPoint {
            pie(in: area, canvas: canvas)
        } else if chart.kind == .scatter {
            scatter(in: area, canvas: canvas)
        } else {
            categoryPlots(in: area, canvas: canvas)
        }
        return canvas.items
    }

    // MARK: - Colours

    /// The colour of the `index`th series or slice: the theme's six accents,
    /// then the same again darker, then lighter.
    func color(at index: Int) -> RGBAColor {
        var color = DrawingColor.scheme("accent\(index % 6 + 1)")
        switch (index / 6) % 3 {
        case 1: color.transforms = [.init(name: "lumMod", value: 60_000)]
        case 2: color.transforms = [.init(name: "lumMod", value: 80_000), .init(name: "lumOff", value: 20_000)]
        default: break
        }
        return style.color(color)
    }

    private func seriesColor(_ series: Chart.Series, index: Int) -> RGBAColor {
        series.color.map { style.color($0) } ?? color(at: index)
    }

    // MARK: - Legend

    private func legend(in area: CGRect, padding: CGFloat, canvas: Canvas) -> CGRect {
        let entries: [(String, RGBAColor)] = chart.kind.colorsByPoint
            ? chart.categories.enumerated().map { index, name in
                (name, chart.plots.first?.series.first?.pointColors[index].map { style.color($0) } ?? color(at: index))
            }
            : chart.allSeries.enumerated().map { ($1.name, seriesColor($1, index: $0)) }
        guard !entries.isEmpty else { return area }
        let swatch = fontSize * 0.7
        let lineHeight = fontSize * 1.5
        let widths = entries.map { measure($0.0, size: fontSize) + swatch + fontSize * 0.5 }
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

    private func legendEntry(_ entry: (String, RGBAColor), at point: CGPoint, swatch: CGFloat, canvas: Canvas) {
        canvas.rect(CGRect(x: point.x, y: point.y, width: swatch, height: swatch), fill: entry.1)
        text(entry.0, in: CGRect(x: point.x + swatch + fontSize * 0.35, y: point.y + swatch / 2 - fontSize * 0.7, width: 1_000, height: fontSize * 1.4),
             size: fontSize, alignment: "start", canvas: canvas)
    }

    // MARK: - Columns, bars, lines and areas

    /// A range from `low` to `high` rounded out to steps of 1, 2 or 5 times a power of ten, about five of them.
    private struct Scale {
        var minimum: Double
        var maximum: Double
        var step: Double

        static func nice(low: Double, high: Double, fixedMinimum: Double? = nil, fixedMaximum: Double? = nil) -> Scale {
            var low = min(low, 0)
            var high = max(high, 0)
            if let fixedMinimum { low = fixedMinimum }
            if let fixedMaximum { high = fixedMaximum }
            if high <= low { high = low + 1 }
            let rough = (high - low) / 5
            let magnitude = pow(10, floor(log10(rough)))
            let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? rough
            return Scale(minimum: fixedMinimum ?? floor(low / step) * step, maximum: fixedMaximum ?? ceil(high / step) * step, step: step)
        }

        var ticks: [Double] {
            guard step > 0, maximum > minimum else { return [minimum] }
            return Array(stride(from: minimum, through: maximum + step / 1_000, by: step))
        }
    }

    private func valueScale() -> Scale {
        var low = 0.0
        var high = 0.0
        for plot in chart.plots {
            let count = chart.categories.count
            if plot.grouping == .percentStacked {
                high = max(high, 1)
                continue
            }
            if plot.grouping == .stacked && plot.kind != .line {
                for index in 0..<count {
                    let values = plot.series.compactMap { $0.values.indices.contains(index) ? $0.values[index] : nil }
                    high = max(high, values.filter { $0 > 0 }.reduce(0, +))
                    low = min(low, values.filter { $0 < 0 }.reduce(0, +))
                }
            } else {
                let values = plot.series.flatMap { $0.values.compactMap(\.self) }
                high = max(high, values.max() ?? 0)
                low = min(low, values.min() ?? 0)
            }
        }
        return .nice(low: low, high: high, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
    }

    private func categoryPlots(in area: CGRect, canvas: Canvas) {
        let horizontal = chart.kind == .bar
        let scale = valueScale()
        let isPercent = chart.plots.first?.grouping == .percentStacked
        let labels = scale.ticks.map { format($0, percent: isPercent) }
        let labelWidth = (labels.map { measure($0, size: fontSize) }.max() ?? 0) + fontSize * 0.5
        let categoryHeight = fontSize * 1.6
        var plot = area
        if horizontal {
            let widest = (chart.categories.map { measure($0, size: fontSize) }.max() ?? 0) + fontSize * 0.6
            plot.origin.x += min(widest, area.width * 0.3)
            plot.size.width -= min(widest, area.width * 0.3)
            plot.size.height -= categoryHeight
        } else {
            plot.origin.x += labelWidth
            plot.size.width -= labelWidth
            plot.size.height -= categoryHeight
        }
        guard plot.width > 4, plot.height > 4 else { return }

        func position(_ value: Double) -> CGFloat {
            let fraction = (value - scale.minimum) / (scale.maximum - scale.minimum)
            return horizontal ? plot.minX + plot.width * fraction : plot.maxY - plot.height * fraction
        }

        for (index, tick) in scale.ticks.enumerated() {
            let at = position(tick)
            if chart.showsGridlines {
                canvas.line(
                    from: horizontal ? CGPoint(x: at, y: plot.minY) : CGPoint(x: plot.minX, y: at),
                    to: horizontal ? CGPoint(x: at, y: plot.maxY) : CGPoint(x: plot.maxX, y: at), color: gridColor, width: 0.75
                )
            }
            if horizontal {
                text(labels[index], in: CGRect(x: at - 40, y: plot.maxY + fontSize * 0.2, width: 80, height: fontSize * 1.4),
                     size: fontSize, alignment: "middle", canvas: canvas)
            } else {
                text(labels[index], in: CGRect(x: area.minX, y: at - fontSize * 0.7, width: labelWidth - fontSize * 0.4, height: fontSize * 1.4),
                     size: fontSize, alignment: "end", canvas: canvas)
            }
        }

        let count = max(chart.categories.count, 1)
        let band = (horizontal ? plot.height : plot.width) / CGFloat(count)
        let widest = chart.categories.map { measure($0, size: fontSize) }.max() ?? 0
        let every = horizontal ? 1 : max(Int(ceil((widest + fontSize) / max(band, 1))), 1)
        for (index, name) in chart.categories.enumerated() where index % every == 0 {
            // Bars list their categories from the bottom up, as PowerPoint does.
            let center = horizontal ? plot.maxY - band * (CGFloat(index) + 0.5) : plot.minX + band * (CGFloat(index) + 0.5)
            if horizontal {
                text(name, in: CGRect(x: area.minX, y: center - fontSize * 0.7, width: plot.minX - area.minX - fontSize * 0.3, height: fontSize * 1.4),
                     size: fontSize, alignment: "end", canvas: canvas)
            } else {
                text(name, in: CGRect(x: center - band * CGFloat(every) / 2, y: plot.maxY + fontSize * 0.2, width: band * CGFloat(every), height: fontSize * 1.4),
                     size: fontSize, alignment: "middle", canvas: canvas)
            }
        }

        var seriesIndex = 0
        for plotData in chart.plots {
            switch plotData.kind {
            case .column, .bar:
                bars(plotData, firstIndex: seriesIndex, band: band, plot: plot, horizontal: horizontal, position: position, canvas: canvas)
            case .line:
                lines(plotData, firstIndex: seriesIndex, band: band, plot: plot, area: false, position: position, canvas: canvas)
            case .area:
                lines(plotData, firstIndex: seriesIndex, band: band, plot: plot, area: true, position: position, canvas: canvas)
            default:
                break
            }
            seriesIndex += plotData.series.count
        }

        let zero = position(max(min(0, scale.maximum), scale.minimum))
        canvas.line(
            from: horizontal ? CGPoint(x: zero, y: plot.minY) : CGPoint(x: plot.minX, y: zero),
            to: horizontal ? CGPoint(x: zero, y: plot.maxY) : CGPoint(x: plot.maxX, y: zero),
            color: gridColor.applying(.init(name: "lumMod", value: 75_000)), width: 1
        )
    }

    private func stackedRange(_ plot: Chart.Plot, series: Int, category: Int) -> (from: Double, to: Double)? {
        func value(_ series: Chart.Series) -> Double? {
            series.values.indices.contains(category) ? series.values[category] : nil
        }
        guard let own = value(plot.series[series]) else { return nil }
        guard plot.grouping != .standard else { return (0, own) }
        let below = plot.series[..<series].compactMap(value).filter { ($0 >= 0) == (own >= 0) }.reduce(0, +)
        var range = (from: below, to: below + own)
        if plot.grouping == .percentStacked {
            let total = plot.series.compactMap(value).map(abs).reduce(0, +)
            if total > 0 { range = (range.from / total, range.to / total) }
        }
        return range
    }

    private func bars(
        _ plot: Chart.Plot, firstIndex: Int, band: CGFloat, plot rect: CGRect, horizontal: Bool,
        position: (Double) -> CGFloat, canvas: Canvas
    ) {
        let stacked = plot.grouping != .standard
        let slots = stacked ? 1 : max(plot.series.count, 1)
        let barWidth = band / (CGFloat(slots) + 1.5)
        for category in 0..<chart.categories.count {
            let start = horizontal
                ? rect.maxY - band * CGFloat(category + 1) + barWidth * 0.75
                : rect.minX + band * CGFloat(category) + barWidth * 0.75
            for (index, series) in plot.series.enumerated() {
                guard let range = stackedRange(plot, series: index, category: category) else { continue }
                let slot = stacked ? 0 : (horizontal ? slots - 1 - index : index)
                let from = position(range.from)
                let to = position(range.to)
                let bar = horizontal
                    ? CGRect(x: min(from, to), y: start + barWidth * CGFloat(slot), width: abs(to - from), height: barWidth)
                    : CGRect(x: start + barWidth * CGFloat(slot), y: min(from, to), width: barWidth, height: abs(to - from))
                canvas.rect(bar, fill: series.pointColors[category].map { style.color($0) } ?? seriesColor(series, index: firstIndex + index))
                if chart.showsValueLabels, series.values.indices.contains(category), let value = series.values[category] {
                    let labelRect = horizontal
                        ? CGRect(x: bar.maxX + 2, y: bar.midY - fontSize * 0.6, width: 80, height: fontSize * 1.2)
                        : CGRect(x: bar.midX - 40, y: bar.minY - fontSize * 1.3, width: 80, height: fontSize * 1.2)
                    text(format(value, percent: false), in: labelRect, size: fontSize * 0.85, alignment: horizontal ? "start" : "middle", canvas: canvas)
                }
            }
        }
    }

    private func lines(
        _ plot: Chart.Plot, firstIndex: Int, band: CGFloat, plot rect: CGRect, area: Bool,
        position: (Double) -> CGFloat, canvas: Canvas
    ) {
        for index in plot.series.indices {
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
            let path = CGMutablePath()
            path.move(to: points[0].0)
            for point in points.dropFirst() { path.addLine(to: point.0) }
            if area {
                for point in baseline.reversed() { path.addLine(to: point) }
                path.closeSubpath()
                canvas.path(path, fill: color)
            } else {
                canvas.path(path, stroke: color, width: max(fontSize * 0.19, 1.5), round: true)
                let marker = fontSize * 0.42
                for point in points {
                    let dot = CGMutablePath()
                    dot.addEllipse(in: CGRect(x: point.0.x - marker / 2, y: point.0.y - marker / 2, width: marker, height: marker))
                    canvas.path(dot, fill: color)
                }
            }
            if chart.showsValueLabels {
                for point in points {
                    text(format(point.1, percent: false), in: CGRect(x: point.0.x - 40, y: point.0.y - fontSize * 1.5, width: 80, height: fontSize * 1.2),
                         size: fontSize * 0.85, alignment: "middle", canvas: canvas)
                }
            }
        }
    }

    // MARK: - Pies

    private func pie(in area: CGRect, canvas: Canvas) {
        guard let plot = chart.plots.first, let series = plot.series.first else { return }
        let values = series.values.map { max($0 ?? 0, 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let radius = min(area.width, area.height) / 2 * 0.92
        let hole = plot.kind == .doughnut ? radius * CGFloat(min(max(plot.holeSize, 10), 90)) / 100 : 0
        let center = CGPoint(x: area.midX, y: area.midY)
        var angle = -CGFloat.pi / 2
        for (index, value) in values.enumerated() where value > 0 {
            let sweep = CGFloat(value / total) * .pi * 2
            let slice = CGMutablePath()
            if hole > 0 {
                slice.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
                slice.addArc(center: center, radius: hole, startAngle: angle + sweep, endAngle: angle, clockwise: true)
            } else {
                slice.move(to: center)
                slice.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
            }
            slice.closeSubpath()
            canvas.path(slice, fill: series.pointColors[index].map { style.color($0) } ?? color(at: index), stroke: style.color(.scheme("bg1")), width: 1)
            if chart.showsValueLabels {
                let middle = angle + sweep / 2
                let distance = hole > 0 ? (radius + hole) / 2 : radius * 0.65
                let at = CGPoint(x: center.x + cos(middle) * distance, y: center.y + sin(middle) * distance)
                text(format(value, percent: false), in: CGRect(x: at.x - 40, y: at.y - fontSize * 0.6, width: 80, height: fontSize * 1.2),
                     size: fontSize * 0.9, alignment: "middle", canvas: canvas, color: .white)
            }
            angle += sweep
        }
    }

    // MARK: - Scatter

    private func scatter(in area: CGRect, canvas: Canvas) {
        let series = chart.allSeries
        let xs = series.flatMap { $0.xValues.isEmpty ? $0.values.indices.map { Double($0 + 1) } : $0.xValues.compactMap(\.self) }
        let ys = series.flatMap { $0.values.compactMap(\.self) }
        let xScale = Scale.nice(low: xs.min() ?? 0, high: xs.max() ?? 1)
        let yScale = Scale.nice(low: ys.min() ?? 0, high: ys.max() ?? 1, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
        let labelWidth = (yScale.ticks.map { measure(format($0, percent: false), size: fontSize) }.max() ?? 0) + fontSize * 0.5
        var plot = area
        plot.origin.x += labelWidth
        plot.size.width -= labelWidth
        plot.size.height -= fontSize * 1.6
        guard plot.width > 4, plot.height > 4 else { return }
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(
                x: plot.minX + plot.width * (x - xScale.minimum) / (xScale.maximum - xScale.minimum),
                y: plot.maxY - plot.height * (y - yScale.minimum) / (yScale.maximum - yScale.minimum)
            )
        }
        for tick in yScale.ticks {
            let at = point(xScale.minimum, tick).y
            if chart.showsGridlines {
                canvas.line(from: CGPoint(x: plot.minX, y: at), to: CGPoint(x: plot.maxX, y: at), color: gridColor, width: 0.75)
            }
            text(format(tick, percent: false), in: CGRect(x: area.minX, y: at - fontSize * 0.7, width: labelWidth - fontSize * 0.4, height: fontSize * 1.4),
                 size: fontSize, alignment: "end", canvas: canvas)
        }
        for tick in xScale.ticks {
            let at = point(tick, yScale.minimum).x
            text(format(tick, percent: false), in: CGRect(x: at - 40, y: plot.maxY + fontSize * 0.2, width: 80, height: fontSize * 1.4),
                 size: fontSize, alignment: "middle", canvas: canvas)
        }
        let marker = fontSize * 0.5
        for (index, series) in series.enumerated() {
            let color = seriesColor(series, index: index)
            for (pointIndex, value) in series.values.enumerated() {
                guard let value else { continue }
                let x = series.xValues.isEmpty ? Double(pointIndex + 1)
                    : (series.xValues.indices.contains(pointIndex) ? series.xValues[pointIndex] ?? 0 : 0)
                let at = point(x, value)
                let dot = CGMutablePath()
                dot.addEllipse(in: CGRect(x: at.x - marker / 2, y: at.y - marker / 2, width: marker, height: marker))
                canvas.path(dot, fill: color)
            }
        }
    }

    // MARK: - Text

    private func format(_ value: Double, percent: Bool) -> String {
        if percent { return (value * 100).formatted(.number.precision(.fractionLength(0))) + "%" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// About how wide a line of text sets: half an em for Latin letters, an em for Chinese, Japanese and Korean.
    private func measure(_ text: String, size: CGFloat) -> CGFloat {
        text.unicodeScalars.reduce(0) { width, scalar in
            width + size * (scalar.value >= 0x2E80 ? 1 : (scalar.properties.isUppercase ? 0.65 : 0.52))
        }
    }

    private func text(_ text: String, in rect: CGRect, size: CGFloat, alignment: String, canvas: Canvas, color: RGBAColor? = nil) {
        canvas.text(text, in: rect, size: size, alignment: alignment, color: color ?? textColor, family: style.theme.minorFont)
    }
}
