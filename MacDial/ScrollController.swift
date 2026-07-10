import AppKit
import Foundation

/// Scroll mode. Rotation scrolls through the ScrollEngine; press-and-turn
/// adjusts volume instead; a press with no rotation clicks on release.
class ScrollController: Controller {
    private struct PressState {
        var pressed = false
        var rotated = false
        var volume = VolumeControl()
    }

    private var pressStates: [String: PressState] = [:]

    private func click() {
        let mousePos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let translatedMousePos = NSPoint(x: mousePos.x, y: screenHeight - mousePos.y)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil,
                                mouseType: type,
                                mouseCursorPosition: translatedMousePos,
                                mouseButton: .left)
            event?.post(tap: .cghidEventTap)
        }
    }

    func onDown(dial: Dial) {
        pressStates[dial.serialNumber] = PressState(pressed: true)
    }

    func onUp(dial: Dial) {
        let state = pressStates.removeValue(forKey: dial.serialNumber)
        // Click on release, but only if the press wasn't a press-and-turn.
        if state?.rotated != true {
            click()
        }
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction: Int) {
        if var state = pressStates[dial.serialNumber], state.pressed {
            // Press-and-turn: accelerated volume.
            state.rotated = true
            state.volume.rotate(ticks: rotation.ticks,
                                ticksPerRevolution: dial.wheelSensitivity)
            pressStates[dial.serialNumber] = state
            return
        }

        ScrollEngine.shared.ingest(ticks: rotation.ticks * direction,
                                   ticksPerRevolution: dial.wheelSensitivity)
    }
}
