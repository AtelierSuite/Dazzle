import Foundation

/// The theme, masters and layouts a presentation's slides are built on.
/// Read once with the file; Dazzle does not edit them.
public final class DeckResources: Equatable, Sendable {
    public let masters: [String: SlideMaster]
    public let layouts: [String: SlideLayout]
    /// Layouts in the order the first master lists them, for New Slide.
    public let layoutOrder: [String]
    /// `p:defaultTextStyle`: the base of every text style.
    public let defaultTextStyle: ListStyle
    public let notesMasterPath: String?
    /// Table styles the file defines, by id.
    public let tableStyles: [String: TableStyle]
    /// Fonts the file carries inside it.
    public let embeddedFonts: EmbeddedFonts

    public init(
        masters: [String: SlideMaster], layouts: [String: SlideLayout], layoutOrder: [String],
        defaultTextStyle: ListStyle, notesMasterPath: String?, tableStyles: [String: TableStyle] = [:],
        embeddedFonts: EmbeddedFonts = .none
    ) {
        self.tableStyles = tableStyles
        self.embeddedFonts = embeddedFonts
        self.masters = masters
        self.layouts = layouts
        self.layoutOrder = layoutOrder
        self.defaultTextStyle = defaultTextStyle
        self.notesMasterPath = notesMasterPath
    }

    public static func == (lhs: DeckResources, rhs: DeckResources) -> Bool { lhs === rhs }

    public func master(for layout: SlideLayout?) -> SlideMaster? {
        guard let layout else { return masters.values.first }
        return masters[layout.masterPath] ?? masters.values.first
    }

    public var orderedLayouts: [SlideLayout] { layoutOrder.compactMap { layouts[$0] } }
}

/// A theme's colours, fonts and style matrix.
public struct Theme: Equatable, Sendable {
    /// `dk1`, `lt1`, `dk2`, `lt2`, `accent1`…`accent6`, `hlink`, `folHlink`.
    public var colors: [String: UInt32]
    public var majorFont: String
    public var minorFont: String
    public var majorEastAsianFont: String?
    public var minorEastAsianFont: String?
    /// `fillStyleLst`, used by shape style references 1…3.
    public var fillStyles: [Fill]
    /// `bgFillStyleLst`, used by background references 1001…1003.
    public var backgroundFillStyles: [Fill]
    public var lineStyles: [LineStyle]

    /// Office's own default, for a package that somehow has no theme.
    public static let office = Theme(
        colors: [
            "dk1": 0x000000, "lt1": 0xFFFFFF, "dk2": 0x0E2841, "lt2": 0xE8E8E8,
            "accent1": 0x156082, "accent2": 0xE97132, "accent3": 0x196B24, "accent4": 0x0F9ED5,
            "accent5": 0xA02B93, "accent6": 0x4EA72E, "hlink": 0x467886, "folHlink": 0x96607D,
        ],
        majorFont: "Aptos Display", minorFont: "Aptos",
        fillStyles: [.solid(.scheme("phClr"))], backgroundFillStyles: [.solid(.scheme("phClr"))],
        lineStyles: [LineStyle(fill: .solid(.scheme("phClr")), width: 12_700)]
    )
}

/// A slide master.
public struct SlideMaster: Equatable, Sendable {
    public var path: String
    public var theme: Theme
    /// `p:clrMap`: which theme colour each alias such as `tx1` stands for.
    public var colorMap: [String: String]
    public var background: Background?
    /// Every shape on the master, placeholders included.
    public var shapes: [SlideShape]
    public var titleStyle: ListStyle
    public var bodyStyle: ListStyle
    public var otherStyle: ListStyle

    public func textStyle(_ category: TextStyleCategory) -> ListStyle {
        switch category {
        case .title: titleStyle
        case .body: bodyStyle
        case .other: otherStyle
        }
    }

    public static let defaultColorMap = [
        "bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2",
        "accent1": "accent1", "accent2": "accent2", "accent3": "accent3",
        "accent4": "accent4", "accent5": "accent5", "accent6": "accent6",
        "hlink": "hlink", "folHlink": "folHlink",
    ]
}

/// A slide layout.
public struct SlideLayout: Equatable, Sendable {
    public var path: String
    public var name: String
    public var masterPath: String
    public var background: Background?
    /// Every shape on the layout, placeholders included.
    public var shapes: [SlideShape]
    public var showsMasterShapes: Bool
    public var colorMapOverride: [String: String]?
}

extension Array where Element == SlideShape {
    /// The placeholder `placeholder` inherits from among these: by index
    /// first, then by type, as PowerPoint does.
    public func inheritedPlaceholder(for placeholder: Placeholder) -> SlideShape? {
        let candidates = filter { $0.placeholder != nil }
        return candidates.first { $0.placeholder.map { placeholder.matches($0, byIndex: true) } ?? false }
            ?? candidates.first { $0.placeholder.map { placeholder.matches($0, byIndex: false) } ?? false }
    }

    /// The placeholder on a master that `placeholder` inherits from, which
    /// is matched by type alone.
    public func masterPlaceholder(for placeholder: Placeholder) -> SlideShape? {
        first { $0.placeholder.map { placeholder.matches($0, byIndex: false) } ?? false }
    }
}
