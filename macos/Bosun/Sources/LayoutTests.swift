import AppKit
import BosunCore

// Focus-test sections for layout and dragging: the new-session sheet at every window and pane
// count, the exited-row and no-rows placeholders at every width, moving panes by their header,
// sidebar drag and drop through the outline's own drag code, and the keyboard shortcuts panel.

extension FocusTest {
    func layoutSections(_ only: Set<String>?) async {
        func wants(_ s: String) -> Bool { only?.contains(s) ?? true }
        if wants("sheet") { await sheetLayout() }
        if wants("empty") { await emptyState() }
        if wants("tiledrag") { await tileDrag() }
        if wants("sidebardrag") { await sidebarDrag() }
        if wants("shortcuts") { await shortcuts() }
    }

    // MARK: Sheet layout

    /// Every control and every label in the sheet (all AppKit views) lies inside its content view, with a margin, and none overlap.
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

    func sheetLayout() async {
        guard let api = session("api"), let web = session("web"), let webRow = rowID(web) else { return }
        await showRow(api)
        // One pane.
        await cmd("n", [.shift])
        await waitUntil(2) { app.sheetOpen }
        await sleep(300)
        await checkSheet("sheet over one pane", shot: "15-sheet-1-pane")
        await closeSheet()

        // The three-pane row, with the sheet opened by Cmd+T (New Tab…).
        await showRow(web)
        await cmd("t")
        await waitUntil(2) { app.sheetOpen }
        r.check("Cmd+T opens the sheet over the three-pane row", app.sheetOpen && app.formModel?.isAddTab == true)
        await sleep(300)
        await checkSheet("sheet over three panes", shot: "16-sheet-3-panes")
        await closeSheet()

        // Four panes: Cmd+D adds a terminal tab.
        let before = tabs(webRow)
        await cmd("d")
        await waitUntil(4) { ws.layout.count == 4 }
        let extra = tabs(webRow).first { !before.contains($0) }
        await cmd("n", [.shift])
        await waitUntil(2) { app.sheetOpen }
        await sleep(300)
        await checkSheet("sheet over four panes", shot: "17-sheet-4-panes")
        await closeSheet()

        // The smallest window the app allows, still with four panes.
        let frame = w.frame
        w.setFrame(NSRect(origin: frame.origin, size: w.minSize), display: true)
        await sleep(300)
        await cmd("n", [.shift])
        await waitUntil(2) { app.sheetOpen }
        await sleep(300)
        await checkSheet("sheet in the smallest window", shot: "18-sheet-small-window")
        await closeSheet()
        r.check("after the sheet the keyboard is back in the terminal", firstResponderIsActiveTerminal)
        w.setFrame(frame, display: true)
        await sleep(200)
        if let extra {
            await killTab(extra)
            await waitUntil(4) { ws.layout.count == 3 }
        }
    }

    // MARK: Empty tiles

    /// What in an empty tile's placeholder is cut off: anything outside it, or text taller than its frame.
    func placeholderProblems(_ p: PlaceholderView) -> [String] {
        p.layoutSubtreeIfNeeded()
        var bad: [String] = []
        let inner = p.bounds.insetBy(dx: 4, dy: 0)
        for v in [p.title, p.hint, p.primary, p.secondary] as [NSControl] where !v.isHidden {
            let name = (v as? NSButton)?.title ?? (v as? NSTextField)?.stringValue.prefix(24).description ?? ""
            if !inner.contains(v.frame) { bad.append("“\(name)” at \(v.frame) outside \(p.bounds)") }
            if let t = v as? NSTextField, let cell = t.cell {
                let need = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: t.frame.width, height: .greatestFiniteMagnitude))
                if need.height > t.frame.height + 1 { bad.append("“\(name)” needs \(Int(need.height)) pt, has \(Int(t.frame.height))") }
                if (t.attributedStringValue.size().width > t.frame.width + 1) && t.frame.height < 2 * (t.font?.boundingRectForFont.height ?? 14) - 4 {
                    bad.append("“\(name)” doesn't wrap: one line of \(Int(t.frame.height)) pt for \(Int(t.attributedStringValue.size().width)) pt of text")
                }
            }
        }
        return bad
    }

    /// The two placeholders (an exited row, and an empty main area with no rows at all) keep their text
    /// and buttons inside at every width, wrapping rather than running off the edge.
    func emptyState() async {
        guard let api = session("api") else { return }
        await showRow(api)
        for (label, session) in [("an exited row's placeholder", api as String?), ("the no-rows placeholder", nil)] {
            let p = PlaceholderView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
            p.configure(session: session, app: app, theme: app.theme)
            var bad: [String] = []
            var narrowTitle: CGFloat = 0
            for width in stride(from: 40, through: 900, by: 20) {
                p.setFrameSize(NSSize(width: CGFloat(width), height: 500))
                p.needsLayout = true
                bad += placeholderProblems(p).map { "\(width) pt: \($0)" }
                if width == 80 { narrowTitle = p.title.frame.height }
            }
            r.check("\(label) keeps its text inside at every width from 40 to 900 pt", bad.isEmpty, bad.prefix(4).joined(separator: "; "))
            r.check("…its title wraps onto more lines when narrow", narrowTitle > 22, "title \(narrowTitle) pt at 80 pt")
            if session == nil {
                r.check("…and offers New Session…", p.primary.title == "New Session…" && p.secondary.isHidden)
            }
        }
    }

    // MARK: Tile drag

    /// A point on a tile's header strip, in window coordinates.
    func headerPoint(_ t: TileID) -> NSPoint? {
        guard let r = ws.tileRects[t] else { return nil }
        return ws.area.convert(NSPoint(x: r.minX + r.width * 0.6, y: r.minY + Workspace.headerHeight / 2), to: nil)
    }

    /// A point in a tile's drop zone, in window coordinates.
    func zonePoint(_ t: TileID, _ zone: TileDropZone) -> NSPoint? {
        guard let r = ws.tileRects[t] else { return nil }
        let p: NSPoint
        switch zone {
        case .swap: p = NSPoint(x: r.midX, y: r.midY)
        case .edge(.left): p = NSPoint(x: r.minX + r.width * 0.08, y: r.midY)
        case .edge(.right): p = NSPoint(x: r.maxX - r.width * 0.08, y: r.midY)
        case .edge(.up): p = NSPoint(x: r.midX, y: r.minY + r.height * 0.08)
        case .edge(.down): p = NSPoint(x: r.midX, y: r.maxY - r.height * 0.08)
        }
        return ws.area.convert(p, to: nil)
    }

    private func post(_ type: NSEvent.EventType, _ p: NSPoint) {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                      pressure: type == .leftMouseUp ? 0 : 1) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// Press on `from`, move to `to` in steps, run `during` while still held, then release at `release ?? to`.
    func drag(from: NSPoint, to: NSPoint, release: NSPoint? = nil, during: (() async -> Void)? = nil) async {
        post(.leftMouseDown, from)
        await sleep(30)
        for i in 1...8 {
            let f = CGFloat(i) / 8
            post(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f))
            await sleep(15)
        }
        await sleep(60)
        await during?()
        if let release {
            post(.leftMouseDragged, release)
            await sleep(40)
        }
        post(.leftMouseUp, release ?? to)
        await sleep(120)
    }

    /// Pane → its terminal view, to check that moves reuse the same views.
    private var viewsByTile: [TileID: ObjectIdentifier] {
        var out: [TileID: ObjectIdentifier] = [:]
        for t in ws.layout.panes { if let v = ws.terminal(in: t) { out[t] = ObjectIdentifier(v) } }
        return out
    }

    private func keysLandIn(_ s: String, _ tag: String) async -> Bool {
        await waitUntil(1) { firstResponderIsActiveTerminal }
        // Let the resize after a move settle (the agent redraws on SIGWINCH) before typing.
        await sleep(250)
        guard (w.firstResponder as? TerminalView)?.session == s else { return false }
        if app.displayName(s) == "ticker" { return true }
        if ShellCommand.isShell(app.daemon.state.sessions[s]?.paneCommand) {
            await type("echo \(tag)\n")
            return await paneHasLine(s, tag)
        }
        await type("\(tag)\n")
        // Matched within a "got:" line: an earlier section can leave a stray key in the agent's input line.
        return await waitUntil(3) { pane(s).split(separator: "\n").contains { $0.hasPrefix("got: ") && $0.contains(tag) } }
    }

    func tileDrag() async {
        guard let api = session("api"), let web = session("web"), let webTests = session("web tests"),
              let webShell = session("web shell") else { return }
        await showRow(web)
        await waitUntil(3) { ws.layout.count == 3 }
        r.check("pane drag: the three-pane row", Set(ws.layout.panes) == [web, webTests, webShell])
        let parser = webShell
        await sleep(300)

        // Each edge: drag parser's tile onto api's tile, then check the tree, the views and the keyboard.
        let moving = parser
        let target = web
        var edgeShot = false
        for side in [Direction.left, .right, .up, .down] {
            let zone = TileDropZone.edge(side)
            let expected = ws.layout.root?.moving(moving, to: target, zone: zone)
            guard let from = headerPoint(moving), let to = zonePoint(target, zone) else { continue }
            let views = viewsByTile
            let poolSize = ws.pool.views.count
            var indicator: CGRect?
            var reported: TileDropZone?
            let want = ws.tileRects[target].map { zone.indicatorRect(in: $0) }
            await drag(from: from, to: to) { [self] in
                indicator = ws.dropIndicator.shownRect
                reported = ws.tileDropTarget?.zone
                if !edgeShot, side == .right { edgeShot = true; shot("21-pane-drop-edge") }
            }
            if expected == nil {
                r.check("drag to the \(side) edge: a no-op drop shows nothing and changes nothing", indicator == nil && reported == nil)
                continue
            }
            r.check("drag to the \(side) edge: the indicator covers that half of the target", indicator == want && reported == zone,
                    "indicator \(String(describing: indicator)) want \(String(describing: want))")
            r.check("drag to the \(side) edge: the tile moves there", ws.layout.root == expected, "\(ws.layout.root)")
            let sameViews = viewsByTile == views && ws.pool.views.count == poolSize
            r.check("…with the same terminal views (no reattach)", sameViews)
            r.check("…and the dragged pane stays active with the keyboard", ws.activeTile == moving && ws.activeSession == parser)
            r.check("…typing reaches it", await keysLandIn(parser, "moved-\(side)"))
        }

        // Swap: two tiles that aren't the one just moved.
        let others = ws.layout.panes.filter { $0 != moving }
        guard others.count >= 2 else {
            r.check("pane drag: two other panes to swap", false, "\(ws.layout.count) panes")
            return
        }
        let docsAgain = others[0]
        let a = others[0]
        let b = others[1]
        let swapped = ws.layout.root?.swapping(a, b)
        let views = viewsByTile
        let poolSize = ws.pool.views.count
        if let from = headerPoint(a), let to = zonePoint(b, .swap) {
            var label = false
            await drag(from: from, to: to) { [self] in
                label = ws.dropIndicator.showsSwap
                shot("22-pane-drop-swap")
            }
            r.check("drag to the middle: the indicator says swap", label)
            r.check("…and the two tiles swap places", ws.layout.root == swapped, "\(ws.layout.root)")
            r.check("…with the same terminal views", ws.pool.views.count == poolSize && viewsByTile == views)
            let activeAfter = ws.activeSession
            let landed = await keysLandIn(docsAgain, "swapped")
            r.check("…and the keyboard in the dragged tile", activeAfter == docsAgain && landed,
                    "active \(activeAfter.map(app.displayName) ?? "-"), landed \(landed)")
        }

        // Esc cancels, mid-drag.
        let before = ws.layout.root
        if let from = headerPoint(b), let to = zonePoint(a, .edge(.left)) {
            var shown = false
            await drag(from: from, to: to) { [self] in
                shown = ws.dropIndicator.shownRect != nil
                await key(53, "\u{1b}")
            }
            r.check("Esc during a drag hides the indicator and cancels it", shown && !ws.tileDragActive && ws.layout.root == before)
            let current = ws.activeSession ?? api
            r.check("…and the Esc never reaches the terminal", !pane(current).contains("^["))
        }
        // Released outside the tiles (over the sidebar).
        if let from = headerPoint(b), let to = zonePoint(a, .edge(.down)), let side = sidebarPoint(api) {
            await drag(from: from, to: to, release: side)
            r.check("a drop outside the tiles cancels", ws.layout.root == before && !ws.tileDragActive && ws.dropIndicator.superview == nil)
        }
        // Onto itself.
        if let from = headerPoint(b), let to = zonePoint(b, .edge(.left)) {
            var shown = true
            await drag(from: from, to: to) { [self] in shown = ws.dropIndicator.shownRect != nil }
            r.check("a drop onto itself shows nothing and does nothing", !shown && ws.layout.root == before)
        }
        r.check("after the drags the keyboard is in the active terminal", firstResponderIsActiveTerminal)

        // File drops keep working and never show the tile indicator.
        let file = NSTemporaryDirectory() + "bosun tiledrag.txt"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        let pb = NSPasteboard(name: NSPasteboard.Name("dev.yetidevworks.bosun.test-drag-tiles"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: file) as NSURL])
        if let t = ws.layout.panes.first(where: { $0 != webShell }), let c = tileCenter(t) {
            let target = t
            let info = FakeDrag(location: c, pasteboard: pb, window: w)
            let op = ws.area.draggingEntered(info)
            r.check("a file dragged over a tile is still accepted, without the tile drop indicator",
                    op == .copy && ws.dropIndicator.shownRect == nil && ws.dropIndicator.superview == nil)
            _ = ws.area.performDragOperation(info)
            await sleep(150)
            await type("\n")
            r.check("…and the drop inserts the path as before", await paneShows(target, "got: \(ShellEscape.escape(file))"))
        }
        r.check("after the pane drags the row still has its three tabs as panes", Set(ws.layout.panes) == [web, webTests, webShell])
        await showRow(api)
    }

    // MARK: Sidebar drag and drop

    /// A point in a sidebar item's row (fraction 0 = top, 1 = bottom), in window coordinates.
    func rowPoint(_ item: SidebarItem?, _ fy: CGFloat, x: CGFloat = 60) -> NSPoint? {
        guard let item else { return nil }
        let o = app.sidebar.outline
        let row = o.row(forItem: item)
        guard row >= 0 else { return nil }
        let r = o.rect(ofRow: row)
        return o.convert(NSPoint(x: r.minX + x, y: r.minY + r.height * fy), to: nil)
    }

    func sectionItem(_ name: String) -> SidebarItem? {
        let o = app.sidebar.outline
        guard let id = app.daemon.state.sidebar.sections.first(where: { $0.name == name })?.id else { return nil }
        return (0..<o.numberOfRows).compactMap { o.item(atRow: $0) as? SidebarItem }.first { $0.kind == .section(id) }
    }

    func rowItem(_ session: String) -> SidebarItem? {
        let o = app.sidebar.outline
        guard let c = app.daemon.state.sidebar.container(holding: session) else { return nil }
        return (0..<o.numberOfRows).compactMap { o.item(atRow: $0) as? SidebarItem }.first { $0.kind == .row(c.id) }
    }

    /// Press on `from` and move: AppKit's own table tracking decides whether a drag starts and builds
    /// the dragging items. Then the drop side is played through the outline's own NSDraggingDestination
    /// (which proposes the drop item and index from the location), ending at `to`.
    func outlineDrag(from: NSPoint, to: NSPoint) async -> (started: Bool, op: NSDragOperation, accepted: Bool) {
        let o = app.sidebar.outline
        var captured: (NSDraggingSession, [NSDraggingItem])?
        o.dragCapture = { s, items, _ in captured = (s, items) }
        defer { o.dragCapture = nil }
        post(.leftMouseDown, from)
        for i in 1...6 { post(.leftMouseDragged, NSPoint(x: from.x + CGFloat(i), y: from.y + CGFloat(i) * 2)) }
        await waitUntil(2) { captured != nil }
        guard let (session, items) = captured else {
            post(.leftMouseUp, from)
            await sleep(100)
            return (false, [], false)
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("dev.yetidevworks.bosun.test-sidebar-drag"))
        pb.clearContents()
        pb.writeObjects(items.compactMap { $0.item as? NSPasteboardWriting })
        let info = FakeDrag(location: from, pasteboard: pb, window: w, source: o, mask: .move)
        var op = o.draggingEntered(info)
        for i in 1...6 {
            let f = CGFloat(i) / 6
            info.location = NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
            op = o.draggingUpdated(info)
            await sleep(15)
        }
        var ok = false
        if op != [] {
            _ = o.prepareForDragOperation(info)
            ok = o.performDragOperation(info)
            o.concludeDragOperation(info)
        } else {
            o.draggingExited(info)
        }
        o.draggingSession(session, endedAt: w.convertPoint(toScreen: to), operation: ok ? .move : [])
        await sleep(150)
        return (true, op, ok)
    }

    private func names(_ cs: [Container]) -> [String] { cs.map { app.displayName($0.active) } }

    func sidebarDrag() async {
        guard let api = session("api"), let docs = session("docs"), let parser = session("parser"),
              let web = session("web"), let webTests = session("web tests") else { return }
        let original = app.daemon.state.sidebar
        await showRow(review1Session ?? api)
        let shownBefore = ws.activeSession

        // a) A row onto the lower edge of the next row: reordered among the ungrouped rows.
        if let from = rowPoint(rowItem(api), 0.5), let to = rowPoint(rowItem(docs), 0.92) {
            let res = await outlineDrag(from: from, to: to)
            r.check("sidebar: pressing a row and moving starts a drag (AppKit's own tracking)", res.started)
            r.check("…a row dropped below the next one is accepted", res.op == .move && res.accepted, "op \(res.op.rawValue)")
            await waitUntil(1) { names(app.daemon.state.sidebar.ungrouped) == ["docs", "api"] }
            r.check("…and the rows are reordered", names(app.daemon.state.sidebar.ungrouped) == ["docs", "api"],
                    "\(names(app.daemon.state.sidebar.ungrouped))")
            r.check("…a drag isn't a click: the main area still shows what it did", ws.activeSession == shownBefore)
        }
        // b) A row dropped near the top edge of a row in a section: it goes into that section, beside that row.
        // (The middle of a row means merge, checked in g.)
        if let from = rowPoint(rowItem(api), 0.5), let to = rowPoint(rowItem(parser), 0.1) {
            let res = await outlineDrag(from: from, to: to)
            let work = app.daemon.state.sidebar.sections.first { $0.name == "Work" }
            r.check("sidebar: a row dropped near another row's edge is accepted (not refused)", res.op == .move && res.accepted, "op \(res.op.rawValue)")
            r.check("…and lands in that row's section next to it", work.map { names($0.members).prefix(2).contains("api") } ?? false,
                    "Work: \(work.map { names($0.members) } ?? [])")
        }
        // c) A section header dragged above another section.
        if let from = rowPoint(sectionItem("Reviews"), 0.5), let to = rowPoint(sectionItem("Work"), 0.15) {
            let res = await outlineDrag(from: from, to: to)
            let order = app.daemon.state.sidebar.sections.map(\.name)
            r.check("sidebar: a section dragged above another moves there", res.started && res.accepted && order.first == "Reviews", "\(order) op \(res.op.rawValue)")
        }
        // d) A tab dragged above the row's other tab.
        if let tabItem = app.sidebar.itemFor(session: webTests), let webItem = app.sidebar.itemFor(session: web),
           let from = rowPoint(tabItem, 0.5, x: 80), let to = rowPoint(webItem, 0.1, x: 80) {
            let res = await outlineDrag(from: from, to: to)
            let tabs = app.daemon.state.sidebar.container(holding: web)?.tabs.map { app.displayName($0.session) } ?? []
            r.check("sidebar: a tab dragged above its sibling reorders the row's tabs", res.accepted && Array(tabs.prefix(3)) == ["web tests", "web", "web shell"], "\(tabs) op \(res.op.rawValue)")
        }
        // e) A row dropped on the middle of one of a multi-tab row's tabs merges into that row.
        if let shell = session("shell"), let webTab = app.sidebar.itemFor(session: web),
           let from = rowPoint(rowItem(shell), 0.5), let to = rowPoint(webTab, 0.5, x: 80) {
            let res = await outlineDrag(from: from, to: to)
            await waitUntil(2) { app.daemon.state.sidebar.container(holding: web)?.tabs.contains { $0.session == shell } == true }
            let tabs = app.daemon.state.sidebar.container(holding: web)?.tabs.map { app.displayName($0.session) } ?? []
            r.check("sidebar: a row dropped on another row's tab merges into that row", res.accepted && tabs.contains("shell"),
                    "\(tabs) op \(res.op.rawValue)")
        }
        // f) Finder-style rename tells a click from a drag: dragging the selected row's name never renames.
        await showRow(docs)
        if let from = sidebarPoint(docs), let to = rowPoint(sectionItem("Reviews"), 0.9) {
            let res = await outlineDrag(from: from, to: to)
            await sleep(NSEvent.doubleClickInterval * 1000 + 300)
            r.check("sidebar: dragging the selected row's name starts a drag, not a rename",
                    res.started && app.focus.exception == nil && !app.sidebar.isRenaming)
            r.check("…and the keyboard stays in the terminal", firstResponderIsActiveTerminal)
        }
        // A plain click on the selected row's name still renames (the drag fix mustn't break it).
        if let p = sidebarPoint(docs) {
            await click(p)
            await waitUntil(2) { app.focus.exception == .rename }
            r.check("sidebar: a click on the selected row's name still starts a rename", app.focus.exception == .rename)
            await key(53, "\u{1b}")
            await waitUntil(1) { firstResponderIsActiveTerminal }
        }
        app.daemon.saveSidebar(original)
        await sleep(300)
        r.check("sidebar: put back as it was", app.daemon.state.sidebar == original)

        // g) A one-tab row dropped on the middle of another one-tab row merges into it. With the old gap
        // feedback the target row slid away from the pointer, so this only ever reordered.
        await showRow(api)
        if let from = rowPoint(rowItem(docs), 0.5), let to = rowPoint(rowItem(api), 0.5) {
            let res = await outlineDrag(from: from, to: to)
            await waitUntil(2) { app.daemon.state.sidebar.container(holding: docs)?.tabs.contains { $0.session == api } == true }
            let merged = app.daemon.state.sidebar.container(holding: docs)?.tabs.map(\.session) ?? []
            r.check("sidebar: a row dropped on the middle of a one-tab row merges into it", res.accepted && merged.contains(api) && merged.contains(docs),
                    "\(merged.map { app.displayName($0) }) op \(res.op.rawValue)")
            await waitUntil(2) { ws.layout.count == 2 }
            r.check("…and the merged row shows both as panes", ws.layout.count == 2 && ws.layout.contains(api) && ws.layout.contains(docs), "\(ws.layout.panes)")
            r.check("…with the keyboard still in a terminal", firstResponderIsActiveTerminal)
            app.moveTabToOwnRow(docs)
            await waitUntil(2) { app.daemon.state.sidebar.container(holding: docs)?.tabs.count == 1 }
            r.check("…and Move to Own Row splits it back out",
                    app.daemon.state.sidebar.container(holding: docs)?.tabs.count == 1 && app.daemon.state.sidebar.container(holding: api)?.tabs.count == 1)
        }
        await showRow(api)
    }

    private var review1Session: String? { session("review-1") }

    // MARK: Keyboard shortcuts panel

    func shortcuts() async {
        guard let api = session("api") else { return }
        await showRow(api)
        // The catalog and the menus agree both ways.
        var missing: [String] = []
        var listed = Set<String>()
        for g in AppController.shortcutCatalog {
            for row in g.rows {
                for title in row.items {
                    listed.insert(title)
                    guard let item = app.menuItem(titled: title) else { missing.append("\(title): no menu item"); continue }
                    if ShortcutsPanel.keyLabel(item) == nil { missing.append("\(title): no key equivalent") }
                }
            }
        }
        r.check("every shortcut in the panel is a menu item with that key equivalent", missing.isEmpty, missing.joined(separator: "; "))
        var unlisted: [String] = []
        func walk(_ m: NSMenu?) {
            for item in m?.items ?? [] {
                // AppKit adds Dictation and Emoji & Symbols to the Edit menu itself; they aren't the app's.
                let system = [NSSelectorFromString("startDictation:"), #selector(NSApplication.orderFrontCharacterPalette(_:))].contains { $0 == item.action }
                if !item.keyEquivalent.isEmpty, !listed.contains(item.title), item.title != "Exit Full Screen", !system {
                    let row = Int(item.title.split(separator: " ").last ?? "") ?? 0
                    if !(item.title.hasPrefix("Row ") && (1...9).contains(row)) { unlisted.append(item.title) }
                }
                walk(item.submenu)
            }
        }
        walk(NSApp.mainMenu)
        r.check("every menu shortcut is listed in the panel", unlisted.isEmpty, unlisted.joined(separator: ", "))
        // The nav keys come from [keybindings].
        let navRows: [(String, NavAction)] = [("Next session (row)", .nextSession), ("Previous session (row)", .previousSession),
                                               ("Next tab (pane)", .nextTab), ("Previous tab (pane)", .previousTab),
                                               ("Send the next key to the terminal", .sendNextKey)]
        let groups = app.shortcutGroups()
        let nav = groups.first { $0.name == "Navigation" }?.rows ?? []
        let navOK = navRows.allSatisfy { title, action in nav.first { $0.title == title }?.keys == (app.nav.chords[action]?.label ?? "off") }
        r.check("the panel's navigation keys are the configured [keybindings]", navOK, nav.map { "\($0.title) \($0.keys)" }.joined(separator: ", "))

        // Cmd+/ opens it without taking the keyboard.
        await cmd("/")
        await waitUntil(1) { app.shortcutsPanel != nil }
        r.check("Cmd+/ opens the keyboard shortcuts panel", app.shortcutsPanel != nil)
        r.check("…and the keyboard stays in the terminal", firstResponderIsActiveTerminal && app.focus.exception == nil)
        if let p = app.shortcutsPanel {
            let inside = w.contentView.map { p.frame.insetBy(dx: -1, dy: -1).intersection($0.bounds) == p.frame.insetBy(dx: -1, dy: -1) } ?? false
            r.check("…and fits in the window", inside, "\(p.frame)")
        }
        await sleep(200)
        shot("19-shortcuts-panel")
        await type("with-help-open\n")
        r.check("…typing while it's open still reaches the terminal", await paneShows(api, "got: with-help-open"))
        await key(53, "\u{1b}")
        await waitUntil(1) { app.shortcutsPanel == nil }
        r.check("Esc closes it", app.shortcutsPanel == nil)
        await type("after-help\n")
        r.check("…the Esc never reached the terminal and typing goes there", await paneShows(api, "got: after-help") && !pane(api).contains("^["))
        await cmd("/")
        await waitUntil(1) { app.shortcutsPanel != nil }
        await cmd("/")
        await waitUntil(1) { app.shortcutsPanel == nil }
        r.check("Cmd+/ toggles it closed", app.shortcutsPanel == nil && firstResponderIsActiveTerminal)
        await cmd("/")
        await waitUntil(1) { app.shortcutsPanel != nil }
        if let c = tileCenter(ws.activeTile) { await click(NSPoint(x: c.x, y: c.y + 200)) }
        r.check("a click closes it", app.shortcutsPanel == nil && firstResponderIsActiveTerminal)
        // Smallest window: one column, still inside.
        let frame = w.frame
        w.setFrame(NSRect(origin: frame.origin, size: w.minSize), display: true)
        await sleep(200)
        await cmd("/")
        await waitUntil(1) { app.shortcutsPanel != nil }
        if let p = app.shortcutsPanel {
            let main = ws.area.frame
            r.check("in the smallest window the panel fits inside the main area, its list scrolling",
                    main.contains(p.frame) && p.scrolls, "\(p.frame) in \(main), scrolls \(p.scrolls)")
            shot("20-shortcuts-panel-small")
        }
        await key(53, "\u{1b}")
        w.setFrame(frame, display: true)
        await sleep(200)
        // While the rename field has the keyboard the nav menu items are off, so Shift+arrows edit the text.
        app.sidebar.beginRename(session: api)
        await sleep(100)
        let next = app.menuItem(titled: "Next Session")!
        r.check("nav menu items are off while a rename has the keyboard", !app.validateMenuItem(next))
        await key(53, "\u{1b}")
        await waitUntil(1) { firstResponderIsActiveTerminal }
        r.check("…and on again once the terminal has it", app.validateMenuItem(next))
    }
}
