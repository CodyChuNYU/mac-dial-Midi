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
/// double-press = next track, press-and-turn = scrub through the song
/// (falls back to track skipping when no scriptable player is running).
class PlaybackController: Controller {
    private static let scrubSecondsPerRevolution = 60.0

    /// One press-and-turn session. Everything here runs on the main queue.
    private final class ScrubSession {
        var started = false
        var base: PlayerPosition? // nil after start = fall back to skipping
        var offset = 0.0
        var lastSend = 0.0
        var skip = TickAccumulator()
    }

    private var lastClick = Date().timeIntervalSince1970
    private var sessions: [String: ScrubSession] = [:] // by dial serial
    private var volume = VolumeControl()

    func onDown(dial: Dial) {
        let session = ScrubSession()
        DispatchQueue.main.async { [weak self] in
            self?.sessions[dial.serialNumber] = session
        }
    }

    func onUp(dial: Dial) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let session = self.sessions.removeValue(forKey: dial.serialNumber)

            if let session = session, session.started {
                // Press-and-turn: flush the final scrub position, no play/pause.
                if session.base != nil {
                    self.sendScrub(session, force: true)
                }
                return
            }

            let clickDelay = Date().timeIntervalSince1970 - self.lastClick

            // Next song on double click
            if clickDelay < 0.5 {
                // Undo pause sent on first click
                HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)

                HIDPostAuxKey(key: NX_KEYTYPE_NEXT, modifiers: [])
            } else { // Play / Pause on single click
                HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)
            }

            self.lastClick = Date().timeIntervalSince1970
        }
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction _: Int) {
        let ticks = rotation.ticks
        let ticksPerRev = dial.wheelSensitivity

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let session = self.sessions[dial.serialNumber] {
                self.scrub(session, ticks: ticks, ticksPerRevolution: ticksPerRev)
            } else {
                self.volume.rotate(ticks: ticks, ticksPerRevolution: ticksPerRev)
            }
        }
    }

    // MARK: - Scrubbing (main queue)

    private func scrub(_ session: ScrubSession, ticks: Int, ticksPerRevolution: Int) {
        if !session.started {
            session.started = true
            if MediaRemote.canSeek {
                session.base = queryPlayerPosition() // one AppleScript read per session
            }
        }

        guard session.base != nil else {
            // No scriptable player: skip tracks instead, 1/16 rev each.
            let steps = session.skip.steps(ticks: ticks,
                                           ticksPerRevolution: ticksPerRevolution,
                                           stepsPerRevolution: 16)
            if steps != 0 {
                let key = steps > 0 ? NX_KEYTYPE_NEXT : NX_KEYTYPE_PREVIOUS
                HIDPostAuxKey(key: key, modifiers: [], _repeat: abs(steps))
            }
            return
        }

        session.offset += Double(ticks) / Double(ticksPerRevolution) * Self.scrubSecondsPerRevolution
        sendScrub(session, force: false)
    }

    private func sendScrub(_ session: ScrubSession, force: Bool) {
        guard let base = session.base else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - session.lastSend > 0.1 else { return } // ~10Hz
        session.lastSend = now

        var target = base.position + session.offset
        let upperBound = (base.duration ?? .greatestFiniteMagnitude) - 1
        target = max(0, min(target, upperBound))
        MediaRemote.setElapsedTime(target)
    }
}
