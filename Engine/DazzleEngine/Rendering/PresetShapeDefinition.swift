#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A preset shape as ECMA-376's presetShapeDefinitions.xml defines it: adjust
/// values, guides computed from them and the shape's size, a text rectangle,
/// and paths drawn through the guides. Read from the table
/// PresetShapeDefinitions.swift holds, which Engine/Scripts/generate-preset-shapes.py
/// writes.
struct PresetShapeDefinition: Sendable {
    /// A number in a formula or a path: a constant, or a value computed earlier.
    enum Operand: Sendable {
        case number(CGFloat)
        case slot(Int)
    }

    enum Operation: String, Sendable {
        case multiplyDivide = "*/", addSubtract = "+-", addDivide = "+/", ifElse = "?:", abs, at2, cat2, cos, max, min
        case mod, pin, sat2, sin, sqrt, tan, val
    }

    struct Guide: Sendable {
        var operation: Operation
        var x: Operand, y: Operand, z: Operand
    }

    enum Command: Sendable {
        case move(Operand, Operand)
        case line(Operand, Operand)
        case arc(wR: Operand, hR: Operand, start: Operand, sweep: Operand)
        case quadratic(Operand, Operand, Operand, Operand)
        case cubic(Operand, Operand, Operand, Operand, Operand, Operand)
        case close
    }

    /// How a path is filled: with the shape's fill, not at all, or with the
    /// fill darkened or lightened, which gives cubes and scrolls their depth.
    enum Fill: Character, Sendable {
        case norm = "n", none = "x", darken = "d", darkenLess = "D", lighten = "l", lightenLess = "L"
    }

    struct Path: Sendable {
        /// The path's own coordinate space, or zero for the shape's.
        var width: CGFloat
        var height: CGFloat
        var fill: Fill
        var isStroked: Bool
        var commands: [Command] = []
    }

    /// The names every formula can use, in the order of their slots.
    static let builtIns = [
        "w", "h", "l", "t", "r", "b", "hc", "vc", "ss", "ls", "cd2", "cd4", "cd8", "3cd4", "3cd8", "5cd8", "7cd8",
        "wd2", "wd3", "wd4", "wd5", "wd6", "wd8", "wd10", "wd12", "wd32",
        "hd2", "hd3", "hd4", "hd5", "hd6", "hd8", "hd10", "ssd2", "ssd4", "ssd6", "ssd8", "ssd16", "ssd32",
    ]

    private static func builtInValues(width w: CGFloat, height h: CGFloat) -> [CGFloat] {
        let ss = Swift.min(w, h)
        return [
            w, h, 0, 0, w, h, w / 2, h / 2, ss, Swift.max(w, h), 10_800_000, 5_400_000, 2_700_000, 16_200_000,
            8_100_000, 13_500_000, 18_900_000,
            w / 2, w / 3, w / 4, w / 5, w / 6, w / 8, w / 10, w / 12, w / 32,
            h / 2, h / 3, h / 4, h / 5, h / 6, h / 8, h / 10, ss / 2, ss / 4, ss / 6, ss / 8, ss / 16, ss / 32,
        ]
    }

    /// The adjust values' names and defaults, which take the slots after the built-in names.
    var adjusts: [(name: String, value: CGFloat)] = []
    /// The guides, which take the slots after the adjust values, in order.
    var guides: [Guide] = []
    var textRect: (left: Operand, top: Operand, right: Operand, bottom: Operand)?
    /// Where connectors meet the shape, in the order `a:stCxn` and `a:endCxn` count them.
    var sites: [(angle: Operand, x: Operand, y: Operand)] = []
    var paths: [Path] = []

    /// Whether no path is filled, so the preset is a line.
    var isOpen: Bool { paths.allSatisfy { $0.fill == .none } }

    static func named(_ name: String) -> PresetShapeDefinition? { all[name] }

    private static let all: [String: PresetShapeDefinition] = encoded.compactMapValues(PresetShapeDefinition.init(encoded:))

    /// Reads the generator's encoding (see generate-preset-shapes.py).
    init?(encoded: String) {
        var slots: [Substring: Int] = [:]
        for (index, name) in Self.builtIns.enumerated() { slots[Substring(name)] = index }
        func operand(_ token: Substring) -> Operand? {
            if let slot = slots[token] { return .slot(slot) }
            return Double(token).map { .number(CGFloat($0)) }
        }
        for statement in encoded.split(separator: ";") {
            let tokens = statement.split(separator: " ")
            guard let kind = tokens.first else { continue }
            let operands = tokens.dropFirst().compactMap(operand)
            switch kind {
            case "a":
                guard tokens.count == 3, let value = Double(tokens[2]) else { return nil }
                slots[tokens[1]] = Self.builtIns.count + adjusts.count
                adjusts.append((String(tokens[1]), CGFloat(value)))
            case "g":
                guard tokens.count >= 4, let operation = Operation(rawValue: String(tokens[2])) else { return nil }
                let arguments = tokens.dropFirst(3).compactMap(operand)
                guard arguments.count == tokens.count - 3 else { return nil }
                let zero = Operand.number(0)
                guides.append(Guide(operation: operation, x: arguments[0],
                                    y: arguments.count > 1 ? arguments[1] : zero, z: arguments.count > 2 ? arguments[2] : zero))
                slots[tokens[1]] = Self.builtIns.count + adjusts.count + guides.count - 1
            case "t":
                guard operands.count == 4 else { return nil }
                textRect = (operands[0], operands[1], operands[2], operands[3])
            case "c":
                guard operands.count == 3 else { return nil }
                sites.append((operands[0], operands[1], operands[2]))
            case "p":
                guard tokens.count == 5, let width = Double(tokens[1]), let height = Double(tokens[2]),
                      let fillCode = tokens[3].first, let fill = Fill(rawValue: fillCode) else { return nil }
                paths.append(Path(width: CGFloat(width), height: CGFloat(height), fill: fill, isStroked: tokens[4] == "1"))
            default:
                guard !paths.isEmpty, operands.count == tokens.count - 1 else { return nil }
                let command: Command
                switch (kind, operands.count) {
                case ("M", 2): command = .move(operands[0], operands[1])
                case ("L", 2): command = .line(operands[0], operands[1])
                case ("A", 4): command = .arc(wR: operands[0], hR: operands[1], start: operands[2], sweep: operands[3])
                case ("Q", 4): command = .quadratic(operands[0], operands[1], operands[2], operands[3])
                case ("C", 6): command = .cubic(operands[0], operands[1], operands[2], operands[3], operands[4], operands[5])
                case ("Z", 0): command = .close
                default: return nil
                }
                paths[paths.count - 1].commands.append(command)
            }
        }
        // `line` and `lineInv` don't say their one straight path isn't
        // filled, but it has no area to fill.
        for index in paths.indices where paths[index].commands.allSatisfy({
            if case .move = $0 { true } else if case .line = $0 { true } else { false }
        }) {
            paths[index].fill = .none
        }
    }

    /// Every slot's value for a shape of `size`, with the file's adjust values in place of the defaults.
    func values(adjustments: [String: Int], size: CGSize) -> [CGFloat] {
        var values = Self.builtInValues(width: size.width, height: size.height)
        values.reserveCapacity(values.count + adjusts.count + guides.count)
        for adjust in adjusts {
            values.append(adjustments[adjust.name].map { CGFloat($0) } ?? adjust.value)
        }
        func value(_ operand: Operand) -> CGFloat {
            switch operand {
            case .number(let number): number
            case .slot(let slot): values[slot]
            }
        }
        /// Angles are in 60000ths of a degree.
        func radians(_ angle: CGFloat) -> CGFloat { angle / 60_000 * .pi / 180 }
        for guide in guides {
            let x = value(guide.x), y = value(guide.y), z = value(guide.z)
            var result: CGFloat
            switch guide.operation {
            case .multiplyDivide: result = z == 0 ? 0 : x * y / z
            case .addSubtract: result = x + y - z
            case .addDivide: result = z == 0 ? 0 : (x + y) / z
            case .ifElse: result = x > 0 ? y : z
            case .abs: result = Swift.abs(x)
            case .at2: result = atan2(y, x) * 180 / .pi * 60_000
            case .cat2: result = x * Foundation.cos(atan2(z, y))
            case .cos: result = x * Foundation.cos(radians(y))
            case .max: result = Swift.max(x, y)
            case .min: result = Swift.min(x, y)
            case .mod: result = (x * x + y * y + z * z).squareRoot()
            case .pin: result = y < x ? x : y > z ? z : y
            case .sat2: result = x * Foundation.sin(atan2(z, y))
            case .sin: result = x * Foundation.sin(radians(y))
            case .sqrt: result = Swift.max(x, 0).squareRoot()
            case .tan: result = x * Foundation.tan(radians(y))
            case .val: result = x
            }
            values.append(result.isFinite ? result : 0)
        }
        return values
    }

    /// The text rectangle, for a shape drawn in `rect`.
    func textRect(adjustments: [String: Int], in rect: CGRect) -> CGRect? {
        guard let textRect else { return nil }
        let values = values(adjustments: adjustments, size: rect.size)
        func value(_ operand: Operand) -> CGFloat {
            switch operand {
            case .number(let number): number
            case .slot(let slot): values[slot]
            }
        }
        let left = value(textRect.left), top = value(textRect.top)
        return CGRect(x: rect.minX + left, y: rect.minY + top,
                      width: Swift.max(value(textRect.right) - left, 1), height: Swift.max(value(textRect.bottom) - top, 1))
    }

    /// The connection sites of a shape drawn in `rect`: where each is, and
    /// the angle a connector leaves it at, in degrees clockwise from rightwards.
    func connectionSites(adjustments: [String: Int], in rect: CGRect) -> [(point: CGPoint, angle: CGFloat)] {
        let values = values(adjustments: adjustments, size: rect.size)
        func value(_ operand: Operand) -> CGFloat {
            switch operand {
            case .number(let number): number
            case .slot(let slot): values[slot]
            }
        }
        return sites.map { site in
            (CGPoint(x: rect.minX + value(site.x), y: rect.minY + value(site.y)), value(site.angle) / 60_000)
        }
    }

    /// The paths, drawn in `rect`.
    func draw(adjustments: [String: Int], in rect: CGRect) -> [(path: Path, outline: CGMutablePath)] {
        let values = values(adjustments: adjustments, size: rect.size)
        func value(_ operand: Operand) -> CGFloat {
            switch operand {
            case .number(let number): number
            case .slot(let slot): values[slot]
            }
        }
        return paths.map { path in
            let scale = CGSize(width: path.width > 0 ? rect.width / path.width : 1,
                               height: path.height > 0 ? rect.height / path.height : 1)
            func point(_ x: Operand, _ y: Operand) -> CGPoint {
                CGPoint(x: rect.minX + value(x) * scale.width, y: rect.minY + value(y) * scale.height)
            }
            let outline = CGMutablePath()
            var current = CGPoint(x: rect.minX, y: rect.minY)
            var start = current
            for command in path.commands {
                switch command {
                case .move(let x, let y):
                    current = point(x, y)
                    start = current
                    outline.move(to: current)
                case .line(let x, let y):
                    current = point(x, y)
                    outline.addLine(to: current)
                case .arc(let wR, let hR, let startAngle, let sweep):
                    if outline.isEmpty { outline.move(to: current) }
                    current = PresetGeometry.arcTo(outline, from: current, wR: value(wR), hR: value(hR),
                                                   start: value(startAngle), sweep: value(sweep), scale: scale)
                case .quadratic(let x1, let y1, let x2, let y2):
                    current = point(x2, y2)
                    outline.addQuadCurve(to: current, control: point(x1, y1))
                case .cubic(let x1, let y1, let x2, let y2, let x3, let y3):
                    current = point(x3, y3)
                    outline.addCurve(to: current, control1: point(x1, y1), control2: point(x2, y2))
                case .close:
                    outline.closeSubpath()
                    current = start
                }
            }
            return (path, outline)
        }
    }
}
