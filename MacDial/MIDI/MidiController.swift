//
//  MidiController.swift
//  MacDial
//
//  Minimal controller that turns dial detents into relative CC pulses.
//

import Foundation

/// Sends relative CC on dial rotation.
/// Defaults: Channel 1 (0), CC 16, Traktor 7Fh/01h mode.
final class MidiController: Controller {
    private let midi: MidiOutput?
    private let channel: UInt8 = 0    // 0 = MIDI ch 1
    private let cc: UInt8 = 16
    private let mode: MidiOutput.RelMode = .sevenF_01

    init(portName: String = "Mac Dial A") {
        self.midi = MidiOutput(name: portName)
    }

    func onDown() { /* add press actions if you want */ }
    func onUp()   { /* no-op */ }

    func onRotate(_ rotation: Dial.Rotation,_ scrollDirection: Int) {
        guard let midi = midi else { return }
        let steps: Int
        switch rotation {
        case .Clockwise(let d):        steps = d
        case .CounterClockwise(let d): steps = -d
        }
        midi.sendRelativeCC(channel: channel, controller: cc, steps: steps, mode: mode)
    }
}
