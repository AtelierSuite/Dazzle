import Foundation

/// Decompresses the Snappy blocks Keynote stores its object archives in.
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
}
