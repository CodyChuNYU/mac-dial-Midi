import AppKit
import Foundation

class ScrollController: Controller {
    private enum MouseButton {
        case down
        case up
    }

    private func sendMouse(button: MouseButton) {
        let mousePos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let translatedMousePos = NSPoint(x: mousePos.x, y: screenHeight - mousePos.y)
        let event = CGEvent(mouseEventSource: nil,
                            mouseType: button == .down ? .leftMouseDown : .leftMouseUp,
                            mouseCursorPosition: translatedMousePos,
                            mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    func onDown(dial _: Dial) {
        sendMouse(button: .down)
    }

    func onUp(dial _: Dial) {
        sendMouse(button: .up)
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction: Int) {
        ScrollEngine.shared.ingest(ticks: rotation.ticks * direction,
                                   ticksPerRevolution: dial.wheelSensitivity)
    }
}
