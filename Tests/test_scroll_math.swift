// Standalone check for the scroll feel math. Run with:
//   swiftc -o /tmp/scrollmath Tests/test_scroll_math.swift MacDial/ScrollMath.swift && /tmp/scrollmath

func assertClose(_ a: Double, _ b: Double, _ label: String, tolerance: Double = 1e-9) {
    assert(abs(a - b) < tolerance, "\(label): \(a) != \(b)")
}

@main
enum ScrollMathTests {
    static func main() {
        // Gain curve: identity at rest, monotonic, capped.
        assertClose(ScrollMath.gain(velocity: 0, accel: 3, exponent: 1.35, maxGain: 12), 1, "gain at rest is 1")
        var last = 0.0
        for i in 0 ... 100 {
            let g = ScrollMath.gain(velocity: Double(i) * 0.1, accel: 3, exponent: 1.35, maxGain: 12)
            assert(g >= last, "gain must be monotonic")
            assert(g <= 12, "gain must respect maxGain")
            last = g
        }

        assert(ScrollMath.gain(velocity: 1e6, accel: 3, exponent: 1.35, maxGain: 12) == 12, "gain caps at maxGain")
        assert(ScrollMath.gain(velocity: -5, accel: 3, exponent: 1.35, maxGain: 12) == 1, "negative velocity clamps to rest")

        // Release: sign-preserving, converging, and lossless overall.
        for pending0 in [240.0, -240.0] {
            var pending = pending0
            var emitted = 0.0
            for _ in 0 ..< 200 { // 200 frames @120Hz
                let portion = ScrollMath.releasePortion(pending: pending, dt: 1.0 / 120, tau: 0.045)
                assert(portion == 0 || (portion > 0) == (pending > 0), "release preserves direction")
                assert(abs(portion) <= abs(pending) + 1e-9, "release never overshoots")
                pending -= portion
                emitted += portion
            }
            assertClose(emitted, pending0, "all pending pixels are eventually emitted")
            assertClose(pending, 0, "pending drains to exactly zero")
        }

        // Tail flush: small residue emits exactly, in one frame.
        assertClose(ScrollMath.releasePortion(pending: 1.2, dt: 1.0 / 120, tau: 0.045), 1.2, "tail flushes exactly")
        assert(ScrollMath.releasePortion(pending: 0, dt: 1.0 / 120, tau: 0.045) == 0, "zero pending emits nothing")

        // Regression: the engine's whole-pixel emit loop must fully drain a
        // SMALL pool (2-5px once rounded to zero pixels per frame forever).
        var pending = 3.0
        var residual = 0.0
        var wholeEmitted = 0
        for _ in 0 ..< 60 { // half a second at 120Hz
            let portion = ScrollMath.releasePortion(pending: pending, dt: 1.0 / 120, tau: 0.045)
            pending -= portion
            residual += portion
            // Mirrors the engine: truncate mid-gesture, snap to nearest once
            // the pool is empty so float error can't strand the last pixel.
            let emit = Int(residual.rounded(pending == 0 ? .toNearestOrAwayFromZero : .towardZero))
            residual -= Double(emit)
            wholeEmitted += emit
        }
        assert(pending == 0, "small pool must drain, \(pending)px left stranded")
        assert(wholeEmitted == 3, "all 3 whole pixels must be emitted, got \(wholeEmitted)")

        // Velocity tracker: steady 1 rev/s input reads ~1 rev/s; stale
        // samples fall out of the window.
        var tracker = VelocityTracker()
        var v = 0.0
        for i in 0 ... 30 { // 100 ticks/s, 0.01 revs each = 1 rev/s
            v = tracker.record(revs: 0.01, at: Double(i) * 0.01)
        }
        assert(abs(v - 1.0) < 0.15, "steady spin reads ~1 rev/s, got \(v)")
        v = tracker.record(revs: 0.0, at: 10)
        assert(v < 0.01, "velocity decays once samples age out, got \(v)")

        print("scroll math: all checks passed")
    }
}
