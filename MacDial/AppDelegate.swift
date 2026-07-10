import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_: Notification) {
        statusBarController = StatusBarController(DialManager.shared)
        DialManager.shared.start()
    }

    func applicationWillTerminate(_: Notification) {
        DialManager.shared.stop()
    }
}
