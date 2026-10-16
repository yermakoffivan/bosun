import AppKit
import BosunCore
import os
import UniformTypeIdentifiers

/// The main area (design section 6): the shown sidebar row's panes, one per live tab, laid out from
/// that row's split tree by hand (no Auto Layout), with the warm pool's views positioned inside them,
/// per-pane chrome, dividers, click/hover activation and drops. Every row keeps its own tree and its
/// active pane; showing another row swaps the whole area for that row's panes.
@MainActor
final class Workspace {
    unowned let app: AppController
    let area = MainAreaView()
    let pool: TerminalPool
    /// Every row's layout, by container id. A row gets one the first time it's shown (or prewarmed).
    private(set) var rows: [String: RowLayout] = [:]
    /// The row on screen (a container id), nil before there is any.
    private(set) var currentRow: String?
    private var chrome: [TileID: TileChromeView] = [:]
    /// Chrome views of panes that went, kept for the next row's panes so a switch makes no new views.
    private var spareChrome: [TileChromeView] = []
    private var dividers: [DividerView] = []
    private var lastLayout = SplitNode.Layout()
    static let headerHeight: CGFloat = 26
    static let gap: CGFloat = 1
    static let inset: CGFloat = 5
    private var windowKey = true
    private var dropTile: TileID?
    /// A pane being dragged by its header, and where it would land (see `tileDragMoved`).
    private var tileDrag: (tile: TileID, target: TileID?, zone: TileDropZone?)?
    let dropIndicator = TileDropIndicatorView()
    /// Sessions whose deferred agent launch waits for their terminal to attach.
    private var pendingLaunch: [String: Bool?] = [:]
    /// Panes the app asked for (Cmd+D, New Tab…): where the row's next new tab goes, until it arrives.
    private var pendingSplits: [String: (split: PendingSplit, at: Date)] = [:]
    /// A tab the app created that should become its row's active pane once it has one.
    private var activateWhenPlaced: [String: String] = [:]
    /// Panes closed with Cmd+W whose kill hasn't landed: a delta that still lists them as alive
    /// mustn't bring the pane back.
    private var closing: Set<String> = []
    /// The row order at the last reconcile, to find the neighbour of a row that went.
    private var lastRowOrder: [String] = []
    /// The old single-tree layout file's active session: its row is shown first after the change.
    private var legacyActive: String?
    /// Views attach only once the app has the daemon's tmux socket (`startAttaching`).
    private var attaching = false
    private var saveTimer: Timer?
    /// When the current row switch started (the warm and cold measurements count from here).
    private var switchStart: CFTimeInterval?
    /// Hooks for the self-test: (session, warm, seconds to first frame / first painted frame).
    var onShowMeasured: ((String, Bool, Double, Double?) -> Void)?
    /// Self-test hook: a row was shown (row id, every pane warm, seconds of main-thread work for the swap).
    var onRowShown: ((String, Bool, Double) -> Void)?

    init(app: AppController) {
        self.app = app
        pool = TerminalPool(daemon: app.daemon, capacity: AppSettings.shared.poolSize)
        pool.container = area
        pool.onExit = { [weak self] s in self?.terminalExited(s) }
        area.workspace = self
        area.registerForDraggedTypes(DropReader.types)
    }

    // MARK: What is shown

    /// The shown row's layout (empty when there's no row, or every tab of it has ended).
    var layout: RowLayout { currentRow.flatMap { rows[$0] } ?? RowLayout() }
    /// The shown row as the daemon describes it.
    var container: Container? { currentRow.flatMap { app.daemon.state.sidebar.container(id: $0) } }

    /// The tree on screen: the row's panes; for a row whose tabs have all ended, one tile for its
    /// active tab (the exited placeholder, with Restart); with no rows at all, one empty tile ("").
    var displayRoot: SplitNode {
        if let r = layout.root { return r }
        if let c = container { return .leaf(c.active) }
        return .leaf("")
    }

    var tiles: [TileID] { displayRoot.leaves }
    var activeTile: TileID { layout.active ?? tiles[0] }
    /// The active pane's session (an exited row's ended tab while it shows the placeholder).
    var activeSession: String? { activeTile.isEmpty ? nil : activeTile }
    var activeTerminal: TerminalView? {
        guard layout.contains(activeTile) else { return nil }
        return pool.view(for: activeTile).flatMap { $0.exited ? nil : $0 }
    }
    /// The panes on screen.
    var visibleSessions: Set<String> { Set(layout.panes) }
    var tileRects: [TileID: CGRect] { lastLayout.tiles }
    func headerSession(_ tile: TileID) -> String? { chrome[tile]?.headerSession }
    func session(in tile: TileID) -> String? { tile.isEmpty ? nil : tile }

    func terminal(in tile: TileID) -> TerminalView? {
        layout.contains(tile) ? pool.view(for: tile) : nil
    }

    /// The pane a row would show with the keyboard: its remembered active pane, else its active tab.
    func rememberedPane(row id: String) -> String? {
        rows[id]?.active ?? app.daemon.state.sidebar.container(id: id)?.active
    }

    private var aspect: Double {
        let b = area.bounds
        return b.height > 1 && b.width > 1 ? Double(b.width / b.height) : 1.6
    }

    /// A row's tabs that can have a pane: alive, known to the daemon, and not being closed.
    func liveTabs(_ c: Container) -> [String] {
        c.tabs.filter { $0.alive && app.isAlive($0.session) && !closing.contains($0.session) }.map(\.session)
    }

    // MARK: Persistence

    private var layoutURL: URL { Paths.supportDir.appendingPathComponent("rows-\(Paths.key(for: app.daemon.socketPath)).json") }
    /// The one-tree-per-window layout of earlier builds.
    private var legacyURL: URL { Paths.supportDir.appendingPathComponent("layout-\(Paths.key(for: app.daemon.socketPath)).json") }

    func restore() {
        if let data = try? Data(contentsOf: layoutURL), let saved = SavedLayouts.decode(data) {
            rows = saved.rows
            currentRow = saved.current
        } else if let data = try? Data(contentsOf: legacyURL) {
            legacyActive = SavedLayouts.legacyActiveSession(data)
        }
        reconcile(focus: false)
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let data = SavedLayouts(current: currentRow, rows: rows).encoded() else { return }
        try? data.write(to: layoutURL, options: .atomic)
        // The old layout can't be carried over (its tiles mixed rows); once the new file exists it goes.
        if FileManager.default.fileExists(atPath: legacyURL.path) { try? FileManager.default.removeItem(at: legacyURL) }
    }

    /// Save soon: pane activation (hover included) changes the model often, the file needn't follow every step.
    private func scheduleSave() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    // MARK: Rows

    /// Show a row: its whole layout replaces the main area, and the keyboard goes to `pane` if given,
    /// else to the pane that was active when the row was last shown.
    func selectRow(_ id: String, pane: TileID? = nil, focus: Bool = true) {
        guard app.daemon.state.sidebar.container(id: id) != nil else { return }
        if id == currentRow {
            if let pane, layout.contains(pane) { activate(pane, focus: focus) } else if focus { focusActiveTerminal() }
            return
        }
        let t0 = CACurrentMediaTime()
        let sp = signposter.beginInterval("RowSwitch", id: signposter.makeSignpostID(), "\(id, privacy: .public)")
        // The row we leave tells the daemon which tab it was on, so the TUI shows the same one.
        if let old = currentRow { app.syncActiveTab(row: old, pane: rows[old]?.active) }
        let before = layout.panes
        reconcileRow(id, create: true)
        if let pane { rows[id]?.activate(pane) }
        currentRow = id
        legacyActive = nil
        switchStart = t0
        let warm = layout.panes.allSatisfy { pool.isWarm($0) }
        apply(previous: before, focus: focus)
        switchStart = nil
        let spent = CACurrentMediaTime() - t0
        signposter.endInterval("RowSwitch", sp)
        save()
        onRowShown?(id, warm, spent)
    }

    /// Show `session`'s row with that pane active (a dead tab just shows its row).
    func show(_ session: String, focus: Bool = true) {
        guard let c = app.daemon.state.sidebar.container(holding: session) else { return }
        selectRow(c.id, pane: session, focus: focus)
    }

    /// Match a row's layout to its live tabs. `create` gives a row its first layout.
    @discardableResult
    private func reconcileRow(_ id: String, create: Bool) -> RowLayout.Change? {
        guard let c = app.daemon.state.sidebar.container(id: id), create || rows[id] != nil else { return nil }
        var l = rows[id] ?? RowLayout()
        var pending = pendingSplits[id]
        if let p = pending, Date().timeIntervalSince(p.at) > 15 {
            pendingSplits[id] = nil
            pending = nil
        }
        let change = l.reconcile(liveTabs: liveTabs(c), preferredActive: c.active, aspect: aspect, pending: pending?.split)
        if change.usedPending { pendingSplits[id] = nil }
        if let want = activateWhenPlaced[id], l.contains(want) {
            l.activate(want)
            activateWhenPlaced[id] = nil
        }
        if rows[id] != l { rows[id] = l }
        return change
    }

    /// The daemon's sidebar or sessions changed: match every row's panes to its tabs, keep a row on
    /// screen, attach panes that appeared in it and let go of the ones that went. Views that stay are
    /// never touched.
    func reconcile(focus: Bool = true) {
        let st = app.daemon.state
        let sb = st.sidebar
        let order = sb.allRows.map(\.id)
        closing = closing.filter { app.isAlive($0) }
        // The shown row's active session, read before rows that went are dropped: if its row was merged
        // into another, the screen follows the session there.
        let shownActive = layout.active
        if st.live {
            let ids = Set(order)
            rows = rows.filter { ids.contains($0.key) }
            pendingSplits = pendingSplits.filter { ids.contains($0.key) }
        }
        let before = layout.panes
        let beforeActive = layout.active
        for id in Array(rows.keys) { reconcileRow(id, create: false) }

        // Keep a row on screen: the old file's session's row on the first run after the change, the
        // neighbour of a row that went (once the state is live, not from the cache), or the first row.
        var target = currentRow
        if let legacy = legacyActive, let c = sb.container(holding: legacy) {
            target = c.id
            legacyActive = nil
        }
        if let t = target, !order.contains(t), st.live, let s = shownActive, let moved = sb.container(holding: s) {
            target = moved.id
            activateWhenPlaced[moved.id] = s
        } else if let t = target, !order.contains(t), st.live {
            let i = lastRowOrder.firstIndex(of: t) ?? 0
            let later = lastRowOrder.dropFirst(i + 1).first { order.contains($0) }
            let earlier = lastRowOrder.prefix(i).last { order.contains($0) }
            target = later ?? earlier ?? order.first
        }
        if target == nil {
            target = sb.allRows.first { !liveTabs($0).isEmpty }?.id ?? order.first
        }
        if !order.isEmpty { lastRowOrder = order }
        if target != currentRow {
            if let t = target { reconcileRow(t, create: true) }
            currentRow = target
            apply(previous: before, focus: focus)
            save()
            return
        }
        if let c = currentRow, order.contains(c) { reconcileRow(c, create: true) }
        let changed = layout.panes != before || layout.active != beforeActive || layout.root == nil
        apply(previous: before, focus: focus && changed)
        if changed { scheduleSave() }
    }

    /// Make the screen match the model: frames, chrome, and a live view in every pane of the shown row.
    private func apply(previous: [TileID], focus: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lastLayout = displayRoot.layout(in: area.bounds, gap: Workspace.gap)
        // Others first and the active pane last, so it's the most recently used in the pool.
        let panes = layout.panes.filter { $0 != layout.active } + layout.panes.filter { $0 == layout.active }
        for s in panes {
            if let v = pool.view(for: s), !v.exited, !v.isHidden { pool.touch(s); continue }
            attachVisible(s)
        }
        for s in previous where !layout.contains(s) { pool.hide(s) }
        pool.evict(keeping: visibleSessions)
        app.focus.setTiles(count: tiles.count, active: activeTile)
        syncChrome()
        CATransaction.commit()
        if focus { focusActiveTerminal() }
        app.workspaceChanged()
    }

    /// The app got the daemon's tmux socket: attach the shown row's panes.
    func startAttaching() {
        pool.tmuxSocket = app.daemon.state.server?.tmuxSocket
        guard app.daemon.state.server != nil else { return }
        attaching = true
        reconcile()
        focusActiveTerminal()
    }

    /// Start attaching a row's panes in the background (hover, keyboard stepping), so showing it is warm.
    /// The active pane first, then the others.
    func prewarm(row id: String) {
        guard attaching, id != currentRow, app.daemon.state.sidebar.container(id: id) != nil else { return }
        reconcileRow(id, create: true)
        guard let l = rows[id], let root = l.root else { return }
        let rects = root.layout(in: area.bounds, gap: Workspace.gap).tiles
        let order = l.panes.filter { $0 == l.active } + l.panes.filter { $0 != l.active }
        for s in order where app.isAlive(s) {
            pool.prewarm(s, size: Workspace.terminalRect(in: rects[s] ?? area.bounds).size)
        }
        pool.evict(keeping: visibleSessions)
    }

    // MARK: Showing sessions

    /// Put a session's view into its pane: swap in a warm view, or attach a new one.
    private func attachVisible(_ session: String) {
        guard attaching, app.isAlive(session) else { return }
        let rect = terminalRect(for: session)
        let t0 = switchStart ?? CACurrentMediaTime()
        let (v, warm) = pool.acquire(session, frame: rect, hidden: false)
        let label: StaticString = warm ? "WarmSwitch" : "ColdAttach"
        let sp = signposter.beginInterval(label, id: signposter.makeSignpostID(), "\(session, privacy: .public)")
        if v.frame != rect { v.frame = rect }
        v.resizeThrottle = 0
        pool.reveal(session, wasWarm: warm)
        if !warm && !v.hasPaintedContent {
            // Stay transparent until tmux paints, so login(1)'s banner never flashes up. (Layer opacity,
            // not alphaValue: AppKit won't make a view with alphaValue 0 first responder.)
            v.layer?.opacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak v] in MainActor.assumeIsolated { v?.layer?.opacity = 1 } }
        }
        var first: Double?
        let before = v.contentsCount
        // A pooled view can still be waiting for tmux's first paint (shown again before it drew).
        let awaitingPaint = !v.hasPaintedContent
        v.onContents = { [weak self] view in
            let now = CACurrentMediaTime()
            if first == nil {
                first = now - t0
                signposter.endInterval(label, sp)
                if warm { self?.onShowMeasured?(session, true, first!, nil) }
            }
            if awaitingPaint, view.contentsCount - before >= 1, view.hasPaintedContent {
                view.onContents = nil
                view.layer?.opacity = 1
                let painted = now - t0
                signposter.emitEvent("AttachFirstPaint", "\(session, privacy: .public)")
                if !warm { self?.onShowMeasured?(session, false, first ?? painted, painted) }
                self?.app.terminalPainted(session)
                self?.launchIfPending(session)
            } else if !awaitingPaint {
                view.onContents = nil
            }
        }
        if !awaitingPaint { launchIfPending(session) }
    }

    func expectLaunch(_ session: String, resume: Bool?) {
        pendingLaunch[session] = resume
        if let v = pool.view(for: session), v.hasPaintedContent { launchIfPending(session) }
    }

    private func launchIfPending(_ session: String) {
        guard let resume = pendingLaunch.removeValue(forKey: session) else { return }
        // A beat after tmux's first paint, so the agent's startup probes reach an attached client.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [app] in
            MainActor.assumeIsolated { app.daemon.command(.launchAgent(session: session, resume: resume)) }
        }
    }

    private func terminalExited(_ session: String) {
        // The tmux client ended on its own: the session was killed or the client detached elsewhere.
        pool.drop(session)
        if layout.contains(session), app.isAlive(session) {
            // Still alive (detached by someone else, or Ctrl+q): attach again.
            attachVisible(session)
            // The old view had the keyboard; the new one takes it over.
            if session == activeTile { focusActiveTerminal() }
        }
        syncChrome()
    }

    /// The daemon saw the tmux client on `tty` move to `target` (nil: it detached). Bosun's tmux
    /// bindings for the TUI (prefix 1-9, `switch-client`), or tmux's own, typed inside a terminal can
    /// do that. A pane always shows its own tab, so the client always goes back; the app follows the
    /// move instead: a tab of the same row becomes the active pane, a tab of another row shows that row.
    func clientMoved(tty: String, to target: String?) {
        guard let v = pool.view(onTTY: tty) else { return }  // not one of ours, or already going away
        let session = v.session
        // A detach also ends the `tmux attach` in the view, and `terminalExited` attaches it again.
        // Attaches and `make_latest` report the session the client is already on.
        guard let target, target != session else { return }
        log.info("client \(tty, privacy: .public) moved from \(session, privacy: .public) to \(target, privacy: .public); moving it back")
        pool.moveClient(tty, to: session)
        // A hidden pooled view: nobody is looking at it, so putting it back is all.
        guard layout.contains(session), !v.isHidden else { return }
        guard app.isAlive(target), let c = app.daemon.state.sidebar.container(holding: target) else { return }
        if c.id == currentRow {
            activate(target)
        } else {
            selectRow(c.id, pane: target)
        }
    }

    /// Sessions went away: free their views, then match the layouts to the new state.
    func stateChanged(removed: Set<String>) {
        for s in removed { pool.drop(s) }
        reconcile()
    }

    // MARK: New and closed panes

    /// The app is creating a tab in row `id` (Cmd+D, New Tab…): the row's next new tab splits `from`.
    func expectSplit(row id: String, from: TileID?, axis: SplitAxis) {
        pendingSplits[id] = (PendingSplit(from: from, axis: axis), Date())
    }

    func cancelSplit(row id: String) { pendingSplits[id] = nil }

    /// The daemon acknowledged a tab the app created: show its row with that pane active (once it's there).
    func paneCreated(_ session: String, row id: String) {
        if rows[id]?.contains(session) == true {
            selectRow(id, pane: session)
        } else {
            activateWhenPlaced[id] = session
            selectRow(id)
        }
    }

    /// Cmd+W, after any confirmation: the pane goes now (its sibling takes the space and the keyboard)
    /// and the kill follows. The last pane of a row isn't removed here: the row shows what the daemon
    /// reports once the kill lands (gone, or exited).
    func closePane(_ session: String) {
        guard let id = currentRow, rows[id]?.contains(session) == true, layout.count > 1 else { return }
        let before = layout.panes
        closing.insert(session)
        rows[id]?.close(session)
        apply(previous: before, focus: true)
        save()
    }

    /// The kill for a closed pane failed: it comes back.
    func closeFailed(_ session: String) {
        closing.remove(session)
        reconcile()
    }

    // MARK: Panes

    func activate(_ tile: TileID, focus: Bool = true) {
        guard let id = currentRow, layout.contains(tile) else {
            if focus { focusActiveTerminal() }
            return
        }
        let changed = tile != layout.active
        rows[id]?.activate(tile)
        app.focus.activate(tile)
        if changed {
            pool.touch(tile)
            updateChromeState()
            app.workspaceChanged()
            scheduleSave()
        }
        if focus { focusActiveTerminal() }
    }

    func focusActiveTerminal() {
        guard app.focus.terminalOwnsKeyboard, let w = area.window else { return }
        if let t = activeTerminal {
            if w.firstResponder !== t { w.makeFirstResponder(t) }
        } else if w.firstResponder is TerminalView {
            w.makeFirstResponder(nil)
        }
    }

    /// Previous/next tab: the active pane moves through the row's panes in tab order.
    func stepPane(forward: Bool) {
        guard let c = container, let next = layout.step(forward: forward, order: c.tabs.map(\.session)) else { return }
        activate(next)
    }

    func moveFocus(_ d: Direction) {
        guard let n = SplitNode.neighbor(of: activeTile, d, in: lastLayout) else { NSSound.beep(); return }
        activate(n)
    }

    func tile(at point: NSPoint) -> TileID? {
        lastLayout.tiles.first { $0.value.contains(point) }?.key
    }

    func terminalRect(for tile: TileID) -> NSRect {
        Workspace.terminalRect(in: lastLayout.tiles[tile] ?? area.bounds)
    }

    /// The terminal inside a pane's rect: below the header, inset a little so text never touches the
    /// ring (the margin shows the terminal's own background).
    static func terminalRect(in r: CGRect) -> NSRect {
        let i = Workspace.inset
        return NSRect(x: r.minX + i, y: r.minY + Workspace.headerHeight + 2, width: max(1, r.width - 2 * i),
                      height: max(1, r.height - Workspace.headerHeight - 2 - i))
    }

    // MARK: Layout

    func relayout() {
        lastLayout = displayRoot.layout(in: area.bounds, gap: Workspace.gap)
        syncChrome()
    }

    /// Create/remove chrome views to match the tree, then position everything.
    func syncChrome() {
        let ids = Set(tiles)
        // A pane closed mid-drag (Cmd+W with the header held) never gets its mouse up.
        if let d = tileDrag, !ids.contains(d.tile) { cancelTileDrag() }
        for (id, v) in chrome where !ids.contains(id) {
            v.isHidden = true
            v.frame = .zero
            chrome[id] = nil
            spareChrome.append(v)
        }
        for id in tiles where chrome[id] == nil {
            let c = spareChrome.popLast() ?? TileChromeView(tile: id, workspace: self)
            c.tile = id
            c.isHidden = false
            chrome[id] = c
            if c.superview == nil { area.addSubview(c) }
        }
        let divs = lastLayout.dividers
        while dividers.count > divs.count { dividers.removeLast().removeFromSuperview() }
        while dividers.count < divs.count {
            let d = DividerView(workspace: self)
            dividers.append(d)
            area.addSubview(d)
        }
        positionAll()
        updateChromeState()
    }

    private func positionAll() {
        if Set(lastLayout.tiles.keys) != Set(tiles) { lastLayout = displayRoot.layout(in: area.bounds, gap: Workspace.gap) }
        for (id, c) in chrome {
            guard let r = lastLayout.tiles[id] else { continue }
            if c.frame != r { c.frame = r }
            if layout.contains(id), let v = pool.view(for: id) {
                let tr = terminalRect(for: id)
                if v.frame != tr { v.frame = tr }
            }
        }
        for (i, d) in lastLayout.dividers.enumerated() where i < dividers.count {
            dividers[i].divider = d
            let hit: CGFloat = 7
            let r = d.axis == .horizontal
                ? NSRect(x: d.rect.midX - hit / 2, y: d.rect.minY, width: hit, height: d.rect.height)
                : NSRect(x: d.rect.minX, y: d.rect.midY - hit / 2, width: d.rect.width, height: hit)
            dividers[i].frame = r
        }
    }

    /// Ring, dimming, headers and placeholders from the current state and theme.
    func updateChromeState() {
        let theme = app.theme
        let ring = tiles.count >= 2
        let active = activeTile
        for (id, c) in chrome {
            let s = session(in: id)
            let hasTerminal = layout.contains(id) && app.isAlive(id)
            c.update(session: s, active: id == active, showRing: ring, windowKey: windowKey,
                     hasTerminal: hasTerminal, dropTarget: dropTile == id, theme: theme)
        }
        for d in dividers { d.color = theme.shadow; d.needsDisplay = true }
        area.layer?.backgroundColor = (GhosttyRuntime.shared.configColor("background") ?? theme.bg).cgColor
    }

    func windowKeyChanged(_ key: Bool) {
        windowKey = key
        updateChromeState()
    }

    // MARK: Divider drag

    private var dragSignpost: OSSignpostIntervalState?

    func dividerDragBegan() {
        dragSignpost = signposter.beginInterval("DividerDrag", id: signposter.makeSignpostID())
        for s in visibleSessions { pool.view(for: s)?.resizeThrottle = 0.1 }
    }

    func dividerDragged(_ d: SplitNode.Divider, to point: NSPoint) {
        guard let id = currentRow else { return }
        rows[id]?.setRatio(at: d.path, SplitNode.ratio(for: d, at: point, gap: Workspace.gap))
        lastLayout = displayRoot.layout(in: area.bounds, gap: Workspace.gap)
        positionAll()
    }

    func dividerDragEnded() {
        for s in visibleSessions {
            guard let v = pool.view(for: s) else { continue }
            v.flushGridSize()
            v.resizeThrottle = 0
        }
        if let sp = dragSignpost { signposter.endInterval("DividerDrag", sp) }
        dragSignpost = nil
        save()
    }

    // MARK: Moving panes by their header

    var tileDragActive: Bool { tileDrag != nil }
    /// Where the dragged pane would land right now (for the test modes): nil while a drop would do nothing.
    var tileDropTarget: (target: TileID, zone: TileDropZone)? {
        guard let d = tileDrag, let t = d.target, let z = d.zone else { return nil }
        return (t, z)
    }

    /// A header drag passed the threshold. Only with two or more panes, and never while the keyboard is lent out.
    func tileDragBegan(_ tile: TileID) -> Bool {
        guard layout.count > 1, layout.contains(tile), app.focus.exception == nil else { return false }
        tileDrag = (tile, nil, nil)
        area.addSubview(dropIndicator, positioned: .above, relativeTo: nil)
        dropIndicator.frame = area.bounds
        dropIndicator.show(nil, swap: false, theme: app.theme)
        NSCursor.closedHand.push()
        return true
    }

    /// The pointer moved during a pane drag (`p` in the area's coordinates). The indicator shows where
    /// the pane would go, and only for a drop that changes something.
    func tileDragMoved(to p: NSPoint) {
        guard var d = tileDrag else { return }
        var rect: CGRect?
        d.target = nil
        d.zone = nil
        if let t = tile(at: p), let r = lastLayout.tiles[t] {
            let zone = TileDropZone.at(p, in: r)
            if layout.root?.moving(d.tile, to: t, zone: zone) != nil {
                d.target = t
                d.zone = zone
                rect = zone.indicatorRect(in: r)
            }
        }
        tileDrag = d
        dropIndicator.show(rect, swap: d.zone == .swap, theme: app.theme)
    }

    /// Mouse up: move the pane if the pointer is over a drop that changes something; anywhere else cancels.
    func tileDragEnded(at p: NSPoint) {
        guard tileDrag != nil else { return }
        tileDragMoved(to: p)
        let d = tileDrag!
        endTileDrag()
        if let target = d.target, let zone = d.zone { moveTile(d.tile, to: target, zone: zone) }
    }

    /// Esc during a drag.
    func cancelTileDrag() {
        guard tileDrag != nil else { return }
        endTileDrag()
    }

    private func endTileDrag() {
        tileDrag = nil
        dropIndicator.show(nil, swap: false, theme: app.theme)
        dropIndicator.removeFromSuperview()
        NSCursor.pop()
    }

    /// Move a pane within the row's tree. Its terminal view goes with it (no reattach); it stays active and keeps the keyboard.
    func moveTile(_ tile: TileID, to target: TileID, zone: TileDropZone) {
        guard let id = currentRow, rows[id]?.move(tile, to: target, zone: zone) == true else { return }
        app.focus.setTiles(count: tiles.count, active: activeTile)
        relayout()
        focusActiveTerminal()
        app.workspaceChanged()
        save()
    }

    // MARK: Pointer

    func tileClicked(_ tile: TileID) {
        activate(tile)
    }

    /// Focus follows the mouse: called for real mouse-moved events in the window.
    func pointerMoved(_ event: NSEvent) {
        let p = area.convert(event.locationInWindow, from: nil)
        let over = area.bounds.contains(p) ? tile(at: p) : nil
        let screen = area.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if let t = app.focus.pointerMoved(to: screen, over: over, buttonsDown: NSEvent.pressedMouseButtons != 0) {
            activate(t)
        }
    }

    // MARK: Drops

    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let p = area.convert(info.draggingLocation, from: nil)
        let t = tile(at: p)
        let ok = t.map { layout.contains($0) && app.isAlive($0) } ?? false
        let target = ok ? t : nil
        if target != dropTile {
            dropTile = target
            updateChromeState()
        }
        return ok ? .copy : []
    }

    func dragEnded() {
        if dropTile != nil {
            dropTile = nil
            updateChromeState()
        }
    }

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        let p = area.convert(info.draggingLocation, from: nil)
        dragEnded()
        guard let t = tile(at: p), layout.contains(t), app.isAlive(t) else { return false }
        activate(t)
        DropReader.read(info.draggingPasteboard) { [weak self] text in
            guard let text, let v = self?.pool.view(for: t) else { return }
            v.paste(text)
        }
        return true
    }
}

// MARK: - Views

final class MainAreaView: NSView {
    weak var workspace: Workspace?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        MainActor.assumeIsolated { workspace?.relayout() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { workspace?.dragUpdated(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { workspace?.dragUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { workspace?.dragEnded() }
    override func draggingEnded(_ sender: NSDraggingInfo) { workspace?.dragEnded() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { workspace?.performDrop(sender) ?? false }
}

/// Per-pane chrome above the terminal: header strip, active ring or inactive border and dimming,
/// and the placeholder for an exited row or an empty main area. Clicks on an inactive tile stop here (consumed).
final class TileChromeView: NSView {
    /// The pane (its tab's session) this chrome is on; chrome views are reused across rows.
    var tile: TileID
    unowned let workspace: Workspace
    private let header = TileHeaderView()
    private let border = CALayer()
    private let dim = CALayer()
    private let dropHighlight = CALayer()
    private var placeholder: PlaceholderView?
    private(set) var isActive = false
    private var session: String?
    /// The session the header names, and the placeholder (for the test modes).
    var headerSession: String? { session }
    var placeholderView: PlaceholderView? { placeholder }

    override var isFlipped: Bool { true }

    init(tile: TileID, workspace: Workspace) {
        self.tile = tile
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(header)
        layer?.addSublayer(dim)
        layer?.addSublayer(dropHighlight)
        layer?.addSublayer(border)
        border.zPosition = 10
        dropHighlight.zPosition = 9
        header.onClick = { [weak self] in
            guard let self else { return }
            self.workspace.tileClicked(self.tile)
        }
        header.onDragBegan = { [weak self] in
            guard let self else { return false }
            return self.workspace.tileDragBegan(self.tile)
        }
        header.onDragMoved = { [weak self] e in
            guard let self else { return }
            self.workspace.tileDragMoved(to: self.workspace.area.convert(e.locationInWindow, from: nil))
        }
        header.onDragEnded = { [weak self] e in
            guard let self else { return }
            self.workspace.tileDragEnded(at: self.workspace.area.convert(e.locationInWindow, from: nil))
        }
        header.menuProvider = { [weak self] in
            guard let self, let s = self.session else { return nil }
            return self.workspace.app.sessionMenu(for: s)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Workspace.headerHeight)
        placeholder?.frame = NSRect(x: 0, y: Workspace.headerHeight, width: bounds.width, height: max(0, bounds.height - Workspace.headerHeight))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        dim.frame = NSRect(x: 0, y: Workspace.headerHeight, width: bounds.width, height: max(0, bounds.height - Workspace.headerHeight))
        dropHighlight.frame = bounds.insetBy(dx: 2, dy: 2)
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func update(session: String?, active: Bool, showRing: Bool, windowKey: Bool, hasTerminal: Bool, dropTarget: Bool, theme: AppTheme) {
        self.session = session
        isActive = active
        let app = workspace.app
        header.draggable = showRing
        header.update(name: session.map { app.displayName($0) }, group: session.flatMap { app.groupLabel($0) },
                      state: session.map { app.displayState($0) }, detail: session.flatMap { app.statusDetail($0) },
                      exited: session.map { !app.isAlive($0) } ?? false, active: active && showRing, theme: theme)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if showRing && active {
            border.borderWidth = 2
            border.borderColor = (windowKey ? theme.accent : theme.accent.withAlphaComponent(0.4)).cgColor
        } else if showRing {
            border.borderWidth = 1
            border.borderColor = theme.panelAlt.cgColor
        } else {
            border.borderWidth = 0
        }
        dim.backgroundColor = (GhosttyRuntime.shared.configColor("background") ?? theme.bg).withAlphaComponent(0.4).cgColor
        dim.isHidden = !(showRing && !active && hasTerminal)
        dropHighlight.backgroundColor = theme.accent.withAlphaComponent(0.12).cgColor
        dropHighlight.borderColor = theme.accent.cgColor
        dropHighlight.borderWidth = 2
        dropHighlight.cornerRadius = 4
        dropHighlight.isHidden = !dropTarget
        CATransaction.commit()

        if hasTerminal {
            placeholder?.removeFromSuperview()
            placeholder = nil
        } else {
            if placeholder == nil {
                let p = PlaceholderView()
                placeholder = p
                addSubview(p, positioned: .below, relativeTo: header)
                needsLayout = true
            }
            placeholder?.configure(session: session, app: app, theme: theme)
        }
        layer?.backgroundColor = hasTerminal ? nil : theme.bg.cgColor
    }

    /// Inactive tiles take the click (to activate, consumed). The active tile lets it through to the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // A spare chrome view (kept for the next row's panes) is hidden and must never take a click.
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if p.y < Workspace.headerHeight { return header }
        if !isActive { return self }
        if let placeholder, let hit = placeholder.hitTest(convert(p, to: placeholder.superview)) { return hit }
        return placeholder != nil ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        workspace.tileClicked(tile)
    }

    override func scrollWheel(with event: NSEvent) {
        // Scrolling an inactive tile still scrolls its terminal.
        workspace.terminal(in: tile)?.scrollWheel(with: event)
    }
}

/// The thin strip above each terminal: status, session name, waiting detail.
final class TileHeaderView: NSView {
    private let badge = StatusBadge(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bottomLine = CALayer()
    var onClick: (@MainActor () -> Void)?
    var menuProvider: (@MainActor () -> NSMenu?)?
    /// Dragging the header moves the tile (only with two or more tiles).
    var onDragBegan: (@MainActor () -> Bool)?
    var onDragMoved: (@MainActor (NSEvent) -> Void)?
    var onDragEnded: (@MainActor (NSEvent) -> Void)?
    var draggable = false {
        didSet { if draggable != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var downAt: NSPoint?
    private var dragging = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [name, detail] {
            l.lineBreakMode = .byTruncatingTail
            l.isSelectable = false
            l.refusesFirstResponder = true
            addSubview(l)
        }
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        detail.font = .systemFont(ofSize: 11.5, weight: .regular)
        addSubview(badge)
        layer?.addSublayer(bottomLine)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        badge.frame = NSRect(x: 10, y: (h - 10) / 2, width: 10, height: 10)
        name.sizeToFit()
        let nameW = min(name.frame.width, bounds.width * 0.55)
        name.frame = NSRect(x: 27, y: (h - name.frame.height) / 2, width: nameW, height: name.frame.height)
        detail.sizeToFit()
        let dx = name.frame.maxX + 8
        detail.frame = NSRect(x: dx, y: (h - detail.frame.height) / 2, width: max(0, bounds.width - dx - 10), height: detail.frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomLine.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    func update(name n: String?, group: String?, state: AgentState?, detail d: String?, exited: Bool, active: Bool, theme: AppTheme) {
        layer?.backgroundColor = (active ? AppTheme.mix(theme.panel, theme.accent, 0.08) : theme.panel).cgColor
        bottomLine.backgroundColor = theme.shadow.cgColor
        if let n {
            name.stringValue = n
            name.textColor = exited ? theme.textMuted : theme.text
            badge.isHidden = false
            badge.set(state ?? .unknown, exited: exited, theme: theme)
        } else {
            name.stringValue = "No session"
            name.textColor = theme.textMuted
            badge.isHidden = true
        }
        var text = ""
        var color = theme.textMuted
        if exited {
            text = "exited"
        } else if let state {
            switch state {
            case .waiting:
                text = d.map { "waiting · \($0)" } ?? "waiting for you"
                color = theme.waiting
            case .error:
                text = d ?? "error"
                color = theme.error
            case .done:
                text = "done"
                color = theme.done
            case .running:
                text = d ?? ""
            default:
                text = ""
            }
        }
        if text.isEmpty, let group, !exited {
            text = group
            color = theme.textMuted
        }
        detail.stringValue = text
        detail.textColor = color
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = false
        onClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        if !dragging {
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
            guard onDragBegan?() == true else { downAt = nil; return }
            dragging = true
        }
        onDragMoved?(event)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onDragEnded?(event) }
        downAt = nil
        dragging = false
    }

    override func resetCursorRects() {
        if draggable { addCursorRect(bounds, cursor: .openHand) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// The translucent box over the tile a dragged tile would land on: the half it would take, or the
/// whole tile (inset) with "Swap" for a swap. Never takes clicks.
final class TileDropIndicatorView: NSView {
    private let box = CALayer()
    private let label = CATextLayer()
    private(set) var shownRect: CGRect?
    private(set) var showsSwap = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(box)
        box.addSublayer(label)
        box.cornerRadius = 8
        box.borderWidth = 2
        label.alignmentMode = .center
        label.fontSize = 13
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.string = "Swap"
        box.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ rect: CGRect?, swap: Bool, theme: AppTheme) {
        shownRect = rect
        showsSwap = rect != nil && swap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let rect else { box.isHidden = true; return }
        box.isHidden = false
        box.frame = rect.insetBy(dx: swap ? 10 : 5, dy: swap ? 10 : 5)
        box.backgroundColor = theme.accent.withAlphaComponent(0.2).cgColor
        box.borderColor = theme.accent.withAlphaComponent(0.85).cgColor
        label.isHidden = !swap
        label.foregroundColor = theme.text.cgColor
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 0, y: (box.bounds.height - 18) / 2, width: box.bounds.width, height: 18)
    }
}

/// What an exited row (every tab ended) or an empty main area (no rows at all) shows. Text wraps and stays centred however narrow the
/// tile gets; the buttons stack when they don't fit side by side, and what doesn't fit at all is left out.
final class PlaceholderView: NSView {
    let title = NSTextField(wrappingLabelWithString: "")
    let hint = NSTextField(wrappingLabelWithString: "")
    let primary = NSButton(title: "", target: nil, action: nil)
    let secondary = NSButton(title: "", target: nil, action: nil)
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    static let margin: CGFloat = 14

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        hint.font = .systemFont(ofSize: 12.5)
        for l in [title, hint] {
            l.alignment = .center
            l.refusesFirstResponder = true
            l.isSelectable = false
            l.maximumNumberOfLines = 4
            l.cell?.truncatesLastVisibleLine = true
            l.lineBreakMode = .byWordWrapping
            addSubview(l)
        }
        hint.maximumNumberOfLines = 6
        for (b, sel) in [(primary, #selector(primaryClicked)), (secondary, #selector(secondaryClicked))] {
            b.bezelStyle = .push
            b.controlSize = .regular
            b.refusesFirstResponder = true
            b.lineBreakMode = .byTruncatingTail
            b.target = self
            b.action = sel
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(session: String?, app: AppController, theme: AppTheme) {
        title.textColor = theme.text
        hint.textColor = theme.textMuted
        if let session {
            title.stringValue = "\(app.displayName(session)) has exited"
            hint.stringValue = "The tmux session ended. Restart it from its saved spec, or resume the agent's last conversation."
            primary.title = "Restart"
            secondary.title = "Resume"
            primaryAction = { app.restartExited(session, resume: false) }
            secondaryAction = { app.restartExited(session, resume: true) }
            secondary.isHidden = false
        } else {
            title.stringValue = "No sessions yet"
            hint.stringValue = "Each session is a row in the sidebar, and its tabs open side by side here. Start one with ⇧⌘N."
            primary.title = "New Session…"
            secondary.title = ""
            primaryAction = { app.newSession() }
            secondaryAction = nil
            secondary.isHidden = true
        }
        needsLayout = true
    }

    /// Height of a wrapping label at `width`.
    private func height(_ l: NSTextField, _ width: CGFloat) -> CGFloat {
        guard !l.stringValue.isEmpty, width > 0, let cell = l.cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
    }

    override func layout() {
        super.layout()
        let m = PlaceholderView.margin
        let w = max(0, min(bounds.width - 2 * m, 420))
        let x = (bounds.width - w) / 2
        let th = height(title, w)
        let hh = height(hint, w)
        primary.sizeToFit()
        secondary.sizeToFit()
        let two = secondaryAction != nil && !secondary.title.isEmpty
        let gap: CGFloat = 10
        let pw = min(primary.frame.width, w), sw = min(secondary.frame.width, w)
        let sideBySide = !two || pw + gap + sw <= w
        let buttonsH: CGFloat = sideBySide ? 28 : 28 * 2 + 8
        // Leave out what doesn't fit: first the buttons, then the hint.
        let avail = bounds.height - 2 * 10
        var showHint = hh > 0, showButtons = w >= 60
        func total() -> CGFloat { th + (showHint ? 8 + hh : 0) + (showButtons ? 14 + buttonsH : 0) }
        if total() > avail { showButtons = false }
        if total() > avail { showHint = false }
        hint.isHidden = !showHint
        primary.isHidden = !showButtons
        secondary.isHidden = !showButtons || !two
        var y = max(10, (bounds.height - total()) / 2)
        title.frame = NSRect(x: x, y: y, width: w, height: min(th, max(0, bounds.height - y)))
        y += th + 8
        if showHint {
            hint.frame = NSRect(x: x, y: y, width: w, height: hh)
            y += hh + 14
        } else {
            y += 6
        }
        guard showButtons else { return }
        if sideBySide {
            var bx = (bounds.width - (pw + (two ? gap + sw : 0))) / 2
            primary.frame = NSRect(x: bx, y: y, width: pw, height: 28)
            bx += pw + gap
            secondary.frame = NSRect(x: bx, y: y, width: sw, height: 28)
        } else {
            let bw = min(w, max(pw, sw))
            primary.frame = NSRect(x: (bounds.width - bw) / 2, y: y, width: bw, height: 28)
            secondary.frame = NSRect(x: (bounds.width - bw) / 2, y: y + 36, width: bw, height: 28)
        }
    }

    @objc private func primaryClicked() { primaryAction?() }
    @objc private func secondaryClicked() { secondaryAction?() }
}

/// A thin divider between tiles; the hit area is wider than the line it draws.
final class DividerView: NSView {
    unowned let workspace: Workspace
    var divider: SplitNode.Divider?
    var color: NSColor = .separatorColor
    private var dragging = false

    override var isFlipped: Bool { true }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let d = divider else { return }
        color.setFill()
        if d.axis == .horizontal {
            NSRect(x: (bounds.width - Workspace.gap) / 2, y: 0, width: Workspace.gap, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: (bounds.height - Workspace.gap) / 2, width: bounds.width, height: Workspace.gap).fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: divider?.axis == .vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        workspace.dividerDragBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let d = divider, let sv = superview else { return }
        workspace.dividerDragged(d, to: sv.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        workspace.dividerDragEnded()
    }
}

/// Turns a drag pasteboard into the text a terminal should receive: escaped file paths (space separated),
/// image data written to a temp file first, or plain text.
@MainActor
enum DropReader {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .string, .URL,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static var dropDir: URL {
        let d = Paths.cacheDir.appendingPathComponent("drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func canRead(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        return !Set(types).isDisjoint(with: Set(Self.types))
    }

    static func read(_ pb: NSPasteboard, _ done: @escaping (String?) -> Void) {
        // 1. Files.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            done(ShellEscape.dropText(paths: urls.map(\.path)))
            return
        }
        // 2. File promises (Photos, Mail, some screenshot thumbnails).
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let queue = OperationQueue()
            let dest = dropDir
            var paths: [String] = []
            let group = DispatchGroup()
            let lock = NSLock()
            for p in promises {
                group.enter()
                p.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { url, error in
                    if error == nil {
                        lock.lock()
                        paths.append(url.path)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                lock.lock()
                let got = paths
                lock.unlock()
                done(got.isEmpty ? nil : ShellEscape.dropText(paths: got))
            }
            return
        }
        // 3. Image data that isn't a file (a browser image, a screenshot thumbnail): write it out first.
        if let path = writeImage(pb) {
            done(ShellEscape.dropText(paths: [path]))
            return
        }
        // 4. Text.
        done(pb.string(forType: .string) ?? (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString)
    }

    static func writeImage(_ pb: NSPasteboard) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "drop-\(stamp)-\(UInt32.random(in: 0...0xffff))"
        if let png = pb.data(forType: .png) {
            let url = dropDir.appendingPathComponent("\(name).png")
            if (try? png.write(to: url)) != nil { return url.path }
        }
        if let jpg = pb.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            let url = dropDir.appendingPathComponent("\(name).jpg")
            if (try? jpg.write(to: url)) != nil { return url.path }
        }
        if let data = pb.data(forType: .tiff) ?? pb.data(forType: NSPasteboard.PasteboardType(UTType.heic.identifier)),
           let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            let url = dropDir.appendingPathComponent("\(name).png")
            if (try? png.write(to: url)) != nil { return url.path }
        }
        return nil
    }
}
