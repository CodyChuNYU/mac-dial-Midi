import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_: Notification) {
        statusBarController = StatusBarController(DialManager.shared)
        DialManager.shared.start()
        ensurePostEventAccess()
    }

    func applicationWillTerminate(_: Notification) {
        DialManager.shared.stop()
    }

    /// Scrolling/clicks/media keys are synthetic events, gated behind the
    /// Accessibility permission. First launch: trigger the system prompt.
    /// Later launches without access: show one alert with a deep link.
    private func ensurePostEventAccess() {
        guard !CGPreflightPostEventAccess() else { return }

        let promptedKey = "promptedForPostEventAccess"
        if !UserDefaults.standard.bool(forKey: promptedKey) {
            UserDefaults.standard.set(true, forKey: promptedKey)
            CGRequestPostEventAccess() // shows the system dialog once
            return
        }

        let alert = NSAlert()
        alert.messageText = "Mac Dial needs Accessibility access"
        alert.informativeText = "Turning the dial posts scroll and media events, which macOS "
            + "requires Accessibility permission for. Enable Mac Dial under "
            + "System Settings → Privacy & Security → Accessibility, then relaunch."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
