import Foundation

extension Theme {
    /// The twelve colours a theme defines, in the order PowerPoint lists them.
    public static let colorSlots = [
        "dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink",
    ]
}

extension DeckResources {
    /// The same resources with `theme` on the masters at `paths`.
    public func replacingTheme(_ theme: Theme, onMasters paths: Set<String>) -> DeckResources {
        var masters = masters
        for path in paths where masters[path] != nil {
            masters[path]?.theme = theme
        }
        return DeckResources(
            masters: masters, layouts: layouts, layoutOrder: layoutOrder, defaultTextStyle: defaultTextStyle,
            notesMasterPath: notesMasterPath, tableStyles: tableStyles, embeddedFonts: embeddedFonts, masterOrder: masterOrder
        )
    }
}

extension Presentation {
    /// The theme part a slide master is drawn with.
    public func themePath(ofMaster masterPath: String) -> String? {
        Relationship.parse(data(at: PackagePath.relationships(of: masterPath)))
            .first { $0.type == OOXML.RelationshipType.theme && !$0.isExternal }
            .map { PackagePath.resolve($0.target, from: masterPath) }
    }

    /// Gives a master new theme colours and fonts. Every master drawn with
    /// the same theme part changes with it, and so does every slide that
    /// refers to the theme, as they look its colours and fonts up when drawn.
    ///
    /// The theme part is written at once, so whatever reads the masters
    /// again, such as leaving master view, reads the theme as edited.
    public mutating func setTheme(_ theme: Theme, ofMaster masterPath: String) throws {
        guard let current = resources.masters[masterPath]?.theme, current != theme else { return }
        let part = themePath(ofMaster: masterPath)
        if let part {
            guard let data = data(at: part), let patched = ThemeXML.patched(data, with: theme) else {
                throw PresentationWriteError.unwritablePart(part)
            }
            addedParts[part] = patched
            addedContentTypes[part] = OOXML.ContentType.theme
        }
        let sharing = Set(resources.masters.keys.filter { $0 == masterPath || (part != nil && themePath(ofMaster: $0) == part) })
        resources = resources.replacingTheme(theme, onMasters: sharing)
    }
}

/// Writes a theme's colours and fonts into its theme part, leaving the rest
/// of the part (its name, format scheme and extensions) as it was.
public enum ThemeXML {
    public static func patched(_ data: Data, with theme: Theme) -> Data? {
        guard let root = try? XMLLite.parse(data), let elements = root.firstChild(named: "themeElements") else { return nil }
        if let scheme = elements.firstChild(named: "clrScheme") {
            for slot in Theme.colorSlots {
                guard let color = theme.colors[slot] else { continue }
                let element = scheme.firstChild(named: slot) ?? {
                    let created = XMLLite.fragment("<a:\(slot)/>", namespaces: ["a": OOXML.drawingML])
                    if let created { scheme.insertChild(created, at: insertionIndex(of: slot, in: scheme)) }
                    return created
                }()
                guard let element, Self.color(of: element) != color else { continue }
                // A system colour that no longer matches becomes a plain one.
                for child in element.children { element.removeChild(child) }
                if let value = XMLLite.fragment("<a:srgbClr val=\"\(hex(color))\"/>", namespaces: ["a": OOXML.drawingML]) {
                    element.insertChild(value, at: 0)
                }
            }
        }
        if let fonts = elements.firstChild(named: "fontScheme") {
            setTypeface(theme.majorFont, of: fonts.firstChild(named: "majorFont"))
            setTypeface(theme.minorFont, of: fonts.firstChild(named: "minorFont"))
        }
        guard let xml = XMLLite.serialize(root) else { return nil }
        return Data((PackagePath.declaration + xml).utf8)
    }

    /// The colour a scheme slot holds, as `PPTXReader` reads it.
    private static func color(of slot: XMLElement) -> UInt32? {
        if let rgb = slot.firstChild(named: "srgbClr")?.attribute("val") { return UInt32(rgb, radix: 16) }
        if let system = slot.firstChild(named: "sysClr") {
            return system.attribute("lastClr").flatMap { UInt32($0, radix: 16) }
                ?? (system.attribute("val") == "window" ? 0xFFFFFF : 0x000000)
        }
        return nil
    }

    /// Where a missing slot goes: after the slots that come before it.
    private static func insertionIndex(of slot: String, in scheme: XMLElement) -> Int {
        let earlier = Set(Theme.colorSlots.prefix { $0 != slot })
        return (scheme.children.lastIndex { earlier.contains($0.name) } ?? -1) + 1
    }

    private static func setTypeface(_ typeface: String, of font: XMLElement?) {
        guard let font else { return }
        if let latin = font.firstChild(named: "latin") {
            latin.setAttribute("typeface", typeface)
        } else if let latin = XMLLite.fragment("<a:latin typeface=\"\(XMLLite.escape(typeface))\"/>", namespaces: ["a": OOXML.drawingML]) {
            font.insertChild(latin, at: 0)
        }
    }

    private static func hex(_ color: UInt32) -> String { String(format: "%06X", color & 0xFFFFFF) }
}
