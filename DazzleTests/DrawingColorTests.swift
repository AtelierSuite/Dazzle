import CoreGraphics
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Preset colours")
struct DrawingColorTests {
    private func preset(_ name: String) throws -> DrawingColor {
        let element = try XMLLite.parse(Data("<a:prstClr val=\"\(name)\"/>".utf8))
        guard let color = DrawingColor(element: element) else {
            throw DrawingColorTestError.unparsed
        }
        return color
    }

    private enum DrawingColorTestError: Error { case unparsed }

    private func expect(_ name: String, _ hex: UInt32) throws {
        let color = try preset(name)
        guard case .rgb(let value) = color.base else {
            Issue.record("\(name) did not resolve to an rgb value")
            return
        }
        #expect(value == hex, "\(name) should be \(String(hex, radix: 16)), got \(String(value, radix: 16))")
    }

    @Test("Names beyond the original handful resolve to their real colour, not black")
    func namedColoursBeyondTheOriginal18() throws {
        try expect("coral", 0xFF7F50)
        try expect("cornflowerBlue", 0x6495ED)
        try expect("darkSlateGray", 0x2F4F4F)
        try expect("mediumTurquoise", 0x48D1CC)
        try expect("paleVioletRed", 0xDB7093)
        try expect("yellowGreen", 0x9ACD32)
        try expect("peachPuff", 0xFFDAB9)
        try expect("lavenderBlush", 0xFFF0F5)
        try expect("aliceBlue", 0xF0F8FF)
        try expect("midnightBlue", 0x191970)
        try expect("seaGreen", 0x2E8B57)
        try expect("sandyBrown", 0xF4A460)
    }

    @Test("Grey-spelled variants resolve like their gray twins")
    func greySpelledVariants() throws {
        try expect("grey", 0x808080)
        try expect("darkGrey", 0xA9A9A9)
        try expect("lightGrey", 0xD3D3D3)
        try expect("dimGrey", 0x696969)
        try expect("slateGrey", 0x708090)
        try expect("darkSlateGrey", 0x2F4F4F)
        try expect("lightSlateGrey", 0x778899)
        try expect("lightSteelGrey", 0xB0C4DE)
    }

    @Test("Theme slots named by prstClr resolve to the default Office theme")
    func themeSlots() throws {
        try expect("dk1", 0x000000)
        try expect("lt1", 0xFFFFFF)
        try expect("dk2", 0x44546A)
        try expect("lt2", 0xE7E6E6)
        try expect("accent1", 0x4472C4)
        try expect("accent2", 0xED7D31)
        try expect("accent3", 0xA5A5A5)
        try expect("accent4", 0xFFC000)
        try expect("accent5", 0x5B9BD5)
        try expect("accent6", 0x70AD47)
        try expect("hlink", 0x0563C1)
        try expect("folHlink", 0x954F72)
    }

    @Test("The names that already worked keep their values")
    func originalNamesUnchanged() throws {
        try expect("black", 0x000000)
        try expect("white", 0xFFFFFF)
        try expect("red", 0xFF0000)
        try expect("green", 0x008000)
        try expect("blue", 0x0000FF)
        try expect("yellow", 0xFFFF00)
        try expect("orange", 0xFFA500)
        try expect("purple", 0x800080)
        try expect("gray", 0x808080)
        try expect("darkGray", 0xA9A9A9)
        try expect("lightGray", 0xD3D3D3)
        try expect("cyan", 0x00FFFF)
        try expect("magenta", 0xFF00FF)
        try expect("navy", 0x000080)
        try expect("maroon", 0x800000)
        try expect("teal", 0x008080)
        try expect("silver", 0xC0C0C0)
    }

    @Test("An unknown name still falls back to black")
    func unknownNameFallsBackToBlack() throws {
        try expect("notARealColour", 0x000000)
    }

    @Test("A named preset colour is saved as its colour, not as black")
    func namedColourRoundTripsAsSRGB() throws {
        let coral = try preset("coral")
        #expect(coral.xml == "<a:srgbClr val=\"FF7F50\"/>")
        let accent5 = try preset("accent5")
        #expect(accent5.xml == "<a:srgbClr val=\"5B9BD5\"/>")
    }

    @Test("Every preset name in the table resolves to its ECMA-376 value",
        arguments: [
        ("phClr", 0x000000),
        ("dk1", 0x000000),
        ("lt1", 0xFFFFFF),
        ("dk2", 0x44546A),
        ("lt2", 0xE7E6E6),
        ("accent1", 0x4472C4),
        ("accent2", 0xED7D31),
        ("accent3", 0xA5A5A5),
        ("accent4", 0xFFC000),
        ("accent5", 0x5B9BD5),
        ("accent6", 0x70AD47),
        ("hlink", 0x0563C1),
        ("folHlink", 0x954F72),
        ("aliceBlue", 0xF0F8FF),
        ("antiqueWhite", 0xFAEBD7),
        ("aqua", 0x00FFFF),
        ("aquamarine", 0x7FFFD4),
        ("azure", 0xF0FFFF),
        ("beige", 0xF5F5DC),
        ("bisque", 0xFFE4C4),
        ("black", 0x000000),
        ("blanchedAlmond", 0xFFEBCD),
        ("blue", 0x0000FF),
        ("blueViolet", 0x8A2BE2),
        ("brown", 0xA52A2A),
        ("burlyWood", 0xDEB887),
        ("cadetBlue", 0x5F9EA0),
        ("chartreuse", 0x7FFF00),
        ("chocolate", 0xD2691E),
        ("coral", 0xFF7F50),
        ("cornflowerBlue", 0x6495ED),
        ("cornsilk", 0xFFF8DC),
        ("crimson", 0xDC143C),
        ("cyan", 0x00FFFF),
        ("darkBlue", 0x00008B),
        ("darkCyan", 0x008B8B),
        ("darkGoldenrod", 0xB8860B),
        ("darkGray", 0xA9A9A9),
        ("darkGreen", 0x006400),
        ("darkKhaki", 0xBDB76B),
        ("darkMagenta", 0x8B008B),
        ("darkOliveGreen", 0x556B2F),
        ("darkOrange", 0xFF8C00),
        ("darkOrchid", 0x9932CC),
        ("darkRed", 0x8B0000),
        ("darkSalmon", 0xE9967A),
        ("darkSeaGreen", 0x8FBC8F),
        ("darkSlateBlue", 0x483D8B),
        ("darkSlateGray", 0x2F4F4F),
        ("darkTurquoise", 0x00CED1),
        ("darkViolet", 0x9400D3),
        ("deepPink", 0xFF1493),
        ("deepSkyBlue", 0x00BFFF),
        ("dimGray", 0x696969),
        ("dodgerBlue", 0x1E90FF),
        ("firebrick", 0xB22222),
        ("floralWhite", 0xFFFAF0),
        ("forestGreen", 0x228B22),
        ("fuchsia", 0xFF00FF),
        ("gainsboro", 0xDCDCDC),
        ("ghostWhite", 0xF8F8FF),
        ("gold", 0xFFD700),
        ("goldenrod", 0xDAA520),
        ("gray", 0x808080),
        ("green", 0x008000),
        ("greenYellow", 0xADFF2F),
        ("honeydew", 0xF0FFF0),
        ("hotPink", 0xFF69B4),
        ("indianRed", 0xCD5C5C),
        ("indigo", 0x4B0082),
        ("ivory", 0xFFFFF0),
        ("khaki", 0xF0E68C),
        ("lavender", 0xE6E6FA),
        ("lavenderBlush", 0xFFF0F5),
        ("lawnGreen", 0x7CFC00),
        ("lemonChiffon", 0xFFFACD),
        ("lightBlue", 0xADD8E6),
        ("lightCoral", 0xF08080),
        ("lightCyan", 0xE0FFFF),
        ("lightGoldenrodYellow", 0xFAFAD2),
        ("lightGray", 0xD3D3D3),
        ("lightGreen", 0x90EE90),
        ("lightPink", 0xFFB6C1),
        ("lightSalmon", 0xFFA07A),
        ("lightSeaGreen", 0x20B2AA),
        ("lightSkyBlue", 0x87CEFA),
        ("lightSlateGray", 0x778899),
        ("lightSteelBlue", 0xB0C4DE),
        ("lightYellow", 0xFFFFE0),
        ("lime", 0x00FF00),
        ("limeGreen", 0x32CD32),
        ("linen", 0xFAF0E6),
        ("magenta", 0xFF00FF),
        ("maroon", 0x800000),
        ("mediumAquamarine", 0x66CDAA),
        ("mediumBlue", 0x0000CD),
        ("mediumOrchid", 0xBA55D3),
        ("mediumPurple", 0x9370DB),
        ("mediumSeaGreen", 0x3CB371),
        ("mediumSlateBlue", 0x7B68EE),
        ("mediumSpringGreen", 0x00FA9A),
        ("mediumTurquoise", 0x48D1CC),
        ("mediumVioletRed", 0xC71585),
        ("midnightBlue", 0x191970),
        ("mintCream", 0xF5FFFA),
        ("mistyRose", 0xFFE4E1),
        ("moccasin", 0xFFE4B5),
        ("navajoWhite", 0xFFDEAD),
        ("navy", 0x000080),
        ("oldLace", 0xFDF5E6),
        ("olive", 0x808000),
        ("oliveDrab", 0x6B8E23),
        ("orange", 0xFFA500),
        ("orangeRed", 0xFF4500),
        ("orchid", 0xDA70D6),
        ("paleGoldenrod", 0xEEE8AA),
        ("paleGreen", 0x98FB98),
        ("paleTurquoise", 0xAFEEEE),
        ("paleVioletRed", 0xDB7093),
        ("papayaWhip", 0xFFEFD5),
        ("peachPuff", 0xFFDAB9),
        ("peru", 0xCD853F),
        ("pink", 0xFFC0CB),
        ("plum", 0xDDA0DD),
        ("powderBlue", 0xB0E0E6),
        ("purple", 0x800080),
        ("red", 0xFF0000),
        ("rosyBrown", 0xBC8F8F),
        ("royalBlue", 0x4169E1),
        ("saddleBrown", 0x8B4513),
        ("salmon", 0xFA8072),
        ("sandyBrown", 0xF4A460),
        ("seaGreen", 0x2E8B57),
        ("seaShell", 0xFFF5EE),
        ("seashell", 0xFFF5EE),
        ("sienna", 0xA0522D),
        ("silver", 0xC0C0C0),
        ("skyBlue", 0x87CEEB),
        ("slateBlue", 0x6A5ACD),
        ("slateGray", 0x708090),
        ("snow", 0xFFFAFA),
        ("springGreen", 0x00FF7F),
        ("steelBlue", 0x4682B4),
        ("tan", 0xD2B48C),
        ("teal", 0x008080),
        ("thistle", 0xD8BFD8),
        ("tomato", 0xFF6347),
        ("turquoise", 0x40E0D0),
        ("violet", 0xEE82EE),
        ("wheat", 0xF5DEB3),
        ("white", 0xFFFFFF),
        ("whiteSmoke", 0xF5F5F5),
        ("yellow", 0xFFFF00),
        ("yellowGreen", 0x9ACD32),
        ("grey", 0x808080),
        ("darkGrey", 0xA9A9A9),
        ("lightGrey", 0xD3D3D3),
        ("dimGrey", 0x696969),
        ("slateGrey", 0x708090),
        ("darkSlateGrey", 0x2F4F4F),
        ("lightSlateGrey", 0x778899),
        ("lightSteelGrey", 0xB0C4DE),
        ])
    func everyPresetName(name: String, hex: UInt32) throws {
        try expect(name, hex)
    }
}
