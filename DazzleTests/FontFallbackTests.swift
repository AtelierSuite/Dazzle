import CoreText
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Font fallback")
struct FontFallbackTests {
    private func font(_ family: String, bold: Bool = false) -> CTFont {
        FontResolver.shared.font(family: family, size: 20, bold: bold, italic: false)
    }

    private func weight(of font: CTFont) -> Double {
        let traits = CTFontCopyTraits(font) as NSDictionary
        return (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
    }

    @Test("Families iOS lacks are sorted by what their names suggest")
    func categories() {
        #expect(FontResolver.category(of: "Merriweather") == .serif)
        #expect(FontResolver.category(of: "Source Serif Pro") == .serif)
        #expect(FontResolver.category(of: "PT Sans") == .sansSerif)
        #expect(FontResolver.category(of: "Noto Sans Mono") == .monospaced)
        #expect(FontResolver.category(of: "Fira Code") == .monospaced)
        #expect(FontResolver.category(of: "Monaco") == .monospaced)
        #expect(FontResolver.category(of: "Open Sans") == .sansSerif)
        #expect(FontResolver.category(of: "Montserrat") == .sansSerif)
        #expect(FontResolver.category(of: "游明朝") == .mincho)
        #expect(FontResolver.category(of: "ＭＳ ゴシック") == .gothic)
    }

    @Test("Family names are read word by word, not letter run by letter run")
    func categoryWords() {
        #expect(FontResolver.category(of: "Monotype Corsiva") == .sansSerif)
        #expect(FontResolver.category(of: "Flora") == .sansSerif)
        #expect(FontResolver.category(of: "Arial Unicode MS") == .sansSerif)
        #expect(FontResolver.category(of: "IBMPlexMono") == .monospaced)
        #expect(FontResolver.category(of: "SourceCodePro-Regular") == .monospaced)
        #expect(FontResolver.category(of: "PTSerif") == .serif)
        #expect(FontResolver.category(of: "Microsoft Sans Serif") == .sansSerif)
        #expect(FontResolver.category(of: "Lora") == .serif)
    }

    @Test("Serif families fall back to Times, monospaced ones to a fixed-width face, others to the system font")
    func faces() {
        #expect(CTFontCopyFamilyName(font("Merriweather")) as String == "Times New Roman")
        #expect(CTFontGetSymbolicTraits(font("Fira Code")).contains(.traitMonoSpace))
        let system = CTFontCopyFamilyName(CTFontCreateUIFontForLanguage(.system, 20, nil)!) as String
        #expect(CTFontCopyFamilyName(font("Open Sans")) as String == system)
    }

    @Test("A weight in the family's name carries over to the face it falls back to")
    func weights() {
        #expect(weight(of: font("Open Sans Light")) < weight(of: font("Open Sans")))
        #expect(weight(of: font("Open Sans Semibold")) > weight(of: font("Open Sans")))
        #expect(CTFontGetSymbolicTraits(font("Merriweather Black")).contains(.traitBold))
        #expect(CTFontGetSymbolicTraits(font("Open Sans", bold: true)).contains(.traitBold))
    }

    @Test("Families iOS has are used as they are")
    func installed() {
        #expect(CTFontCopyFamilyName(font("Georgia")) as String == "Georgia")
        #expect(CTFontCopyFamilyName(font("Calibri")) as String != "Times New Roman")
    }

    private func isInstalled(_ family: String) -> Bool {
        CTFontCopyFamilyName(CTFontCreateWithName(family as CFString, 12, nil)) as String == family
    }

    @Test("Office and Windows families are drawn in metric-compatible stand-ins first, then the nearest in look")
    func substituteTable() {
        #expect(FontResolver.substitutes(for: "Calibri")?.first == "Carlito")
        #expect(FontResolver.substitutes(for: "Calibri Light")?.first == "Carlito")
        #expect(FontResolver.substitutes(for: "Cambria")?.first == "Caladea")
        #expect(FontResolver.substitutes(for: "Arial") == ["Helvetica"])
        #expect(FontResolver.substitutes(for: "Liberation Sans")?.first == "Arial")
        #expect(FontResolver.substitutes(for: "Meiryo UI") == ["Hiragino Sans"])
        #expect(FontResolver.substitutes(for: "Yu Gothic") == ["Hiragino Sans"])
        #expect(FontResolver.substitutes(for: "ＭＳ Ｐゴシック") == ["Hiragino Sans"])
        // The longest prefix wins, and whole-name entries don't take in their longer relatives.
        #expect(FontResolver.substitutes(for: "Arial Nova") == [""])
        #expect(FontResolver.substitutes(for: "Arial Narrow") == nil)
        #expect(FontResolver.substitutes(for: "Open Sans") == nil)
    }

    @Test("A stand-in is used only where the device has it")
    func installedStandIns() {
        #expect(CTFontCopyFamilyName(font("Calibri")) as String == (isInstalled("Carlito") ? "Carlito" : CTFontCopyFamilyName(font("Aptos")) as String))
        #expect(CTFontCopyFamilyName(font("Cambria")) as String == (isInstalled("Caladea") ? "Caladea" : "Georgia"))
        #expect(CTFontCopyFamilyName(font("Meiryo")) as String == "Hiragino Sans")
        #expect(CTFontCopyFamilyName(font("Arial")) as String == (isInstalled("Arial") ? "Arial" : "Helvetica"))
        #if os(iOS)
        // iOS ships Carlito, metric-compatible with Calibri.
        #expect(CTFontCopyFamilyName(font("Calibri")) as String == "Carlito")
        #endif
    }

    @Test("Substitutes are named, and fonts the device has or the deck carries are not")
    func substituteNames() {
        #expect(FontResolver.shared.substitute(for: "Georgia") == nil)
        #expect(FontResolver.shared.substitute(for: "Meiryo") == "Hiragino Sans")
        #expect(FontResolver.shared.substitute(for: "Merriweather") == "Times New Roman")
        #expect(FontResolver.shared.substitute(for: "Aptos") == "SF Pro")
        #expect(FontResolver.shared.substitute(for: "") == nil)
    }

    @Test("A deck lists the fonts it uses that are drawn in others, theme fonts included")
    func presentationSubstitutions() {
        var presentation = Presentation.blank
        var properties = RunProperties()
        properties.latinFont = "Meiryo"
        var box = SlideShape(shapeID: 90, name: "Box", kind: .shape, frame: EMURect(x: 0, y: 0, width: 100, height: 100))
        box.text = TextBody(paragraphs: [Paragraph(runs: [TextRun(text: "こんにちは", properties: properties)])])
        properties.latinFont = "Georgia"
        box.text?.paragraphs.append(Paragraph(runs: [TextRun(text: "Hello", properties: properties)]))
        presentation.slides[0].shapes.append(box)
        let substitutions = presentation.fontSubstitutions
        #expect(substitutions.contains(FontSubstitution(requested: "Meiryo", substitute: "Hiragino Sans")))
        #expect(!substitutions.contains { $0.requested == "Georgia" })
        #expect(presentation.typefaces.contains("Georgia"))
        // The theme's fonts are what titles and body text use unless told otherwise.
        let theme = presentation.resources.master(for: presentation.layout(for: presentation.slides[0]))?.theme
        #expect(presentation.typefaces.contains(theme?.minorFont ?? ""))
        #expect(substitutions.noticeMessage.contains("• Meiryo → Hiragino Sans"))
    }
}
