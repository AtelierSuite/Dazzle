import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Slide and section zooms")
@MainActor
struct SlideZoomTests {
    // MARK: - A deck with zooms

    private static let namespaces = """
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
        """
    static let sectionID = "{6C1C2D9B-6A0D-4C1B-9E0F-1A2B3C4D5E6F}"

    /// A slide with a title and a coloured panel, so each looks different.
    static func slideXML(_ title: String, color: String, hidden: Bool = false, panel: Bool = true, extra: String = "") -> String {
        let panel = panel ? panelXML(title, color: color) : ""
        return """
        <p:sld \(namespaces)\(hidden ? " show=\"0\"" : "")><p:cSld><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr/><p:nvPr><p:ph type="ctrTitle"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="609600" y="304800"/><a:ext cx="10972800" cy="1143000"/></a:xfrm></p:spPr>\
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>\(title)</a:t></a:r></a:p></p:txBody></p:sp>\
        \(panel)\(extra)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    private static func panelXML(_ title: String, color: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Panel"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="609600" y="1752600"/><a:ext cx="10972800" cy="4572000"/></a:xfrm>\
        <a:prstGeom prst="roundRect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(color)"/></a:solidFill></p:spPr>\
        <p:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="en-US" sz="4400">\
        <a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:rPr><a:t>\(title)</a:t></a:r></a:p></p:txBody></p:sp>
        """
    }

    /// A zoom as PowerPoint writes it: the zoom for newer readers, and a
    /// picture with a link for older ones.
    static func zoomXML(
        id: Int, name: String, x: Int, y: Int, kind: String, object: String, link: String
    ) -> String {
        let (prefix, uri) = kind == "slide"
            ? ("pslz", SlideZoom.slideNamespace) : ("psez", SlideZoom.sectionNamespace)
        let element = kind == "slide" ? "sldZm" : "sectionZm"
        let frame = "<a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"3657600\" cy=\"2057400\"/></a:xfrm>"
        let outline = "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:ln w=\"12700\"><a:solidFill><a:srgbClr val=\"404040\"/></a:solidFill></a:ln>"
        return """
            <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">\
            <mc:Choice xmlns:\(prefix)="\(uri)" Requires="\(prefix)"><p:graphicFrame>\
            <p:nvGraphicFramePr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvGraphicFramePr>\
            <a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>\
            <p:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="3657600" cy="2057400"/></p:xfrm>\
            <a:graphic><a:graphicData uri="\(uri)"><\(prefix):\(element)>\(object)</\(prefix):\(element)></a:graphicData></a:graphic>\
            </p:graphicFrame></mc:Choice><mc:Fallback><p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="\(name)">\
            <a:hlinkClick r:id="\(link)" action="ppaction://hlinksldjump"/></p:cNvPr><p:cNvPicPr>\
            <a:picLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr>\(frame)\(outline)</p:spPr></p:pic></mc:Fallback></mc:AlternateContent>
            """
    }

    static func zoomProperties(_ prefix: String, returns: Bool, duration: Int?) -> String {
        """
        <\(prefix):zmPr id="{\(UUID().uuidString)}" returnToParent="\(returns ? "1" : "0")"\
        \(duration.map { " transitionDur=\"\($0)\"" } ?? "")>\
        <p166:blipFill xmlns:p166="http://schemas.microsoft.com/office/powerpoint/2016/6/main"><a:blip r:embed="rId2"/>\
        <a:stretch><a:fillRect/></a:stretch></p166:blipFill>\
        <p166:spPr xmlns:p166="http://schemas.microsoft.com/office/powerpoint/2016/6/main"><a:xfrm><a:off x="0" y="0"/>\
        <a:ext cx="3657600" cy="2057400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p166:spPr></\(prefix):zmPr>
        """
    }

    /// A grey picture, the stale image a zoom was saved with.
    static var stalePicture: Data {
        let context = CGContext(
            data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return PreparedMedia.png(of: context.makeImage()!) ?? Data()
    }

    /// Seven slides in four sections. The first has a slide zoom to the
    /// hidden fourth slide and a section zoom to the section of the fifth
    /// and sixth, both coming back, flying for `duration` milliseconds.
    static func deck(returns: Bool = true, duration: Int? = 1_000) throws -> Presentation {
        let layout = Relationship(id: "rId1", type: OOXML.RelationshipType.slideLayout, target: "../slideLayouts/slideLayout1.xml")
        let picture = Relationship(id: "rId2", type: OOXML.RelationshipType.image, target: "../media/stale.png")
        func link(_ slide: Int) -> Relationship {
            Relationship(id: "rId\(slide + 2)", type: OOXML.RelationshipType.slide, target: "slide\(slide).xml")
        }
        let slideZoom = zoomXML(
            id: 10, name: "Slide Zoom 9", x: 609600, y: 2286000, kind: "slide",
            object: "<pslz:sldZmObj sldId=\"259\" cId=\"0\">\(zoomProperties("pslz", returns: returns, duration: duration))</pslz:sldZmObj>",
            link: "rId6"
        )
        let sectionZoom = zoomXML(
            id: 11, name: "Section Zoom 10", x: 7924800, y: 2286000, kind: "section",
            object: "<psez:sectionZmObj sectionId=\"\(sectionID)\">\(zoomProperties("psez", returns: returns, duration: duration))</psez:sectionZmObj>",
            link: "rId7"
        )
        let overview = slideXML("Overview", color: "2F5597", panel: false, extra: slideZoom + sectionZoom)
        let slides: [PresentationTemplate.SlidePart] = [
            .init(xml: overview, relationships: [layout, picture, link(4), link(5)]),
            .init(xml: slideXML("Agenda", color: "548235"), relationships: [layout]),
            .init(xml: slideXML("Method", color: "BF9000"), relationships: [layout]),
            .init(xml: slideXML("Hidden detail", color: "C00000", hidden: true), relationships: [layout]),
            .init(xml: slideXML("Results: sales", color: "7030A0"), relationships: [layout]),
            .init(xml: slideXML("Results: costs", color: "00B0F0"), relationships: [layout]),
            .init(xml: slideXML("Thank you", color: "404040"), relationships: [layout]),
        ]
        var presentation = try PPTXReader.presentation(fromParts: PresentationTemplate.parts(
            size: .widescreen, slides: slides, media: ["ppt/media/stale.png": stalePicture]
        ))
        let ids = presentation.slides.map(\.id)
        presentation.sections = [
            SlideSection(name: "Introduction", slideIDs: [ids[0], ids[1]]),
            SlideSection(name: "Details", slideIDs: [ids[2], ids[3]]),
            SlideSection(id: sectionID, name: "Results", slideIDs: [ids[4], ids[5]]),
            SlideSection(name: "Wrap-up", slideIDs: [ids[6]]),
        ]
        presentation.areSectionsModified = true
        // Read back, so the zooms meet the sections as they would in a file.
        return try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    private func zooms(on slide: Slide) -> [SlideZoom] {
        slide.shapes.compactMap { if case .zoom(let zoom)? = $0.link { zoom } else { nil } }
    }

    // MARK: - Reading

    @Test("Slide and section zooms are read with their target, return and duration")
    func reading() throws {
        let presentation = try Self.deck()
        let found = zooms(on: presentation.slides[0])
        #expect(found.count == 2)
        #expect(found[0].target == .slide(presentation.slides[3].id))
        #expect(found[1].target == .section(Self.sectionID))
        #expect(found.allSatisfy { $0.returnsToParent && $0.transitionDuration == 1 && $0.showsPreview })
        #expect(presentation.slides[0].shapes.filter { $0.link != nil }.allSatisfy { $0.isLocked })
        #expect(found[1].slideIndices(in: presentation) == [4, 5])
        #expect(found[0].previewSlide(in: presentation)?.id == presentation.slides[3].id)

        // Not returning and with no flight of their own.
        let plain = zooms(on: try Self.deck(returns: false, duration: nil).slides[0])
        #expect(plain.allSatisfy { !$0.returnsToParent && $0.transitionDuration == nil })

        // Left untouched, they are saved exactly as they were.
        let saved = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(zooms(on: saved.slides[0]) == zooms(on: presentation.slides[0]).map { zoom in
            var zoom = zoom
            if case .slide = zoom.target { zoom.target = .slide(saved.slides[3].id) }
            return zoom
        })
    }

    @Test("A summary zoom's pictures each lead to their own section")
    func summary() throws {
        let alternate = try XMLLite.parse(Data("""
            <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
            xmlns:psuz="\(SlideZoom.summaryNamespace)"><mc:Choice Requires="psuz"><psuz:summaryZm>\
            <psuz:summaryZmObj sectionId="{A}"><psuz:zmPr id="{1}" returnToParent="0"/></psuz:summaryZmObj>\
            <psuz:summaryZmObj sectionId="{B}"><psuz:zmPr id="{2}" imageType="cover"/></psuz:summaryZmObj>\
            <psuz:gridLayout/></psuz:summaryZm></mc:Choice><mc:Fallback/></mc:AlternateContent>
            """.utf8))
        let found = SlideZoom.zooms(in: alternate)
        #expect(found.map(\.target) == [.section("{A}"), .section("{B}")])
        #expect(found.map(\.returnsToParent) == [false, true])
        #expect(found.map(\.showsPreview) == [true, false])
    }

    // MARK: - Drawing

    @Test("A zoom's picture shows its slide as it is now, not the picture saved with it")
    func livePreview() throws {
        var presentation = try Self.deck()
        let overview = presentation.slides[0]
        let zoomFrame = try #require(overview.shapes.first { if case .zoom? = $0.link { true } else { false } }).frame.points
        func colour(in presentation: Presentation) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
            let size = presentation.slideSize.points
            let image = try #require(SlideExporter.cgImage(of: presentation.slides[0], in: presentation, width: Int(size.width), opaque: true))
            let data = try #require(image.dataProvider?.data as Data?)
            // Within the zoom's picture, on the target slide's panel, above its words.
            let x = Int(zoomFrame.midX), y = Int(zoomFrame.minY + zoomFrame.height * 160 / 540)
            let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
            return (data[offset], data[offset + 1], data[offset + 2])
        }
        let before = try colour(in: presentation)
        // The hidden slide's red panel, not the grey picture.
        #expect(before.red > 150 && before.green < 60 && before.blue < 60)

        // Recoloured, the zoom follows.
        let hidden = 3
        let panel = try #require(presentation.slides[hidden].shapes.firstIndex { $0.name == "Panel" })
        presentation.slides[hidden].shapes[panel].fill = .solid(.rgb(0x00A000))
        presentation.slides[hidden].shapes[panel].edits.insert(.fill)
        let after = try colour(in: presentation)
        #expect(after.green > 120 && after.red < 60)
    }

    // MARK: - Playing

    private func play(_ presentation: Presentation) -> PresentationSession {
        let session = PresentationSession()
        session.start(presentation, title: "Zooms", fromSlide: 0, owner: UUID())
        return session
    }

    private func tapZoom(_ index: Int, in session: PresentationSession) throws {
        let slide = try #require(session.currentSlide)
        let zoom = zooms(on: slide)[index]
        let area = try #require(session.presentation.map {
            SlideRenderer(presentation: $0, slide: slide).linkAreas().first { $0.1 == .zoom(zoom) }?.0
        } ?? nil)
        let link = try #require(session.link(at: CGPoint(x: area.midX, y: area.midY)))
        #expect(link == .zoom(zoom))
        _ = session.follow(link)
    }

    @Test("A slide zoom shows its hidden slide, then comes back to the zoom's slide")
    func slideZoom() throws {
        let presentation = try Self.deck()
        let session = play(presentation)
        defer { session.end() }
        #expect(session.currentSlide?.title == "Overview")
        try tapZoom(0, in: session)
        #expect(session.currentSlide?.title == "Hidden detail")
        if case .zoomObject(let frame, let returning)? = session.transition?.transition.effect {
            #expect(!returning)
            #expect(abs(frame.x - 0.05) < 0.01 && abs(frame.width - 0.3) < 0.01)
        } else {
            Issue.record("The zoom should fly into its picture")
        }
        session.next()
        session.next()
        #expect(session.currentSlide?.title == "Overview")
        if case .zoomObject(_, let returning)? = session.transition?.transition.effect {
            #expect(returning)
        } else {
            Issue.record("The return should fly back out into the picture")
        }
        // From there the show goes on as before.
        session.next()
        session.next()
        #expect(session.currentSlide?.title == "Agenda")
    }

    @Test("A section zoom shows the section's slides, then comes back")
    func sectionZoom() throws {
        let session = play(try Self.deck())
        defer { session.end() }
        try tapZoom(1, in: session)
        #expect(session.currentSlide?.title == "Results: sales")
        session.next()
        session.next()
        #expect(session.currentSlide?.title == "Results: costs")
        session.next()
        session.next()
        #expect(session.currentSlide?.title == "Overview")
    }

    @Test("A zoom that does not come back carries on from its slides, with their own transition")
    func noReturn() throws {
        let session = play(try Self.deck(returns: false, duration: nil))
        defer { session.end() }
        try tapZoom(1, in: session)
        #expect(session.currentSlide?.title == "Results: sales")
        #expect(session.transition == nil)
        session.next()
        session.next()
        #expect(session.currentSlide?.title == "Thank you")
    }

    @Test("The zoom's flight grows its picture to fill the slide, and shrinks back on return")
    func flight() {
        let frame = SlideTransition.ZoomFrame(x: 0.5, y: 0.5, width: 0.25, height: 0.25)
        let size = CGSize(width: 960, height: 540)
        let start = SlideTransition(effect: .zoomObject(frame, returning: false), duration: 1).frame(progress: 0, size: size)
        let incoming = start.layers[1]
        #expect(incoming.content == .incoming)
        #expect(CGRect(origin: .zero, size: size).applying(incoming.transform) == CGRect(x: 480, y: 270, width: 240, height: 135))
        let end = SlideTransition(effect: .zoomObject(frame, returning: false), duration: 1).frame(progress: 1, size: size)
        #expect(end.layers[1].transform == .identity)
        #expect(end.layers[1].opacity == 1)
        // Back out: the zoomed slide ends where its picture is.
        let back = SlideTransition(effect: .zoomObject(frame, returning: true), duration: 1).frame(progress: 1, size: size)
        #expect(back.layers.map(\.content) == [.incoming, .outgoing])
        #expect(back.layers[0].transform == .identity)
        #expect(CGRect(origin: .zero, size: size).applying(back.layers[1].transform) == CGRect(x: 480, y: 270, width: 240, height: 135))
        // With Reduce Motion, a cross-fade.
        #expect(SlideTransition(effect: .zoomObject(frame, returning: false), duration: 1)
            .played(reduceMotion: true).effect == .fade(throughBlack: false))
    }
}
