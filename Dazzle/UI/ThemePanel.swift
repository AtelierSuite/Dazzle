import DazzleEngine
import SwiftUI

/// The theme's twelve colours and its heading and body fonts. Each change
/// is made at once, so the slides behind the panel follow it as it is made.
struct ThemePanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    private var theme: Theme { state.theme(in: presentation) }

    var body: some View {
        Form {
            Section("Theme.Colors") {
                ForEach(ThemeColorSlot.all, id: \.slot) { slot, key in
                    ColorPicker(selection: color(slot), supportsOpacity: false) {
                        Text(verbatim: ThemeColorSlot.label(key))
                    }
                    .accessibilityIdentifier("themeColor.\(slot)")
                }
            }
            Section {
                fontRow("Theme.HeadingFont", family: theme.majorFont, heading: true)
                    .accessibilityIdentifier("themeHeadingFont")
                fontRow("Theme.BodyFont", family: theme.minorFont, heading: false)
                    .accessibilityIdentifier("themeBodyFont")
            } header: {
                Text("Theme.Fonts")
            } footer: {
                Text("Theme.Footer")
            }
        }
    }

    private func color(_ slot: String) -> Binding<Color> {
        Binding(
            get: { Color(cgColor: RGBAColor(hex: theme.colors[slot] ?? 0).cgColor) },
            set: { color in
                let resolved = color.resolve(in: EnvironmentValues())
                let rgb = RGBAColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
                guard rgb.hexValue != theme.colors[slot] else { return }
                state.setThemeColor(rgb.hexValue, for: slot, in: &presentation)
            }
        )
    }

    private func fontRow(_ label: LocalizedStringKey, family: String, heading: Bool) -> some View {
        NavigationLink {
            FontPicker(theme: nil, selected: family) { picked in
                state.setThemeFont(picked, heading: heading, in: &presentation)
            }
        } label: {
            LabeledContent(label) {
                Text(verbatim: family)
                    .font(Font(FontResolver.shared.font(family: family, size: 17, bold: false, italic: false) as UIFont))
            }
        }
    }
}
