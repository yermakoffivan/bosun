import AppKit
import BosunCore

// Focus-test sections for layout and dragging: the new-session sheet at every window and tile
// size, empty tiles in narrow tiles, moving tiles by their header, sidebar drag and drop through
// the outline's own drag code, and the keyboard shortcuts panel.

extension FocusTest {
    func layoutSections(_ only: Set<String>?) async {
        func wants(_ s: String) -> Bool { only?.contains(s) ?? true }
        if wants("sheet") { await sheetLayout() }
    }

    // MARK: Sheet layout

    /// Every control and every piece of text in the sheet lies inside its content view, with a margin.
    func sheetProblems(_ sheet: NSWindow) -> [String] {
        guard let content = sheet.contentView else { return ["no content view"] }
        content.layoutSubtreeIfNeeded()
        let inner = content.bounds.insetBy(dx: 12, dy: 8)
        var bad: [String] = []
        func fmt(_ r: NSRect) -> String { "x \(Int(r.minX))…\(Int(r.maxX)) y \(Int(r.minY))…\(Int(r.maxY))" }
        func walk(_ v: NSView) {
            for s in v.subviews where !s.isHidden {
                let f = s.convert(s.bounds, to: content)
                if s is NSControl, f.width > 1, f.height > 1, !inner.contains(f) {
                    let title = (s as? NSButton)?.title ?? (s as? NSTextField)?.stringValue ?? ""
                    bad.append("\(Swift.type(of: s)) “\(title)” at \(fmt(f)) outside \(fmt(inner))")
                }
                walk(s)
            }
        }
        walk(content)
        // No two controls overlap (rows running into the buttons when the height changes, say).
        var leaves: [(String, NSRect)] = []
        func collect(_ v: NSView) {
            for s in v.subviews where !s.isHidden {
                if let c = s as? NSControl, !(c.superview is NSControl) {
                    let title = (c as? NSButton)?.title ?? (c as? NSTextField)?.stringValue ?? ""
                    leaves.append(("\(Swift.type(of: c)) “\(title.prefix(20))”", c.convert(c.bounds, to: content)))
                }
                collect(s)
            }
        }
        collect(content)
        for i in leaves.indices {
            for j in leaves.indices where j > i && leaves[i].1.insetBy(dx: 1, dy: 1).intersects(leaves[j].1.insetBy(dx: 1, dy: 1)) {
                bad.append("\(leaves[i].0) overlaps \(leaves[j].0)")
            }
        }
        // SwiftUI draws labels itself; their accessibility frames say where.
        let screenInner = sheet.convertToScreen(content.convert(content.bounds.insetBy(dx: 6, dy: 4), to: nil))
        func ax(_ e: Any, _ depth: Int) {
            guard depth < 40 else { return }
            let o = e as AnyObject
            guard let f = o.accessibilityFrame?() else { return }
            let role = (o.accessibilityRole?() ?? nil) ?? .unknown
            if role == .staticText || role == .button || role == .checkBox || role == .radioButton || role == .textField,
               f.width > 1, f.height > 1, !screenInner.contains(f) {
                let label = (o.accessibilityLabel?() ?? nil) ?? ""
                let obj = o as? NSObject
                let value = obj?.responds(to: NSSelectorFromString("accessibilityValue")) == true
                    ? (obj?.value(forKey: "accessibilityValue") as? String).map { " \($0)" } ?? "" : ""
                bad.append("\(role.rawValue) “\(label)\(value)” at screen \(fmt(f)) outside \(fmt(screenInner))")
            }
            for c in (o.accessibilityChildren?() ?? nil) ?? [] { ax(c, depth + 1) }
        }
        ax(content, 0)
        return bad
    }

    private func checkSheet(_ label: String, shot name: String?) async {
        guard let sheet = w.attachedSheet, let model = app.formModel else {
            r.check("\(label): the sheet is open", false)
            return
        }
        var problems: [String] = []
        // Long values, as a recent session's path fills in: text fields must not grow the form.
        model.path = "~/Projects/some-client/a-rather-long-repository-name/packages/backend/services/api-gateway"
        model.name = "a-session-name-that-goes-on-for-quite-a-while-longer-than-the-field"
        model.args = "--model opus --append-system-prompt 'be brief' --permission-mode acceptEdits --verbose"
        for agent in agentNames {
            for wt in [false, true] {
                model.agent = agent
                model.worktree = wt
                await sleep(120)
                problems += sheetProblems(sheet).map { "\(agent)\(wt ? "+worktree" : ""): \($0)" }
            }
        }
        model.agent = "claude"
        model.worktree = false
        model.args = ""
        await sleep(150)
        let size = sheet.frame.size
        r.check("\(label): every control and label lies inside the sheet, with margins", problems.isEmpty,
                "sheet \(Int(size.width))×\(Int(size.height)); " + problems.prefix(6).joined(separator: "; "))
        r.check("\(label): the sheet is attached to the window and centred on it",
                sheet.sheetParent === w && abs(sheet.frame.midX - w.frame.midX) <= 1, "sheet \(sheet.frame) window \(w.frame)")
        if let name { shot(name) }
    }

    private func closeSheet() async {
        if let sheet = w.attachedSheet { await key(53, "\u{1b}", window: sheet) }
        await waitUntil(2) { !app.sheetOpen }
        await waitUntil(1) { firstResponderIsActiveTerminal }
    }

    /// The "New Session…" button in an empty tile's placeholder.
    func placeholderButton(_ tile: TileID, title: String) -> NSButton? {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.title == title, !b.isHidden { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return ws.area.subviews.compactMap { $0 as? TileChromeView }.first { $0.tile == tile }.flatMap(find)
    }

    func sheetLayout() async {
        guard let api = session("api") else { return }
        await showOnly(api)
        // One tile.
        await cmd("n", [.shift])
        await waitUntil(2) { app.sheetOpen }
        await sleep(300)
        await checkSheet("sheet over one tile", shot: "10-sheet-1-tile")
        await closeSheet()

        // Two tiles, opened from the new (empty) tile's placeholder, as Andy did.
        await cmd("d")
        await waitUntil(2) { ws.layout.count == 2 }
        r.check("Cmd+D after the sheet splits", ws.layout.count == 2)
        let newTile = ws.activeTile
        ws.clear(newTile)
        await sleep(200)
        if let b = placeholderButton(newTile, title: "New Session…") {
            await click(b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil))
        }
        await waitUntil(2) { app.sheetOpen }
        r.check("the empty tile's New Session… button opens the sheet", app.sheetOpen)
        await sleep(300)
        await checkSheet("sheet over two tiles", shot: "11-sheet-2-tiles")
        await closeSheet()

        // Four tiles.
        await cmd("d", [.shift])
        await arrow(123, [.command, .option])
        await cmd("d", [.shift])
        await waitUntil(3) { ws.layout.count == 4 }
        await cmd("n", [.shift])
        await waitUntil(2) { app.sheetOpen }
        await sleep(300)
        await checkSheet("sheet over four tiles", shot: "12-sheet-4-tiles")
        await closeSheet()

        // The smallest window the app allows, still with four tiles.
        let frame = w.frame
        w.setFrame(NSRect(origin: frame.origin, size: w.minSize), display: true)
        await sleep(300)
        await cmd("n", [.shift])
        await waitUntil(2) { app.sheetOpen }
        await sleep(300)
        await checkSheet("sheet in the smallest window", shot: "13-sheet-small-window")
        await closeSheet()
        r.check("after the sheet the keyboard is back in the terminal", firstResponderIsActiveTerminal)
        w.setFrame(frame, display: true)
        await sleep(200)
        for _ in 0..<10 where ws.layout.count > 1 { ws.closeActive() }
    }
}
