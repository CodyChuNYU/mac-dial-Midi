import Foundation

/// MIDI mode. Each dial keeps a stable slot N (first-seen order, persisted
/// by serial), and every gesture gets its own mappable lane:
///  - rotate:      relative CC 16+N
///  - press:       note 60+N (on at press, off at release)
///  - hold ≥0.25s: note 72+N (on when the hold engages, off at release)
///  - hold + turn: relative CC 32+N
class MidiController: Controller {
    private static let slotsKey = "midi.slots"
    private static let holdSeconds = 0.25

    /// Marks the hold as engaged. `fired` is only touched on the main queue,
    /// so onUp's main-queue check is race-free.
    private final class HoldToken {
        var fired = false
        private(set) var item: DispatchWorkItem!

        init(action: @escaping () -> Void) {
            item = DispatchWorkItem { [weak self] in
                self?.fired = true
                action()
            }
        }
    }

    private var holds: [String: HoldToken] = [:] // HID thread only

    private static func slot(for serial: String) -> Int {
        var slots = UserDefaults.standard.dictionary(forKey: slotsKey) as? [String: Int] ?? [:]
        if let existing = slots[serial] { return existing }
        let next = (slots.values.max() ?? -1) + 1
        slots[serial] = next
        UserDefaults.standard.set(slots, forKey: slotsKey)
        return next
    }

    func onDown(dial: Dial) {
        let serial = dial.serialNumber
        let slot = Self.slot(for: serial)
        MIDIManager.shared.sendNote(serial: serial, channel: 0,
                                    note: UInt8(min(127, 60 + slot)), on: true)

        let token = HoldToken {
            MIDIManager.shared.sendNote(serial: serial, channel: 0,
                                        note: UInt8(min(127, 72 + slot)), on: true)
        }
        holds[serial] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: token.item)
    }

    func onUp(dial: Dial) {
        let serial = dial.serialNumber
        let slot = Self.slot(for: serial)
        MIDIManager.shared.sendNote(serial: serial, channel: 0,
                                    note: UInt8(min(127, 60 + slot)), on: false)

        guard let token = holds.removeValue(forKey: serial) else { return }
        token.item.cancel()
        DispatchQueue.main.async {
            if token.fired {
                MIDIManager.shared.sendNote(serial: serial, channel: 0,
                                            note: UInt8(min(127, 72 + slot)), on: false)
            }
        }
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction: Int) {
        let slot = Self.slot(for: dial.serialNumber)
        // Held rotation gets its own CC lane.
        let cc = holds[dial.serialNumber] != nil ? 32 + slot : 16 + slot
        MIDIManager.shared.sendRelativeCC(serial: dial.serialNumber, channel: 0,
                                          cc: UInt8(min(127, cc)),
                                          delta: rotation.ticks * direction)
    }
}
