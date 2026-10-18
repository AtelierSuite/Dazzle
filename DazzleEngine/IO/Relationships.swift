import Foundation

/// Namespace and relationship-type URIs a presentation package uses.
public enum OOXML {
    public static let presentationML = "http://schemas.openxmlformats.org/presentationml/2006/main"
    public static let drawingML = "http://schemas.openxmlformats.org/drawingml/2006/main"
    public static let relationshipsNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    public static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    public static let contentTypesNS = "http://schemas.openxmlformats.org/package/2006/content-types"

    /// The prefixes Dazzle writes new XML with.
    public static let namespaces = ["a": drawingML, "r": relationshipsNS, "p": presentationML]

    public enum RelationshipType {
        private static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        public static let officeDocument = base + "officeDocument"
        public static let slide = base + "slide"
        public static let slideLayout = base + "slideLayout"
        public static let slideMaster = base + "slideMaster"
        public static let notesSlide = base + "notesSlide"
        public static let notesMaster = base + "notesMaster"
        public static let theme = base + "theme"
        public static let image = base + "image"
        public static let comments = base + "comments"
        public static let commentAuthors = base + "commentAuthors"
        public static let hyperlink = base + "hyperlink"
        public static let video = base + "video"
        public static let audio = base + "audio"
        public static let chart = base + "chart"
        public static let package = base + "package"
        public static let presProps = base + "presProps"
        public static let media = "http://schemas.microsoft.com/office/2007/relationships/media"
        public static let modernComments = "http://schemas.microsoft.com/office/2018/10/relationships/comments"
        public static let authors = "http://schemas.microsoft.com/office/2018/10/relationships/authors"
        public static let diagramDrawing = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"
        public static let vbaProject = "http://schemas.microsoft.com/office/2006/relationships/vbaProject"
    }

    public enum ContentType {
        private static let base = "application/vnd.openxmlformats-officedocument.presentationml."
        public static let slide = base + "slide+xml"
        public static let notesSlide = base + "notesSlide+xml"
        public static let notesMaster = base + "notesMaster+xml"
        public static let theme = "application/vnd.openxmlformats-officedocument.theme+xml"
    }
}

/// One entry in a part's `.rels`.
public struct Relationship: Equatable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var target: String
    public var isExternal = false

    /// Reads a `.rels` part.
    public static func parse(_ data: Data?) -> [Relationship] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        return root.children(named: "Relationship").compactMap { element in
            guard let id = element.attribute("Id"), let type = element.attribute("Type"),
                  let target = element.attribute("Target") else { return nil }
            return Relationship(id: id, type: type, target: target, isExternal: element.attribute("TargetMode") == "External")
        }
    }

    public static func xml(_ relationships: [Relationship]) -> Data {
        let entries = relationships.map { relationship in
            let mode = relationship.isExternal ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(XMLLite.escape(relationship.id))\" Type=\"\(XMLLite.escape(relationship.type))\" "
                + "Target=\"\(XMLLite.escape(relationship.target))\"\(mode)/>"
        }
        return Data((PackagePath.declaration
            + "<Relationships xmlns=\"\(OOXML.packageRelationships)\">\(entries.joined())</Relationships>").utf8)
    }

    /// The first id of the form `rIdN` that none of `relationships` uses.
    public static func unusedID(in relationships: [Relationship]) -> String {
        let used = Set(relationships.map(\.id))
        var number = relationships.count + 1
        while used.contains("rId\(number)") { number += 1 }
        return "rId\(number)"
    }

    public init(id: String, type: String, target: String, isExternal: Bool = false) {
        self.id = id
        self.type = type
        self.target = target
        self.isExternal = isExternal
    }
}

/// Paths inside a package.
public enum PackagePath {
    public static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// Where the relationships of `part` live: `ppt/slides/slide1.xml` →
    /// `ppt/slides/_rels/slide1.xml.rels`.
    public static func relationships(of part: String) -> String {
        let directory = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        return directory.isEmpty ? "_rels/\(file).rels" : "\(directory)/_rels/\(file).rels"
    }

    /// Resolves a relationship target against the part that holds it.
    public static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = (part as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            switch component {
            case "..": if !components.isEmpty { components.removeLast() }
            case ".": continue
            default: components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    /// The target that reaches `path` from `part`.
    public static func relativeTarget(to path: String, from part: String) -> String {
        let from = (part as NSString).deletingLastPathComponent.split(separator: "/")
        let to = path.split(separator: "/")
        var shared = 0
        while shared < from.count, shared < to.count - 1, from[shared] == to[shared] { shared += 1 }
        let ups = Array(repeating: "..", count: from.count - shared)
        return (ups + to[shared...].map(String.init)).joined(separator: "/")
    }

    /// The first path `prefix{n}.suffix` that is not in `taken`.
    public static func unused(prefix: String, suffix: String, taken: Set<String>) -> String {
        var number = 1
        while taken.contains("\(prefix)\(number)\(suffix)") { number += 1 }
        return "\(prefix)\(number)\(suffix)"
    }
}

extension XMLElement {
    /// `r:id`. Stripping prefixes folds it into the plain `id` that list
    /// entries such as `p:sldId` also carry, so it is looked up by its
    /// qualified name instead.
    public var relationshipID: String? {
        qualifiedAttributes.first { $0.key.hasSuffix(":id") && !$0.key.hasPrefix("xmlns") }?.value
    }
}
