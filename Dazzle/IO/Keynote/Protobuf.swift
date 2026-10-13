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

/// A protocol buffer message as the run of fields it was written as, for
/// changing a few of them and writing the rest back byte for byte.
///
/// Fields keep their order and their encoding, including any Dazzle has no
/// name for, so a message that is only read and written again comes out
/// exactly as it went in.
struct ProtoFields: Sendable, Equatable {
    struct Field: Sendable, Equatable {
        let number: Int
        let wireType: UInt8
        /// The value's bytes, without the key, and for length-delimited
        /// fields without the length.
        var value: [UInt8]
    }

    private(set) var fields: [Field] = []

    init() {}

    init<Bytes: Collection<UInt8>>(_ source: Bytes) throws where Bytes.Index == Int {
        let bytes = ArraySlice(source)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let key = try ProtoMessage.varint(bytes, &index)
            let number = Int(key >> 3)
            let wireType = UInt8(key & 0x07)
            guard number > 0 else { throw ProtoMessage.DecodingError() }
            let start = index
            switch wireType {
            case 0: _ = try ProtoMessage.varint(bytes, &index)
            case 1: index += 8
            case 2:
                let length = Int(try ProtoMessage.varint(bytes, &index))
                guard length >= 0 else { throw ProtoMessage.DecodingError() }
                index += length
                guard index <= bytes.endIndex else { throw ProtoMessage.DecodingError() }
                fields.append(Field(number: number, wireType: wireType, value: Array(bytes[(index - length)..<index])))
                continue
            case 5: index += 4
            default: throw ProtoMessage.DecodingError()
            }
            guard index <= bytes.endIndex else { throw ProtoMessage.DecodingError() }
            fields.append(Field(number: number, wireType: wireType, value: Array(bytes[start..<index])))
        }
    }

    var bytes: [UInt8] {
        var output: [UInt8] = []
        for field in fields {
            output += Self.varint(UInt64(field.number) << 3 | UInt64(field.wireType))
            if field.wireType == 2 { output += Self.varint(UInt64(field.value.count)) }
            output += field.value
        }
        return output
    }

    var message: ProtoMessage { (try? ProtoMessage(bytes)) ?? ProtoMessage() }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var output: [UInt8] = []
        while value >= 0x80 {
            output.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        output.append(UInt8(value))
        return output
    }

    // MARK: - Reading

    func has(_ number: Int) -> Bool { fields.contains { $0.number == number } }

    /// Every length-delimited value of a field, in order.
    func all(_ number: Int) -> [[UInt8]] {
        fields.filter { $0.number == number && $0.wireType == 2 }.map(\.value)
    }

    func uint(_ number: Int) -> UInt64? {
        guard let field = fields.last(where: { $0.number == number && $0.wireType == 0 }) else { return nil }
        var index = 0
        return try? ProtoMessage.varint(field.value[...], &index)
    }

    func nested(_ number: Int) -> ProtoFields? {
        guard let value = all(number).last else { return nil }
        return try? ProtoFields(value)
    }

    // MARK: - Changing

    /// Replaces every occurrence of a field with `values`, written where the
    /// first occurrence was, or at the end if there was none.
    mutating func replace(_ number: Int, wireType: UInt8, with values: [[UInt8]]) {
        let position = fields.firstIndex { $0.number == number } ?? fields.endIndex
        let before = fields[..<position].filter { $0.number != number }
        let after = fields[position...].filter { $0.number != number }
        fields = before + values.map { Field(number: number, wireType: wireType, value: $0) } + after
    }

    mutating func setVarint(_ number: Int, _ value: UInt64) {
        replace(number, wireType: 0, with: [Self.varint(value)])
    }

    mutating func setBool(_ number: Int, _ value: Bool) { setVarint(number, value ? 1 : 0) }

    mutating func setFloat(_ number: Int, _ value: Float) {
        let raw = value.bitPattern
        replace(number, wireType: 5, with: [(0..<4).map { UInt8(truncatingIfNeeded: raw >> (8 * $0)) }])
    }

    mutating func setBytes(_ number: Int, _ value: [UInt8]) {
        replace(number, wireType: 2, with: [value])
    }

    mutating func setRepeatedBytes(_ number: Int, _ values: [[UInt8]]) {
        replace(number, wireType: 2, with: values)
    }

    mutating func remove(_ number: Int) {
        fields.removeAll { $0.number == number }
    }

    /// Changes a nested message, made empty first if it isn't there.
    mutating func update(_ number: Int, _ change: (inout ProtoFields) throws -> Void) rethrows {
        var nested = nested(number) ?? ProtoFields()
        try change(&nested)
        if let index = fields.lastIndex(where: { $0.number == number && $0.wireType == 2 }) {
            fields[index].value = nested.bytes
        } else {
            fields.append(Field(number: number, wireType: 2, value: nested.bytes))
        }
    }
}
