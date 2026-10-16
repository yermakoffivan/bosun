import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private var test: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ProcessClock.start
        controller.start()
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            let t = SelfTest(app: controller)
            test = t
            Task { await t.run(); NSApp.terminate(nil) }
        } else if args.contains("--launchprobe") {
            let t = LaunchProbe(app: controller)
            test = t
            t.run()
        } else if args.contains("--focustest") {
            let t = FocusTest(app: controller)
            test = t
            Task { await t.run(); NSApp.terminate(nil) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GhosttyRuntime.shared.setAppFocus(true)
        controller.appBecameActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        GhosttyRuntime.shared.setAppFocus(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controller.persist()
    }
}
