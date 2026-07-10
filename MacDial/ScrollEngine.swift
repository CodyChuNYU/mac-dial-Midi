import CoreGraphics
import CoreVideo
import Foundation

/// Turns dial detents into trackpad-quality pixel scrolling.
///
/// Feel model:
///  - Input is normalized to revolutions, so hardware sensitivity changes
///    granularity but not speed.
///  - A velocity-based gain curve (1 + accel * v^exponent) accelerates fast
///    spins while keeping slow rotation precise.
///  - Output pixels go through an exponential-release accumulator drained on
///    a display link, so irregular HID reports become a smooth per-frame
///    stream with sub-pixel carry — no tick is ever lost or duplicated.
final class ScrollEngine {
    static let shared = ScrollEngine()

    struct Config {
        /// Pixels scrolled by one slow full revolution.
        var pixelsPerRevolution: Double = 360
        /// Acceleration strength: gain = 1 + accel * v^exponent (v in rev/s).
        var accel: Double = 3.0
        /// Curve shape; >1 keeps slow speeds precise and ramps up fast spins.
        var exponent: Double = 1.35
        /// Upper bound on the acceleration multiplier.
        var maxGain: Double = 12
        /// Smoothing time constant (seconds). Higher = silkier, more latency.
        var tau: Double = 0.045

        static func load() -> Config {
            var c = Config()
            let d = UserDefaults.standard
            if d.object(forKey: "scroll.pixelsPerRevolution") != nil {
                c.pixelsPerRevolution = d.double(forKey: "scroll.pixelsPerRevolution")
                c.accel = d.double(forKey: "scroll.accel")
                c.exponent = d.double(forKey: "scroll.exponent")
                c.maxGain = d.double(forKey: "scroll.maxGain")
                c.tau = d.double(forKey: "scroll.tau")
            }
            return c
        }

        func save() {
            let d = UserDefaults.standard
            d.set(pixelsPerRevolution, forKey: "scroll.pixelsPerRevolution")
            d.set(accel, forKey: "scroll.accel")
            d.set(exponent, forKey: "scroll.exponent")
            d.set(maxGain, forKey: "scroll.maxGain")
            d.set(tau, forKey: "scroll.tau")
        }
    }

    private let source: CGEventSource
    private let lock = NSLock()
    private var cfg = Config.load()

    /// Pixels waiting to be emitted (signed, sub-pixel precision).
    private var pendingPixels: Double = 0
    // Sliding window of (timestamp ns, revolutions) for velocity estimation.
    private var recentRevs: [(t: UInt64, revs: Double)] = []
    private var lastDrainNS: UInt64 = 0
    private var displayLink: CVDisplayLink?

    private init() {
        guard let s = CGEventSource(stateID: .hidSystemState) else {
            fatalError("Could not create CGEventSource")
        }
        source = s
        source.localEventsSuppressionInterval = 0.0
        startDisplayLink()
    }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
    }

    // MARK: - API

    /// Thread-safe. `ticks` is a signed detent count; `ticksPerRevolution`
    /// is the dial's current hardware sensitivity.
    func ingest(ticks: Int, ticksPerRevolution: Int) {
        guard ticks != 0, ticksPerRevolution > 0 else { return }
        let now = nowNS()
        let revs = Double(ticks) / Double(ticksPerRevolution)

        lock.lock()
        recentRevs.append((now, abs(revs)))
        trimWindow(now: now)

        let v = velocityLocked(now: now) // rev/s
        let gain = min(cfg.maxGain, 1 + cfg.accel * pow(v, cfg.exponent))
        let pixels = revs * cfg.pixelsPerRevolution * gain

        // Direction reversal: dump leftover travel so the dial never
        // rubber-bands against buffered pixels from the old direction.
        if pendingPixels != 0, (pendingPixels < 0) != (pixels < 0) {
            pendingPixels = 0
        }
        pendingPixels += pixels
        lock.unlock()
    }

    func updateConfig(_ update: (inout Config) -> Void) {
        lock.lock()
        update(&cfg)
        let copy = cfg
        lock.unlock()
        copy.save()
    }

    var config: Config {
        lock.lock()
        defer { lock.unlock() }
        return cfg
    }

    // MARK: - Drain

    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let dl = link else { return }
        displayLink = dl
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, userInfo -> CVReturn in
            Unmanaged<ScrollEngine>.fromOpaque(userInfo!).takeUnretainedValue().drain()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
    }

    private func drain() {
        let now = nowNS()

        lock.lock()
        let dt = lastDrainNS == 0 ? 1.0 / 60 : min(0.05, Double(now - lastDrainNS) / 1e9)
        lastDrainNS = now
        trimWindow(now: now)

        var emit = 0
        if pendingPixels != 0 {
            // Exponential release: each frame emits a fixed fraction of what's
            // left, converging smoothly instead of stair-stepping.
            var portion = pendingPixels * (1 - exp(-dt / cfg.tau))
            if abs(pendingPixels) < 1.5 { portion = pendingPixels } // flush tail
            emit = Int(portion.rounded(.towardZero))
            // Keep the sub-pixel remainder in the pool: nothing is lost.
            pendingPixels -= Double(emit)
            if emit == 0, abs(pendingPixels) < 0.01 { pendingPixels = 0 }
        }
        lock.unlock()

        if emit != 0 {
            post(pixels: emit)
        }
    }

    private func post(pixels: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel,
                                  wheelCount: 1,
                                  wheel1: Int32(pixels),
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        // Present as a continuous (trackpad-style) stream so apps use their
        // smooth pixel-scrolling path.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pixels))
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Velocity

    private func trimWindow(now: UInt64) {
        let cutoff = now &- 150_000_000 // 150ms
        while let first = recentRevs.first, first.t < cutoff {
            recentRevs.removeFirst()
        }
    }

    private func velocityLocked(now _: UInt64) -> Double {
        let total = recentRevs.reduce(0) { $0 + $1.revs }
        return total / 0.15 // rev/s over the 150ms window
    }

    private func nowNS() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
