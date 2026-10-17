import AppKit
import BosunCore
import CoreGraphics

/// Real input for `--realtest`: CGEvents through the window server, the way a mouse makes them, so tracking
/// areas, drag sessions and window activation all take part. The focus test posts into the app's own queue,
/// which skips all three (2.2.3's sidebar drags that died on their first move, and focus following the pointer,
/// both lived there). It moves the real pointer, so it stops the moment the pointer is somewhere it didn't put it.
@MainActor
enum RealInput {
    struct Stopped: Error { let reason: String }
    private static var last: CGPoint?

    /// A window point as a global point (top-left origin, as CGEvents use).
    static func global(_ p: NSPoint, in window: NSWindow) -> CGPoint {
        let s = window.convertPoint(toScreen: p)
        return CGPoint(x: s.x, y: (NSScreen.screens.first?.frame.height ?? 0) - s.y)
    }

    static var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Nobody else is moving the pointer: it's where the last event put it.
    static func checkUntouched() throws {
        guard let last else { return }
        let p = pointer
        guard abs(p.x - last.x) <= 3, abs(p.y - last.y) <= 3 else {
            throw Stopped(reason: "the pointer is at \(Int(p.x)),\(Int(p.y)), not \(Int(last.x)),\(Int(last.y)): stopped so as not to fight you")
        }
    }

    /// `window` is the front window at a global point, so an event there can only reach it.
    static func checkFront(_ p: CGPoint, _ window: NSWindow) throws {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let d = info[kCGWindowBounds as String], let b = CGRect(dictionaryRepresentation: d as! CFDictionary), b.contains(p) else { continue }
            if (info[kCGWindowNumber as String] as? Int) == window.windowNumber { return }
            throw Stopped(reason: "another window (\(info[kCGWindowOwnerName as String] as? String ?? "?")) is in front at \(Int(p.x)),\(Int(p.y))")
        }
        throw Stopped(reason: "no window at \(Int(p.x)),\(Int(p.y))")
    }

    static func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
        e.post(tap: .cghidEventTap)
        last = p
    }

    /// Bring this app to the front. Since macOS 14 an app can't take activation for itself (`NSApp.activate()`
    /// only asks), and one started from a terminal never gets it; System Events can, with the Accessibility
    /// access that posting input needs anyway.
    static func bringAppForward() {
        NSApp.activate()
        let pid = ProcessInfo.processInfo.processIdentifier
        _ = ShellEnv.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(pid)) to true"],
                         timeout: 5)
    }

    /// Put the pointer back without the checks (the end of a run, or after a stop).
    static func park(_ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        last = nil
    }
}

extension FocusTest {
    // MARK: Real input

    /// Move the real pointer to a window point in small steps (a drag when `dragging`).
    func realMove(to p: NSPoint, steps: Int = 14, dragging: Bool = false) async throws {
        let to = RealInput.global(p, in: w)
        try RealInput.checkFront(to, w)
        let from = RealInput.pointer
        for i in 1...steps {
            try RealInput.checkUntouched()
            let t = CGFloat(i) / CGFloat(steps)
            RealInput.post(dragging ? .leftMouseDragged : .mouseMoved, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            await sleep(12)
        }
        await sleep(60)
    }

    func realClick(_ p: NSPoint, clicks: Int = 1) async throws {
        try await realMove(to: p)
        let g = RealInput.global(p, in: w)
        for n in 1...clicks {
            try RealInput.checkUntouched()
            RealInput.post(.leftMouseDown, g, clicks: Int64(n))
            await sleep(30)
            RealInput.post(.leftMouseUp, g, clicks: Int64(n))
            await sleep(n < clicks ? 60 : 150)
        }
    }

    /// Press at `from`, move past the drag threshold, travel to `to`, rest there (so the drop is checked
    /// where the pointer stops), and let go.
    func realDrag(from: NSPoint, to: NSPoint) async throws {
        try RealInput.checkFront(RealInput.global(to, in: w), w)
        try await realMove(to: from)
        let g = RealInput.global(from, in: w)
        RealInput.post(.leftMouseDown, g)
        await sleep(80)
        for i in 1...4 {
            RealInput.post(.leftMouseDragged, CGPoint(x: g.x + CGFloat(i), y: g.y + CGFloat(i) * 2))
            await sleep(16)
        }
        try await realMove(to: to, steps: 24, dragging: true)
        await sleep(250)
        try RealInput.checkUntouched()
        RealInput.post(.leftMouseUp, RealInput.global(to, in: w))
        await sleep(400)
    }

    func runReal() async {
        r.say("# Bosun real-input test  \(Date())")
        r.say("Real input: this moves your pointer. Hands off the mouse and keyboard until it's done (about a minute);")
        r.say("moving the pointer yourself stops it.")
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            r.check("allowed to post input (System Settings → Privacy & Security → Accessibility, for the app that started this)", false)
            r.save()
            return
        }
        guard await waitUntil(10, { app.daemon.status == .connected && session("api") != nil }),
              let api = session("api"), let docs = session("docs"), let parser = session("parser"), let web = session("web"),
              let webTests = session("web tests"), let webShell = session("web shell"),
              let review1 = session("review-1"), let review2 = session("review-2"),
              rowID(web) != nil, rowID(webTests) == rowID(web), rowID(webShell) == rowID(web) else {
            r.check("fixture sessions present, with web, web tests and web shell as the three tabs of one row (./dev.sh up)", false)
            r.save()
            return
        }
        let f = Fixture(api: api, docs: docs, parser: parser, web: web, webTests: webTests, webShell: webShell, review1: review1, review2: review2)
        RealInput.bringAppForward()
        app.bringForward(app.windows[0])
        await waitUntil(3) { NSApp.isActive && w.isKeyWindow }
        r.check("real: the app is active with its window key", NSApp.isActive && w.isKeyWindow)
        app.focus.followsMouse = true
        let original = app.daemon.state.sidebar
        let start = RealInput.pointer
        r.say("starting in 3 s")
        await sleep(3000)
        do {
            try await realFocus(f)
            try await realSidebarDrag(f)
            // The sidebar drags merged and split rows: the fixture's rows again before the pane drag.
            app.daemon.saveSidebar(original)
            await waitUntil(3) { app.daemon.state.sidebar == original }
            try await realTileDrag(f)
            try await stillFollows("after the drags", f)
        } catch let stop as RealInput.Stopped {
            r.check("real input ran to the end", false, stop.reason)
        } catch {
            r.check("real input ran to the end", false, "\(error)")
        }
        RealInput.park(start)
        if app.daemon.state.sidebar != original {
            app.daemon.saveSidebar(original)
            await waitUntil(3) { app.daemon.state.sidebar == original }
        }
        r.check("real: the sidebar is put back as it was", app.daemon.state.sidebar == original)
        r.say("")
        r.say("\(r.failures == 0 ? "ALL PASSED" : "\(r.failures) FAILED")")
        r.save()
        r.say("saved \(r.path)")
    }

    // MARK: Focus follows the pointer

    private func realFocus(_ f: Fixture) async throws {
        await showRow(f.web)
        await waitUntil(3) { ws.layout.count == 3 }
        let panes = ws.layout.panes
        for t in Array(panes.dropFirst()) + [panes[0]] {
            guard let c = tileCenter(t) else { continue }
            try await realMove(to: c)
            await waitUntil(1.5) { ws.activeSession == t }
            r.check("real: the pointer moving into \(app.displayName(t)) makes it active", ws.activeSession == t,
                    "active \(ws.activeSession.map(app.displayName) ?? "-")")
            r.check("…with the keyboard", firstResponderIsActiveTerminal)
        }

        // Whatever borrows the window or the keyboard for a while, the pointer moves focus again afterwards.
        try await stillFollows("after Settings opened and closed", f) {
            app.showSettings()
            await waitUntil(2) { NSApp.keyWindow != nil && NSApp.keyWindow !== w }
            NSApp.keyWindow?.performClose(nil)
            await waitUntil(2) { w.isKeyWindow }
        }
        try await stillFollows("after switching to Finder and clicking back into a pane", f) {
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
            await waitUntil(3) { !NSApp.isActive }
            // Back with a click on a pane, as a person would; if Finder's windows now cover it, by activating.
            if let p = tileCenter(ws.activeTile ?? ""), (try? RealInput.checkFront(RealInput.global(p, in: w), w)) != nil {
                try await realClick(p)
            } else {
                RealInput.bringAppForward()
            }
            await waitUntil(3) { NSApp.isActive && w.isKeyWindow }
        }
        try await stillFollows("after the palette (Cmd+K, Esc)", f) {
            await cmd("k")
            await waitUntil(2) { app.paletteOpen }
            await key(53, "\u{1b}")
            await waitUntil(2) { !app.paletteOpen }
        }
        try await stillFollows("after a rename (double-click on a tab's name, Esc)", f) {
            if let p = sidebarPoint(f.webTests) { try await realClick(p, clicks: 2) }
            await waitUntil(2) { app.focus.exception == .rename }
            r.check("real: a double-click on a tab's name starts a rename", app.focus.exception == .rename)
            await key(53, "\u{1b}")
            await waitUntil(2) { app.focus.exception == nil }
        }
        try await stillFollows("after the new-tab sheet (Cmd+T, Esc)", f) {
            await cmd("t")
            await waitUntil(2) { app.sheetOpen }
            await key(53, "\u{1b}")
            await waitUntil(2) { !app.sheetOpen }
        }
        try await stillFollows("after clicking another row in the sidebar and back", f) {
            if let p = sidebarPoint(f.api) { try await realClick(p) }
            await waitUntil(2) { ws.activeSession == f.api }
            if let p = sidebarPoint(f.web) { try await realClick(p) }
            await waitUntil(3) { ws.layout.count == 3 }
        }
    }

    /// After `setup`, moving the pointer into a pane that isn't active makes it active.
    private func stillFollows(_ label: String, _ f: Fixture, _ setup: () async throws -> Void = {}) async throws {
        try await setup()
        if ws.layout.count < 3 { await showRow(f.web) }
        await sleep(200)
        guard let t = ws.layout.panes.first(where: { $0 != ws.activeSession }), let c = tileCenter(t) else {
            r.check("real: focus follows the pointer \(label)", false, "no other pane to move to")
            return
        }
        try await realMove(to: c)
        await waitUntil(1.5) { ws.activeSession == t }
        r.check("real: focus follows the pointer \(label)", ws.activeSession == t,
                "active \(ws.activeSession.map(app.displayName) ?? "-"), key \(w.isKeyWindow), exception \(String(describing: app.focus.exception))")
    }

    // MARK: Sidebar drags

    private func realSidebarDrag(_ f: Fixture) async throws {
        func names(_ cs: [Container]) -> [String] { cs.map { app.displayName($0.active) } }
        await showRow(f.review1)

        // A row onto the lower edge of the next one: reordered.
        if let from = rowPoint(rowItem(f.api), 0.5), let to = rowPoint(rowItem(f.docs), 0.92) {
            try await realDrag(from: from, to: to)
            await waitUntil(2) { names(app.daemon.state.sidebar.ungrouped) == ["docs", "api"] }
            r.check("real: a row dragged below the next one is reordered (the drag follows the pointer)",
                    names(app.daemon.state.sidebar.ungrouped) == ["docs", "api"], "\(names(app.daemon.state.sidebar.ungrouped))")
        }
        // A row onto the upper half of a multi-tab row's tab: merged just before that tab.
        if let shell = session("shell"), let webTab = app.sidebar.itemFor(session: f.web),
           let from = rowPoint(rowItem(shell), 0.5), let to = rowPoint(webTab, 0.3, x: 80) {
            try await realDrag(from: from, to: to)
            await waitUntil(2) { app.daemon.state.sidebar.container(holding: f.web)?.tabs.contains { $0.session == shell } == true }
            let tabs = app.daemon.state.sidebar.container(holding: f.web)?.tabs.map { app.displayName($0.session) } ?? []
            let shellAt = tabs.firstIndex(of: "shell"), webAt = tabs.firstIndex(of: "web")
            r.check("real: a row dropped on a tab's upper half merges in before that tab",
                    shellAt != nil && webAt != nil && shellAt! < webAt!, "\(tabs)")
        }
        // A tab dragged out to the top edge of a row in a section: a row of its own just above it.
        if let tabItem = app.sidebar.itemFor(session: f.webShell),
           let from = rowPoint(tabItem, 0.5, x: 80), let to = rowPoint(rowItem(f.parser), 0.1) {
            try await realDrag(from: from, to: to)
            await waitUntil(2) { app.daemon.state.sidebar.container(holding: f.webShell)?.tabs.count == 1 }
            let work = app.daemon.state.sidebar.sections.first { $0.name == "Work" }.map { names($0.members) } ?? []
            let at = work.firstIndex(of: "web shell"), parserAt = work.firstIndex(of: "parser")
            r.check("real: a tab dragged out to a row's edge in a section becomes a row there",
                    at != nil && parserAt != nil && at! + 1 == parserAt!, "Work: \(work)")
        }
        // A section header dragged above another section.
        if let from = rowPoint(sectionItem("Reviews"), 0.5), let to = rowPoint(sectionItem("Work"), 0.15) {
            try await realDrag(from: from, to: to)
            await waitUntil(2) { app.daemon.state.sidebar.sections.first?.name == "Reviews" }
            r.check("real: a section dragged above another moves there", app.daemon.state.sidebar.sections.first?.name == "Reviews",
                    "\(app.daemon.state.sidebar.sections.map(\.name))")
        }
    }

    // MARK: Pane drags

    private func realTileDrag(_ f: Fixture) async throws {
        await showRow(f.web)
        await waitUntil(3) { ws.layout.count >= 3 }
        let panes = ws.layout.panes
        guard panes.count >= 2, let from = headerPoint(panes[0]), let to = zonePoint(panes[1], .swap) else { return }
        let expected = ws.layout.root?.moving(panes[0], to: panes[1], zone: .swap)
        try await realDrag(from: from, to: to)
        await waitUntil(2) { ws.layout.root == expected }
        r.check("real: a pane dragged by its header onto another's middle swaps them", expected != nil && ws.layout.root == expected,
                "\(ws.layout.panes.map(app.displayName))")
        r.check("…and the dragged pane is active with the keyboard", ws.activeSession == panes[0] && firstResponderIsActiveTerminal)
    }
}
