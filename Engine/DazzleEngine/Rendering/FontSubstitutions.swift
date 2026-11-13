import Foundation

/// A typeface a presentation's text asks for that this device draws in another.
public struct FontSubstitution: Hashable, Sendable {
    /// The typeface as the file names it.
    public var requested: String
    /// The family drawn instead.
    public var substitute: String

    public init(requested: String, substitute: String) {
        self.requested = requested
        self.substitute = substitute
    }
}

extension [FontSubstitution] {
    /// A line for each, as a notice lists them.
    public var noticeMessage: String {
        map { "• \($0.requested) → \($0.substitute)" }.joined(separator: "\n")
    }
}

extension Presentation {
    /// The typefaces the slides' text is set in, theme references such as
    /// `+mn-lt` made names: what the slides' runs, their layouts and masters,
    /// and their themes' heading and body fonts ask for.
    public var typefaces: Set<String> {
        var names: Set<String> = []
        var layoutsSeen: Set<String> = []
        for slide in slides {
            let layout = layout(for: slide)
            let master = master(for: slide)
            let theme = master?.theme ?? .office
            names.insert(theme.majorFont)
            names.insert(theme.minorFont)
            func addRun(_ properties: RunProperties?) {
                if let font = properties?.latinFont { names.insert(theme.typeface(font)) }
            }
            func addStyle(_ style: ListStyle) {
                for properties in style.levels.values { addRun(properties.defaultRun) }
            }
            func addBody(_ body: TextBody?) {
                guard let body else { return }
                addStyle(body.listStyle)
                for paragraph in body.paragraphs {
                    addRun(paragraph.properties.defaultRun)
                    addRun(paragraph.endProperties)
                    for run in paragraph.runs { addRun(run.properties) }
                }
            }
            func addShapes(_ shapes: [SlideShape]) {
                for shape in shapes.flatMap(\.flattened) {
                    addBody(shape.text)
                    if case .table(let table) = shape.kind {
                        for row in table.rows { for cell in row.cells { addBody(cell.text) } }
                    }
                }
            }
            addShapes(slide.shapes)
            if let layout, layoutsSeen.insert(layout.path).inserted {
                addShapes(layout.shapes)
                if let master {
                    addShapes(master.shapes)
                    addStyle(master.titleStyle)
                    addStyle(master.bodyStyle)
                    addStyle(master.otherStyle)
                }
            }
        }
        names.remove("")
        return names
    }

    #if canImport(CoreText)
    /// The typefaces this presentation uses that are neither carried in it
    /// nor on this device, with what each is drawn in instead, by name.
    public var fontSubstitutions: [FontSubstitution] {
        typefaces.compactMap { family in
            FontResolver.shared.substitute(for: family, embedded: resources.embeddedFonts)
                .map { FontSubstitution(requested: family, substitute: $0) }
        }
        .sorted { $0.requested.localizedStandardCompare($1.requested) == .orderedAscending }
    }
    #endif
}
