import Foundation

/// Every object in a Keynote document, read from its `Index/*.iwa` files,
/// along with the media under `Data/`.
///
/// A `.key` file is either a ZIP archive or a package directory; both hold
/// the same entries. Each `.iwa` is a Snappy-compressed run of objects: a
/// length-prefixed `TSP.ArchiveInfo` naming the object's identifier and the
/// type and length of each message that follows it.
struct KeynoteArchive {
    struct Object {
        let identifier: UInt64
        let type: UInt32
        let message: ProtoMessage
    }

    /// One object as an `.iwa` file holds it: its `TSP.ArchiveInfo` and its
    /// messages, exactly as read, so it can be written back unchanged.
    struct Record: Sendable {
        let identifier: UInt64
        var header: ProtoFields
        var messages: [ArraySlice<UInt8>]
    }

    private(set) var objects: [UInt64: Object] = [:]
    /// Media file contents by data identifier.
    private(set) var data: [UInt64: (name: String, contents: Data)] = [:]
    /// Each `.iwa` file's objects, in the order the file has them.
    private(set) var files: [String: [Record]] = [:]
    /// Where each object is kept: its file and its place in it.
    private(set) var locations: [UInt64: (file: String, index: Int)] = [:]
    /// Files with an object changed since they were read.
    private(set) var changedFiles: Set<String> = []
    /// Whether the index came out of an `Index.zip`, as packages from older
    /// versions keep it, which Dazzle reads but doesn't write.
    private(set) var hasZippedIndex = false

    init(entries: [String: Data]) throws {
        var entries = entries
        // Packages from older versions keep the index zipped inside the package.
        if let index = entries["Index.zip"], let inner = try? ZipArchive.entries(in: index) {
            for (path, contents) in inner { entries[path] = contents }
            hasZippedIndex = true
        }
        let indexFiles = entries.filter { $0.key.hasPrefix("Index/") && $0.key.hasSuffix(".iwa") }
        guard !indexFiles.isEmpty else { throw KeynoteReadError.notKeynote }
        for (path, contents) in indexFiles {
            try read(Snappy.iwaStream(contents), file: path)
        }

        let metadata = objects.values.first { $0.type == KeynoteType.packageMetadata }
        for info in metadata?.message.messages(4) ?? [] {
            guard let identifier = info.uint(1) else { continue }
            let name = info.string(4) ?? info.string(3) ?? ""
            if let contents = entries["Data/" + name] {
                data[identifier] = (name, contents)
            }
        }
    }

    private mutating func read(_ stream: [UInt8], file: String) throws {
        let bytes = stream[...]
        var index = bytes.startIndex
        var records: [Record] = []
        while index < bytes.endIndex {
            let headerLength = Int(try ProtoMessage.varint(bytes, &index))
            guard index + headerLength <= bytes.endIndex else { throw KeynoteReadError.corrupt }
            let headerBytes = bytes[index..<index + headerLength]
            let info = try ProtoMessage(headerBytes)
            index += headerLength
            guard let identifier = info.uint(1) else { throw KeynoteReadError.corrupt }
            var messages: [ArraySlice<UInt8>] = []
            for (position, messageInfo) in info.messages(2).enumerated() {
                let length = messageInfo.int(3) ?? 0
                guard length >= 0, index + length <= bytes.endIndex else { throw KeynoteReadError.corrupt }
                // The first message is the object; any after it extend it.
                if position == 0, let type = messageInfo.uint(1) {
                    objects[identifier] = Object(
                        identifier: identifier, type: UInt32(truncatingIfNeeded: type),
                        message: try ProtoMessage(bytes[index..<index + length])
                    )
                }
                messages.append(bytes[index..<index + length])
                index += length
            }
            locations[identifier] = (file, records.count)
            records.append(Record(identifier: identifier, header: try ProtoFields(headerBytes), messages: messages))
        }
        files[file] = records
    }

    // MARK: - Writing

    /// The fields of an object's message, ready to change.
    func fields(_ identifier: UInt64) -> ProtoFields? {
        guard let location = locations[identifier],
              let message = files[location.file]?[location.index].messages.first else { return nil }
        return try? ProtoFields(message)
    }

    /// Puts a changed message in place of an object's own, keeping any
    /// messages that extend it, and its length in the header in step.
    mutating func replace(_ identifier: UInt64, with fields: ProtoFields) throws {
        guard let location = locations[identifier], var record = files[location.file]?[location.index],
              let object = objects[identifier], !record.messages.isEmpty else { throw KeynoteWriteError.missingObject }
        let bytes = fields.bytes
        var infos = record.header.all(2)
        guard !infos.isEmpty else { throw KeynoteWriteError.missingObject }
        var first = try ProtoFields(infos[0])
        first.setVarint(3, UInt64(bytes.count))
        infos[0] = first.bytes
        record.header.setRepeatedBytes(2, infos)
        record.messages[0] = bytes[...]
        files[location.file]?[location.index] = record
        objects[identifier] = Object(identifier: identifier, type: object.type, message: try ProtoMessage(bytes))
        changedFiles.insert(location.file)
    }

    /// An `.iwa` file's contents: each object's header and messages, compressed.
    func iwaData(_ file: String) -> Data? {
        guard let records = files[file] else { return nil }
        var stream: [UInt8] = []
        for record in records {
            let header = record.header.bytes
            stream += ProtoFields.varint(UInt64(header.count))
            stream += header
            for message in record.messages { stream += message }
        }
        return Snappy.iwaFile(stream)
    }

    subscript(identifier: UInt64?) -> Object? {
        identifier.flatMap { objects[$0] }
    }

    /// The locale the document was written in, from its `TSA.DocumentArchive`.
    var locale: Locale {
        let document = objects.values.first { $0.type == KeynoteType.document }
        let identifier = document?.message.message(3)?.message(1)?.string(4)
        return identifier.map(Locale.init(identifier:)) ?? Locale(identifier: "en_US")
    }
}

/// Message type numbers from Keynote's type registry.
enum KeynoteType {
    static let document: UInt32 = 1
    static let show: UInt32 = 2
    static let slideNode: UInt32 = 4
    static let slide: UInt32 = 5
    static let templateSlide: UInt32 = 6
    static let placeholder: UInt32 = 7
    static let slideStyle: UInt32 = 9
    static let note: UInt32 = 15
    static let storage: UInt32 = 2001
    static let shapeInfo: UInt32 = 2011
    static let characterStyle: UInt32 = 2021
    static let paragraphStyle: UInt32 = 2022
    static let listStyle: UInt32 = 2023
    static let textShapeStyle: UInt32 = 2025
    static let shape: UInt32 = 3004
    static let image: UInt32 = 3005
    static let movie: UInt32 = 3007
    static let group: UInt32 = 3008
    static let connectionLine: UInt32 = 3009
    static let shapeStyle: UInt32 = 3015
    static let mediaStyle: UInt32 = 3016
    static let chart: UInt32 = 5021
    static let table: UInt32 = 6000
    static let tableModel: UInt32 = 6001
    static let tableStyle: UInt32 = 6003
    static let cellStyle: UInt32 = 6004
    static let packageMetadata: UInt32 = 11006
}

enum KeynoteWriteError: Error {
    /// An object a change was meant for isn't in the document.
    case missingObject
}

enum KeynoteReadError: LocalizedError {
    case notKeynote
    case corrupt

    var errorDescription: String? {
        String(localized: "Error.NotAKeynotePresentation")
    }
}
