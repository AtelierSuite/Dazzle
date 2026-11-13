#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A place on a shape where a connector can be attached, on the slide.
public struct ConnectionSite: Equatable, Sendable {
    /// The shape and which of its sites this is.
    public var connection: SlideShape.Connection
    /// Where it is, in slide points.
    public var point: CGPoint
    /// The way a connector leaves it, in degrees clockwise from rightwards.
    public var angle: Double
}

extension SlideShape {
    /// One end of a connector.
    public enum ConnectorEnd: Sendable, CaseIterable {
        case start
        case end
    }

    /// Whether connectors can be attached to it. Connectors join the members
    /// of a group, never the group itself.
    public var takesConnections: Bool {
        guard !isHidden else { return false }
        switch kind {
        case .connector, .group, .diagram: return false
        case .shape, .picture, .table, .chart, .unsupported: return true
        }
    }

    public subscript(connection end: ConnectorEnd) -> Connection? {
        get { end == .start ? startConnection : endConnection }
        set {
            if end == .start { startConnection = newValue } else { endConnection = newValue }
        }
    }

    /// A direction in the shape's own space as it lies on the slide, once
    /// the shape is flipped and turned.
    private func onSlide(direction: CGPoint) -> CGPoint {
        Self.turned(
            CGPoint(x: flipsHorizontally ? -direction.x : direction.x, y: flipsVertically ? -direction.y : direction.y),
            by: rotation
        )
    }

    /// A point of the unturned frame where it lies on the slide, in points.
    private func onSlide(_ point: CGPoint) -> CGPoint {
        let frame = self.frame.points
        let offset = onSlide(direction: CGPoint(x: point.x - frame.midX, y: point.y - frame.midY))
        return CGPoint(x: frame.midX + offset.x, y: frame.midY + offset.y)
    }

    /// `vector` turned `degrees` clockwise, in a y-down space.
    private static func turned(_ vector: CGPoint, by degrees: Double) -> CGPoint {
        guard degrees != 0 else { return vector }
        let radians = degrees * .pi / 180
        return CGPoint(
            x: vector.x * cos(radians) - vector.y * sin(radians), y: vector.x * sin(radians) + vector.y * cos(radians)
        )
    }

    /// Where connectors can be attached to the shape, in the order a
    /// connector counts them, for a shape that stands on the slide itself.
    public var connectionSites: [ConnectionSite] {
        guard takesConnections else { return [] }
        let sites = PresetGeometry.connectionSites(
            geometry.presetName, adjustments: geometry.adjustments, in: frame.points
        )
        return sites.enumerated().map { index, site in
            let radians = Double(site.angle) * .pi / 180
            let direction = onSlide(direction: CGPoint(x: cos(radians), y: sin(radians)))
            return ConnectionSite(
                connection: Connection(shapeID: shapeID, site: index), point: onSlide(site.point),
                angle: Self.normalized(atan2(direction.y, direction.x) * 180 / .pi)
            )
        }
    }

    /// Where a connector's two ends are on the slide, in points. Every
    /// connector runs from the top left of its frame to the bottom right,
    /// before it is flipped and turned.
    public var connectorEnds: (start: CGPoint, end: CGPoint) {
        let frame = self.frame.points
        return (onSlide(CGPoint(x: frame.minX, y: frame.minY)), onSlide(CGPoint(x: frame.maxX, y: frame.maxY)))
    }

    /// How far past a shape an elbow runs before turning back, in points.
    private static let stub = 18.0

    /// Puts a connector's ends at `start` and `end`, in slide points. An
    /// elbow or curved connector attached at both ends, leaving its shapes
    /// at the angles given, is routed afresh: out of each shape the way its
    /// site faces, round by as many corners as that takes. Anything else is
    /// stretched between the two points, turned as it was.
    public mutating func routeConnector(from start: CGPoint, to end: CGPoint, leaving: Double? = nil, arriving: Double? = nil) {
        let name = geometry.presetName ?? ""
        let family = ["bentConnector", "curvedConnector"].first { name.hasPrefix($0) }
        var turn = Self.normalized(rotation)
        var routed: (leaving: CGPoint, arriving: CGPoint)?
        if let family, !family.isEmpty, let leaving, let arriving {
            let out = Self.axis(leaving)
            // Every elbow leaves its first end along its own width.
            turn = out.x == 0 ? (turn == 270 ? 270 : 90) : (turn == 180 ? 180 : 0)
            routed = (out, Self.axis(arriving))
        }
        let span = Self.turned(CGPoint(x: end.x - start.x, y: end.y - start.y), by: -turn)
        let flipsHorizontally = span.x < 0
        let flipsVertically = span.y < 0
        let width = abs(span.x)
        let height = abs(span.y)

        if let family, let routed {
            /// A direction on the slide as the unflipped, unturned connector sees it.
            func own(_ direction: CGPoint) -> CGPoint {
                let local = Self.turned(direction, by: -turn)
                return CGPoint(x: flipsHorizontally ? -local.x : local.x, y: flipsVertically ? -local.y : local.y)
            }
            /// An adjust value that puts a corner a stub's length past the far side, or before the near one.
            func past(_ length: Double) -> Int { Self.adjustValue((length + Self.stub) / max(length, 0.01)) }
            func before(_ length: Double) -> Int { Self.adjustValue(-Self.stub / max(length, 0.01)) }
            let leavesToward = own(routed.leaving).x > 0
            let faces = own(routed.arriving)
            let corners: Int
            var adjustments: [String: Int]
            if abs(faces.x) > 0.5 {
                if faces.x < 0 {
                    // The far site faces back at the connector: one step across.
                    (corners, adjustments) = (3, ["adj1": leavesToward ? 50_000 : before(width)])
                } else if leavesToward {
                    (corners, adjustments) = (3, ["adj1": past(width)])
                } else {
                    (corners, adjustments) = (5, ["adj1": before(width), "adj2": 50_000, "adj3": past(width)])
                }
            } else if faces.y < 0 {
                (corners, adjustments) = leavesToward ? (2, [:]) : (4, ["adj1": before(width), "adj2": 50_000])
            } else {
                (corners, adjustments) = (4, ["adj1": leavesToward ? 50_000 : before(width), "adj2": past(height)])
            }
            let preset = family + String(corners)
            // A corner someone placed between the ends stays where they put it
            // while the connector keeps its shape.
            let keepsShape = preset == name && turn == Self.normalized(rotation)
                && flipsHorizontally == self.flipsHorizontally && flipsVertically == self.flipsVertically
            for (key, value) in adjustments where value == 50_000 {
                if keepsShape, let placed = geometry.adjustments[key], (0...100_000).contains(placed) {
                    adjustments[key] = placed
                } else {
                    adjustments[key] = nil
                }
            }
            let geometry = ShapeGeometry.preset(preset, adjustments: adjustments)
            if geometry != self.geometry {
                self.geometry = geometry
                edits.insert(.geometry)
            }
        }

        let frame = EMURect(points: CGRect(
            x: (start.x + end.x - width) / 2, y: (start.y + end.y - height) / 2, width: width, height: height
        ))
        guard frame != self.frame || turn != rotation || flipsHorizontally != self.flipsHorizontally
            || flipsVertically != self.flipsVertically || !hasOwnFrame else { return }
        self.frame = frame
        rotation = turn
        self.flipsHorizontally = flipsHorizontally
        self.flipsVertically = flipsVertically
        hasOwnFrame = true
        edits.insert(.transform)
    }

    /// The nearest of right, down, left and up to an angle in degrees clockwise from rightwards.
    private static func axis(_ angle: Double) -> CGPoint {
        switch Int((normalized(angle) / 90).rounded()) % 4 {
        case 1: CGPoint(x: 0, y: 1)
        case 2: CGPoint(x: -1, y: 0)
        case 3: CGPoint(x: 0, y: -1)
        default: CGPoint(x: 1, y: 0)
        }
    }

    /// A fraction of a connector's width or height as an adjust value, kept within reason.
    private static func adjustValue(_ fraction: Double) -> Int {
        Int((min(max(fraction, -1_000), 1_000) * 100_000).rounded())
    }
}

extension Array where Element == SlideShape {
    /// Makes copies of connectors attach to the copies of the shapes they
    /// joined. `ids` gives each copied shape's new `shapeID` by its old one;
    /// an end attached to a shape that was not copied is let go.
    public mutating func reconnect(_ ids: [Int: Int]) {
        for index in indices where self[index].startConnection != nil || self[index].endConnection != nil {
            for end in SlideShape.ConnectorEnd.allCases {
                guard let connection = self[index][connection: end] else { continue }
                self[index][connection: end] = ids[connection.shapeID].map {
                    SlideShape.Connection(shapeID: $0, site: connection.site)
                }
            }
            self[index].edits.insert(.connections)
        }
    }
}

extension Slide {
    /// Every shape a connector can be attached to, as it stands on the
    /// slide: the members of groups where their groups show them.
    public var connectableShapes: [SlideShape] {
        func gather(_ shapes: [SlideShape]) -> [SlideShape] {
            shapes.flatMap { shape -> [SlideShape] in
                guard !shape.isHidden else { return [] }
                if case .group(let group) = shape.kind {
                    return gather(group.children.map { SlideShape.ungrouped($0, from: shape, childFrame: group.childFrame) })
                }
                return shape.takesConnections ? [shape] : []
            }
        }
        return gather(shapes)
    }

    /// Each connectable shape's sites, by its `shapeID`.
    private var connectionSites: [Int: [ConnectionSite]] {
        Dictionary(connectableShapes.map { ($0.shapeID, $0.connectionSites) }) { first, _ in first }
    }

    /// The site nearest `point`, in slide points, if one is within `distance`.
    public func connectionSite(near point: CGPoint, within distance: CGFloat) -> ConnectionSite? {
        connectableShapes.flatMap(\.connectionSites)
            .map { (site: $0, distance: hypot($0.point.x - point.x, $0.point.y - point.y)) }
            .filter { $0.distance <= distance }
            .min { $0.distance < $1.distance }?.site
    }

    /// The sites of every shape `point` is on or within `margin` of, to
    /// show while the end of a connector is dragged by.
    public func connectionSites(around point: CGPoint, margin: CGFloat) -> [ConnectionSite] {
        connectableShapes.filter { $0.boundingBox.insetBy(dx: -margin, dy: -margin).contains(point) }
            .flatMap(\.connectionSites)
    }

    /// Makes connectors go with the shapes they are attached to, after a
    /// change from `before`: an end whose site has moved moves with it, an
    /// end pulled off its site by moving the connector is let go, and so is
    /// one whose shape is gone. Connectors inside groups stay as they are.
    public mutating func followConnections(from before: Slide) {
        guard shapes.contains(where: { $0.kind == .connector && ($0.startConnection != nil || $0.endConnection != nil) }) else {
            return
        }
        let sites = connectionSites
        let sitesBefore = before.connectionSites
        let shapesBefore = Dictionary(before.shapes.map { ($0.id, $0) }) { first, _ in first }
        for index in shapes.indices where shapes[index].kind == .connector && shapes[index].isEditable {
            var connector = shapes[index]
            guard connector.startConnection != nil || connector.endConnection != nil,
                  let old = shapesBefore[connector.id] else { continue }
            let wasMoved = old.frame != connector.frame || old.rotation != connector.rotation
                || old.flipsHorizontally != connector.flipsHorizontally || old.flipsVertically != connector.flipsVertically
            let ends = connector.connectorEnds
            var points = [ends.start, ends.end]
            var angles: [Double?] = [nil, nil]
            var follows = false
            for (place, end) in SlideShape.ConnectorEnd.allCases.enumerated() {
                guard let connection = connector[connection: end] else { continue }
                guard let shapeSites = sites[connection.shapeID], shapeSites.indices.contains(connection.site) else {
                    connector[connection: end] = nil
                    connector.edits.insert(.connections)
                    continue
                }
                let site = shapeSites[connection.site]
                angles[place] = site.angle
                guard hypot(site.point.x - points[place].x, site.point.y - points[place].y) > 0.05 else { continue }
                let siteBefore = sitesBefore[connection.shapeID].flatMap { $0.indices.contains(connection.site) ? $0[connection.site] : nil }
                if siteBefore != site || old[connection: end] != connection {
                    points[place] = site.point
                    follows = true
                } else if wasMoved {
                    connector[connection: end] = nil
                    connector.edits.insert(.connections)
                    angles[place] = nil
                }
            }
            if follows {
                connector.routeConnector(from: points[0], to: points[1], leaving: angles[0], arriving: angles[1])
            }
            if connector != shapes[index] { shapes[index] = connector }
        }
    }

    /// Moves one end of a connector to `point`, in slide points, attaching
    /// it to `connection`'s site, or with `nil`, to nothing.
    public mutating func setConnectorEnd(
        _ end: SlideShape.ConnectorEnd, of id: SlideShape.ID, to point: CGPoint, connection: SlideShape.Connection?
    ) {
        guard let index = shapes.firstIndex(where: { $0.id == id }), shapes[index].kind == .connector else { return }
        var connector = shapes[index]
        let sites = connectionSites
        func site(_ connection: SlideShape.Connection?) -> ConnectionSite? {
            guard let connection, let shapeSites = sites[connection.shapeID], shapeSites.indices.contains(connection.site) else {
                return nil
            }
            return shapeSites[connection.site]
        }
        let attached = site(connection)
        if connector[connection: end] != attached?.connection {
            connector[connection: end] = attached?.connection
            connector.edits.insert(.connections)
        }
        let ends = connector.connectorEnds
        let moved = attached?.point ?? point
        let other = site(connector[connection: end == .start ? .end : .start])
        if end == .start {
            connector.routeConnector(from: moved, to: ends.end, leaving: attached?.angle, arriving: other?.angle)
        } else {
            connector.routeConnector(from: ends.start, to: moved, leaving: other?.angle, arriving: attached?.angle)
        }
        shapes[index] = connector
    }
}
