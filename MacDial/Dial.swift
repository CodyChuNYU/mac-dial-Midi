import Foundation
import IOKit.hid
import os

let hidLog = Logger(subsystem: "com.codychu.MacDial", category: "hid")

/// One physical Surface Dial, wrapping a seized IOHIDDevice.
/// Input reports arrive on the DialManager's HID runloop thread; callbacks
/// fire on that thread.
final class Dial {
    static let vendorId = 0x045E
    static let productId = 0x091B

    enum ButtonState {
        case pressed
        case released
    }

    enum Rotation {
        case Clockwise(Int)
        case CounterClockwise(Int)

        var ticks: Int {
            switch self {
            case let .Clockwise(d): return d
            case let .CounterClockwise(d): return -d
            }
        }
    }

    let device: IOHIDDevice
    let serialNumber: String

    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var lastButtonState = ButtonState.released
    private var isOpen = false

    var onButtonStateChanged: ((Dial, ButtonState) -> Void)?
    var onRotation: ((Dial, Rotation) -> Void)?

    /// Feature/output reports are synchronous BLE round-trips; sending them
    /// from the input-report thread stalls rotation delivery, so they go
    /// through this serial queue instead.
    private let reportQueue = DispatchQueue(label: "dial.reports", qos: .userInteractive)

    private var _wheelSensitivity = 36
    private var _haptics = false

    /// Steps per full revolution reported by the hardware (18...3600).
    var wheelSensitivity: Int {
        get { _wheelSensitivity }
        set { configure(sensitivity: newValue, haptics: _haptics) }
    }

    var haptics: Bool {
        get { _haptics }
        set { configure(sensitivity: _wheelSensitivity, haptics: newValue) }
    }

    /// Sets both knobs with a single feature report (one BLE round-trip).
    func configure(sensitivity: Int, haptics: Bool) {
        _wheelSensitivity = sensitivity
        _haptics = haptics
        reportQueue.async { [weak self] in
            self?.sendSensitivityReport(steps: sensitivity, haptics: haptics)
        }
    }

    init?(device: IOHIDDevice) {
        self.device = device
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? "unknown"
        serialNumber = serial

        // Seize so macOS stops interpreting dial input as bogus mouse events.
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            hidLog.error("IOHIDDeviceOpen failed for \(serial, privacy: .public): \(result)")
            reportBuffer.deallocate()
            return nil
        }
        isOpen = true

        IOHIDDeviceRegisterInputReportCallback(
            device, reportBuffer, 64,
            { context, _, _, _, _, report, reportLength in
                let dial = Unmanaged<Dial>.fromOpaque(context!).takeUnretainedValue()
                dial.handleReport(report, count: reportLength)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        close()
        reportBuffer.deallocate()
    }

    func close() {
        guard isOpen else { return }
        reportQueue.sync {} // flush queued reports (e.g. the shutdown restore)
        isOpen = false
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    }

    // MARK: - Reports

    /// https://github.com/daniel5151/surface-dial-linux/blob/main/src/dial_device/haptics.rs
    private func sendSensitivityReport(steps: Int, haptics: Bool) {
        var buf: [UInt8] = [
            0x01, // Report ID
            UInt8(steps & 0xFF), // steps lo
            UInt8((steps >> 8) & 0xFF), // steps hi
            0x00, // repeat count
            haptics ? 0x03 : 0x02, // auto trigger
            0x00, // waveform cutoff time
            0x00, 0x00, // retrigger period
        ]
        setReport(type: kIOHIDReportTypeFeature, data: &buf)
    }

    func impact(repeatCount: UInt8 = 0) {
        reportQueue.async { [weak self] in
            var buf: [UInt8] = [0x01, repeatCount, 0x03, 0x00, 0x00]
            self?.setReport(type: kIOHIDReportTypeOutput, data: &buf)
        }
    }

    private func setReport(type: IOHIDReportType, data: inout [UInt8]) {
        guard isOpen else { return }
        // Numbered report: buffer includes the ID byte, ID passed separately.
        IOHIDDeviceSetReport(device, type, CFIndex(data[0]), data, data.count)
    }

    private func handleReport(_ bytes: UnsafePointer<UInt8>, count: CFIndex) {
        guard count >= 3, bytes[0] == 1 else { return }

        let buttonState: ButtonState = bytes[1] & 1 == 1 ? .pressed : .released
        if buttonState != lastButtonState {
            lastButtonState = buttonState
            onButtonStateChanged?(self, buttonState)
        }

        // Signed delta; several detents can coalesce into one report at
        // high sensitivity, so this is not always ±1.
        let delta = Int(Int8(bitPattern: bytes[2]))
        if delta != 0 {
            let rotation: Rotation = delta < 0 ? .CounterClockwise(-delta) : .Clockwise(delta)
            onRotation?(self, rotation)
        }
    }
}
