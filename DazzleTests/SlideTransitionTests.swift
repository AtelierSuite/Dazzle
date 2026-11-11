import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Slide transitions")
struct SlideTransitionTests {
    private static let namespaces = """
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \(newerNamespaces)
        """
    private static let newerNamespaces = """
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
        xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" \
        xmlns:p15="http://schemas.microsoft.com/office/powerpoint/2012/main" \
        xmlns:p159="http://schemas.microsoft.com/office/powerpoint/2015/09/main"
        """

    /// The transition a slide with `xml` after its shapes reads as.
    private func transition(_ xml: String) throws -> SlideTransition? {
        let root = try XMLLite.parse(Data("<p:sld \(Self.namespaces)><p:cSld/>\(xml)</p:sld>".utf8))
        return SlideTransition(versions: PPTXReader.transitions(in: root))
    }

    private func alternate(_ choice: String, requires: String = "p14", fallback: String = "<p:fade/>", attributes: String = "") -> String {
        """
        <mc:AlternateContent><mc:Choice Requires="\(requires)"><p:transition spd="slow" p14:dur="2000"\(attributes)>\(choice)</p:transition>\
        </mc:Choice><mc:Fallback><p:transition spd="slow"\(attributes)>\(fallback)</p:transition></mc:Fallback></mc:AlternateContent>
        """
    }

    @Test("PowerPoint's effects, their options and speeds are read")
    func parsing() throws {
        #expect(try transition("<p:transition/>") == nil)
        #expect(try transition("<p:transition><p:fade/></p:transition>") == SlideTransition(effect: .fade(throughBlack: false), duration: 0.5))
        #expect(try transition("<p:transition spd=\"med\"><p:fade thruBlk=\"1\"/></p:transition>")
            == SlideTransition(effect: .fade(throughBlack: true), duration: 0.75))
        #expect(try transition("<p:transition spd=\"slow\"><p:push dir=\"u\"/></p:transition>")?.effect == .push(.up))
        #expect(try transition("<p:transition><p:push/></p:transition>")?.effect == .push(.left))
        #expect(try transition("<p:transition><p:wipe dir=\"d\"/></p:transition>")?.effect == .wipe(.down))
        #expect(try transition("<p:transition><p:cover dir=\"rd\"/></p:transition>")?.effect == .cover(.rightDown))
        #expect(try transition("<p:transition><p:pull dir=\"r\"/></p:transition>")?.effect == .uncover(.right))
        #expect(try transition("<p:transition><p:split orient=\"vert\" dir=\"in\"/></p:transition>")?.effect
            == .split(vertical: true, outward: false))
        #expect(try transition("<p:transition><p:split/></p:transition>")?.effect == .split(vertical: false, outward: true))
        #expect(try transition("<p:transition><p:zoom dir=\"out\"/></p:transition>")?.effect == .zoom(outward: true))
        #expect(try transition("<p:transition><p:cut thruBlk=\"1\"/></p:transition>")?.effect == .cut(throughBlack: true))
        #expect(try transition("<p:transition><p:blinds dir=\"vert\"/></p:transition>")?.effect
            == .pattern(AnimationFilter("blinds(vertical)")!))
        #expect(try transition("<p:transition><p:checker/></p:transition>")?.effect == .pattern(AnimationFilter("checkerboard(across)")!))
        #expect(try transition("<p:transition><p:randomBar dir=\"vert\"/></p:transition>")?.effect
            == .pattern(AnimationFilter("randombar(vertical)")!))
        #expect(try transition("<p:transition><p:dissolve/></p:transition>")?.effect == .pattern(AnimationFilter("dissolve")!))
        #expect(try transition("<p:transition><p:wheel spokes=\"8\"/></p:transition>")?.effect == .pattern(AnimationFilter("wheel(8)")!))
        #expect(try transition("<p:transition><p:strips dir=\"rd\"/></p:transition>")?.effect
            == .pattern(AnimationFilter("strips(downRight)")!))
        #expect(try transition("<p:transition><p:comb dir=\"vert\"/></p:transition>")?.effect == .comb(vertical: true))
        #expect(try transition("<p:transition><p:random/></p:transition>")?.effect == .random)
        #expect(try transition("<p:transition advTm=\"3000\"><p:fade/></p:transition>")?.approximates == nil)
    }

    @Test("Newer effects are read from AlternateContent with their exact duration, and unknown ones fall back to a fade")
    func alternateContent() throws {
        let flash = try #require(try transition(alternate("<p14:flash/>")))
        #expect(flash.effect == .flash)
        #expect(flash.duration == 2)
        #expect(flash.approximates == nil)
        let doors = try #require(try transition(alternate("<p14:doors dir=\"vert\"/>")))
        #expect(doors.effect == .split(vertical: true, outward: true))
        // A vortex has no drawing: PowerPoint's own fallback is played, still for its duration.
        let vortex = try #require(try transition(alternate("<p14:vortex dir=\"r\"/>", fallback: "<p:push dir=\"r\"/>")))
        #expect(vortex.effect == .push(.right))
        #expect(vortex.duration == 2)
        #expect(vortex.approximates == "vortex")
        let curtains = try #require(try transition(alternate("<p15:prstTrans prst=\"curtains\"/>", requires: "p15")))
        #expect(curtains.effect == .fade(throughBlack: false))
        #expect(curtains.approximates == "curtains")
        let morph = try #require(try transition(alternate("<p159:morph option=\"byObject\"/>", requires: "p159")))
        #expect(morph.effect == .fade(throughBlack: false))
        #expect(morph.approximates == "morph")
        // With nothing better offered, still a fade rather than a cut.
        let ripple = try #require(try transition("<p:transition><p14:ripple/></p:transition>"))
        #expect(ripple.effect == .fade(throughBlack: false))
        #expect(ripple.approximates == "ripple")
    }

    @Test("Only transitions played as something else are noted")
    func notice() throws {
        let playable = try deck(slideXML: alternate("<p:push dir=\"u\"/>", attributes: " advTm=\"1500\""))
        #expect(playable.unsupportedFeatures.features.isEmpty)
        #expect(playable.slides[0].transition == SlideTransition(effect: .push(.up), duration: 2))
        #expect(playable.slides[0].autoAdvanceAfter == 1.5)
        let vortex = try deck(slideXML: alternate("<p14:vortex/>"))
        #expect(vortex.unsupportedFeatures.features == [.transitions])
    }

    @Test("Transitions are saved exactly as they were read, slide timing edits included")
    @MainActor
    func roundTrip() throws {
        let xml = alternate("<p14:vortex dir=\"r\"/>", attributes: " advClick=\"0\"")
        var presentation = try deck(slideXML: xml)
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let untouched = try transitionXML(in: PPTXWriter.data(from: presentation))
        #expect(untouched.contains("<p14:vortex dir=\"r\"/>"))
        #expect(untouched.contains("p14:dur=\"2000\""))
        state.setAutoAdvance(4, in: &presentation)
        let saved = try PPTXWriter.data(from: presentation)
        let edited = try transitionXML(in: saved)
        #expect(edited.contains("<p14:vortex dir=\"r\"/>"))
        #expect(edited.contains("advTm=\"4000\""))
        let reread = try PPTXReader.presentation(from: saved)
        #expect(reread.slides[0].transition == presentation.slides[0].transition)
        #expect(reread.slides[0].autoAdvanceAfter == 4)
        #expect(!reread.slides[0].advancesOnClick)
    }

    @Test("A transition set in Dazzle is written for every version of PowerPoint, and read back")
    @MainActor
    func written() throws {
        var presentation = try deck(slideXML: alternate("<p14:vortex/>"))
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let effects: [SlideTransition.Effect] = [
            .push(.down), .wipe(.right), .cover(.leftUp), .uncover(.up), .split(vertical: true, outward: false),
            .zoom(outward: true), .fade(throughBlack: true), .cut(throughBlack: true), .flash, .comb(vertical: true),
            .newsflash, .random, .pattern(AnimationFilter("blinds(vertical)")!), .pattern(AnimationFilter("checkerboard(down)")!),
            .pattern(AnimationFilter("dissolve")!), .pattern(AnimationFilter("wheel(2)")!), .pattern(AnimationFilter("strips(upRight)")!),
        ]
        for effect in effects {
            let transition = SlideTransition(effect: effect, duration: 1.25)
            state.setTransition(transition, in: &presentation)
            let saved = try PPTXWriter.data(from: presentation)
            let xml = try transitionXML(in: saved)
            #expect(!xml.contains("vortex"))
            #expect(xml.components(separatedBy: "<mc:AlternateContent").count == 2)
            #expect(try PPTXReader.presentation(from: saved).slides[0].transition == transition)
        }
        state.setTransition(nil, in: &presentation)
        let none = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(none.slides[0].transition == nil)
    }

    @Test("Each effect moves the slides as PowerPoint does")
    func frames() {
        let size = CGSize(width: 100, height: 50)
        func layers(_ effect: SlideTransition.Effect, _ progress: Double) -> [TransitionFrame.Layer] {
            SlideTransition(effect: effect, duration: 1).frame(progress: progress, size: size).layers
        }
        // Push up: the old slide leaves upwards as the new one arrives from below.
        let push = layers(.push(.up), 0.5)
        #expect(push.map(\.content) == [.outgoing, .incoming])
        #expect(push[0].transform.ty == -25)
        #expect(push[1].transform.ty == 25)
        #expect(layers(.push(.up), 1)[1].transform == .identity)
        // Cover from the right, uncover to the left.
        #expect(layers(.cover(.left), 0)[1].transform.tx == 100)
        #expect(layers(.uncover(.left), 1)[1].transform.tx == -100)
        #expect(layers(.uncover(.left), 0).map(\.content) == [.incoming, .outgoing])
        // A fade cross-fades; through black, each slide fades with black between.
        #expect(layers(.fade(throughBlack: false), 0.25)[1].opacity == 0.25)
        let black = layers(.fade(throughBlack: true), 0.25)
        #expect(black.map(\.content) == [.black, .outgoing, .incoming])
        #expect(black[1].opacity == 0.5 && black[2].opacity == 0)
        // A wipe to the left uncovers the new slide from the right edge.
        let wipe = layers(.wipe(.left), 0.5)
        #expect(wipe[1].clip?.boundingBoxOfPath == CGRect(x: 50, y: 0, width: 50, height: 50))
        // Patterns fill in partway, and completely by the end.
        let blinds = layers(.pattern(AnimationFilter("blinds(horizontal)")!), 0.5)
        #expect(blinds[1].clip?.contains(CGPoint(x: 50, y: 1), using: .evenOdd) == true)
        #expect(blinds[1].clip?.contains(CGPoint(x: 50, y: 6), using: .evenOdd) == false)
        #expect(layers(.split(vertical: true, outward: true), 1)[1].clip?.contains(CGPoint(x: 1, y: 1)) == true)
        // Comb strips come from alternate sides.
        let comb = layers(.comb(vertical: false), 0.5)
        #expect(comb.count == 9)
        #expect(comb[1].transform.tx == 50 && comb[2].transform.tx == -50)
        // Every moment of one effect has the same layers, for the web app to animate between.
        let effects: [SlideTransition.Effect] = [.zoom(outward: false), .zoom(outward: true), .newsflash, .flash, .cut(throughBlack: true)]
        for effect in effects {
            #expect(layers(effect, 0).map(\.content) == layers(effect, 1).map(\.content))
            #expect(layers(effect, 1).last?.opacity == 1)
        }
    }

    @Test("Reduce Motion cross-fades, and a random transition plays a real effect")
    func played() {
        let push = SlideTransition(effect: .push(.left), duration: 1)
        #expect(push.played(reduceMotion: true).effect == .fade(throughBlack: false))
        #expect(push.played(reduceMotion: true).duration == 1)
        #expect(push.played(reduceMotion: false) == push)
        #expect(SlideTransition(effect: .fade(throughBlack: true)).played(reduceMotion: true).effect == .fade(throughBlack: true))
        #expect(SlideTransition(effect: .cut(throughBlack: false)).isAnimated == false)
        let random = SlideTransition(effect: .random, duration: 1)
        for seed in 0..<20 { #expect(random.played(reduceMotion: false, seed: seed).effect != .random) }
        #expect(random.played(reduceMotion: true, seed: 3).effect == .fade(throughBlack: false))
    }

    @Test("The show plays the slide's transition, waits for it before moving on by itself, and a tap finishes it")
    @MainActor
    func playback() async throws {
        var presentation = Presentation.blank
        let state = EditorState()
        let layout = try #require(presentation.resources.orderedLayouts.last)
        state.addSlide(using: layout, in: &presentation)
        state.addSlide(using: layout, in: &presentation)
        presentation.slides[1].transition = SlideTransition(effect: .push(.left), duration: 0.4)
        presentation.slides[1].autoAdvanceAfter = 0.1
        let session = PresentationSession()
        session.start(presentation, title: "Transitions", fromSlide: 0, owner: UUID())
        #expect(session.transition == nil)
        session.next()
        #expect(session.position == 1)
        let showing = try #require(session.transition)
        #expect(showing.outgoing.id == presentation.slides[0].id)
        #expect(session.isAnimating)
        #expect(abs(showing.progress(at: showing.startedAt.addingTimeInterval(0.2)) - 0.5) < 0.001)
        // Moving on by itself counts from the end of the transition.
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.position == 1)
        try await Task.sleep(for: .milliseconds(700))
        #expect(session.position == 2)
        #expect(session.transition == nil)
        // A tap during a transition finishes it rather than moving on.
        session.go(toPosition: 0)
        session.go(toPosition: 1)
        #expect(session.transition != nil)
        session.next()
        #expect(session.transition == nil && session.position == 1)
        // Going back has no transition.
        session.next()
        session.previous()
        #expect(session.transition == nil)
        session.end()
    }

    // MARK: - Decks

    /// A one-slide deck whose slide has `slideXML` after its colour mapping.
    private func deck(slideXML: String) throws -> Presentation {
        var entries = try ZipArchive.entries(in: PPTXWriter.data(from: .blank))
        let path = "ppt/slides/slide1.xml"
        var slide = try #require(entries[path].flatMap { String(data: $0, encoding: .utf8) })
        let anchor = slide.range(of: "</p:clrMapOvr>") ?? slide.range(of: "</p:cSld>")
        let end = try #require(anchor).upperBound
        slide.insert(contentsOf: slideXML, at: end)
        // The prefixes the transition uses, on the slide.
        slide = slide.replacingOccurrences(of: "<p:sld ", with: "<p:sld \(Self.newerNamespaces) ")
        entries[path] = Data(slide.utf8)
        let archive = try ZipArchive.archive(entries: entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        return try PPTXReader.presentation(from: archive)
    }

    /// Everything from a saved deck's first slide's first transition to its last.
    private func transitionXML(in data: Data) throws -> String {
        let entries = try ZipArchive.entries(in: data)
        let slide = try #require(entries["ppt/slides/slide1.xml"].flatMap { String(data: $0, encoding: .utf8) })
        guard let start = slide.range(of: "<mc:AlternateContent") ?? slide.range(of: "<p:transition"),
              let end = slide.range(of: "</mc:AlternateContent>", options: .backwards)
                ?? slide.range(of: "</p:transition>", options: .backwards) else { return "" }
        return String(slide[start.lowerBound..<end.upperBound])
    }
}
