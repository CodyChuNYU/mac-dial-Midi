import Foundation

/// Discovers and owns every connected Surface Dial. A single discovery
/// thread enumerates on hotplug events (hid_monitor) or every few seconds,
/// opening any dial that isn't open yet. Each Dial runs its own read thread.
class DialManager {
    static let shared = DialManager()

    private var thread: Thread?
    private var running = false
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var dialsByPath: [String: Dial] = [:]

    /// Fired on the main queue whenever a dial connects or disconnects.
    var onDialsChanged: (([Dial]) -> Void)?
    /// Fired from the dial's read thread.
    var onButtonStateChanged: ((Dial, Dial.ButtonState) -> Void)?
    var onRotation: ((Dial, Dial.Rotation) -> Void)?
    /// Applied to every dial when it connects (sensitivity, haptics).
    var configureDial: ((Dial) -> Void)?

    var dials: [Dial] {
        lock.lock()
        defer { lock.unlock() }
        return dialsByPath.values.sorted { $0.serialNumber < $1.serialNumber }
    }

    private init() {
        hid_init()
    }

    func start() {
        guard thread == nil else { return }
        running = true
        let t = Thread { [weak self] in self?.discoveryLoop() }
        t.name = "DialManager discovery"
        thread = t
        t.start()
    }

    func stop() {
        running = false
        semaphore.signal()
        lock.lock()
        let all = Array(dialsByPath.values)
        lock.unlock()
        for dial in all {
            // Restore hardware defaults so the dial isn't left in an odd state.
            dial.haptics = false
            dial.wheelSensitivity = 36
            dial.stop()
        }
    }

    /// Re-apply global settings (sensitivity/haptics) to all connected dials.
    func reconfigureAll() {
        for dial in dials {
            configureDial?(dial)
        }
    }

    private func discoveryLoop() {
        hid_monitor { vendorId, productId, _ in
            if vendorId == Dial.VendorId, productId == Dial.ProductId {
                // C function pointer — can't capture, go through the singleton.
                DialManager.shared.semaphore.signal()
            }
        }

        while running {
            openNewDials()
            _ = semaphore.wait(timeout: .now() + .seconds(5))
        }
    }

    private func openNewDials() {
        var paths: [String] = []
        var info = hid_enumerate(Dial.VendorId, Dial.ProductId)
        let head = info
        while let cur = info {
            if let cPath = cur.pointee.path {
                paths.append(String(cString: cPath))
            }
            info = cur.pointee.next
        }
        hid_free_enumeration(head)

        var changed = false
        for path in paths {
            lock.lock()
            let alreadyOpen = dialsByPath[path] != nil
            lock.unlock()
            guard !alreadyOpen else { continue }
            guard let dial = Dial(path: path) else {
                // Usually means Input Monitoring permission is missing.
                print("Found Surface Dial at \(path) but couldn't open it")
                continue
            }

            dial.onButtonStateChanged = { [weak self] dial, state in
                self?.onButtonStateChanged?(dial, state)
            }
            dial.onRotation = { [weak self] dial, rotation in
                self?.onRotation?(dial, rotation)
            }
            dial.onDisconnected = { [weak self] dial in
                guard let self = self else { return }
                self.lock.lock()
                self.dialsByPath.removeValue(forKey: dial.path)
                self.lock.unlock()
                self.notifyChanged()
                self.semaphore.signal() // re-enumerate soon
            }

            lock.lock()
            dialsByPath[path] = dial
            lock.unlock()

            configureDial?(dial)
            dial.start()
            print("Opened Surface Dial \(dial.serialNumber)")
            changed = true
        }

        if changed {
            notifyChanged()
        }
    }

    private func notifyChanged() {
        let current = dials
        DispatchQueue.main.async { [weak self] in
            self?.onDialsChanged?(current)
        }
    }
}
