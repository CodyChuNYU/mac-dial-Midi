import AppKit
import Foundation

/// Scroll mode. Rotation scrolls through the ScrollEngine. Pressing summons
/// the ⌘Tab app switcher: turning while held clicks through apps (one felt
/// detent per app), releasing commits. A quick press-and-release therefore
/// toggles to the previous app.
class ScrollController: Controller {
    private struct PressState {
        var appCycle = TickAccumulator()
    }

    private var pressStates: [String: PressState] = [:]
    private let keySource = CGEventSource(stateID: .hidSystemState)

    private let tabKey: CGKeyCode = 48 // kVK_Tab
    private let commandKey: CGKeyCode = 55 // kVK_Command

    private func postKey(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: keySource, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// One ⌘Tab step; backward adds shift.
    private func switcherStep(forward: Bool) {
        let flags: CGEventFlags = forward ? .maskCommand : [.maskCommand, .maskShift]
        postKey(tabKey, down: true, flags: flags)
        postKey(tabKey, down: false, flags: flags)
    }

    func onDown(dial: Dial) {
        // Clicky detents while held: one felt click = one app in the switcher.
        dial.configure(sensitivity: 30, haptics: true)
        pressStates[dial.serialNumber] = PressState()
        // Summon the switcher: ⌘ goes down and STAYS down until release;
        // the first Tab selects the previous app, so a quick press is an
        // instant back-and-forth app toggle.
        postKey(commandKey, down: true, flags: .maskCommand)
        switcherStep(forward: true)
    }

    func onUp(dial: Dial) {
        // Restore the user's configured feel (global haptics setting).
        DialManager.shared.configureDial?(dial)
        pressStates.removeValue(forKey: dial.serialNumber)
        // Releasing ⌘ commits whatever the switcher has selected.
        postKey(commandKey, down: false, flags: [])
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction: Int) {
        if var state = pressStates[dial.serialNumber] {
            // Held: dial through the app switcher, one app per detent.
            let steps = state.appCycle.steps(ticks: rotation.ticks,
                                             ticksPerRevolution: dial.wheelSensitivity,
                                             stepsPerRevolution: 30)
            pressStates[dial.serialNumber] = state
            for _ in 0 ..< abs(steps) {
                switcherStep(forward: steps > 0)
            }
            return
        }

        ScrollEngine.shared.ingest(ticks: rotation.ticks * direction,
                                   ticksPerRevolution: dial.wheelSensitivity)
    }
}
