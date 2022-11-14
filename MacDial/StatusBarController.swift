import Foundation
import AppKit

enum WheelSensitivity: String {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case extreme = "extreme"
}

enum ScrollDirection: String {
    case standard = "standard"
    case natural = "natural"
}

enum Mode: String {
    case scrolling = "scrolling"
    case playback = "playback"
    case midi = "midi"      // ← added
}

enum HapticsMode: String {
    case enabled = "enabled"
    case disabled = "disabled"
}

extension NSMenuItem {
    convenience init(title: String) {
        self.init()
        self.title = title
    }
}

class MenuOptionItem<Type>: NSMenuItem {
    init(title: String, option: Type) {
        super.init(title: title, action: nil, keyEquivalent: "")
        self.representedObject = option
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var selected: Bool {
        get { return self.state == .on }
        set { self.state = newValue ? .on : .off }
    }

    var option: Type {
        return self.representedObject as! Type
    }
}

class ControllerOptionItem: MenuOptionItem<Mode> {
    let controller: Controller

    init(title: String, mode: Mode, controller: Controller) {
        self.controller = controller
        super.init(title: title, option: mode)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension NSMenu {
    func addMenuItems(_ items: StatusBarController.MenuItems) {
        self.addItem(items.title)
        self.addItem(items.connectionStatus)
        self.addItem(items.separator)

        self.addItem(items.scrollMode)
        self.addItem(items.playbackMode)
        self.addItem(items.midiMode)          // ← added

        self.addItem(items.separator2)

        items.wheelSensitivity.submenu = NSMenu()
        for sensitivityOption in items.wheelSensitivityOptions {
            items.wheelSensitivity.submenu?.addItem(sensitivityOption)
        }
        self.addItem(items.wheelSensitivity)

        items.scrollDirection.submenu = NSMenu()
        for scrollDirectionOption in items.scrollDirectionOptions {
            items.scrollDirection.submenu?.addItem(scrollDirectionOption)
        }
        self.addItem(items.scrollDirection)

        items.hapticsMode.submenu = NSMenu()
        for hapticsModeOption in items.hapticsModeOptions {
            items.hapticsMode.submenu?.addItem(hapticsModeOption)
        }
        self.addItem(items.hapticsMode)

        self.addItem(items.separator3)
        self.addItem(items.quit)
    }
}

class StatusBarController {
    private let statusBar: NSStatusBar
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let dial: Dial
    private let menuItems = MenuItems()

    struct MenuItems {
        let title = NSMenuItem(title: "Mac Dial")
        let connectionStatus = NSMenuItem()
        let separator = NSMenuItem.separator()

        let scrollMode   = ControllerOptionItem(title: "Scroll mode",   mode: .scrolling, controller: ScrollController())
        let playbackMode = ControllerOptionItem(title: "Playback mode", mode: .playback,  controller: PlaybackController())
        let midiMode     = ControllerOptionItem(title: "MIDI mode",     mode: .midi,      controller: MidiController())  // ← added

        let separator2 = NSMenuItem.separator()

        let wheelSensitivity = NSMenuItem(title: "Wheel Sensitivity")
        let wheelSensitivityOptions = [
            MenuOptionItem<WheelSensitivity>(title: "Low",     option: .low),
            MenuOptionItem<WheelSensitivity>(title: "Medium",  option: .medium),
            MenuOptionItem<WheelSensitivity>(title: "High",    option: .high),
            MenuOptionItem<WheelSensitivity>(title: "Extreme", option: .extreme)
        ]

        let scrollDirection = NSMenuItem(title: "Scroll Direction")
        let scrollDirectionOptions = [
            MenuOptionItem<ScrollDirection>(title: "Standard", option: .standard),
            MenuOptionItem<ScrollDirection>(title: "Natural",  option: .natural)
        ]

        let hapticsMode = NSMenuItem(title: "Haptics")
        let hapticsModeOptions = [
            MenuOptionItem<HapticsMode>(title: "Disabled", option: .disabled),
            MenuOptionItem<HapticsMode>(title: "Enabled",  option: .enabled)
        ]

        let separator3 = NSMenuItem.separator()
        let quit = NSMenuItem(title: "Quit")
    }

    var currentMode: Mode {
        get {
            switch UserDefaults.standard.string(forKey: "mode") {
            case .some("scroll"):   return .scrolling
            case .some("playback"): return .playback
            case .some("midi"):     return .midi      // ← added
            default:                return .scrolling
            }
        }
        set {
            switch newValue {
            case .playback:
                UserDefaults.standard.setValue("playback", forKey: "mode")
            case .scrolling:
                UserDefaults.standard.setValue("scroll", forKey: "mode")
            case .midi:
                UserDefaults.standard.setValue("midi", forKey: "mode")   // ← added
            }
        }
    }

    var currentController: Controller {
        switch currentMode {
        case .playback:
            return menuItems.playbackMode.controller
        case .scrolling:
            return menuItems.scrollMode.controller
        case .midi:
            return menuItems.midiMode.controller       // ← added
        }
    }

    var wheelSensitivity: WheelSensitivity? {
        get {
            let raw = UserDefaults.standard.string(forKey: "sensitivity") ?? WheelSensitivity.medium.rawValue
            return WheelSensitivity(rawValue: raw)
        }
        set {
            switch newValue {
            case .low:
                dial.wheelSensitivity = 18
            case .medium:
                dial.wheelSensitivity = 36
            case .high:
                dial.wheelSensitivity = 72
            case .extreme:
                dial.wheelSensitivity = 360
            case .none:
                break
            }
            for option in menuItems.wheelSensitivityOptions {
                option.state = (option.representedObject as! WheelSensitivity) == newValue ? .on : .off
            }
            UserDefaults.standard.setValue(newValue?.rawValue, forKey: "sensitivity")
        }
    }

    var scrollDirection: ScrollDirection? {
        get {
            let raw = UserDefaults.standard.string(forKey: "direction") ?? ScrollDirection.natural.rawValue
            return ScrollDirection(rawValue: raw)
        }
        set {
            switch newValue {
            case .standard:
                dial.scrollDirection = 1
            case .natural:
                dial.scrollDirection = -1
            case .none:
                break
            }
            for option in menuItems.scrollDirectionOptions {
                option.state = (option.representedObject as! ScrollDirection) == newValue ? .on : .off
            }
            UserDefaults.standard.setValue(newValue?.rawValue, forKey: "direction")
        }
    }

    var hapticsMode: HapticsMode? {
        get {
            let raw = UserDefaults.standard.string(forKey: "hapticsmode") ?? HapticsMode.disabled.rawValue
            return HapticsMode(rawValue: raw)
        }
        set {
            switch newValue {
            case .disabled:
                dial.haptics = false
            case .enabled:
                dial.haptics = true
            case .none:
                break
            }
            for option in menuItems.hapticsModeOptions {
                option.state = (option.representedObject as! HapticsMode) == newValue ? .on : .off
            }
            if let v = newValue {
                UserDefaults.standard.setValue(String(v.rawValue), forKey: "hapticsmode")
            }
        }
    }

    init(_ dial: Dial) {
        self.dial = dial
        self.menu = NSMenu()

        statusBar = NSStatusBar()
        // In StatusBarController.init(...)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Add 2–3 pt of extra width for breathing room
        let slot = NSStatusBar.system.thickness          // ~22
        statusItem.length = slot + 2                   // try 2–4 and pick what matches your bar

        menu.minimumWidth = 260

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 0)
        ]

        menuItems.title.attributedTitle = NSAttributedString(string: menuItems.title.title, attributes: attributes)
        menuItems.title.target = self
        menuItems.title.action = #selector(showAbout(sender:))

        menuItems.connectionStatus.target = self
        menuItems.connectionStatus.isEnabled = false

        menuItems.scrollMode.target = self
        menuItems.scrollMode.action = #selector(setMode(sender:))
        menuItems.scrollMode.selected = currentMode == .scrolling

        menuItems.playbackMode.target = self
        menuItems.playbackMode.action = #selector(setMode(sender:))
        menuItems.playbackMode.selected = currentMode == .playback

        // MIDI mode wiring (added)
        menuItems.midiMode.target = self
        menuItems.midiMode.action = #selector(setMode(sender:))
        menuItems.midiMode.selected = currentMode == .midi

        for option in menuItems.wheelSensitivityOptions {
            option.target = self
            option.action = #selector(setSensitivity(sender:))
            option.selected = option.option == wheelSensitivity
        }
        wheelSensitivity = wheelSensitivity // apply to hardware

        for option in menuItems.scrollDirectionOptions {
            option.target = self
            option.action = #selector(setScrollDirection(sender:))
            option.selected = option.option == scrollDirection
        }
        scrollDirection = scrollDirection // apply to hardware (sets ±1)

        for option in menuItems.hapticsModeOptions {
            option.target = self
            option.action = #selector(setHaptics(sender:))
            option.selected = option.option == hapticsMode
        }
        hapticsMode = hapticsMode // apply to hardware

        menuItems.quit.target = self
        menuItems.quit.action = #selector(quitApp(sender:))

        menu.addMenuItems(menuItems)
        statusItem.menu = menu

        if let button = statusItem.button {
            button.target = self
            updateIcon()
        }

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self]_ in
            self?.updateConnectionStatus()
        }

        dial.onButtonStateChanged = { [unowned self] state in
            switch state {
            case .pressed:
                currentController.onDown()
            case .released:
                currentController.onUp()
            }
        }

        dial.onRotation = { [unowned self] rotation, scrollDirection in
            currentController.onRotate(rotation, scrollDirection)
        }
    }

    private func updateConnectionStatus() {
        if dial.device.isConnected {
            let serialNumber = dial.device.serialNumber
            menuItems.connectionStatus.title = "Surface Dial '\(serialNumber)' connected"
        } else {
            menuItems.connectionStatus.title = "No Surface Dial connected"
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let symbol: String =
            menuItems.playbackMode.state == .on ? "speaker.wave.2" :
            menuItems.midiMode.state     == .on ? "dial.medium"     :
                                                  "arrow.up.and.down.circle"

        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mac Dial")?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            button.image = img
        }

        button.imagePosition = .imageOnly
        button.imageScaling  = .scaleNone
    }

    @objc func showAbout(sender: AnyObject) { }

    @objc func setMode(sender: AnyObject) {
        let item = sender as! ControllerOptionItem

        menuItems.playbackMode.state = (item == menuItems.playbackMode) ? .on : .off
        menuItems.scrollMode.state   = (item == menuItems.scrollMode)   ? .on : .off
        menuItems.midiMode.state     = (item == menuItems.midiMode)     ? .on : .off

        currentMode = item.option
        updateIcon()
    }

    @objc func setSensitivity(sender: AnyObject) {
        let item = sender as! NSMenuItem
        wheelSensitivity = (item.representedObject as! WheelSensitivity)
    }

    @objc func setScrollDirection(sender: AnyObject) {
        let item = sender as! NSMenuItem
        scrollDirection = (item.representedObject as! ScrollDirection)
    }

    @objc func setHaptics(sender: AnyObject) {
        let item = sender as! NSMenuItem
        hapticsMode = (item.representedObject as! HapticsMode)
    }

    @objc func quitApp(sender: AnyObject) {
        NSApplication.shared.terminate(self)
    }
}
