#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A comment on a slide, with its replies.
///
/// PowerPoint has written comments two ways. The older, in ECMA-376, lists
/// a slide's comments by author number and index, threading replies in an
/// extension. The newer, PowerPoint 365's, gives each comment and author an
/// id, holds replies inside their comment, and can mark a thread resolved.
/// Both are read. A slide's comments are written back the way they came;
/// a slide with none yet gets the older kind, which every app reads.
public struct SlideComment: Identifiable, Equatable, Hashable, Sendable {
    public enum Format: Equatable, Hashable, Sendable {
        case legacy
        case modern
    }

    public var id: String
    public var author: String
    public var initials: String
    public var date: Date?
    public var text: String
    /// Where it is pinned on the slide, in points.
    public var position: CGPoint?
    public var replies: [SlideComment] = []
    public var isResolved = false
    public var format: Format
    /// The modern comment's XML as read, so what Dazzle does not model —
    /// where in the slide it is anchored — survives.
    public var source: String?

    public init(
        id: String, author: String, initials: String, date: Date? = nil, text: String, position: CGPoint? = nil,
        replies: [SlideComment] = [], isResolved: Bool = false, format: Format, source: String? = nil
    ) {
        self.id = id
        self.author = author
        self.initials = initials
        self.date = date
        self.text = text
        self.position = position
        self.replies = replies
        self.isResolved = isResolved
        self.format = format
        self.source = source
    }
}

/// Someone who has commented, in the older format's list.
public struct CommentAuthor: Equatable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var initials: String
    /// The highest comment index this author has used.
    public var lastIndex: Int
    public var colorIndex: Int
}

/// Someone who has commented, in the newer format's list.
public struct ModernCommentAuthor: Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var initials: String
    public var userID: String
    public var providerID: String
}

public enum CommentXML {
    public static let modernNamespace = "http://schemas.microsoft.com/office/powerpoint/2018/8/main"
    public static let threadingNamespace = "http://schemas.microsoft.com/office/powerpoint/2012/main"
    public static let threadingExtension = "{C676402C-5697-4E1C-873F-D02D1690AC5C}"
    public static let legacyContentType = "application/vnd.openxmlformats-officedocument.presentationml.comments+xml"
    public static let legacyAuthorsContentType = "application/vnd.openxmlformats-officedocument.presentationml.commentAuthors+xml"
    public static let modernContentType = "application/vnd.ms-powerpoint.comments+xml"
    public static let modernAuthorsContentType = "application/vnd.ms-powerpoint.authors+xml"
    /// Older comments are positioned in eighths of a point.
    public static let legacyUnitsPerPoint = 8.0

    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Dates as comments write them: without a time zone, taken as UTC.
    public static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if !text.hasSuffix("Z"), !text.contains("+") { text += "Z" }
        if !text.contains(".") { text = text.replacingOccurrences(of: "Z", with: ".000Z") }
        return try? dateFormat.parse(text)
    }

    public static func string(_ date: Date?) -> String {
        (date ?? Date()).formatted(dateFormat).replacingOccurrences(of: "Z", with: "")
    }

    public static func newID() -> String { "{\(UUID().uuidString)}" }

    // MARK: - Reading

    public static func authors(_ data: Data?) -> [CommentAuthor] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        return root.children(named: "cmAuthor").compactMap { element in
            guard let id = element.attribute("id").flatMap(Int.init) else { return nil }
            return CommentAuthor(
                id: id, name: element.attribute("name") ?? "", initials: element.attribute("initials") ?? "",
                lastIndex: element.attribute("lastIdx").flatMap(Int.init) ?? 0,
                colorIndex: element.attribute("clrIdx").flatMap(Int.init) ?? 0
            )
        }
    }

    public static func modernAuthors(_ data: Data?) -> [ModernCommentAuthor] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        return root.children(named: "author").compactMap { element in
            guard let id = element.attribute("id") else { return nil }
            return ModernCommentAuthor(
                id: id, name: element.attribute("name") ?? "", initials: element.attribute("initials") ?? "",
                userID: element.attribute("userId") ?? "", providerID: element.attribute("providerId") ?? "None"
            )
        }
    }

    /// The older format's comments, with replies gathered under the
    /// comments they answer.
    public static func legacyComments(_ data: Data?, authors: [CommentAuthor]) -> [SlideComment] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        var threads: [SlideComment] = []
        var replies: [(parent: String, comment: SlideComment)] = []
        for element in root.children(named: "cm") {
            var comment = legacyComment(element, authors: authors)
            comment.source = XMLLite.serialize(element)
            let parent = element.firstDescendant(atPath: "extLst/ext/threadingInfo/parentCm")
            if let parent, let parentAuthor = parent.attribute("authorId"), let parentIndex = parent.attribute("idx") {
                replies.append(("\(parentAuthor)-\(parentIndex)", comment))
            } else {
                threads.append(comment)
            }
        }
        for reply in replies {
            if let index = threads.firstIndex(where: { $0.id == reply.parent }) {
                threads[index].replies.append(reply.comment)
            } else {
                threads.append(reply.comment)
            }
        }
        return threads
    }

    private static func legacyComment(_ element: XMLElement, authors: [CommentAuthor]) -> SlideComment {
        let authorID = element.attribute("authorId").flatMap(Int.init) ?? 0
        let index = element.attribute("idx").flatMap(Int.init) ?? 0
        let author = authors.first { $0.id == authorID }
        var comment = SlideComment(
            id: "\(authorID)-\(index)", author: author?.name ?? "", initials: author?.initials ?? "",
            date: date(element.attribute("dt")), text: element.firstChild(named: "text")?.text ?? "", format: .legacy
        )
        if let position = element.firstChild(named: "pos"),
           let x = position.attribute("x").flatMap(Double.init), let y = position.attribute("y").flatMap(Double.init) {
            comment.position = CGPoint(x: x / legacyUnitsPerPoint, y: y / legacyUnitsPerPoint)
        }
        return comment
    }

    public static func modernComments(_ data: Data?, authors: [ModernCommentAuthor]) -> [SlideComment] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        return root.children(named: "cm").map { element in
            var thread = modernComment(element, authors: authors)
            thread.replies = element.firstChild(named: "replyLst")?.children(named: "reply").map { reply in
                var comment = modernComment(reply, authors: authors)
                comment.source = XMLLite.serialize(reply)
                return comment
            } ?? []
            thread.source = XMLLite.serialize(element)
            return thread
        }
    }

    private static func modernComment(_ element: XMLElement, authors: [ModernCommentAuthor]) -> SlideComment {
        let author = authors.first { $0.id == element.attribute("authorId") }
        var comment = SlideComment(
            id: element.attribute("id") ?? newID(), author: author?.name ?? "", initials: author?.initials ?? "",
            date: date(element.attribute("created")), text: bodyText(element.firstChild(named: "txBody")), format: .modern
        )
        comment.isResolved = ["resolved", "closed"].contains(element.attribute("status") ?? "")
        if let position = element.firstChild(named: "pos"),
           let x = position.attribute("x").flatMap(Int.init), let y = position.attribute("y").flatMap(Int.init) {
            comment.position = CGPoint(x: EMU.points(x), y: EMU.points(y))
        }
        return comment
    }

    private static func bodyText(_ body: XMLElement?) -> String {
        guard let body else { return "" }
        return body.children(named: "p").map { paragraph in
            paragraph.children.compactMap { child in
                child.name == "br" ? "\n" : child.firstChild(named: "t")?.text
            }.joined()
        }.joined(separator: "\n")
    }

    // MARK: - Writing

    /// A slide's comments in the older format. A comment read from the file
    /// keeps its number and is written as read, changed only where it was
    /// edited; each author's new comments are numbered on from the highest
    /// number that author has used.
    public static func legacyXML(_ comments: [SlideComment], authors: inout [CommentAuthor], existing: Data? = nil) -> String {
        let namespaces = ["a": OOXML.drawingML, "r": OOXML.relationshipsNS, "p": OOXML.presentationML]
        let known = authors
        func parsed(_ source: String?) -> XMLElement? {
            source.flatMap { try? XMLLite.parse(Data($0.utf8)) }
        }
        func number(of element: XMLElement) -> (author: Int, index: Int)? {
            guard let author = element.attribute("authorId").flatMap(Int.init),
                  let index = element.attribute("idx").flatMap(Int.init) else { return nil }
            return (author, index)
        }
        for element in comments.flatMap({ [$0] + $0.replies }).compactMap({ parsed($0.source) }) {
            guard let number = number(of: element), let position = authors.firstIndex(where: { $0.id == number.author }) else { continue }
            authors[position].lastIndex = max(authors[position].lastIndex, number.index)
        }
        func author(named name: String, initials: String) -> Int {
            if let existing = authors.first(where: { $0.name == name }) { return existing.id }
            let id = (authors.map(\.id).max() ?? -1) + 1
            authors.append(CommentAuthor(
                id: id, name: name, initials: initials, lastIndex: 0, colorIndex: (authors.map(\.colorIndex).max() ?? -1) + 1
            ))
            return id
        }
        func position(_ point: CGPoint) -> (x: String, y: String) {
            (String(Int(point.x * legacyUnitsPerPoint)), String(Int(point.y * legacyUnitsPerPoint)))
        }
        func entry(_ comment: SlideComment, parent: (author: Int, index: Int)?) -> XMLElement? {
            if let element = parsed(comment.source) {
                let read = legacyComment(element, authors: known)
                if read.text != comment.text { element.firstChild(named: "text")?.setText(comment.text) }
                if read.date != comment.date { element.setAttribute("dt", string(comment.date)) }
                if read.position != comment.position, let point = comment.position, let pos = element.firstChild(named: "pos") {
                    let (x, y) = position(point)
                    pos.setAttribute("x", x)
                    pos.setAttribute("y", y)
                }
                return element
            }
            let authorID = author(named: comment.author, initials: comment.initials)
            let index = authors.firstIndex { $0.id == authorID } ?? 0
            authors[index].lastIndex += 1
            let (x, y) = position(comment.position ?? .zero)
            var xml = "<p:cm authorId=\"\(authorID)\" dt=\"\(string(comment.date))\" idx=\"\(authors[index].lastIndex)\">"
                + "<p:pos x=\"\(x)\" y=\"\(y)\"/><p:text>\(XMLLite.escape(comment.text))</p:text>"
            if let parent {
                xml += "<p:extLst><p:ext uri=\"\(threadingExtension)\"><p15:threadingInfo xmlns:p15=\"\(threadingNamespace)\" "
                    + "timeZoneBias=\"0\"><p15:parentCm authorId=\"\(parent.author)\" idx=\"\(parent.index)\"/>"
                    + "</p15:threadingInfo></p:ext></p:extLst>"
            }
            return XMLLite.fragment(xml + "</p:cm>", namespaces: namespaces)
        }
        var entries: [XMLElement] = []
        for thread in comments {
            guard let element = entry(thread, parent: nil) else { continue }
            entries.append(element)
            let parent = number(of: element)
            entries += thread.replies.compactMap { entry($0, parent: parent) }
        }
        func list(in root: XMLElement) -> String? {
            let first = root.children.firstIndex { $0.name == "cm" } ?? root.children.firstIndex { $0.name == "extLst" }
                ?? root.children.count
            root.children(named: "cm").forEach(root.removeChild)
            for (offset, entry) in entries.enumerated() { root.insertChild(entry, at: first + offset) }
            return XMLLite.serialize(root)
        }
        let read = existing.flatMap { try? XMLLite.parse($0) }.flatMap { $0.name == "cmLst" ? $0 : nil }
        return read.flatMap(list) ?? list(in: XMLElement(
            name: "cmLst", qualifiedName: "p:cmLst", attributes: [:],
            qualifiedAttributes: Dictionary(uniqueKeysWithValues: namespaces.map { ("xmlns:\($0.key)", $0.value) })
        )) ?? ""
    }

    /// The older format's list of who has commented. A list read from the
    /// file is kept as read, with each author's highest comment number
    /// brought up to date and new authors added; `nil` when nothing changed.
    public static func legacyAuthorsXML(_ authors: [CommentAuthor], existing: Data? = nil) -> String? {
        func entry(_ author: CommentAuthor) -> String {
            "<p:cmAuthor id=\"\(author.id)\" name=\"\(XMLLite.escape(author.name))\" initials=\"\(XMLLite.escape(author.initials))\" "
                + "lastIdx=\"\(author.lastIndex)\" clrIdx=\"\(author.colorIndex)\"/>"
        }
        if let existing, let root = try? XMLLite.parse(existing), root.name == "cmAuthorLst" {
            var changed = false
            let listed = root.children(named: "cmAuthor")
            for element in listed {
                guard let author = authors.first(where: { String($0.id) == element.attribute("id") }),
                      element.attribute("lastIdx") != String(author.lastIndex) else { continue }
                element.setAttribute("lastIdx", String(author.lastIndex))
                changed = true
            }
            let ids = Set(listed.compactMap { $0.attribute("id") })
            let added = authors.filter { !ids.contains(String($0.id)) }
            let index = root.children.firstIndex { $0.name == "extLst" } ?? root.children.count
            for (offset, author) in added.enumerated() {
                guard let element = XMLLite.fragment(entry(author), namespaces: ["p": OOXML.presentationML]) else { continue }
                root.insertChild(element, at: index + offset)
                changed = true
            }
            guard changed else { return nil }
            if let xml = XMLLite.serialize(root) { return xml }
        }
        return "<p:cmAuthorLst xmlns:a=\"\(OOXML.drawingML)\" xmlns:r=\"\(OOXML.relationshipsNS)\" xmlns:p=\"\(OOXML.presentationML)\">"
            + authors.map(entry).joined() + "</p:cmAuthorLst>"
    }

    /// A slide's comments in the newer format. A comment or reply read from
    /// the file is written as read, changed only where it was edited; one
    /// added here is anchored as the others are.
    public static func modernXML(
        _ comments: [SlideComment], authors: inout [ModernCommentAuthor], existing: Data? = nil
    ) -> String {
        let namespaces = ["p188": modernNamespace, "a": OOXML.drawingML, "r": OOXML.relationshipsNS]
        let known = authors
        func authorID(_ comment: SlideComment) -> String {
            if let existing = authors.first(where: { $0.name == comment.author }) { return existing.id }
            let author = ModernCommentAuthor(
                id: newID(), name: comment.author, initials: comment.initials, userID: comment.author, providerID: "None"
            )
            authors.append(author)
            return author.id
        }
        func paragraphs(_ text: String) -> String {
            text.components(separatedBy: "\n").map { line in
                line.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>"
                    : "<a:p><a:r><a:rPr lang=\"en-US\"/><a:t>\(XMLLite.escape(line))</a:t></a:r></a:p>"
            }.joined()
        }
        func body(_ text: String) -> String {
            "<p188:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs(text))</p188:txBody>"
        }
        func parsed(_ source: String?) -> XMLElement? {
            source.flatMap { try? XMLLite.parse(Data($0.utf8)) }
        }
        /// Brings an element read from the file in line with what was edited.
        func update(_ element: XMLElement, to comment: SlideComment, isThread: Bool) {
            let read = modernComment(element, authors: known)
            if read.text != comment.text {
                let lines = XMLLite.fragment("<a:fragment>\(paragraphs(comment.text))</a:fragment>", namespaces: namespaces)?.children ?? []
                if let txBody = element.firstChild(named: "txBody") {
                    for paragraph in txBody.children(named: "p") { txBody.removeChild(paragraph) }
                    for line in lines { txBody.insertChild(line, at: txBody.children.count) }
                } else if let txBody = XMLLite.fragment(body(comment.text), namespaces: namespaces) {
                    let extensions = element.children.firstIndex { $0.name == "extLst" } ?? element.children.count
                    element.insertChild(txBody, at: extensions)
                }
            }
            if read.author != comment.author { element.setAttribute("authorId", authorID(comment)) }
            if read.date != comment.date { element.setAttribute("created", string(comment.date)) }
            guard isThread else { return }
            if read.isResolved != comment.isResolved {
                element.setAttribute("status", comment.isResolved ? "resolved" : nil)
            }
            if read.position != comment.position {
                let pos = element.firstChild(named: "pos")
                if let point = comment.position {
                    let x = String(EMU.from(points: point.x)), y = String(EMU.from(points: point.y))
                    if let pos {
                        pos.setAttribute("x", x)
                        pos.setAttribute("y", y)
                    } else if let pos = XMLLite.fragment("<p188:pos x=\"\(x)\" y=\"\(y)\"/>", namespaces: namespaces) {
                        let anchor = element.children.lastIndex { $0.name.hasSuffix("MkLst") }.map { $0 + 1 } ?? 0
                        element.insertChild(pos, at: anchor)
                    }
                } else if let pos {
                    element.removeChild(pos)
                }
            }
        }
        func reply(_ reply: SlideComment) -> XMLElement? {
            if let element = parsed(reply.source) {
                update(element, to: reply, isThread: false)
                return element
            }
            return XMLLite.fragment(
                "<p188:reply id=\"\(reply.id)\" authorId=\"\(authorID(reply))\" created=\"\(string(reply.date))\">"
                    + body(reply.text) + "</p188:reply>",
                namespaces: namespaces
            )
        }
        // The anchor a new comment borrows: the slide's, from another comment.
        let anchor = comments.lazy.compactMap { parsed($0.source) }
            .compactMap { $0.children.first { $0.name.hasSuffix("MkLst") } }.first.flatMap { XMLLite.serialize($0) } ?? ""

        let entries = comments.compactMap { thread -> XMLElement? in
            let replies = thread.replies.compactMap(reply)
            guard let element = parsed(thread.source) else {
                let status = thread.isResolved ? " status=\"resolved\"" : ""
                let position = thread.position.map { "<p188:pos x=\"\(EMU.from(points: $0.x))\" y=\"\(EMU.from(points: $0.y))\"/>" } ?? ""
                let element = XMLLite.fragment(
                    "<p188:cm id=\"\(thread.id)\" authorId=\"\(authorID(thread))\" created=\"\(string(thread.date))\"\(status)>"
                        + anchor + position + body(thread.text) + "</p188:cm>",
                    namespaces: namespaces
                )
                if let element, !replies.isEmpty, let list = XMLLite.fragment("<p188:replyLst/>", namespaces: namespaces) {
                    for reply in replies { list.insertChild(reply, at: list.children.count) }
                    element.insertChild(list, at: element.children.firstIndex { $0.name == "txBody" } ?? element.children.count)
                }
                return element
            }
            update(element, to: thread, isThread: true)
            let list = element.firstChild(named: "replyLst")
            let readReplies = list?.children(named: "reply") ?? []
            if replies.isEmpty {
                if let list {
                    readReplies.forEach(list.removeChild)
                    if list.children.isEmpty { element.removeChild(list) }
                }
            } else if let list {
                let first = list.children.firstIndex { $0.name == "reply" } ?? list.children.count
                readReplies.forEach(list.removeChild)
                for (offset, reply) in replies.enumerated() { list.insertChild(reply, at: first + offset) }
            } else if let list = XMLLite.fragment("<p188:replyLst/>", namespaces: namespaces) {
                for reply in replies { list.insertChild(reply, at: list.children.count) }
                let index = element.children.firstIndex { $0.name == "txBody" || $0.name == "extLst" } ?? element.children.count
                element.insertChild(list, at: index)
            }
            return element
        }
        func list(in root: XMLElement) -> String? {
            let first = root.children.firstIndex { $0.name == "cm" } ?? root.children.firstIndex { $0.name == "extLst" }
                ?? root.children.count
            root.children(named: "cm").forEach(root.removeChild)
            for (offset, entry) in entries.enumerated() { root.insertChild(entry, at: first + offset) }
            return XMLLite.serialize(root)
        }
        let read = existing.flatMap { try? XMLLite.parse($0) }.flatMap { $0.name == "cmLst" ? $0 : nil }
        return read.flatMap(list) ?? list(in: XMLElement(
            name: "cmLst", qualifiedName: "p188:cmLst", attributes: [:],
            qualifiedAttributes: Dictionary(uniqueKeysWithValues: namespaces.map { ("xmlns:\($0.key)", $0.value) })
        )) ?? ""
    }

    /// The newer format's list of who has commented. A list read from the
    /// file is kept as read, with only the authors new to it added; `nil`
    /// when it has none to add.
    public static func modernAuthorsXML(_ authors: [ModernCommentAuthor], existing: Data? = nil) -> String? {
        func entry(_ author: ModernCommentAuthor) -> String {
            "<p188:author id=\"\(XMLLite.escape(author.id))\" name=\"\(XMLLite.escape(author.name))\" "
                + "initials=\"\(XMLLite.escape(author.initials))\" userId=\"\(XMLLite.escape(author.userID))\" "
                + "providerId=\"\(XMLLite.escape(author.providerID))\"/>"
        }
        if let existing, let root = try? XMLLite.parse(existing), root.name == "authorLst" {
            let listed = Set(root.children(named: "author").compactMap { $0.attribute("id") })
            let added = authors.filter { !listed.contains($0.id) }
            guard !added.isEmpty else { return nil }
            let namespaces = ["p188": modernNamespace]
            let index = root.children.firstIndex { $0.name == "extLst" } ?? root.children.count
            for (offset, author) in added.enumerated() {
                guard let element = XMLLite.fragment(entry(author), namespaces: namespaces) else { continue }
                root.insertChild(element, at: index + offset)
            }
            if let xml = XMLLite.serialize(root) { return xml }
        }
        return "<p188:authorLst xmlns:a=\"\(OOXML.drawingML)\" xmlns:r=\"\(OOXML.relationshipsNS)\" xmlns:p188=\"\(modernNamespace)\">"
            + authors.map(entry).joined() + "</p188:authorLst>"
    }
}
