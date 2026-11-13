import DazzleEngine
import Foundation

/// The theme's twelve colours as the theme editors list them, each with
/// the name PowerPoint gives it.
enum ThemeColorSlot {
    static let all: [(slot: String, labelKey: String)] = [
        ("dk1", "Theme.Color.Dark1"), ("lt1", "Theme.Color.Light1"),
        ("dk2", "Theme.Color.Dark2"), ("lt2", "Theme.Color.Light2"),
        ("accent1", "Theme.Color.Accent1"), ("accent2", "Theme.Color.Accent2"),
        ("accent3", "Theme.Color.Accent3"), ("accent4", "Theme.Color.Accent4"),
        ("accent5", "Theme.Color.Accent5"), ("accent6", "Theme.Color.Accent6"),
        ("hlink", "Theme.Color.Hyperlink"), ("folHlink", "Theme.Color.FollowedHyperlink"),
    ]

    static func label(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
}

extension EditorState {
    /// The master whose theme is edited: the one the slide being edited is
    /// built on.
    func themeMasterPath(in presentation: Presentation) -> String? {
        let layout = selectedSlide(in: presentation).flatMap { presentation.layout(for: $0) }
        return presentation.resources.master(for: layout)?.path
    }

    func theme(in presentation: Presentation) -> Theme {
        themeMasterPath(in: presentation).flatMap { presentation.resources.masters[$0]?.theme } ?? .office
    }

    /// Whether the theme can be changed: not in a Keynote document, which
    /// keeps its styles in a form Dazzle doesn't write, nor in master view,
    /// whose slides are the masters themselves.
    func canEditTheme(in presentation: Presentation) -> Bool {
        presentation.keynoteSource == nil && !presentation.isInMasterView && themeMasterPath(in: presentation) != nil
    }

    func setThemeColor(_ color: UInt32, for slot: String, in presentation: inout Presentation) {
        var theme = theme(in: presentation)
        theme.colors[slot] = color & 0xFFFFFF
        setTheme(theme, in: &presentation)
    }

    func setThemeFont(_ family: String, heading: Bool, in presentation: inout Presentation) {
        let family = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty else { return }
        var theme = theme(in: presentation)
        if heading { theme.majorFont = family } else { theme.minorFont = family }
        setTheme(theme, in: &presentation)
    }

    func setTheme(_ theme: Theme, in presentation: inout Presentation) {
        guard canEditTheme(in: presentation), let path = themeMasterPath(in: presentation) else { return }
        presentation.setTheme(theme, ofMaster: path)
    }
}
