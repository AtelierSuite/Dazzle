import CoreText
import Foundation
import Testing
@testable import Dazzle

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
}
