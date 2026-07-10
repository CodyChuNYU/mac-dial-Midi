import CoreMIDI
import Foundation

/// Publishes one virtual MIDI source per dial so DAWs see each Surface Dial
/// as its own controller. Uses the modern MIDIEventList (UMP) API.
final class MIDIManager {
    static let shared = MIDIManager()

    private var client = MIDIClientRef()
    private var endpoints: [String: MIDIEndpointRef] = [:] // serial -> source
    private let lock = NSLock()

    private init() {
        MIDIClientCreate("MacDial" as CFString, nil, nil, &client)
    }

    deinit {
        for endpoint in endpoints.values {
            MIDIEndpointDispose(endpoint)
        }
        MIDIClientDispose(client)
    }

    private func endpoint(for serial: String) -> MIDIEndpointRef {
        lock.lock()
        defer { lock.unlock() }
        if let existing = endpoints[serial] { return existing }
        var endpoint = MIDIEndpointRef()
        let suffix = String(serial.suffix(4))
        MIDISourceCreateWithProtocol(client, "Surface Dial \(suffix)" as CFString, ._1_0, &endpoint)
        endpoints[serial] = endpoint
        return endpoint
    }

    private func send(serial: String, status: UInt8, data1: UInt8, data2: UInt8) {
        let source = endpoint(for: serial)
        // UMP MIDI 1.0 channel voice message (message type 2, group 0).
        let word: UInt32 = (0x2 << 28) | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, [word])
        MIDIReceivedEventList(source, &list)
    }

    /// Relative CC, two's-complement encoding (1..63 = up, 127..65 = down).
    func sendRelativeCC(serial: String, channel: UInt8, cc: UInt8, delta: Int) {
        guard delta != 0 else { return }
        let value: UInt8 = delta > 0
            ? UInt8(min(63, delta))
            : UInt8(128 + max(-64, delta))
        send(serial: serial, status: 0xB0 | (channel & 0x0F), data1: cc & 0x7F, data2: value)
    }

    func sendNote(serial: String, channel: UInt8, note: UInt8, on: Bool) {
        let status: UInt8 = (on ? 0x90 : 0x80) | (channel & 0x0F)
        send(serial: serial, status: status, data1: note & 0x7F, data2: on ? 127 : 0)
    }
}
