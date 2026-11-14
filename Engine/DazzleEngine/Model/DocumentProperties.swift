import Foundation

/// What a presentation says about itself: `docProps/core.xml` (title,
/// author, dates) and the parts of `docProps/app.xml` worth showing.
public struct DocumentProperties: Equatable, Sendable {
    public var title = ""
    public var subject = ""
    /// `dc:creator`: who wrote it.
    public var author = ""
    public var keywords = ""
    public var category = ""
    /// `dc:description`, which PowerPoint calls Comments.
    public var comments = ""
    /// Who saved it last, and when.
    public var lastModifiedBy = ""
    public var modified: Date?
    public var created: Date?
    /// How many times it has been saved, if the file counts.
    public var revision: Int?
    /// `app.xml`: the company it was written for, and what wrote it.
    public var company = ""
    public var application = ""
    public var applicationVersion = ""

    public init() {}

    /// The properties that can be edited, by key, for the editors that edit
    /// them one by one.
    public enum Field: String, CaseIterable, Sendable {
        case title, subject, author, keywords, category, comments, company
    }

    public subscript(field: Field) -> String {
        get {
            switch field {
            case .title: title
            case .subject: subject
            case .author: author
            case .keywords: keywords
            case .category: category
            case .comments: comments
            case .company: company
            }
        }
        set {
            switch field {
            case .title: title = newValue
            case .subject: subject = newValue
            case .author: author = newValue
            case .keywords: keywords = newValue
            case .category: category = newValue
            case .comments: comments = newValue
            case .company: company = newValue
            }
        }
    }

    /// What wrote the file, with its version if it says.
    public var applicationDescription: String {
        [application, applicationVersion].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension Presentation {
    /// The presentation as it is written to disk at `date`: the modified
    /// date, the last author and the revision moved on, as PowerPoint does
    /// on every save. An empty `author` leaves the last author as it was.
    public func stampedForSaving(by author: String?, at date: Date = Date()) -> Presentation {
        var copy = self
        copy.properties.modified = date
        if let author = author?.trimmed, !author.isEmpty {
            copy.properties.lastModifiedBy = author
        }
        copy.properties.revision = (properties.revision ?? 0) + 1
        copy.arePropertiesModified = true
        return copy
    }
}

/// Reading and writing `docProps/core.xml` and `docProps/app.xml`.
public enum DocumentPropertiesXML {
    public static let coreNamespace = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    public static let extendedNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
    public static let coreRelationship = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    public static let extendedRelationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
    public static let coreContentType = "application/vnd.openxmlformats-package.core-properties+xml"
    public static let extendedContentType = "application/vnd.openxmlformats-officedocument.extended-properties+xml"

    static let namespaces = [
        "cp": coreNamespace,
        "dc": "http://purl.org/dc/elements/1.1/",
        "dcterms": "http://purl.org/dc/terms/",
        "dcmitype": "http://purl.org/dc/dcmitype/",
        "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    ]

    /// Core properties Dazzle writes, by local name and the prefix it gives
    /// a new one. Anything else in the part is kept.
    private static let coreElements: [(name: String, prefix: String)] = [
        ("title", "dc"), ("subject", "dc"), ("creator", "dc"), ("keywords", "cp"), ("description", "dc"),
        ("lastModifiedBy", "cp"), ("revision", "cp"), ("created", "dcterms"), ("modified", "dcterms"), ("category", "cp"),
    ]

    // MARK: - Dates

    /// W3C dates, as `dcterms:created` and `dcterms:modified` hold them.
    public static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmed, !text.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        // A date without a time zone is taken as UTC.
        if let date = try? Date.ISO8601FormatStyle().parse(text + "Z") { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text + "Z")
    }

    /// A date to the second, in UTC, as PowerPoint writes it.
    public static func string(_ date: Date) -> String {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)).formatted(Date.ISO8601FormatStyle())
    }

    // MARK: - Reading

    /// The properties in a package's core and extended property parts, found
    /// through the package's own relationships.
    public static func properties(in parts: [String: Data]) -> DocumentProperties {
        var properties = DocumentProperties()
        let (corePath, appPath) = paths(in: parts)
        if let data = corePath.flatMap({ parts[$0] }), let root = try? XMLLite.parse(data) {
            func text(_ name: String) -> String { root.firstChild(named: name).map(flattenedText) ?? "" }
            properties.title = text("title")
            properties.subject = text("subject")
            properties.author = text("creator")
            properties.keywords = text("keywords")
            properties.category = text("category")
            properties.comments = text("description")
            properties.lastModifiedBy = text("lastModifiedBy")
            properties.revision = Int(text("revision").trimmed)
            properties.created = date(text("created"))
            properties.modified = date(text("modified"))
        }
        if let data = appPath.flatMap({ parts[$0] }), let root = try? XMLLite.parse(data) {
            func text(_ name: String) -> String { root.firstChild(named: name)?.text.trimmed ?? "" }
            properties.company = text("Company")
            properties.application = text("Application")
            properties.applicationVersion = text("AppVersion")
        }
        return properties
    }

    /// Where the package keeps its core and extended properties.
    public static func paths(in parts: [String: Data]) -> (core: String?, app: String?) {
        let relationships = Relationship.parse(parts["_rels/.rels"])
        func path(_ type: String) -> String? {
            relationships.first { $0.type == type && !$0.isExternal }.map { PackagePath.resolve($0.target, from: "") }
        }
        return (path(coreRelationship), path(extendedRelationship))
    }

    /// An element's text, with keywords split by language (`cp:value`) run together.
    private static func flattenedText(_ element: XMLElement) -> String {
        ([element.text] + element.children.map(flattenedText)).filter { !$0.trimmed.isEmpty }.joined(separator: " ").trimmed
    }

    // MARK: - Writing

    /// `core.xml` with the properties written over what `existing` held.
    public static func coreXML(_ properties: DocumentProperties, existing: Data?) -> Data? {
        let base = existing.flatMap { try? XMLLite.parse($0) }.flatMap { $0.name == "coreProperties" ? $0 : nil }
        let declarations = namespaces.sorted { $0.key < $1.key }.map { " xmlns:\($0.key)=\"\($0.value)\"" }.joined()
        guard let root = base ?? (try? XMLLite.parse(Data("<cp:coreProperties\(declarations)/>".utf8))) else { return nil }
        let values: [String: String] = [
            "title": properties.title, "subject": properties.subject, "creator": properties.author,
            "keywords": properties.keywords, "description": properties.comments, "lastModifiedBy": properties.lastModifiedBy,
            "revision": properties.revision.map(String.init) ?? "", "created": properties.created.map(string) ?? "",
            "modified": properties.modified.map(string) ?? "", "category": properties.category,
        ]
        for (name, prefix) in coreElements {
            let value = values[name] ?? ""
            let existing = root.children(named: name)
            if let first = existing.first, !value.isEmpty, first.children.isEmpty || name != "keywords" {
                existing.dropFirst().forEach(root.removeChild)
                for child in first.children { first.removeChild(child) }
                first.setText(value)
                continue
            }
            existing.forEach(root.removeChild)
            guard !value.isEmpty else { continue }
            let type = prefix == "dcterms" ? " xsi:type=\"dcterms:W3CDTF\"" : ""
            guard let element = XMLLite.fragment(
                "<\(prefix):\(name)\(type)>\(XMLLite.escape(value))</\(prefix):\(name)>",
                namespaces: prefix == "dcterms" ? namespaces.filter { ["dcterms", "xsi"].contains($0.key) } : namespaces.filter { $0.key == prefix }
            ) else { continue }
            root.insertChild(element, at: root.children.count)
        }
        return XMLLite.serialize(root).map { Data((PackagePath.declaration + $0).utf8) }
    }

    /// `app.xml` with the company and the slide counts brought up to date.
    /// Everything else in it, such as the list of slide titles, is kept.
    public static func appXML(_ properties: DocumentProperties, slides: [Slide], existing: Data?) -> Data? {
        let base = existing.flatMap { try? XMLLite.parse($0) }.flatMap { $0.name == "Properties" ? $0 : nil }
        let blank = "<Properties xmlns=\"\(extendedNamespace)\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"/>"
        guard let root = base ?? (try? XMLLite.parse(Data(blank.utf8))) else { return nil }
        func set(_ name: String, _ value: String, keepEmpty: Bool = false) {
            if let element = root.firstChild(named: name) {
                if value.isEmpty && !keepEmpty { root.removeChild(element) } else { element.setText(value) }
            } else if !value.isEmpty {
                let element = XMLElement(name: name, attributes: [:])
                element.setText(value)
                root.insertChild(element, at: root.children.count)
            }
        }
        set("Company", properties.company)
        // Counts are only kept up to date where the file keeps them.
        if root.firstChild(named: "Slides") != nil { set("Slides", String(slides.count), keepEmpty: true) }
        if root.firstChild(named: "HiddenSlides") != nil { set("HiddenSlides", String(slides.filter(\.isHidden).count), keepEmpty: true) }
        if root.firstChild(named: "Notes") != nil {
            set("Notes", String(slides.filter { $0.notesPart != nil || !$0.notes.isEmpty }.count), keepEmpty: true)
        }
        return XMLLite.serialize(root).map { Data((PackagePath.declaration + $0).utf8) }
    }
}
