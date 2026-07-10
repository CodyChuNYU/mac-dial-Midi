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

class PlaybackController: Controller {
    var lastClick = Date().timeIntervalSince1970
    private var volume = TickAccumulator()

    func onDown(dial _: Dial) {}

    func onUp(dial _: Dial) {
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
        // Normalize to ~36 volume steps per revolution at any hardware
        // resolution, so smooth mode doesn't change volume 10x faster.
        let steps = volume.steps(ticks: rotation.ticks,
                                 ticksPerRevolution: dial.wheelSensitivity)
        guard steps != 0 else { return }
        let key = steps > 0 ? NX_KEYTYPE_SOUND_UP : NX_KEYTYPE_SOUND_DOWN
        HIDPostAuxKey(key: key,
                      modifiers: [.shift, .option], // quarter-step volume
                      _repeat: abs(steps))
    }
}
