//
//  MidiOutput.swift
//  MacDial
//
//  Minimal CoreMIDI virtual source that sends CC messages.
//  Includes relative encoder pulses compatible with Traktor (7Fh/01h or 3Fh/41h).
//

import Foundation
import CoreMIDI

public final class MidiOutput {
    public enum RelMode {
        case sevenF_01   // increment = 0x01, decrement = 0x7F (Traktor “7Fh/01h”)
        case threeF_41   // increment = 0x41, decrement = 0x3F (Traktor “3Fh/41h”)
    }

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private let queue = DispatchQueue(label: "MacDial.MidiOutput")

    public let name: String

    public init?(name: String) {
        self.name = name
        guard MIDIClientCreate("\(name) Client" as CFString, nil, nil, &client) == noErr else { return nil }
        guard MIDISourceCreate(client, name as CFString, &source) == noErr else { return nil }
    }

    deinit {
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Absolute Control Change 0–127
    public func sendCC(channel: UInt8, controller: UInt8, value: UInt8) {
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        send(bytes: [status, controller, value])
    }

    /// Relative encoder pulses (map as Encoder/Relative in Traktor).
    public func sendRelativeCC(channel: UInt8, controller: UInt8, steps: Int, mode: RelMode = .sevenF_01) {
        guard steps != 0 else { return }
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        let (inc, dec): (UInt8, UInt8) = (mode == .sevenF_01) ? (0x01, 0x7F) : (0x41, 0x3F)
        let val = (steps > 0) ? inc : dec
        let count = abs(steps)

        queue.async {
            var packetList = MIDIPacketList()
            withUnsafeMutablePointer(to: &packetList) { plPtr in
                var pkt = MIDIPacketListInit(plPtr)
                for _ in 0..<count {
                    var msg: [UInt8] = [status, controller, val]
                    pkt = MIDIPacketListAdd(plPtr, 1024, pkt, 0, msg.count, &msg)
                }
                MIDIReceived(self.source, plPtr)
            }
        }
    }

    private func send(bytes: [UInt8]) {
        queue.async {
            var packetList = MIDIPacketList()
            withUnsafeMutablePointer(to: &packetList) { plPtr in
                var pkt = MIDIPacketListInit(plPtr)
                var b = bytes
                pkt = MIDIPacketListAdd(plPtr, 1024, pkt, 0, b.count, &b)
                MIDIReceived(self.source, plPtr)
            }
        }
    }
}
