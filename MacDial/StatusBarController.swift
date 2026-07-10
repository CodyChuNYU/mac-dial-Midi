import AppKit
import Foundation

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
}

class StatusBarController {
    private let statusBar = NSStatusBar()
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let manager: DialManager
    private let scrollTestPanel = ScrollTestPanel()

    private let controllers: [Mode: Controller] = [
        .scrolling: ScrollController(),
        .playback: PlaybackController(),
        .midi: MidiController(),
    ]

    // MARK: - Settings (global hardware settings + per-dial mode)

    private var wheelSensitivity: WheelSensitivity {
        get {
            let raw = UserDefaults.standard.string(forKey: "sensitivity")
            // Extreme by default: the engine normalizes speed by resolution,
            // so more steps only means smoother input, not faster scrolling.
            return raw.flatMap(WheelSensitivity.init(rawValue:)) ?? .extreme
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

    private func mode(for dial: Dial) -> Mode {
        let raw = UserDefaults.standard.string(forKey: "mode.\(dial.serialNumber)")
        return raw.flatMap(Mode.init(rawValue:)) ?? .scrolling
    }

    private func setMode(_ mode: Mode, for serial: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: "mode.\(serial)")
        rebuildMenu()
    }

    // MARK: - Init

    init(_ manager: DialManager) {
        self.manager = manager
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        menu.minimumWidth = 260

        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "icon-scroll")
            button.image?.size = NSSize(width: 18, height: 18)
            button.imagePosition = .imageLeft
        }

        manager.configureDial = { [weak self] dial in
            guard let self = self else { return }
            dial.wheelSensitivity = self.wheelSensitivity.steps
            dial.haptics = self.haptics
        }

        manager.onButtonStateChanged = { [weak self] dial, state in
            guard let self = self else { return }
            let controller = self.controllers[self.mode(for: dial)]
            switch state {
            case .pressed: controller?.onDown(dial: dial)
            case .released: controller?.onUp(dial: dial)
            }
        }

        manager.onRotation = { [weak self] dial, rotation in
            guard let self = self else { return }
            self.controllers[self.mode(for: dial)]?
                .onRotate(dial: dial, rotation: rotation, direction: self.scrollDirection.sign)
        }

        manager.onDialsChanged = { [weak self] _ in
            self?.rebuildMenu()
        }

        rebuildMenu()
    }

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

        let sensitivity = NSMenuItem(title: "Wheel Sensitivity", action: nil, keyEquivalent: "")
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

        menu.addItem(.separator())

        let test = NSMenuItem(title: "Scroll Test…", action: #selector(openScrollTest(_:)), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String],
              pair.count == 2,
              let mode = Mode(rawValue: pair[1]) else { return }
        setMode(mode, for: pair[0])
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

    @objc private func openScrollTest(_: NSMenuItem) {
        scrollTestPanel.show()
    }

    @objc private func quitApp(_: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }
}
