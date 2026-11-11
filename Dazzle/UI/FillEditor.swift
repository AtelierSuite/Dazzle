import DazzleEngine
import PhotosUI
import SwiftUI

/// Choosing how a shape or a slide is filled: not at all, with a colour,
/// with a gradient between two colours, or with a picture. A pattern from
/// the file keeps a kind of its own, with its two colours to change.
struct FillEditor: View {
    let identifier: String
    let fill: Fill?
    let choices: [ColorChoice]
    /// For a background: the first choice means "as the layout has it",
    /// rather than no fill at all.
    var noneIsAutomatic = false
    let onChange: (Fill?) -> Void
    let onPicture: (PreparedMedia, _ tiled: Bool) -> Void

    @State private var photo: PhotosPickerItem?
    @State private var kind: Kind?
    @State private var isLoadingPicture = false

    enum Kind: Hashable {
        case none
        case solid
        case gradient
        case picture
        case pattern
    }

    private var currentKind: Kind {
        switch fill {
        case nil, .none?, .group?: .none
        case .solid?: .solid
        case .gradient?: .gradient
        case .picture?, .tiledPicture?: .picture
        case .pattern?: .pattern
        }
    }

    var body: some View {
        Picker("Fill.Kind", selection: Binding(get: { kind ?? currentKind }, set: choose)) {
            Text(noneIsAutomatic ? "Fill.Automatic" : "Fill.None").tag(Kind.none)
            Text("Fill.Solid").tag(Kind.solid)
            Text("Fill.Gradient").tag(Kind.gradient)
            Text("Fill.Picture").tag(Kind.picture)
            // Patterns are not made here, only kept and recoloured.
            if currentKind == .pattern { Text("Fill.Pattern").tag(Kind.pattern) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("\(identifier).kind")
        .onChange(of: fill) { _, _ in kind = nil }

        switch kind ?? currentKind {
        case .none:
            EmptyView()
        case .solid:
            ColorSwatches(
                identifier: identifier, choices: choices,
                selected: { if case .solid(let color) = fill { return color } else { return nil } }()
            ) { color in
                if let color { onChange(.solid(color)) }
            }
        case .gradient:
            gradientControls
        case .picture:
            pictureControls
        case .pattern:
            patternControls
        }
    }

    private func choose(_ new: Kind) {
        switch new {
        case .none:
            kind = nil
            onChange(noneIsAutomatic ? nil : Fill.none)
        case .solid:
            kind = nil
            onChange(.solid(firstColor ?? .scheme("accent1")))
        case .gradient:
            kind = nil
            let start = firstColor ?? .scheme("accent1")
            var end = start
            end.transforms.append(.init(name: "lumMod", value: 40_000))
            end.transforms.append(.init(name: "lumOff", value: 60_000))
            onChange(.gradient(Fill.Gradient(
                stops: [.init(position: 0, color: start), .init(position: 1, color: end)], angle: 90, isRadial: false
            )))
        case .picture:
            // Nothing changes until a picture is picked.
            kind = .picture
        case .pattern:
            kind = nil
        }
    }

    /// The colour the fill has now, to carry over to another kind of fill.
    /// A style's placeholder colour means nothing outside the style.
    private var firstColor: DrawingColor? {
        let color: DrawingColor? = switch fill {
        case .solid(let color)?: color
        case .gradient(let gradient)?: gradient.stops.first?.color
        case .pattern(let pattern)?: pattern.foreground
        default: nil
        }
        return color?.base == .scheme("phClr") ? nil : color
    }

    // MARK: - Gradient

    private var gradient: Fill.Gradient? {
        if case .gradient(let gradient) = fill { return gradient }
        return nil
    }

    @ViewBuilder
    private var gradientControls: some View {
        if let gradient {
            Text("Fill.Gradient.Start").font(.footnote).foregroundStyle(.secondary)
            ColorSwatches(identifier: "\(identifier).start", choices: choices, selected: gradient.stops.first?.color) { color in
                if let color { update { $0.stops[0].color = color } }
            }
            Text("Fill.Gradient.End").font(.footnote).foregroundStyle(.secondary)
            ColorSwatches(identifier: "\(identifier).end", choices: choices, selected: gradient.stops.last?.color) { color in
                if let color { update { $0.stops[$0.stops.count - 1].color = color } }
            }
            Picker("Fill.Gradient.Style", selection: Binding(
                get: { gradient.path },
                set: { path in update { $0.path = path } }
            )) {
                Text("Fill.Gradient.Linear").tag(Fill.Gradient.Path?.none)
                Text("Fill.Gradient.Radial").tag(Fill.Gradient.Path?.some(.circle))
                Text("Fill.Gradient.Rectangular").tag(Fill.Gradient.Path?.some(.rect))
                Text("Fill.Gradient.Path").tag(Fill.Gradient.Path?.some(.shape))
            }
            .accessibilityIdentifier("\(identifier).gradientStyle")
            if !gradient.isRadial {
                Picker("Fill.Gradient.Direction", selection: Binding(
                    get: { (gradient.angle / 45).rounded() * 45 },
                    set: { angle in update { $0.angle = angle } }
                )) {
                    ForEach(Array(stride(from: 0.0, to: 360, by: 45)), id: \.self) { angle in
                        // DrawingML's angles turn clockwise from left-to-right;
                        // the arrow points where the gradient runs to.
                        Image(systemName: "arrow.right").rotationEffect(.degrees(angle)).tag(angle)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func update(_ change: (inout Fill.Gradient) -> Void) {
        guard var gradient else { return }
        // A style's gradient is in its placeholder colour, which means
        // nothing as a fill of the shape's own; the accent stands in.
        for index in gradient.stops.indices where gradient.stops[index].color.base == .scheme("phClr") {
            gradient.stops[index].color.base = .scheme("accent1")
        }
        change(&gradient)
        onChange(.gradient(gradient))
    }

    // MARK: - Pattern

    @ViewBuilder
    private var patternControls: some View {
        if case .pattern(let pattern)? = fill {
            Text("Fill.Pattern.Foreground").font(.footnote).foregroundStyle(.secondary)
            ColorSwatches(identifier: "\(identifier).foreground", choices: choices, selected: pattern.foreground) { color in
                if let color { recolor { $0.foreground = color } }
            }
            Text("Fill.Pattern.Background").font(.footnote).foregroundStyle(.secondary)
            ColorSwatches(identifier: "\(identifier).background", choices: choices, selected: pattern.background) { color in
                if let color { recolor { $0.background = color } }
            }
        }
    }

    private func recolor(_ change: (inout Fill.Pattern) -> Void) {
        guard case .pattern(var pattern)? = fill else { return }
        // As with a gradient, a style's placeholder colour means nothing on the shape itself.
        if pattern.foreground.base == .scheme("phClr") { pattern.foreground.base = .scheme("accent1") }
        if pattern.background.base == .scheme("phClr") { pattern.background.base = .scheme("bg1") }
        change(&pattern)
        onChange(.pattern(pattern))
    }

    // MARK: - Picture

    @ViewBuilder
    private var pictureControls: some View {
        let label = String(localized: currentKind == .picture ? "Fill.Picture.Change" : "Fill.Picture.Choose")
        PhotosPicker(selection: $photo, matching: .images) {
            Label(label, systemImage: "photo")
        }
        .accessibilityIdentifier("\(identifier).picture")
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            load(item)
        }
        if case .picture(let path, let effects)? = fill {
            Toggle("Fill.Picture.Tile", isOn: Binding(get: { false }, set: { tiled in
                if tiled { onChange(.tiledPicture(path: path, effects: effects)) }
            }))
        } else if case .tiledPicture(let path, let effects, _)? = fill {
            Toggle("Fill.Picture.Tile", isOn: Binding(get: { true }, set: { tiled in
                if !tiled { onChange(.picture(path: path, effects: effects)) }
            }))
        }
        if isLoadingPicture { ProgressView() }
    }

    private func load(_ item: PhotosPickerItem) {
        isLoadingPicture = true
        Task {
            defer { isLoadingPicture = false }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let media = await Task.detached(operation: { PreparedMedia(data: data) }).value else { return }
            kind = nil
            onPicture(media, false)
        }
    }
}
