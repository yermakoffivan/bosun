import AppKit
import BosunCore
import os
import UniformTypeIdentifiers

/// The main area: a split tree of tiles laid out by hand (no Auto Layout), the warm pool's views
/// positioned inside them, per-tile chrome, dividers, click/hover activation and drops.
@MainActor
final class Workspace {
    unowned let app: AppController
    let area = MainAreaView()
    let pool: TerminalPool
    private(set) var layout = TileLayout()
    private var chrome: [TileID: TileChromeView] = [:]
    private var dividers: [DividerView] = []
    private var lastLayout = SplitNode.Layout()
    static let headerHeight: CGFloat = 26
    static let gap: CGFloat = 1
    static let inset: CGFloat = 5
    private var windowKey = true
    private var dropTile: TileID?
    /// Sessions whose deferred agent launch waits for their terminal to attach.
    private var pendingLaunch: [String: Bool?] = [:]
    /// Hooks for the self-test: (session, warm, seconds to first frame / first painted frame).
    var onShowMeasured: ((String, Bool, Double, Double?) -> Void)?

    init(app: AppController) {
        self.app = app
        pool = TerminalPool(daemon: app.daemon, capacity: AppSettings.shared.poolSize)
        pool.container = area
        pool.onExit = { [weak self] s in self?.terminalExited(s) }
        area.workspace = self
        area.registerForDraggedTypes(DropReader.types)
    }

    var activeTile: TileID { layout.active }
    var activeSession: String? { layout.activeSession }
    var activeTerminal: TerminalView? { activeSession.flatMap { pool.view(for: $0) }.flatMap { $0.exited ? nil : $0 } }
    var visibleSessions: Set<String> { layout.visibleSessions }
    var tileRects: [TileID: CGRect] { lastLayout.tiles }

    func terminal(in tile: TileID) -> TerminalView? {
        layout.session(in: tile).flatMap { pool.view(for: $0) }
    }

    // MARK: Persistence

    private var layoutURL: URL { Paths.supportDir.appendingPathComponent("layout-\(Paths.key(for: app.daemon.socketPath)).json") }

    func restore() {
        if let data = try? Data(contentsOf: layoutURL), let l = try? JSONDecoder().decode(TileLayout.self, from: data) {
            layout = l
        }
        syncChrome()
    }

    func save() {
        if let data = try? JSONEncoder().encode(layout) { try? data.write(to: layoutURL, options: .atomic) }
    }

    // MARK: Showing sessions

    /// Show `session` in `tile` (default: the active tile) and make that tile active.
    /// A session already visible in another tile activates that tile instead (one tile per session).
    func show(_ session: String, in tile: TileID? = nil, focus: Bool = true) {
        if let other = layout.tile(showing: session), other != (tile ?? layout.active) {
            activate(other, focus: focus)
            return
        }
        let target = tile ?? layout.active
        let old = layout.assign(session, to: target)
        layout.activate(target)
        attachVisible(session, in: target)
        if let old, old != session { pool.hide(old) }
        pool.evict(keeping: visibleSessions)
        syncChrome()
        if focus { focusActiveTerminal() }
        app.workspaceChanged()
        save()
    }

    /// Put a session's view into a tile: swap in a warm view, or attach a new one.
    private func attachVisible(_ session: String, in tile: TileID) {
        guard app.isAlive(session) else { return }
        let rect = terminalRect(for: tile)
        let t0 = CACurrentMediaTime()
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
        v.onContents = { [weak self] view in
            let now = CACurrentMediaTime()
            if first == nil {
                first = now - t0
                signposter.endInterval(label, sp)
                if warm { self?.onShowMeasured?(session, true, first!, nil) }
            }
            if !warm, view.contentsCount - before >= 1, view.hasPaintedContent {
                view.onContents = nil
                view.layer?.opacity = 1
                let painted = now - t0
                signposter.emitEvent("AttachFirstPaint", "\(session, privacy: .public)")
                self?.onShowMeasured?(session, false, first ?? painted, painted)
                self?.app.terminalPainted(session)
                self?.launchIfPending(session)
            } else if warm {
                view.onContents = nil
            }
        }
        if warm { launchIfPending(session) }
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

    func prewarm(_ session: String) {
        guard app.isAlive(session), layout.tile(showing: session) == nil else { return }
        let size = terminalRect(for: layout.active).size
        pool.prewarm(session, size: size)
        pool.evict(keeping: visibleSessions)
    }

    /// Empty a tile without closing it.
    func clear(_ tile: TileID) {
        if let old = layout.assign(nil, to: tile) { pool.hide(old) }
        syncChrome()
        app.workspaceChanged()
        save()
    }

    private func terminalExited(_ session: String) {
        // The tmux client ended on its own: the session was killed or the client detached elsewhere.
        if let v = pool.view(for: session) { pool.drop(session); _ = v }
        if layout.tile(showing: session) != nil, app.isAlive(session) {
            // Still alive (detached by someone else): attach again.
            if let t = layout.tile(showing: session) { attachVisible(session, in: t) }
        }
        syncChrome()
    }

    /// The daemon's session list changed: refresh chrome, and drop views for sessions that are gone.
    func sessionsChanged(removed: Set<String>) {
        for s in removed { pool.drop(s) }
        // A tile whose session came back (restart from an exited row) attaches again.
        for t in layout.tiles {
            if let s = layout.session(in: t), app.isAlive(s), pool.view(for: s) == nil || pool.view(for: s)?.exited == true {
                attachVisible(s, in: t)
            }
        }
        syncChrome()
    }

    // MARK: Tiles

    func activate(_ tile: TileID, focus: Bool = true) {
        guard layout.tiles.contains(tile) else { return }
        let changed = tile != layout.active
        layout.activate(tile)
        app.focus.activate(tile)
        if changed {
            updateChromeState()
            app.workspaceChanged()
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

    func split(_ axis: SplitAxis) {
        let from = layout.activeSession
        guard let id = layout.splitActive(axis) else { NSSound.beep(); return }
        let next = app.sessionForNewTile(excluding: visibleSessions, after: from)
        app.focus.setTiles(count: layout.count, active: id)
        relayout()
        if let next { show(next, in: id) } else { syncChrome(); focusActiveTerminal(); app.workspaceChanged(); save() }
    }

    func closeActive() {
        if layout.count == 1 && layout.activeSession == nil { NSSound.beep(); return }
        if let s = layout.close(layout.active) { pool.hide(s) }
        app.focus.setTiles(count: layout.count, active: layout.active)
        relayout()
        focusActiveTerminal()
        app.workspaceChanged()
        save()
    }

    func moveFocus(_ d: Direction) {
        guard let n = SplitNode.neighbor(of: layout.active, d, in: lastLayout) else { NSSound.beep(); return }
        activate(n)
    }

    func tile(at point: NSPoint) -> TileID? {
        lastLayout.tiles.first { $0.value.contains(point) }?.key
    }

    func terminalRect(for tile: TileID) -> NSRect {
        guard let r = lastLayout.tiles[tile] ?? (layout.count == 1 ? area.bounds : nil) else { return area.bounds }
        // Inset a little so text never touches the ring; the margin shows the terminal's own background.
        let i = Workspace.inset
        return NSRect(x: r.minX + i, y: r.minY + Workspace.headerHeight + 2, width: max(1, r.width - 2 * i),
                      height: max(1, r.height - Workspace.headerHeight - 2 - i))
    }

    // MARK: Layout

    func relayout() {
        lastLayout = layout.root.layout(in: area.bounds, gap: Workspace.gap)
        syncChrome()
    }

    /// Create/remove chrome views to match the tree, then position everything.
    func syncChrome() {
        let ids = Set(layout.tiles)
        for (id, v) in chrome where !ids.contains(id) {
            v.removeFromSuperview()
            chrome[id] = nil
        }
        for id in layout.tiles where chrome[id] == nil {
            let c = TileChromeView(tile: id, workspace: self)
            chrome[id] = c
            area.addSubview(c)
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
        if lastLayout.tiles.count != layout.count { lastLayout = layout.root.layout(in: area.bounds, gap: Workspace.gap) }
        for (id, c) in chrome {
            guard let r = lastLayout.tiles[id] else { continue }
            if c.frame != r { c.frame = r }
            if let s = layout.session(in: id), let v = pool.view(for: s) {
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
        let ring = layout.count >= 2
        for (id, c) in chrome {
            let s = layout.session(in: id)
            let hasTerminal = s.map { app.isAlive($0) } ?? false
            c.update(session: s, active: id == layout.active, showRing: ring, windowKey: windowKey,
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
        layout.setRatio(at: d.path, SplitNode.ratio(for: d, at: point, gap: Workspace.gap))
        lastLayout = layout.root.layout(in: area.bounds, gap: Workspace.gap)
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
        let ok = t.flatMap { layout.session(in: $0) }.map { app.isAlive($0) } ?? false
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
        guard let t = tile(at: p), let s = layout.session(in: t), app.isAlive(s) else { return false }
        activate(t)
        DropReader.read(info.draggingPasteboard) { [weak self] text in
            guard let text, let v = self?.pool.view(for: s) else { return }
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

/// Per-tile chrome above the terminal: header strip, active ring or inactive border and dimming,
/// and the placeholder for an empty or exited tile. Clicks on an inactive tile stop here (consumed).
final class TileChromeView: NSView {
    let tile: TileID
    unowned let workspace: Workspace
    private let header = TileHeaderView()
    private let border = CALayer()
    private let dim = CALayer()
    private let dropHighlight = CALayer()
    private var placeholder: PlaceholderView?
    private(set) var isActive = false
    private var session: String?

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
        dim.backgroundColor = theme.bg.withAlphaComponent(0.36).cgColor
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

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// What an empty tile or an exited session shows.
final class PlaceholderView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        hint.font = .systemFont(ofSize: 12.5)
        for l in [title, hint] {
            l.alignment = .center
            l.refusesFirstResponder = true
            addSubview(l)
        }
        hint.maximumNumberOfLines = 2
        for (b, sel) in [(primary, #selector(primaryClicked)), (secondary, #selector(secondaryClicked))] {
            b.bezelStyle = .push
            b.controlSize = .regular
            b.refusesFirstResponder = true
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
            title.stringValue = "No session in this tile"
            hint.stringValue = "Pick one in the sidebar, or press ⌘K to search. ⌘W closes the tile."
            primary.title = "Go to Session…"
            secondary.title = "New Session…"
            primaryAction = { app.showPalette() }
            secondaryAction = { app.newSession() }
            secondary.isHidden = false
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = min(bounds.width - 40, 420)
        let x = (bounds.width - w) / 2
        title.sizeToFit()
        let hintH: CGFloat = 36
        let total = title.frame.height + 8 + hintH + 14 + 28
        var y = max(10, (bounds.height - total) / 2)
        title.frame = NSRect(x: x, y: y, width: w, height: title.frame.height)
        y += title.frame.height + 8
        hint.frame = NSRect(x: x, y: y, width: w, height: hintH)
        y += hintH + 14
        primary.sizeToFit()
        secondary.sizeToFit()
        let bw = primary.frame.width + (secondary.isHidden ? 0 : 10 + secondary.frame.width)
        var bx = (bounds.width - bw) / 2
        primary.frame = NSRect(x: bx, y: y, width: primary.frame.width, height: 28)
        bx += primary.frame.width + 10
        secondary.frame = NSRect(x: bx, y: y, width: secondary.frame.width, height: 28)
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
