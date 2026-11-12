@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

/// Theme Colors & Fonts: changing the theme's colours and fonts, slides
/// following, and the theme part written back.
@MainActor
@Suite("Theme editing")
struct ThemeEditingTests {
    private func blankDeck() -> (Presentation, EditorState) {
        let presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        return (presentation, state)
    }

    private func themeXML(of presentation: Presentation) throws -> String {
        let data = try PPTXWriter.data(from: presentation)
        let master = try #require(presentation.resources.masters.keys.first)
        let path = try #require(presentation.themePath(ofMaster: master))
        let theme = try #require(try ZipArchive.entries(in: data)[path])
        return String(decoding: theme, as: UTF8.self)
    }

    @Test("A changed accent colour shows on every slide that refers to it")
    func accentFollows() throws {
        var (presentation, state) = blankDeck()
        let layout = try #require(presentation.resources.orderedLayouts.dropFirst().first)
        state.addSlide(using: layout, in: &presentation)
        #expect(!presentation.isThemeModified)
        state.setThemeColor(0x8E44AD, for: "accent1", in: &presentation)
        #expect(presentation.isThemeModified)
        for slide in presentation.slides {
            let style = SlideStyleContext(presentation: presentation, slide: slide)
            #expect(style.color(.scheme("accent1")).hexValue == 0x8E44AD)
            #expect(style.color(.scheme("accent2")).hexValue == 0xFF9500)
        }
        #expect(state.theme(in: presentation).colors["accent1"] == 0x8E44AD)
    }

    @Test("Text in the heading font follows a new heading font")
    func headingFontFollows() {
        var (presentation, state) = blankDeck()
        state.setThemeFont("Georgia", heading: true, in: &presentation)
        let slide = presentation.slides[0]
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let title = slide.shapes[0]
        let base = style.paragraphBase(for: title, sources: style.sources(for: title), level: 0)
        #expect(style.typeface(base.defaultRun.latinFont) == "Georgia")
        #expect(style.theme.majorFont == "Georgia")
        #expect(style.theme.minorFont == "Arial")
    }

    @Test("An unchanged theme is not marked as edited, and a blank font is ignored")
    func noChange() {
        var (presentation, state) = blankDeck()
        let theme = state.theme(in: presentation)
        state.setTheme(theme, in: &presentation)
        state.setThemeFont("  ", heading: false, in: &presentation)
        #expect(!presentation.isThemeModified)
    }

    @Test("The theme part is written with the new colours and fonts and reads back")
    func roundTrip() throws {
        var (presentation, state) = blankDeck()
        state.setThemeColor(0x8E44AD, for: "accent1", in: &presentation)
        state.setThemeColor(0x101010, for: "dk1", in: &presentation)
        state.setThemeFont("Georgia", heading: true, in: &presentation)
        state.setThemeFont("Verdana", heading: false, in: &presentation)

        let xml = try themeXML(of: presentation)
        #expect(xml.contains("<a:accent1><a:srgbClr val=\"8E44AD\"/></a:accent1>"))
        // A system colour that changed becomes a plain one; one left alone stays.
        #expect(xml.contains("<a:dk1><a:srgbClr val=\"101010\"/></a:dk1>"))
        #expect(xml.contains("<a:sysClr val=\"window\" lastClr=\"FFFFFF\"/>"))
        // The East Asian fonts and the format scheme are kept.
        #expect(xml.contains("<a:ea typeface=\"Meiryo UI\"/>"))
        #expect(xml.contains("fmtScheme"))

        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let theme = try #require(copy.resources.masters.values.first?.theme)
        #expect(theme.colors["accent1"] == 0x8E44AD)
        #expect(theme.colors["dk1"] == 0x101010)
        #expect(theme.colors["lt1"] == 0xFFFFFF)
        #expect(theme.majorFont == "Georgia")
        #expect(theme.minorFont == "Verdana")
        #expect(theme.majorEastAsianFont == "Meiryo UI")
    }

    @Test("An untouched theme part is written back byte for byte")
    func untouchedPart() throws {
        let presentation = Presentation.blank
        let master = try #require(presentation.resources.masters.keys.first)
        let path = try #require(presentation.themePath(ofMaster: master))
        let data = try PPTXWriter.data(from: presentation)
        let written = try #require(try ZipArchive.entries(in: data)[path])
        #expect(written == presentation.package.parts[path])
    }

    @Test("A missing colour slot is added in its place")
    func missingSlot() throws {
        let xml = """
            <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="T"><a:themeElements>\
            <a:clrScheme name="C"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:accent2><a:srgbClr val="FF0000"/></a:accent2></a:clrScheme>\
            <a:fontScheme name="F"><a:majorFont><a:ea typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Arial"/></a:minorFont></a:fontScheme>\
            </a:themeElements></a:theme>
            """
        var theme = Theme.office
        theme.colors["accent1"] = 0x123456
        theme.colors["dk1"] = 0x000000
        theme.colors["accent2"] = 0xFF0000
        theme.majorFont = "Georgia"
        let patched = String(decoding: try #require(ThemeXML.patched(Data(xml.utf8), with: theme)), as: UTF8.self)
        #expect(patched.contains("</a:dk1><a:lt1>"))
        #expect(patched.contains("<a:accent1><a:srgbClr val=\"123456\"/></a:accent1><a:accent2><a:srgbClr val=\"FF0000\"/></a:accent2>"))
        #expect(patched.contains("<a:majorFont><a:latin typeface=\"Georgia\"/><a:ea typeface=\"\"/></a:majorFont>"))
    }
}
