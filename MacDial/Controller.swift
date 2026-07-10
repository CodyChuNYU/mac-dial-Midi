import Foundation

protocol Controller: AnyObject {
    func onDown(dial: Dial)

    func onUp(dial: Dial)

    /// `direction` is +1 (standard) or -1 (natural).
    func onRotate(dial: Dial, rotation: Dial.Rotation, direction: Int)
}

/// Converts raw detent ticks into coarse steps independent of the dial's
/// hardware resolution (~36 steps per revolution regardless of sensitivity),
/// carrying the remainder so slow rotation still accumulates.
struct TickAccumulator {
    private var residual = 0

    mutating func steps(ticks: Int, ticksPerRevolution: Int) -> Int {
        let ticksPerStep = max(1, ticksPerRevolution / 36)
        residual += ticks
        let steps = residual / ticksPerStep
        residual -= steps * ticksPerStep
        return steps
    }

    mutating func reset() {
        residual = 0
    }
}
