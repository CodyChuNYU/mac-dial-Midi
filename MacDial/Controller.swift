import Foundation

protocol Controller: AnyObject {
    func onDown(dial: Dial)

    func onUp(dial: Dial)

    /// `direction` is +1 (standard) or -1 (natural).
    func onRotate(dial: Dial, rotation: Dial.Rotation, direction: Int)
}

/// Converts raw detent ticks into coarse steps independent of the dial's
/// hardware resolution (stepsPerRevolution regardless of sensitivity),
/// carrying the remainder so slow rotation still accumulates. An optional
/// gain multiplier lets callers accelerate fast spins.
struct TickAccumulator {
    private var residual = 0.0

    mutating func steps(ticks: Int, ticksPerRevolution: Int,
                        stepsPerRevolution: Int = 36, gain: Double = 1) -> Int
    {
        let ticksPerStep = max(1, ticksPerRevolution / max(1, stepsPerRevolution))
        residual += Double(ticks) * gain
        let steps = Int(residual / Double(ticksPerStep))
        residual -= Double(steps * ticksPerStep)
        return steps
    }

    mutating func reset() {
        residual = 0
    }
}
