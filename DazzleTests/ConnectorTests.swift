import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Connectors attached to shapes")
@MainActor
struct ConnectorTests {
    /// A slide with two rectangles, `first` at the left and `second` at the
    /// right and lower, and a connector of `preset` between them.
    @MainActor
    private struct Deck {
        var presentation = Presentation.blank
        let state = EditorState()
        var first: SlideShape.ID
        var second: SlideShape.ID
        var connector: SlideShape.ID

        init(_ preset: String = "bentConnector3") {
            state.selectSlide(presentation.slides[0].id)
            state.insertShape("rect", in: &presentation)
            first = presentation.slides[0].shapes.last!.id
            state.setFrame(CGRect(x: 100, y: 100, width: 100, height: 60), of: first, in: &presentation)
            state.insertShape("rect", in: &presentation)
            second = presentation.slides[0].shapes.last!.id
            state.setFrame(CGRect(x: 400, y: 300, width: 100, height: 60), of: second, in: &presentation)
            state.insertShape(preset, in: &presentation)
            connector = presentation.slides[0].shapes.last!.id
        }

        var slide: Slide { presentation.slides[0] }
        func shape(_ id: SlideShape.ID) -> SlideShape { slide.shapes.first { $0.id == id }! }

        /// Attaches the connector's `end` to one of a shape's sites: 0 top, 1 left, 2 bottom, 3 right.
        mutating func attach(_ end: SlideShape.ConnectorEnd, to id: SlideShape.ID, site: Int) {
            let connection = SlideShape.Connection(shapeID: shape(id).shapeID, site: site)
            state.setConnectorEnd(end, of: connector, to: .zero, connection: connection, in: &presentation)
        }
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.01 }

    @Test("A rectangle has a site in the middle of each side, and a turned shape's turn with it")
    func sites() {
        var shape = SlideShape(shapeID: 7, name: "", kind: .shape, frame: EMURect(points: CGRect(x: 100, y: 100, width: 200, height: 100)))
        let sites = shape.connectionSites
        #expect(sites.map(\.connection.site) == [0, 1, 2, 3])
        #expect(near(sites[0].point, CGPoint(x: 200, y: 100)) && sites[0].angle == 270)
        #expect(near(sites[1].point, CGPoint(x: 100, y: 150)) && sites[1].angle == 180)
        #expect(near(sites[2].point, CGPoint(x: 200, y: 200)) && sites[2].angle == 90)
        #expect(near(sites[3].point, CGPoint(x: 300, y: 150)) && sites[3].angle == 0)
        shape.rotation = 90
        #expect(near(shape.connectionSites[0].point, CGPoint(x: 250, y: 150)))
        #expect(abs(shape.connectionSites[0].angle - 0) < 0.001 || abs(shape.connectionSites[0].angle - 360) < 0.001)
        shape.rotation = 0
        shape.geometry = .preset("ellipse", adjustments: [:])
        #expect(shape.connectionSites.count == 8)
        // A freeform is joined where a rectangle would be.
        shape.geometry = .custom([])
        #expect(shape.connectionSites.count == 4)
    }

    @Test("A new connector is a p:cxnSp, and what it is attached to is written and read back")
    func roundTrip() throws {
        var deck = Deck()
        deck.attach(.start, to: deck.first, site: 3)
        deck.attach(.end, to: deck.second, site: 1)
        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: deck.presentation))
        let connector = try #require(copy.slides[0].shapes.last)
        #expect(connector.kind == .connector)
        #expect(connector.startConnection == SlideShape.Connection(shapeID: deck.shape(deck.first).shapeID, site: 3))
        #expect(connector.endConnection == SlideShape.Connection(shapeID: deck.shape(deck.second).shapeID, site: 1))
        #expect(connector.geometry.presetName == "bentConnector3")
        let source = try #require(connector.source)
        #expect(source.contains("<p:cxnSp>") && source.contains("<a:stCxn id=") && source.contains("<a:endCxn id="))
        let ends = connector.connectorEnds
        #expect(near(ends.start, CGPoint(x: 200, y: 130)) && near(ends.end, CGPoint(x: 400, y: 330)))

        // Letting an end go takes its connection out of the file.
        var edited = copy
        let state = EditorState()
        state.selectSlide(edited.slides[0].id)
        state.setConnectorEnd(.end, of: connector.id, to: CGPoint(x: 350, y: 200), connection: nil, in: &edited)
        let detached = try #require(try PPTXReader.presentation(from: PPTXWriter.data(from: edited)).slides[0].shapes.last)
        #expect(detached.startConnection != nil && detached.endConnection == nil)
        #expect(detached.source?.contains("endCxn") == false)
        #expect(near(detached.connectorEnds.end, CGPoint(x: 350, y: 200)))
    }

    @Test("Moving, resizing and turning a shape takes its connectors with it", arguments: ["line", "bentConnector3", "curvedConnector3"])
    func follows(preset: String) throws {
        var deck = Deck(preset)
        deck.attach(.start, to: deck.first, site: 3)
        deck.attach(.end, to: deck.second, site: 1)
        // Moved.
        deck.state.setFrame(CGRect(x: 420, y: 80, width: 100, height: 60), of: deck.second, in: &deck.presentation)
        var ends = deck.shape(deck.connector).connectorEnds
        #expect(near(ends.start, CGPoint(x: 200, y: 130)) && near(ends.end, CGPoint(x: 420, y: 110)))
        // Resized.
        deck.state.setFrame(CGRect(x: 100, y: 100, width: 160, height: 200), of: deck.first, in: &deck.presentation)
        ends = deck.shape(deck.connector).connectorEnds
        #expect(near(ends.start, CGPoint(x: 260, y: 200)) && near(ends.end, CGPoint(x: 420, y: 110)))
        // Turned a quarter: the right side's site is now at the bottom.
        deck.state.setTransform(frame: CGRect(x: 100, y: 100, width: 160, height: 200), rotation: 90, of: deck.first, in: &deck.presentation)
        ends = deck.shape(deck.connector).connectorEnds
        #expect(near(ends.start, CGPoint(x: 180, y: 280)))
        // Where it ends up is what is saved.
        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: deck.presentation))
        let saved = try #require(copy.slides[0].shapes.last)
        #expect(near(saved.connectorEnds.start, CGPoint(x: 180, y: 280)) && near(saved.connectorEnds.end, CGPoint(x: 420, y: 110)))
        #expect(saved.geometry == deck.shape(deck.connector).geometry)
        #expect(saved.startConnection != nil && saved.endConnection != nil)
    }

    @Test("An elbow is routed by the way the sites it joins face")
    func routes() {
        var deck = Deck()
        // Facing each other: one step across.
        deck.attach(.start, to: deck.first, site: 3)
        deck.attach(.end, to: deck.second, site: 1)
        #expect(deck.shape(deck.connector).geometry == .preset("bentConnector3", adjustments: [:]))
        // Out of the right, into the top: one corner.
        deck.attach(.end, to: deck.second, site: 0)
        #expect(deck.shape(deck.connector).geometry.presetName == "bentConnector2")
        // Out of the right, into the far side: past it and back.
        deck.attach(.end, to: deck.second, site: 3)
        var connector = deck.shape(deck.connector)
        #expect(connector.geometry.presetName == "bentConnector3")
        #expect((connector.geometry.adjustments["adj1"] ?? 0) > 100_000)
        // Out of the bottom: the connector is turned to leave downwards.
        deck.attach(.start, to: deck.first, site: 2)
        deck.attach(.end, to: deck.second, site: 0)
        connector = deck.shape(deck.connector)
        #expect(connector.rotation == 90 && connector.geometry.presetName == "bentConnector3")
        #expect(near(connector.connectorEnds.start, CGPoint(x: 150, y: 160)) && near(connector.connectorEnds.end, CGPoint(x: 450, y: 300)))
        // The shape moved behind the site: out, round and back in.
        deck.attach(.start, to: deck.first, site: 3)
        deck.attach(.end, to: deck.second, site: 1)
        deck.state.setFrame(CGRect(x: 100, y: 300, width: 100, height: 60), of: deck.first, in: &deck.presentation)
        deck.state.setFrame(CGRect(x: 100, y: 100, width: 100, height: 60), of: deck.second, in: &deck.presentation)
        connector = deck.shape(deck.connector)
        #expect(connector.geometry.presetName == "bentConnector5")
        #expect(near(connector.connectorEnds.start, CGPoint(x: 200, y: 330)) && near(connector.connectorEnds.end, CGPoint(x: 100, y: 130)))
    }

    @Test("A corner placed between the ends stays where it was put while the connector keeps its shape")
    func keepsAdjustment() {
        var deck = Deck()
        deck.attach(.start, to: deck.first, site: 3)
        deck.attach(.end, to: deck.second, site: 1)
        deck.state.updateShape(deck.connector, edits: [.geometry], in: &deck.presentation) {
            $0.geometry = .preset("bentConnector3", adjustments: ["adj1": 25_000])
        }
        deck.state.setFrame(CGRect(x: 500, y: 320, width: 100, height: 60), of: deck.second, in: &deck.presentation)
        #expect(deck.shape(deck.connector).geometry == .preset("bentConnector3", adjustments: ["adj1": 25_000]))
    }

    @Test("Moving a connector off its shapes, or deleting a shape, lets its ends go")
    func detaches() {
        var deck = Deck("line")
        deck.attach(.start, to: deck.first, site: 3)
        deck.attach(.end, to: deck.second, site: 1)
        let frame = deck.shape(deck.connector).frame.points
        deck.state.setFrame(frame.offsetBy(dx: 0, dy: 40), of: deck.connector, in: &deck.presentation)
        #expect(deck.shape(deck.connector).startConnection == nil && deck.shape(deck.connector).endConnection == nil)
        #expect(deck.shape(deck.connector).frame.points == frame.offsetBy(dx: 0, dy: 40))

        deck.attach(.start, to: deck.first, site: 3)
        deck.attach(.end, to: deck.second, site: 1)
        deck.state.selectedShapeID = deck.second
        deck.state.deleteSelectedShape(in: &deck.presentation)
        #expect(deck.shape(deck.connector).startConnection != nil && deck.shape(deck.connector).endConnection == nil)
    }

    @Test("Shapes moved together keep their connector, and copies are joined to each other")
    func movesAndCopiesTogether() {
        var deck = Deck()
        deck.attach(.start, to: deck.first, site: 3)
        deck.attach(.end, to: deck.second, site: 1)
        let ids = [deck.first, deck.second, deck.connector]
        let frames = Dictionary(uniqueKeysWithValues: ids.map { ($0, deck.shape($0).frame.points.offsetBy(dx: 30, dy: 20)) })
        deck.state.setFrames(frames, in: &deck.presentation)
        var connector = deck.shape(deck.connector)
        #expect(connector.startConnection != nil && connector.endConnection != nil)
        #expect(near(connector.connectorEnds.start, CGPoint(x: 230, y: 150)))

        deck.state.selectedShapeIDs = ids
        deck.state.duplicateSelectedShape(in: &deck.presentation)
        let copies = deck.slide.shapes.suffix(3)
        connector = copies.first { $0.kind == .connector }!
        let others = Set(copies.filter { $0.kind != .connector }.map(\.shapeID))
        #expect(others.contains(connector.startConnection?.shapeID ?? 0) && others.contains(connector.endConnection?.shapeID ?? 0))

        // A connector copied alone is attached to nothing.
        deck.state.selectedShapeIDs = [deck.connector]
        deck.state.duplicateSelectedShape(in: &deck.presentation)
        #expect(deck.slide.shapes.last?.startConnection == nil && deck.slide.shapes.last?.endConnection == nil)
    }

    @Test("Elbows with two and four corners, and curves, are drawn from their definitions")
    func drawn() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        func stroked(_ name: String, _ adjustments: [String: Int] = [:]) -> CGPath {
            PresetGeometry.path(name, adjustments: adjustments, in: rect)
                .copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        }
        // Along the top and down the right.
        #expect(stroked("bentConnector2").contains(CGPoint(x: 100, y: 50)) && !stroked("bentConnector2").contains(CGPoint(x: 50, y: 50)))
        // Down the middle to below the bottom, across and back up.
        let four = stroked("bentConnector4", ["adj2": 120_000])
        #expect(four.contains(CGPoint(x: 75, y: 120)) && four.contains(CGPoint(x: 100, y: 110)))
        // A quarter curve keeps to the far corner.
        #expect(!stroked("curvedConnector2").contains(CGPoint(x: 50, y: 50)))
    }
}
