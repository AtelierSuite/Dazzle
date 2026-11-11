import DazzleEngine
import Foundation

/// A chart drawn as `ChartPainter` draws it on Apple platforms, in the look
/// PowerPoint gives a new chart, as shapes and labels for the page to put in
/// SVG. Text is measured roughly here; the page draws it where it is anchored.
struct WebChart {
    let chart: Chart
    let style: SlideStyleContext

    /// Every rectangle, path and label, in order, in a frame at the origin.
    final class Canvas: ChartCanvas {
        var items: [[String: Any]] = []
        let family: String

        init(family: String) {
            self.family = family
        }

        func fill(_ rect: CGRect, color: RGBAColor) {
            items.append(["k": "rect", "x": n(rect.minX), "y": n(rect.minY), "w": n(rect.width), "h": n(rect.height), "fill": css(color)])
        }

        func draw(_ path: CGPath, fill: RGBAColor?, stroke: RGBAColor?, lineWidth: CGFloat, round: Bool) {
            var item: [String: Any] = ["k": "path", "d": path.svgData]
            if let fill { item["fill"] = css(fill) }
            if let stroke, lineWidth > 0 {
                item["stroke"] = css(stroke)
                item["sw"] = n(lineWidth)
            }
            if round { item["round"] = true }
            items.append(item)
        }

        func text(_ text: String, in rect: CGRect, size: CGFloat, alignment: ChartTextAlignment, color: RGBAColor) {
            let (x, anchor): (CGFloat, String) = switch alignment {
            case .center: (rect.midX, "middle")
            case .right: (rect.maxX, "end")
            case .left: (rect.minX, "start")
            }
            items.append([
                "k": "text", "t": text, "x": n(x), "y": n(rect.midY), "anchor": anchor, "sz": n(size), "fill": css(color), "f": family,
            ])
        }

        /// About how wide a line of text sets: half an em for Latin letters, an em for Chinese, Japanese and Korean.
        func measure(_ text: String, size: CGFloat) -> CGFloat {
            text.unicodeScalars.reduce(0) { width, scalar in
                width + size * (scalar.value >= 0x2E80 ? 1 : (scalar.properties.isUppercase ? 0.65 : 0.52))
            }
        }

        func lineHeight(size: CGFloat) -> CGFloat { size * 1.25 }

        private func n(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
    }

    func primitives(in frame: CGRect) -> [[String: Any]] {
        let canvas = Canvas(family: style.theme.minorFont)
        ChartPainter(chart: chart, style: style).draw(in: frame, on: canvas)
        return canvas.items
    }
}
