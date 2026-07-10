import CoreMIDI
import Foundation

/// Publishes one virtual MIDI source per dial so DAWs see each Surface Dial
/// as its own controller.
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
        MIDISourceCreate(client, "Surface Dial \(suffix)" as CFString, &endpoint)
        endpoints[serial] = endpoint
        return endpoint
    }

    private func send(serial: String, bytes: (UInt8, UInt8, UInt8)) {
        let source = endpoint(for: serial)
        var packet = MIDIPacket()
        packet.timeStamp = 0
        packet.length = 3
        packet.data.0 = bytes.0
        packet.data.1 = bytes.1
        packet.data.2 = bytes.2
        var list = MIDIPacketList(numPackets: 1, packet: packet)
        MIDIReceived(source, &list)
    }

    /// Relative CC, two's-complement encoding (1..63 = up, 127..65 = down).
    func sendRelativeCC(serial: String, channel: UInt8, cc: UInt8, delta: Int) {
        guard delta != 0 else { return }
        let value: UInt8 = delta > 0
            ? UInt8(min(63, delta))
            : UInt8(128 + max(-64, delta))
        send(serial: serial, bytes: (0xB0 | (channel & 0x0F), cc & 0x7F, value))
    }

    func sendNote(serial: String, channel: UInt8, note: UInt8, on: Bool) {
        let status: UInt8 = (on ? 0x90 : 0x80) | (channel & 0x0F)
        send(serial: serial, bytes: (status, note & 0x7F, on ? 127 : 0))
    }
}
