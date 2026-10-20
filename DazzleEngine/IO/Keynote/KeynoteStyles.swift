import CoreGraphics
import Foundation

/// Looks properties up through Keynote's style inheritance and turns the
/// drawing ones into DrawingML.
///
/// A Keynote style sets only what differs from its parent, so every property
/// is read from the first style up the chain that has it.
public struct KeynoteStyles {
    public let archive: KeynoteArchive

    /// The first value `read` finds, starting at `style` and walking parents.
    public func resolve<Value>(_ style: UInt64?, _ read: (KeynoteArchive.Object) -> Value?) -> Value? {
        var current = style
        var visited: Set<UInt64> = []
        while let identifier = current, visited.insert(identifier).inserted, let object = archive[identifier] {
            if let value = read(object) { return value }
            current = Self.styleArchive(of: object)?.reference(3)
        }
        return nil
    }

    /// The `TSS.StyleArchive` every style starts with, which names its parent.
    private static func styleArchive(of object: KeynoteArchive.Object) -> ProtoMessage? {
        // Text shape styles extend drawing shape styles, which extend the base.
        object.type == KeynoteType.textShapeStyle ? object.message.message(1)?.message(1) : object.message.message(1)
    }

    /// What a shape or media style sets, and where: shapes number their
    /// fill, stroke, opacity, shadow and reflection from 1, media from stroke at 1.
    private static func drawingProperties(_ object: KeynoteArchive.Object) -> (message: ProtoMessage, offset: Int)? {
        switch object.type {
        case KeynoteType.textShapeStyle: object.message.message(1)?.message(11).map { ($0, 0) }
        case KeynoteType.shapeStyle: object.message.message(11).map { ($0, 0) }
        case KeynoteType.mediaStyle: object.message.message(11).map { ($0, -1) }
        default: nil
        }
    }

    public enum DrawingProperty: Int {
        case fill = 1, stroke, opacity, shadow, reflection
        case headLineEnd = 6, tailLineEnd
    }

    public func drawingProperty(_ style: UInt64?, _ property: DrawingProperty) -> ProtoMessage? {
        resolve(style) { object in
            Self.drawingProperties(object).flatMap { $0.message.message(property.rawValue + $0.offset) }
        }
    }

    public func opacity(_ style: UInt64?) -> Double {
        resolve(style) { object in
            Self.drawingProperties(object).flatMap { $0.message.float(DrawingProperty.opacity.rawValue + $0.offset) }
        } ?? 1
    }

    // MARK: - Colour

    /// `RRGGBB` and alpha in sRGB, converting from Display P3, CMYK and grey.
    public static func color(_ message: ProtoMessage?) -> (hex: String, alpha: Double)? {
        guard let message else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0
        switch message.int(1) ?? 1 {
        case 2:
            let black = message.float(10) ?? 0
            red = (1 - (message.float(7) ?? 0)) * (1 - black)
            green = (1 - (message.float(8) ?? 0)) * (1 - black)
            blue = (1 - (message.float(9) ?? 0)) * (1 - black)
        case 3:
            red = message.float(11) ?? 0
            green = red
            blue = red
        default:
            red = message.float(3) ?? 0
            green = message.float(4) ?? 0
            blue = message.float(5) ?? 0
            if message.int(12) == 2, let p3 = CGColorSpace(name: CGColorSpace.displayP3),
               let srgb = CGColorSpace(name: CGColorSpace.sRGB),
               let converted = CGColor(colorSpace: p3, components: [red, green, blue, 1])?
                .converted(to: srgb, intent: .relativeColorimetric, options: nil),
               let components = converted.components, components.count >= 3 {
                red = components[0]
                green = components[1]
                blue = components[2]
            }
        }
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return (String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue)), message.float(6) ?? 1)
    }

    public static func colorXML(_ message: ProtoMessage?, opacity: Double = 1) -> String? {
        guard let color = color(message) else { return nil }
        let alpha = color.alpha * opacity
        let alphaXML = alpha < 0.999 ? "<a:alpha val=\"\(Int((max(alpha, 0) * 100_000).rounded()))\"/>" : ""
        return "<a:srgbClr val=\"\(color.hex)\">\(alphaXML)</a:srgbClr>"
    }

    public static func solidFill(_ message: ProtoMessage?, opacity: Double = 1) -> String? {
        colorXML(message, opacity: opacity).map { "<a:solidFill>\($0)</a:solidFill>" }
    }

    // MARK: - Fill

    /// A `TSD.FillArchive` as a DrawingML fill. Image fills need a
    /// relationship, so `image` is asked for one.
    public static func fill(_ fill: ProtoMessage?, opacity: Double, image: (UInt64) -> String?) -> String? {
        guard let fill else { return nil }
        if let color = fill.message(1) {
            return solidFill(color, opacity: opacity)
        }
        if let gradient = fill.message(2) {
            return gradientFill(gradient, opacity: opacity)
        }
        if let imageFill = fill.message(3), let data = imageFill.reference(6) ?? imageFill.reference(7),
           let relationship = image(data) {
            let mode = switch imageFill.int(2) ?? 0 {
            case 2: "<a:tile tx=\"0\" ty=\"0\" sx=\"100000\" sy=\"100000\" flip=\"none\" algn=\"tl\"/>"
            default: "<a:stretch><a:fillRect/></a:stretch>"
            }
            let alpha = opacity < 0.999 ? "<a:alphaModFix amt=\"\(Int(opacity * 100_000))\"/>" : ""
            return "<a:blipFill rotWithShape=\"1\"><a:blip r:embed=\"\(relationship)\">\(alpha)</a:blip>\(mode)</a:blipFill>"
        }
        // A texture the document doesn't carry leaves the colour it was tinted with.
        if let tint = fill.message(3)?.message(3) {
            return solidFill(tint, opacity: opacity)
        }
        return nil
    }

    private static func gradientFill(_ gradient: ProtoMessage, opacity: Double) -> String? {
        let gradientOpacity = (gradient.float(3) ?? 1) * opacity
        let stops = gradient.messages(2).compactMap { stop -> String? in
            guard let color = colorXML(stop.message(1), opacity: gradientOpacity) else { return nil }
            let position = Int(((stop.float(2) ?? 0) * 100_000).rounded())
            return "<a:gs pos=\"\(min(max(position, 0), 100_000))\">\(color)</a:gs>"
        }
        guard !stops.isEmpty else { return nil }
        let shade: String
        if gradient.int(1) == 1 {
            shade = "<a:path path=\"circle\"><a:fillToRect l=\"50000\" t=\"50000\" r=\"50000\" b=\"50000\"/></a:path>"
        } else {
            // Keynote measures anticlockwise with y up; DrawingML clockwise with y down.
            let radians = gradient.message(5)?.float(2) ?? 0
            var degrees = (360 - radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
            if degrees < 0 { degrees += 360 }
            shade = "<a:lin ang=\"\(Int((degrees * 60_000).rounded()))\" scaled=\"0\"/>"
        }
        return "<a:gradFill rotWithShape=\"1\"><a:gsLst>\(stops.joined())</a:gsLst>\(shade)</a:gradFill>"
    }

    // MARK: - Stroke

    /// A `TSD.StrokeArchive` and line ends as `a:ln`, or as a table cell's
    /// `a:lnL` and the like.
    public static func line(
        _ stroke: ProtoMessage?, head: ProtoMessage?, tail: ProtoMessage?, opacity: Double, element: String = "ln"
    ) -> String {
        guard let stroke, let width = stroke.float(2), width > 0,
              stroke.message(6)?.int(1) != 2,
              let color = solidFill(stroke.message(1), opacity: opacity) else {
            return "<a:\(element)><a:noFill/></a:\(element)>"
        }
        let cap = switch stroke.int(3) ?? 0 {
        case 1: " cap=\"rnd\""
        case 2: " cap=\"sq\""
        default: ""
        }
        var dash = ""
        if let pattern = stroke.message(6), pattern.int(1) == 0 {
            let lengths = Array(pattern.floats(4).prefix(pattern.int(3) ?? Int.max))
            var stops: [String] = []
            var index = 0
            while index + 1 < lengths.count {
                stops.append("<a:ds d=\"\(Int(lengths[index] * 100_000))\" sp=\"\(Int(lengths[index + 1] * 100_000))\"/>")
                index += 2
            }
            if !stops.isEmpty { dash = "<a:custDash>\(stops.joined())</a:custDash>" }
        }
        let join = switch stroke.int(4) ?? 0 {
        case 1: "<a:round/>"
        case 2: "<a:bevel/>"
        default: "<a:miter lim=\"800000\"/>"
        }
        // Keynote's head is where the path ends; DrawingML's where the line starts.
        let ends = (lineEnd(tail, element: "headEnd") ?? "") + (lineEnd(head, element: "tailEnd") ?? "")
        return "<a:\(element) w=\"\(KeynoteUnits.emu(width))\"\(cap)>\(color)\(dash)\(join)\(ends)</a:\(element)>"
    }

    private static func lineEnd(_ end: ProtoMessage?, element: String) -> String? {
        guard let identifier = end?.string(5)?.lowercased(), !identifier.isEmpty, identifier != "none" else { return nil }
        let type = if identifier.contains("circle") || identifier.contains("dot") {
            "oval"
        } else if identifier.contains("diamond") || identifier.contains("square") {
            "diamond"
        } else if identifier.contains("open") || identifier.contains("simple") || identifier.contains("line") {
            "arrow"
        } else {
            "triangle"
        }
        return "<a:\(element) type=\"\(type)\" w=\"med\" len=\"med\"/>"
    }

    // MARK: - Shadow

    /// A shape's shadow and reflection as `a:effectLst`, or `nil` for neither.
    public static func effects(_ shadow: ProtoMessage?, reflection: ProtoMessage? = nil, opacity: Double) -> String? {
        let list = (self.shadow(shadow, opacity: opacity) ?? "") + (self.reflection(reflection) ?? "")
        return list.isEmpty ? nil : "<a:effectLst>\(list)</a:effectLst>"
    }

    /// A `TSD.ShadowArchive` as `a:outerShdw`, for shapes and text alike.
    public static func shadow(_ shadow: ProtoMessage?, opacity: Double) -> String? {
        guard let shadow, shadow.bool(6) ?? true, shadow.int(7) ?? 0 == 0,
              let color = colorXML(shadow.message(1), opacity: (shadow.float(5) ?? 1) * opacity) else { return nil }
        var direction = (360 - (shadow.float(2) ?? 315)).truncatingRemainder(dividingBy: 360)
        if direction < 0 { direction += 360 }
        let distance = KeynoteUnits.emu(shadow.float(3) ?? 5)
        let blur = KeynoteUnits.emu(Double(shadow.int(4) ?? 1))
        return """
            <a:outerShdw blurRad="\(blur)" dist="\(distance)" dir="\(Int(direction * 60_000))" \
            algn="ctr" rotWithShape="0">\(color)</a:outerShdw>
            """
    }

    /// A `TSD.ReflectionArchive`: Keynote fades its reflections out halfway
    /// down from the opacity it gives them, and stands them upright below
    /// turned shapes. The shape's own opacity is in what is reflected already.
    private static func reflection(_ reflection: ProtoMessage?) -> String? {
        // Styles with no reflection keep an empty one.
        guard let start = reflection?.float(1), start > 0 else { return nil }
        return Reflection(startOpacity: start, endPosition: 0.5, rotatesWithShape: false).xml
    }
}

public enum KeynoteUnits {
    /// Keynote measures in points.
    public static func emu(_ points: Double) -> Int { Int((points * 12_700).rounded()) }
}
