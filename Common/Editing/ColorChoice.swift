import CoreGraphics
import DazzleEngine
import Foundation

/// A colour on offer in the format panels: one of the presentation's theme
/// colours, or one of the Human Interface Guidelines system colours.
///
/// Theme colours come first and are written as theme references, so text
/// coloured "Accent 1" still follows the theme in PowerPoint.
struct ColorChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let value: DrawingColor
    /// What it looks like in this presentation.
    let display: CGColor

    static func themeChoices(in style: SlideStyleContext) -> [ColorChoice] {
        let slots: [(String, String)] = [
            ("tx1", "Color.Theme.Text"), ("bg1", "Color.Theme.Background"),
            ("tx2", "Color.Theme.Text2"), ("bg2", "Color.Theme.Background2"),
            ("accent1", "Color.Theme.Accent1"), ("accent2", "Color.Theme.Accent2"),
            ("accent3", "Color.Theme.Accent3"), ("accent4", "Color.Theme.Accent4"),
            ("accent5", "Color.Theme.Accent5"), ("accent6", "Color.Theme.Accent6"),
        ]
        return slots.map { slot, key in
            let value = DrawingColor.scheme(slot)
            return ColorChoice(
                id: "theme.\(slot)", label: String(localized: String.LocalizationValue(key)),
                value: value, display: style.color(value).cgColor
            )
        }
    }

    /// The HIG system colours, light-appearance values: a stored colour has
    /// to mean one fixed thing in the file.
    static let system: [ColorChoice] = [
        ("red", "Color.Red", 0xFF3B30), ("orange", "Color.Orange", 0xFF9500),
        ("yellow", "Color.Yellow", 0xFFCC00), ("green", "Color.Green", 0x34C759),
        ("mint", "Color.Mint", 0x00C7BE), ("teal", "Color.Teal", 0x30B0C7),
        ("cyan", "Color.Cyan", 0x32ADE6), ("blue", "Color.Blue", 0x007AFF),
        ("indigo", "Color.Indigo", 0x5856D6), ("purple", "Color.Purple", 0xAF52DE),
        ("pink", "Color.Pink", 0xFF2D55), ("brown", "Color.Brown", 0xA2845E),
        ("black", "Color.Black", 0x000000), ("gray", "Color.Grey", 0x8E8E93),
        ("gray4", "Color.LightGrey", 0xD1D1D6), ("white", "Color.White", 0xFFFFFF),
    ].map { id, key, hex in
        ColorChoice(
            id: id, label: String(localized: String.LocalizationValue(key)), value: .rgb(UInt32(hex)),
            display: RGBAColor(hex: UInt32(hex)).cgColor
        )
    }
}
