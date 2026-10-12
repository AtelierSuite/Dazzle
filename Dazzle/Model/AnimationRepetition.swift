import Foundation

/// Repeats and auto-reverse apply to a complete animation cycle. A nil count
/// repeats until the presenter advances; repeatDuration can bound that run.
struct AnimationRepetition: Equatable, Hashable, Sendable {
    var count: Double? = 1
    var autoReverses = false
    var repeatDuration: Double?

    func duration(base: Double) -> Double {
        guard base > 0 else { return 0 }
        let total = count.map { max($0, 0) * base * (autoReverses ? 2 : 1) } ?? .infinity
        return repeatDuration.map { min(total, max($0, 0)) } ?? total
    }

    func progress(elapsed: Double, base: Double, finished: Bool = false) -> Double {
        guard base > 0 else { return autoReverses ? 0 : 1 }
        let total = duration(base: base)
        let end = finished || elapsed >= total
        if finished && !total.isFinite { return autoReverses ? 0 : 1 }
        let time = min(max(elapsed, 0), total)
        let cycle = base * (autoReverses ? 2 : 1)
        var local = time.truncatingRemainder(dividingBy: cycle) / base
        // A finite run ending exactly at a boundary holds its last endpoint.
        if end && time > 0 && local < 0.0000001 { local = autoReverses ? 2 : 1 }
        return autoReverses && local > 1 ? 2 - local : min(local, 1)
    }
}
