import Foundation
import AppKit

// https://stackoverflow.com/a/55854051
func HIDPostAuxKey(key: Int32, modifiers: [NSEvent.ModifierFlags], _repeat: Int = 1) {
    func doKey(down: Bool) {
        
        var rawFlags: UInt = (down ? 0xa00 : 0xb00);
        
        for modifier in modifiers {
            rawFlags |= modifier.rawValue
        }
        
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        
        let data1 = Int((key<<16) | (down ? 0xa00 : 0xb00))

        let ev = NSEvent.otherEvent(with: NSEvent.EventType.systemDefined,
                                    location: NSPoint(x:0,y:0),
                                    modifierFlags: flags,
                                    timestamp: 0,
                                    windowNumber: 0,
                                    context: nil,
                                    subtype: 8,
                                    data1: data1,
                                    data2: -1
                                    )
        let cev = ev?.cgEvent
        cev?.post(tap: CGEventTapLocation.cghidEventTap)
    }
    for _ in 0..<_repeat {
        doKey(down: true)
        doKey(down: false)
    }

}


class PlaybackController : Controller {
    
    var lastClick = Date().timeIntervalSince1970
    
    func onDown() {
        
    }
    
    func onUp() {
        
        let clickDelay = Date().timeIntervalSince1970 - lastClick
        
        // Next song on double click
        if (clickDelay < 0.5) {
            // Undo pause sent on first click
            HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)
            
            HIDPostAuxKey(key: NX_KEYTYPE_NEXT, modifiers: [])
        }
        else { // Play / Pause on single click
            
            HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)
        }
        
        lastClick = Date().timeIntervalSince1970
    }
    
    
    
    func onRotate(_ rotation: Dial.Rotation,_ scrollDirection: Int) {
        var detents = 0
        switch rotation {
        case .Clockwise(let d):        detents = d
        case .CounterClockwise(let d): detents = -d
        }
        // Defensive: if scrollDirection isn't initialized yet, treat as +1
        let dir = (scrollDirection == 0) ? 1 : scrollDirection
        detents *= dir

        // Volume control with quarter‑step precision + acceleration
        VolumeDial.shared.onDialDetents(detents)
    }
    
    
}

fileprivate final class ScrollSmoother {
    static let shared = ScrollSmoother()

    // Tuning knobs:
    // Smaller = finer per detent; increase if it feels too slow.
    private let pixelsPerDetent: Double = 32.0
    // Fraction of the accumulator emitted per tick. 0.15–0.35 is a good range.
    private let easing: Double = 0.25
    // Timer frequency (Hz). 60–240 are typical; higher = smoother but more events.
    private let hz: Double = 120.0

    private var accumulator: Double = 0.0
    private var timer: DispatchSourceTimer?

    private init() {
        let q = DispatchQueue(label: "ScrollSmoother.timer", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000.0 / hz))
        t.schedule(deadline: .now() + .milliseconds(10), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Feed dial detents (+/-), typically ±1 per click.
    func onDialDetents(_ detents: Int) {
        guard detents != 0 else { return }
        accumulator += Double(detents) * pixelsPerDetent
    }

    private func tick() {
        // Emit a fraction of the accumulator (simple exponential smoothing).
        let out = accumulator * easing
        if abs(out) < 0.5 { return } // deadzone; let it build up
        accumulator -= out
        let px = Int(out.rounded())
        postPixelScroll(px)
    }

    private func postPixelScroll(_ delta: Int) {
        guard delta != 0 else { return }
        if let src = CGEventSource(stateID: .combinedSessionState),
           let ev  = CGEvent(scrollWheelEvent2Source: src,
                             units: .pixel,
                             wheelCount: 1,
                             wheel1: Int32(delta),
                             wheel2: 0,
                             wheel3: 0) {
            ev.post(tap: .cghidEventTap)
        }
    }
}

fileprivate final class VolumeDial {
    static let shared = VolumeDial()

    // Tuning:
    // Base quarter-steps per detent when moving slowly (Opt+Shift yields 1/4 step per event).
    private let baseQuarterPerDetent: Double = 1.0
    // Gain for acceleration as spin speed increases.
    private let accelGain: Double = 0.75
    // Cap the aggressiveness to keep control predictable.
    private let maxQuarterPerDetent: Double = 12.0 // up to 3 full steps per detent
    // Timer cadence for emitting key events.
    private let hz: Double = 240.0
    // Momentum decay per tick (0.90–0.98 recommended).
    private let momentumDecay: Double = 0.92
    // Prevent huge bursts in a single tick.
    private let maxBurstPerTick: Int = 24

    private var accumulator: Double = 0.0      // in quarter-steps; signed
    private var momentum: Double = 0.0         // dimensionless; grows with spin intensity
    private var timer: DispatchSourceTimer?

    private init() {
        let q = DispatchQueue(label: "VolumeDial.timer", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000.0 / hz))
        t.schedule(deadline: .now() + .milliseconds(5), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Feed dial detents (+/-). Positive increases volume, negative decreases.
    func onDialDetents(_ detents: Int) {
        guard detents != 0 else { return }
        let absd = abs(detents)

        // Build momentum proportional to input intensity; clamp for stability.
        // Momentum boosts the quarter-steps per detent to keep fast spins snappy.
        momentum = min(8.0, momentum + Double(absd))

        // Compute effective quarter-steps per detent with acceleration, clamped.
        let qPerDetent = min(maxQuarterPerDetent,
                             baseQuarterPerDetent + momentum * accelGain)

        accumulator += Double(detents) * qPerDetent
    }

    private func tick() {
        // Soften momentum over time to return to fine control quickly.
        momentum *= momentumDecay

        // Emit up to an integer number of quarter-steps this tick.
        var toEmit = Int(accumulator.rounded(.towardZero))
        if toEmit == 0 { return }

        // Rate-limit per tick to avoid overwhelming the system event queue.
        if abs(toEmit) > maxBurstPerTick {
            toEmit = maxBurstPerTick * (toEmit > 0 ? 1 : -1)
        }

        accumulator -= Double(toEmit)
        postQuarterSteps(toEmit)
    }

    private func postQuarterSteps(_ qs: Int) {
        guard qs != 0 else { return }
        let key: Int32 = (qs > 0) ? NX_KEYTYPE_SOUND_UP : NX_KEYTYPE_SOUND_DOWN
        let reps = abs(qs)

        // Use Option+Shift for 1/4-step precision; acceleration is achieved by higher repeat counts.
        HIDPostAuxKey(key: key, modifiers: [.shift, .option], _repeat: reps)
    }
}
