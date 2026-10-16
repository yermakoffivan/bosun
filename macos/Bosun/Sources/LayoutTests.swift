import AppKit
import BosunCore

// Focus-test sections for layout and dragging: the new-session sheet at every window and tile
// size, empty tiles in narrow tiles, moving tiles by their header, sidebar drag and drop through
// the outline's own drag code, and the keyboard shortcuts panel.

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

    func emptyState() async {
        guard let api = session("api") else { return }
        await showOnly(api)
        await cmd("d")
        await cmd("d")
        await waitUntil(3) { ws.layout.count == 3 }
        // Squeeze the first tile with the first divider, then empty it.
        let first = ws.layout.tiles[0]
        if let d = ws.area.subviews.compactMap({ $0 as? DividerView }).compactMap(\.divider).first(where: { $0.path.isEmpty }) {
            ws.dividerDragBegan()
            ws.dividerDragged(d, to: NSPoint(x: d.container.minX + 30, y: d.container.midY))
            ws.dividerDragEnded()
        }
        ws.clear(first)
        await sleep(200)
        let chrome = ws.area.subviews.compactMap { $0 as? TileChromeView }.first { $0.tile == first }
        let width = Int(ws.tileRects[first]?.width ?? 0)
        if let p = chrome?.placeholderView {
            let bad = placeholderProblems(p)
            r.check("a narrow empty tile (\(width) pt) wraps and centres its text, nothing cut off", bad.isEmpty, bad.joined(separator: "; "))
            r.check("…its title wraps onto more lines rather than running off the edge", p.title.frame.height > 22, "title \(p.title.frame)")
        } else {
            r.check("a narrow empty tile shows its placeholder", false)
        }
        shot("14-empty-tile-narrow")
        // Every width from very narrow to wide: nothing ever cut off.
        var bad: [String] = []
        if let d = ws.area.subviews.compactMap({ $0 as? DividerView }).compactMap(\.divider).first(where: { $0.path.isEmpty }), let p = chrome?.placeholderView {
            for x in stride(from: 20, through: Int(d.container.width * 0.6), by: 25) {
                ws.dividerDragged(d, to: NSPoint(x: d.container.minX + CGFloat(x), y: d.container.midY))
                ws.area.layoutSubtreeIfNeeded()
                bad += placeholderProblems(p).map { "\(Int(ws.tileRects[first]?.width ?? 0)) pt: \($0)" }
            }
            ws.dividerDragEnded()
        }
        r.check("an empty tile at every width from narrow to wide keeps its text inside", bad.isEmpty, bad.prefix(4).joined(separator: "; "))
        for _ in 0..<10 where ws.layout.count > 1 { ws.closeActive() }
        await showOnly(api)
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

    /// Tile → its terminal view, to check that moves reuse the same views (tiles keep their ids when moved).
    private var viewsByTile: [TileID: ObjectIdentifier] {
        var out: [TileID: ObjectIdentifier] = [:]
        for t in ws.layout.tiles { if let v = ws.terminal(in: t) { out[t] = ObjectIdentifier(v) } }
        return out
    }

    private func keysLandIn(_ s: String, _ tag: String) async -> Bool {
        await waitUntil(1) { firstResponderIsActiveTerminal }
        // Let the resize after a move settle (the agent redraws on SIGWINCH) before typing.
        await sleep(250)
        guard (w.firstResponder as? TerminalView)?.session == s else { return false }
        if app.displayName(s) == "ticker" { return true }
        await type("\(tag)\n")
        // Matched within a "got:" line: an earlier section can leave a stray key in the agent's input line.
        return await waitUntil(3) { pane(s).split(separator: "\n").contains { $0.hasPrefix("got: ") && $0.contains(tag) } }
    }

    func tileDrag() async {
        guard let api = session("api"), let docs = session("docs"), let parser = session("parser") else { return }
        await showOnly(api)
        await cmd("d")
        await cmd("d", [.shift])
        await waitUntil(3) { ws.layout.count == 3 }
        // Fixed sessions: api | (docs / parser).
        let tiles = ws.layout.tiles
        ws.show(api, in: tiles[0], focus: false)
        ws.show(docs, in: tiles[1], focus: false)
        ws.show(parser, in: tiles[2], focus: false)
        await waitUntil(3) { ws.layout.tiles.allSatisfy { ws.terminal(in: $0)?.hasPaintedContent == true } }
        await sleep(300)

        // Each edge: drag parser's tile onto api's tile, then check the tree, the views and the keyboard.
        let moving = ws.layout.tile(showing: parser)!
        let target = ws.layout.tile(showing: api)!
        var edgeShot = false
        for side in [Direction.left, .right, .up, .down] {
            let zone = TileDropZone.edge(side)
            let expected = ws.layout.root.moving(moving, to: target, zone: zone)
            guard let from = headerPoint(moving), let to = zonePoint(target, zone) else { continue }
            let views = viewsByTile
            let poolSize = ws.pool.views.count
            var indicator: CGRect?
            var reported: TileDropZone?
            let want = ws.tileRects[target].map { zone.indicatorRect(in: $0) }
            await drag(from: from, to: to) { [self] in
                indicator = ws.dropIndicator.shownRect
                reported = ws.tileDropTarget?.zone
                if !edgeShot, side == .right { edgeShot = true; shot("15-tile-drop-edge") }
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
            r.check("…and the dragged tile stays active with the keyboard", ws.activeTile == moving && ws.activeSession == parser)
            r.check("…typing reaches it", await keysLandIn(parser, "moved-\(side)"))
        }

        // Swap: two tiles that aren't the one just moved.
        let others = ws.layout.tiles.filter { $0 != moving && ws.layout.session(in: $0) != nil }
        guard others.count >= 2, let docsAgain = ws.layout.session(in: others[0]) else {
            r.check("tile drag: two other tiles with sessions to swap", false, "\(ws.layout.tiles.count) tiles")
            return
        }
        let a = others[0]
        let b = others[1]
        let swapped = ws.layout.root.swapping(a, b)
        let views = viewsByTile
        let poolSize = ws.pool.views.count
        if let from = headerPoint(a), let to = zonePoint(b, .swap) {
            var label = false
            await drag(from: from, to: to) { [self] in
                label = ws.dropIndicator.showsSwap
                shot("16-tile-drop-swap")
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
        if let from = headerPoint(b), let to = zonePoint(a, .edge(.down)), let side = sidebarPoint(docs) {
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
        if let t = ws.layout.tiles.first(where: { ws.layout.session(in: $0).map { app.displayName($0) != "ticker" } ?? false }),
           let target = ws.layout.session(in: t), let c = tileCenter(t) {
            let info = FakeDrag(location: c, pasteboard: pb, window: w)
            let op = ws.area.draggingEntered(info)
            r.check("a file dragged over a tile is still accepted, without the tile drop indicator",
                    op == .copy && ws.dropIndicator.shownRect == nil && ws.dropIndicator.superview == nil)
            _ = ws.area.performDragOperation(info)
            await sleep(150)
            await type("\n")
            r.check("…and the drop inserts the path as before", await paneShows(target, "got: \(ShellEscape.escape(file))"))
        }
        for _ in 0..<10 where ws.layout.count > 1 { ws.closeActive() }
        await showOnly(api)
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
        await showOnly(review1Session ?? api)
        let shownBefore = ws.activeSession

        // a) A row onto the lower edge of the next row: reordered among the ungrouped rows.
        if let from = rowPoint(rowItem(api), 0.5), let to = rowPoint(rowItem(docs), 0.92) {
            let res = await outlineDrag(from: from, to: to)
            r.check("sidebar: pressing a row and moving starts a drag (AppKit's own tracking)", res.started)
            r.check("…a row dropped below the next one is accepted", res.op == .move && res.accepted, "op \(res.op.rawValue)")
            await waitUntil(1) { names(app.daemon.state.sidebar.ungrouped) == ["docs", "api"] }
            r.check("…and the rows are reordered", names(app.daemon.state.sidebar.ungrouped) == ["docs", "api"],
                    "\(names(app.daemon.state.sidebar.ungrouped))")
            r.check("…a drag isn't a click: the tile still shows what it did", ws.activeSession == shownBefore)
        }
        // b) A row dropped on the middle of a row in a section: it goes into that section, beside that row.
        if let from = rowPoint(rowItem(api), 0.5), let to = rowPoint(rowItem(parser), 0.4) {
            let res = await outlineDrag(from: from, to: to)
            let work = app.daemon.state.sidebar.sections.first { $0.name == "Work" }
            r.check("sidebar: a row dropped on the middle of another row is accepted (not refused)", res.op == .move && res.accepted, "op \(res.op.rawValue)")
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
            r.check("sidebar: a tab dragged above its sibling reorders the row's tabs", res.accepted && tabs == ["web tests", "web"], "\(tabs) op \(res.op.rawValue)")
        }
        // e) A row dropped over a multi-tab row's tabs goes beside that row, not inside it (refused before).
        if let shell = session("shell"), let webTab = app.sidebar.itemFor(session: web),
           let from = rowPoint(rowItem(shell), 0.5), let to = rowPoint(webTab, 0.5, x: 80) {
            let res = await outlineDrag(from: from, to: to)
            let work = app.daemon.state.sidebar.sections.first { $0.name == "Work" }.map { names($0.members) } ?? []
            r.check("sidebar: a row dropped over another row's tabs lands beside that row", res.accepted && work.contains("shell"),
                    "Work: \(work) op \(res.op.rawValue)")
        }
        // f) Finder-style rename tells a click from a drag: dragging the selected row's name never renames.
        await showOnly(docs)
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
        await showOnly(api)
    }

    private var review1Session: String? { session("review-1") }

    // MARK: Keyboard shortcuts panel

    func shortcuts() async {
        guard let api = session("api") else { return }
        await showOnly(api)
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
        let navRows: [(String, NavAction)] = [("Next session", .nextSession), ("Previous session", .previousSession),
                                               ("Next tab", .nextTab), ("Previous tab", .previousTab),
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
        shot("17-shortcuts-panel")
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
            shot("18-shortcuts-panel-small")
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
