import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Morph transition")
struct SlideMorphTests {
    private static let namespaces = """
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
        xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" \
        xmlns:p159="http://schemas.microsoft.com/office/powerpoint/2015/09/main"
        """
    private static let morphXML = """
        <mc:AlternateContent><mc:Choice Requires="p159"><p:transition spd="slow" p14:dur="2000">\
        <p159:morph option="byObject"/></p:transition></mc:Choice>\
        <mc:Fallback><p:transition spd="slow"><p:fade/></p:transition></mc:Fallback></mc:AlternateContent>
        """

    private func shape(
        _ id: Int, _ name: String, x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 100, height: CGFloat = 100,
        rotation: Double = 0, color: UInt32? = nil, kind: SlideShape.Kind = .shape
    ) -> SlideShape {
        var shape = SlideShape(
            shapeID: id, name: name, kind: kind, frame: EMURect(points: CGRect(x: x, y: y, width: width, height: height))
        )
        shape.rotation = rotation
        shape.fill = color.map { .solid(.rgb($0)) }
        return shape
    }

    /// A blank deck's slide, twice, each with its own shapes.
    private func deck(_ first: [SlideShape], _ second: [SlideShape]) -> Presentation {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = first
        var next = Slide(layoutPath: presentation.slides[0].layoutPath, relationships: presentation.slides[0].relationships, shapes: second)
        next.transition = SlideTransition(effect: .morph, duration: 0.4)
        presentation.slides.append(next)
        return presentation
    }

    /// Where `transform` puts the corners of `rect`, as the box around them.
    private func box(_ rect: CGRect, _ transform: CGAffineTransform) -> CGRect {
        rect.applying(transform)
    }

    private func isNear(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 0.01 && abs(first.minY - second.minY) < 0.01
            && abs(first.width - second.width) < 0.01 && abs(first.height - second.height) < 0.01
    }

    @Test("A Morph is read as itself, with nothing to say about it")
    func parsing() throws {
        let root = try XMLLite.parse(Data("""
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \(Self.namespaces)><p:cSld/>\(Self.morphXML)</p:sld>
            """.utf8))
        let transition = try #require(SlideTransition(versions: PPTXReader.transitions(in: root)))
        #expect(transition.effect == .morph)
        #expect(transition.approximates == nil)
        #expect(transition.duration == 2)
        // With Reduce Motion on, nothing moves.
        #expect(transition.played(reduceMotion: true).effect == .fade(throughBlack: false))
        // Under the shapes the slides share, the rest cross-fades.
        let layers = transition.frame(progress: 0.5, size: CGSize(width: 960, height: 540)).layers
        #expect(layers.map(\.content) == [.outgoing, .incoming])
        #expect(layers[1].opacity == 0.5 && layers[1].transform == .identity)
    }

    @Test("A Morph set in Dazzle is written for PowerPoint 2019, with a fade for older versions, and read back")
    @MainActor
    func written() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let transition = SlideTransition(effect: .morph, duration: 1.5)
        state.setTransition(transition, in: &presentation)
        let saved = try PPTXWriter.data(from: presentation)
        let slide = try #require(try ZipArchive.entries(in: saved)["ppt/slides/slide1.xml"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(slide.contains("<mc:Choice Requires=\"p159\">"))
        #expect(slide.contains("xmlns:p159=\"http://schemas.microsoft.com/office/powerpoint/2015/09/main\""))
        #expect(slide.contains("p14:dur=\"1500\""))
        #expect(slide.contains("<p159:morph option=\"byObject\"/>"))
        #expect(slide.contains("<mc:Fallback><p:transition spd=\"slow\"><p:fade/></p:transition></mc:Fallback>"))
        let reread = try PPTXReader.presentation(from: saved)
        #expect(reread.slides[0].transition == transition)
        #expect(reread.unsupportedFeatures.features.isEmpty)
    }

    @Test("Shapes are paired by name: any two with a !! name, otherwise only the same kind of thing")
    func matching() {
        let picture = SlideShape.Kind.picture(SlideShape.Picture())
        let outgoing = Slide(layoutPath: "", shapes: [
            shape(2, "Box"), shape(3, "Box"), shape(4, "!!Hero"), shape(5, "Photo"), shape(6, "Gone"), shape(7, ""), shape(8, "Faded"),
        ])
        let incoming = Slide(layoutPath: "", shapes: [
            shape(12, "!!Hero", kind: picture), shape(13, "Photo", kind: picture), shape(14, "Box"), shape(15, "New"), shape(16, ""),
            shape(17, "Box"), shape(18, "Box"), shape(19, "Faded"),
        ])
        // An animation had taken "Faded" away before the slide was left.
        let left = AnimationFrame(shapes: [8: .hidden])
        let morph = SlideMorph(from: outgoing, to: incoming, outgoingFrame: left)
        // Back to front as the arriving slide has them; same-named shapes pair in order.
        #expect(morph.pairs.map(\.outgoing.shapeID) == [4, 2, 3])
        #expect(morph.pairs.map(\.incoming.shapeID) == [12, 14, 17])

        // The rest of each slide is drawn without them.
        #expect(morph.rest(of: .outgoing)?.shapes == [8: .hidden, 4: .hidden, 2: .hidden, 3: .hidden])
        #expect(morph.rest(of: .incoming)?.shapes == [12: .hidden, 14: .hidden, 17: .hidden])
        // And each on its own.
        #expect(Set(morph.alone(morph.pairs[0].incoming, of: .incoming).shapes.keys) == [13, 14, 15, 16, 17, 18, 19])
        #expect(SlideMorph(from: outgoing, to: Slide(layoutPath: "", shapes: [])).rest(of: .incoming) == nil)
    }

    @Test("A pair moves, resizes and turns the shorter way between its two places, both shapes in the same spot")
    func placement() throws {
        let from = shape(2, "Box", x: 100, y: 100, width: 100, height: 100, rotation: 350)
        let to = shape(3, "Box", x: 500, y: 300, width: 300, height: 200, rotation: 10)
        let morph = SlideMorph(from: Slide(layoutPath: "", shapes: [from]), to: Slide(layoutPath: "", shapes: [to]))
        let pair = try #require(morph.pairs.first)
        let start = morph.placement(of: pair, progress: 0)
        #expect(start.mix == 0)
        #expect(isNear(box(from.frame.points, start.outgoing), from.frame.points))
        let end = morph.placement(of: pair, progress: 1)
        #expect(end.mix == 1)
        #expect(isNear(box(to.frame.points, end.incoming), to.frame.points))
        // Half way: half way between the frames, and upright, having turned 10° of the 20° through 0°.
        let middle = morph.placement(of: pair, progress: 0.5)
        #expect(middle.mix == 0.5)
        let expected = CGRect(x: 300, y: 200, width: 200, height: 150)
        // Each shape's own turn is undone and the pair's put on, so with their own both sit upright in the same box.
        func drawn(_ shape: SlideShape, _ transform: CGAffineTransform) -> CGRect {
            let frame = shape.frame.points
            let own = CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(shape.rotation * .pi / 180)))
                .concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY))
            return frame.applying(own.concatenating(transform))
        }
        #expect(isNear(drawn(from, middle.outgoing), expected))
        #expect(isNear(drawn(to, middle.incoming), expected))
        // It eases in and out.
        #expect(morph.placement(of: pair, progress: 0.25).mix < 0.25)
        #expect(morph.placement(of: pair, progress: 0.75).mix > 0.75)
    }

    @Test("A pair is drawn solid on its way, in a colour between its two")
    func drawing() throws {
        let presentation = deck(
            [shape(2, "!!Box", x: 100, y: 100, width: 100, height: 100, color: 0xFF0000), shape(3, "Stays", x: 600, y: 300, color: 0x00FF00)],
            [shape(2, "!!Box", x: 300, y: 100, width: 100, height: 100, color: 0x0000FF)]
        )
        let morph = SlideMorph(from: presentation.slides[0], to: presentation.slides[1])
        let size = presentation.slideSize.points
        let width = Int(size.width), height = Int(size.height)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        morph.draw(progress: 0.5, in: context, size: size, presentation: presentation)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let offset = y * context.bytesPerRow + x * 4
            return (0..<4).map { Int(data[offset + $0]) }
        }
        // Half way between x 100 and 300, the box covers 200 to 300: solid, half red and half blue.
        let middle = pixel(250, 150)
        #expect(middle[3] == 255)
        #expect(abs(middle[0] - 128) < 12 && middle[1] < 12 && abs(middle[2] - 128) < 12)
        // Nothing where it started or will end, and nothing of the shape that is not shared.
        #expect(pixel(120, 150)[3] == 0)
        #expect(pixel(380, 150)[3] == 0)
        #expect(pixel(650, 350)[3] == 0)
    }

    @Test("The show finds a Morph's shared shapes as it moves onto the slide")
    @MainActor
    func playback() throws {
        let presentation = deck(
            [shape(2, "Box", x: 100, y: 100), shape(3, "Only here")],
            [shape(2, "Box", x: 400, y: 200), shape(4, "Only there")]
        )
        let session = PresentationSession()
        session.start(presentation, title: "Morph", fromSlide: 0, owner: UUID())
        session.next()
        let showing = try #require(session.transition)
        #expect(showing.transition.effect == .morph)
        #expect(showing.morph?.pairs.map(\.incoming.name) == ["Box"])
        // A tap finishes it.
        session.next()
        #expect(session.transition == nil && session.position == 1)
        session.end()
    }
}
