import Foundation

/// A protocol buffer message read without its schema.
///
/// Keynote's archives are protocol buffers, but only a small part of the
/// schema matters here, so fields are looked up by number and interpreted at
/// the point of use rather than generated from `.proto` files.
struct ProtoMessage: Sendable {
    enum Value: Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    struct DecodingError: Error {}

    private(set) var fields: [Int: [Value]] = [:]

    init() {}

    init<Bytes: Collection<UInt8>>(_ source: Bytes) throws where Bytes.Index == Int {
        let bytes = ArraySlice(source)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let key = try Self.varint(bytes, &index)
            let number = Int(key >> 3)
            guard number > 0 else { throw DecodingError() }
            let value: Value
            switch key & 0x07 {
            case 0:
                value = .varint(try Self.varint(bytes, &index))
            case 1:
                guard index + 8 <= bytes.endIndex else { throw DecodingError() }
                var raw: UInt64 = 0
                for byte in 0..<8 { raw |= UInt64(bytes[index + byte]) << (8 * UInt64(byte)) }
                index += 8
                value = .fixed64(raw)
            case 2:
                let length = Int(try Self.varint(bytes, &index))
                guard length >= 0, index + length <= bytes.endIndex else { throw DecodingError() }
                value = .bytes(bytes[index..<index + length])
                index += length
            case 5:
                guard index + 4 <= bytes.endIndex else { throw DecodingError() }
                var raw: UInt32 = 0
                for byte in 0..<4 { raw |= UInt32(bytes[index + byte]) << (8 * UInt32(byte)) }
                index += 4
                value = .fixed32(raw)
            default:
                throw DecodingError()
            }
            fields[number, default: []].append(value)
        }
    }

    static func varint(_ bytes: ArraySlice<UInt8>, _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.endIndex, shift < 64 else { throw DecodingError() }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    // MARK: - Reading fields

    func has(_ number: Int) -> Bool { fields[number] != nil }

    /// The last occurrence wins, as protocol buffers specify for singular fields.
    func message(_ number: Int) -> ProtoMessage? {
        guard case .bytes(let bytes)? = fields[number]?.last else { return nil }
        return try? ProtoMessage(bytes)
    }

    func messages(_ number: Int) -> [ProtoMessage] {
        (fields[number] ?? []).compactMap {
            guard case .bytes(let bytes) = $0 else { return nil }
            return try? ProtoMessage(bytes)
        }
    }

    func uint(_ number: Int) -> UInt64? {
        switch fields[number]?.last {
        case .varint(let value)?, .fixed64(let value)?: value
        case .fixed32(let value)?: UInt64(value)
        default: nil
        }
    }

    func int(_ number: Int) -> Int? { uint(number).map { Int(truncatingIfNeeded: $0) } }

    func bool(_ number: Int) -> Bool? { uint(number).map { $0 != 0 } }

    func float(_ number: Int) -> Double? {
        switch fields[number]?.last {
        case .fixed32(let raw)?: Double(Float(bitPattern: raw))
        case .fixed64(let raw)?: Double(bitPattern: raw)
        default: nil
        }
    }

    func string(_ number: Int) -> String? {
        guard case .bytes(let bytes)? = fields[number]?.last else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    func strings(_ number: Int) -> [String] {
        (fields[number] ?? []).compactMap {
            guard case .bytes(let bytes) = $0 else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Repeated integers, whether written packed or one per field.
    func uints(_ number: Int) -> [UInt64] {
        var result: [UInt64] = []
        for value in fields[number] ?? [] {
            switch value {
            case .varint(let raw), .fixed64(let raw):
                result.append(raw)
            case .fixed32(let raw):
                result.append(UInt64(raw))
            case .bytes(let bytes):
                var index = bytes.startIndex
                while index < bytes.endIndex, let raw = try? Self.varint(bytes, &index) {
                    result.append(raw)
                }
            }
        }
        return result
    }

    /// Repeated floats, whether written packed or one per field.
    func floats(_ number: Int) -> [Double] {
        var result: [Double] = []
        for value in fields[number] ?? [] {
            switch value {
            case .fixed32(let raw):
                result.append(Double(Float(bitPattern: raw)))
            case .bytes(let bytes):
                var index = bytes.startIndex
                while index + 4 <= bytes.endIndex {
                    var raw: UInt32 = 0
                    for byte in 0..<4 { raw |= UInt32(bytes[index + byte]) << (8 * UInt32(byte)) }
                    result.append(Double(Float(bitPattern: raw)))
                    index += 4
                }
            default:
                continue
            }
        }
        return result
    }

    // MARK: - Keynote conventions

    /// The identifier inside a `TSP.Reference` or `TSP.DataReference`.
    func reference(_ number: Int) -> UInt64? { message(number)?.uint(1) }

    func references(_ number: Int) -> [UInt64] { messages(number).compactMap { $0.uint(1) } }
}
