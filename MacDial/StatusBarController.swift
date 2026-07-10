import AppKit
import Foundation
import ServiceManagement

enum WheelSensitivity: String, CaseIterable {
    case low, medium, high, extreme

    var title: String {
        switch self {
        case .low: return "Low (18)"
        case .medium: return "Medium (36)"
        case .high: return "High (72)"
        case .extreme: return "Extreme (360)"
        }
    }

    var steps: Int {
        switch self {
        case .low: return 18
        case .medium: return 36
        case .high: return 72
        case .extreme: return 360
        }
    }
}

enum ScrollDirection: String, CaseIterable {
    case standard, natural

    var title: String {
        rawValue.capitalized
    }

    var sign: Int {
        self == .standard ? 1 : -1
    }
}

enum Mode: String, CaseIterable {
    case scrolling, playback, midi

    var title: String {
        switch self {
        case .scrolling: return "Scroll mode"
        case .playback: return "Playback mode"
        case .midi: return "MIDI mode"
        }
    }

    var shortTitle: String {
        switch self {
        case .scrolling: return "Scroll"
        case .playback: return "Playback"
        case .midi: return "MIDI"
        }
    }
}

/// Tracks the frontmost app (excluding ourselves) so dial events can be
/// routed per app. Updated on the main queue, read from the HID thread.
final class FrontAppTracker {
    private let lock = NSLock()
    private var front: (bundleID: String, name: String)?

    init() {
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.update(app)
        }
    }

    private func update(_ app: NSRunningApplication?) {
        guard let app = app,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        lock.lock()
        front = (bundleID, app.localizedName ?? bundleID)
        lock.unlock()
    }

    var current: (bundleID: String, name: String)? {
        lock.lock()
        defer { lock.unlock() }
        return front
    }
}

class StatusBarController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let manager: DialManager
    private let scrollTestPanel = ScrollTestPanel()
    private let frontApp = FrontAppTracker()

    private let controllers: [Mode: Controller] = [
        .scrolling: ScrollController(),
        .playback: PlaybackController(),
        .midi: MidiController(),
    ]

    // MARK: - Settings (global hardware settings + per-dial mode)

    private var wheelSensitivity: WheelSensitivity {
        get {
            let raw = UserDefaults.standard.string(forKey: "sensitivity")
            // Only used while haptics is on: it sets the click density.
            // Medium = 36 real detents per revolution, like a mouse wheel.
            return raw.flatMap(WheelSensitivity.init(rawValue:)) ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "sensitivity")
            manager.reconfigureAll()
        }
    }

    private var scrollDirection: ScrollDirection {
        get {
            let raw = UserDefaults.standard.string(forKey: "direction")
            return raw.flatMap(ScrollDirection.init(rawValue:)) ?? .natural
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "direction") }
    }

    private var haptics: Bool {
        get { UserDefaults.standard.bool(forKey: "haptics") }
        set {
            UserDefaults.standard.set(newValue, forKey: "haptics")
            manager.reconfigureAll()
        }
    }

    private var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                hidLog.error("Launch at login toggle failed: \(error)")
            }
        }
    }

    private func mode(for dial: Dial) -> Mode {
        let raw = UserDefaults.standard.string(forKey: "mode.\(dial.serialNumber)")
        return raw.flatMap(Mode.init(rawValue:)) ?? .scrolling
    }

    private func setMode(_ mode: Mode, for serial: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: "mode.\(serial)")
        rebuildMenu()
    }

    // MARK: - Per-app profiles

    private var appModes: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "appModes") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "appModes") }
    }

    private var appNames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "appNames") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "appNames") }
    }

    /// Per-app override wins; the dial's own mode is the fallback.
    private func effectiveMode(for dial: Dial) -> Mode {
        if let bundleID = frontApp.current?.bundleID,
           let raw = appModes[bundleID],
           let mode = Mode(rawValue: raw)
        {
            return mode
        }
        return mode(for: dial)
    }

    // MARK: - Init

    init(_ manager: DialManager) {
        self.manager = manager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        menu.minimumWidth = 260
        menu.delegate = menuDelegate
        menuDelegate.onOpen = { [weak self] in self?.rebuildMenu() }

        if let button = statusItem.button {
            if let symbol = NSImage(systemSymbolName: "dial.min.fill",
                                    accessibilityDescription: "Mac Dial")
            {
                symbol.isTemplate = true
                button.image = symbol
                button.imagePosition = .imageOnly
            } else {
                button.title = "◐"
            }
        }

        manager.configureDial = { [weak self] dial in
            guard let self = self else { return }
            // Haptics on: coarse hardware steps, each one a physical click.
            // Haptics off: fine 360-step resolution for buttery scrolling.
            // The scroll engine normalizes by resolution, so speed is
            // identical either way — only the feel changes.
            dial.wheelSensitivity = self.haptics ? self.wheelSensitivity.steps : 360
            dial.haptics = self.haptics
        }

        manager.onButtonStateChanged = { [weak self] dial, state in
            guard let self = self else { return }
            let controller = self.controllers[self.effectiveMode(for: dial)]
            switch state {
            case .pressed: controller?.onDown(dial: dial)
            case .released: controller?.onUp(dial: dial)
            }
        }

        manager.onRotation = { [weak self] dial, rotation in
            guard let self = self else { return }
            self.controllers[self.effectiveMode(for: dial)]?
                .onRotate(dial: dial, rotation: rotation, direction: self.scrollDirection.sign)
        }

        manager.onDialsChanged = { [weak self] _ in
            self?.rebuildMenu()
        }

        rebuildMenu()
    }

    /// Rebuilds just before the menu opens so the per-app section reflects
    /// the app that was frontmost at click time.
    private let menuDelegate = MenuOpenDelegate()

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "Mac Dial", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "Mac Dial",
                                                   attributes: [.font: NSFont.boldSystemFont(ofSize: 0)])
        menu.addItem(title)

        let dials = manager.dials
        if dials.isEmpty {
            let item = NSMenuItem(title: "No Surface Dial connected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for (index, dial) in dials.enumerated() {
            menu.addItem(.separator())
            let name = NSMenuItem(title: "Dial \(index + 1) — \(dial.serialNumber)",
                                  action: nil, keyEquivalent: "")
            name.isEnabled = false
            menu.addItem(name)

            let currentMode = mode(for: dial)
            for mode in Mode.allCases {
                let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
                item.target = self
                item.state = mode == currentMode ? .on : .off
                item.representedObject = [dial.serialNumber, mode.rawValue]
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addAppProfilesMenu()

        menu.addItem(.separator())

        let sensitivity = NSMenuItem(title: "Click Density (Haptics)", action: nil, keyEquivalent: "")
        sensitivity.submenu = NSMenu()
        for option in WheelSensitivity.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.state = option == wheelSensitivity ? .on : .off
            item.representedObject = option.rawValue
            sensitivity.submenu?.addItem(item)
        }
        menu.addItem(sensitivity)

        let direction = NSMenuItem(title: "Scroll Direction", action: nil, keyEquivalent: "")
        direction.submenu = NSMenu()
        for option in ScrollDirection.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectDirection(_:)), keyEquivalent: "")
            item.target = self
            item.state = option == scrollDirection ? .on : .off
            item.representedObject = option.rawValue
            direction.submenu?.addItem(item)
        }
        menu.addItem(direction)

        let hapticsItem = NSMenuItem(title: "Haptics", action: #selector(toggleHaptics(_:)), keyEquivalent: "")
        hapticsItem.target = self
        hapticsItem.state = haptics ? .on : .off
        menu.addItem(hapticsItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = launchAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let test = NSMenuItem(title: "Scroll Test…", action: #selector(openScrollTest(_:)), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addAppProfilesMenu() {
        let profiles = NSMenuItem(title: "App Profiles", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if let front = frontApp.current {
            let header = NSMenuItem(title: "For \(front.name):", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)

            let currentOverride = appModes[front.bundleID].flatMap(Mode.init(rawValue:))
            let defaultItem = NSMenuItem(title: "Default (per-dial mode)",
                                         action: #selector(setAppOverride(_:)), keyEquivalent: "")
            defaultItem.target = self
            defaultItem.state = currentOverride == nil ? .on : .off
            defaultItem.representedObject = [front.bundleID, front.name, ""]
            defaultItem.indentationLevel = 1
            submenu.addItem(defaultItem)

            for mode in Mode.allCases {
                let item = NSMenuItem(title: mode.shortTitle,
                                      action: #selector(setAppOverride(_:)), keyEquivalent: "")
                item.target = self
                item.state = currentOverride == mode ? .on : .off
                item.representedObject = [front.bundleID, front.name, mode.rawValue]
                item.indentationLevel = 1
                submenu.addItem(item)
            }
        }

        let overrides = appModes
        if !overrides.isEmpty {
            submenu.addItem(.separator())
            let header = NSMenuItem(title: "Active overrides (click to remove):", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            for (bundleID, raw) in overrides.sorted(by: { $0.key < $1.key }) {
                let name = appNames[bundleID] ?? bundleID
                let modeTitle = Mode(rawValue: raw)?.shortTitle ?? raw
                let item = NSMenuItem(title: "\(name) — \(modeTitle)",
                                      action: #selector(removeAppOverride(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bundleID
                item.indentationLevel = 1
                submenu.addItem(item)
            }
        }

        if submenu.items.isEmpty {
            let empty = NSMenuItem(title: "No app in front", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }

        profiles.submenu = submenu
        menu.addItem(profiles)
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String],
              pair.count == 2,
              let mode = Mode(rawValue: pair[1]) else { return }
        setMode(mode, for: pair[0])
    }

    @objc private func setAppOverride(_ sender: NSMenuItem) {
        guard let triple = sender.representedObject as? [String], triple.count == 3 else { return }
        let (bundleID, name, raw) = (triple[0], triple[1], triple[2])
        if raw.isEmpty {
            appModes.removeValue(forKey: bundleID)
            appNames.removeValue(forKey: bundleID)
        } else {
            appModes[bundleID] = raw
            appNames[bundleID] = name
        }
        rebuildMenu()
    }

    @objc private func removeAppOverride(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        appModes.removeValue(forKey: bundleID)
        appNames.removeValue(forKey: bundleID)
        rebuildMenu()
    }

    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = WheelSensitivity(rawValue: raw) else { return }
        wheelSensitivity = option
        rebuildMenu()
    }

    @objc private func selectDirection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = ScrollDirection(rawValue: raw) else { return }
        scrollDirection = option
        rebuildMenu()
    }

    @objc private func toggleHaptics(_: NSMenuItem) {
        haptics.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin(_: NSMenuItem) {
        launchAtLogin.toggle()
        rebuildMenu()
    }

    @objc private func openScrollTest(_: NSMenuItem) {
        scrollTestPanel.show()
    }

    @objc private func quitApp(_: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }
}

/// Small delegate that lets the controller refresh the menu right as it opens.
final class MenuOpenDelegate: NSObject, NSMenuDelegate {
    var onOpen: (() -> Void)?

    func menuNeedsUpdate(_: NSMenu) {
        onOpen?()
    }
}
