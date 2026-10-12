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

    private(set) var objects: [UInt64: Object] = [:]
    /// Media file contents by data identifier.
    private(set) var data: [UInt64: (name: String, contents: Data)] = [:]

    init(entries: [String: Data]) throws {
        var entries = entries
        // Packages from older versions keep the index zipped inside the package.
        if let index = entries["Index.zip"], let inner = try? ZipArchive.entries(in: index) {
            for (path, contents) in inner { entries[path] = contents }
        }
        let indexFiles = entries.filter { $0.key.hasPrefix("Index/") && $0.key.hasSuffix(".iwa") }
        guard !indexFiles.isEmpty else { throw KeynoteReadError.notKeynote }
        for (_, contents) in indexFiles {
            try read(Snappy.iwaStream(contents))
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

    private mutating func read(_ stream: [UInt8]) throws {
        let bytes = stream[...]
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let headerLength = Int(try ProtoMessage.varint(bytes, &index))
            guard index + headerLength <= bytes.endIndex else { throw KeynoteReadError.corrupt }
            let info = try ProtoMessage(bytes[index..<index + headerLength])
            index += headerLength
            guard let identifier = info.uint(1) else { throw KeynoteReadError.corrupt }
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
                index += length
            }
        }
    }

    subscript(identifier: UInt64?) -> Object? {
        identifier.flatMap { objects[$0] }
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
    static let packageMetadata: UInt32 = 11006
}

enum KeynoteReadError: LocalizedError {
    case notKeynote
    case corrupt
    case notWritable

    var errorDescription: String? {
        switch self {
        case .notKeynote, .corrupt: String(localized: "Error.NotAKeynotePresentation")
        case .notWritable: String(localized: "Error.KeynoteNotWritable")
        }
    }
}
