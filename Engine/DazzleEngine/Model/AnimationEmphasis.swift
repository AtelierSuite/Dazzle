import Foundation

/// Numeric behaviour keyframes, expressed as fractions of the behaviour time.
public struct AnimationScalar: Equatable, Hashable, Sendable {
    public struct Keyframe: Equatable, Hashable, Sendable { public var time: Double; public var value: Double }
    public var from: Double?
    public var to: Double?
    public var by: Double?
    public var keyframes: [Keyframe] = []
    public var isDiscrete = false

    public func value(at progress: Double, base: Double) -> Double {
        let p = min(max(progress, 0), 1)
        let start = from ?? base
        guard !keyframes.isEmpty else { return start + ((to ?? (start + (by ?? 0))) - start) * p }
        let keys = keyframes.sorted { $0.time < $1.time }
        guard let next = keys.firstIndex(where: { $0.time > p }) else { return keys.last!.value }
        guard next > 0 else { return keys[0].value }
        let left = keys[next-1], right = keys[next]
        if isDiscrete { return left.value }
        let t = (p-left.time) / max(right.time-left.time, 0.000001)
        return left.value + (right.value-left.value)*t
    }
}

public struct AnimationColorChange: Equatable, Hashable, Sendable {
    public enum Target: String, Hashable, Sendable { case fill, stroke, text }
    public var target: Target
    public var from: DrawingColor?
    public var to: DrawingColor
    public var usesHSL = false
    public var clockwise = true

    public struct Value: Equatable, Hashable, Sendable {
        public var change: AnimationColorChange
        public var progress: Double
        public func color(base: RGBAColor, resolve: (DrawingColor) -> RGBAColor) -> RGBAColor {
            let a = change.from.map(resolve) ?? base, b = resolve(change.to), p = min(max(progress, 0), 1)
            let alpha = a.alpha + (b.alpha-a.alpha)*p
            if change.usesHSL {
                let first = a.hsl, last = b.hsl
                var distance = last.hue-first.hue
                if change.clockwise && distance < 0 { distance += 1 }
                if !change.clockwise && distance > 0 { distance -= 1 }
                let hue = (first.hue+distance*p+1).truncatingRemainder(dividingBy: 1)
                return RGBAColor(hue: hue, saturation: first.saturation+(last.saturation-first.saturation)*p,
                                 luminance: first.luminance+(last.luminance-first.luminance)*p, alpha: alpha)
            }
            return RGBAColor(red: a.red+(b.red-a.red)*p, green: a.green+(b.green-a.green)*p,
                             blue: a.blue+(b.blue-a.blue)*p, alpha: alpha)
        }
    }
}
