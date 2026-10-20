import DazzleEngine
import SwiftUI

/// A horizontal carousel of colour swatches, led by the system colour
/// picker. Runs edge to edge in a form row, as Tables' does.
struct ColorSwatches: View {
    let identifier: String
    let choices: [ColorChoice]
    /// The colour currently applied, so its swatch can show as chosen.
    let selected: DrawingColor?
    /// Offer "none" as a choice — for fills and outlines, not for text.
    var allowsNone = false
    var isNoneSelected = false
    let onSelect: (DrawingColor?) -> Void

    private let swatchSize: CGFloat = 28

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ColorPicker("ColorSwatches.MoreColours", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: swatchSize, height: swatchSize)
                    .padding(3)
                    .accessibilityIdentifier("\(identifier).more")

                Divider().frame(height: swatchSize)

                if allowsNone { noneSwatch }

                ForEach(choices) { choice in
                    let isSelected = !isNoneSelected && selected == choice.value
                    Button {
                        onSelect(choice.value)
                    } label: {
                        Circle()
                            .fill(Color(cgColor: choice.display))
                            .frame(width: swatchSize, height: swatchSize)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay {
                                if isSelected {
                                    Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-3)
                                }
                            }
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier).\(choice.id)")
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets())
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { choices.first { $0.value == selected }.map { Color(cgColor: $0.display) } ?? .accentColor },
            set: { color in
                let resolved = color.resolve(in: EnvironmentValues())
                let rgb = RGBAColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
                onSelect(.rgb(rgb.hexValue))
            }
        )
    }

    /// "No colour": an empty ring with a rule through it.
    private var noneSwatch: some View {
        Button {
            onSelect(nil)
        } label: {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                .overlay {
                    Path { path in
                        let inset = swatchSize / 2 * (1 - 1 / sqrt(2))
                        path.move(to: CGPoint(x: inset, y: swatchSize - inset))
                        path.addLine(to: CGPoint(x: swatchSize - inset, y: inset))
                    }
                    .stroke(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                .frame(width: swatchSize, height: swatchSize)
                .overlay {
                    if isNoneSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-3)
                    }
                }
                .padding(3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifier).none")
        .accessibilityLabel("ColorSwatches.None")
        .accessibilityAddTraits(isNoneSelected ? [.isButton, .isSelected] : .isButton)
    }
}
