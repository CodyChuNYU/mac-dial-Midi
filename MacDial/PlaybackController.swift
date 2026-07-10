import AppKit
import Foundation

/// https://stackoverflow.com/a/55854051
func HIDPostAuxKey(key: Int32, modifiers: [NSEvent.ModifierFlags], _repeat: Int = 1) {
    func doKey(down: Bool) {
        var rawFlags: UInt = (down ? 0xA00 : 0xB00)

        for modifier in modifiers {
            rawFlags |= modifier.rawValue
        }

        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)

        let data1 = Int((key << 16) | (down ? 0xA00 : 0xB00))

        let ev = NSEvent.otherEvent(with: NSEvent.EventType.systemDefined,
                                    location: NSPoint(x: 0, y: 0),
                                    modifierFlags: flags,
                                    timestamp: 0,
                                    windowNumber: 0,
                                    context: nil,
                                    subtype: 8,
                                    data1: data1,
                                    data2: -1)
        let cev = ev?.cgEvent
        cev?.post(tap: CGEventTapLocation.cghidEventTap)
    }
    for _ in 0 ..< _repeat {
        doKey(down: true)
        doKey(down: false)
    }
}

/// Shared volume-with-acceleration helper: ~36 quarter-steps per slow
/// revolution, ramping up to 4x when the dial is spun fast.
struct VolumeControl {
    private var accumulator = TickAccumulator()
    private var velocity = VelocityTracker()

    mutating func rotate(ticks: Int, ticksPerRevolution: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let v = velocity.record(revs: Double(ticks) / Double(ticksPerRevolution), at: now)
        let gain = ScrollMath.gain(velocity: v, accel: 2.0, exponent: 1.2, maxGain: 4)
        let steps = accumulator.steps(ticks: ticks, ticksPerRevolution: ticksPerRevolution, gain: gain)
        guard steps != 0 else { return }
        let key = steps > 0 ? NX_KEYTYPE_SOUND_UP : NX_KEYTYPE_SOUND_DOWN
        HIDPostAuxKey(key: key,
                      modifiers: [.shift, .option], // quarter-step volume
                      _repeat: abs(steps))
    }
}

/// Playback mode: rotate = volume (accelerated), press = play/pause,
/// double-press = next track, press-and-turn = skip tracks.
class PlaybackController: Controller {
    private struct PressState {
        var rotated = false
        var skip = TickAccumulator()
    }

    private var lastClick = Date().timeIntervalSince1970
    private var pressStates: [String: PressState] = [:]
    private var volume = VolumeControl()

    func onDown(dial: Dial) {
        pressStates[dial.serialNumber] = PressState()
    }

    func onUp(dial: Dial) {
        let state = pressStates.removeValue(forKey: dial.serialNumber)
        // Press-and-turn already skipped tracks; don't also play/pause.
        guard state?.rotated != true else { return }

        let clickDelay = Date().timeIntervalSince1970 - lastClick

        // Next song on double click
        if clickDelay < 0.5 {
            // Undo pause sent on first click
            HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)

            HIDPostAuxKey(key: NX_KEYTYPE_NEXT, modifiers: [])
        } else { // Play / Pause on single click
            HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)
        }

        lastClick = Date().timeIntervalSince1970
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction _: Int) {
        if var state = pressStates[dial.serialNumber] {
            // Press-and-turn: one track skip per 1/8 revolution (45°).
            state.rotated = true
            let steps = state.skip.steps(ticks: rotation.ticks,
                                         ticksPerRevolution: dial.wheelSensitivity,
                                         stepsPerRevolution: 8)
            pressStates[dial.serialNumber] = state
            if steps != 0 {
                let key = steps > 0 ? NX_KEYTYPE_NEXT : NX_KEYTYPE_PREVIOUS
                HIDPostAuxKey(key: key, modifiers: [], _repeat: abs(steps))
            }
            return
        }

        volume.rotate(ticks: rotation.ticks, ticksPerRevolution: dial.wheelSensitivity)
    }
}
