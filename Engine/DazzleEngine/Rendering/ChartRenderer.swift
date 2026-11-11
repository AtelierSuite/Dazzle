#if canImport(CoreText)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif
import Foundation

/// Draws a chart into a Core Graphics context, as `ChartPainter` lays it out.
public struct ChartRenderer {
    public typealias Scale = ChartPainter.Scale

    public let chart: Chart
    public let style: SlideStyleContext

    public init(chart: Chart, style: SlideStyleContext) {
        self.chart = chart
        self.style = style
    }

    /// Draws the chart filling `frame`, in a context whose y axis points down.
    public func draw(in frame: CGRect, context: CGContext) {
        guard frame.width > 20, frame.height > 20 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: frame)
        ChartPainter(chart: chart, style: style).draw(in: frame, on: Canvas(context: context, style: style))
    }

    /// The colour of the `index`th series or slice.
    public func color(at index: Int) -> RGBAColor {
        ChartPainter(chart: chart, style: style).color(at: index)
    }

    private final class Canvas: ChartCanvas {
        let context: CGContext
        let style: SlideStyleContext

        init(context: CGContext, style: SlideStyleContext) {
            self.context = context
            self.style = style
        }

        func fill(_ rect: CGRect, color: RGBAColor) {
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }

        func draw(_ path: CGPath, fill: RGBAColor?, stroke: RGBAColor?, lineWidth: CGFloat, round: Bool) {
            if let fill {
                context.addPath(path)
                context.setFillColor(fill.cgColor)
                context.fillPath()
            }
            if let stroke, lineWidth > 0 {
                context.addPath(path)
                context.setStrokeColor(stroke.cgColor)
                context.setLineWidth(lineWidth)
                context.setLineJoin(round ? .round : .miter)
                context.setLineCap(round ? .round : .butt)
                context.strokePath()
            }
        }

        private func font(size: CGFloat) -> CTFont {
            FontResolver.shared.font(
                family: style.theme.minorFont, size: size, bold: false, italic: false, embedded: style.resources.embeddedFonts
            )
        }

        func measure(_ text: String, size: CGFloat) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(size: size),
            ]))
            return CTLineGetBoundsWithOptions(line, .useOpticalBounds).width
        }

        func lineHeight(size: CGFloat) -> CGFloat {
            let font = font(size: size)
            return CTFontGetAscent(font) + CTFontGetDescent(font)
        }

        func text(_ text: String, in rect: CGRect, size: CGFloat, alignment: ChartTextAlignment, color: RGBAColor) {
            let font = font(size: size)
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            ])
            let line = CTLineCreateWithAttributedString(string)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let x: CGFloat = switch alignment {
            case .center: rect.midX - bounds.width / 2
            case .right: rect.maxX - bounds.width
            case .left: rect.minX
            }
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: x, y: rect.midY + (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
#endif
