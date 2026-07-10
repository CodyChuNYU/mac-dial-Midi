import Foundation

/// MIDI mode: rotation sends a relative CC, press sends a note.
/// Each dial keeps a stable slot (first-seen order, persisted by serial), so
/// dial N is always CC 16+N / note 60+N across reconnects and restarts.
class MidiController: Controller {
    private static let slotsKey = "midi.slots"

    private static func slot(for serial: String) -> Int {
        var slots = UserDefaults.standard.dictionary(forKey: slotsKey) as? [String: Int] ?? [:]
        if let existing = slots[serial] { return existing }
        let next = (slots.values.max() ?? -1) + 1
        slots[serial] = next
        UserDefaults.standard.set(slots, forKey: slotsKey)
        return next
    }

    func onDown(dial: Dial) {
        let slot = Self.slot(for: dial.serialNumber)
        MIDIManager.shared.sendNote(serial: dial.serialNumber, channel: 0,
                                    note: UInt8(min(127, 60 + slot)), on: true)
    }

    func onUp(dial: Dial) {
        let slot = Self.slot(for: dial.serialNumber)
        MIDIManager.shared.sendNote(serial: dial.serialNumber, channel: 0,
                                    note: UInt8(min(127, 60 + slot)), on: false)
    }

    func onRotate(dial: Dial, rotation: Dial.Rotation, direction: Int) {
        let slot = Self.slot(for: dial.serialNumber)
        MIDIManager.shared.sendRelativeCC(serial: dial.serialNumber, channel: 0,
                                          cc: UInt8(min(127, 16 + slot)),
                                          delta: rotation.ticks * direction)
    }
}
