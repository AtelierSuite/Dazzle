import Foundation

/// Something on a slide: a shape, a picture, a group, a table, or an object
/// Dazzle keeps but cannot draw.
public struct SlideShape: Identifiable, Equatable, Hashable, Sendable {
    /// What Dazzle has changed about a shape read from a file. Only these
    /// parts of its XML are rewritten; everything else is written back as read.
    public enum Edit: Hashable, Sendable {
        case transform
        case fill
        case line
        case text
        /// A copy, which needs ids of its own.
        case identity
        /// No longer a placeholder: pasted where its layout has no place for it.
        case placeholder
        /// A table's rows, columns or cells.
        case table
        /// A picture's image or its crop.
        case picture
        /// The description read out in place of the shape.
        case altText
        /// Its shadow and reflection.
        case effects
        /// Where clicking it goes.
        case link
    }

    public enum Kind: Equatable, Hashable, Sendable {
        case shape
        case connector
        case picture(Picture)
        case group(ShapeGroup)
        case table(SlideTable)
        /// A chart, or `nil` for one Dazzle cannot read.
        case chart(Chart?)
        /// SmartArt, drawn from the shapes PowerPoint saved alongside it.
        case diagram([SlideShape])
        /// Anything else: an embedded object, ink, a 3D model.
        case unsupported(String)
    }

    public struct Picture: Equatable, Hashable, Sendable {
        /// Where the whole image lies when `frame` shows the cropped part, in points.
        public static func imageRect(frame: CGRect, picture: Picture) -> CGRect {
            let visibleWidth = 1 - picture.cropLeft - picture.cropRight
            let visibleHeight = 1 - picture.cropTop - picture.cropBottom
            guard visibleWidth > 0.001, visibleHeight > 0.001 else { return frame }
            let width = frame.width / visibleWidth
            let height = frame.height / visibleHeight
            return CGRect(x: frame.minX - width * picture.cropLeft, y: frame.minY - height * picture.cropTop, width: width, height: height)
        }

        /// The image's path inside the package; `nil` for a linked image.
        public var imagePath: String?
        /// Fractions of the image cut from each edge.
        public var cropLeft = 0.0
        public var cropTop = 0.0
        public var cropRight = 0.0
        public var cropBottom = 0.0
        public var effects = BlipEffects()
        /// The video or sound the picture stands for, if it is one.
        public var media: Media?

        public init(
            imagePath: String? = nil, cropLeft: Double = 0.0, cropTop: Double = 0.0, cropRight: Double = 0.0,
            cropBottom: Double = 0.0, effects: BlipEffects = BlipEffects(), media: Media? = nil
        ) {
            self.imagePath = imagePath
            self.cropLeft = cropLeft
            self.cropTop = cropTop
            self.cropRight = cropRight
            self.cropBottom = cropBottom
            self.effects = effects
            self.media = media
        }
    }

    /// A video or sound, shown as a picture until it plays.
    public struct Media: Equatable, Hashable, Sendable {
        public enum Kind: Equatable, Hashable, Sendable {
            case video
            case audio
        }

        public var kind: Kind
        /// The media's path inside the package; `nil` for a linked file.
        public var path: String?
        /// Where a linked file is, outside the package.
        public var url: String?
        /// Whether it starts as its slide does, rather than when tapped.
        public var playsAutomatically = false

        public init(kind: Kind, path: String? = nil, url: String? = nil, playsAutomatically: Bool = false) {
            self.kind = kind
            self.path = path
            self.url = url
            self.playsAutomatically = playsAutomatically
        }
    }

    public struct ShapeGroup: Equatable, Hashable, Sendable {
        /// The space the children's coordinates are in, which the group maps
        /// onto its own frame.
        public var childFrame: EMURect
        public var children: [SlideShape]

        public init(childFrame: EMURect, children: [SlideShape]) {
            self.childFrame = childFrame
            self.children = children
        }
    }

    public let id: UUID
    /// `cNvPr id`: unique within a slide, and what animations refer to.
    public var shapeID: Int
    public var name: String
    /// `cNvPr hidden`: retained in the file, excluded from drawing and hit tests.
    public var isHidden = false
    public var kind: Kind
    /// Where the shape sits. For a placeholder that does not say, this is
    /// where its layout puts it.
    public var frame: EMURect
    /// Whether the file gives the frame, rather than the layout.
    public var hasOwnFrame: Bool
    /// Degrees clockwise.
    public var rotation: Double = 0
    public var flipsHorizontally = false
    public var flipsVertically = false
    public var placeholder: Placeholder?
    public var geometry: ShapeGeometry = .preset("rect", adjustments: [:])
    public var fill: Fill?
    public var line: LineStyle?
    /// A shadow the shape's own properties cast.
    public var shadow: Shadow?
    /// A reflection the shape's own properties cast.
    public var reflection: Reflection?
    public var style: StyleReferences?
    public var text: TextBody?
    /// For SmartArt shapes, where the text goes when it is not the whole shape.
    public var textFrame: EMURect?
    public var isTextBox = false
    /// `descr`: what the shape shows, for people who cannot see it.
    public var altText: String?
    /// Where clicking the shape goes, in a slideshow.
    public var link: Hyperlink?
    /// Read from XML Dazzle can show but not safely rewrite, such as a shape
    /// offered in two forms for different versions of PowerPoint. It can be
    /// deleted, but not changed.
    public var isLocked = false
    /// The shape's XML as read, or `nil` for one Dazzle made.
    public var source: String?
    public var edits: Set<Edit> = []

    public init(
        id: UUID = UUID(), shapeID: Int, name: String, kind: Kind, frame: EMURect, hasOwnFrame: Bool = true
    ) {
        self.id = id
        self.shapeID = shapeID
        self.name = name
        self.kind = kind
        self.frame = frame
        self.hasOwnFrame = hasOwnFrame
    }

    /// Whether Dazzle can move, resize and restyle it without risk of
    /// writing back something PowerPoint would reject.
    public var isEditable: Bool {
        guard !isLocked else { return false }
        return switch kind {
        case .shape, .connector, .picture, .group, .table, .chart, .diagram: true
        case .unsupported: false
        }
    }

    /// Whether it can be turned and flipped. PowerPoint keeps tables, charts
    /// and other graphic frames square to the slide.
    public var canRotate: Bool {
        guard isEditable else { return false }
        return switch kind {
        case .shape, .connector, .picture, .group: true
        case .table, .chart, .diagram, .unsupported: false
        }
    }

    /// Degrees brought into 0..<360.
    public static func normalized(_ degrees: Double) -> Double {
        let turned = degrees.truncatingRemainder(dividingBy: 360)
        return turned < 0 ? turned + 360 : turned
    }

    public var canHoldText: Bool {
        switch kind {
        case .shape: true
        default: false
        }
    }

    public var isPicture: Bool {
        if case .picture = kind { return true }
        return false
    }

    /// Every shape inside this one, depth first, including itself.
    public var flattened: [SlideShape] {
        switch kind {
        case .group(let group): [self] + group.children.flatMap(\.flattened)
        case .diagram(let children): [self] + children.flatMap(\.flattened)
        default: [self]
        }
    }
}

/// `p:ph`: which of the layout's placeholders a shape stands in for.
public struct Placeholder: Equatable, Hashable, Sendable {
    /// `title`, `body`, `ctrTitle`, `subTitle`, `dt`, `ftr`, `sldNum`, `pic`…
    /// `nil` means `obj`, the generic content placeholder.
    public var type: String?
    public var index: Int?

    public init(type: String?, index: Int?) {
        self.type = type
        self.index = index
    }

    public init?(element: XMLElement?) {
        guard let element else { return nil }
        type = element.attribute("type")
        index = element.attribute("idx").flatMap(Int.init)
    }

    public var isTitle: Bool { type == "title" || type == "ctrTitle" }

    /// Placeholders that only ever hold furniture PowerPoint fills in.
    public var isFurniture: Bool { ["dt", "ftr", "sldNum", "hdr"].contains(type ?? "") }

    /// Which of the master's text styles governs it.
    public var textStyleCategory: TextStyleCategory {
        switch type {
        case "title", "ctrTitle": .title
        case nil, "body", "subTitle", "obj", "tbl", "chart", "dgm", "media", "clipArt", "pic": .body
        default: .other
        }
    }

    /// Whether `other`, a layout or master placeholder, is the one this inherits from.
    public func matches(_ other: Placeholder, byIndex: Bool) -> Bool {
        if byIndex {
            guard let index, let otherIndex = other.index else { return false }
            return index == otherIndex
        }
        return Self.family(type) == Self.family(other.type)
    }

    /// Types the master treats as one kind of placeholder.
    private static func family(_ type: String?) -> String {
        switch type {
        case "title", "ctrTitle": "title"
        case nil, "body", "subTitle", "obj": "body"
        default: type ?? "body"
        }
    }
}

public enum TextStyleCategory: Sendable {
    case title
    case body
    case other
}

/// The outline a shape is drawn with.
public enum ShapeGeometry: Equatable, Hashable, Sendable {
    /// One of DrawingML's preset shapes, by name, with its adjust values.
    case preset(String, adjustments: [String: Int])
    /// A freeform outline, as paths in their own coordinate spaces.
    case custom([CustomPath])

    public struct CustomPath: Equatable, Hashable, Sendable {
        public enum Command: Equatable, Hashable, Sendable {
            case move(Double, Double)
            case line(Double, Double)
            case cubic(Double, Double, Double, Double, Double, Double)
            case quadratic(Double, Double, Double, Double)
            case arc(widthRadius: Double, heightRadius: Double, start: Double, sweep: Double)
            case close
        }

        public var width: Double
        public var height: Double
        public var isFilled: Bool
        public var isStroked: Bool
        public var commands: [Command]
    }

    public var presetName: String? {
        if case .preset(let name, _) = self { return name }
        return nil
    }

    public var adjustments: [String: Int] {
        if case .preset(_, let adjustments) = self { return adjustments }
        return [:]
    }
}
