import Foundation

/// Pure math behind the scroll feel — kept dependency-free so it can be
/// compiled and asserted standalone (see Tests/test_scroll_math.swift).
enum ScrollMath {
    /// Acceleration multiplier for a given angular velocity (rev/s).
    /// 1.0 at rest, rising along a power curve, capped at maxGain.
    static func gain(velocity: Double, accel: Double, exponent: Double, maxGain: Double) -> Double {
        min(maxGain, 1 + accel * pow(max(0, velocity), exponent))
    }

    /// Exponential-release accumulator: how many of the pending pixels to
    /// emit for a frame of duration dt. Emits a fixed fraction of what's
    /// left each frame (converging smoothly), and flushes the sub-1.5px
    /// tail exactly so no travel is ever lost.
    static func releasePortion(pending: Double, dt: Double, tau: Double) -> Double {
        guard pending != 0 else { return 0 }
        if abs(pending) < 1.5 { return pending }
        return pending * (1 - exp(-dt / max(tau, 0.001)))
    }
}
