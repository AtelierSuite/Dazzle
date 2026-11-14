import Foundation

/// A whole presentation: its slides, and the package they came from.
///
/// Dazzle models what it draws and edits. Everything else — transitions,
/// embedded objects, custom XML, macros — stays in `package` exactly
/// as it was read and is written back untouched.
public struct Presentation: Equatable, Sendable {
    public var slideSize: EMUSize
    public var slides: [Slide]
    /// Theme, masters and layouts. Read with the file, and read again once
    /// master view has changed them.
    public var resources: DeckResources
    /// Every part of the file as it was read.
    public let package: Package
    /// Parts Dazzle has added since, such as pictures.
    public var addedParts: [String: Data] = [:]
    /// Content types for added parts that their extension does not settle,
    /// such as a chart's XML.
    public var addedContentTypes: [String: String] = [:]
    /// Parts Dazzle has taken out since, such as a deleted layout.
    public var removedParts: Set<String> = []
    /// Set while the masters and layouts are being edited: `slides` then
    /// holds them, and this the slides set aside.
    public var masterView: MasterView?
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
    /// Title, author, dates and the rest of `docProps`.
    public var properties = DocumentProperties()
    /// Whether `properties` must be written over the file's own.
    public var arePropertiesModified = false
    /// The Keynote document the presentation was converted from, if it was.
    public var keynoteSource: KeynoteSource?

    public var unsupportedFeatures: UnsupportedFeatureReport { package.unsupportedFeatures }

    /// The bytes of a part, whether read or added.
    public func data(at path: String) -> Data? {
        removedParts.contains(path) ? nil : addedParts[path] ?? package.parts[path]
    }

    /// Every part name in use, read or added.
    public var partNames: Set<String> {
        Set(package.parts.keys).union(addedParts.keys).subtracting(removedParts)
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

    /// The layout a slide is built on. In master view, a layout being edited
    /// is its own slide, so what it is built on holds nothing but its settings.
    public func layout(for slide: Slide) -> SlideLayout? {
        switch slide.role {
        case .slide:
            return resources.layouts[slide.layoutPath]
        case .master:
            return nil
        case .layout(let masterPath):
            return SlideLayout(
                path: slide.partName ?? "", name: slide.layoutName ?? "", masterPath: masterPath, background: nil,
                shapes: [], showsMasterShapes: slide.showsMasterShapes,
                colorMapOverride: slide.sourcePart.flatMap { resources.layouts[$0] }?.colorMapOverride
            )
        }
    }

    /// The master a slide is built on. In master view, a layout follows its
    /// master as it stands being edited, and a master is built on nothing
    /// but its own theme and text styles.
    public func master(for slide: Slide) -> SlideMaster? {
        switch slide.role {
        case .slide:
            return resources.master(for: layout(for: slide))
        case .master:
            guard var master = slide.partName.flatMap({ resources.masters[$0] }) else { return nil }
            master.shapes = []
            master.background = nil
            return master
        case .layout(let masterPath):
            guard var master = resources.masters[masterPath] else { return nil }
            if let edited = slides.first(where: { $0.role == .master && $0.partName == masterPath }) {
                master.shapes = edited.shapes
                master.background = edited.background
            }
            return master
        }
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

/// The slides set aside while master view shows the masters and layouts.
public struct MasterView: Equatable, Sendable {
    public var slides: [Slide]
    /// The masters and layouts as they were on the way in, to go back to
    /// when nothing about them was changed.
    public var resources: DeckResources
    /// The slide that was being edited, to go back to.
    public var selectedSlideID: Slide.ID?

    public init(slides: [Slide], resources: DeckResources, selectedSlideID: Slide.ID? = nil) {
        self.slides = slides
        self.resources = resources
        self.selectedSlideID = selectedSlideID
    }
}

/// One slide.
public struct Slide: Identifiable, Equatable, Sendable {
    /// What a slide is. Master view edits masters and layouts as slides of
    /// their own, so everything that edits a slide edits them.
    public enum Role: Equatable, Sendable {
        case slide
        case master
        /// A layout, and the master it belongs to.
        case layout(masterPath: String)
    }

    public let id: UUID
    public var role = Role.slide
    /// A layout's name, in master view.
    public var layoutName: String?
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
    /// How the slideshow moves onto the slide; `nil` for straight on.
    public var transition: SlideTransition?
    /// Whether `transition` must be written over the slide's own, which is
    /// otherwise kept exactly as it was.
    public var isTransitionEffectModified = false
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
            case .macros: String(localized: "Notice.Feature.Macros", bundle: .engine)
            case .charts: String(localized: "Notice.Feature.Charts", bundle: .engine)
            case .media: String(localized: "Notice.Feature.Media", bundle: .engine)
            case .embeddedObjects: String(localized: "Notice.Feature.EmbeddedObjects", bundle: .engine)
            case .transitions: String(localized: "Notice.Feature.Transitions", bundle: .engine)
            }
        }
    }

    /// What a file converted on opening, such as a Keynote presentation,
    /// lost on the way in. Unlike `features`, none of it is saved.
    public enum Omission: String, CaseIterable, Sendable {
        case tables
        /// Tables that are kept in their place as stand-ins, and saved
        /// back only into the Keynote file they came from.
        case tableStandIns
        case charts
        /// Charts that are kept in their place as stand-ins, and saved
        /// back only into the Keynote file they came from.
        case chartStandIns
        case builds
        case approximatedBuilds
        case movies
        /// 3D objects, which show a still picture of themselves.
        case objects3D
        /// Equations whose picture can't be shown here, kept in their place as stand-ins.
        case equationStandIns
        /// Objects of kinds Dazzle doesn't know, kept in their place as stand-ins.
        case objectStandIns
        case otherObjects

        public var message: String {
            switch self {
            case .tables: String(localized: "Notice.Omission.Tables", bundle: .engine)
            case .tableStandIns: String(localized: "Notice.Omission.TableStandIns", bundle: .engine)
            case .charts: String(localized: "Notice.Omission.Charts", bundle: .engine)
            case .chartStandIns: String(localized: "Notice.Omission.ChartStandIns", bundle: .engine)
            case .builds: String(localized: "Notice.Omission.Builds", bundle: .engine)
            case .approximatedBuilds: String(localized: "Notice.Omission.ApproximatedBuilds", bundle: .engine)
            case .movies: String(localized: "Notice.Omission.Movies", bundle: .engine)
            case .objects3D: String(localized: "Notice.Omission.Objects3D", bundle: .engine)
            case .equationStandIns: String(localized: "Notice.Omission.EquationStandIns", bundle: .engine)
            case .objectStandIns: String(localized: "Notice.Omission.ObjectStandIns", bundle: .engine)
            case .otherObjects: String(localized: "Notice.Omission.Other", bundle: .engine)
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
