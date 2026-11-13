#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Trendlines and error bars, drawn over a chart's series.
extension ChartPainter {
    /// Where a series' points are, in its data, and how to place data on the plot.
    struct AnalysisFrame {
        /// The plot's bounds, to clip lines and keep labels within.
        var rect: CGRect
        /// The x and value ranges the plot shows.
        var xRange: ClosedRange<Double>
        var yRange: ClosedRange<Double>
        /// Where a point of data sits.
        var place: (Double, Double) -> CGPoint
    }

    // MARK: - Legend

    /// The legend's entries for trendlines: each its own name, or the kind
    /// of line and its series', as PowerPoint names them.
    func trendlineLegendEntries() -> [(String, RGBAColor)] {
        guard chart.kind.hasAxes, chart.kind != .surface, !chart.kind.isExtended else { return [] }
        return chart.allSeries.enumerated().flatMap { index, series in
            series.trendlines.compactMap { trendline -> (String, RGBAColor)? in
                guard let color = lineColor(trendline.line, fallback: seriesColor(series, index: index)) else { return nil }
                return (trendline.name ?? Self.trendlineName(trendline, series: series.name), color)
            }
        }
    }

    static func trendlineName(_ trendline: Chart.Trendline, series: String) -> String {
        switch trendline.kind {
        case .linear: String(format: String(localized: "Chart.Trendline.Linear", bundle: .engine), series)
        case .exp: String(format: String(localized: "Chart.Trendline.Exponential", bundle: .engine), series)
        case .log: String(format: String(localized: "Chart.Trendline.Logarithmic", bundle: .engine), series)
        case .poly: String(format: String(localized: "Chart.Trendline.Polynomial", bundle: .engine), series)
        case .power: String(format: String(localized: "Chart.Trendline.Power", bundle: .engine), series)
        case .movingAvg: String(format: String(localized: "Chart.Trendline.MovingAverage", bundle: .engine), trendline.period, series)
        }
    }

    /// How far series' error bars along `direction` reach, so the axis can take them in.
    func errorBarReach(_ series: [Chart.Series], along direction: Chart.ErrorBars.Direction) -> ClosedRange<Double>? {
        var low = Double.infinity
        var high = -Double.infinity
        for series in series {
            let values = direction == .x ? series.values.indices.map { Optional(xValue(series, at: $0)) } : series.values
            for bars in series.errorBars where bars.direction == direction {
                for (value, extent) in zip(values, bars.extents(of: values)) {
                    guard let value, let extent else { continue }
                    low = min(low, (extent.center ?? value) - extent.minus)
                    high = max(high, (extent.center ?? value) + extent.plus)
                }
            }
        }
        return low <= high ? low...high : nil
    }

    // MARK: - Drawing

    /// A series' error bars, then its trendlines, over its points. `points`
    /// are each point's index, x and plotted value; `values` the series' own
    /// values the bars are measured from, and `xValues` its x values.
    func analysis(
        _ series: Chart.Series, color: RGBAColor, points: [(index: Int, x: Double, y: Double)], values: [Double?], xValues: [Double?],
        frame: AnalysisFrame, canvas: ChartCanvas
    ) {
        for bars in series.errorBars {
            errorBars(bars, points: points, values: bars.direction == .x ? xValues : values, frame: frame, canvas: canvas)
        }
        var labels = 0
        for trendline in series.trendlines {
            guard let lineColor = lineColor(trendline.line, fallback: color) else { continue }
            let data = points.map { (x: $0.x, y: values.indices.contains($0.index) ? values[$0.index] ?? $0.y : $0.y) }
            var curve: [(x: Double, y: Double)]
            var fit: Chart.Trendline.Fit?
            if trendline.kind == .movingAvg {
                curve = trendline.movingAverage(data)
            } else {
                guard let fitted = trendline.fit(data), let low = data.map(\.x).min(), let high = data.map(\.x).max() else { continue }
                fit = fitted
                let from = low - max(trendline.backward, 0)
                let to = high + max(trendline.forward, 0)
                let steps = trendline.kind == .linear ? 1 : 120
                curve = (0...steps).compactMap { step in
                    let x = from + (to - from) * Double(step) / Double(steps)
                    return fitted.value(at: x).map { (x, $0) }
                }
            }
            let runs = clip(curve, to: frame).map { $0.map { frame.place($0.x, $0.y) } }
            let width = CGFloat(EMU.points(trendline.line?.width ?? 19_050))
            canvas.draw(dashed(runs, pattern: dashPattern(trendline.line?.dash ?? "sysDot", width: width)), fill: nil, stroke: lineColor,
                        lineWidth: width, round: false)

            // The equation and R² where the line ends, on the side of it the
            // line leaves clear: under a line that rises to its end, over one that falls.
            guard let fit, trendline.showsEquation || trendline.showsRSquared, let run = runs.last, let end = run.last else { continue }
            let before = run.count > 1 ? run[run.count - 2] : end
            let lines = [trendline.showsEquation ? fit.equation : nil, trendline.showsRSquared ? fit.rSquaredText : nil].compactMap(\.self)
            let size = fontSize * 0.85
            let lineHeight = size * 1.3
            let labelWidth = lines.map { canvas.measure($0, size: size) }.max() ?? 0
            let height = lineHeight * CGFloat(lines.count)
            // Where the line is under the label's far edge, so the label clears it all along.
            let slope = end.x != before.x ? (end.y - before.y) / (end.x - before.x) : 0
            let far = end.y - slope * labelWidth
            let rises = slope < 0
            var origin = CGPoint(
                x: end.x - labelWidth,
                y: rises
                    ? max(end.y, far) + size * 0.4 + lineHeight * CGFloat(labels)
                    : min(end.y, far) - height - size * 0.4 - lineHeight * CGFloat(labels)
            )
            origin.x = min(max(origin.x, frame.rect.minX), frame.rect.maxX - labelWidth)
            origin.y = min(max(origin.y, frame.rect.minY), frame.rect.maxY - height)
            for (row, line) in lines.enumerated() {
                canvas.text(line, in: CGRect(x: origin.x, y: origin.y + lineHeight * CGFloat(row), width: labelWidth, height: lineHeight),
                            size: size, alignment: .left, color: textColor)
            }
            labels += lines.count
        }
    }

    private func errorBars(
        _ bars: Chart.ErrorBars, points: [(index: Int, x: Double, y: Double)], values: [Double?], frame: AnalysisFrame, canvas: ChartCanvas
    ) {
        guard let color = lineColor(bars.line, fallback: textColor) else { return }
        let width = CGFloat(EMU.points(bars.line?.width ?? 9_525))
        let extents = bars.extents(of: values)
        let cap = max(fontSize * 0.3, width * 2)
        let path = CGMutablePath()
        for point in points {
            guard extents.indices.contains(point.index), let extent = extents[point.index] else { continue }
            let along = bars.direction == .x ? point.x : point.y
            let center = extent.center ?? along
            func place(_ value: Double) -> CGPoint {
                bars.direction == .x ? frame.place(value, point.y) : frame.place(point.x, value)
            }
            let low = place(center - extent.minus)
            let high = place(center + extent.plus)
            guard low != high else { continue }
            path.move(to: low)
            path.addLine(to: high)
            guard bars.hasEndCap else { continue }
            // A crossbar at each end the bar reaches out to.
            let length = hypot(high.x - low.x, high.y - low.y)
            let across = CGPoint(x: -(high.y - low.y) / length * cap, y: (high.x - low.x) / length * cap)
            for (end, amount) in [(low, extent.minus), (high, extent.plus)] where amount > 0 {
                path.move(to: CGPoint(x: end.x - across.x, y: end.y - across.y))
                path.addLine(to: CGPoint(x: end.x + across.x, y: end.y + across.y))
            }
        }
        guard !path.isEmpty else { return }
        canvas.draw(path, fill: nil, stroke: color, lineWidth: width, round: false)
    }

    // MARK: - Lines

    /// A line's colour, or `fallback` if it doesn't give one; `nil` if it isn't drawn.
    private func lineColor(_ line: LineStyle?, fallback: RGBAColor) -> RGBAColor? {
        switch line?.fill {
        case .none?: nil
        case .solid(let color)?: style.color(color)
        case .gradient(let gradient)?: gradient.stops.first.map { style.color($0.color) } ?? fallback
        default: fallback
        }
    }

    /// Dashes and gaps for a preset dash, in multiples of the line's width; `nil` for solid.
    func dashPattern(_ dash: String, width: CGFloat) -> [CGFloat]? {
        let pattern: [CGFloat]? = switch dash {
        case "sysDot": [1, 1]
        case "sysDash": [3, 1]
        case "dot": [1, 3]
        case "dash": [4, 3]
        case "lgDash": [8, 3]
        case "dashDot": [4, 3, 1, 3]
        case "sysDashDot": [3, 1, 1, 1]
        case "lgDashDot": [8, 3, 1, 3]
        case "lgDashDotDot": [8, 3, 1, 3, 1, 3]
        case "sysDashDotDot": [3, 1, 1, 1, 1, 1]
        default: nil
        }
        return pattern?.map { $0 * max(width, 0.5) }
    }

    /// Runs of points as one path, cut into dashes where `pattern` gives them,
    /// so that every canvas draws them alike.
    func dashed(_ runs: [[CGPoint]], pattern: [CGFloat]?) -> CGPath {
        let path = CGMutablePath()
        for run in runs {
            guard let first = run.first, run.count > 1 else { continue }
            guard let pattern, pattern.reduce(0, +) > 0 else {
                path.move(to: first)
                for point in run.dropFirst() { path.addLine(to: point) }
                continue
            }
            var part = 0
            var left = pattern[0]
            var drawing = true
            path.move(to: first)
            for (start, end) in zip(run, run.dropFirst()) {
                let length = hypot(end.x - start.x, end.y - start.y)
                var done: CGFloat = 0
                while length - done > left {
                    done += left
                    let at = CGPoint(x: start.x + (end.x - start.x) * done / length, y: start.y + (end.y - start.y) * done / length)
                    if drawing { path.addLine(to: at) } else { path.move(to: at) }
                    drawing.toggle()
                    part = (part + 1) % pattern.count
                    left = pattern[part]
                }
                left -= length - done
                if drawing { path.addLine(to: end) } else { path.move(to: end) }
            }
        }
        return path
    }

    /// The parts of a line, in data, that lie within the plot's ranges.
    private func clip(_ points: [(x: Double, y: Double)], to frame: AnalysisFrame) -> [[(x: Double, y: Double)]] {
        func inside(_ point: (x: Double, y: Double)) -> Bool { frame.xRange.contains(point.x) && frame.yRange.contains(point.y) }
        // Where a segment from `a` to `b` crosses into the ranges, as fractions along it.
        func span(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> (Double, Double)? {
            var low = 0.0
            var high = 1.0
            for (delta, start, minimum, maximum) in [
                (b.x - a.x, a.x, frame.xRange.lowerBound, frame.xRange.upperBound),
                (b.y - a.y, a.y, frame.yRange.lowerBound, frame.yRange.upperBound),
            ] {
                if delta == 0 {
                    if start < minimum || start > maximum { return nil }
                    continue
                }
                var t1 = (minimum - start) / delta
                var t2 = (maximum - start) / delta
                if t1 > t2 { swap(&t1, &t2) }
                low = max(low, t1)
                high = min(high, t2)
                if low > high { return nil }
            }
            return (low, high)
        }
        func lerp(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double), _ t: Double) -> (x: Double, y: Double) {
            (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        }
        var runs: [[(x: Double, y: Double)]] = []
        var current: [(x: Double, y: Double)] = []
        if points.count == 1, let only = points.first, inside(only) { return [[only]] }
        for (a, b) in zip(points, points.dropFirst()) {
            guard let (low, high) = span(a, b) else {
                if !current.isEmpty { runs.append(current) }
                current = []
                continue
            }
            if current.isEmpty { current.append(lerp(a, b, low)) }
            current.append(lerp(a, b, high))
            if high < 1 {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
