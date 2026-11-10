import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Compound lines, caps and joins")
struct CompoundLineTests {
    private func line(_ xml: String) throws -> LineStyle {
        LineStyle(element: try XMLLite.parse(Data(xml.utf8)))
    }

    @Test("a:ln reads its compound, cap and join")
    func reads() throws {
        let double = try line(#"<ln w="38100" cmpd="dbl" cap="rnd"><solidFill><srgbClr val="FF0000"/></solidFill><bevel/></ln>"#)
        #expect(double.compound == "dbl")
        #expect(double.cap == "rnd")
        #expect(double.join == .bevel)
        #expect(try line(#"<ln><miter lim="800000"/></ln>"#).join == .miter(limit: 800_000))
        #expect(try line(#"<ln><miter/></ln>"#).join == .miter(limit: nil))
        #expect(try line(#"<ln><round/></ln>"#).join == .round)
        let plain = try line("<ln/>")
        #expect(plain.compound == nil && plain.cap == nil && plain.join == nil)
    }

    @Test("Unsaid compound, cap and join come from the style beneath")
    func inherits() {
        let theme = LineStyle(width: 9_525, compound: "thickThin", cap: "sq", join: .miter(limit: 500_000))
        let merged = LineStyle(cap: "flat").merged(over: theme)
        #expect(merged.compound == "thickThin")
        #expect(merged.cap == "flat")
        #expect(merged.join == .miter(limit: 500_000))
    }

    @Test("Compound lines split the width into strokes and gaps")
    func bands() {
        func bands(_ compound: String?) -> [[Double]] {
            LineStyle(compound: compound).compoundBands.map { [$0.start, $0.end] }
        }
        let whole: [[Double]] = [[0, 1]]
        let double: [[Double]] = [[0, 1.0 / 3], [2.0 / 3, 1]]
        let thickThin: [[Double]] = [[0, 0.5], [0.75, 1]]
        let thinThick: [[Double]] = [[0, 0.25], [0.5, 1]]
        let triple: [[Double]] = [[0, 1.0 / 6], [2.0 / 6, 4.0 / 6], [5.0 / 6, 1]]
        #expect(bands(nil) == whole)
        #expect(bands("sng") == whole)
        #expect(bands("dbl") == double)
        #expect(bands("thickThin") == thickThin)
        #expect(bands("thinThick") == thinThick)
        #expect(bands("tri") == triple)
    }
}
