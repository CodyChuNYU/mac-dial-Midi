import Foundation
import IOKit.hid
import os

/// Discovers and owns every connected Surface Dial via IOHIDManager.
/// Matching/removal callbacks and input reports all run on a dedicated
/// runloop thread — no polling.
final class DialManager {
    static let shared = DialManager()

    private var manager: IOHIDManager?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let lock = NSLock()
    private var dialsBySerial: [String: Dial] = [:]

    /// Fired on the main queue whenever a dial connects or disconnects.
    var onDialsChanged: (([Dial]) -> Void)?
    /// Fired from the HID runloop thread.
    var onButtonStateChanged: ((Dial, Dial.ButtonState) -> Void)?
    var onRotation: ((Dial, Dial.Rotation) -> Void)?
    /// Applied to every dial when it connects (sensitivity, haptics).
    var configureDial: ((Dial) -> Void)?

    var dials: [Dial] {
        lock.lock()
        defer { lock.unlock() }
        return dialsBySerial.values.sorted { $0.serialNumber < $1.serialNumber }
    }

    private init() {}

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.hidThreadMain() }
        t.name = "DialManager HID"
        thread = t
        t.start()
    }

    func stop() {
        if let runLoop = runLoop {
            CFRunLoopStop(runLoop)
        }
        lock.lock()
        let all = Array(dialsBySerial.values)
        dialsBySerial.removeAll()
        lock.unlock()
        for dial in all {
            // Restore hardware defaults so the dial isn't left in an odd state.
            dial.configure(sensitivity: 36, haptics: false)
            dial.close()
        }
    }

    /// Re-apply global settings (sensitivity/haptics) to all connected dials.
    func reconfigureAll() {
        for dial in dials {
            configureDial?(dial)
        }
    }

    // MARK: - HID runloop

    private func hidThreadMain() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        runLoop = CFRunLoopGetCurrent()

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Dial.vendorId,
            kIOHIDProductIDKey: Dial.productId,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            Unmanaged<DialManager>.fromOpaque(context!).takeUnretainedValue().deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            Unmanaged<DialManager>.fromOpaque(context!).takeUnretainedValue().deviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

        CFRunLoopRun()

        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? "unknown"

        lock.lock()
        let alreadyOpen = dialsBySerial[serial] != nil
        lock.unlock()
        // A dial can surface as more than one matched HID service; one is enough.
        guard !alreadyOpen else { return }

        guard let dial = Dial(device: device) else {
            hidLog.error("Found Surface Dial \(serial, privacy: .public) but couldn't open it")
            return
        }

        dial.onButtonStateChanged = { [weak self] dial, state in
            self?.onButtonStateChanged?(dial, state)
        }
        dial.onRotation = { [weak self] dial, rotation in
            self?.onRotation?(dial, rotation)
        }

        lock.lock()
        dialsBySerial[serial] = dial
        lock.unlock()

        configureDial?(dial)
        hidLog.info("Opened Surface Dial \(dial.serialNumber, privacy: .public)")
        notifyChanged()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        lock.lock()
        let entry = dialsBySerial.first { $0.value.device == device }
        if let entry = entry {
            dialsBySerial.removeValue(forKey: entry.key)
        }
        lock.unlock()

        guard let dial = entry?.value else { return }
        dial.close()
        hidLog.info("Surface Dial \(dial.serialNumber, privacy: .public) disconnected")
        notifyChanged()
    }

    private func notifyChanged() {
        let current = dials
        DispatchQueue.main.async { [weak self] in
            self?.onDialsChanged?(current)
        }
    }
}
