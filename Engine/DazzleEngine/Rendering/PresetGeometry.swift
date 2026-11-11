#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Outlines for DrawingML's preset shapes.
///
/// Covers the shapes decks are actually built from; anything else is drawn
/// as its bounding rectangle, which keeps it in place and the right size.
public enum PresetGeometry {
    /// Whether the preset is a line rather than an area, so is never filled.
    public static func isOpen(_ name: String) -> Bool {
        name == "line" || name == "arc" || name.hasSuffix("Connector1") || name.hasSuffix("Connector2")
            || name.hasSuffix("Connector3") || name.hasSuffix("Connector4") || name.hasSuffix("Connector5")
            || name == "leftBracket" || name == "rightBracket" || name == "leftBrace" || name == "rightBrace"
            || name == "bracketPair" || name == "bracePair"
    }

    public static func path(_ name: String, adjustments: [String: Int], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY
        let shortSide = min(w, h)
        /// An adjust value as a fraction, from the file or the preset's default.
        func adjust(_ key: String, _ fallback: Int) -> CGFloat {
            CGFloat(adjustments[key] ?? fallback) / 100_000
        }
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + px, y: y + py) }
        func polygon(_ points: [CGPoint]) {
            path.addLines(between: points)
            path.closeSubpath()
        }

        switch name {
        case "ellipse", "flowChartConnector":
            path.addEllipse(in: rect)
        case "roundRect", "flowChartAlternateProcess":
            let radius = min(shortSide * adjust("adj", 16_667), shortSide / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case "flowChartTerminator":
            path.addRoundedRect(in: rect, cornerWidth: min(w / 2, h / 2), cornerHeight: h / 2)
        case "round2SameRect":
            let radius = min(shortSide * adjust("adj1", 16_667), shortSide / 2)
            path.move(to: point(0, h))
            path.addLine(to: point(0, radius))
            path.addArc(tangent1End: point(0, 0), tangent2End: point(radius, 0), radius: radius)
            path.addLine(to: point(w - radius, 0))
            path.addArc(tangent1End: point(w, 0), tangent2End: point(w, radius), radius: radius)
            path.addLine(to: point(w, h))
            path.closeSubpath()
        case "snip1Rect":
            let snip = shortSide * adjust("adj", 16_667)
            polygon([point(0, 0), point(w - snip, 0), point(w, snip), point(w, h), point(0, h)])
        case "triangle", "flowChartExtract":
            polygon([point(w * adjust("adj", 50_000), 0), point(w, h), point(0, h)])
        case "rtTriangle":
            polygon([point(0, 0), point(w, h), point(0, h)])
        case "diamond", "flowChartDecision":
            polygon([point(w / 2, 0), point(w, h / 2), point(w / 2, h), point(0, h / 2)])
        case "parallelogram", "flowChartInputOutput":
            let offset = min(shortSide * adjust("adj", 25_000), w)
            polygon([point(offset, 0), point(w, 0), point(w - offset, h), point(0, h)])
        case "trapezoid":
            let offset = min(shortSide * adjust("adj", 25_000), w / 2)
            polygon([point(offset, 0), point(w - offset, 0), point(w, h), point(0, h)])
        case "pentagon", "homePlate":
            if name == "homePlate" {
                let tip = min(shortSide * adjust("adj", 50_000), w)
                polygon([point(0, 0), point(w - tip, 0), point(w, h / 2), point(w - tip, h), point(0, h)])
            } else {
                polygon(regularPolygon(sides: 5, in: rect))
            }
        case "chevron":
            let tip = min(shortSide * adjust("adj", 50_000), w)
            polygon([point(0, 0), point(w - tip, 0), point(w, h / 2), point(w - tip, h), point(0, h), point(tip, h / 2)])
        case "hexagon":
            let inset = min(shortSide * adjust("adj", 25_000), w / 2)
            polygon([point(inset, 0), point(w - inset, 0), point(w, h / 2), point(w - inset, h), point(inset, h), point(0, h / 2)])
        case "octagon":
            let inset = shortSide * adjust("adj", 29_289)
            polygon([
                point(inset, 0), point(w - inset, 0), point(w, inset), point(w, h - inset),
                point(w - inset, h), point(inset, h), point(0, h - inset), point(0, inset),
            ])
        case "star4", "star5", "star6", "star7", "star8", "star10", "star12", "star16", "star24", "star32":
            let points = Int(name.dropFirst(4)) ?? 5
            let defaults = [4: 12_500, 5: 19_098, 6: 28_868, 7: 34_601, 8: 37_500, 10: 42_533, 12: 37_500]
            let inner = adjust("adj", defaults[points] ?? 37_500) * 2
            polygon(star(points: points, innerRatio: inner, in: rect))
        case "plus", "mathPlus":
            let arm = shortSide * adjust("adj", 25_000)
            polygon([
                point(arm, 0), point(w - arm, 0), point(w - arm, arm), point(w, arm), point(w, h - arm),
                point(w - arm, h - arm), point(w - arm, h), point(arm, h), point(arm, h - arm), point(0, h - arm),
                point(0, arm), point(arm, arm),
            ])
        case "rightArrow", "leftArrow", "upArrow", "downArrow", "leftRightArrow":
            arrow(name, path: path, rect: rect, shaft: adjust("adj1", 50_000), head: adjust("adj2", 50_000))
        case "donut":
            path.addEllipse(in: rect)
            let thickness = shortSide * adjust("adj", 25_000)
            path.addEllipse(in: rect.insetBy(dx: thickness, dy: thickness))
        case "heart":
            path.move(to: point(w / 2, h / 4))
            path.addCurve(to: point(w / 2, h), control1: point(w * 1.1, -h / 3), control2: point(w * 1.25, h / 2))
            path.addCurve(to: point(w / 2, h / 4), control1: point(-w * 0.25, h / 2), control2: point(-w * 0.1, -h / 3))
            path.closeSubpath()
        case "wedgeRectCallout", "wedgeRoundRectCallout", "wedgeEllipseCallout":
            callout(name, path: path, rect: rect,
                    offset: CGPoint(x: adjust("adj1", -20_833), y: adjust("adj2", 62_500)),
                    corner: adjust("adj3", 16_667))
        case "can", "flowChartMagneticDisk":
            let lid = h * adjust("adj", 25_000) / 2
            path.move(to: point(0, lid / 2))
            path.addLine(to: point(0, h - lid / 2))
            path.addCurve(to: point(w, h - lid / 2), control1: point(0, h + lid / 6), control2: point(w, h + lid / 6))
            path.addLine(to: point(w, lid / 2))
            path.addEllipse(in: CGRect(x: x, y: y, width: w, height: lid))
        case "line", "straightConnector1":
            path.move(to: point(0, 0))
            path.addLine(to: point(w, h))
        case "bentConnector2":
            path.addLines(between: [point(0, 0), point(w, 0), point(w, h)])
        case "bentConnector3", "bentConnector4", "bentConnector5":
            let bend = w * adjust("adj1", 50_000)
            path.addLines(between: [point(0, 0), point(bend, 0), point(bend, h), point(w, h)])
        case "curvedConnector2", "curvedConnector3", "curvedConnector4", "curvedConnector5":
            path.move(to: point(0, 0))
            path.addCurve(to: point(w, h), control1: point(w / 2, 0), control2: point(w / 2, h))
        case "arc":
            let start = CGFloat(adjustments["adj1"] ?? 16_200_000) / 60_000 * .pi / 180
            let end = CGFloat(adjustments["adj2"] ?? 0) / 60_000 * .pi / 180
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: w / 2, y: h / 2)
            path.addArc(center: .zero, radius: 1, startAngle: start, endAngle: end, clockwise: false, transform: transform)
        case "leftBracket", "rightBracket":
            let isLeft = name == "leftBracket"
            let edge = isLeft ? w : 0
            let spine = isLeft ? 0 : w
            path.move(to: point(edge, 0))
            path.addQuadCurve(to: point(spine, h * 0.1), control: point(spine, 0))
            path.addLine(to: point(spine, h * 0.9))
            path.addQuadCurve(to: point(edge, h), control: point(spine, h))
        case "wave", "doubleWave":
            path.addPath(wave(name, adjustments: adjustments, in: rect).outline)
        case "ellipseRibbon":
            path.addPath(ellipseRibbon(adjustments: adjustments, in: rect).outline)
        case "cloud":
            path.addPath(cloud(in: rect))
        case "cloudCallout":
            return cloudCallout(adjustments: adjustments, in: rect)
        default:
            path.addRect(rect)
        }
        return path
    }

    /// Lines some presets draw over their fill, with the outline's stroke but
    /// never filled: a ribbon's folds and the inner curves of a cloud's puffs.
    public static func detailPath(_ name: String, adjustments: [String: Int], in rect: CGRect) -> CGPath? {
        switch name {
        case "ellipseRibbon":
            return ellipseRibbon(adjustments: adjustments, in: rect).folds
        case "cloud", "cloudCallout":
            let path = CGMutablePath()
            let scale = CGSize(width: rect.width / 43_200, height: rect.height / 43_200)
            for puff in cloudPuffs {
                let start = CGPoint(x: rect.minX + puff.x * scale.width, y: rect.minY + puff.y * scale.height)
                path.move(to: start)
                arcTo(path, from: start, wR: puff.wR, hR: puff.hR, start: puff.start, sweep: puff.sweep, scale: scale)
            }
            return path
        default:
            return nil
        }
    }

    /// The rectangle text is laid out in, which for most presets is smaller
    /// than the shape so text stays inside its outline.
    public static func textRect(_ name: String, adjustments: [String: Int], in rect: CGRect) -> CGRect {
        let w = rect.width
        let h = rect.height
        let shortSide = min(w, h)
        func adjust(_ key: String, _ fallback: Int) -> CGFloat {
            CGFloat(adjustments[key] ?? fallback) / 100_000
        }
        func inset(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> CGRect {
            CGRect(x: rect.minX + left, y: rect.minY + top, width: max(w - left - right, 1), height: max(h - top - bottom, 1))
        }
        switch name {
        case "wave", "doubleWave":
            return wave(name, adjustments: adjustments, in: rect).text
        case "ellipseRibbon":
            return ellipseRibbon(adjustments: adjustments, in: rect).text
        case "cloud", "cloudCallout":
            // ECMA-376's text box for the cloud, in its 21600-unit grid.
            return CGRect(x: rect.minX + w * 2_977 / 21_600, y: rect.minY + h * 3_262 / 21_600,
                          width: w * (17_087 - 2_977) / 21_600, height: h * (17_337 - 3_262) / 21_600)
        case "ellipse", "flowChartConnector", "donut", "wedgeEllipseCallout":
            // The square inscribed in the circle: 1 − 1/√2, halved.
            return inset(left: w * 0.146_4, top: h * 0.146_4, right: w * 0.146_4, bottom: h * 0.146_4)
        case "roundRect", "flowChartAlternateProcess":
            let corner = min(shortSide * adjust("adj", 16_667), shortSide / 2) * 0.292_9
            return inset(left: corner, top: corner, right: corner, bottom: corner)
        case "wedgeRoundRectCallout":
            let corner = min(max(shortSide * adjust("adj3", 16_667), 0), shortSide / 2) * 0.292_9
            return inset(left: corner, top: corner, right: corner, bottom: corner)
        case "diamond", "flowChartDecision":
            return inset(left: w / 4, top: h / 4, right: w / 4, bottom: h / 4)
        case "triangle", "flowChartExtract":
            let apex = w * adjust("adj", 50_000)
            return CGRect(x: rect.minX + apex / 2, y: rect.minY + h / 2, width: w / 2, height: h / 2)
        case "rtTriangle":
            return inset(left: w / 12, top: h * 7 / 12, right: w * 7 / 12, bottom: h / 12)
        case "star4", "star5", "star6", "star7", "star8":
            return inset(left: w * 0.31, top: h * 0.38, right: w * 0.31, bottom: h * 0.24)
        case "hexagon", "octagon":
            let side = shortSide * adjust("adj", name == "hexagon" ? 25_000 : 29_289) * 0.5
            return inset(left: side, top: side, right: side, bottom: side)
        case "parallelogram", "trapezoid", "flowChartInputOutput":
            let slant = min(shortSide * adjust("adj", 25_000), w / 2) * 0.5
            return inset(left: slant, top: 0, right: slant, bottom: 0)
        case "rightArrow", "leftArrow", "leftRightArrow":
            let shaft = h * (1 - adjust("adj1", 50_000)) / 2
            return inset(left: name == "rightArrow" ? 0 : shortSide * 0.25, top: shaft,
                         right: name == "leftArrow" ? 0 : shortSide * 0.25, bottom: shaft)
        case "upArrow", "downArrow":
            let shaft = w * (1 - adjust("adj1", 50_000)) / 2
            return inset(left: shaft, top: 0, right: shaft, bottom: 0)
        case "chevron", "homePlate":
            let tip = min(shortSide * adjust("adj", 50_000), w) * 0.5
            return inset(left: name == "chevron" ? tip : 0, top: 0, right: tip, bottom: 0)
        default:
            return rect
        }
    }

    /// The tail replaces part of the body's perimeter. Separate overlapping
    /// subpaths would cut a hole with even-odd filling and stroke across the text.
    private static func callout(_ name: String, path: CGMutablePath, rect: CGRect, offset: CGPoint, corner: CGFloat) {
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x, y: rect.minY + y)
        }
        let tip = point(w * (0.5 + offset.x), h * (0.5 + offset.y))
        if name == "wedgeEllipseCallout" {
            guard hypot(offset.x * 2, offset.y * 2) > 1 else {
                path.addEllipse(in: rect)
                return
            }
            let angle = atan2(offset.y, offset.x)
            let gap = CGFloat.pi * 11 / 180
            let start = angle + gap
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: w / 2, y: h / 2)
            path.move(to: tip)
            path.addLine(to: point(w / 2 * (1 + cos(start)), h / 2 * (1 + sin(start))))
            path.addArc(center: .zero, radius: 1, startAngle: start,
                        endAngle: angle - gap + 2 * .pi, clockwise: false, transform: transform)
            path.closeSubpath()
            return
        }

        let radius = name == "wedgeRoundRectCallout" ? min(max(min(w, h) * corner, 0), min(w, h) / 2) : 0
        // DrawingML attaches to the dominant axis in normalized shape space.
        let vertical = abs(offset.y) > abs(offset.x)
        let side = vertical ? (offset.y > 0 ? 2 : 0) : (offset.x > 0 ? 1 : 3)
        let hasTail = max(abs(offset.x), abs(offset.y)) > 0.5
        let x1 = min(w - radius, max(radius, w * (offset.x > 0 ? 7 : 2) / 12))
        let x2 = min(w - radius, max(radius, w * (offset.x > 0 ? 10 : 5) / 12))
        let y1 = min(h - radius, max(radius, h * (offset.y > 0 ? 7 : 2) / 12))
        let y2 = min(h - radius, max(radius, h * (offset.y > 0 ? 10 : 5) / 12))
        func tail(_ edge: Int, from: CGPoint, to: CGPoint) {
            guard hasTail, side == edge else { return }
            path.addLine(to: from)
            path.addLine(to: tip)
            path.addLine(to: to)
        }
        func turn(_ x: CGFloat, _ y: CGFloat, _ endX: CGFloat, _ endY: CGFloat) {
            if radius > 0 {
                path.addArc(tangent1End: point(x, y), tangent2End: point(endX, endY), radius: radius)
            } else {
                path.addLine(to: point(x, y))
            }
        }
        path.move(to: point(radius, 0))
        tail(0, from: point(x1, 0), to: point(x2, 0))
        path.addLine(to: point(w - radius, 0))
        turn(w, 0, w, radius)
        tail(1, from: point(w, y1), to: point(w, y2))
        path.addLine(to: point(w, h - radius))
        turn(w, h, w - radius, h)
        tail(2, from: point(x2, h), to: point(x1, h))
        path.addLine(to: point(radius, h))
        turn(0, h, 0, h - radius)
        tail(3, from: point(0, y2), to: point(0, y1))
        path.addLine(to: point(0, radius))
        turn(0, 0, radius, 0)
        path.closeSubpath()
    }

    /// An adjust value pinned to the range the preset allows, as a fraction.
    private static func pinned(_ adjustments: [String: Int], _ key: String, _ fallback: Int, _ low: Int, _ high: Int) -> CGFloat {
        CGFloat(min(max(adjustments[key] ?? fallback, low), high)) / 100_000
    }

    /// A banner with one (`wave`) or two (`doubleWave`) S-curves along its top
    /// and bottom. `adj1` is the curves' depth and `adj2` skews the bottom
    /// edge against the top, as ECMA-376 defines them.
    private static func wave(_ name: String, adjustments: [String: Int], in rect: CGRect) -> (outline: CGPath, text: CGRect) {
        let w = rect.width
        let h = rect.height
        let isDouble = name == "doubleWave"
        let depth = pinned(adjustments, "adj1", isDouble ? 6_250 : 12_500, 0, isDouble ? 12_500 : 20_000)
        let skew = pinned(adjustments, "adj2", 0, -10_000, 10_000)
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: rect.minX + px, y: rect.minY + py) }
        let y1 = h * depth
        let swing = y1 * 10 / 3
        let y4 = h - y1
        // A positive skew pulls the top edge's right end and the bottom
        // edge's left end in; a negative one the other two ends.
        let offset = w * skew * 2
        let topLeft = offset > 0 ? 0 : -offset
        let topRight = w - max(offset, 0)
        let bottomLeft = max(offset, 0)
        let bottomRight = w + min(offset, 0)
        let waves = isDouble ? 2 : 1
        let length = (topRight - topLeft) / CGFloat(waves)

        let path = CGMutablePath()
        path.move(to: point(topLeft, y1))
        for index in 0..<waves {
            let start = topLeft + length * CGFloat(index)
            path.addCurve(to: point(start + length, y1),
                          control1: point(start + length / 3, y1 - swing),
                          control2: point(start + length * 2 / 3, y1 + swing))
        }
        path.addLine(to: point(bottomRight, y4))
        for index in 0..<waves {
            let start = bottomRight - length * CGFloat(index)
            path.addCurve(to: point(start - length, y4),
                          control1: point(start - length / 3, y4 + swing),
                          control2: point(start - length * 2 / 3, y4 - swing))
        }
        path.closeSubpath()

        let left = max(topLeft, bottomLeft)
        let right = min(topRight, bottomRight)
        let text = CGRect(x: rect.minX + left, y: rect.minY + 2 * y1,
                          width: max(right - left, 1), height: max(h - 4 * y1, 1))
        return (path, text)
    }

    /// A ribbon whose band sags in a parabola, its ends folded behind it.
    /// `adj1` is the band's height, `adj2` the front panel's width and `adj3`
    /// the sag; the folds are lines drawn over the fill, as ECMA-376 defines them.
    private static func ellipseRibbon(adjustments: [String: Int], in rect: CGRect) -> (outline: CGPath, folds: CGPath, text: CGRect) {
        let w = rect.width
        let h = rect.height
        let a1 = pinned(adjustments, "adj1", 25_000, 0, 100_000)
        let a2 = pinned(adjustments, "adj2", 50_000, 25_000, 75_000)
        let a3 = min(max(CGFloat(adjustments["adj3"] ?? 12_500) / 100_000, max(0, a1 - (1 - a1) / 2)), a1)
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: rect.minX + px, y: rect.minY + py) }
        let x2 = w / 2 - w * a2 / 2
        let x3 = x2 + w / 8
        let x4 = w - x3
        let x5 = w - x2
        let x6 = w - w / 8
        let dy1 = h * a3
        // The sag along the band: 0 at the ends, dy1 in the middle.
        let f1 = w > 0 ? 4 * dy1 / w : 0
        let y1 = f1 * (x3 - x3 * x3 / max(w, 1))
        let cx1 = x3 / 2
        let cy1 = f1 * cx1
        let cx2 = w - cx1
        let band = h * a1
        let dy3 = band - dy1
        let q5 = f1 * (x2 - x2 * x2 / max(w, 1))
        let y3 = q5 + dy3
        let cy3 = (dy1 + dy3 - y3) + dy1 + dy3
        let rh = h - band
        let y2 = (dy1 * 14 / 16 + rh) / 2
        let y5 = q5 + rh
        let y6 = y3 + rh
        let cx4 = x2 / 2
        let cy4 = f1 * cx4 + rh
        let cx5 = w - cx4
        let cy6 = cy3 + rh
        let y7 = y1 + dy3

        let outline = CGMutablePath()
        outline.move(to: point(0, 0))
        outline.addQuadCurve(to: point(x3, y1), control: point(cx1, cy1))
        outline.addLine(to: point(x2, y3))
        outline.addQuadCurve(to: point(x5, y3), control: point(w / 2, cy3))
        outline.addLine(to: point(x4, y1))
        outline.addQuadCurve(to: point(w, 0), control: point(cx2, cy1))
        outline.addLine(to: point(x6, y2))
        outline.addLine(to: point(w, rh))
        outline.addQuadCurve(to: point(x5, y5), control: point(cx5, cy4))
        outline.addLine(to: point(x5, y6))
        outline.addQuadCurve(to: point(x2, y6), control: point(w / 2, cy6))
        outline.addLine(to: point(x2, y5))
        outline.addQuadCurve(to: point(0, rh), control: point(cx4, cy4))
        outline.addLine(to: point(w / 8, y2))
        outline.closeSubpath()

        let folds = CGMutablePath()
        for (from, to) in [((x2, y5), (x2, y3)), ((x5, y3), (x5, y5)), ((x3, y1), (x3, y7)), ((x4, y7), (x4, y1))] {
            folds.move(to: point(from.0, from.1))
            folds.addLine(to: point(to.0, to.1))
        }
        let text = CGRect(x: rect.minX + x2, y: rect.minY + band, width: max(x5 - x2, 1), height: max(y6 - band, 1))
        return (outline, folds, text)
    }

    /// ECMA-376's cloud: eleven elliptical arcs in a 43200-unit square.
    private static let cloudStart = CGPoint(x: 3_900, y: 14_370)
    private static let cloudArcs: [(wR: CGFloat, hR: CGFloat, start: CGFloat, sweep: CGFloat)] = [
        (6_753, 9_190, -11_429_249, 7_426_832), (5_333, 7_267, -8_646_143, 5_396_714),
        (4_365, 5_945, -8_748_475, 5_983_381), (4_857, 6_595, -7_859_164, 7_034_504),
        (5_333, 7_273, -4_722_533, 6_541_615), (6_775, 9_220, -2_776_035, 7_816_140),
        (5_785, 7_867, 37_501, 6_842_000), (6_752, 9_215, 1_347_096, 6_910_353),
        (7_720, 10_543, 3_974_558, 4_542_661), (4_360, 5_918, -16_496_525, 8_804_134),
        (4_345, 5_945, -14_809_710, 9_151_131),
    ]

    /// The inner curves where the cloud's puffs overlap, in the same space.
    private static let cloudPuffs: [(x: CGFloat, y: CGFloat, wR: CGFloat, hR: CGFloat, start: CGFloat, sweep: CGFloat)] = [
        (4_693, 26_177, 4_345, 5_945, 5_204_520, 1_585_770), (6_928, 34_899, 4_360, 5_918, 4_416_628, 686_848),
        (16_478, 39_090, 6_752, 9_215, 8_257_449, 844_866), (28_827, 34_751, 6_752, 9_215, 387_196, 959_901),
        (34_129, 22_954, 5_785, 7_867, -4_217_541, 4_255_042), (41_798, 15_354, 5_333, 7_273, 1_819_082, 1_665_090),
        (38_324, 5_426, 4_857, 6_595, -824_660, 891_534), (29_078, 3_952, 4_857, 6_595, -8_950_887, 1_091_722),
        (22_141, 4_720, 4_365, 5_945, -9_809_656, 1_061_181), (14_000, 5_192, 6_753, 9_190, -4_002_417, 739_161),
        (4_127, 15_789, 6_753, 9_190, 9_459_261, 711_490),
    ]

    private static func cloud(in rect: CGRect) -> CGMutablePath {
        let path = CGMutablePath()
        let scale = CGSize(width: rect.width / 43_200, height: rect.height / 43_200)
        var current = CGPoint(x: rect.minX + cloudStart.x * scale.width, y: rect.minY + cloudStart.y * scale.height)
        path.move(to: current)
        for arc in cloudArcs {
            current = arcTo(path, from: current, wR: arc.wR, hR: arc.hR, start: arc.start, sweep: arc.sweep, scale: scale)
        }
        path.closeSubpath()
        return path
    }

    /// The cloud with three bubbles trailing to the point `adj1`/`adj2`
    /// (offsets from the centre, as fractions of the size) names.
    private static func cloudCallout(adjustments: [String: Int], in rect: CGRect) -> CGPath {
        let w = rect.width
        let h = rect.height
        let ss = min(w, h)
        let dx = w * CGFloat(adjustments["adj1"] ?? -20_833) / 100_000
        let dy = h * CGFloat(adjustments["adj2"] ?? 62_500) / 100_000
        let tip = CGPoint(x: rect.midX + dx, y: rect.midY + dy)
        // Where the line from the centre towards the tip leaves the ellipse.
        let toward = atan2(dy, dx)
        let ht = h / 2 * cos(toward)
        let wt = w / 2 * sin(toward)
        let edgeAngle = atan2(wt, ht)
        let edge = CGPoint(x: rect.midX + w / 2 * cos(edgeAngle), y: rect.midY + h / 2 * sin(edgeAngle))
        let gap = CGPoint(x: edge.x - tip.x, y: edge.y - tip.y)
        let distance = hypot(gap.x, gap.y)
        let unit = distance > 0 ? CGPoint(x: gap.x / distance, y: gap.y / distance) : .zero
        let third = (distance - ss * 6_600 / 21_600) / 3
        let bubbles: [(offset: CGFloat, radius: CGFloat)] = [
            (0, ss * 600 / 21_600),
            (third + ss * 1_800 / 21_600, ss * 1_200 / 21_600),
            (ss * 4_800 / 21_600 + 2 * third, ss * 1_800 / 21_600),
        ]
        let trail = CGMutablePath()
        for bubble in bubbles {
            let centre = CGPoint(x: tip.x + unit.x * bubble.offset, y: tip.y + unit.y * bubble.offset)
            trail.addEllipse(in: CGRect(x: centre.x - bubble.radius, y: centre.y - bubble.radius,
                                        width: bubble.radius * 2, height: bubble.radius * 2))
        }
        let body = cloud(in: rect)
        #if canImport(CoreGraphics)
        // Bubbles overlapping the cloud would cut holes in an even-odd fill.
        return body.union(trail, using: .winding)
        #else
        body.addPath(trail)
        return body
        #endif
    }

    /// DrawingML's `arcTo`, in a path space `scale` maps to points. Its
    /// angles (60000ths of a degree) are where the radius points, not the
    /// ellipse's parameter, so they are converted before drawing.
    @discardableResult
    static func arcTo(
        _ path: CGMutablePath, from current: CGPoint, wR: CGFloat, hR: CGFloat, start: CGFloat, sweep: CGFloat, scale: CGSize
    ) -> CGPoint {
        let fullTurn = 2 * CGFloat.pi
        let startAngle = start / 60_000 * .pi / 180
        let sweepAngle = sweep / 60_000 * .pi / 180
        func parameter(_ angle: CGFloat) -> CGFloat { atan2(wR * sin(angle), hR * cos(angle)) }
        let turns = (abs(sweepAngle) / fullTurn).rounded(.down)
        let rest = abs(sweepAngle) - turns * fullTurn
        var delta: CGFloat = 0
        if rest > 0.000_001 {
            delta = parameter(startAngle + (sweepAngle < 0 ? -rest : rest)) - parameter(startAngle)
            delta = delta.truncatingRemainder(dividingBy: fullTurn)
            if sweepAngle > 0, delta < 0 { delta += fullTurn }
            if sweepAngle < 0, delta > 0 { delta -= fullTurn }
        }
        delta += (sweepAngle < 0 ? -turns : turns) * fullTurn
        let t0 = parameter(startAngle)
        let t1 = t0 + delta
        let rx = max(wR * scale.width, 0.001)
        let ry = max(hR * scale.height, 0.001)
        let centre = CGPoint(x: current.x - rx * cos(t0), y: current.y - ry * sin(t0))
        let transform = CGAffineTransform(translationX: centre.x, y: centre.y).scaledBy(x: rx, y: ry)
        path.addArc(center: .zero, radius: 1, startAngle: t0, endAngle: t1, clockwise: delta < 0, transform: transform)
        return CGPoint(x: centre.x + rx * cos(t1), y: centre.y + ry * sin(t1))
    }

    private static func regularPolygon(sides: Int, in rect: CGRect) -> [CGPoint] {
        (0..<sides).map { index in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
        }
    }

    private static func star(points: Int, innerRatio: CGFloat, in rect: CGRect) -> [CGPoint] {
        (0..<(points * 2)).map { index in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / CGFloat(points)
            let scale = index.isMultiple(of: 2) ? 1 : innerRatio
            return CGPoint(
                x: rect.midX + rect.width / 2 * scale * cos(angle),
                y: rect.midY + rect.height / 2 * scale * sin(angle)
            )
        }
    }

    /// Block arrows, drawn pointing right and turned to face their way.
    private static func arrow(_ name: String, path: CGMutablePath, rect: CGRect, shaft: CGFloat, head: CGFloat) {
        let isVertical = name == "upArrow" || name == "downArrow"
        // Lay the arrow out along its own length.
        let length = isVertical ? rect.height : rect.width
        let breadth = isVertical ? rect.width : rect.height
        let headLength = min(min(length, breadth) * head, length)
        let shaftInset = breadth * (1 - shaft) / 2
        var points: [CGPoint]
        if name == "leftRightArrow" {
            points = [
                CGPoint(x: 0, y: breadth / 2), CGPoint(x: headLength, y: 0), CGPoint(x: headLength, y: shaftInset),
                CGPoint(x: length - headLength, y: shaftInset), CGPoint(x: length - headLength, y: 0),
                CGPoint(x: length, y: breadth / 2), CGPoint(x: length - headLength, y: breadth),
                CGPoint(x: length - headLength, y: breadth - shaftInset), CGPoint(x: headLength, y: breadth - shaftInset),
                CGPoint(x: headLength, y: breadth),
            ]
        } else {
            points = [
                CGPoint(x: 0, y: shaftInset), CGPoint(x: length - headLength, y: shaftInset),
                CGPoint(x: length - headLength, y: 0), CGPoint(x: length, y: breadth / 2),
                CGPoint(x: length - headLength, y: breadth), CGPoint(x: length - headLength, y: breadth - shaftInset),
                CGPoint(x: 0, y: breadth - shaftInset),
            ]
        }
        points = points.map { local in
            switch name {
            case "leftArrow": CGPoint(x: rect.maxX - local.x, y: rect.minY + local.y)
            case "downArrow": CGPoint(x: rect.minX + local.y, y: rect.minY + local.x)
            case "upArrow": CGPoint(x: rect.minX + local.y, y: rect.maxY - local.x)
            default: CGPoint(x: rect.minX + local.x, y: rect.minY + local.y)
            }
        }
        path.addLines(between: points)
        path.closeSubpath()
    }

    /// A freeform outline, scaled from its own coordinate space to `rect`.
    public static func path(_ paths: [ShapeGeometry.CustomPath], in rect: CGRect) -> (fill: CGPath, stroke: CGPath) {
        let fill = CGMutablePath()
        let stroke = CGMutablePath()
        for custom in paths {
            let scaleX = custom.width > 0 ? rect.width / custom.width : 1
            let scaleY = custom.height > 0 ? rect.height / custom.height : 1
            let path = CGMutablePath()
            var current = CGPoint.zero
            func map(_ px: Double, _ py: Double) -> CGPoint {
                CGPoint(x: rect.minX + px * scaleX, y: rect.minY + py * scaleY)
            }
            for command in custom.commands {
                switch command {
                case .move(let px, let py):
                    current = map(px, py)
                    path.move(to: current)
                case .line(let px, let py):
                    current = map(px, py)
                    path.addLine(to: current)
                case .cubic(let x1, let y1, let x2, let y2, let x3, let y3):
                    current = map(x3, y3)
                    path.addCurve(to: current, control1: map(x1, y1), control2: map(x2, y2))
                case .quadratic(let x1, let y1, let x2, let y2):
                    current = map(x2, y2)
                    path.addQuadCurve(to: current, control: map(x1, y1))
                case .arc(let widthRadius, let heightRadius, let start, let sweep):
                    let rx = widthRadius * scaleX
                    let ry = heightRadius * scaleY
                    let startRadians = start * .pi / 180
                    let endRadians = (start + sweep) * .pi / 180
                    let center = CGPoint(x: current.x - rx * cos(startRadians), y: current.y - ry * sin(startRadians))
                    let transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: max(rx, 0.001), y: max(ry, 0.001))
                    if path.isEmpty { path.move(to: current) }
                    path.addArc(
                        center: .zero, radius: 1, startAngle: startRadians, endAngle: endRadians,
                        clockwise: sweep < 0, transform: transform
                    )
                    current = CGPoint(x: center.x + rx * cos(endRadians), y: center.y + ry * sin(endRadians))
                case .close:
                    path.closeSubpath()
                }
            }
            if custom.isFilled { fill.addPath(path) }
            if custom.isStroked { stroke.addPath(path) }
        }
        return (fill, stroke)
    }
}
