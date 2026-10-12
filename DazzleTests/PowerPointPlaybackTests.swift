import CoreGraphics
import Foundation
import Testing
@testable import Dazzle

@Suite("Broader PowerPoint playback")
struct PowerPointPlaybackTests {
    private func imported(_ behavior: String, category: String = "emph", attributes: String = "", preset: Int = 999) throws -> ShapeAnimation {
        let timing = try XMLLite.parse(Data("""
            <p:timing xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <p:tnLst><p:par><p:cTn id="1" nodeType="tmRoot"><p:childTnLst><p:seq><p:cTn id="2" nodeType="mainSeq"><p:childTnLst>
            <p:par><p:cTn id="3"><p:stCondLst><p:cond evt="onBegin" delay="0"/></p:stCondLst><p:childTnLst>
            <p:par><p:cTn id="4"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>
            <p:par><p:cTn id="5" presetClass="\(category)" presetID="\(preset)" nodeType="withEffect" \(attributes)><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>
            \(behavior)
            </p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>
            </p:childTnLst></p:cTn></p:seq></p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>
            """.utf8))
        return try #require(AnimationXML.animations(in: timing).first)
    }
    private func behavior(_ name: String, attributes: String = "", content: String = "", property: String = "", timing: String = "") -> String {
        "<p:\(name) \(attributes)><p:cBhvr><p:cTn id=\"6\" dur=\"1000\" \(timing)/><p:tgtEl><p:spTgt spid=\"2\"/></p:tgtEl>"
        + (property.isEmpty ? "" : "<p:attrNameLst><p:attrName>\(property)</p:attrName></p:attrNameLst>")
        + "</p:cBhvr>\(content)</p:\(name)>"
    }
    private var shape: SlideShape {
        SlideShape(shapeID: 2, name: "", kind: .shape, frame: EMURect(x: 0, y: 0, width: 1_270_000, height: 1_270_000))
    }
    private func appearance(_ animation: ShapeAnimation, time: Double) -> AnimatedAppearance {
        AnimationTimeline(animations: [animation]).frame(begun: 1, elapsed: time, shapes: [shape], slideSize: CGSize(width: 100, height: 100)).shapes[2] ?? AnimatedAppearance()
    }

    @Test("Imported repeat counts and auto-reverse replay cycles rather than stretching one")
    func repeatedMotion() throws {
        let motion = behavior("animMotion", attributes: "origin=\"layout\" path=\"M 0 0 L 0.5 0 E\"")
        let repeated = try imported(motion, category: "path", attributes: "repeatCount=\"2500\"")
        #expect(repeated.duration == 1)
        #expect(repeated.activeDuration == 2.5)
        #expect(appearance(repeated, time: 1.5).offset.width == 25)
        #expect(appearance(repeated, time: 3).offset.width == 25)
        let reversed = try imported(motion, category: "path", attributes: "autoRev=\"1\" repeatCount=\"2000\"")
        #expect(reversed.activeDuration == 4)
        #expect(appearance(reversed, time: 1.25).offset.width == 37.5)
        #expect(appearance(reversed, time: 3.75).offset.width == 12.5)
        #expect(appearance(reversed, time: 4).offset == .zero)
        let bounded = try imported(motion, category: "path", attributes: "repeatCount=\"indefinite\" repeatDur=\"2500\"")
        #expect(bounded.activeDuration == 2.5)
        #expect(appearance(bounded, time: 3).offset.width == 25)
        let forever = try imported(motion, category: "path", attributes: "repeatCount=\"indefinite\"")
        #expect(forever.activeDuration.isInfinite)
        #expect(appearance(forever, time: 100.5).offset.width == 25)
    }
    @Test("An indefinite animation keeps redrawing and does not auto-advance") @MainActor
    func indefinitePlayback() async throws {
        var presentation = Presentation.blank
        var animation = try imported(behavior("animMotion", attributes: "origin=\"layout\" path=\"M 0 0 L 0.5 0 E\""), category: "path", attributes: "repeatCount=\"indefinite\"")
        animation.shapeID = presentation.slides[0].shapes[0].shapeID
        presentation.slides[0].animations = [animation]
        presentation.slides[0].autoAdvanceAfter = 0.1
        let state = EditorState()
        state.previewAnimations(in: presentation)
        #expect(state.animationPreviewStartedAt != nil)
        state.stopPreviewingAnimations()
        let session = PresentationSession()
        session.start(presentation, title: "Repeat", fromSlide: 0, owner: UUID())
        try await Task.sleep(for: .milliseconds(250))
        #expect(session.isPresenting && session.isAnimating)
        #expect(session.position == 0)
        session.next()
        #expect(!session.isPresenting)
    }
    @Test("All supported named filters import and produce deterministic reveal masks")
    func transitionFilters() throws {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        for name in AnimationFilter.names {
            let animation = try imported(behavior("animEffect", attributes: "transition=\"in\" filter=\"\(name)\""), category: "entr")
            guard case .filter(let filter, _, _) = animation.effect else { Issue.record("Filter \(name) was flattened"); continue }
            #expect(filter.name == name)
            #expect(appearance(animation, time: 0.5).mask?.filter == filter)
            #expect(filter.path(progress: 0, frame: rect).isEmpty)
            #expect(filter.path(progress: 1, frame: rect).contains(CGPoint(x: 50, y: 50)))
            let mask = filter.path(progress: 0.5, frame: rect)
            let points = (0..<10).flatMap { y in (0..<10).map { x in CGPoint(x: Double(x)*10+5, y: Double(y)*10+5) } }
            let count = points.filter { mask.contains($0, using: .evenOdd) }.count
            #expect(count > 0 && count < 100)
            #expect(mask == filter.path(progress: 0.5, frame: rect))
        }
        #expect(AnimationFilter("wheel(9999999)") == nil)
        let exit = try imported(behavior("animEffect", attributes: "transition=\"out\" filter=\"blinds(horizontal)\""), category: "exit")
        #expect(appearance(exit, time: 1).opacity == 0)
    }
    @Test("Filter masks and colour emphasis reach rendered pixels")
    func renderedEffects() throws {
        var presentation = Presentation.blank
        presentation.slideSize = EMUSize(width: 1_270_000, height: 1_270_000)
        var drawing = shape
        drawing.fill = .solid(.rgb(0xFF0000))
        drawing.line = LineStyle(fill: .none, width: 0)
        presentation.slides[0].shapes = [drawing]
        func pixels(_ animation: ShapeAnimation) throws -> [UInt8] {
            let frame = AnimationTimeline(animations: [animation]).frame(begun: 1, elapsed: 0.5, shapes: [drawing], slideSize: CGSize(width: 100, height: 100))
            let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: 100); context.scaleBy(x: 1, y: -1)
            SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false, animation: frame))
                .draw(in: context, size: CGSize(width: 100, height: 100))
            return Array(try #require(context.makeImage()?.dataProvider?.data as Data?))
        }
        let blinds = try imported(behavior("animEffect", attributes: "transition=\"in\" filter=\"blinds(horizontal)\""), category: "entr")
        let clipped = try pixels(blinds)
        let visible = stride(from: 3, to: clipped.count, by: 4).filter { clipped[$0] > 127 }.count
        #expect(visible >= 4_500 && visible <= 5_500)
    }

}
