import Foundation

extension NSString {
    convenience init(wcharArray: UnsafeMutablePointer<wchar_t>) {
        self.init(bytes: UnsafePointer(wcharArray),
                  length: wcslen(wcharArray) * MemoryLayout<wchar_t>.stride,
                  encoding: String.Encoding.utf32LittleEndian.rawValue)!
    }
}

/// One physical Surface Dial, opened by HID path. Reading happens on a
/// dedicated thread; callbacks fire on that thread.
class Dial {
    static let VendorId: UInt16 = 0x045E
    static let ProductId: UInt16 = 0x091B

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

    private enum InputReport {
        case dial(ButtonState, Rotation?)
        case unknown
        case timeout
    }

    let path: String
    let serialNumber: String

    private var dev: OpaquePointer?
    private var thread: Thread?
    private var running = false
    private let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var lastButtonState = ButtonState.released

    var onButtonStateChanged: ((Dial, ButtonState) -> Void)?
    var onRotation: ((Dial, Rotation) -> Void)?
    var onDisconnected: ((Dial) -> Void)?

    /// Steps per full revolution reported by the hardware (18...3600).
    var wheelSensitivity: Int = 36 {
        didSet { updateSensitivity() }
    }

    var haptics: Bool = false {
        didSet { updateSensitivity() }
    }

    init?(path: String) {
        guard let dev = hid_open_path(path) else { return nil }
        self.dev = dev
        self.path = path

        let buffer = UnsafeMutablePointer<wchar_t>.allocate(capacity: 255)
        defer { buffer.deallocate() }
        buffer[0] = 0
        hid_get_serial_number_string(dev, buffer, 255)
        serialNumber = buffer[0] != 0 ? (NSString(wcharArray: buffer) as String) : path
    }

    deinit {
        stop()
        readBuffer.deallocate()
    }

    var isConnected: Bool {
        dev != nil
    }

    func start() {
        guard thread == nil else { return }
        running = true
        updateSensitivity()
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "Dial \(serialNumber)"
        thread = t
        t.start()
    }

    func stop() {
        running = false
        // Reader uses hid_read_timeout, so it notices `running` within ~250ms
        // and closes the handle itself.
        thread = nil
    }

    /// https://github.com/daniel5151/surface-dial-linux/blob/main/src/dial_device/haptics.rs
    private func updateSensitivity() {
        guard let dev = dev else { return }
        let steps = wheelSensitivity
        var buf: [UInt8] = [
            0x01, // Report ID
            UInt8(steps & 0xFF), // steps lo
            UInt8((steps >> 8) & 0xFF), // steps hi
            0x00, // repeat count
            haptics ? 0x03 : 0x02, // auto trigger
            0x00, // waveform cutoff time
            0x00, 0x00, // retrigger period
        ]
        hid_send_feature_report(dev, &buf, 8)
    }

    func impact(repeatCount: UInt8 = 0) {
        guard let dev = dev else { return }
        var buf: [UInt8] = [0x01, repeatCount, 0x03, 0x00, 0x00]
        hid_write(dev, &buf, 5)
    }

    private func parse(count: Int) -> InputReport {
        guard count >= 3, readBuffer[0] == 1 else { return .unknown }

        let buttonState: ButtonState = readBuffer[1] & 1 == 1 ? .pressed : .released

        // Signed delta; several detents can coalesce into one report at
        // high sensitivity, so this is not always ±1.
        let delta = Int(Int8(bitPattern: readBuffer[2]))
        let rotation: Rotation?
        switch delta {
        case 0: rotation = nil
        case ..<0: rotation = .CounterClockwise(-delta)
        default: rotation = .Clockwise(delta)
        }

        return .dial(buttonState, rotation)
    }

    private func read() -> InputReport? {
        guard let dev = dev else { return nil }
        let n = hid_read_timeout(dev, readBuffer, 64, 250)
        if n < 0 { return nil } // device gone
        if n == 0 { return .timeout } // no data; loop re-checks `running`
        return parse(count: Int(n))
    }

    private func readLoop() {
        while running {
            switch read() {
            case let .dial(buttonState, rotation):
                if buttonState != lastButtonState {
                    lastButtonState = buttonState
                    onButtonStateChanged?(self, buttonState)
                }
                if let rotation = rotation {
                    onRotation?(self, rotation)
                }
            case .timeout, .unknown:
                continue
            case nil:
                running = false
            }
        }
        if let dev = dev {
            hid_close(dev)
            self.dev = nil
        }
        onDisconnected?(self)
    }
}
