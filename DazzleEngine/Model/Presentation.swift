import Foundation

/// A whole presentation: its slides, and the package they came from.
///
/// Dazzle models what it draws and edits. Everything else — transitions,
/// embedded objects, custom XML, macros — stays in `package` exactly
/// as it was read and is written back untouched.
public struct Presentation: Equatable, Sendable {
    public var slideSize: EMUSize
    public var slides: [Slide]
    /// Theme, masters and layouts: read once, never edited.
    public let resources: DeckResources
    /// Every part of the file as it was read.
    public let package: Package
    /// Parts Dazzle has added since, such as pictures.
    public var addedParts: [String: Data] = [:]
    /// Content types for added parts that their extension does not settle,
    /// such as a chart's XML.
    public var addedContentTypes: [String: String] = [:]
    /// Whether slides were added, removed or reordered, which means the
    /// slide list itself has to be written again.
    public var isStructureModified = false
    /// Everyone who has commented, in each of PowerPoint's two formats.
    public var commentAuthors: [CommentAuthor] = []
    public var modernCommentAuthors: [ModernCommentAuthor] = []
    /// Whether the slideshow starts again from the first slide after the
    /// last, until stopped.
    public var loopsSlideshow = false
    public var isShowSettingsModified = false
    /// The Keynote document the presentation was converted from, if it was.
    public var keynoteSource: KeynoteSource?

    public var unsupportedFeatures: UnsupportedFeatureReport { package.unsupportedFeatures }

    /// The bytes of a part, whether read or added.
    public func data(at path: String) -> Data? {
        addedParts[path] ?? package.parts[path]
    }

    /// Every part name in use, read or added.
    public var partNames: Set<String> {
        Set(package.parts.keys).union(addedParts.keys)
    }

    /// A part's content type: one Dazzle gave it, or what the package's
    /// `[Content_Types].xml` says.
    public func contentType(of path: String) -> String? {
        if let added = addedContentTypes[path] { return added }
        return package.contentTypes.type(of: path)
    }

    public func index(of slideID: Slide.ID?) -> Int? {
        slides.firstIndex { $0.id == slideID }
    }

    public func layout(for slide: Slide) -> SlideLayout? {
        resources.layouts[slide.layoutPath]
    }

    /// The slides a slideshow steps through: all but the hidden ones.
    public var visibleSlideIndices: [Int] {
        let visible = slides.indices.filter { !slides[$0].isHidden }
        // A deck whose every slide is hidden still has something to show.
        return visible.isEmpty ? Array(slides.indices) : visible
    }
}

/// The package as read, shared between every copy of a presentation.
public final class Package: Equatable, Sendable {
    public let parts: [String: Data]
    /// Where the presentation part lives, normally `ppt/presentation.xml`.
    public let mainPart: String
    public let unsupportedFeatures: UnsupportedFeatureReport
    public let contentTypes: ContentTypeMap

    public init(parts: [String: Data], mainPart: String, unsupportedFeatures: UnsupportedFeatureReport) {
        self.parts = parts
        self.mainPart = mainPart
        self.unsupportedFeatures = unsupportedFeatures
        contentTypes = ContentTypeMap(data: parts["[Content_Types].xml"])
    }

    public static func == (lhs: Package, rhs: Package) -> Bool { lhs === rhs }
}

/// `[Content_Types].xml`, for looking types up.
public struct ContentTypeMap: Sendable {
    private var defaults: [String: String] = [:]
    private var overrides: [String: String] = [:]

    public init(data: Data?) {
        guard let data, let root = try? XMLLite.parse(data) else { return }
        for element in root.children(named: "Default") {
            if let ext = element.attribute("Extension"), let type = element.attribute("ContentType") {
                defaults[ext.lowercased()] = type
            }
        }
        for element in root.children(named: "Override") {
            if let part = element.attribute("PartName"), let type = element.attribute("ContentType") {
                overrides[String(part.drop { $0 == "/" })] = type
            }
        }
    }

    public func type(of path: String) -> String? {
        overrides[path] ?? defaults[(path as NSString).pathExtension.lowercased()]
    }

    /// Whether the type comes from an override rather than the extension.
    public func isOverridden(_ path: String) -> Bool { overrides[path] != nil }
}

/// One slide.
public struct Slide: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The part it is saved as; `nil` for a slide not yet saved.
    public var partName: String?
    /// The part whose XML supplies everything Dazzle does not model: the
    /// slide itself, or for a duplicate, the slide it was copied from.
    public var sourcePart: String?
    public var layoutPath: String
    public var relationships: [Relationship]
    public var shapes: [SlideShape]
    public var background: Background?
    public var isHidden = false
    public var showsMasterShapes = true
    /// The speaker notes, as plain text.
    public var notes = ""
    public var notesPart: String?
    /// The slide's comment threads, and the parts they were read from.
    public var comments: [SlideComment] = []
    /// Seconds before the slideshow moves on by itself, if it does.
    public var autoAdvanceAfter: Double?
    /// Whether a tap or click moves the slideshow on.
    public var advancesOnClick = true
    public var isTransitionModified = false
    /// The effects the slideshow plays as the slide is tapped through.
    public var animations: [ShapeAnimation] = []
    public var areAnimationsModified = false
    public var legacyCommentsPart: String?
    public var modernCommentsPart: String?
    public var areCommentsModified = false
    /// Whether the slide's own XML must be written again.
    public var isModified = false
    public var isBackgroundModified = false
    public var areNotesModified = false
    /// Whether every shape could be read faithfully enough to write back
    /// individually. When not, the slide is kept exactly as it was.
    public var canEditShapes = true
    /// Whether a shape was removed, which leaves animations pointing at
    /// nothing. Those are dropped on save, along with anything else in the
    /// slide's timing that names it.
    public var hasRemovedShapes = false

    public init(id: UUID = UUID(), layoutPath: String, relationships: [Relationship] = [], shapes: [SlideShape] = []) {
        self.id = id
        self.layoutPath = layoutPath
        self.relationships = relationships
        self.shapes = shapes
    }

    /// The text of the slide's title placeholder, if it has one.
    public var title: String? {
        shapes.first { $0.placeholder?.isTitle == true }?.text?.plainText
            .replacingOccurrences(of: "\n", with: " ").trimmed.nilIfEmpty
    }

    /// The animations whose shapes are still on the slide, in playing order.
    public var playableAnimations: [ShapeAnimation] {
        let ids = Set(shapes.map(\.shapeID))
        return animations.filter { ids.contains($0.shapeID) }
    }

    public var animationTimeline: AnimationTimeline { AnimationTimeline(animations: playableAnimations) }

    /// The first `cNvPr id` no shape on the slide uses.
    public var nextShapeID: Int {
        (shapes.flatMap(\.flattened).map(\.shapeID).max() ?? 1) + 1
    }
}

extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Array {
    public var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

/// The parts of a file Dazzle shows but cannot edit, or keeps but cannot use.
public struct UnsupportedFeatureReport: Equatable, Sendable {
    public enum Feature: String, CaseIterable, Sendable {
        case macros
        case charts
        case media
        case embeddedObjects
        case transitions

        public var message: String {
            switch self {
            case .macros: String(localized: "Notice.Feature.Macros", bundle: #bundle)
            case .charts: String(localized: "Notice.Feature.Charts", bundle: #bundle)
            case .media: String(localized: "Notice.Feature.Media", bundle: #bundle)
            case .embeddedObjects: String(localized: "Notice.Feature.EmbeddedObjects", bundle: #bundle)
            case .transitions: String(localized: "Notice.Feature.Transitions", bundle: #bundle)
            }
        }
    }

    /// What a file converted on opening, such as a Keynote presentation,
    /// lost on the way in. Unlike `features`, none of it is saved.
    public enum Omission: String, CaseIterable, Sendable {
        case tables
        case charts
        case builds
        case movies
        case otherObjects

        public var message: String {
            switch self {
            case .tables: String(localized: "Notice.Omission.Tables", bundle: #bundle)
            case .charts: String(localized: "Notice.Omission.Charts", bundle: #bundle)
            case .builds: String(localized: "Notice.Omission.Builds", bundle: #bundle)
            case .movies: String(localized: "Notice.Omission.Movies", bundle: #bundle)
            case .otherObjects: String(localized: "Notice.Omission.Other", bundle: #bundle)
            }
        }
    }

    public var features: Set<Feature> = []
    public var omissions: Set<Omission> = []

    public var isEmpty: Bool { features.isEmpty && omissions.isEmpty }

    public var noticeMessage: String {
        Feature.allCases.filter(features.contains).map { "• " + $0.message }.joined(separator: "\n")
    }

    public var omissionMessage: String {
        Omission.allCases.filter(omissions.contains).map { "• " + $0.message }.joined(separator: "\n")
    }
}
