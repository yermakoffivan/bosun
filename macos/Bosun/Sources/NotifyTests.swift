import AppKit
import BosunCore

// Focus-test section for notifications (design 10): a fixture session driven to waiting and to done through
// Claude's hooks while it isn't on screen, what the notification says and where a click on it goes, the Dock
// badge, that a pane you're looking at in the frontmost app never notifies, the settings, Cmd+Shift+U, and the
// saved input times. Notifications go to a recorder in the test modes, never to Notification Center, and
// whether the window is in front of you is injected (`AppController.windowSeen`).

extension FocusTest {
    private var recorder: RecordingNotifier? { app.notifier as? RecordingNotifier }

    private func permission(_ s: String, tool: String = "Bash") async -> Bool {
        await claudeHook(s, "PermissionRequest", #"{"hook_event_name":"PermissionRequest","tool_name":"\#(tool)","tool_input":{"command":"ls"}}"#)
    }

    private func toolDone(_ s: String) async {
        _ = await claudeHook(s, "PostToolUse", #"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#)
        await waitUntil(3) { app.daemon.state.state(of: s) == .running }
    }

    private func stop(_ s: String) async -> Bool {
        await claudeHook(s, "Stop", #"{"hook_event_name":"Stop","stop_hook_active":false}"#)
    }

    /// Back to idle from the hook (the fixture's resting state).
    private func settle(_ s: String) async {
        _ = await claudeHook(s, "SessionStart", #"{"hook_event_name":"SessionStart"}"#)
    }

    private var waitingCount: Int {
        Attention.badgeCount(statuses: app.daemon.state.statuses) { app.isAlive($0) }
    }

    private func describe(_ n: AppNotification?) -> String {
        guard let n else { return "none" }
        return "“\(n.title)” / “\(n.subtitle)” / “\(n.body)” → \(app.displayName(n.session))"
    }

    func notifications(_ f: Fixture) async {
        guard let rec = recorder else {
            r.check("notify: the test modes record notifications instead of posting them", false)
            return
        }
        let realSeen = app.windowSeen
        // As if another app were in front: nothing is visible to you.
        app.windowSeen = { false }
        rec.reset()
        await showRow(f.api)
        let before = waitingCount
        let updatesBefore = app.dockBadgeUpdates

        // 1. A wait in a session that isn't on screen.
        let s = f.review1
        let id = Attention.id(.waiting, s)
        r.check("notify: bosun hook claude PermissionRequest runs in review-1's pane (another row)", await permission(s))
        let posted = await waitUntil(3) { rec.delivered[id] != nil }
        let n = rec.delivered[id]
        r.check("…a notification request is made", posted, "daemon \(String(describing: app.daemon.state.statuses[s]))")
        r.check("…titled with the session's name, its section beneath", n?.title == "review-1" && n?.subtitle == "Reviews", describe(n))
        r.check("…saying what it waits for", n?.body == "Waiting — permission: Bash", describe(n))
        r.check("…for that session", n?.session == s && n?.userInfo["session"] == s && n?.kind == .waiting)
        r.check("badge: the Dock badge counts the wait", app.dockBadgeLabel == Attention.badgeLabel(before + 1) && NSApp.dockTile.badgeLabel == app.dockBadgeLabel,
                "badge \(app.dockBadgeLabel ?? "none"), \(before) waiting before")

        // The same wait again (Claude's permission_prompt Notification follows PermissionRequest).
        _ = await claudeHook(s, "Notification", #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#)
        await sleep(700)
        r.check("notify: the same wait doesn't notify twice", rec.posts(for: s).count == 1, "\(rec.posts(for: s).count) posts")

        // 2. Clicking it: the app comes forward on that row, with its pane active and the keyboard in it.
        if let n {
            app.notificationClicked(userInfo: n.userInfo)
            await waitUntil(3) { ws.activeSession == s && ws.activeTerminal?.hasPaintedContent == true }
            r.check("click: shows the session's row with its pane active", ws.currentRow == rowID(s) && ws.activeSession == s,
                    "row \(ws.currentRow ?? "-"), active \(ws.activeSession.map(app.displayName) ?? "-")")
            r.check("…with the keyboard in it", firstResponderIsActiveTerminal)
            r.check("…and takes the notification back", rec.removed.contains(id) && rec.delivered[id] == nil)
            await sleep(250)
            shot("16-notification-click-shows-the-waiting-pane")
            await type("yes\n")
            r.check("…typing reaches it", await paneShows(s, "got: yes"))
        }

        // 3. The wait ends: the badge goes back down, and the tile was set only when the number changed.
        await toolDone(s)
        r.check("badge: the wait ending takes the badge back down", await waitUntil(3) { app.dockBadgeLabel == Attention.badgeLabel(before) },
                "badge \(app.dockBadgeLabel ?? "none")")
        r.check("…the Dock tile was set only when the number changed (twice)", app.dockBadgeUpdates == updatesBefore + 2,
                "\(app.dockBadgeUpdates - updatesBefore) updates")

        // 4. The pane you're looking at in the frontmost app never notifies.
        app.windowSeen = { true }
        _ = await permission(s)
        await waitUntil(3) { app.daemon.state.state(of: s) == .waiting }
        await sleep(500)
        r.check("visible: a wait in the pane on screen in the frontmost app doesn't notify", rec.posts(for: s).count == 1, "\(rec.posts(for: s).count) posts")
        r.check("…the badge still counts it", app.dockBadgeLabel == Attention.badgeLabel(before + 1), "badge \(app.dockBadgeLabel ?? "none")")
        await toolDone(s)

        // 5. The same pane while the app isn't in front does; coming to the front takes it back.
        app.windowSeen = { false }
        _ = await permission(s, tool: "Edit")
        r.check("inactive: the pane on screen notifies while the app isn't in front", await waitUntil(3) { rec.posts(for: s).count == 2 },
                "\(rec.posts(for: s).count) posts")
        r.check("…with the new wait's detail", rec.delivered[id]?.body == "Waiting — permission: Edit", describe(rec.delivered[id]))
        app.windowSeen = { true }
        app.appBecameActive()
        r.check("…and the app coming to the front takes it back", rec.delivered[id] == nil)
        app.windowSeen = { false }
        await toolDone(s)
        await settle(s)

        // 6. A finished turn (a new done_at) in a session that isn't on screen.
        let d = f.api
        let did = Attention.id(.done, d)
        r.check("done: bosun hook claude Stop runs in api's pane (another row)", await stop(d))
        r.check("…a notification request is made", await waitUntil(3) { rec.delivered[did] != nil })
        let dn = rec.delivered[did]
        r.check("…titled with its name (an ungrouped row: no subtitle), saying it's your turn",
                dn?.title == "api" && dn?.subtitle == "" && dn?.body == "Done — your turn" && dn?.session == d, describe(dn))
        r.check("…the badge doesn't count done turns", app.dockBadgeLabel == Attention.badgeLabel(before), "badge \(app.dockBadgeLabel ?? "none")")
        if let dn {
            app.notificationClicked(userInfo: dn.userInfo)
            await waitUntil(3) { ws.activeSession == d && ws.activeTerminal?.hasPaintedContent == true }
            r.check("click: shows api's row with the keyboard in its pane", ws.currentRow == rowID(d) && ws.activeSession == d && firstResponderIsActiveTerminal)
            r.check("…and takes the notification back", rec.delivered[did] == nil)
        }
        // The next turn finishes while api is on screen but the app is behind: notified; typing takes it back.
        _ = await claudeHook(d, "UserPromptSubmit", #"{"hook_event_name":"UserPromptSubmit","prompt":"more"}"#)
        await waitUntil(3) { app.daemon.state.state(of: d) == .running }
        _ = await stop(d)
        r.check("done: the next turn (a newer done_at) notifies again", await waitUntil(3) { rec.posts(for: d).count == 2 }, "\(rec.posts(for: d).count) posts")
        await type("ok\n")
        r.check("…typing into the session takes it back", await waitUntil(2) { rec.delivered[did] == nil })
        await sleep(400)
        r.check("…and the same done_at never comes back", rec.posts(for: d).count == 2)

        // 7. The settings.
        AppSettings.shared.notifyWhenDone = false
        _ = await claudeHook(d, "UserPromptSubmit", #"{"hook_event_name":"UserPromptSubmit","prompt":"quiet"}"#)
        await waitUntil(3) { app.daemon.state.state(of: d) == .running }
        _ = await stop(d)
        await waitUntil(3) { app.daemon.state.statuses[d]?.doneAt != nil }
        await sleep(500)
        r.check("settings: Notify When Done off: a finished turn doesn't notify", rec.posts(for: d).count == 2, "\(rec.posts(for: d).count) posts")
        AppSettings.shared.notifyWhenDone = true
        AppSettings.shared.notifyWhenWaiting = false
        await showRow(f.api)
        _ = await permission(f.review2)
        await waitUntil(3) { app.daemon.state.state(of: f.review2) == .waiting }
        await sleep(500)
        r.check("settings: Notify When Waiting off: a wait doesn't notify", rec.posts(for: f.review2).isEmpty)
        AppSettings.shared.notifyWhenWaiting = true
        AppSettings.shared.showDockBadge = false
        r.check("settings: Show Dock Badge off: no badge though one session waits", app.dockBadgeLabel == nil && NSApp.dockTile.badgeLabel == nil,
                "badge \(app.dockBadgeLabel ?? "none")")
        AppSettings.shared.showDockBadge = true
        r.check("…on again: it's back", app.dockBadgeLabel == Attention.badgeLabel(before + 1), "badge \(app.dockBadgeLabel ?? "none")")
        await menuToggles()

        // 8. Cmd+Shift+U: the oldest wait first, across rows; a tab of a multi-tab row comes up as its pane.
        await sleep(30)
        _ = await permission(f.webTests)
        await waitUntil(3) { app.daemon.state.state(of: f.webTests) == .waiting }
        r.check("oldest: review-2 (waiting first) is the oldest wait", app.oldestWaiting == f.review2, app.oldestWaiting.map(app.displayName) ?? "none")
        await cmd("u", .shift)
        await waitUntil(2) { ws.activeSession == f.review2 }
        r.check("oldest: Cmd+Shift+U shows the oldest waiting session's row, keyboard in its pane",
                ws.currentRow == rowID(f.review2) && ws.activeSession == f.review2 && firstResponderIsActiveTerminal,
                "active \(ws.activeSession.map(app.displayName) ?? "-")")
        await settle(f.review2)
        await waitUntil(3) { app.daemon.state.state(of: f.review2) != .waiting }
        await cmd("u", .shift)
        await waitUntil(2) { ws.activeSession == f.webTests }
        r.check("…then the next: web tests, as the active pane of the web row's three",
                ws.currentRow == rowID(f.web) && ws.layout.count == 3 && ws.activeSession == f.webTests && firstResponderIsActiveTerminal,
                "row \(ws.container.map(app.rowLabel) ?? "-"), \(ws.layout.count) panes, active \(ws.activeSession.map(app.displayName) ?? "-")")
        await settle(f.webTests)
        await waitUntil(3) { app.daemon.state.state(of: f.webTests) != .waiting }
        if waitingCount == 0 {
            let row = ws.currentRow
            await cmd("u", .shift)
            r.check("…and with nothing waiting it stays put and says so", ws.currentRow == row && app.noticeText == "Nothing is waiting", app.noticeText)
        }

        // 9. Input times are saved per daemon, for sessions that exist.
        app.saveInputs()
        let saved = (try? Data(contentsOf: app.inputsURL)).flatMap(SavedInputs.decode)
        r.check("inputs: typing times are saved (keyed by the daemon's socket)", saved?.inputs[f.api] != nil && saved?.inputs[f.review1] != nil,
                "\(app.inputsURL.lastPathComponent): \(saved.map { $0.inputs.keys.map(app.displayName).sorted().joined(separator: ", ") } ?? "missing")")
        r.check("…only for sessions that exist", saved?.inputs.keys.allSatisfy { app.isAlive($0) } == true)

        // Leave the fixture as it was.
        for x in [f.api, f.review1, f.review2, f.webTests] { await settle(x) }
        await showRow(f.api)
        app.windowSeen = realSeen
        rec.reset()
    }

    /// The three toggles in the Bosun menu, checked by default, and the same settings in the Settings window.
    private func menuToggles() async {
        let titles = ["Notify When Waiting", "Notify When Done", "Show Dock Badge"]
        let items = titles.compactMap { app.menuItem(titled: $0) }
        r.check("menu: the Bosun menu has \(titles.joined(separator: ", "))", items.count == 3 && items.allSatisfy { $0.menu === NSApp.mainMenu?.items.first?.submenu })
        for i in items { _ = app.validateMenuItem(i) }
        r.check("…checked (on by default), with no keys", items.allSatisfy { $0.state == .on && $0.keyEquivalent.isEmpty })
        if let i = items.first {
            _ = NSApp.sendAction(i.action!, to: i.target, from: i)
            _ = app.validateMenuItem(i)
            r.check("…choosing one turns it off", !AppSettings.shared.notifyWhenWaiting && i.state == .off)
            _ = NSApp.sendAction(i.action!, to: i.target, from: i)
            _ = app.validateMenuItem(i)
            r.check("…and on again", AppSettings.shared.notifyWhenWaiting && i.state == .on)
        }
        // A picture of the menu. A test run never activates the app (--no-activate), and an inactive app can't
        // open a menu, so this draws the live menu's items (titles, the states validation gives them, keys).
        if let shots, let appMenu = NSApp.mainMenu?.items.first?.submenu {
            for i in appMenu.items { _ = app.validateMenuItem(i) }
            let ok = MenuPicture.write(appMenu, to: URL(fileURLWithPath: "\(shots)/17-bosun-menu-notification-toggles.png"))
            r.say("      screenshot 17-bosun-menu-notification-toggles.png \(ok ? "(drawn from the live menu items)" : "FAILED")")
        }

        guard let shots else { return }
        app.showSettings()
        if let sw = app.settingsWindow {
            var ok = false
            for _ in 0..<10 where !ok {
                await sleep(200)
                sw.contentView?.layoutSubtreeIfNeeded()
                sw.displayIfNeeded()
                ok = WindowSnapshot.write(sw, to: URL(fileURLWithPath: "\(shots)/18-settings-notifications.png"))
            }
            r.say("      screenshot 18-settings-notifications.png \(ok ? "" : "FAILED")")
            sw.close()
        }
        ws.focusActiveTerminal()
    }
}

/// Draws a menu's items as AppKit lays them out in a menu: checkmark column, title, key equivalent, separators.
@MainActor
enum MenuPicture {
    static func write(_ menu: NSMenu, to url: URL) -> Bool {
        let font = NSFont.menuFont(ofSize: 13)
        let rowH: CGFloat = 22, sepH: CGFloat = 11, pad: CGFloat = 5
        let widest = menu.items.map { NSAttributedString(string: $0.title, attributes: [.font: font]).size().width }.max() ?? 0
        let width = max(260, ceil(widest) + 60)
        let height = menu.items.reduce(pad * 2) { $0 + ($1.isSeparatorItem ? sepH : rowH) }
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            NSColor(white: 0.17, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: 8, yRadius: 8).fill()
            var y = height - pad
            for item in menu.items {
                if item.isSeparatorItem {
                    y -= sepH
                    NSColor(white: 1, alpha: 0.12).setFill()
                    NSRect(x: 12, y: y + sepH / 2, width: width - 24, height: 1).fill()
                    continue
                }
                y -= rowH
                let color = item.isEnabled ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.5, alpha: 1)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let ty = y + (rowH - font.boundingRectForFont.height) / 2 + 2
                if item.state == .on { NSAttributedString(string: "✓", attributes: attrs).draw(at: NSPoint(x: 10, y: ty)) }
                NSAttributedString(string: item.title, attributes: attrs).draw(at: NSPoint(x: 28, y: ty))
                if let key = ShortcutsPanel.keyLabel(item) {
                    let k = NSAttributedString(string: key, attributes: [.font: font, .foregroundColor: NSColor(white: 0.6, alpha: 1)])
                    k.draw(at: NSPoint(x: width - 14 - k.size().width, y: ty))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
