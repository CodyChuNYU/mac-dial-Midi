import Foundation
import AppKit

// MARK: - Phaseful "trackpad-like" scroll event emission
// Emits CGEvent scrolls with phases (began/changed/ended) and point/fixed-point deltas.
enum TrackpadScroll {
    private static var streaming = false
    private static var endTimer: DispatchSourceTimer?
    private static let endDelay: TimeInterval = 0.020  // shorter = better chaining of micro-bursts

    static func post(delta: Int) {
        guard delta != 0 else { return }
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }

        let phase: CGScrollPhase = streaming ? .changed : .began
        streaming = true

        if let ev = CGEvent(scrollWheelEvent2Source: src,
                            units: .pixel,
                            wheelCount: 1,
                            wheel1: Int32(delta),
                            wheel2: 0,
                            wheel3: 0) {
            ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
            ev.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(delta) << 16)
            ev.post(tap: .cghidEventTap)
        }

        scheduleEnd()
    }

    private static func scheduleEnd() {
        endTimer?.cancel()
        let q = DispatchQueue(label: "TrackpadScroll.end")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + endDelay)
        t.setEventHandler {
            guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
            if let endEv = CGEvent(scrollWheelEvent2Source: src,
                                   units: .pixel,
                                   wheelCount: 1,
                                   wheel1: 0, wheel2: 0, wheel3: 0) {
                endEv.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                endEv.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
                endEv.post(tap: .cghidEventTap)
            }
            streaming = false
        }
        t.resume()
        endTimer = t
    }

    static func endNow() {
        endTimer?.cancel()
        guard streaming else { return }
        if let src = CGEventSource(stateID: .combinedSessionState),
           let endEv = CGEvent(scrollWheelEvent2Source: src,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: 0, wheel2: 0, wheel3: 0) {
            endEv.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            endEv.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
            endEv.post(tap: .cghidEventTap)
        }
        streaming = false
    }
}

// MARK: - High-rate scroller (locked cadence)
// Accumulates "pixels" (can be fractional) and emits tiny deltas at a fixed frame rate.
// Simplified to direct accumulation and emission without FIR micro-envelope smoothing.
final class TouchpadLikeScroller {
    static let shared = TouchpadLikeScroller()

    // Locked cadence: keep this <= your display refresh multiple; 240 Hz feels trackpad-grade.
    private let hz: Double = 240.0  // locked cadence
    // Fraction of the bucket emitted per tick (0<easing<=1). Higher = snappier, lower = syrupy.
    private let easing: Double = 0.38  // snappier output

    private var bucket: Double = 0.0   // accumulated "pixels to send" (fractional allowed)
    private var carry: Double = 0.0    // fractional remainder carried across ticks

    private var timer: DispatchSourceTimer?
    private var enabled: Bool = true

    private init() {
        let q = DispatchQueue(label: "MacDial.TouchpadLikeScroller", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000.0 / hz))
        t.schedule(deadline: .now() + .milliseconds(10), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func setEnabled(_ on: Bool) {
        if enabled == on { return }
        enabled = on
        if !on {
            bucket = 0
            carry = 0
            TrackpadScroll.endNow()
        }
    }

    /// Feed pixels (can be fractional). Positive = up; negative = down.
    func addImpulse(pixels: Double) {
        guard enabled, pixels != 0 else { return }
        bucket += pixels
    }

    private func tick() {
        guard enabled else { return }

        // Ease out some bucket to smooth emission
        let out = bucket * easing

        // Convert fractional to integer pixels to actually emit.
        var total = carry + out
        let send: Int = (total > 0) ? Int(floor(total)) : Int(ceil(total))
        total -= Double(send)
        carry = total

        // Subtract emitted amount from bucket
        bucket -= out

        if send != 0 {
            TrackpadScroll.post(delta: send)
        }
    }
}

// MARK: - Encoder Scroll Engine (acceleration-aware)
// Uses both EMA speed and jerk with hysteresis to distinguish slow/fine vs fast/accelerated.
private final class EncoderScrollEngine {
    struct Tuning {
        let basePxPerDetent: Double = 1.0

        // EMA alphas
        let speedAlpha: Double = 0.65
        let jerkAlpha: Double  = 0.50

        // Thresholds for hysteresis
        let speedFastOn: Double  = 12.0
        let speedFastOff: Double = 8.0
        let jerkOn: Double       = 50.0
        let jerkOff: Double      = 25.0

        // Gain caps
        let fineMaxGain: Double  = 2.0
        let fastMaxGain: Double  = 14.0
    }

    private enum Mode { case fine, fast }

    private var t = Tuning()
    private var mode: Mode = .fine
    private var speedEMA: Double = 0.0
    private var jerkEMA: Double  = 0.0
    private var lastTime: TimeInterval = Date().timeIntervalSince1970
    private var lastSpeed: Double = 0.0

    private func gain(for speed: Double) -> Double {
        switch mode {
        case .fine:
            let g = max(1.0, min(t.fineMaxGain, 1.0 + 0.08*speed))
            return g
        case .fast:
            var g = 1.0 + 0.12*speed + 0.0035*speed*speed
            if g < 1.0 { g = 1.0 }
            if g > t.fastMaxGain { g = t.fastMaxGain }
            return g
        }
    }

    func feed(detents: Int, direction: Int) -> Double {
        guard detents != 0 else { return 0 }
        let dir = (direction == 0) ? 1 : direction
        let signedSteps = Double(detents * dir)

        let now = Date().timeIntervalSince1970
        let dt  = max(now - lastTime, 0.001)

        let instSpeed = abs(signedSteps) / dt
        let instJerk  = (instSpeed - lastSpeed) / dt

        speedEMA = t.speedAlpha * instSpeed + (1 - t.speedAlpha) * speedEMA
        jerkEMA  = t.jerkAlpha  * instJerk  + (1 - t.jerkAlpha)  * jerkEMA

        switch mode {
        case .fine:
            if speedEMA >= t.speedFastOn || abs(jerkEMA) >= t.jerkOn {
                mode = .fast
            }
        case .fast:
            if speedEMA <= t.speedFastOff && abs(jerkEMA) <= t.jerkOff {
                mode = .fine
            }
        }

        let g = gain(for: speedEMA)
        let pixels = signedSteps * t.basePxPerDetent * g

        lastTime = now
        lastSpeed = instSpeed
        return pixels
    }
}

// MARK: - ScrollController (Controller-conforming)
class ScrollController: Controller {
    enum Direction { case up, down }

    private func sendMouse(button direction: Direction) {
        let mousePos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let translated = NSPoint(x: mousePos.x, y: screenHeight - mousePos.y)
        let type: CGEventType = (direction == .down) ? .leftMouseDown : .leftMouseUp
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: translated, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func onDown() { sendMouse(button: .down) }
    func onUp()   { sendMouse(button: .up)   }

    private let engine = EncoderScrollEngine()

    func onRotate(_ rotation: Dial.Rotation,_ scrollDirection: Int) {
        let steps: Int
        switch rotation {
        case .Clockwise(let d):        steps = d
        case .CounterClockwise(let d): steps = -d
        }
        guard steps != 0 else { return }

        // Convert detents → pixels via fast EMA-based engine (monotonic acceleration)
        let impulsePx = engine.feed(detents: steps, direction: scrollDirection)

        // Stream out at locked cadence with phaseful events
        TouchpadLikeScroller.shared.addImpulse(pixels: impulsePx)
    }
}
