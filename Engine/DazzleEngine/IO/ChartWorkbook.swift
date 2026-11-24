import Foundation

/// Patches a chart's embedded workbook in place: only the cells the chart's
/// formulas name, and whose values changed, are written.
extension ChartWriter {
    struct CellRange {
        var formula: String
        var sheet: String
        var cells: [(column: Int, row: Int)]
    }

    /// The cells a series reads, as its formulas name them.
    struct SeriesCells {
        var name: CellRange
        var categories: CellRange
        var values: CellRange
        var sizes: CellRange?
    }

    /// Each plot's series' cells, or `nil` if any series' formulas no longer
    /// fit its data: a series added, a category added or removed, a kind changed.
    static func references(of chart: Chart) -> [[SeriesCells]]? {
        let count = chart.categories.count
        var result: [[SeriesCells]] = []
        for plot in chart.plots {
            var cells: [SeriesCells] = []
            for series in plot.series {
                guard let element = series.source.flatMap(fragment) else { return nil }
                let xy = plot.kind.isXY
                func range(_ name: String, size: Int) -> CellRange? {
                    guard let child = element.firstChild(named: name),
                          let formula = (child.firstChild(named: "strRef") ?? child.firstChild(named: "numRef"))?.firstChild(named: "f")?.text,
                          let range = cellRange(formula), range.cells.count == size else { return nil }
                    return range
                }
                guard let name = range("tx", size: 1), let categories = range(xy ? "xVal" : "cat", size: count),
                      let values = range(xy ? "yVal" : "val", size: count) else { return nil }
                var entry = SeriesCells(name: name, categories: categories, values: values)
                if plot.kind == .bubble {
                    guard let sizes = range("bubbleSize", size: count) else { return nil }
                    entry.sizes = sizes
                }
                cells.append(entry)
            }
            result.append(cells)
        }
        return result
    }

    /// `Sheet1!$B$2:$B$5` as its sheet and cells, for a range along one row or one column.
    static func cellRange(_ formula: String) -> CellRange? {
        let trimmed = formula.trimmed
        guard !trimmed.hasPrefix("("), !trimmed.hasPrefix("["), let bang = trimmed.lastIndex(of: "!"),
              let sheet = Chart.sheetName(in: trimmed) else { return nil }
        let ends = trimmed[trimmed.index(after: bang)...].split(separator: ":", omittingEmptySubsequences: false).map(cellReference)
        guard (1...2).contains(ends.count), let first = ends.first ?? nil, let last = ends.last ?? nil else { return nil }
        let cells: [(column: Int, row: Int)]
        if first.column == last.column, first.row <= last.row {
            cells = (first.row...last.row).map { (first.column, $0) }
        } else if first.row == last.row, first.column <= last.column {
            cells = (first.column...last.column).map { ($0, first.row) }
        } else {
            return nil
        }
        return CellRange(formula: trimmed, sheet: sheet, cells: cells)
    }

    /// `$B$2` or `B2` as a one-based column and row.
    static func cellReference<S: StringProtocol>(_ text: S) -> (column: Int, row: Int)? {
        var column = 0
        var digits = ""
        for character in text where character != "$" {
            if let letter = character.asciiValue, (65...90).contains(letter), digits.isEmpty {
                column = column * 26 + Int(letter - 64)
            } else if character.isASCII, character.isNumber {
                digits.append(character)
            } else {
                return nil
            }
        }
        guard column > 0, let row = Int(digits), row > 0 else { return nil }
        return (column, row)
    }

    enum CellValue: Equatable {
        case number(Double)
        case text(String)
        case empty
    }

    struct CellWrite {
        var sheet: String
        var column: Int
        var row: Int
        var value: CellValue
    }

    /// The cells whose values the chart changed since it was read.
    static func changedCells(of chart: Chart, references: [[SeriesCells]]) -> [CellWrite] {
        let count = chart.categories.count
        let numbered = chart.kind.isXY || (chart.categoryFormat != nil && chart.categories.allSatisfy { Double($0) != nil })
        var writes: [CellWrite] = []
        func add(_ range: CellRange, _ index: Int, _ value: CellValue) {
            let cell = range.cells[index]
            writes.append(CellWrite(sheet: range.sheet, column: cell.column, row: cell.row, value: value))
        }
        func padded<T>(_ list: [T?], _ size: Int) -> [T?] {
            (0..<size).map { list.indices.contains($0) ? list[$0] : nil }
        }
        func numbers(_ list: [Double?], against original: [Double?], into range: CellRange) {
            let new = padded(list, count)
            let old = padded(original, count)
            for index in 0..<count where new[index] != old[index] {
                add(range, index, new[index].map(CellValue.number) ?? .empty)
            }
        }
        for (plot, cells) in zip(chart.plots, references) {
            for (series, cells) in zip(plot.series, cells) {
                guard let element = series.source.flatMap(fragment) else { continue }
                if series.name != Chart.cachedText(in: element.firstChild(named: "tx")) ?? "" {
                    add(cells.name, 0, .text(series.name))
                }
                if plot.kind.isXY {
                    numbers(chart.categories.map { Double($0) }, against: Chart.numbers(in: element.firstChild(named: "xVal")), into: cells.categories)
                    numbers(series.values, against: Chart.numbers(in: element.firstChild(named: "yVal")), into: cells.values)
                    if let sizes = cells.sizes {
                        numbers(series.sizes, against: Chart.numbers(in: element.firstChild(named: "bubbleSize")), into: sizes)
                    }
                } else {
                    let category = element.firstChild(named: "cat")
                    if numbered {
                        numbers(chart.categories.map { Double($0) }, against: Chart.numbers(in: category), into: cells.categories)
                    } else {
                        let old = padded(Chart.labels(in: category), count)
                        for (index, label) in chart.categories.enumerated() where label != old[index] ?? "" {
                            add(cells.categories, index, .text(label))
                        }
                    }
                    numbers(series.values, against: Chart.numbers(in: element.firstChild(named: "val")), into: cells.values)
                }
            }
        }
        return writes
    }

    /// `original` with the cells the chart changed written into it, or `nil`
    /// if the chart's formulas no longer fit its data or the workbook can't
    /// be patched safely.
    public static func workbook(for chart: Chart, patching original: Data) -> Data? {
        guard let references = references(of: chart) else { return nil }
        let writes = changedCells(of: chart, references: references)
        guard !writes.isEmpty else { return original }
        guard let entries = try? ZipArchive.orderedEntries(in: original) else { return nil }
        var package = WorkbookPackage(entries: entries)
        guard package.apply(writes) else { return nil }
        return try? ZipArchive.archive(entries: package.entries, reusing: (try? ZipArchive.compressedEntries(in: original)) ?? [:])
    }
}

/// An `.xlsx` package's parts, edited as XML.
private struct WorkbookPackage {
    var entries: [(path: String, data: Data)]

    private func data(_ path: String) -> Data? { entries.first { $0.path == path }?.data }

    private func xml(_ path: String) -> XMLElement? { data(path).flatMap { try? XMLLite.parse($0) } }

    private mutating func set(_ path: String, _ root: XMLElement) -> Bool {
        guard let xml = XMLLite.serialize(root), let index = entries.firstIndex(where: { $0.path == path }) else { return false }
        entries[index].data = Data((PackagePath.declaration + xml).utf8)
        return true
    }

    private func relationships(of part: String) -> [Relationship] {
        Relationship.parse(data(PackagePath.relationships(of: part)))
    }

    private func target(of part: String, type: String) -> String? {
        relationships(of: part).first { !$0.isExternal && $0.type.hasSuffix("/" + type) }
            .map { PackagePath.resolve($0.target, from: part) }
    }

    mutating func apply(_ writes: [ChartWriter.CellWrite]) -> Bool {
        let main = Relationship.parse(data("_rels/.rels")).first { $0.type.hasSuffix("/officeDocument") }
            .map { PackagePath.resolve($0.target, from: "") } ?? "xl/workbook.xml"
        guard let workbook = xml(main), let sheets = workbook.firstChild(named: "sheets") else { return false }
        let workbookRelationships = relationships(of: main)
        let stringsPath = target(of: main, type: "sharedStrings")
        let strings = stringsPath.flatMap(xml)
        if stringsPath != nil, strings == nil { return false }
        var removedFormula = false

        for (name, sheetWrites) in Dictionary(grouping: writes, by: \.sheet) {
            guard let id = sheets.children(named: "sheet").first(where: { $0.attribute("name") == name })?.attribute("id"),
                  let relationship = workbookRelationships.first(where: { $0.id == id && !$0.isExternal }) else { return false }
            let path = PackagePath.resolve(relationship.target, from: main)
            guard let sheet = xml(path), let sheetData = sheet.firstChild(named: "sheetData") else { return false }
            var headerNames: [(column: Int, row: Int, name: String)] = []
            for write in sheetWrites {
                guard let cell = Self.cell(column: write.column, row: write.row, in: sheetData) else { return false }
                if let formula = cell.firstChild(named: "f") {
                    // A shared or array formula's first cell holds it for the others.
                    guard formula.attribute("ref") == nil else { return false }
                    cell.removeChild(formula)
                    removedFormula = true
                }
                for child in cell.children where child.name == "v" || child.name == "is" { cell.removeChild(child) }
                switch write.value {
                case .number(let value):
                    cell.setAttribute("t", nil)
                    cell.insertChild(Self.element("v", like: cell, text: Chart.number(value)), at: 0)
                case .text(let text):
                    if let strings {
                        cell.setAttribute("t", "s")
                        cell.insertChild(Self.element("v", like: cell, text: String(Self.index(of: text, in: strings))), at: 0)
                    } else {
                        cell.setAttribute("t", "inlineStr")
                        let inline = Self.element("is", like: cell)
                        inline.insertChild(Self.textElement(text, like: cell), at: 0)
                        cell.insertChild(inline, at: 0)
                    }
                    headerNames.append((write.column, write.row, text))
                case .empty:
                    cell.setAttribute("t", nil)
                }
            }
            guard set(path, sheet) else { return false }
            guard renameTableColumns(headerNames, of: path) else { return false }
        }

        if let stringsPath, let strings, !set(stringsPath, strings) { return false }
        if removedFormula, let chain = target(of: main, type: "calcChain") {
            // The chain lists formula cells; Excel rebuilds it from what is left.
            entries.removeAll { $0.path == chain }
            if let rels = xml(PackagePath.relationships(of: main)) {
                for child in rels.children where PackagePath.resolve(child.attribute("Target") ?? "", from: main) == chain {
                    rels.removeChild(child)
                }
                guard set(PackagePath.relationships(of: main), rels) else { return false }
            }
            if let types = xml("[Content_Types].xml") {
                for child in types.children where child.attribute("PartName") == "/" + chain { types.removeChild(child) }
                guard set("[Content_Types].xml", types) else { return false }
            }
        }
        // Formulas that read the changed cells are worked out again when the workbook opens.
        if let calculation = workbook.firstChild(named: "calcPr") {
            calculation.setAttribute("fullCalcOnLoad", "1")
        } else {
            let after: Set<String> = ["oleSize", "customWorkbookViews", "pivotCaches", "smartTagPr", "smartTagTypes",
                                      "webPublishing", "fileRecoveryPr", "webPublishObjects", "extLst"]
            let before = workbook.children.firstIndex { after.contains($0.name) }
            workbook.insertChild(Self.element("calcPr", like: sheets, attributes: ["fullCalcOnLoad": "1"]), at: before ?? workbook.children.count)
        }
        return set(main, workbook)
    }

    /// Keeps a table's column names in step with the header cells written.
    private mutating func renameTableColumns(_ cells: [(column: Int, row: Int, name: String)], of sheet: String) -> Bool {
        guard !cells.isEmpty else { return true }
        for relationship in relationships(of: sheet) where !relationship.isExternal && relationship.type.hasSuffix("/table") {
            let path = PackagePath.resolve(relationship.target, from: sheet)
            guard let table = xml(path), let ref = table.attribute("ref") else { return false }
            let ends = ref.split(separator: ":").map(ChartWriter.cellReference)
            guard let first = ends.first ?? nil, let last = ends.last ?? nil else { return false }
            guard table.attribute("headerRowCount") != "0", let columns = table.firstChild(named: "tableColumns")?.children(named: "tableColumn")
            else { continue }
            var changed = false
            for cell in cells where cell.row == first.row && (first.column...last.column).contains(cell.column) {
                let index = cell.column - first.column
                guard columns.indices.contains(index) else { continue }
                columns[index].setAttribute("name", cell.name)
                changed = true
            }
            if changed, !set(path, table) { return false }
        }
        return true
    }

    /// The cell at `column` and `row`, made if the sheet has none there yet.
    private static func cell(column: Int, row: Int, in sheetData: XMLElement) -> XMLElement? {
        let rows = sheetData.children(named: "row")
        let numbers = rows.map { $0.attribute("r").flatMap(Int.init) }
        // Rows and cells that leave out their position can't be placed among safely.
        guard !numbers.contains(nil) else { return nil }
        let rowElement: XMLElement
        if let index = numbers.firstIndex(of: row) {
            rowElement = rows[index]
        } else {
            rowElement = element("row", like: sheetData, attributes: ["r": String(row)])
            let next = rows.firstIndex { ($0.attribute("r").flatMap(Int.init) ?? 0) > row }
            let position = next.flatMap { index in sheetData.children.firstIndex { $0 === rows[index] } }
            sheetData.insertChild(rowElement, at: position ?? sheetData.children.count)
        }
        let cells = rowElement.children(named: "c")
        let columns = cells.map { $0.attribute("r").flatMap(ChartWriter.cellReference)?.column }
        guard !columns.contains(nil) else { return nil }
        if let index = columns.firstIndex(of: column) { return cells[index] }
        let reference = ChartWriter.columnLetter(column) + String(row)
        let cell = element("c", like: rowElement, attributes: ["r": reference])
        let next = cells.firstIndex { ($0.attribute("r").flatMap(ChartWriter.cellReference)?.column ?? 0) > column }
        let position = next.flatMap { index in rowElement.children.firstIndex { $0 === cells[index] } }
            ?? rowElement.children.firstIndex { $0.name == "extLst" }
        rowElement.insertChild(cell, at: position ?? rowElement.children.count)
        rowElement.setAttribute("spans", nil)
        return cell
    }

    /// The index of `text` among the shared strings, added if it isn't there.
    private static func index(of text: String, in strings: XMLElement) -> Int {
        let items = strings.children(named: "si")
        if let index = items.firstIndex(where: { item in
            item.firstChild(named: "t")?.text ?? item.children(named: "r").compactMap { $0.firstChild(named: "t")?.text }.joined() == text
        }) {
            return index
        }
        let item = element("si", like: strings)
        item.insertChild(textElement(text, like: strings), at: 0)
        let before = strings.children.firstIndex { $0.name == "extLst" }
        strings.insertChild(item, at: before ?? strings.children.count)
        strings.setAttribute("uniqueCount", String(items.count + 1))
        if let count = strings.attribute("count").flatMap(Int.init) { strings.setAttribute("count", String(count + 1)) }
        return items.count
    }

    /// An element in the same namespace, spelled with the same prefix, as `sibling`.
    private static func element(_ name: String, like sibling: XMLElement, attributes: [String: String] = [:], text: String? = nil) -> XMLElement {
        let prefix = sibling.qualifiedName.firstIndex(of: ":").map { String(sibling.qualifiedName[...$0]) } ?? ""
        let element = XMLElement(name: name, qualifiedName: prefix + name, attributes: attributes, qualifiedAttributes: attributes)
        if let text { element.setText(text) }
        return element
    }

    private static func textElement(_ text: String, like sibling: XMLElement) -> XMLElement {
        let preserves = text.first?.isWhitespace == true || text.last?.isWhitespace == true
        let prefix = sibling.qualifiedName.firstIndex(of: ":").map { String(sibling.qualifiedName[...$0]) } ?? ""
        let element = XMLElement(
            name: "t", qualifiedName: prefix + "t",
            attributes: preserves ? ["space": "preserve"] : [:], qualifiedAttributes: preserves ? ["xml:space": "preserve"] : [:]
        )
        element.setText(text)
        return element
    }
}
