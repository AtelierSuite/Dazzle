#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Everything a slide inherits — its layout, master and theme — with the
/// lookups that turn a shape's unsaid properties into ones to draw with.
public struct SlideStyleContext: Sendable {
    public let resources: DeckResources
    public let layout: SlideLayout?
    public let master: SlideMaster?
    public let colorMap: [String: String]

    public init(presentation: Presentation, slide: Slide) {
        resources = presentation.resources
        layout = presentation.layout(for: slide)
        master = presentation.master(for: slide)
        var map = master?.colorMap ?? SlideMaster.defaultColorMap
        for (key, value) in layout?.colorMapOverride ?? [:] { map[key] = value }
        colorMap = map
    }

    public var theme: Theme { master?.theme ?? .office }

    // MARK: - Colour

    /// Resolves a colour through the colour map and theme. `placeholder`
    /// is what `phClr` stands for, when a style reference supplies one.
    public func color(_ color: DrawingColor, placeholder: RGBAColor? = nil) -> RGBAColor {
        var resolved: RGBAColor
        switch color.base {
        case .rgb(let value):
            resolved = RGBAColor(hex: value)
        case .system(let name, let last):
            resolved = RGBAColor(hex: last ?? (name == "window" ? 0xFFFFFF : 0x000000))
        case .scheme(let name):
            if name == "phClr" {
                resolved = placeholder ?? .black
            } else {
                let slot = colorMap[name] ?? name
                resolved = RGBAColor(hex: theme.colors[slot] ?? theme.colors[name] ?? 0)
            }
        }
        for transform in color.transforms {
            resolved = resolved.applying(transform)
        }
        return resolved
    }

    // MARK: - Inheritance

    /// The layout and master placeholders a slide's placeholder inherits from.
    public func sources(for shape: SlideShape) -> [SlideShape] {
        guard let placeholder = shape.placeholder else { return [] }
        return [
            layout?.shapes.inheritedPlaceholder(for: placeholder),
            master?.shapes.masterPlaceholder(for: placeholder),
        ].compactMap(\.self)
    }

    /// A fill with what `phClr` means for it.
    public struct ResolvedFill {
        public var fill: Fill
        public var placeholderColor: RGBAColor?
    }

    public func fill(for shape: SlideShape, sources: [SlideShape]) -> ResolvedFill? {
        if let fill = shape.fill { return ResolvedFill(fill: fill) }
        for source in sources {
            if let fill = source.fill { return ResolvedFill(fill: fill) }
        }
        for candidate in [shape] + sources {
            guard let reference = candidate.style?.fill, reference.index > 0 else { continue }
            let list = reference.index >= 1000 ? theme.backgroundFillStyles : theme.fillStyles
            let index = reference.index >= 1000 ? reference.index - 1001 : reference.index - 1
            let fill = list.indices.contains(index) ? list[index] : .solid(.scheme("phClr"))
            return ResolvedFill(fill: fill, placeholderColor: reference.color.map { color($0) })
        }
        return nil
    }

    public func line(for shape: SlideShape, sources: [SlideShape]) -> (line: LineStyle, placeholderColor: RGBAColor?)? {
        var line = shape.line
        for source in sources {
            if let inherited = source.line { line = line?.merged(over: inherited) ?? inherited }
        }
        for candidate in [shape] + sources {
            guard let reference = candidate.style?.line, reference.index > 0 else { continue }
            let themed = theme.lineStyles.indices.contains(reference.index - 1)
                ? theme.lineStyles[reference.index - 1]
                : LineStyle(fill: .solid(.scheme("phClr")), width: 12_700)
            return ((line ?? LineStyle()).merged(over: themed), reference.color.map { color($0) })
        }
        return line.map { ($0, nil) }
    }

    /// The shadow, reflection and other effects a shape is drawn with: its
    /// own, if its properties list any (even none), or else the theme's
    /// effect style its `p:style` names, in the colour that names it.
    public func effects(for shape: SlideShape, sources: [SlideShape] = []) -> EffectStyle {
        // Once edited, effects are written as the shape's own.
        if shape.hasOwnEffects || shape.edits.contains(.effects) {
            return EffectStyle(shadow: shape.shadow, reflection: shape.reflection, effects: shape.effects)
        }
        if var themed = themedEffectStyle(for: shape, sources: sources) {
            themed.scene3D = nil
            themed.shape3D = nil
            return themed
        }
        return EffectStyle(shadow: shape.shadow, reflection: shape.reflection, effects: shape.effects)
    }

    /// The theme's effect style a shape's `p:style`, or its placeholder's,
    /// names, in the colour that names it.
    public func themedEffectStyle(for shape: SlideShape, sources: [SlideShape] = []) -> EffectStyle? {
        for candidate in [shape] + sources {
            guard let reference = candidate.style?.effect else { continue }
            guard reference.index > 0, theme.effectStyles.indices.contains(reference.index - 1) else { return nil }
            var themed = theme.effectStyles[reference.index - 1]
            if let color = reference.color {
                if let shadow = themed.shadow { themed.shadow?.color = shadow.color.replacingPlaceholder(with: color) }
                themed.effects = themed.effects.replacingPlaceholder(with: color)
                themed.shape3D = themed.shape3D?.replacingPlaceholder(with: color)
            }
            return themed
        }
        return nil
    }

    /// The shape with the effects it is drawn with made its own. Its camera,
    /// lights, bevels and depth are its own where its properties give them,
    /// and its theme effect style's where they don't.
    public func resolvingEffects(of shape: SlideShape, sources: [SlideShape] = []) -> SlideShape {
        var shape = shape
        if shape.scene3D == nil || shape.shape3D == nil, let themed = themedEffectStyle(for: shape, sources: sources) {
            shape.scene3D = shape.scene3D ?? themed.scene3D
            shape.shape3D = shape.shape3D ?? themed.shape3D
        }
        guard !shape.hasOwnEffects else { return shape }
        let resolved = effects(for: shape, sources: sources)
        shape.shadow = resolved.shadow
        shape.reflection = resolved.reflection
        shape.effects = resolved.effects
        shape.hasOwnEffects = true
        return shape
    }

    /// How a shape's camera, lights, bevels and depth are drawn, for a shape
    /// filling `bounds` whose fill is `fill`. Pictures show their bevel on
    /// the picture. `nil` for a shape without them, and for an open one.
    public func threeDLook(
        for shape: SlideShape, bounds: CGRect, fill: ResolvedFill?, isOpen: Bool = false
    ) -> Shape3DLook? {
        guard let shape3D = shape.shape3D, !isOpen else { return nil }
        let face: RGBAColor? = switch fill?.fill ?? Fill.none {
        case .solid(let color): self.color(color, placeholder: fill?.placeholderColor)
        case .gradient(let gradient): gradient.stops.first.map { self.color($0.color, placeholder: fill?.placeholderColor) }
        case .pattern(let pattern): self.color(pattern.foreground, placeholder: fill?.placeholderColor)
        case .picture, .tiledPicture: RGBAColor(red: 0.6, green: 0.6, blue: 0.6)
        case .none, .group:
            if case .picture = shape.kind { RGBAColor(red: 0.6, green: 0.6, blue: 0.6) } else { nil }
        }
        return Shape3DLook(
            scene: shape.scene3D, shape: shape3D, bounds: bounds, rotation: shape.rotation,
            flipsHorizontally: shape.flipsHorizontally, flipsVertically: shape.flipsVertically, face: face,
            color: { self.color($0, placeholder: fill?.placeholderColor) }
        )
    }

    public func background(of slide: Slide) -> ResolvedFill {
        let background = slide.background ?? layout?.background ?? master?.background
        switch background {
        case .fill(let fill):
            return ResolvedFill(fill: fill)
        case .reference(let index, let reference):
            let list = index >= 1000 ? theme.backgroundFillStyles : theme.fillStyles
            let position = index >= 1000 ? index - 1001 : index - 1
            let fill = list.indices.contains(position) ? list[position] : .solid(.scheme("phClr"))
            return ResolvedFill(fill: fill, placeholderColor: reference.map { color($0) })
        case nil:
            return ResolvedFill(fill: .solid(.scheme("bg1")))
        }
    }

    // MARK: - Text

    public func bodyProperties(for shape: SlideShape, sources: [SlideShape]) -> BodyProperties {
        var properties = shape.text?.properties ?? BodyProperties()
        for source in sources {
            if let inherited = source.text?.properties { properties = properties.merged(over: inherited) }
        }
        return properties
    }

    /// Paragraph properties at an outline level, with everything above the
    /// paragraph itself folded in.
    public func paragraphBase(for shape: SlideShape, sources: [SlideShape], level: Int) -> ParagraphProperties {
        var properties = shape.text?.listStyle.level(level) ?? ParagraphProperties()
        for source in sources {
            if let inherited = source.text?.listStyle.level(level) { properties = properties.merged(over: inherited) }
        }
        if let fontColor = shape.style?.fontColor ?? sources.lazy.compactMap(\.style?.fontColor).first {
            var layer = ParagraphProperties()
            layer.defaultRun.color = fontColor
            properties = properties.merged(over: layer)
        }
        if let placeholder = shape.placeholder, let master {
            properties = properties.merged(over: master.textStyle(placeholder.textStyleCategory).level(level))
        }
        return properties.merged(over: resources.defaultTextStyle.level(level))
    }

    /// A theme font reference such as `+mj-lt`, made a typeface name.
    public func typeface(_ name: String?, eastAsian: Bool = false) -> String? {
        name.map(theme.typeface)
    }
}
