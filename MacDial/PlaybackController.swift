import AppKit
import CoreAudio
import Foundation

/// Dedicated players, preferred over e.g. a browser that also makes noise.
private let knownPlayerBundles = ["com.apple.Music", "com.spotify.client"]

/// The user-facing app currently producing audio output, found via
/// CoreAudio's process objects (public API, no permissions needed).
/// Catches anything — Music, Spotify, YouTube in a browser.
func audiblyPlayingApp() -> NSRunningApplication? {
    var listAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &listAddr, 0, nil, &size) == noErr, size > 0 else { return nil }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &listAddr, 0, nil, &size, &objects) == noErr else { return nil }

    func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &valueSize, &value) == noErr else { return nil }
        return value
    }

    var audible: [NSRunningApplication] = []
    for object in objects {
        guard property(object, kAudioProcessPropertyIsRunningOutput) == 1,
              let pid = property(object, kAudioProcessPropertyPID),
              let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
        audible.append(app)
    }
    return audible.first { knownPlayerBundles.contains($0.bundleIdentifier ?? "") } ?? audible.first
}

/// Fallback when nothing is audible (e.g. already paused): a running
/// dedicated player app.
func runningKnownPlayer() -> NSRunningApplication? {
    for bundle in knownPlayerBundles {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            return app
        }
    }
    return nil
}

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
/// double-press = focus the app that's playing, press-and-turn = skip tracks.
class PlaybackController: Controller {
    private struct PressState {
        var rotated = false
        var skip = TickAccumulator()
    }

    private var lastClick = Date().timeIntervalSince1970
    private var pressStates: [String: PressState] = [:]
    private var volume = VolumeControl()
    private var lastAudibleApp: NSRunningApplication? // main queue only

    func onDown(dial: Dial) {
        pressStates[dial.serialNumber] = PressState()
    }

    func onUp(dial: Dial) {
        let state = pressStates.removeValue(forKey: dial.serialNumber)
        // Press-and-turn already skipped tracks; don't also play/pause.
        guard state?.rotated != true else { return }

        let clickDelay = Date().timeIntervalSince1970 - lastClick
        lastClick = Date().timeIntervalSince1970

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if clickDelay < 0.5 { // Double click: focus the playing app
                // Undo pause sent on first click
                HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)
                let app = self.lastAudibleApp ?? audiblyPlayingApp() ?? runningKnownPlayer()
                app?.activate()
            } else { // Play / Pause on single click
                // Snapshot who's audible before the pause silences them, so a
                // second click knows where to go.
                self.lastAudibleApp = audiblyPlayingApp()
                HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)
            }
        }
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction _: Int) {
        if var state = pressStates[dial.serialNumber] {
            // Press-and-turn: one track skip per 1/32 revolution (11.25°).
            state.rotated = true
            let steps = state.skip.steps(ticks: rotation.ticks,
                                         ticksPerRevolution: dial.wheelSensitivity,
                                         stepsPerRevolution: 32)
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
