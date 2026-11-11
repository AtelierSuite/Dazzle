import Foundation

/// Writes a chart's data, type, title and legend back into its part, and
/// its data into the workbook PowerPoint opens to edit it.
///
/// The chart part is patched rather than rewritten: a plot whose kind did
/// not change keeps its own XML, and each series its formatting, with only
/// names, categories and values replaced. Everything outside the plot area,
/// title and legend is kept as it was.
public enum ChartWriter {
    public static let namespaces: [String: String] = [
        "c": "http://schemas.openxmlformats.org/drawingml/2006/chart",
        "a": OOXML.drawingML,
        "r": OOXML.relationshipsNS,
    ]

    public static let contentType = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"

    private static func fragment(_ xml: String) -> XMLElement? {
        XMLLite.fragment(xml, namespaces: namespaces)
    }

    // MARK: - Chart part

    /// The chart part's XML with `chart` laid over `original`, or a new part
    /// if there is no original. `workbookRelationship` is the id of the
    /// relationship to an embedded workbook, for a new part.
    public static func data(for chart: Chart, original: Data?, workbookRelationship: String? = nil) -> Data? {
        let root = original.flatMap { try? XMLLite.parse($0) } ?? fragment(skeleton(workbookRelationship: workbookRelationship))
        guard let root, let chartElement = root.firstChild(named: "chart"),
              let area = chartElement.firstChild(named: "plotArea") else { return nil }

        writeTitle(chart.title, into: chartElement)
        writeView3D(chart, into: chartElement)
        writePlots(chart, into: area)
        writeLegend(chart, into: chartElement)

        guard let xml = XMLLite.serialize(root) else { return nil }
        return Data((PackagePath.declaration + xml).utf8)
    }

    private static func skeleton(workbookRelationship: String?) -> String {
        let external = workbookRelationship.map { "<c:externalData r:id=\"\($0)\"><c:autoUpdate val=\"0\"/></c:externalData>" } ?? ""
        return """
            <c:chartSpace xmlns:c="\(namespaces["c"]!)" xmlns:a="\(OOXML.drawingML)" xmlns:r="\(OOXML.relationshipsNS)">\
            <c:date1904 val="0"/><c:roundedCorners val="0"/><c:chart><c:autoTitleDeleted val="1"/><c:plotArea><c:layout/>\
            </c:plotArea><c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/></c:chart><c:spPr><a:noFill/><a:ln><a:noFill/>\
            </a:ln></c:spPr><c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr/></a:pPr><a:endParaRPr lang="en-US"/>\
            </a:p></c:txPr>\(external)</c:chartSpace>
            """
    }

    /// Where a child of `c:chart` goes among its siblings.
    private static func chartChildOrder(_ name: String) -> Int {
        ["title", "autoTitleDeleted", "pivotFmts", "view3D", "floor", "sideWall", "backWall", "plotArea", "legend",
         "plotVisOnly", "dispBlanksAs", "showDLblsOverMax", "extLst"].firstIndex(of: name) ?? 99
    }

    private static func insert(_ child: XMLElement, into parent: XMLElement, order: (String) -> Int) {
        let before = parent.children.firstIndex { order($0.name) > order(child.name) }
        parent.insertChild(child, at: before ?? parent.children.count)
    }

    // MARK: - Title, view and legend

    /// The angle a 3D plot is seen from, for a chart that has none yet.
    private static func writeView3D(_ chart: Chart, into element: XMLElement) {
        guard element.firstChild(named: "view3D") == nil, chart.plots.contains(where: { $0.isThreeD && $0.kind.hasThreeD }) else { return }
        let view = chart.effectiveView3D
        let rightAngles = chart.kind == .pie ? 0 : 1
        guard let view3D = fragment("""
            <c:view3D><c:rotX val="\(view.rotX)"/><c:rotY val="\(view.rotY)"/><c:depthPercent val="\(view.depthPercent)"/>\
            <c:rAngAx val="\(rightAngles)"/></c:view3D>
            """) else { return }
        insert(view3D, into: element, order: chartChildOrder)
    }

    private static func writeTitle(_ title: String?, into chart: XMLElement) {
        let existing = chart.firstChild(named: "title")
        let deleted = chart.firstChild(named: "autoTitleDeleted")
        guard let title, !title.isEmpty else {
            existing.map(chart.removeChild)
            if let deleted { deleted.setAttribute("val", "1") } else if let mark = fragment("<c:autoTitleDeleted val=\"1\"/>") {
                insert(mark, into: chart, order: chartChildOrder)
            }
            return
        }
        deleted?.setAttribute("val", "0")
        let runs = title.components(separatedBy: "\n").map { line in
            "<a:p><a:pPr><a:defRPr/></a:pPr><a:r><a:rPr lang=\"en-US\"/><a:t>\(XMLLite.escape(line))</a:t></a:r></a:p>"
        }.joined()
        // A title the file formatted keeps its formatting: only its text changes.
        if let rich = existing?.firstChild(named: "tx")?.firstChild(named: "rich") {
            let template = rich.children(named: "p").first
            for paragraph in rich.children(named: "p") { rich.removeChild(paragraph) }
            for line in title.components(separatedBy: "\n") {
                guard let paragraph = template.flatMap({ XMLLite.serialize($0) }).flatMap(fragment) ?? fragment("<a:p/>") else { continue }
                let runProperties = paragraph.children.first { $0.name == "r" }?.firstChild(named: "rPr")
                for child in paragraph.children where ["r", "fld", "br"].contains(child.name) { paragraph.removeChild(child) }
                let properties = runProperties.flatMap { XMLLite.serialize($0) } ?? "<a:rPr lang=\"en-US\"/>"
                if let run = fragment("<a:r>\(properties)<a:t>\(XMLLite.escape(line))</a:t></a:r>") {
                    let before = paragraph.children.firstIndex { $0.name == "endParaRPr" }
                    paragraph.insertChild(run, at: before ?? paragraph.children.count)
                }
                rich.insertChild(paragraph, at: rich.children.count)
            }
            return
        }
        existing.map(chart.removeChild)
        guard let element = fragment("""
            <c:title><c:tx><c:rich><a:bodyPr rot="0" spcFirstLastPara="1" vertOverflow="ellipsis" vert="horz" wrap="square" \
            anchor="ctr" anchorCtr="1"/><a:lstStyle/>\(runs)</c:rich></c:tx><c:overlay val="0"/></c:title>
            """) else { return }
        insert(element, into: chart, order: chartChildOrder)
    }

    private static func writeLegend(_ chart: Chart, into element: XMLElement) {
        let existing = element.firstChild(named: "legend")
        guard chart.hasLegend else {
            existing.map(element.removeChild)
            return
        }
        if let existing {
            existing.firstChild(named: "legendPos")?.setAttribute("val", chart.legendPosition)
            return
        }
        if let legend = fragment("<c:legend><c:legendPos val=\"\(chart.legendPosition)\"/><c:overlay val=\"0\"/></c:legend>") {
            insert(legend, into: element, order: chartChildOrder)
        }
    }

    // MARK: - Plots

    private static let plotNames: Set<String> = [
        "barChart", "bar3DChart", "lineChart", "line3DChart", "areaChart", "area3DChart", "pieChart", "pie3DChart",
        "ofPieChart", "doughnutChart", "scatterChart", "bubbleChart", "radarChart", "stockChart", "surfaceChart", "surface3DChart",
    ]
    private static let axisNames: Set<String> = ["catAx", "valAx", "dateAx", "serAx"]

    private static func elementName(for plot: Chart.Plot) -> String {
        let threeD = plot.isThreeD && plot.kind.hasThreeD ? "3D" : ""
        return switch plot.kind {
        case .column, .bar: "bar\(threeD)Chart"
        case .line: "line\(threeD)Chart"
        case .area: "area\(threeD)Chart"
        case .pie: "pie\(threeD)Chart"
        case .doughnut: "doughnutChart"
        case .scatter: "scatterChart"
        case .bubble: "bubbleChart"
        case .radar: "radarChart"
        case .stock: "stockChart"
        case .surface: "surface\(threeD)Chart"
        case .pieOfPie, .barOfPie: "ofPieChart"
        }
    }

    /// Whether a plot names a series axis too: a 3D line or surface always, a 3D bar or area standing in rows.
    private static func needsSeriesAxis(_ plot: Chart.Plot) -> Bool {
        plot.kind == .surface || (plot.isThreeD && plot.kind == .line)
    }

    private static func writePlots(_ chart: Chart, into area: XMLElement) {
        let firstPlot = area.children.firstIndex { plotNames.contains($0.name) } ?? (area.firstChild(named: "layout") != nil ? 1 : 0)
        for child in area.children where plotNames.contains(child.name) { area.removeChild(child) }

        // Axes: kept if the plots still use the kind they are, made if not.
        let needsAxes = chart.plots.contains { $0.kind.hasAxes }
        let isXY = chart.plots.contains { $0.kind.isXY }
        let horizontal = chart.plots.first?.kind == .bar
        let seriesAxis = chart.plots.contains(where: needsSeriesAxis)
        var axes = area.children.filter { axisNames.contains($0.name) }
        let hasCategoryAxis = axes.contains { $0.name == "catAx" || $0.name == "dateAx" }
        let valueAxes = axes.filter { $0.name == "valAx" }.count
        let fits = isXY ? (valueAxes >= 2 && !hasCategoryAxis) : (hasCategoryAxis && valueAxes >= 1)
        if !needsAxes || !fits {
            for axis in axes { area.removeChild(axis) }
            axes = []
        }
        if needsAxes, axes.isEmpty {
            axes = newAxes(scatter: isXY, horizontal: horizontal)
            let after = area.children.lastIndex { $0.name == "layout" } ?? -1
            for (offset, axis) in axes.enumerated() { area.insertChild(axis, at: after + 1 + offset) }
        }
        if needsAxes, seriesAxis, !axes.contains(where: { $0.name == "serAx" }), let axis = fragment(newSeriesAxis) {
            let after = area.children.lastIndex { axisNames.contains($0.name) } ?? area.children.count - 1
            area.insertChild(axis, at: after + 1)
            axes.append(axis)
        }
        let axisIDs = axes.compactMap { $0.firstChild(named: "axId")?.attribute("val") }
        // The first category and value axes are the plot's own; others, such as a
        // stock chart's prices beside its volume, a series axis, keep where they are.
        let primary = [axes.first { $0.name == "catAx" || $0.name == "dateAx" }, axes.first { $0.name == "valAx" }].compactMap(\.self)
        let gridlineAxis = isXY ? axes.last { $0.name == "valAx" } : primary.last { $0.name == "valAx" }
        for axis in axes {
            let isCategory = axis.name == "catAx" || axis.name == "dateAx"
            // Bars run along whichever side their category axis sits on.
            if !isXY, primary.contains(where: { $0 === axis }) {
                axis.firstChild(named: "axPos")?.setAttribute("val", isCategory == horizontal ? "l" : "b")
            }
            if axis === gridlineAxis { writeValueAxis(axis, chart: chart) }
        }

        var column = 1
        for (index, plot) in chart.plots.enumerated() {
            guard let element = plotElement(plot, chart: chart, firstColumn: column, axisIDs: axisIDs) else { continue }
            area.insertChild(element, at: firstPlot + index)
            column += plot.series.count * (plot.kind == .bubble ? 2 : 1)
        }
    }

    private static let newSeriesAxis = """
        <c:serAx><c:axId val="500000003"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/>\
        <c:axPos val="b"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/>\
        <c:crossAx val="500000002"/><c:crosses val="autoZero"/></c:serAx>
        """

    private static func writeValueAxis(_ axis: XMLElement, chart: Chart) {
        let gridlines = axis.firstChild(named: "majorGridlines")
        if chart.showsGridlines, gridlines == nil, let new = fragment("<c:majorGridlines/>") {
            // After axId, scaling, delete and axPos.
            let before = axis.children.firstIndex { !["axId", "scaling", "delete", "axPos"].contains($0.name) }
            axis.insertChild(new, at: before ?? axis.children.count)
        } else if !chart.showsGridlines, let gridlines {
            axis.removeChild(gridlines)
        }
    }

    private static func newAxes(scatter: Bool, horizontal: Bool) -> [XMLElement] {
        let tail = """
            <c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="none"/><c:minorTickMark val="none"/>\
            <c:tickLblPos val="nextTo"/>
            """
        let first = scatter
            ? "<c:valAx><c:axId val=\"500000001\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/>"
                + "<c:axPos val=\"b\"/>\(tail)<c:crossAx val=\"500000002\"/><c:crosses val=\"autoZero\"/>"
                + "<c:crossBetween val=\"midCat\"/></c:valAx>"
            : "<c:catAx><c:axId val=\"500000001\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/>"
                + "<c:axPos val=\"\(horizontal ? "l" : "b")\"/>\(tail)<c:crossAx val=\"500000002\"/><c:crosses val=\"autoZero\"/>"
                + "<c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx>"
        let second = "<c:valAx><c:axId val=\"500000002\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling>"
            + "<c:delete val=\"0\"/><c:axPos val=\"\(horizontal ? "b" : "l")\"/><c:majorGridlines/>\(tail)"
            + "<c:crossAx val=\"500000001\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"\(scatter ? "midCat" : "between")\"/></c:valAx>"
        return [first, second].compactMap(fragment)
    }

    /// Children of a plot element that follow its series.
    private static let afterSeries: Set<String> = [
        "dLbls", "gapWidth", "overlap", "serLines", "axId", "dropLines", "hiLowLines", "upDownBars", "marker", "smooth",
        "firstSliceAng", "holeSize", "extLst", "bubbleScale", "showNegBubbles", "gapDepth", "shape", "bandFmts", "splitType",
        "splitPos", "custSplit", "secondPieSize", "sizeRepresents", "bubble3D",
    ]

    private static func plotElement(_ plot: Chart.Plot, chart: Chart, firstColumn: Int, axisIDs: [String]) -> XMLElement? {
        let name = elementName(for: plot)
        // A plot of the same element keeps its own XML; an of-pie chart only if it is still a pie or still a bar.
        let kept = plot.source.flatMap(fragment).flatMap { element -> XMLElement? in
            guard element.name == name else { return nil }
            if name == "ofPieChart" {
                let isBar = element.firstChild(named: "ofPieType")?.attribute("val") == "bar"
                return isBar == (plot.kind == .barOfPie) ? element : nil
            }
            return element
        }
        let axisCount = needsSeriesAxis(plot) ? 3 : 2
        let element = kept ?? fragment(plotSkeleton(plot, axisIDs: Array(axisIDs.prefix(axisCount))))
        guard let element else { return nil }
        if plot.kind == .column || plot.kind == .bar {
            element.firstChild(named: "barDir")?.setAttribute("val", plot.kind == .bar ? "bar" : "col")
        }
        if let grouping = element.firstChild(named: "grouping"), plot.kind.hasGrouping {
            let current: Chart.Grouping = switch grouping.attribute("val") {
            case "stacked": .stacked
            case "percentStacked": .percentStacked
            default: .standard
            }
            // A grouping that didn't change is left as it was: a 3D chart's
            // series standing in rows are "standard", not "clustered".
            if current != plot.grouping || kept == nil {
                let value = switch (plot.kind, plot.grouping) {
                case (.column, .standard), (.bar, .standard): "clustered"
                case (_, .standard): "standard"
                case (_, .stacked): "stacked"
                case (_, .percentStacked): "percentStacked"
                }
                grouping.setAttribute("val", value)
                // Stacked bars sit on one another, side by side ones apart.
                if plot.kind == .column || plot.kind == .bar, !plot.isThreeD {
                    let overlap = element.firstChild(named: "overlap")
                    if plot.grouping == .standard {
                        overlap?.setAttribute("val", "-27")
                    } else if let overlap {
                        overlap.setAttribute("val", "100")
                    } else if let new = fragment("<c:overlap val=\"100\"/>") {
                        let before = element.children.firstIndex { ["serLines", "axId", "extLst"].contains($0.name) }
                        element.insertChild(new, at: before ?? element.children.count)
                    }
                }
            }
        }
        if plot.kind == .doughnut { element.firstChild(named: "holeSize")?.setAttribute("val", String(plot.holeSize)) }
        if plot.kind == .radar { element.firstChild(named: "radarStyle")?.setAttribute("val", plot.radarStyle.rawValue) }
        writeValueLabels(chart.showsValueLabels, into: element)
        // The plot's axes, which a plot that was made fresh names already. A
        // plot keeps axes of its own that are still there, as a stock chart's prices on their own axis.
        if kept != nil, plot.kind.hasAxes {
            let own = element.children(named: "axId").compactMap { $0.attribute("val") }
            if own.count < axisCount || !own.allSatisfy(axisIDs.contains) {
                for axis in element.children(named: "axId") { element.removeChild(axis) }
                let before = element.children.firstIndex { $0.name == "extLst" }
                for (offset, id) in axisIDs.prefix(axisCount).enumerated() {
                    if let axis = fragment("<c:axId val=\"\(id)\"/>") { element.insertChild(axis, at: (before ?? element.children.count) + offset) }
                }
            }
        }

        for series in element.children(named: "ser") { element.removeChild(series) }
        let insertion = element.children.firstIndex { afterSeries.contains($0.name) } ?? element.children.count
        let width = plot.kind == .bubble ? 2 : 1
        for (offset, series) in plot.series.enumerated() {
            let index = firstColumn - 1 + offset
            guard let seriesElement = seriesElement(
                series, kind: plot.kind, index: index, column: firstColumn + offset * width, chart: chart
            ) else { continue }
            element.insertChild(seriesElement, at: insertion + offset)
        }
        return element
    }

    private static func plotSkeleton(_ plot: Chart.Plot, axisIDs: [String]) -> String {
        let axes = axisIDs.map { "<c:axId val=\"\($0)\"/>" }.joined()
        let labels = "<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"0\"/><c:showCatName val=\"0\"/>"
            + "<c:showSerName val=\"0\"/><c:showPercent val=\"0\"/><c:showBubbleSize val=\"0\"/></c:dLbls>"
        let name = elementName(for: plot)
        switch plot.kind {
        case .column, .bar:
            let gaps = plot.isThreeD ? "<c:gapWidth val=\"150\"/><c:shape val=\"box\"/>" : "<c:gapWidth val=\"219\"/><c:overlap val=\"-27\"/>"
            return "<c:\(name)><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>\(labels)"
                + "\(gaps)\(axes)</c:\(name)>"
        case .line:
            let marker = plot.isThreeD ? "<c:gapDepth val=\"150\"/>" : "<c:marker val=\"1\"/>"
            return "<c:\(name)><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(labels)\(marker)\(axes)</c:\(name)>"
        case .area:
            return "<c:\(name)><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(labels)\(axes)</c:\(name)>"
        case .pie:
            let angle = plot.isThreeD ? "" : "<c:firstSliceAng val=\"0\"/>"
            return "<c:\(name)><c:varyColors val=\"1\"/>\(labels)\(angle)</c:\(name)>"
        case .doughnut:
            return "<c:doughnutChart><c:varyColors val=\"1\"/>\(labels)<c:firstSliceAng val=\"0\"/><c:holeSize val=\"50\"/></c:doughnutChart>"
        case .scatter:
            return "<c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>\(labels)\(axes)</c:scatterChart>"
        case .bubble:
            return "<c:bubbleChart><c:varyColors val=\"0\"/>\(labels)<c:bubbleScale val=\"\(plot.bubbleScale)\"/>"
                + "<c:showNegBubbles val=\"\(plot.showsNegativeBubbles ? 1 : 0)\"/>"
                + (plot.sizeIsWidth ? "<c:sizeRepresents val=\"w\"/>" : "") + "\(axes)</c:bubbleChart>"
        case .radar:
            return "<c:radarChart><c:radarStyle val=\"\(plot.radarStyle.rawValue)\"/><c:varyColors val=\"0\"/>\(labels)\(axes)</c:radarChart>"
        case .stock:
            let lines = "<c:hiLowLines><c:spPr><a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"tx1\">"
                + "<a:lumMod val=\"75000\"/><a:lumOff val=\"25000\"/></a:schemeClr></a:solidFill><a:round/></a:ln></c:spPr></c:hiLowLines>"
            let bars = "<c:upDownBars><c:gapWidth val=\"150\"/><c:upBars/><c:downBars/></c:upDownBars>"
            return "<c:stockChart>\(labels)\(plot.hasHighLowLines ? lines : "")\(plot.hasUpDownBars ? bars : "")\(axes)</c:stockChart>"
        case .surface:
            return "<c:\(name)><c:wireframe val=\"\(plot.isWireframe ? 1 : 0)\"/>\(axes)</c:\(name)>"
        case .pieOfPie, .barOfPie:
            let split = plot.splitPosition.map { "<c:splitPos val=\"\(number($0))\"/>" } ?? ""
            let custom = plot.splitType == .cust
                ? "<c:custSplit>" + plot.customSplit.map { "<c:secondPiePt val=\"\($0)\"/>" }.joined() + "</c:custSplit>" : ""
            return "<c:ofPieChart><c:ofPieType val=\"\(plot.kind == .barOfPie ? "bar" : "pie")\"/><c:varyColors val=\"1\"/>\(labels)"
                + "<c:gapWidth val=\"\(plot.gapWidth)\"/><c:splitType val=\"\(plot.splitType.rawValue)\"/>\(split)\(custom)"
                + "<c:secondPieSize val=\"\(plot.secondPieSize)\"/>" + (plot.hasSeriesLines ? "<c:serLines/>" : "") + "</c:ofPieChart>"
        }
    }

    private static func writeValueLabels(_ isOn: Bool, into plot: XMLElement) {
        if let labels = plot.firstChild(named: "dLbls") {
            if let value = labels.firstChild(named: "showVal") {
                value.setAttribute("val", isOn ? "1" : "0")
            } else if isOn, let value = fragment("<c:showVal val=\"1\"/>") {
                let before = labels.children.firstIndex { ["showCatName", "showSerName", "showPercent", "showBubbleSize", "separator", "showLeaderLines", "extLst"].contains($0.name) }
                labels.insertChild(value, at: before ?? labels.children.count)
            }
        }
    }

    // MARK: - Series

    /// The order of a series' children, for each kind of plot.
    private static func seriesChildOrder(_ kind: Chart.Kind) -> [String] {
        switch kind {
        case .column, .bar:
            ["idx", "order", "tx", "spPr", "invertIfNegative", "pictureOptions", "dPt", "dLbls", "trendline", "errBars", "cat", "val", "shape", "extLst"]
        case .line, .stock:
            ["idx", "order", "tx", "spPr", "marker", "dPt", "dLbls", "trendline", "errBars", "cat", "val", "smooth", "extLst"]
        case .area:
            ["idx", "order", "tx", "spPr", "pictureOptions", "dPt", "dLbls", "trendline", "errBars", "cat", "val", "extLst"]
        case .pie, .doughnut, .pieOfPie, .barOfPie:
            ["idx", "order", "tx", "spPr", "explosion", "dPt", "dLbls", "cat", "val", "extLst"]
        case .scatter:
            ["idx", "order", "tx", "spPr", "marker", "dPt", "dLbls", "trendline", "errBars", "xVal", "yVal", "smooth", "extLst"]
        case .bubble:
            ["idx", "order", "tx", "spPr", "invertIfNegative", "dPt", "dLbls", "trendline", "errBars", "xVal", "yVal", "bubbleSize", "bubble3D", "extLst"]
        case .radar:
            ["idx", "order", "tx", "spPr", "marker", "dPt", "dLbls", "cat", "val", "extLst"]
        case .surface:
            ["idx", "order", "tx", "spPr", "cat", "val", "extLst"]
        }
    }

    private static func seriesElement(_ series: Chart.Series, kind: Chart.Kind, index: Int, column: Int, chart: Chart) -> XMLElement? {
        let order = seriesChildOrder(kind)
        // A series keeps its formatting if it is still in a plot of the kind it was.
        let kept = series.source.flatMap(fragment).flatMap { element -> XMLElement? in
            element.children.allSatisfy { order.contains($0.name) } ? element : nil
        }
        guard let element = kept ?? fragment("<c:ser/>") else { return nil }
        for child in element.children where ["idx", "order", "tx", "cat", "val", "xVal", "yVal", "bubbleSize"].contains(child.name) {
            element.removeChild(child)
        }
        let sheet = quotedSheet(chart.sheetName)
        // Categories are in column A, so the first series is in B.
        let letter = columnLetter(column + 1)
        let count = chart.categories.count
        let last = count + 1
        var parts = [
            "<c:idx val=\"\(index)\"/>", "<c:order val=\"\(index)\"/>",
            "<c:tx><c:strRef><c:f>\(sheet)!$\(letter)$1</c:f><c:strCache><c:ptCount val=\"1\"/><c:pt idx=\"0\">"
                + "<c:v>\(XMLLite.escape(series.name))</c:v></c:pt></c:strCache></c:strRef></c:tx>",
        ]
        let values = (0..<count).map { series.values.indices.contains($0) ? series.values[$0] : nil }
        if kind.isXY {
            parts.append("<c:xVal>" + numberReference("\(sheet)!$A$2:$A$\(last)", chart.categories.map { Double($0) }) + "</c:xVal>")
            parts.append("<c:yVal>" + numberReference("\(sheet)!$\(letter)$2:$\(letter)$\(last)", values) + "</c:yVal>")
            if kind == .bubble {
                let sizes = (0..<count).map { series.sizes.indices.contains($0) ? series.sizes[$0] : nil }
                let sizeLetter = columnLetter(column + 2)
                parts.append("<c:bubbleSize>" + numberReference("\(sheet)!$\(sizeLetter)$2:$\(sizeLetter)$\(last)", sizes) + "</c:bubbleSize>")
            }
        } else {
            let numbers = chart.categories.map { Double($0) }
            if let format = chart.categoryFormat, numbers.allSatisfy({ $0 != nil }) {
                // Categories the file gave as numbers, such as dates, stay numbers in their format.
                parts.append("<c:cat>" + numberReference("\(sheet)!$A$2:$A$\(last)", numbers, format: format) + "</c:cat>")
            } else {
                let points = chart.categories.enumerated().map { "<c:pt idx=\"\($0)\"><c:v>\(XMLLite.escape($1))</c:v></c:pt>" }.joined()
                parts.append("<c:cat><c:strRef><c:f>\(sheet)!$A$2:$A$\(last)</c:f><c:strCache><c:ptCount val=\"\(count)\"/>"
                    + "\(points)</c:strCache></c:strRef></c:cat>")
            }
            parts.append("<c:val>" + numberReference("\(sheet)!$\(letter)$2:$\(letter)$\(last)", values) + "</c:val>")
        }
        let isLine = [.line, .scatter, .radar, .stock].contains(kind)
        if kept == nil, kind == .stock, series.hasLine != true {
            parts.append("<c:spPr><a:ln w=\"19050\" cap=\"rnd\"><a:noFill/><a:round/></a:ln></c:spPr>")
        } else if kept == nil, let color = series.color {
            let properties = isLine
                ? "<c:spPr><a:ln w=\"28575\" cap=\"rnd\"><a:solidFill>\(color.xml)</a:solidFill><a:round/></a:ln></c:spPr>"
                : "<c:spPr><a:solidFill>\(color.xml)</a:solidFill></c:spPr>"
            parts.append(properties)
        }
        if kept == nil, isLine {
            let symbol = series.marker ?? (kind == .stock ? "none" : "circle")
            parts.append(symbol == "none" ? "<c:marker><c:symbol val=\"none\"/></c:marker>"
                : "<c:marker><c:symbol val=\"\(XMLLite.escape(symbol))\"/><c:size val=\"5\"/></c:marker>")
        }
        if kept == nil, kind == .column || kind == .bar || kind == .bubble {
            parts.append("<c:invertIfNegative val=\"0\"/>")
        }
        if kept == nil, kind == .bubble {
            parts.append("<c:bubble3D val=\"0\"/>")
        }
        for xml in parts {
            guard let child = fragment(xml) else { continue }
            let rank = order.firstIndex(of: child.name) ?? order.count
            let before = element.children.firstIndex { (order.firstIndex(of: $0.name) ?? order.count) > rank }
            element.insertChild(child, at: before ?? element.children.count)
        }
        return element
    }

    private static func numberReference(_ formula: String, _ values: [Double?], format: String = "General") -> String {
        let points = values.enumerated().compactMap { index, value in
            value.map { "<c:pt idx=\"\(index)\"><c:v>\(number($0))</c:v></c:pt>" }
        }.joined()
        return "<c:numRef><c:f>\(XMLLite.escape(formula))</c:f><c:numCache><c:formatCode>\(XMLLite.escape(format))</c:formatCode>"
            + "<c:ptCount val=\"\(values.count)\"/>\(points)</c:numCache></c:numRef>"
    }

    private static func number(_ value: Double) -> String { Chart.number(value) }

    /// `A`, `B`… `Z`, `AA`… for a one-based column.
    public static func columnLetter(_ column: Int) -> String {
        var number = column
        var letters = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + remainder))) + letters
            number = (number - 1) / 26
        }
        return letters
    }

    private static func quotedSheet(_ name: String) -> String {
        let plain = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return XMLLite.escape(plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'")
    }

    // MARK: - Workbook

    /// The chart's data as a workbook: categories down the first column,
    /// each series down a column of its own, named in the first row.
    public static func workbook(for chart: Chart) -> Data? {
        let sheet = XMLLite.escape(chart.sheetName)
        func cell(_ reference: String, text: String) -> String {
            "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(XMLLite.escape(text))</t></is></c>"
        }
        func cell(_ reference: String, number value: Double?) -> String {
            value.map { "<c r=\"\(reference)\"><v>\(number($0))</v></c>" } ?? ""
        }
        // Each series' column, and a bubble's sizes in the column after it, as the chart part's formulas name them.
        var columns: [(name: String, values: [Double?])] = []
        for plot in chart.plots {
            for series in plot.series {
                columns.append((series.name, series.values))
                if plot.kind == .bubble { columns.append((String(localized: "Chart.Data.Size", bundle: .engine), series.sizes)) }
            }
        }
        let numbered = chart.kind.isXY || (chart.categoryFormat != nil && chart.categories.allSatisfy { Double($0) != nil })
        var rows = ["<row r=\"1\">" + columns.enumerated().map { cell("\(columnLetter($0 + 2))1", text: $1.name) }.joined() + "</row>"]
        for (index, category) in chart.categories.enumerated() {
            let row = index + 2
            let label = numbered ? cell("A\(row)", number: Double(category)) : cell("A\(row)", text: category)
            let values = columns.enumerated().map { column, entry in
                cell("\(columnLetter(column + 2))\(row)", number: entry.values.indices.contains(index) ? entry.values[index] : nil)
            }.joined()
            rows.append("<row r=\"\(row)\">\(label)\(values)</row>")
        }
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let parts: [(path: String, data: Data)] = [
            ("[Content_Types].xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="\(OOXML.contentTypesNS)"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" \
                ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override \
                PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
                """),
            ("_rels/.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="\(OOXML.packageRelationships)"><Relationship Id="rId1" \
                Type="\(OOXML.RelationshipType.officeDocument)" Target="xl/workbook.xml"/></Relationships>
                """),
            ("xl/workbook.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <workbook xmlns="\(main)" xmlns:r="\(OOXML.relationshipsNS)"><sheets><sheet name="\(sheet)" sheetId="1" r:id="rId1"/>\
                </sheets></workbook>
                """),
            ("xl/_rels/workbook.xml.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="\(OOXML.packageRelationships)"><Relationship Id="rId1" \
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
                Target="styles.xml"/></Relationships>
                """),
            ("xl/worksheets/sheet1.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <worksheet xmlns="\(main)"><sheetData>\(rows.joined())</sheetData></worksheet>
                """),
            ("xl/styles.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <styleSheet xmlns="\(main)"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
                <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
                </fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs \
                count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" \
                fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
                """),
        ].map { ($0.0, Data($0.1.utf8)) }
        return try? ZipArchive.archive(entries: parts)
    }

    /// Where the chart's embedded workbook is, if it has one Dazzle can rewrite.
    public static func workbookPath(of chart: Chart, in presentation: Presentation) -> String? {
        guard let data = presentation.data(at: chart.path), let root = try? XMLLite.parse(data),
              let id = root.firstChild(named: "externalData")?.relationshipID else { return nil }
        let relationships = Relationship.parse(presentation.data(at: PackagePath.relationships(of: chart.path)))
        guard let relationship = relationships.first(where: { $0.id == id }), !relationship.isExternal else { return nil }
        let path = PackagePath.resolve(relationship.target, from: chart.path)
        return path.lowercased().hasSuffix(".xlsx") ? path : nil
    }
}
