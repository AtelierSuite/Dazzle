#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A Keynote table (`TST.TableInfoArchive`) as a DrawingML table.
///
/// The table model keeps cells in tiles of rows, each row a buffer of
/// packed cells with a 16-bit offset per column. A cell names its value
/// and styles by keys into the data store's lists: strings, styles, number
/// formats and rich text. Styles not set on a cell come from its region:
/// header rows, header columns, footer rows or the body.
public struct KeynoteTable {
    public let archive: KeynoteArchive
    public let styles: KeynoteStyles
    public let text: KeynoteText
    /// The document's locale, which numbers and dates are written in.
    public let locale: Locale

    private struct Cell {
        var type: UInt8 = 0
        var number: Double?
        var seconds: Double?
        var string: UInt32?
        var richText: UInt32?
        var cellStyle: UInt32?
        var textStyle: UInt32?
        var numberFormat: UInt32?
        var currencyFormat: UInt32?
        var dateFormat: UInt32?
    }

    private struct Merge {
        var rowSpan: Int
        var columnSpan: Int
    }

    /// The `a:graphic` for a table model, with its size in points.
    public func graphic(model: KeynoteArchive.Object) -> (xml: String, size: CGSize)? {
        let message = model.message
        guard model.type == KeynoteType.tableModel, let store = message.message(4) else { return nil }
        let rowCount = message.int(6) ?? 0
        let columnCount = message.int(7) ?? 0
        // A table too big to draw on a slide is left to its stand-in.
        guard rowCount > 0, columnCount > 0, rowCount * columnCount <= Self.maximumCells else { return nil }
        let headerRows = message.int(9) ?? 0
        let headerColumns = message.int(10) ?? 0
        let footerRows = message.int(11) ?? 0

        // Sizes and visibility: an entry only for a row or column that differs.
        let rowHeaders = store.message(1)?.references(2).compactMap { archive[$0]?.message } ?? []
        let rows = headers(rowHeaders, count: rowCount, default: message.float(16) ?? 20)
        let columns = headers(archive[store.reference(2)].map { [$0.message] } ?? [], count: columnCount,
                              default: message.float(17) ?? 100)

        let strings = list(store.reference(4)) { $0.string(3) }
        let cellStyles = list(store.reference(5)) { $0.reference(4) }
        let formats = list(store.reference(22) ?? store.reference(11)) { $0.message(6) }
        let richTexts = list(store.reference(17)) { $0.reference(9) ?? $0.reference(4) }
        let cells = self.cells(store.message(3))
        let merges = self.merges(owner: message.message(47)).merging(self.merges(archive[store.reference(13)]?.message)) { kept, _ in kept }

        let tableStyle = message.reference(3)
        func tableProperty<Value>(_ read: (ProtoMessage) -> Value?) -> Value? {
            styles.resolve(tableStyle) { $0.type == KeynoteType.tableStyle ? $0.message.message(11).flatMap(read) : nil }
        }
        let bandedFill = tableProperty { $0.bool(1) } == true ? tableProperty { $0.message(2) } : nil

        let visibleRows = rows.indices.filter { !rows[$0].hidden }
        let visibleColumns = columns.indices.filter { !columns[$0].hidden }
        // Merged ranges, kept within the table and counted in the rows and
        // columns shown. A range whose top row or left column is hidden is
        // anchored at the first shown, which takes the hidden cell's value.
        // One that overlaps a range already merged is left unmerged.
        var spans: [[Int]: Merge] = [:]
        var mergedFrom: [[Int]: [Int]] = [:]
        var coveredBy: [[Int]: [Int]] = [:]
        for (origin, merge) in merges.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            let rowRange = origin[0]..<min(origin[0] + merge.rowSpan, rowCount)
            let columnRange = origin[1]..<min(origin[1] + merge.columnSpan, columnCount)
            let shownRows = rowRange.filter { !rows[$0].hidden }
            let shownColumns = columnRange.filter { !columns[$0].hidden }
            guard let top = shownRows.first, let left = shownColumns.first, shownRows.count * shownColumns.count > 1 else { continue }
            let range = rowRange.flatMap { row in columnRange.map { [row, $0] } }
            guard range.allSatisfy({ coveredBy[$0] == nil && spans[$0] == nil }) else { continue }
            let anchor = [top, left]
            spans[anchor] = Merge(rowSpan: shownRows.count, columnSpan: shownColumns.count)
            mergedFrom[anchor] = origin
            for cell in range where cell != anchor { coveredBy[cell] = anchor }
        }

        var rowXML = ""
        for row in visibleRows {
            let isHeaderRow = row < headerRows
            let isFooter = row >= rowCount - footerRows && !isHeaderRow
            var cellXML = ""
            for column in visibleColumns {
                let cell = cells[mergedFrom[[row, column]] ?? [row, column]] ?? Cell()
                let isHeaderColumn = column < headerColumns
                // Header rows win over header columns where they cross.
                let regionStyle = message.reference(isHeaderRow ? 19 : isFooter ? 21 : isHeaderColumn ? 20 : 18)
                let regionText = message.reference(isHeaderRow ? 25 : isFooter ? 27 : isHeaderColumn ? 26 : 24)
                let ownStyle = cell.cellStyle.flatMap { cellStyles[$0] }
                let cellStyle = ownStyle ?? regionStyle
                let textStyle = cell.textStyle.flatMap { cellStyles[$0] } ?? regionText
                func cellProperty<Value>(_ read: (ProtoMessage) -> Value?) -> Value? {
                    styles.resolve(cellStyle) { $0.type == KeynoteType.cellStyle ? $0.message.message(11).flatMap(read) : nil }
                }

                var attributes = ""
                if let merge = spans[[row, column]] {
                    if merge.columnSpan > 1 { attributes += " gridSpan=\"\(merge.columnSpan)\"" }
                    if merge.rowSpan > 1 { attributes += " rowSpan=\"\(merge.rowSpan)\"" }
                }
                // A cell inside a range continues it from the left, from above or both.
                if let anchor = coveredBy[[row, column]] {
                    if column > anchor[1] { attributes += " hMerge=\"1\"" }
                    if row > anchor[0] { attributes += " vMerge=\"1\"" }
                }

                let paragraphs: String
                if cell.type == 9, let key = cell.richText, let payload = archive[richTexts[key]],
                   let rich = text.paragraphs(archive[payload.message.reference(1)]) {
                    paragraphs = rich
                } else {
                    paragraphs = text.paragraphs(plain: display(cell, strings: strings, formats: formats), style: textStyle)
                }

                let padding = cellProperty { $0.message(9) }
                func inset(_ field: Int) -> Int { KeynoteUnits.emu(padding?.float(field) ?? 4) }
                let anchor = switch cellProperty({ $0.int(8) }) ?? 0 {
                case 1: "ctr"
                case 2: "b"
                default: "t"
                }
                var fill = cellProperty { $0.message(1) }
                let bodyRow = row - headerRows
                if ownStyle == nil, !isHeaderRow, !isHeaderColumn, !isFooter, bodyRow % 2 == 1, let bandedFill {
                    fill = bandedFill
                }
                let fillXML = KeynoteStyles.fill(fill, opacity: 1) { _ in nil } ?? "<a:noFill/>"
                let borders = [("lnL", 13), ("lnR", 11), ("lnT", 10), ("lnB", 12)].map { element, field in
                    KeynoteStyles.line(cellProperty { $0.message(field) }, head: nil, tail: nil, opacity: 1, element: element)
                }.joined()
                cellXML += """
                    <a:tc\(attributes)><a:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</a:txBody>\
                    <a:tcPr marL="\(inset(1))" marR="\(inset(3))" marT="\(inset(2))" marB="\(inset(4))" anchor="\(anchor)">\
                    \(borders)\(fillXML)</a:tcPr></a:tc>
                    """
            }
            rowXML += "<a:tr h=\"\(KeynoteUnits.emu(rows[row].size))\">\(cellXML)</a:tr>"
        }

        let grid = visibleColumns.map { "<a:gridCol w=\"\(KeynoteUnits.emu(columns[$0].size))\"/>" }.joined()
        let size = CGSize(
            width: visibleColumns.reduce(0) { $0 + columns[$1].size },
            height: visibleRows.reduce(0) { $0 + rows[$1].size }
        )
        let xml = """
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>\
            <a:tblPr\(headerRows > 0 ? " firstRow=\"1\"" : "")/><a:tblGrid>\(grid)</a:tblGrid>\(rowXML)</a:tbl>\
            </a:graphicData></a:graphic>
            """
        return (xml, size)
    }

    /// The size, in points, a table model's visible rows and columns add up
    /// to, for a table the rest of which can't be read. A table too big to
    /// draw has none: its stand-in takes the drawable's frame.
    public func size(model: KeynoteArchive.Object) -> CGSize? {
        let message = model.message
        let rowCount = message.int(6) ?? 0
        let columnCount = message.int(7) ?? 0
        guard rowCount > 0, columnCount > 0, rowCount * columnCount <= Self.maximumCells else { return nil }
        let store = message.message(4)
        let rows = headers(store?.message(1)?.references(2).compactMap { archive[$0]?.message } ?? [], count: rowCount,
                           default: message.float(16) ?? 20)
        let columns = headers(archive[store?.reference(2)].map { [$0.message] } ?? [], count: columnCount,
                              default: message.float(17) ?? 100)
        let size = CGSize(
            width: columns.filter { !$0.hidden }.reduce(0) { $0 + $1.size },
            height: rows.filter { !$0.hidden }.reduce(0) { $0 + $1.size }
        )
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// The most cells a table is drawn with. Keynote's own tables are
    /// rarely more than a few hundred; one pasted from a spreadsheet can
    /// be far bigger than any slide shows.
    static let maximumCells = 20_000

    // MARK: - Data store

    /// Row or column sizes, in points, and whether each is hidden.
    private func headers(_ buckets: [ProtoMessage], count: Int, default size: Double) -> [(size: Double, hidden: Bool)] {
        var result = Array(repeating: (size: size, hidden: false), count: count)
        for bucket in buckets {
            for header in bucket.messages(2) {
                guard let index = header.int(1), result.indices.contains(index) else { continue }
                if let value = header.float(2), value > 0 { result[index].size = value }
                result[index].hidden = (header.int(3) ?? 0) != 0
            }
        }
        return result
    }

    /// A `TST.TableDataList`'s entries by key, including those kept in segments.
    private func list<Value>(_ identifier: UInt64?, _ read: (ProtoMessage) -> Value?) -> [UInt32: Value] {
        guard let list = archive[identifier]?.message else { return [:] }
        var result: [UInt32: Value] = [:]
        let entries = list.messages(3) + list.references(4).flatMap { archive[$0]?.message.messages(3) ?? [] }
        for entry in entries {
            if let key = entry.uint(1), let value = read(entry) { result[UInt32(truncatingIfNeeded: key)] = value }
        }
        return result
    }

    /// Every stored cell, by row and column.
    private func cells(_ tiles: ProtoMessage?) -> [[Int]: Cell] {
        guard let tiles else { return [:] }
        let tileSize = tiles.int(2) ?? 256
        var result: [[Int]: Cell] = [:]
        for entry in tiles.messages(1) {
            guard let tile = archive[entry.reference(2)]?.message else { continue }
            let firstRow = (entry.int(1) ?? 0) * tileSize
            for row in tile.messages(5) {
                // Cells as Keynote has kept them since 2019, then as it kept them before.
                let storage: (buffer: [UInt8], offsets: [UInt8])
                if case .bytes(let buffer)? = row.fields[6]?.last, case .bytes(let offsets)? = row.fields[7]?.last, !offsets.isEmpty {
                    storage = (Array(buffer), Array(offsets))
                } else if case .bytes(let buffer)? = row.fields[3]?.last, case .bytes(let offsets)? = row.fields[4]?.last {
                    storage = (Array(buffer), Array(offsets))
                } else {
                    continue
                }
                let scale = row.bool(8) == true ? 4 : 1
                for column in 0..<(storage.offsets.count / 2) {
                    let raw = Int(storage.offsets[column * 2]) | Int(storage.offsets[column * 2 + 1]) << 8
                    guard raw != 0xFFFF, let cell = Self.cell(storage.buffer, at: raw * scale) else { continue }
                    result[[firstRow + (row.int(1) ?? 0), column]] = cell
                }
            }
        }
        return result
    }

    /// One packed cell: a version, a type, then a word of flags saying which
    /// of the optional fields follow, in flag order.
    private static func cell(_ buffer: [UInt8], at offset: Int) -> Cell? {
        guard offset + 12 <= buffer.count else { return nil }
        guard buffer[offset] >= 5 else { return olderCell(buffer, at: offset) }
        var cell = Cell(type: buffer[offset + 1])
        func word(_ at: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(buffer[at + $1]) << (8 * UInt32($1)) }
        }
        let flags = word(offset + 8)
        var cursor = offset + 12
        func take(_ length: Int) -> Int? {
            guard cursor + length <= buffer.count else { return nil }
            defer { cursor += length }
            return cursor
        }
        if flags & 0x1 != 0, let at = take(16) { cell.number = decimal128(Array(buffer[at..<at + 16])) }
        if flags & 0x2 != 0, let at = take(8) {
            cell.number = Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(buffer[at + $1]) << (8 * UInt64($1)) })
        }
        if flags & 0x4 != 0, let at = take(8) {
            cell.seconds = Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(buffer[at + $1]) << (8 * UInt64($1)) })
        }
        // Every field after the values is a four-byte key.
        for bit in 3..<21 {
            guard flags & (1 << bit) != 0, let at = take(4) else { continue }
            let key = word(at)
            switch 1 << bit {
            case 0x8: cell.string = key
            case 0x10: cell.richText = key
            case 0x20: cell.cellStyle = key
            case 0x40: cell.textStyle = key
            case 0x2000: cell.numberFormat = key
            case 0x4000: cell.currencyFormat = key
            case 0x8000: cell.dateFormat = key
            default: break
            }
        }
        return cell
    }

    /// A packed cell as Keynote kept it before 2019, versions 2 to 4: the
    /// flags come first and the value last, after the keys. Versions before
    /// 4 keep the type a byte later.
    private static func olderCell(_ buffer: [UInt8], at offset: Int) -> Cell? {
        let version = buffer[offset]
        guard (2...4).contains(version) else { return nil }
        var cell = Cell(type: buffer[offset + (version >= 4 ? 1 : 2)])
        func word(_ at: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(buffer[at + $1]) << (8 * UInt32($1)) }
        }
        let flags = word(offset + 4)
        var cursor = offset + 12
        func take(_ length: Int) -> Int? {
            guard cursor + length <= buffer.count else { return nil }
            defer { cursor += length }
            return cursor
        }
        // Styles, formats and formulas, four bytes each, in flag order.
        for bit in [0x2, 0x4, 0x8, 0x80, 0x100, 0x400, 0x800] as [UInt32] where flags & bit != 0 {
            guard let at = take(4) else { return nil }
            switch bit {
            case 0x2: cell.cellStyle = word(at)
            case 0x80: cell.textStyle = word(at)
            default: break
            }
        }
        if flags & 0x200 != 0, let at = take(4) { cell.richText = word(at) }
        for bit in [0x1000, 0x2000] as [UInt32] where flags & bit != 0 { _ = take(4) }
        if flags & 0x10 != 0, let at = take(4) { cell.string = word(at) }
        func double(_ at: Int) -> Double {
            Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(buffer[at + $1]) << (8 * UInt64($1)) })
        }
        if flags & 0x20 != 0, let at = take(8) { cell.number = double(at) }
        if flags & 0x40 != 0, let at = take(8) { cell.seconds = double(at) }
        return cell
    }

    /// An IEEE 754 decimal128 in binary integer form, little-endian.
    public static func decimal128(_ bytes: [UInt8]) -> Double {
        let exponent = (Int(bytes[15] & 0x7F) << 7 | Int(bytes[14]) >> 1) - 0x1820
        var coefficient = 0.0
        for index in stride(from: 13, through: 0, by: -1) {
            coefficient = coefficient * 256 + Double(bytes[index])
        }
        coefficient += Double(bytes[14] & 1) * pow(2, 112)
        let value = coefficient * pow(10, Double(exponent))
        return bytes[15] & 0x80 != 0 ? -value : value
    }

    /// Merged ranges by their top-left cell, `[row, column]`, as current
    /// files keep them: one formula per range, its node a colon tract
    /// naming the columns and rows it spans.
    private func merges(owner: ProtoMessage?) -> [[Int]: Merge] {
        var result: [[Int]: Merge] = [:]
        for pair in owner?.message(2)?.messages(3) ?? [] {
            guard let formula = pair.message(2) else { continue }
            let hostColumn = formula.int(2) ?? 0
            let hostRow = formula.int(3) ?? 0
            for node in formula.message(1)?.messages(1) ?? [] {
                guard let tract = node.message(40) else { continue }
                func span(absolute: Int, relative: Int, host: Int) -> (Int, Int)? {
                    if let range = tract.messages(absolute).first, let begin = range.int(1) {
                        return (begin, range.int(2) ?? begin)
                    }
                    if let range = tract.messages(relative).first, let begin = range.int(1) {
                        return (host + begin, host + (range.int(2) ?? begin))
                    }
                    return nil
                }
                guard let columns = span(absolute: 3, relative: 1, host: hostColumn),
                      let rows = span(absolute: 4, relative: 2, host: hostRow),
                      columns.1 >= columns.0, rows.1 >= rows.0 else { continue }
                result[[rows.0, columns.0]] = Merge(rowSpan: rows.1 - rows.0 + 1, columnSpan: columns.1 - columns.0 + 1)
            }
        }
        return result
    }

    /// Merged ranges as older files keep them, in a region map.
    private func merges(_ map: ProtoMessage?) -> [[Int]: Merge] {
        var result: [[Int]: Merge] = [:]
        for range in map?.messages(1) ?? [] {
            guard let origin = range.message(1)?.uint(1), let size = range.message(2)?.uint(1) else { continue }
            // Cell ids pack the row above the column; sizes the columns above the rows.
            let row = Int(origin >> 16 & 0xFFFF)
            let column = Int(origin & 0xFFFF)
            let columns = Int(size >> 16 & 0xFFFF)
            let rows = Int(size & 0xFFFF)
            guard rows > 0, columns > 0 else { continue }
            result[[row, column]] = Merge(rowSpan: rows, columnSpan: columns)
        }
        return result
    }

    // MARK: - Values

    private func display(_ cell: Cell, strings: [UInt32: String], formats: [UInt32: ProtoMessage]) -> String {
        switch cell.type {
        case 3:
            return cell.string.flatMap { strings[$0] } ?? ""
        case 5:
            guard let seconds = cell.seconds else { return "" }
            let date = Date(timeIntervalSinceReferenceDate: seconds)
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let pattern = cell.dateFormat.flatMap({ formats[$0]?.string(14) }), !pattern.isEmpty {
                formatter.dateFormat = pattern
            } else {
                formatter.dateStyle = .medium
            }
            return formatter.string(from: date)
        case 6:
            return (cell.number ?? 0) != 0 ? "TRUE" : "FALSE"
        case 2, 7, 10:
            guard let number = cell.number else { return "" }
            let format = cell.currencyFormat.flatMap { formats[$0] } ?? cell.numberFormat.flatMap { formats[$0] }
            return self.number(number, format: format)
        default:
            return cell.string.flatMap { strings[$0] } ?? ""
        }
    }

    /// A number as its `TSK.FormatStructArchive` shows it. Decimal places
    /// of 253 mean as many as the number needs.
    private func number(_ value: Double, format: ProtoMessage?) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        // Keynote rounds halves away from zero.
        formatter.roundingMode = .halfUp
        switch format?.int(1) {
        case 257:
            formatter.numberStyle = .currency
            if let code = format?.string(3) { formatter.currencyCode = code }
        case 258:
            formatter.numberStyle = .percent
        case 259:
            formatter.numberStyle = .scientific
        default:
            break
        }
        formatter.usesGroupingSeparator = format?.bool(5) ?? false
        if let places = format?.int(2), places != 253 {
            formatter.minimumFractionDigits = places
            formatter.maximumFractionDigits = places
        } else if format?.int(1) != 257 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 10
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
