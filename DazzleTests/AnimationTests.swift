import CoreGraphics
import Foundation
import Testing
@testable import Dazzle

private final class AnimationTestBundle: NSObject {}

@Suite("Animations")
struct AnimationTests {
    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    /// The main sequence PowerPoint writes for: title fades in on a click,
    /// then the body's second and third paragraphs fly in from the left after it.
    private static let powerPointTiming = """
        <p:timing xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:tnLst><p:par>\
        <p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>\
        <p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>\
        <p:par><p:cTn id="3" fill="hold"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="4" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="5" presetID="10" presetClass="entr" presetSubtype="0" fill="hold" grpId="0" nodeType="clickEffect">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:set><p:cBhvr><p:cTn id="6" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\
        <p:tgtEl><p:spTgt spid="2"/></p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr>\
        <p:to><p:strVal val="visible"/></p:to></p:set>\
        <p:animEffect transition="in" filter="fade"><p:cBhvr><p:cTn id="7" dur="750"/><p:tgtEl><p:spTgt spid="2"/></p:tgtEl></p:cBhvr></p:animEffect>\
        </p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>\
        <p:par><p:cTn id="8" fill="hold"><p:stCondLst><p:cond delay="750"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="9" presetID="2" presetClass="entr" presetSubtype="8" fill="hold" grpId="0" nodeType="afterEffect">\
        <p:stCondLst><p:cond delay="250"/></p:stCondLst><p:childTnLst>\
        <p:set><p:cBhvr><p:cTn id="10" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\
        <p:tgtEl><p:spTgt spid="3"><p:txEl><p:pRg st="1" end="2"/></p:txEl></p:spTgt></p:tgtEl>\
        <p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>\
        <p:anim calcmode="lin" valueType="num"><p:cBhvr additive="base"><p:cTn id="11" dur="500" fill="hold"/>\
        <p:tgtEl><p:spTgt spid="3"><p:txEl><p:pRg st="1" end="2"/></p:txEl></p:spTgt></p:tgtEl>\
        <p:attrNameLst><p:attrName>ppt_x</p:attrName></p:attrNameLst></p:cBhvr><p:tavLst>\
        <p:tav tm="0"><p:val><p:strVal val="0-#ppt_w/2"/></p:val></p:tav><p:tav tm="100000"><p:val><p:strVal val="#ppt_x"/></p:val></p:tav>\
        </p:tavLst></p:anim></p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>\
        </p:childTnLst></p:cTn></p:par>\
        </p:childTnLst></p:cTn><p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>\
        <p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq>\
        </p:childTnLst></p:cTn></p:par></p:tnLst>\
        <p:bldLst><p:bldP spid="2" grpId="0"/><p:bldP spid="3" grpId="0" build="p"/></p:bldLst></p:timing>
        """

    @Test("PowerPoint's main sequence reads as effects, triggers and timings")
    func readsMainSequence() throws {
        let timing = try XMLLite.parse(Data(Self.powerPointTiming.utf8))
        let animations = AnimationXML.animations(in: timing)
        #expect(animations.count == 2)
        let fade = animations[0]
        #expect(fade.shapeID == 2)
        #expect(fade.category == .entrance)
        #expect(fade.effect == .fade)
        #expect(fade.trigger == .onClick)
        #expect(abs(fade.duration - 0.75) < 0.001)
        #expect(fade.paragraphs == nil)
        let fly = animations[1]
        #expect(fly.shapeID == 3)
        #expect(fly.effect == .fly(.left))
        #expect(fly.trigger == .afterPrevious)
        #expect(abs(fly.delay - 0.25) < 0.001)
        #expect(abs(fly.duration - 0.5) < 0.001)
        #expect(fly.paragraphs == 1...2)
        #expect(fly.source != nil)
    }

    @Test("Effects that start together, or one after another, share a tap")
    func timeline() {
        let animations = [
            ShapeAnimation(shapeID: 2, category: .entrance, effect: .fade, trigger: .withPrevious, duration: 1),
            ShapeAnimation(shapeID: 3, category: .entrance, effect: .appear, trigger: .onClick),
            ShapeAnimation(shapeID: 4, category: .entrance, effect: .fade, trigger: .withPrevious, duration: 0.5, delay: 0.25),
            ShapeAnimation(shapeID: 5, category: .exit, effect: .fade, trigger: .afterPrevious, duration: 1),
        ]
        let timeline = AnimationTimeline(animations: animations)
        #expect(timeline.startsAutomatically)
        #expect(timeline.steps.count == 2)
        #expect(timeline.tapCount == 1)
        #expect(timeline.tapNumber(of: animations[0].id) == nil)
        #expect(timeline.tapNumber(of: animations[3].id) == 1)
        // The exit waits for the fade before it, which ends at 0.75s.
        #expect(abs(timeline.duration(ofStep: 1) - 1.75) < 0.001)
    }

    @Test("Shapes coming in are hidden until their step, and gone after going out")
    func frames() {
        let shapes = [2, 3].map { SlideShape(shapeID: $0, name: "", kind: .shape, frame: EMURect(x: 0, y: 0, width: 127_000, height: 127_000)) }
        let animations = [
            ShapeAnimation(shapeID: 2, category: .entrance, effect: .fade, duration: 1),
            ShapeAnimation(shapeID: 3, category: .exit, effect: .appear),
        ]
        let timeline = AnimationTimeline(animations: animations)
        let size = CGSize(width: 960, height: 540)
        let before = timeline.frame(begun: 0, elapsed: 0, shapes: shapes, slideSize: size)
        #expect(before.shapes[2]?.opacity == 0)
        #expect(before.shapes[3] == nil)
        let midway = timeline.frame(begun: 1, elapsed: 0.5, shapes: shapes, slideSize: size)
        #expect(abs((midway.shapes[2]?.opacity ?? 0) - 0.5) < 0.001)
        let after = timeline.frame(begun: 2, elapsed: 10, shapes: shapes, slideSize: size)
        #expect(after.shapes[2] == nil)
        #expect(after.shapes[3]?.opacity == 0)
    }

    @Test("Added animations are written and read back")
    func roundTrip() throws {
        var presentation = Presentation.blank
        let title = presentation.slides[0].shapes[0].shapeID
        let subtitle = presentation.slides[0].shapes[1].shapeID
        presentation.slides[0].animations = [
            ShapeAnimation(shapeID: title, category: .entrance, effect: .wipe(.left), trigger: .withPrevious, duration: 0.75),
            ShapeAnimation(shapeID: subtitle, category: .emphasis, effect: .teeter, trigger: .onClick),
            ShapeAnimation(shapeID: subtitle, category: .exit, effect: .fly(.top), trigger: .afterPrevious, delay: 0.5),
        ]
        presentation.slides[0].areAnimationsModified = true
        presentation.slides[0].isModified = true
        let read = try reread(presentation).slides[0].animations
        #expect(read.map(\.shapeID) == [title, subtitle, subtitle])
        #expect(read.map(\.category) == [.entrance, .emphasis, .exit])
        #expect(read.map(\.effect) == [.wipe(.left), .teeter, .fly(.top)])
        #expect(read.map(\.trigger) == [.withPrevious, .onClick, .afterPrevious])
        #expect(read.map { ($0.duration * 1_000).rounded() } == [750, 1_000, 500])
        #expect(read.map { ($0.delay * 1_000).rounded() } == [0, 0, 500])
    }

    @Test("Effects read from a file keep their XML when only their start changes")
    func retimedSource() throws {
        var presentation = Presentation.blank
        presentation.slides[0].animations = [
            ShapeAnimation(shapeID: presentation.slides[0].shapes[0].shapeID, category: .entrance, effect: .preset(id: 37, subtype: 0)),
        ]
        presentation.slides[0].areAnimationsModified = true
        presentation.slides[0].isModified = true
        var copy = try reread(presentation)
        #expect(copy.slides[0].animations.first?.effect == .preset(id: 37, subtype: 0))
        copy.slides[0].animations[0].trigger = .afterPrevious
        copy.slides[0].animations[0].delay = 1
        copy.slides[0].areAnimationsModified = true
        copy.slides[0].isModified = true
        let final = try reread(copy).slides[0].animations
        #expect(final.first?.effect == .preset(id: 37, subtype: 0))
        #expect(final.first?.trigger == .afterPrevious)
        #expect(final.first?.delay == 1)
    }

    @Test("Deleting a shape takes its animations, and an empty timing, with it") @MainActor
    func deletedShape() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        let shape = presentation.slides[0].shapes[0]
        state.selectedShapeID = shape.id
        state.addAnimation(.zoom, category: .entrance, in: &presentation)
        #expect(presentation.slides[0].animations.count == 1)
        state.deleteSelectedShape(in: &presentation)
        #expect(presentation.slides[0].animations.isEmpty)
        let data = try PPTXWriter.data(from: presentation)
        let parts = try ZipArchive.entries(in: data)
        let slide = String(decoding: parts["ppt/slides/slide1.xml"] ?? Data(), as: UTF8.self)
        #expect(!slide.contains("timing"))
    }

    @Test("Motion paths are followed at an even pace")
    func motionPath() {
        let path = MotionPath(path: "M 0 0 L 0.5 0 L 0.5 0.5 E")
        #expect(path.offset(at: 0) == .zero)
        #expect(path.offset(at: 0.5) == CGPoint(x: 0.5, y: 0))
        #expect(path.offset(at: 1) == CGPoint(x: 0.5, y: 0.5))
    }

    // Timing-only fixtures from the supplied LCD sample; no slide artwork is needed.
    private func lcdAnimations(slide: Int) throws -> [ShapeAnimation] {
        let url = try #require(Bundle(for: AnimationTestBundle.self).url(forResource: "LCD-slide\(slide)-timing", withExtension: "xml"))
        return AnimationXML.animations(in: try XMLLite.parse(Data(contentsOf: url)))
    }

    private func shapes(for animations: [ShapeAnimation]) -> [SlideShape] {
        Set(animations.map(\.shapeID)).map {
            SlideShape(shapeID: $0, name: "", kind: .shape,
                       frame: EMURect(x: 127_000, y: 127_000, width: 1_270_000, height: 1_270_000))
        }
    }

    @Test("LCD sample imports every effect and its custom scale axes")
    func lcdSample() throws {
        for (slide, count) in [(2, 47), (3, 74), (4, 36), (5, 52)] {
            let animations = try lcdAnimations(slide: slide)
            #expect(animations.count == count)
            #expect(AnimationTimeline(animations: animations).startsAutomatically)
            let scales = animations.filter { $0.effect == .growShrink }
            #expect(scales.allSatisfy { $0.scaling != nil })
            #expect(scales.contains { $0.scaling?.to == CGSize(width: 1, height: 0) })
        }
        #expect(try lcdAnimations(slide: 3).contains { $0.scaling?.to == .zero })
    }

    @Test("LCD paragraph fades, scaling, and movement play together")
    func lcdParagraphTransforms() throws {
        let animations = try lcdAnimations(slide: 2)
        let timeline = AnimationTimeline(animations: animations)
        let frame = timeline.frame(begun: 1, elapsed: 4.25, shapes: shapes(for: animations), slideSize: CGSize(width: 960, height: 540))
        let paragraph = try #require(frame.paragraphs[111]?[0])
        #expect(abs(paragraph.opacity - 0.5) < 0.001)
        #expect(paragraph.axisScale == CGSize(width: 1, height: 0.5))
        #expect(abs(paragraph.offset.height - 12.5636) < 0.01)
        // At 13 seconds it returns from a different layout-relative path,
        // replacing the held scale and motion from the earlier exit.
        let returned = timeline.frame(begun: 1, elapsed: 13.5, shapes: shapes(for: animations), slideSize: CGSize(width: 960, height: 540))
        let appearance = try #require(returned.paragraphs[111]?[0])
        #expect(appearance.opacity == 1)
        #expect(appearance.axisScale == CGSize(width: 1, height: 1))
        #expect(abs(appearance.offset.height) < 0.01)
    }



    @Test("Later layout paths replace held positions while additive paths sum")
    func successivePaths() {
        let first = ShapeAnimation(shapeID: 2, category: .motionPath, effect: .path(MotionPath(path: "M 0 0 L 0.2 0 E")), trigger: .withPrevious, duration: 1)
        let second = ShapeAnimation(shapeID: 2, category: .motionPath, effect: .path(MotionPath(path: "M 0.2 0 L 0.4 0 E")), trigger: .afterPrevious, duration: 1)
        let shapes = shapes(for: [first])
        let size = CGSize(width: 1_000, height: 500)
        let frame = AnimationTimeline(animations: [first, second]).frame(begun: 1, elapsed: 2, shapes: shapes, slideSize: size)
        #expect(frame.shapes[2]?.offset.width == 400)
        var additive = second
        additive.effect = .path(MotionPath(path: "M 0 0 L 0.4 0 E", isAdditive: true))
        let summed = AnimationTimeline(animations: [first, additive]).frame(begun: 1, elapsed: 2, shapes: shapes, slideSize: size)
        #expect(summed.shapes[2]?.offset.width == 600)
        var parent = second
        parent.effect = .path(MotionPath(path: "M 0.2 0 L 0.4 0.5 E", usesSlideOrigin: true))
        let absolute = AnimationTimeline(animations: [parent]).frame(begun: 1, elapsed: 2, shapes: shapes, slideSize: size)
        #expect(absolute.shapes[2]?.offset == CGSize(width: 340, height: 190))
    }

    @Test("Custom scale axes survive copy and duration edits") @MainActor
    func customScaleRoundTrip() throws {
        var presentation = Presentation.blank
        let shape = presentation.slides[0].shapes[0].shapeID
        let animation = ShapeAnimation(shapeID: shape, category: .emphasis, effect: .growShrink,
                                       scaling: AnimationScale(to: CGSize(width: 1, height: 0)))
        #expect(ShapeAnimation(copying: animation).scaling == animation.scaling)
        presentation.slides[0].animations = [animation]
        presentation.slides[0].areAnimationsModified = true
        presentation.slides[0].isModified = true
        var read = try reread(presentation)
        let state = EditorState()
        state.updateAnimation(read.slides[0].animations[0].id, in: &read) { $0.duration = 1.25 }
        let final = try reread(read).slides[0].animations[0]
        #expect(final.scaling?.to == CGSize(width: 1, height: 0))
        #expect(final.duration == 1.25)
    }

    @Test("Paragraph rendering moves wrapped text and bullets without moving its neighbour")
    func rendersParagraphTransforms() throws {
        let presentation = Presentation.blank
        let style = SlideStyleContext(presentation: presentation, slide: presentation.slides[0])
        var shape = SlideShape(shapeID: 2, name: "", kind: .shape,
                               frame: EMURect(x: 0, y: 0, width: 2_540_000, height: 2_540_000))
        var red = RunProperties()
        red.size = 2_000
        red.color = .rgb(0xFF0000)
        red.isStruckThrough = true
        var blue = red
        blue.color = .rgb(0x0000FF)
        var bullet = ParagraphProperties()
        bullet.bullet = .character("•")
        bullet.bulletColor = .rgb(0xFF0000)
        let body = TextBody(paragraphs: [
            Paragraph(properties: bullet, runs: [TextRun(text: "Wrapped text on several lines", properties: red)]),
            Paragraph(runs: [TextRun(text: "Neighbour", properties: blue)]),
        ])
        shape.text = body
        func pixels(_ appearances: [Int: AnimatedAppearance]) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                                                bytesPerRow: 1_600, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: 300)
            context.scaleBy(x: 1, y: -1)
            TextRenderer(style: style, slideNumber: 1).draw(body, shape: shape, sources: [],
                in: CGRect(x: 30, y: 30, width: 180, height: 230), context: context, paragraphAppearances: appearances)
            let data = try #require(context.data)
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 400 * 300 * 4))
        }
        func bounds(_ pixels: [UInt8], channel: Int) -> CGRect {
            var bounds = CGRect.null
            for y in 0..<300 {
                for x in 0..<400 {
                    let offset = (y * 400 + x) * 4
                    if pixels[offset + channel] > 30 && pixels[offset + 3] > 30 {
                        bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            return bounds
        }
        let normal = try pixels([:])
        let moved = try pixels([0: AnimatedAppearance(offset: CGSize(width: 40, height: 0))])
        let redBounds = bounds(normal, channel: 0)
        #expect(!redBounds.isNull)
        #expect(bounds(moved, channel: 0) == redBounds.offsetBy(dx: 40, dy: 0))
        #expect(bounds(moved, channel: 2) == bounds(normal, channel: 2))
        let hidden = try pixels([0: AnimatedAppearance(axisScale: CGSize(width: 1, height: 0))])
        #expect(bounds(hidden, channel: 0).isNull)
        #expect(bounds(hidden, channel: 2) == bounds(normal, channel: 2))
        let shrunk = try pixels([0: AnimatedAppearance(axisScale: CGSize(width: 1, height: 0.5))])
        #expect(abs(bounds(shrunk, channel: 0).height - redBounds.height / 2) <= 2)
        #expect(bounds(shrunk, channel: 2) == bounds(normal, channel: 2))
    }
}
