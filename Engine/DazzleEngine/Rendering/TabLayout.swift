import Foundation

/// Where a paragraph's tabs stop, worked out the same way wherever text is laid out.
public enum TabLayout {
    /// A stop, in points from the left of the text, insets taken off.
    public struct Stop: Equatable, Sendable {
        public var location: Double
        public var alignment: TabStop.Alignment

        public init(location: Double, alignment: TabStop.Alignment) {
            self.location = location
            self.alignment = alignment
        }
    }

    /// What a decimal stop lines the text up on.
    public static let decimalSeparator: Character = "."

    /// Points between the default stops past the paragraph's own: an inch unless it says otherwise.
    public static func defaultInterval(_ properties: ParagraphProperties) -> Double {
        EMU.points(properties.defaultTabSize ?? 914_400)
    }

    /// Where the tab after a bullet takes the text: to the margin, or past the
    /// bullet when it hangs into nothing.
    public static func bulletTab(_ properties: ParagraphProperties, fontSize: Double) -> Double {
        let margin = EMU.points(properties.marginLeft ?? 0)
        let firstLine = max(margin + EMU.points(properties.indent ?? 0), 0)
        return margin > firstLine ? margin : firstLine + fontSize * 0.6
    }

    /// The farthest a line runs on a slide, in points: the largest slide PowerPoint makes is 56 inches wide.
    static let longestLine = 4_032.0

    /// The paragraph's stops, in order: its own, the margin, where the tab
    /// after a bullet or on a hanging first line lands, and past those the
    /// default stops, which fall on multiples of the default tab size from
    /// the left of the text rather than from the last stop before them.
    /// A bulleted paragraph's text starts past its bullet, so stops short of
    /// there are left out and the bullet's tab always reaches the margin.
    public static func stops(_ properties: ParagraphProperties, fontSize: Double, hasBullet: Bool) -> [Stop] {
        var stops = ownStops(properties, fontSize: fontSize, hasBullet: hasBullet)
        let interval = defaultInterval(properties)
        guard interval > 0 else { return stops }
        let last = stops.last?.location ?? 0
        var location = (floor(last / interval + 0.001) + 1) * interval
        while location <= longestLine, stops.count < 256 {
            stops.append(Stop(location: location, alignment: .left))
            location += interval
        }
        return stops
    }

    /// The paragraph's own stops and the margin's, without the default ones past them.
    public static func ownStops(_ properties: ParagraphProperties, fontSize: Double, hasBullet: Bool) -> [Stop] {
        let hanging = hasBullet ? bulletTab(properties, fontSize: fontSize) : EMU.points(properties.marginLeft ?? 0)
        var stops = (properties.tabStops ?? []).map { Stop(location: EMU.points($0.position), alignment: $0.alignment) }
        if hasBullet { stops.removeAll { $0.location <= hanging + 0.01 } }
        if !stops.contains(where: { abs($0.location - hanging) < 0.01 }) {
            stops.append(Stop(location: hanging, alignment: .left))
        }
        return stops.sorted { $0.location < $1.location }
    }
}
