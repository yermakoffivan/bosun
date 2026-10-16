import AppKit
import BosunCore

// Scripted test modes (run through dev.sh against the test daemon):
//   --focustest [--shots DIR] [--results FILE]   drives the real event path and checks where keys land
//   --selftest [--results FILE]                  measures the section 1 budgets
//   --launchprobe                                prints launch timings and quits (used by --selftest)
//
// Events are injected into the app's own queue (NSApp.postEvent), so they go through AppKit's
// dispatch, the app's local monitors, hit-testing, key equivalents and the first responder,
// exactly as hardware events do. This works with the screen locked, where screencapture and
// CGEvent posting can't reach the window; screenshots are rendered in-process for the same reason.

func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

/// Report lines, echoed to stdout and saved to a file.
final class Report {
    private(set) var lines: [String] = []
    let path: String
    private(set) var failures = 0

    init(_ defaultName: String) {
        path = argValue("--results") ?? Paths.cacheDir.appendingPathComponent(defaultName).path
    }

    func say(_ s: String) {
        lines.append(s)
        print(s)
        fflush(stdout)
    }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        say("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
    }

    func save() {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@MainActor
class TestKit {
    let app: AppController
    let r: Report
    var w: MainWindow { app.window }
    var ws: Workspace { app.workspace }
    let shots: String?

    init(app: AppController, report: String) {
        self.app = app
        r = Report(report)
        shots = argValue("--shots")
        if let shots { try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true) }
    }

    func sleep(_ ms: Double) async { try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000)) }

    @discardableResult
    func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await sleep(10)
        }
        return cond()
    }

    func shot(_ name: String) {
        guard let shots else { return }
        let ok = WindowSnapshot.write(w, to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        r.say("      screenshot \(name).png \(ok ? "" : "FAILED")")
    }

    // MARK: Lookups

    func session(_ display: String) -> String? {
        app.daemon.state.sessionOrder.first { app.daemon.state.sessions[$0]?.display == display }
    }

    var tmuxSocket: String? { app.daemon.state.server?.tmuxSocket }

    /// The pane's visible text, straight from tmux (independent of the app's rendering).
    func pane(_ session: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.tmux)
        p.arguments = (tmuxSocket.map { ["-L", $0] } ?? []) + ["capture-pane", "-p", "-J", "-t", "=\(session):"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func tmux(_ args: [String]) {
        TmuxCLI.run(socket: tmuxSocket, args)
    }

    /// The session tmux has the given session's view's client on.
    func clientSession(of s: String) async -> String? {
        guard let tty = ws.pool.view(for: s)?.ttyName else { return nil }
        let args = (tmuxSocket.map { ["-L", $0] } ?? []) + ["list-clients", "-F", "#{client_tty} #{session_name}"]
        let out = ShellEnv.run(Paths.tmux, args, timeout: 2) ?? ""
        return out.split(separator: "\n").first { $0.hasPrefix(tty + " ") }.map { String($0.dropFirst(tty.count + 1)) }
    }

    func paneShows(_ session: String, _ text: String, timeout: Double = 3) async -> Bool {
        await waitUntil(timeout) { pane(session).contains(text) }
    }

    // MARK: Events

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49, "-": 27, ".": 47, "/": 44,
    ]

    func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = [], ignoring: String? = nil, window: NSWindow? = nil) async {
        let target = window ?? w
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: now, windowNumber: target.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: ignoring ?? chars,
                                           isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
        await sleep(40)
    }

    func cmd(_ c: Character, _ extra: NSEvent.ModifierFlags = []) async {
        let s = extra.contains(.shift) ? String(c).uppercased() : String(c)
        await key(TestKit.keyCodes[c] ?? 0, s, NSEvent.ModifierFlags.command.union(extra))
    }

    func arrow(_ code: UInt16, _ mods: NSEvent.ModifierFlags) async {
        let ch: String = [123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}"][code] ?? ""
        await key(code, ch, mods.union([.numericPad, .function]))
    }

    /// Type text as key presses; "\n" is Return.
    func type(_ text: String, window: NSWindow? = nil) async {
        for c in text {
            if c == "\n" {
                await key(36, "\r", window: window)
            } else {
                let lower = Character(c.lowercased())
                let shift = c.isUppercase
                await key(TestKit.keyCodes[lower] ?? 0, String(c), shift ? [.shift] : [], ignoring: String(c), window: window)
            }
        }
        await sleep(60)
    }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: now, windowNumber: w.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)
    }

    /// A click at a point in window coordinates.
    func click(_ p: NSPoint, right: Bool = false) async {
        if let d = mouse(right ? .rightMouseDown : .leftMouseDown, p), let u = mouse(right ? .rightMouseUp : .leftMouseUp, p) {
            NSApp.postEvent(d, atStart: false)
            NSApp.postEvent(u, atStart: false)
        }
        await sleep(80)
    }

    func move(_ p: NSPoint) async {
        if let e = mouse(.mouseMoved, p) { NSApp.postEvent(e, atStart: false) }
        await sleep(40)
    }

    // MARK: Geometry (window coordinates)

    func sidebarPoint(_ session: String, onName: Bool = true) -> NSPoint? {
        guard let item = app.sidebar.itemFor(session: session) else { return nil }
        let o = app.sidebar.outline
        let row = o.row(forItem: item)
        guard row >= 0 else { return nil }
        let rect = o.rect(ofRow: row)
        var p = NSPoint(x: rect.minX + (onName ? 70 : rect.width - 20), y: rect.midY)
        if onName, let cell = o.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView {
            let f = cell.nameField.frame
            p = o.convert(NSPoint(x: f.minX + 8, y: f.midY), from: cell)
        }
        return o.convert(p, to: nil)
    }

    func sectionPoint(_ id: String) -> NSPoint? {
        let o = app.sidebar.outline
        for row in 0..<o.numberOfRows {
            if let it = o.item(atRow: row) as? SidebarItem, it.kind == .section(id) {
                let r = o.rect(ofRow: row)
                return o.convert(NSPoint(x: r.minX + 40, y: r.midY), to: nil)
            }
        }
        return nil
    }

    func tileCenter(_ t: TileID) -> NSPoint? {
        guard let r = ws.tileRects[t] else { return nil }
        return ws.area.convert(NSPoint(x: r.midX, y: r.midY + 20), to: nil)
    }

    var firstResponderIsActiveTerminal: Bool {
        guard let t = ws.activeTerminal else { return false }
        return w.firstResponder === t
    }

    func showOnly(_ session: String) async {
        for _ in 0..<10 where ws.layout.count > 1 { ws.closeActive() }
        ws.show(session)
        await waitUntil(3) { ws.activeTerminal?.hasPaintedContent == true }
        await sleep(150)
    }
}

/// A drag that never left the app: what AppKit hands a drop destination.
final class FakeDrag: NSObject, NSDraggingInfo {
    let location: NSPoint
    let pasteboard: NSPasteboard
    weak var window: NSWindow?

    init(location: NSPoint, pasteboard: NSPasteboard, window: NSWindow) {
        self.location = location
        self.pasteboard = pasteboard
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

// MARK: - Focus test

@MainActor
final class FocusTest: TestKit {
    init(app: AppController) { super.init(app: app, report: "focustest.txt") }

    private var menuObserver: Any?

    func run() async {
        r.say("# Bosun focus test  \(Date())")
        app.enableTestKey()
        // Context menus run a modal loop; close each one shortly after it opens, as a person would.
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            let menu = note.object as? NSMenu
            nonisolated(unsafe) let m = menu
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { m?.cancelTracking() }
        }
        guard await waitUntil(10, { app.daemon.status == .connected && session("api") != nil }) else {
            r.check("connected to the test daemon with the fixture", false, "\(app.daemon.status)")
            r.save()
            return
        }
        app.focus.followsMouse = true
        guard let api = session("api"), let docs = session("docs"), let parser = session("parser"), let web = session("web"),
              let webTests = session("web tests"), let review1 = session("review-1"), let review2 = session("review-2") else {
            r.check("fixture sessions present", false)
            r.save()
            return
        }
        // Theme for screenshots: whatever the daemon has (opencode by default).
        await showOnly(api)
        r.check("start: the active terminal is first responder", firstResponderIsActiveTerminal)
        shot("01-single-tile")

        // 1. Click a sidebar row, then type.
        if let p = sidebarPoint(docs) { await click(p) }
        await waitUntil(2) { ws.activeSession == docs && ws.activeTerminal?.hasPaintedContent == true }
        r.check("sidebar click shows the session in the active tile", ws.activeSession == docs)
        r.check("sidebar click leaves the keyboard in the terminal", firstResponderIsActiveTerminal,
                "firstResponder=\(String(describing: w.firstResponder.map { Swift.type(of: $0) }))")
        await type("after-click\n")
        r.check("typing after a sidebar click reaches the pane", await paneShows(docs, "got: after-click"))

        // 2. Right-click menu, then type.
        if let p = sidebarPoint(parser) { await click(p, right: true) }
        await sleep(400)
        r.check("right-click menu doesn't move the keyboard", firstResponderIsActiveTerminal)
        await type("after-menu\n")
        r.check("typing after a context menu reaches the pane", await paneShows(docs, "got: after-menu"))

        // 3. Collapse a section, then type.
        let work = app.daemon.state.sidebar.sections.first { $0.name == "Work" }?.id ?? ""
        if let p = sectionPoint(work) { await click(p) }
        await waitUntil(2) { app.daemon.state.sidebar.sections.first { $0.id == work }?.collapsed == true }
        r.check("clicking a section header collapses it", app.daemon.state.sidebar.sections.first { $0.id == work }?.collapsed == true)
        r.check("collapsing leaves the keyboard in the terminal", firstResponderIsActiveTerminal)
        await type("after-collapse\n")
        r.check("typing after a collapse reaches the pane", await paneShows(docs, "got: after-collapse"))
        if let p = sectionPoint(work) { await click(p) }
        await waitUntil(2) { app.daemon.state.sidebar.sections.first { $0.id == work }?.collapsed == false }

        // 4. Rename in place (click the selected row's name), Return, then type.
        if let p = sidebarPoint(docs) { await click(p) }
        await waitUntil(2) { app.focus.exception == .rename }
        r.check("clicking the selected row's name starts a rename", app.focus.exception == .rename)
        r.check("the rename field has the keyboard", w.firstResponder is NSText)
        await type("Docs Two")
        shot("03-rename-in-progress")
        await type("\n")
        await waitUntil(3) { app.daemon.state.sessions[docs]?.display == "Docs Two" }
        r.check("Return commits the rename through the daemon", app.daemon.state.sessions[docs]?.display == "Docs Two")
        await waitUntil(1) { firstResponderIsActiveTerminal }
        r.check("after rename the keyboard is back in the terminal", firstResponderIsActiveTerminal)
        await type("after-rename\n")
        r.check("typing after rename reaches the pane", await paneShows(docs, "got: after-rename"))
        // Esc cancels.
        app.sidebar.beginRename(session: docs)
        await type("nope")
        await key(53, "\u{1b}")
        await sleep(100)
        r.check("Esc cancels a rename", app.daemon.state.sessions[docs]?.display == "Docs Two" && app.focus.exception == nil)
        r.check("after Esc the keyboard is back in the terminal", firstResponderIsActiveTerminal)
        app.daemon.command(.rename(session: docs, display: "docs"))

        // 5. Splits: Cmd+D, Cmd+Shift+D, Cmd+Option+Left, Cmd+Shift+D gives a 2x2 grid.
        await showOnly(api)
        await cmd("d")
        r.check("Cmd+D splits right", ws.layout.count == 2)
        await cmd("d", [.shift])
        r.check("Cmd+Shift+D splits down", ws.layout.count == 3)
        let before = ws.activeTile
        await arrow(123, [.command, .option])
        r.check("Cmd+Option+Left moves to the tile on the left", ws.activeTile != before && ws.activeSession == api)
        await cmd("d", [.shift])
        r.check("2x2 grid", ws.layout.count == 4)
        await waitUntil(3) { ws.layout.tiles.allSatisfy { ws.terminal(in: $0)?.hasPaintedContent == true } }
        let sessionsShown = Set(ws.layout.tiles.compactMap { ws.layout.session(in: $0) })
        r.check("each new tile shows a different session", sessionsShown.count == 4, "\(sessionsShown.count) distinct")
        r.check("after splitting the keyboard is in the new active tile", firstResponderIsActiveTerminal)
        shot("02-grid-2x2-ring")

        // 6. Focus follows the mouse: move into each tile, type, check that pane.
        var hoverOK = true
        for (i, t) in ws.layout.tiles.enumerated() {
            guard let c = tileCenter(t), let s = ws.layout.session(in: t) else { continue }
            await move(NSPoint(x: c.x - 3, y: c.y))
            await move(c)
            let ok = ws.activeTile == t && firstResponderIsActiveTerminal
            await type("hover\(i)\n")
            // The ticker fixture doesn't read input; it only needs to become active.
            let landed = app.displayName(s) == "ticker" ? true : await paneShows(s, "got: hover\(i)")
            if !ok || !landed { hoverOK = false; r.say("      tile \(t) (\(app.displayName(s))): active=\(ok) landed=\(landed)") }
        }
        r.check("the active ring follows the pointer and typing goes to the hovered tile", hoverOK)
        // Same point again (a tile moving under a still pointer) must not activate anything.
        let held = ws.activeTile
        if let other = ws.layout.tiles.first(where: { $0 != held }), let c = tileCenter(other) {
            app.focus.setWindowKey(true)
            await move(c)
            await move(c)
            ws.activate(held)
            await move(c)
            r.check("a pointer that didn't move doesn't activate a tile", ws.activeTile == held)
        }
        // Setting off: hover does nothing, a click activates and is consumed.
        app.focus.followsMouse = false
        let target = ws.layout.tiles.first { $0 != ws.activeTile && app.displayName(ws.layout.session(in: $0) ?? "") != "ticker" }!
        if let c = tileCenter(target) {
            await move(NSPoint(x: c.x + 5, y: c.y))
            r.check("with focus-follows-mouse off, hover doesn't activate", ws.activeTile != target)
            let ts = ws.layout.session(in: target)!
            let beforeClick = ws.terminal(in: target)?.contentsCount ?? 0
            await click(c)
            r.check("a click activates an inactive tile", ws.activeTile == target && firstResponderIsActiveTerminal)
            _ = beforeClick
            await type("clicked\n")
            r.check("typing after a tile click reaches that tile", await paneShows(ts, "got: clicked"))
        }
        app.focus.followsMouse = true

        // 7. A sidebar click for a session already in another tile activates that tile.
        let elsewhere = ws.layout.tiles.first { $0 != ws.activeTile }!
        let elsewhereSession = ws.layout.session(in: elsewhere)!
        if let p = sidebarPoint(elsewhereSession) { await click(p) }
        r.check("sidebar click on a session in another tile activates that tile", ws.activeTile == elsewhere)
        r.check("…and the session stays in one tile", ws.layout.sessions.values.filter { $0 == elsewhereSession }.count == 1)

        // 8. Drops.
        let file = NSTemporaryDirectory() + "bosun drop (test).png"
        FileManager.default.createFile(atPath: file, contents: Data([0x89, 0x50, 0x4e, 0x47]))
        let escaped = ShellEscape.escape(file)
        let pb = NSPasteboard(name: NSPasteboard.Name("dev.yetidevworks.bosun.test-drag"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: file) as NSURL])
        let dropTile = ws.layout.tiles.first { $0 != ws.activeTile && app.displayName(ws.layout.session(in: $0) ?? "") != "ticker" }!
        let dropSession = ws.layout.session(in: dropTile)!
        if let c = tileCenter(dropTile) {
            let info = FakeDrag(location: c, pasteboard: pb, window: w)
            let op = ws.area.draggingEntered(info)
            r.check("a file dragged over a tile is accepted (copy)", op == .copy)
            _ = ws.area.performDragOperation(info)
            await sleep(150)
            r.check("a drop activates the tile under the pointer", ws.activeTile == dropTile)
            await type("\n")
            r.check("the dropped path is inserted, shell-escaped, into that tile", await paneShows(dropSession, "got: \(escaped)"))
        }
        // Over a divider: refused.
        if let d = ws.area.subviews.first(where: { $0 is DividerView }) {
            let p = ws.area.convert(NSPoint(x: d.frame.midX, y: d.frame.midY), to: nil)
            r.check("a drop on a divider is refused", ws.area.draggingUpdated(FakeDrag(location: p, pasteboard: pb, window: w)) == [])
            ws.area.draggingExited(nil)
        }
        // Image data that isn't a file: written to a temp file first.
        let imgPB = NSPasteboard(name: NSPasteboard.Name("dev.yetidevworks.bosun.test-drag-image"))
        imgPB.clearContents()
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        imgPB.writeObjects([img])
        if let t = ws.layout.tiles.first(where: { app.displayName(ws.layout.session(in: $0) ?? "") != "ticker" }), let c = tileCenter(t),
           let s = ws.layout.session(in: t) {
            _ = ws.area.performDragOperation(FakeDrag(location: c, pasteboard: imgPB, window: w))
            await sleep(150)
            await type("\n")
            let ok = await waitUntil(3) { pane(s).contains("got: ") && pane(s).contains("/drops/drop-") }
            r.check("image data (not a file) is written to a temp file and its path inserted", ok)
        }
        // Sidebar: a drop on a session row shows it in the active tile and inserts there; elsewhere refused.
        let sb: SidebarController = app.sidebar
        if let rowItem = sb.itemFor(session: review1) {
            let o = sb.outline
            let rowPoint = o.convert(NSPoint(x: o.rect(ofRow: o.row(forItem: rowItem)).midX, y: o.rect(ofRow: o.row(forItem: rowItem)).midY), to: nil)
            let info = FakeDrag(location: rowPoint, pasteboard: pb, window: w)
            let op = sb.outlineView(o, validateDrop: info, proposedItem: rowItem, proposedChildIndex: NSOutlineViewDropOnItemIndex)
            r.check("a file dragged over a sidebar session row is accepted", op == .copy)
            let activeBefore = ws.activeTile
            _ = sb.outlineView(o, acceptDrop: info, item: rowItem, childIndex: NSOutlineViewDropOnItemIndex)
            await waitUntil(3) { ws.activeSession == review1 && ws.activeTerminal?.hasPaintedContent == true }
            r.check("a drop on a sidebar row shows that session in the active tile", ws.activeSession == review1 && ws.activeTile == activeBefore)
            await sleep(300)
            await type("\n")
            r.check("…and inserts the path there", await paneShows(review1, "got: \(escaped)"))
            let bg = FakeDrag(location: o.convert(NSPoint(x: 40, y: o.bounds.height - 5), to: nil), pasteboard: pb, window: w)
            r.check("a drop on the sidebar background is refused", sb.outlineView(o, validateDrop: bg, proposedItem: nil, proposedChildIndex: 2) == [])
            let secItem = o.item(atRow: (0..<o.numberOfRows).first { (o.item(atRow: $0) as? SidebarItem)?.kind == .section(work) } ?? 0)
            let secPoint = sectionPoint(work) ?? .zero
            r.check("a drop on a section header is refused",
                    sb.outlineView(o, validateDrop: FakeDrag(location: secPoint, pasteboard: pb, window: w), proposedItem: secItem, proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        }

        // 9. Palette.
        await cmd("k")
        r.check("Cmd+K opens the palette", app.paletteOpen && app.focus.exception == .palette)
        r.check("the palette field has the keyboard", w.firstResponder is NSText)
        await type("pars")
        shot("04-palette")
        await type("\n")
        await waitUntil(2) { ws.activeSession == parser }
        r.check("Return in the palette shows the match", ws.activeSession == parser && !app.paletteOpen)
        await waitUntil(1) { firstResponderIsActiveTerminal }
        r.check("after the palette the keyboard is back in the terminal", firstResponderIsActiveTerminal)
        await waitUntil(2) { ws.activeTerminal?.hasPaintedContent == true }
        await type("after-palette\n")
        r.check("typing after the palette reaches the pane", await paneShows(parser, "got: after-palette"))
        await cmd("k")
        await key(53, "\u{1b}")
        r.check("Esc closes the palette and returns the keyboard", !app.paletteOpen && firstResponderIsActiveTerminal)
        await cmd("k")
        if let p = tileCenter(ws.activeTile) { await click(NSPoint(x: p.x, y: 60)) }
        r.check("a click outside closes the palette", !app.paletteOpen && app.focus.exception == nil)

        // 10. Navigation keys from [keybindings] (defaults: Shift+Up/Down sessions, Shift+Left/Right tabs, Ctrl+v send next).
        for _ in 0..<10 where ws.layout.count > 1 { ws.closeActive() }
        r.check("Cmd+W path: tiles close down to one", ws.layout.count == 1)
        await showOnly(api)
        let order = app.daemon.state.sidebar.cycleOrder(isAlive: app.isAlive)
        await arrow(125, [.shift])
        r.check("Shift+Down shows the next session in sidebar order", ws.activeSession == Sidebar.cycle(order, from: api, forward: true),
                "now \(ws.activeSession.map(app.displayName) ?? "-")")
        r.check("…without the key reaching the terminal", !pane(api).contains("[1;2B"))
        await arrow(126, [.shift])
        r.check("Shift+Up goes back", ws.activeSession == api)
        app.show(web)
        await waitUntil(2) { ws.activeTerminal?.hasPaintedContent == true }
        await arrow(124, [.shift])
        r.check("Shift+Right moves to the next tab in the row", ws.activeSession == webTests,
                "now \(ws.activeSession.map(app.displayName) ?? "-"), row tabs \(app.daemon.state.sidebar.container(holding: web)?.tabs.map { app.displayName($0.session) } ?? [])")
        await waitUntil(2) { app.daemon.state.sidebar.container(holding: web)?.active == webTests }
        r.check("…and the row remembers its active tab", app.daemon.state.sidebar.container(holding: web)?.active == webTests)
        await arrow(123, [.shift])
        r.check("Shift+Left moves back", ws.activeSession == web)
        await waitUntil(2) { ws.activeTerminal?.hasPaintedContent == true }
        await key(9, "\u{16}", [.control], ignoring: "v")
        await arrow(125, [.shift])
        await sleep(200)
        await type("\n")
        let passed = await paneShows(web, "got: [1;2B")
        r.check("Ctrl+v then Shift+Down sends the key to the program instead of navigating", ws.activeSession == web && passed)
        let on = await clientSession(of: web)
        r.check("…and tmux kept the client on its session", on == web, "client on \(on ?? "-")")

        // 11. Cmd+1…9, Cmd+Shift+U, Cmd+W.
        let rows = app.daemon.state.sidebar.visibleRows
        await cmd("2")
        r.check("Cmd+2 jumps to the second row", ws.activeSession == rows[1].active)
        await cmd("1")
        r.check("Cmd+1 jumps to the first row", ws.activeSession == rows[0].active)
        tmux(["set-option", "-p", "-t", "=\(review2):", "@bosun_state", "waiting"])
        tmux(["set-option", "-p", "-t", "=\(review2):", "@bosun_state_at", "\(Int(Date().timeIntervalSince1970 * 1000))"])
        tmux(["set-option", "-p", "-t", "=\(review2):", "@bosun_state_detail", "permission: Bash"])
        await waitUntil(3) { app.daemon.state.state(of: review2) == .waiting }
        let oldest = app.oldestWaiting
        await cmd("u", [.shift])
        r.check("Cmd+Shift+U shows the oldest waiting session", ws.activeSession == oldest && oldest != nil,
                "oldest \(oldest.map(app.displayName) ?? "-"), shown \(ws.activeSession.map(app.displayName) ?? "-")")
        await waitUntil(2) { ws.activeTerminal?.hasPaintedContent == true }
        await cmd("d")
        await cmd("w")
        r.check("Cmd+W closes a tile (the session keeps running)", ws.layout.count == 1 && app.isAlive(review2))
        tmux(["set-option", "-p", "-t", "=\(review2):", "@bosun_state", "idle"])
        tmux(["set-option", "-p", "-t", "=\(review2):", "@bosun_state_detail", ""])

        // 12. Ghostty bindings that clash with app shortcuts never fire in the terminal.
        await showOnly(api)
        let fr = (w.firstResponder as? TerminalView)?.session
        r.check("showing a session puts its terminal first", ws.activeSession == api && fr == api,
                "active=\(ws.activeSession.map(app.displayName) ?? "-") firstResponder=\(fr.map(app.displayName) ?? String(describing: w.firstResponder))")
        await type("clash-check\n")
        _ = await paneShows(api, "got: clash-check")
        await cmd("k")
        await key(53, "\u{1b}")
        r.check("Cmd+K opens the palette instead of Ghostty's clear-screen", pane(api).contains("clash-check"))

        // 13. New-session sheet: Cmd+Shift+N, then Esc returns the keyboard.
        await cmd("n", [.shift])
        await waitUntil(2) { app.sheetOpen }
        r.check("Cmd+Shift+N opens the new-session sheet", app.sheetOpen && app.focus.exception == .sheet)
        await sleep(400)
        shot("05-new-session-sheet")
        if let sheet = w.attachedSheet { await key(53, "\u{1b}", window: sheet) }
        await waitUntil(2) { !app.sheetOpen }
        await waitUntil(1) { firstResponderIsActiveTerminal }
        r.check("closing the sheet returns the keyboard to the terminal", !app.sheetOpen && firstResponderIsActiveTerminal)
        await type("after-sheet\n")
        r.check("typing after the sheet reaches the pane", await paneShows(api, "got: after-sheet"))

        // 14. Create, then kill, a session through the app (the sheet's submit path).
        var spec = Spec(name: "temp-focus", path: "~", agent: "terminal", args: "python3 \(fakeAgentPath) temp")
        spec.containerID = nil
        app.daemon.command(.create(spec: spec, deferLaunch: true)) { [app] ack in
            if let s = ack.session { app.show(s) }
            if let p = ack.pendingLaunch { app.workspace.expectLaunch(p.session, resume: p.resume) }
        }
        await waitUntil(5) { session("temp-focus") != nil && ws.activeSession == session("temp-focus") }
        let temp = session("temp-focus")
        r.check("create (deferred launch) shows the new session", temp != nil && ws.activeSession == temp)
        if let temp {
            r.check("the agent launches once the terminal is attached", await paneShows(temp, "fake agent · temp", timeout: 6))
            app.daemon.command(.kill(session: temp))
            await waitUntil(5) { !app.isAlive(temp) }
            r.check("kill ends the session", !app.isAlive(temp))
            if let c = app.daemon.state.sidebar.container(holding: temp) { app.removeRow(c.id) }
        }

        // 15. Themes: a light and a dark one for the screenshots, then back.
        let original = app.daemon.state.theme.name
        await showOnly(api)
        await cmd("d")
        await waitUntil(3) { ws.layout.tiles.allSatisfy { ws.terminal(in: $0)?.hasPaintedContent == true } }
        for (name, file) in [("github-light", "06-theme-light"), ("tokyonight", "07-theme-dark")] {
            app.daemon.command(.setTheme(name: name, persist: false))
            await waitUntil(3) { app.daemon.state.theme.name == name }
            await sleep(300)
            r.check("theme \(name) applies to the chrome", app.theme.palette.name == name)
            shot(file)
        }
        app.daemon.command(.setTheme(name: original, persist: false))
        await waitUntil(3) { app.daemon.state.theme.name == original }
        for _ in 0..<10 where ws.layout.count > 1 { ws.closeActive() }

        // Nothing above may have moved a tmux client to another session (Bosun's tmux bindings can).
        var drift: [String] = []
        for (s, v) in ws.pool.views where !v.exited {
            if let on = await clientSession(of: s), on != s { drift.append("\(app.displayName(s)) -> \(app.displayName(on))") }
        }
        r.check("every terminal's tmux client is still on its own session", drift.isEmpty, drift.joined(separator: ", "))

        r.say("")
        r.say("\(r.failures == 0 ? "ALL PASSED" : "\(r.failures) FAILED")")
        r.save()
        r.say("saved \(r.path)")
    }

    var fakeAgentPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixture/fake_agent.py").path
    }
}

// MARK: - Self-test (budgets, design section 1)

@MainActor
final class SelfTest: TestKit {
    init(app: AppController) { super.init(app: app, report: "selftest.txt") }

    func stats(_ name: String, _ xs: [Double], budget: Double? = nil) {
        let p50 = Stats.percentile(xs, 50), p99 = Stats.percentile(xs, 99)
        var line = String(format: "%@: n=%d  p50=%@  p90=%@  p99=%@  max=%@", name, xs.count, fmtMs(p50), fmtMs(Stats.percentile(xs, 90)),
                          fmtMs(p99), fmtMs(xs.max() ?? .nan))
        if let budget { line += "   budget \(fmtMs(budget)): \(p99 <= budget ? "met at p99" : p50 <= budget ? "met at p50 only" : "MISSED")" }
        r.say(line)
    }

    func run() async {
        app.enableTestKey()
        r.say("# Bosun self-test  \(Date())")
        r.say("display: \(w.screen?.maximumFramesPerSecond ?? 0) Hz max, backing scale \(w.backingScaleFactor), screen \(NSScreen.screens.isEmpty ? "none" : "present")")
        guard await waitUntil(10, { app.daemon.status == .connected && app.daemon.state.sessionOrder.count >= 6 }) else {
            r.say("ERROR: need the dev.sh fixture (6+ sessions)")
            r.save()
            return
        }
        r.say("launch (this process): sidebar painted \(fmtMs(app.sidebarPaintedAt ?? .nan)), first live terminal \(fmtMs(app.firstTerminalAt ?? .nan))")
        let all = app.daemon.state.sidebar.cycleOrder(isAlive: app.isAlive)
        var samples: [(String, Bool, Double, Double?)] = []
        ws.onShowMeasured = { samples.append(($0, $1, $2, $3)) }

        // Warm switches: 4 attached sessions, 100 swaps.
        await showOnly(all[0])
        let warmSet = Array(all.prefix(4))
        for s in warmSet { ws.show(s); await waitUntil(3) { ws.activeTerminal?.hasPaintedContent == true }; await sleep(100) }
        samples.removeAll()
        for i in 0..<100 {
            ws.show(warmSet[(i + 1) % 4])
            await waitUntil(1) { samples.count > i }
            await sleep(30)
        }
        let warm = samples.filter(\.1).map(\.2)
        r.say("")
        stats("warm switch -> first frame", warm, budget: 0.016)

        // Cold attaches.
        samples.removeAll()
        for i in 0..<20 {
            let s = all[4 + (i % max(1, all.count - 4))]
            let other = all[i % 4]
            ws.show(other)
            await sleep(50)
            ws.pool.drop(s)
            await sleep(250)
            let n = samples.count
            ws.show(s)
            await waitUntil(3) { samples.count > n && samples.last?.1 == false }
            await sleep(100)
        }
        let cold = samples.filter { !$0.1 }
        stats("cold attach -> first frame", cold.map(\.2))
        stats("cold attach -> tmux painted (attach -> first frame with content)", cold.compactMap(\.3), budget: 0.080)

        // Status change -> badge, through the daemon's 250 ms poll.
        var badge: [Double] = []
        let target = all.last { !ws.visibleSessions.contains($0) } ?? all[all.count - 1]
        var applied: (String, AgentState, CFTimeInterval)?
        app.sidebar.onBadgeApplied = { s, st in if s == target { applied = (s, st, CACurrentMediaTime()) } }
        for i in 0..<20 {
            let state = i % 2 == 0 ? "waiting" : "idle"
            let want: AgentState = i % 2 == 0 ? .waiting : .idle
            applied = nil
            let t0 = CACurrentMediaTime()
            let sock = tmuxSocket
            let ms = "\(Int(Date().timeIntervalSince1970 * 1000))"
            DispatchQueue.global().async {
                TmuxCLI.run(socket: sock, ["set-option", "-p", "-t", "=\(target):", "@bosun_state", state, ";",
                                            "set-option", "-p", "-t", "=\(target):", "@bosun_state_at", ms])
            }
            if await waitUntil(3, { applied?.1 == want }), let a = applied { badge.append(a.2 - t0) }
            await sleep(120)
        }
        stats("status change (tmux option set) -> sidebar badge", badge, budget: 0.250)
        app.sidebar.onBadgeApplied = nil

        // Daemon round trip.
        var rtt: [Double] = []
        for _ in 0..<50 {
            let t0 = CACurrentMediaTime()
            _ = await app.daemon.request(.getSpec(session: all[0]))
            rtt.append(CACurrentMediaTime() - t0)
        }
        stats("daemon round trip (get_spec -> ack)", rtt)

        // Divider drag: layout cost per step at 120 Hz.
        await showOnly(all[0])
        ws.split(.horizontal)
        await waitUntil(3) { ws.layout.tiles.allSatisfy { ws.terminal(in: $0)?.hasPaintedContent == true } }
        var steps: [Double] = []
        if let d = ws.area.subviews.compactMap({ $0 as? DividerView }).first?.divider {
            ws.dividerDragBegan()
            for i in 0...120 {
                let p = Double(i) / 120
                let x = d.container.minX + d.container.width * (0.5 - 0.25 * sin(p * .pi))
                let t0 = CACurrentMediaTime()
                ws.dividerDragged(d, to: NSPoint(x: x, y: d.container.midY))
                ws.area.layoutSubtreeIfNeeded()
                steps.append(CACurrentMediaTime() - t0)
                await sleep(1000.0 / 120)
            }
            ws.dividerDragEnded()
        }
        stats("divider drag: layout per step", steps, budget: 0.0083)

        // Idle CPU with 4 tiles.
        ws.split(.vertical)
        ws.activate(ws.layout.tiles[0])
        ws.split(.vertical)
        await waitUntil(3) { ws.layout.tiles.allSatisfy { ws.terminal(in: $0)?.hasPaintedContent == true } }
        await sleep(2000)
        let c0 = cpuSeconds(), t0 = Date()
        await sleep(20_000)
        let pct = (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100
        r.say(String(format: "idle CPU, %d tiles, %d views attached: %.2f%% of one core over 20 s   budget 0.5%%: %@",
                     ws.layout.count, ws.pool.views.count, pct, pct <= 0.5 ? "met" : "MISSED"))
        r.say(String(format: "memory footprint: %.0f MB with %d terminal views", physFootprintMB(), ws.pool.views.count))
        for _ in 0..<10 where ws.layout.count > 1 { ws.closeActive() }

        // Launch: separate processes, each reporting sidebar painted and first live terminal.
        r.say("")
        var sidebarT: [Double] = [], terminalT: [Double] = []
        let exe = Bundle.main.executablePath!
        for _ in 0..<10 {
            let out = await Task.detached { () -> String in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["--launchprobe", "-ApplePersistenceIgnoreState", "YES"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                try? p.run()
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: d, as: UTF8.self)
            }.value
            for line in out.split(separator: "\n") where line.hasPrefix("launchprobe ") {
                let f = line.split(separator: " ")
                if f.count >= 3, let a = Double(f[1]), let b = Double(f[2]) { sidebarT.append(a); terminalT.append(b) }
            }
        }
        stats("launch -> sidebar painted (cached snapshot)", sidebarT, budget: 0.300)
        stats("launch -> first live terminal", terminalT, budget: 0.500)
        r.save()
        r.say("saved \(r.path)")
    }
}

/// Started by the self-test: report launch timings, then quit.
@MainActor
final class LaunchProbe {
    let app: AppController
    init(app: AppController) { self.app = app }

    func run() {
        app.onFirstTerminal = { [app] in
            print("launchprobe \(app.sidebarPaintedAt ?? -1) \(app.firstTerminalAt ?? -1)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
    }
}

func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
