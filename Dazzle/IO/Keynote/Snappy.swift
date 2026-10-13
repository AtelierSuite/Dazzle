import Foundation

/// Decompresses, and compresses, the Snappy blocks Keynote stores its
/// object archives in.
///
/// An `.iwa` file is a run of chunks, each a type byte of zero, a three-byte
/// little-endian length and one raw Snappy block. Unlike the framed Snappy
/// format there is no stream identifier and no checksum.
enum Snappy {
    struct CorruptData: Error {}

    /// Joins every chunk of an `.iwa` file into one stream.
    static func iwaStream(_ data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + 4 <= bytes.count, bytes[offset] == 0 else { throw CorruptData() }
            let length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) << 16
            let start = offset + 4
            guard start + length <= bytes.count else { throw CorruptData() }
            try decompress(bytes[start..<start + length], into: &output)
            offset = start + length
        }
        return output
    }

    /// Appends one raw Snappy block to `output`.
    static func decompress(_ block: ArraySlice<UInt8>, into output: inout [UInt8]) throws {
        var index = block.startIndex
        var expected = 0
        var shift = 0
        while true {
            guard index < block.endIndex, shift < 35 else { throw CorruptData() }
            let byte = block[index]
            index += 1
            expected |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        let base = output.count
        output.reserveCapacity(base + expected)

        while index < block.endIndex {
            let tag = block[index]
            index += 1
            switch tag & 0x03 {
            case 0:
                var length = Int(tag >> 2)
                if length >= 60 {
                    let extra = length - 59
                    guard index + extra <= block.endIndex else { throw CorruptData() }
                    length = 0
                    for byte in 0..<extra { length |= Int(block[index + byte]) << (8 * byte) }
                    index += extra
                }
                length += 1
                guard index + length <= block.endIndex else { throw CorruptData() }
                output.append(contentsOf: block[index..<index + length])
                index += length
            case 1:
                guard index < block.endIndex else { throw CorruptData() }
                let length = Int((tag >> 2) & 0x07) + 4
                let distance = Int(tag >> 5) << 8 | Int(block[index])
                index += 1
                try copy(distance: distance, length: length, base: base, into: &output)
            case 2:
                guard index + 2 <= block.endIndex else { throw CorruptData() }
                let distance = Int(block[index]) | Int(block[index + 1]) << 8
                index += 2
                try copy(distance: distance, length: Int(tag >> 2) + 1, base: base, into: &output)
            default:
                guard index + 4 <= block.endIndex else { throw CorruptData() }
                var distance = 0
                for byte in 0..<4 { distance |= Int(block[index + byte]) << (8 * byte) }
                index += 4
                try copy(distance: distance, length: Int(tag >> 2) + 1, base: base, into: &output)
            }
        }
        guard output.count - base == expected else { throw CorruptData() }
    }

    /// Repeats earlier output; the source may overlap what is being written.
    private static func copy(distance: Int, length: Int, base: Int, into output: inout [UInt8]) throws {
        guard distance > 0, output.count - distance >= base else { throw CorruptData() }
        let start = output.count - distance
        for offset in 0..<length {
            output.append(output[start + offset])
        }
    }

    // MARK: - Compressing

    /// The most a chunk holds once expanded, as Keynote writes them.
    static let chunkSize = 65_536

    /// Splits a stream into chunks and compresses each, as an `.iwa` file.
    static func iwaFile(_ stream: [UInt8]) -> Data {
        var output = Data()
        var start = 0
        repeat {
            let end = min(start + chunkSize, stream.count)
            let block = compress(stream[start..<end])
            output.append(0)
            output.append(UInt8(block.count & 0xFF))
            output.append(UInt8(block.count >> 8 & 0xFF))
            output.append(UInt8(block.count >> 16 & 0xFF))
            output.append(contentsOf: block)
            start = end
        } while start < stream.count
        return output
    }

    /// One raw Snappy block. Repeats of four bytes or more found through a
    /// small hash table become copies; everything else stays literal. Input
    /// is never more than a chunk, so every copy reaches back under 64 KiB.
    static func compress(_ input: ArraySlice<UInt8>) -> [UInt8] {
        let bytes = Array(input)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / 6 + 8)
        var length = bytes.count
        while length >= 0x80 {
            output.append(UInt8(length & 0x7F) | 0x80)
            length >>= 7
        }
        output.append(UInt8(length))

        var table = [Int](repeating: -1, count: 1 << 14)
        func load(_ index: Int) -> UInt32 {
            UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
        }
        func hash(_ value: UInt32) -> Int { Int((value &* 0x1E35_A7BD) >> 18) }

        var literalStart = 0
        var index = 0
        while index + 4 <= bytes.count {
            let value = load(index)
            let slot = hash(value)
            let candidate = table[slot]
            table[slot] = index
            guard candidate >= 0, index - candidate <= 0xFFFF, load(candidate) == value else {
                index += 1
                continue
            }
            var matched = 4
            while index + matched < bytes.count, bytes[candidate + matched] == bytes[index + matched] { matched += 1 }
            appendLiteral(bytes[literalStart..<index], to: &output)
            appendCopy(distance: index - candidate, length: matched, to: &output)
            index += matched
            literalStart = index
        }
        appendLiteral(bytes[literalStart..<bytes.count], to: &output)
        return output
    }

    private static func appendLiteral(_ literal: ArraySlice<UInt8>, to output: inout [UInt8]) {
        guard !literal.isEmpty else { return }
        let length = literal.count - 1
        if length < 60 {
            output.append(UInt8(length << 2))
        } else if length < 0x100 {
            output.append(60 << 2)
            output.append(UInt8(length))
        } else if length < 0x1_0000 {
            output.append(61 << 2)
            output.append(UInt8(length & 0xFF))
            output.append(UInt8(length >> 8))
        } else {
            output.append(62 << 2)
            output.append(UInt8(length & 0xFF))
            output.append(UInt8(length >> 8 & 0xFF))
            output.append(UInt8(length >> 16))
        }
        output.append(contentsOf: literal)
    }

    /// Copies with a two-byte distance, at most 64 bytes each.
    private static func appendCopy(distance: Int, length: Int, to output: inout [UInt8]) {
        var remaining = length
        while remaining > 0 {
            // Never leave a piece shorter than the four bytes a copy needs.
            var piece = min(remaining, 64)
            if (1..<4).contains(remaining - piece) { piece = remaining - 4 }
            output.append(UInt8((piece - 1) << 2) | 2)
            output.append(UInt8(distance & 0xFF))
            output.append(UInt8(distance >> 8))
            remaining -= piece
        }
    }
}
