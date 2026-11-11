import CoreGraphics
@testable import DazzleEngine
import Testing

@Suite("Speech bubble geometry")
struct PresetGeometryTests {
    private let presets = ["wedgeRectCallout", "wedgeRoundRectCallout", "wedgeEllipseCallout"]
    private let rect = CGRect(x: 10, y: 20, width: 208, height: 150)

    @Test("Tails preserve the body fill and never stroke through its text")
    func bodyAndTail() {
        let positions = [
            [-20_833, 62_500], [50_000, 75_000], [80_000, 10_000],
            [-80_000, 10_000], [10_000, -80_000], [0, 0],
        ]
        for preset in presets {
            for position in positions {
                let path = PresetGeometry.path(preset, adjustments: ["adj1": position[0], "adj2": position[1]], in: rect)
                let stroke = path.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
                // All samples lie inside the inscribed text area, including
                // the region removed by the old overlapping triangle.
                for x in stride(from: 0.25, through: 0.75, by: 0.05) {
                    for y in stride(from: 0.25, through: 0.75, by: 0.05) {
                        let point = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
                        #expect(path.contains(point, using: .evenOdd), "\(preset), \(position), \(point)")
                        #expect(!stroke.contains(point), "\(preset), \(position), \(point)")
                    }
                }
                if position != [0, 0] {
                    let tip = CGPoint(x: rect.midX + rect.width * CGFloat(position[0]) / 100_000,
                                      y: rect.midY + rect.height * CGFloat(position[1]) / 100_000)
                    let attachment: CGPoint
                    if preset == "wedgeEllipseCallout" {
                        let angle = atan2(CGFloat(position[1]), CGFloat(position[0]))
                        attachment = CGPoint(x: rect.midX + rect.width / 2 * cos(angle),
                                             y: rect.midY + rect.height / 2 * sin(angle))
                    } else if abs(position[1]) > abs(position[0]) {
                        attachment = CGPoint(x: rect.minX + rect.width * (position[0] > 0 ? 17 : 7) / 24,
                                             y: position[1] > 0 ? rect.maxY : rect.minY)
                    } else {
                        attachment = CGPoint(x: position[0] > 0 ? rect.maxX : rect.minX,
                                             y: rect.minY + rect.height * (position[1] > 0 ? 17 : 7) / 24)
                    }
                    let nearTip = CGPoint(x: tip.x * 0.99 + attachment.x * 0.01,
                                          y: tip.y * 0.99 + attachment.y * 0.01)
                    #expect(path.contains(nearTip, using: .evenOdd), "\(preset), \(position)")
                }
            }
        }
    }

    @Test("Rounded bubbles honor the corner adjustment")
    func cornerAdjustment() {
        let square = PresetGeometry.path("wedgeRoundRectCallout", adjustments: ["adj3": 0], in: rect)
        let rounded = PresetGeometry.path("wedgeRoundRectCallout", adjustments: ["adj3": 30_000], in: rect)
        let cornerPoint = CGPoint(x: rect.minX + 1, y: rect.minY + 1)
        #expect(square.contains(cornerPoint, using: .evenOdd))
        #expect(!rounded.contains(cornerPoint, using: .evenOdd))
        let text = PresetGeometry.textRect("wedgeRoundRectCallout", adjustments: ["adj3": 30_000], in: rect)
        #expect(text.minX > rect.minX)
        #expect(text.maxY < rect.maxY)
    }
}

@Suite("Banner and cloud geometry")
struct BannerGeometryTests {
    private let rect = CGRect(x: 10, y: 20, width: 400, height: 200)

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }

    @Test("Waves follow their S-curves rather than an ellipse")
    func waves() {
        let wave = PresetGeometry.path("wave", adjustments: [:], in: rect)
        #expect(wave.contains(point(0.01, 0.5), using: .evenOdd))
        #expect(wave.contains(point(0.25, 0.05), using: .evenOdd))
        #expect(!wave.contains(point(0.75, 0.2), using: .evenOdd))
        #expect(wave.contains(point(0.75, 0.95), using: .evenOdd))
        #expect(!wave.contains(point(0.25, 0.8), using: .evenOdd))

        let double = PresetGeometry.path("doubleWave", adjustments: [:], in: rect)
        #expect(double.contains(point(0.125, 0.03), using: .evenOdd))
        #expect(!double.contains(point(0.375, 0.1), using: .evenOdd))
        #expect(double.contains(point(0.625, 0.03), using: .evenOdd))
        #expect(double.contains(point(0.01, 0.5), using: .evenOdd))
    }

    @Test("Wave adjustments set the depth and skew, and the text sits between the curves")
    func waveAdjustments() {
        let text = PresetGeometry.textRect("wave", adjustments: [:], in: rect)
        #expect(abs(text.minY - point(0, 0.25).y) < 0.01)
        #expect(abs(text.maxY - point(0, 0.75).y) < 0.01)
        #expect(text.minX == rect.minX && text.maxX == rect.maxX)

        let flat = PresetGeometry.path("wave", adjustments: ["adj1": 0], in: rect)
        #expect(flat.contains(point(0.75, 0.02), using: .evenOdd))

        // A positive skew pulls in the top's right end and the bottom's left end.
        let skewed = PresetGeometry.path("wave", adjustments: ["adj2": 10_000], in: rect)
        #expect(!skewed.contains(point(0.99, 0.15), using: .evenOdd))
        #expect(!skewed.contains(point(0.01, 0.85), using: .evenOdd))
        let skewedText = PresetGeometry.textRect("wave", adjustments: ["adj2": 10_000], in: rect)
        #expect(abs(skewedText.minX - point(0.2, 0).x) < 0.01)
        #expect(abs(skewedText.maxX - point(0.8, 0).x) < 0.01)
    }

    @Test("The ellipse ribbon has a sagging band, folded ends and notched tails")
    func ellipseRibbon() {
        let ribbon = PresetGeometry.path("ellipseRibbon", adjustments: [:], in: rect)
        #expect(ribbon.contains(point(0.5, 0.5), using: .evenOdd))
        #expect(ribbon.contains(point(3.0 / 400, 3.0 / 200), using: .evenOdd))
        #expect(ribbon.contains(point(0.1, 0.2), using: .evenOdd))
        // Above the front panel and inside the left tail's notch.
        #expect(!ribbon.contains(point(0.5, 0.15), using: .evenOdd))
        #expect(!ribbon.contains(point(0.02, 0.5), using: .evenOdd))

        let text = PresetGeometry.textRect("ellipseRibbon", adjustments: [:], in: rect)
        #expect(abs(text.minX - point(0.25, 0).x) < 0.01)
        #expect(abs(text.maxX - point(0.75, 0).x) < 0.01)
        #expect(abs(text.minY - point(0, 0.25).y) < 0.01)
        #expect(abs(text.maxY - (rect.minY + 193.75)) < 0.01)

        // A narrower front panel leaves the tail, which stops higher, under this point.
        #expect(ribbon.contains(point(0.3, 0.9), using: .evenOdd))
        let narrow = PresetGeometry.path("ellipseRibbon", adjustments: ["adj2": 25_000], in: rect)
        #expect(!narrow.contains(point(0.3, 0.9), using: .evenOdd))
        #expect(narrow.contains(point(0.5, 0.5), using: .evenOdd))
    }

    @Test("The cloud is drawn from its puffs, with ECMA-376's text box")
    func cloud() {
        let cloud = PresetGeometry.path("cloud", adjustments: [:], in: rect)
        // The puffs reach the frame's edges, and dip in between them.
        let bounds = cloud.boundingBoxOfPath
        #expect(abs(bounds.minX - rect.minX) < rect.width * 0.01 && abs(bounds.maxX - rect.maxX) < rect.width * 0.01)
        #expect(abs(bounds.minY - rect.minY) < rect.height * 0.01 && abs(bounds.maxY - rect.maxY) < rect.height * 0.01)
        #expect(!cloud.contains(point(0.07, 0.333), using: .evenOdd))
        #expect(!cloud.contains(point(0.5, 0.02), using: .evenOdd))
        #expect(cloud.contains(point(0.2, 0.12), using: .evenOdd))
        #expect(cloud.contains(point(0.5, 0.5), using: .evenOdd))
        #expect(!cloud.contains(point(0.03, 0.03), using: .evenOdd))

        let text = PresetGeometry.textRect("cloudCallout", adjustments: [:], in: rect)
        #expect(abs(text.minX - point(2_977.0 / 21_600, 0).x) < 0.01)
        #expect(abs(text.maxY - point(0, 17_337.0 / 21_600).y) < 0.01)
    }

    @Test("Cloud callout bubbles trail to the adjust point without cutting holes in the cloud")
    func cloudCallout() {
        let cloud = PresetGeometry.path("cloud", adjustments: [:], in: rect)
        for position in [[-20_833, 62_500], [70_000, -60_000], [-10_000, 40_000], [0, 0]] {
            let callout = PresetGeometry.path(
                "cloudCallout", adjustments: ["adj1": position[0], "adj2": position[1]], in: rect
            )
            let tip = point(0.5 + CGFloat(position[0]) / 100_000, 0.5 + CGFloat(position[1]) / 100_000)
            #expect(callout.contains(tip, using: .evenOdd), "\(position)")
            for x in stride(from: 0.0, through: 1.0, by: 0.02) {
                for y in stride(from: 0.0, through: 1.0, by: 0.02) where cloud.contains(point(x, y), using: .evenOdd) {
                    #expect(callout.contains(point(x, y), using: .evenOdd), "\(position), \(x), \(y)")
                }
            }
        }
        let callout = PresetGeometry.path("cloudCallout", adjustments: [:], in: rect)
        #expect(!callout.contains(point(0.8, 1.1), using: .evenOdd))
    }

    @Test("Ribbon folds and cloud puffs are stroked over the fill, inside the outline")
    func detailLines() {
        #expect(PresetGeometry.detailPath("wave", adjustments: [:], in: rect) == nil)
        for preset in ["ellipseRibbon", "cloud", "cloudCallout"] {
            let outline = PresetGeometry.path(preset, adjustments: [:], in: rect)
            let details = PresetGeometry.detailPath(preset, adjustments: [:], in: rect)
            #expect(details != nil && !details!.isEmpty, "\(preset)")
            guard let details else { continue }
            let bounds = details.boundingBoxOfPath
            #expect(outline.boundingBoxOfPath.insetBy(dx: -1, dy: -1).contains(bounds), "\(preset)")
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            #expect(outline.contains(centre, using: .evenOdd), "\(preset)")
        }
        // The ribbon's folds drop straight down at the front panel's edges.
        let folds = PresetGeometry.detailPath("ellipseRibbon", adjustments: [:], in: rect)!
        let stroked = folds.copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        #expect(stroked.contains(point(0.25, 0.5)))
        #expect(stroked.contains(point(0.75, 0.5)))
        #expect(!stroked.contains(point(0.5, 0.5)))
    }
}
