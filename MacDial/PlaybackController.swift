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

/// Finds Control Center's Now Playing menu extra via the Accessibility API
/// (covered by the permission the app already holds for posting events).
/// Main thread only. Pressing the returned element toggles the panel.
func nowPlayingMenuExtra() -> AXUIElement? {
    guard let cc = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
    else { return nil }

    let app = AXUIElementCreateApplication(cc.processIdentifier)
    var barRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barRef) == .success,
          let bar = barRef,
          CFGetTypeID(bar) == AXUIElementGetTypeID()
    else {
        hidLog.error("Now Playing: couldn't read Control Center menu extras")
        return nil
    }

    var kidsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(bar as! AXUIElement, "AXChildren" as CFString, &kidsRef) == .success,
          let items = kidsRef as? [AXUIElement]
    else { return nil }

    for item in items {
        var identRef: CFTypeRef?
        AXUIElementCopyAttributeValue(item, "AXIdentifier" as CFString, &identRef)
        if let ident = identRef as? String, ident == "com.apple.menuextra.now-playing" {
            return item
        }
    }
    // Panel only exists while something is (recently) playing.
    hidLog.info("Now Playing menu extra not present")
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
    /// Fires the peek while the dial is still held, caching the menu extra so
    /// the close on release is a single AXPress with no tree walk. `fired`
    /// and `panelItem` are only touched on the main queue, so onUp's
    /// main-queue check is race-free.
    private final class LongPressToken {
        var fired = false
        var panelItem: AXUIElement?
        private(set) var item: DispatchWorkItem!

        init() {
            item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.fired = true
                let t0 = ProcessInfo.processInfo.systemUptime
                self.panelItem = nowPlayingMenuExtra()
                let t1 = ProcessInfo.processInfo.systemUptime
                hidLog.info("peek: find took \(Int((t1 - t0) * 1000))ms, found=\(self.panelItem != nil)")
                if let panelItem = self.panelItem {
                    let err = AXUIElementPerformAction(panelItem, "AXPress" as CFString)
                    let t2 = ProcessInfo.processInfo.systemUptime
                    hidLog.info("peek: open press err=\(err.rawValue) took \(Int((t2 - t1) * 1000))ms")
                }
            }
        }
    }

    private struct PressState {
        var rotated = false
        var skip = TickAccumulator()
        let longPress: LongPressToken
    }

    /// Just past a casual click (~0.1-0.2s), so peek feels instant without
    /// eating play/pause presses.
    private static let longPressSeconds = 0.25

    /// How long a single click waits for a possible second click. Play/pause
    /// fires only after this window, so a double click never pauses playback.
    private static let doubleClickSeconds = 0.35

    private var pressStates: [String: PressState] = [:]
    private var volume = VolumeControl()
    private var lastAudibleApp: NSRunningApplication? // main queue only
    private var pendingSingleClick: DispatchWorkItem? // main queue only
    private var isSecondClick = false // main queue only

    func onDown(dial: Dial) {
        // While held, force coarse clicky detents so each song skip is a felt
        // tick — regardless of the global haptics setting. 30 detents/rev
        // (12° per click) — one felt click is exactly one song.
        dial.configure(sensitivity: 30, haptics: true)
        // Long press (no rotation): expand the menu bar Now Playing panel,
        // as soon as the threshold passes — no release needed.
        let token = LongPressToken()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressSeconds, execute: token.item)
        pressStates[dial.serialNumber] = PressState(longPress: token)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // A press landing inside the single-click window makes this a
            // double click: cancel the pending play/pause so playback is
            // never touched.
            if let pending = self.pendingSingleClick {
                pending.cancel()
                self.pendingSingleClick = nil
                self.isSecondClick = true
            } else {
                self.isSecondClick = false
            }
        }
    }

    func onUp(dial: Dial) {
        // Restore the user's configured feel (global haptics setting).
        DialManager.shared.configureDial?(dial)

        guard let state = pressStates.removeValue(forKey: dial.serialNumber) else { return }
        // Released before the long-press timer: cancel it. (No-op if it
        // already fired; the main-queue block below sees `fired` and bails.)
        state.longPress.item.cancel()

        let rotated = state.rotated

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Long press opened the Now Playing panel: releasing ALWAYS
            // closes it — even if the dial was turned during the peek (a
            // detent jiggle on release must not strand the panel open).
            let token = state.longPress
            if token.fired {
                self.isSecondClick = false
                if let panelItem = token.panelItem {
                    let t0 = ProcessInfo.processInfo.systemUptime
                    let err = AXUIElementPerformAction(panelItem, "AXPress" as CFString)
                    let t1 = ProcessInfo.processInfo.systemUptime
                    hidLog.info("peek: close press err=\(err.rawValue) took \(Int((t1 - t0) * 1000))ms")
                }
                return
            }
            // Press-and-turn already skipped tracks; don't also play/pause.
            if rotated {
                self.isSecondClick = false
                return
            }

            if self.isSecondClick { // Double click: focus the playing app
                self.isSecondClick = false
                let app = self.lastAudibleApp ?? audiblyPlayingApp() ?? runningKnownPlayer()
                app?.activate()
            } else {
                // Snapshot who's audible while sound is still playing, then
                // play/pause once the double-click window passes.
                self.lastAudibleApp = audiblyPlayingApp()
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingSingleClick = nil
                    HIDPostAuxKey(key: NX_KEYTYPE_PLAY, modifiers: [], _repeat: 1)
                }
                self.pendingSingleClick = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleClickSeconds, execute: work)
            }
        }
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction _: Int) {
        if var state = pressStates[dial.serialNumber] {
            // Press-and-turn: the hold runs the dial at 30 haptic detents/rev
            // and one skip per detent, so every physical click you feel is
            // exactly one song.
            state.rotated = true
            state.longPress.item.cancel() // turning means skip, not Now Playing
            let steps = state.skip.steps(ticks: rotation.ticks,
                                         ticksPerRevolution: dial.wheelSensitivity,
                                         stepsPerRevolution: 30)
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
