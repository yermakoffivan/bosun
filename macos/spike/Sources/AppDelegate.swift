import AppKit
import SwiftUI
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let ws = Workspace()
    let args = CommandLine.arguments

    func argValue(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = GhosttyRuntime.shared
        buildMenu()

        let hosting = NSHostingView(rootView: SidebarView(model: ws.model))
        let root = RootView(sidebar: hosting, main: ws.area)
        let w = Double(argValue("--width") ?? "") ?? 1400
        let h = Double(argValue("--height") ?? "") ?? 860
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: w, height: h),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Bosun Spike"
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        root.resizeSubviews(withOldSize: .zero)

        try? FileManager.default.createDirectory(atPath: resultsDir, withIntermediateDirectories: true)
        try? "\(window.windowNumber)\n".write(toFile: resultsDir + "/window-id.txt", atomically: true, encoding: .utf8)
        print("window-id \(window.windowNumber) pid \(getpid())")
        fflush(stdout)

        ws.refreshSessions()
        if args.contains("--selftest") {
            Task { @MainActor in await SelfTest(ws: ws, window: window).run(); NSApp.terminate(nil) }
        } else if args.contains("--q1test") {
            Task { @MainActor in await Q1Test(ws: ws, window: window).run(); NSApp.terminate(nil) }
        } else if args.contains("--memtest") {
            Task { @MainActor in await MemTest(ws: ws).run(label: argValue("--memtest-label") ?? "default"); NSApp.terminate(nil) }
        } else if let secs = argValue("--idle") {
            Task { @MainActor in await IdleTest(ws: ws).run(seconds: Double(secs) ?? 60, sessions: (argValue("--sessions") ?? "").split(separator: ",").map(String.init)); NSApp.terminate(nil) }
        } else if let demo = argValue("--demo") {
            // Non-interactive layouts for screenshots: "single:<s>" or "split:<a>,<b>[,warm...]"
            let parts = demo.split(separator: ":", maxSplits: 1).map(String.init)
            let names = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
            if parts[0] == "split", names.count >= 2 {
                for extra in names.dropFirst(2) { ws.show(extra, inTile: 0) }
                ws.setMode(.split)
                ws.show(names[0], inTile: 0)
                ws.show(names[1], inTile: 1)
            } else if let first = names.first {
                ws.show(first, inTile: 0)
            }
        } else if let first = ws.model.sessions.first {
            ws.show(first, inTile: 0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Bosun Spike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let split = NSMenuItem(title: "Toggle Split", action: #selector(toggleSplit), keyEquivalent: "d")
        split.target = self
        viewMenu.addItem(split)
        let other = NSMenuItem(title: "Focus Other Tile", action: #selector(focusOther), keyEquivalent: "]")
        other.target = self
        viewMenu.addItem(other)
        let refresh = NSMenuItem(title: "Refresh Sessions", action: #selector(refreshSessions), keyEquivalent: "r")
        refresh.target = self
        viewMenu.addItem(refresh)
        viewMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(title: "Session \(i)", action: #selector(selectSession(_:)), keyEquivalent: "\(i)")
            item.tag = i
            item.target = self
            viewMenu.addItem(item)
        }
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
    }

    @objc func toggleSplit() {
        if ws.mode == .single {
            ws.setMode(.split)
            if ws.tiles[1] == nil, let next = ws.model.sessions.first(where: { !ws.tiles.contains($0) }) {
                ws.show(next, inTile: 1)
            }
        } else {
            ws.setMode(.single)
        }
    }

    @objc func focusOther() {
        guard ws.mode == .split else { return }
        ws.focus(tile: ws.focusedTile == 0 ? 1 : 0)
    }

    @objc func refreshSessions() { ws.refreshSessions() }

    @objc func selectSession(_ sender: NSMenuItem) {
        let i = sender.tag - 1
        guard i < ws.model.sessions.count else { return }
        ws.show(ws.model.sessions[i], inTile: ws.focusedTile)
    }
}
