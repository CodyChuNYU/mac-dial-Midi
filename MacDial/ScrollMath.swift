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

/// Angular velocity estimate over a sliding 150ms window. Time is supplied
/// by the caller (seconds, any monotonic clock) so this stays pure/testable.
struct VelocityTracker {
    private var samples: [(t: Double, revs: Double)] = []

    /// Record a rotation of `revs` (sign ignored) at time `t`; returns the
    /// current speed in revolutions per second.
    mutating func record(revs: Double, at t: Double) -> Double {
        samples.append((t, abs(revs)))
        let cutoff = t - 0.15
        samples.removeAll { $0.t < cutoff }
        return samples.reduce(0) { $0 + $1.revs } / 0.15
    }
}
