import AppKit
import BosunCore
import SwiftUI

/// Ties the daemon, the sidebar and the main area together, and owns the focus rules,
/// key routing, menus and commands.
@MainActor
final class AppController: NSObject, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    let daemon = DaemonClient()
    private(set) var workspace: Workspace!
    private(set) var sidebar: SidebarController!
    var focus = FocusModel()
    private var seen = SeenTracker()
    private(set) var theme = AppTheme(.fallback)
    private(set) var nav = NavBindings(nil)
    private(set) var window: MainWindow!
    private var root: RootView!
    private var palette: PaletteView?
    private var settingsWindow: NSWindow?
    private var sendNextPending = false
    private var waitingSince: [String: Date] = [:]
    private var monitors: [Any] = []
    private var themeMenu = NSMenu(title: "Theme")
    private var themeBeforePreview: String?
    private var appliedTerminalTheme: String?
    /// Launch measurements (seconds since process start).
    private(set) var sidebarPaintedAt: Double?
    private(set) var firstTerminalAt: Double?
    var onFirstTerminal: (() -> Void)?
    /// Test modes run where the window can't become key (a locked screen); they treat it as key.
    var assumeKeyForTests = false
    var windowIsKey: Bool { window.isKeyWindow || assumeKeyForTests }

    // MARK: Startup

    func start() {
        workspace = Workspace(app: self)
        sidebar = SidebarController(app: self)
        buildWindow()
        buildMenu()
        installMonitors()

        daemon.onChanges.append { [weak self] in self?.stateChanged($0) }
        daemon.onStatus.append { [weak self] in self?.statusChanged($0) }
        AppSettings.shared.onChange.append { [weak self] in self?.settingsChanged() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        focus.followsMouse = AppSettings.shared.focusFollowsMouse

        // 1. First frame from the cached snapshot: no I/O beyond one small file.
        let cached = daemon.loadCache()
        if !cached { applyTheme() }
        workspace.restore()
        focus.setTiles(count: workspace.layout.count, active: workspace.activeTile)
        if noActivate {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        root.layoutSubtreeIfNeeded()
        workspace.relayout()
        sidebar.reload()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sidebarPaintedAt == nil else { return }
                self.sidebarPaintedAt = ProcessClock.sinceLaunch()
                signposter.emitEvent("SidebarPainted")
            }
        }
        window.displayIfNeeded()
        print("window-id \(window.windowNumber) pid \(getpid())")
        fflush(stdout)

        // 2. Connect in parallel; 3. attach the visible tiles straight away (they only need tmux).
        daemon.start()
        statusChanged(daemon.status)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.attachVisibleTiles() }
        }
    }

    private func attachVisibleTiles() {
        workspace.pool.tmuxSocket = daemon.state.server?.tmuxSocket
        guard daemon.state.server != nil else { return }
        for t in workspace.layout.tiles {
            if let s = workspace.layout.session(in: t), isAlive(s) { workspace.show(s, in: t, focus: t == workspace.activeTile) }
        }
        workspace.activate(workspace.activeTile)
        if workspace.layout.visibleSessions.isEmpty, let first = daemon.state.sidebar.cycleOrder(isAlive: isAlive).first {
            workspace.show(first)
        }
    }

    private func buildWindow() {
        let w = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        w.title = "Bosun"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 640, height: 400)
        w.delegate = self
        w.responderPolicy = { [weak self] r in self?.firstResponderPolicy(r) ?? r }
        // Test modes share the app's defaults; they must never save their window frame over yours.
        if !testMode { w.setFrameAutosaveName("BosunMain") }
        if !w.setFrameUsingName("BosunMain") { w.center() }
        root = RootView(sidebar: sidebar.view, main: workspace.area, sidebarWidth: AppSettings.shared.sidebarWidth)
        root.onSidebarResized = { AppSettings.shared.sidebarWidth = $0 }
        w.contentView = root
        root.titlebarHeight = max(28, w.frame.height - w.contentLayoutRect.height)
        window = w
    }

    // MARK: Focus (design 7b)

    /// Who may hold the keyboard: the active terminal, or a text field while an exception is open.
    private func firstResponderPolicy(_ r: NSResponder?) -> NSResponder? {
        let terminal = workspace.activeTerminal
        if let t = r as? TerminalView {
            return t === terminal ? t : (terminal ?? window)
        }
        if r is NSText || r is NSTextField {
            return focus.exception != nil ? r : (terminal ?? window)
        }
        if r == nil || r === window {
            if focus.exception == nil, let terminal { return terminal }
            return r
        }
        // The outline, buttons, scroll views...: never.
        return terminal ?? window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focus.setWindowKey(true)
        workspace.windowKeyChanged(true)
        workspace.focusActiveTerminal()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !assumeKeyForTests else { return }
        focus.setWindowKey(false)
        workspace.windowKeyChanged(false)
    }

    func enableTestKey() {
        assumeKeyForTests = true
        focus.setWindowKey(true)
        workspace.windowKeyChanged(true)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        // The test modes run with the screen locked, where the window counts as occluded.
        let visible = assumeKeyForTests || window.occlusionState.contains(.visible)
        for s in workspace.visibleSessions { workspace.pool.view(for: s)?.setRendererVisible(visible) }
    }

    func windowWillClose(_ notification: Notification) {
        persist()
    }

    func persist() {
        daemon.writeCache()
        workspace.save()
    }

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            nonisolated(unsafe) let event = e
            nonisolated(unsafe) var out: NSEvent? = e
            // nil from route means the key was used; it must not fall through to the terminal.
            MainActor.assumeIsolated {
                guard let self else { return }
                out = self.route(event)
            }
            return out
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window === self.window { self.workspace.pointerMoved(e) }
            }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.clickedSomewhere(e) }
            return e
        } as Any)
    }

    /// A click outside an open rename or palette closes it (rename keeps the new name).
    private func clickedSomewhere(_ e: NSEvent) {
        guard e.window === window, let ex = focus.exception else { return }
        switch ex {
        case .palette:
            if let p = palette, !p.frame.contains(root.convert(e.locationInWindow, from: nil)) { closePalette() }
        case .rename:
            if let ed = window.firstResponder as? NSTextView, let field = ed.delegate as? NSTextField,
               field.bounds.contains(field.convert(e.locationInWindow, from: nil)) { return }
            window.makeFirstResponder(nil)
        case .sheet:
            break
        }
    }

    // MARK: Keys

    /// Navigation keys are taken before Ghostty encodes them; every other key goes to the terminal.
    private func route(_ e: NSEvent) -> NSEvent? {
        if debugKeys {
            print("key \(e.keyCode) mods=\(e.modifierFlags.rawValue & 0xFFFF0000) key=\(windowIsKey) owns=\(focus.terminalOwnsKeyboard) " +
                  "fr=\((window.firstResponder as? TerminalView).map { displayName($0.session) } ?? String(describing: window.firstResponder.map { type(of: $0) })) active=\(workspace.activeSession.map(displayName) ?? "-")")
        }
        guard e.window === window, windowIsKey, focus.terminalOwnsKeyboard, !(window.firstResponder is NSText) else { return e }
        let term = workspace.activeTerminal
        if let term, term.hasMarkedText() { return e }
        if sendNextPending {
            sendNextPending = false
            root.band.flash(nil)
            if let term {
                // Through tmux's own send-next table (Bosun binds C-v to it), so tmux's root bindings
                // (Shift+arrows switch sessions there) never catch the key on its way to the program.
                if let cv = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: e.timestamp,
                                             windowNumber: e.windowNumber, context: nil, characters: "\u{16}",
                                             charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) {
                    term.keyDown(with: cv)
                }
                term.keyDown(with: e)
                return nil
            }
            return e
        }
        let f = e.modifierFlags
        var m: KeyChord.Mods = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        guard let action = nav.action(keyCode: e.keyCode, charactersIgnoringModifiers: e.charactersIgnoringModifiers, mods: m, command: f.contains(.command)) else {
            return e
        }
        perform(action)
        return nil
    }

    func perform(_ a: NavAction) {
        switch a {
        case .nextSession, .previousSession:
            stepSession(forward: a == .nextSession)
        case .nextTab, .previousTab:
            stepTab(forward: a == .nextTab)
        case .sendNextKey:
            guard workspace.activeTerminal != nil else { NSSound.beep(); return }
            sendNextPending = true
            let label = nav.chords[.sendNextKey]?.label ?? ""
            root.band.flash("\(label) next key goes to the terminal", color: theme.accent, seconds: 0)
        }
    }

    /// Previous/next along the sidebar order, shown in the active tile. Sessions already in another tile are skipped.
    private func stepSession(forward: Bool) {
        let order = daemon.state.sidebar.cycleOrder(isAlive: isAlive)
        let current = workspace.activeSession
        let others = workspace.visibleSessions.subtracting(current.map { [$0] } ?? [])
        let candidates = order.filter { !others.contains($0) }
        guard let next = Sidebar.cycle(candidates, from: current.flatMap { candidates.contains($0) ? $0 : nil } ?? nearest(current, in: order, candidates: candidates, forward: forward), forward: forward),
              next != current else { return }
        show(next)
        // Prewarm the one after, so holding the key keeps landing on warm views.
        if let after = Sidebar.cycle(candidates, from: next, forward: forward), after != current { workspace.prewarm(after) }
    }

    /// When the current session isn't in the candidate list, start from its neighbour in sidebar order.
    private func nearest(_ current: String?, in order: [String], candidates: [String], forward: Bool) -> String? {
        guard let current, let i = order.firstIndex(of: current) else { return nil }
        let n = order.count
        for k in 1..<max(n, 1) {
            let j = forward ? (i - k + n) % n : (i + k) % n
            if candidates.contains(order[j]) { return order[j] }
        }
        return nil
    }

    private func stepTab(forward: Bool) {
        guard let cur = workspace.activeSession,
              let next = daemon.state.sidebar.cycleTab(from: cur, forward: forward, isAlive: isAlive), next != cur else { return }
        if workspace.layout.tile(showing: next) != nil {
            workspace.show(next)
        } else {
            show(next)
        }
    }

    // MARK: Showing

    /// Show a session in the active tile (or activate the tile that has it), and remember it as its row's active tab.
    func show(_ session: String) {
        workspace.show(session)
        rememberActiveTab(session)
    }

    /// Make `session` its row's shown tab, as the TUI does when you switch to a tab.
    func rememberActiveTab(_ session: String) {
        var sb = daemon.state.sidebar
        if let c = sb.container(holding: session), c.tabs.count > 1, sb.setActive(session) {
            daemon.saveSidebar(sb)
        }
    }

    func sidebarActivated(session: String) {
        if focus.exception == .rename { window.makeFirstResponder(nil) }
        show(session)
    }

    func workspaceChanged() {
        seen.setViewed(workspace.visibleSessions)
        sidebar.syncSelection()
        sidebar.refreshRows()
        focus.setTiles(count: workspace.layout.count, active: workspace.activeTile)
        updateTitle()
        updateDockBadge()
    }

    func terminalPainted(_ session: String) {
        guard firstTerminalAt == nil else { return }
        firstTerminalAt = ProcessClock.sinceLaunch()
        signposter.emitEvent("FirstLiveTerminal")
        onFirstTerminal?()
    }

    private func updateTitle() {
        if let s = workspace.activeSession {
            var t = displayName(s)
            if let p = daemon.state.sessions[s]?.path { t += "  —  " + (p as NSString).abbreviatingWithTildeInPath }
            root.band.set(title: t, theme: theme)
            window.title = "Bosun — \(displayName(s))"
        } else {
            root.band.set(title: "Bosun", theme: theme)
            window.title = "Bosun"
        }
    }

    private func updateDockBadge() {
        let n = waitingSince.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// A session for a freshly split tile: the most recently viewed one not on screen, else the next in sidebar order.
    func sessionForNewTile(excluding visible: Set<String>, after: String?) -> String? {
        for s in workspace.pool.lru.reversed() where isAlive(s) && !visible.contains(s) { return s }
        let order = daemon.state.sidebar.cycleOrder(isAlive: isAlive).filter { !visible.contains($0) }
        return Sidebar.cycle(order, from: after.flatMap { order.contains($0) ? $0 : nil }, forward: true)
    }

    // MARK: State

    private func stateChanged(_ changes: [BosunState.Change]) {
        var structure = false
        var touched = Set<String>()
        var removed = Set<String>()
        var chrome = false
        let st = daemon.state
        for c in changes {
            switch c {
            case .snapshot:
                applyTheme()
                nav = NavBindings(st.keybindings)
                workspace.pool.tmuxSocket = st.server?.tmuxSocket
                for name in st.sessionOrder { seen.observe(name, state: st.state(of: name), title: st.sessions[name]?.paneTitle) }
                for (name, info) in st.statuses where info.state == .waiting { if waitingSince[name] == nil { waitingSince[name] = Date() } }
                waitingSince = waitingSince.filter { st.state(of: $0.key) == .waiting }
                structure = true
                chrome = true
                if st.live { liveSnapshotArrived() }
            case .sessions(let changed, let gone):
                for name in changed { seen.observe(name, state: st.state(of: name), title: st.sessions[name]?.paneTitle) }
                for name in gone {
                    seen.forget(name)
                    waitingSince[name] = nil
                }
                touched.formUnion(changed)
                removed.formUnion(gone)
                if !gone.isEmpty || changed.contains(where: { sidebar.itemFor(session: $0) == nil }) { structure = true }
                chrome = chrome || !changed.isDisjoint(with: workspace.visibleSessions) || !gone.isEmpty
            case .status(let name):
                let state = st.state(of: name)
                seen.observe(name, state: state, title: st.sessions[name]?.paneTitle)
                if state == .waiting { if waitingSince[name] == nil { waitingSince[name] = Date() } } else { waitingSince[name] = nil }
                touched.insert(name)
                chrome = chrome || workspace.visibleSessions.contains(name)
            case .sidebar:
                for name in st.sessionOrder { formerNames[name] = displayName(name) }
                structure = true
                chrome = true
            case .theme:
                applyTheme()
            case .keybindings:
                nav = NavBindings(st.keybindings)
                for e in nav.errors { log.error("keybindings: \(e, privacy: .public)") }
            case .notice(let m):
                let shown = readableNotice(m)
                root.band.flash(shown)
                // "created X" comes before X's session delta, so name it again once that lands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.root.band.replaceNote(shown, with: self.readableNotice(m))
                    }
                }
            case .client(let tty, let session):
                workspace.clientMoved(tty: tty, to: session)
            case .recents, .config, .themes:
                break
            }
        }
        if structure { sidebar.reload() } else if !touched.isEmpty { sidebar.refreshRows(touched) }
        if !removed.isEmpty || structure { workspace.sessionsChanged(removed: removed) }
        if chrome { workspace.updateChromeState(); updateTitle() }
        updateDockBadge()
    }

    private var hadLiveSnapshot = false

    private func liveSnapshotArrived() {
        let first = !hadLiveSnapshot
        hadLiveSnapshot = true
        // Tiles whose session is gone and isn't an exited row any more: empty them.
        let sb = daemon.state.sidebar
        for t in workspace.layout.tiles {
            if let s = workspace.layout.session(in: t), !isAlive(s), sb.container(holding: s) == nil { workspace.clear(t) }
        }
        if first { attachVisibleTiles() }
    }

    private func statusChanged(_ s: DaemonClient.Status) {
        switch s {
        case .connected:
            sidebar.setStatus(nil, reconnect: false)
        case .connecting:
            sidebar.setStatus("Connecting…", reconnect: false)
        case .disconnected(let why):
            sidebar.setStatus("Reconnecting… (\(why))", reconnect: true)
        case .failed(let why):
            sidebar.setStatus(why, reconnect: true)
            let alert = NSAlert()
            alert.messageText = "Can't use bosun serve"
            alert.informativeText = why
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: Lookups used by views

    func isAlive(_ s: String) -> Bool { daemon.state.isAlive(s) }

    var noticeText: String { root.band.noteText }

    /// Display names of sessions seen this run, so a notice about one that is already gone still reads well.
    private var formerNames: [String: String] = [:]

    /// Daemon notices name sessions by their tmux name; show the sidebar name instead.
    func readableNotice(_ m: String) -> String {
        var out = m
        for name in daemon.state.sessionOrder { formerNames[name] = displayName(name) }
        for (name, display) in formerNames where display != name && out.contains(name) {
            out = out.replacingOccurrences(of: name, with: display)
        }
        return out
    }

    func displayName(_ s: String) -> String {
        if let d = daemon.state.sessions[s]?.display { return d }
        if let t = daemon.state.sidebar.container(holding: s)?.tabs.first(where: { $0.session == s }), !t.display.isEmpty { return t.display }
        return s
    }

    /// A sidebar row's label: the daemon's (the active tab's name, as the TUI shows it), or the
    /// active tab's display name when the row came from a daemon that sent a tmux name there.
    func rowLabel(_ c: Container) -> String {
        c.name.isEmpty || c.tabs.contains(where: { $0.session == c.name }) ? displayName(c.active) : c.name
    }

    func displayState(_ s: String) -> AgentState {
        guard isAlive(s) else { return .idle }
        return seen.display(s, state: daemon.state.state(of: s))
    }

    func statusDetail(_ s: String) -> String? { daemon.state.statuses[s]?.detail }

    /// "tab 2 of 3" for a session in a multi-tab row.
    func groupLabel(_ s: String) -> String? {
        guard let c = daemon.state.sidebar.container(holding: s), c.tabs.count > 1,
              let i = c.tabs.firstIndex(where: { $0.session == s }) else { return nil }
        return "tab \(i + 1) of \(c.tabs.count)"
    }

    // MARK: Theme

    private func applyTheme() {
        theme = AppTheme(daemon.state.theme)
        window.appearance = theme.appearance
        window.backgroundColor = theme.bg
        sidebar.applyTheme()
        workspace.updateChromeState()
        palette?.theme = theme
        palette?.applyTheme()
        updateTitle()
        applyTerminalTheme()
    }

    private func applyTerminalTheme() {
        let want = AppSettings.shared.matchTerminalTheme ? daemon.state.theme.name : nil
        guard want != appliedTerminalTheme else { return }
        appliedTerminalTheme = want
        GhosttyRuntime.shared.setTerminalTheme(want == nil ? nil : daemon.state.theme)
        workspace.updateChromeState()
    }

    private func settingsChanged() {
        focus.followsMouse = AppSettings.shared.focusFollowsMouse
        workspace.pool.capacity = AppSettings.shared.poolSize
        workspace.pool.evict(keeping: workspace.visibleSessions)
        applyTerminalTheme()
    }

    // MARK: Commands

    private func report(_ ack: Ack) {
        if !ack.ok { root.band.flash(ack.error ?? "failed", color: theme.error, seconds: 6) }
    }

    func restart(_ s: String, resume: Bool) {
        daemon.command(.restart(session: s, resume: resume, deferLaunch: false)) { [weak self] in self?.report($0) }
    }

    /// Restart an exited row from the recents entry with its display name.
    func restartExited(_ s: String, resume: Bool) {
        if isAlive(s) { restart(s, resume: resume); return }
        let name = displayName(s)
        guard let r = daemon.state.recents.first(where: { $0.name == name }) else {
            root.band.flash("No saved spec for “\(name)”", color: theme.error)
            return
        }
        var spec = r.spec
        spec.resume = resume
        let tile = workspace.layout.tile(showing: s)
        daemon.command(.create(spec: spec, deferLaunch: true)) { [weak self] ack in
            guard let self else { return }
            self.report(ack)
            guard ack.ok, let new = ack.session else { return }
            if let tile { self.workspace.show(new, in: tile) } else { self.show(new) }
            if let p = ack.pendingLaunch { self.workspace.expectLaunch(p.session, resume: p.resume) }
        }
    }

    func confirmKill(_ s: String) {
        let alert = NSAlert()
        alert.messageText = "Kill “\(displayName(s))”?"
        alert.informativeText = "The tmux session and the agent in it stop. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        runSheet(alert) { [weak self] ok in
            guard ok, let self else { return }
            self.daemon.command(.kill(session: s)) { [weak self] in self?.report($0) }
        }
    }

    func confirmKillContainer(_ c: Container) {
        let alert = NSAlert()
        alert.messageText = "Kill all \(c.tabs.count) tabs of “\(rowLabel(c))”?"
        alert.informativeText = "Every tmux session in this row stops."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        runSheet(alert) { [weak self] ok in
            guard ok, let self else { return }
            self.daemon.command(.killContainer(sessions: c.tabs.map(\.session))) { [weak self] in self?.report($0) }
        }
    }

    func confirmKillRemoveWorktree(_ s: String) {
        guard let info = daemon.state.sessions[s], let wt = info.worktreePath, let branch = info.branch else { return }
        let alert = NSAlert()
        alert.messageText = "Kill “\(displayName(s))” and remove its worktree?"
        alert.informativeText = "\((wt as NSString).abbreviatingWithTildeInPath) on branch \(branch). A worktree with uncommitted changes is never removed."
        alert.alertStyle = .warning
        let merge = NSButton(checkboxWithTitle: "Merge \(branch) into the repo's current branch first", target: nil, action: nil)
        alert.accessoryView = merge
        alert.addButton(withTitle: "Kill and Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        runSheet(alert) { [weak self] ok in
            guard ok, let self else { return }
            self.daemon.command(.killRemoveWorktree(session: s, worktreePath: wt, branch: branch, merge: merge.state == .on)) { [weak self] in self?.report($0) }
        }
    }

    private func runSheet(_ alert: NSAlert, _ done: @escaping (Bool) -> Void) {
        focus.begin(.sheet)
        alert.beginSheetModal(for: window) { [weak self] resp in
            MainActor.assumeIsolated {
                if self?.focus.end(.sheet) == true { self?.workspace.focusActiveTerminal() }
                done(resp == .alertFirstButtonReturn)
            }
        }
    }

    func rename(item: SidebarItem, to name: String) {
        switch item.kind {
        case .row(let id):
            // A row is labelled by its active tab, so renaming the row renames that session.
            guard let c = daemon.state.sidebar.container(id: id) else { return }
            daemon.command(.rename(session: c.active, display: name)) { [weak self] in self?.report($0) }
        case .tab(let s):
            daemon.command(.rename(session: s, display: name)) { [weak self] in self?.report($0) }
        case .section(let id):
            daemon.command(.renameSection(section: id, name: name)) { [weak self] in self?.report($0) }
        }
    }

    func startRename(_ s: String) {
        if let sec = daemon.state.sidebar.sections.first(where: { $0.members.contains { $0.tabs.contains { $0.session == s } } }), sec.collapsed {
            setSectionCollapsed(sec.id, false)
        }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.sidebar.beginRename(session: s) } }
    }

    func setSectionCollapsed(_ id: String, _ collapsed: Bool) {
        var sb = daemon.state.sidebar
        if sb.setCollapsed(section: id, collapsed) { daemon.saveSidebar(sb) }
    }

    func removeRow(_ id: String) {
        var sb = daemon.state.sidebar
        if sb.removeRow(id: id) != nil { daemon.saveSidebar(sb) }
    }

    func newSection() {
        askText(title: "New Section", message: "Sessions can be dragged into it.", initial: "", button: "Add") { [weak self] name in
            self?.daemon.command(.insertSection(name: name)) { [weak self] in self?.report($0) }
        }
    }

    func renameSection(_ id: String) {
        guard let s = daemon.state.sidebar.sections.first(where: { $0.id == id }) else { return }
        askText(title: "Rename Section", message: "", initial: s.name, button: "Rename") { [weak self] name in
            self?.daemon.command(.renameSection(section: id, name: name)) { [weak self] in self?.report($0) }
        }
    }

    func removeSection(_ id: String) {
        var sb = daemon.state.sidebar
        guard let i = sb.sections.firstIndex(where: { $0.id == id }) else { return }
        // Rows in it move to ungrouped rather than vanishing.
        sb.ungrouped += sb.sections[i].members
        sb.sections.remove(at: i)
        daemon.saveSidebar(sb)
    }

    private func askText(title: String, message: String, initial: String, button: String, _ done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        runSheet(alert) { ok in
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, !v.isEmpty { done(v) }
        }
    }

    // MARK: Sheets

    func newSession(name: String = "") {
        let st = daemon.state
        let model = NewSessionModel(mode: .create, recents: st.recents, defaultAgent: st.defaultAgent, worktreeLocation: st.worktreeLocation, name: name)
        presentForm(model) { [weak self] spec in self?.create(spec) }
    }

    func newTab(in containerID: String) {
        let st = daemon.state
        guard let c = st.sidebar.container(id: containerID) else { return }
        let path = st.sessions[c.active]?.path ?? st.recents.first?.path
        let model = NewSessionModel(mode: .addTab(containerID: containerID), recents: st.recents, defaultAgent: st.defaultAgent,
                                    worktreeLocation: st.worktreeLocation, path: path)
        presentForm(model) { [weak self] spec in self?.create(spec) }
    }

    func modify(_ s: String) {
        daemon.command(.getSpec(session: s)) { [weak self] ack in
            guard let self else { return }
            guard ack.ok, let spec = ack.spec else { self.report(ack); return }
            let model = NewSessionModel(modify: s, spec: spec, recents: self.daemon.state.recents)
            self.presentForm(model) { [weak self] spec in
                self?.daemon.command(.modify(session: s, spec: spec)) { [weak self] in self?.report($0) }
            }
        }
    }

    private func create(_ spec: Spec) {
        daemon.command(.create(spec: spec, deferLaunch: true)) { [weak self] ack in
            guard let self else { return }
            self.report(ack)
            guard ack.ok, let s = ack.session else { return }
            self.show(s)
            if let p = ack.pendingLaunch { self.workspace.expectLaunch(p.session, resume: p.resume) }
        }
    }

    private func presentForm(_ model: NewSessionModel, onSubmit: @escaping (Spec) -> Void) {
        closePalette()
        let form = NewSessionFormView(model: model)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: NewSessionFormView.width, height: form.fittingHeight),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let close = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            self.window.endSheet(sheet)
        }
        form.onSubmit = { spec in close(); onSubmit(spec) }
        form.onCancel = { close() }
        // The sheet's width is fixed; only its height follows the rows the form shows.
        form.onHeightChange = { [weak sheet, weak form] in
            guard let sheet, let form else { return }
            let h = form.fittingHeight
            if abs(sheet.contentLayoutRect.height - h) > 0.5 {
                sheet.setContentSize(NSSize(width: NewSessionFormView.width, height: h))
            }
        }
        sheet.contentView = form
        sheet.contentMinSize = NSSize(width: NewSessionFormView.width, height: 120)
        sheet.contentMaxSize = NSSize(width: NewSessionFormView.width, height: 4000)
        sheet.setContentSize(NSSize(width: NewSessionFormView.width, height: form.fittingHeight))
        sheet.initialFirstResponder = form.nameField
        sheet.appearance = theme.appearance
        formModel = model
        focus.begin(.sheet)
        window.beginSheet(sheet) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.formModel = nil
                if self?.focus.end(.sheet) == true { self?.workspace.focusActiveTerminal() }
            }
        }
        sheet.makeFirstResponder(form.nameField)
    }

    var sheetOpen: Bool { window.attachedSheet != nil }
    /// The open new-session / modify form's model (the focus test switches agents through it).
    private(set) var formModel: NewSessionModel?

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Bosun Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Palette

    func showPalette() {
        if palette != nil { closePalette(); return }
        guard !sheetOpen else { return }
        let p = PaletteView(theme: theme)
        p.source = { [weak self] q in self?.paletteEntries(q) ?? [] }
        p.onClose = { [weak self] in self?.closePalette() }
        palette = p
        root.addSubview(p)
        p.refresh()
        layoutPalette()
        focus.begin(.palette)
        window.makeFirstResponder(p.field)
    }

    private func layoutPalette() {
        guard let p = palette else { return }
        let w = min(PaletteView.width, root.bounds.width - 40)
        let main = workspace.area.frame
        p.frame = NSRect(x: main.midX - w / 2, y: main.minY + min(120, main.height * 0.14), width: w, height: p.preferredHeight)
    }

    func closePalette() {
        guard let p = palette else { return }
        palette = nil
        p.removeFromSuperview()
        if focus.end(.palette) { workspace.focusActiveTerminal() }
    }

    var paletteOpen: Bool { palette != nil }

    private func paletteEntries(_ q: String) -> [PaletteView.Entry] {
        let st = daemon.state
        var scored: [(Int, Int, PaletteView.Entry)] = []
        var order = 0
        func add(_ s: String, section: String?, container: Container) {
            order += 1
            let name = displayName(s)
            let path = st.sessions[s]?.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
            let hay = [name, section, st.sessions[s]?.agent, path].compactMap { $0 }.joined(separator: " ")
            guard let score = q.isEmpty ? 0 : max(Fuzzy.score(q, name).map { $0 + 20 } ?? Int.min, Fuzzy.score(q, hay) ?? Int.min) as Int?,
                  score > Int.min else { return }
            let sub = [section, st.sessions[s]?.agent, path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let title = name
            scored.append((score, order, PaletteView.Entry(title: title, subtitle: sub, state: displayState(s), exited: !isAlive(s),
                                                           action: { [weak self] in self?.sidebarActivated(session: s) })))
        }
        for c in st.sidebar.ungrouped { for t in c.tabs { add(t.session, section: nil, container: c) } }
        for sec in st.sidebar.sections { for c in sec.members { for t in c.tabs { add(t.session, section: sec.name, container: c) } } }
        var out = scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
        out.append(PaletteView.Entry(title: q.isEmpty ? "New Session…" : "New Session “\(q)”…", subtitle: "⇧⌘N", state: nil, exited: false,
                                     action: { [weak self] in self?.newSession(name: q) }))
        return out
    }

    // MARK: Drops on the sidebar

    func dropOnSidebar(session: String, pasteboard: NSPasteboard) {
        show(session)
        DropReader.read(pasteboard) { [weak self] text in
            guard let text, let v = self?.workspace.pool.view(for: session) else { return }
            // A cold view needs tmux attached before the text can land.
            func insert(_ tries: Int) {
                if v.hasPaintedContent || tries == 0 { v.paste(text); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { insert(tries - 1) } }
            }
            insert(40)
        }
    }

    // MARK: Menus

    func sessionMenu(for s: String, rowItem: SidebarItem? = nil) -> NSMenu {
        let m = NSMenu()
        let alive = isAlive(s)
        let container = daemon.state.sidebar.container(holding: s)
        func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: title, action: action)
            m.addItem(i)
            return i
        }
        if alive {
            _ = item("Restart") { [weak self] in self?.restart(s, resume: false) }
            _ = item("Resume") { [weak self] in self?.restart(s, resume: true) }
            _ = item("Modify…") { [weak self] in self?.modify(s) }
        } else {
            _ = item("Restart") { [weak self] in self?.restartExited(s, resume: false) }
            _ = item("Resume") { [weak self] in self?.restartExited(s, resume: true) }
        }
        _ = item("Rename") { [weak self] in self?.startRename(s) }
        if let c = container {
            _ = item("New Tab in This Row…") { [weak self] in self?.newTab(in: c.id) }
        }
        m.addItem(.separator())
        if alive {
            _ = item("Kill…") { [weak self] in self?.confirmKill(s) }
            if let c = container, c.tabs.count > 1, case .row = rowItem?.kind {
                _ = item("Kill All Tabs…") { [weak self] in self?.confirmKillContainer(c) }
            }
            if daemon.state.sessions[s]?.worktreePath != nil, daemon.state.sessions[s]?.branch != nil {
                _ = item("Kill and Remove Worktree…") { [weak self] in self?.confirmKillRemoveWorktree(s) }
            }
        } else if let c = container {
            _ = item("Remove from Sidebar") { [weak self] in self?.removeRow(c.id) }
        }
        return m
    }

    func sectionMenu(for id: String) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Rename Section…") { [weak self] in self?.renameSection(id) })
        m.addItem(ClosureMenuItem(title: "New Section…") { [weak self] in self?.newSection() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Remove Section (keep its sessions)") { [weak self] in self?.removeSection(id) })
        return m
    }

    func sidebarBackgroundMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "New Session…") { [weak self] in self?.newSession() })
        m.addItem(ClosureMenuItem(title: "New Section…") { [weak self] in self?.newSection() })
        return m
    }

    private func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, tag: Int = 0) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target ?? (sel.map { NSApp.responds(to: $0) ? nil : self } ?? nil)
            i.tag = tag
            menu.addItem(i)
        }

        let app = sub("Bosun")
        add(app, "About Bosun", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Settings…", #selector(showSettings), ",", target: self)
        app.addItem(.separator())
        add(app, "Hide Bosun", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Quit Bosun", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = sub("File")
        add(file, "New Session…", #selector(menuNewSession), "N", [.command, .shift], target: self)
        add(file, "New Section…", #selector(menuNewSection), target: self)
        file.addItem(.separator())
        add(file, "Close Tile", #selector(menuCloseTile), "w", target: self)

        let edit = sub("Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let view = sub("View")
        add(view, "Split Right", #selector(menuSplitRight), "d", target: self)
        add(view, "Split Down", #selector(menuSplitDown), "D", [.command, .shift], target: self)
        view.addItem(.separator())
        let arrows: [(String, Unicode.Scalar, Int)] = [("Focus Tile Left", "\u{F702}", 0), ("Focus Tile Right", "\u{F703}", 1),
                                                         ("Focus Tile Up", "\u{F700}", 2), ("Focus Tile Down", "\u{F701}", 3)]
        for (t, k, tag) in arrows { add(view, t, #selector(menuFocusTile(_:)), String(Character(k)), [.command, .option], target: self, tag: tag) }
        view.addItem(.separator())
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeMenu.delegate = self
        themeItem.submenu = themeMenu
        view.addItem(themeItem)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil)

        let go = sub("Go")
        add(go, "Go to Session…", #selector(menuPalette), "k", target: self)
        add(go, "Oldest Waiting Session", #selector(menuOldestWaiting), "U", [.command, .shift], target: self)
        go.addItem(.separator())
        add(go, "Next Session", #selector(menuNav(_:)), target: self, tag: 0)
        add(go, "Previous Session", #selector(menuNav(_:)), target: self, tag: 1)
        add(go, "Next Tab", #selector(menuNav(_:)), target: self, tag: 2)
        add(go, "Previous Tab", #selector(menuNav(_:)), target: self, tag: 3)
        go.addItem(.separator())
        for i in 1...9 { add(go, "Row \(i)", #selector(menuJump(_:)), "\(i)", target: self, tag: i) }

        let session = sub("Session")
        add(session, "Restart", #selector(menuSession(_:)), target: self, tag: 0)
        add(session, "Resume", #selector(menuSession(_:)), target: self, tag: 1)
        add(session, "Modify…", #selector(menuSession(_:)), target: self, tag: 2)
        add(session, "Rename", #selector(menuSession(_:)), target: self, tag: 3)
        add(session, "New Tab in This Row…", #selector(menuSession(_:)), target: self, tag: 5)
        session.addItem(.separator())
        add(session, "Kill…", #selector(menuSession(_:)), target: self, tag: 4)

        let win = sub("Window")
        add(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
        add(win, "Zoom", #selector(NSWindow.performZoom(_:)), target: nil)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    @objc func menuNewSession() { newSession() }
    @objc func menuNewSection() { newSection() }
    @objc func menuCloseTile() { workspace.closeActive() }
    @objc func menuSplitRight() { workspace.split(.horizontal) }
    @objc func menuSplitDown() { workspace.split(.vertical) }
    @objc func menuPalette() { showPalette() }

    @objc func menuFocusTile(_ sender: NSMenuItem) {
        workspace.moveFocus([Direction.left, .right, .up, .down][sender.tag])
    }

    @objc func menuNav(_ sender: NSMenuItem) {
        perform([NavAction.nextSession, .previousSession, .nextTab, .previousTab][sender.tag])
    }

    @objc func menuJump(_ sender: NSMenuItem) {
        let rows = daemon.state.sidebar.visibleRows
        guard sender.tag - 1 < rows.count else { NSSound.beep(); return }
        sidebarActivated(session: rows[sender.tag - 1].active)
    }

    /// The session that has been waiting for you the longest.
    var oldestWaiting: String? {
        waitingSince.filter { isAlive($0.key) }.min { $0.value < $1.value }?.key
    }

    @objc func menuOldestWaiting() {
        guard let s = oldestWaiting else {
            root.band.flash("Nothing is waiting")
            return
        }
        sidebarActivated(session: s)
    }

    @objc func menuSession(_ sender: NSMenuItem) {
        guard let s = workspace.activeSession else { return }
        switch sender.tag {
        case 0: isAlive(s) ? restart(s, resume: false) : restartExited(s, resume: false)
        case 1: isAlive(s) ? restart(s, resume: true) : restartExited(s, resume: true)
        case 2: modify(s)
        case 3: startRename(s)
        case 4: confirmKill(s)
        case 5: if let c = daemon.state.sidebar.container(holding: s) { newTab(in: c.id) }
        default: break
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if sheetOpen { return false }
        switch item.action {
        case #selector(menuSession(_:)):
            guard let s = workspace.activeSession else { return false }
            if item.tag == 2 || item.tag == 4 { return isAlive(s) }
            return true
        case #selector(menuCloseTile):
            return workspace.layout.count > 1 || workspace.activeSession != nil
        case #selector(menuFocusTile(_:)):
            return workspace.layout.count > 1
        case #selector(menuSplitRight), #selector(menuSplitDown):
            return workspace.layout.count < TileLayout.maxTiles
        default:
            return true
        }
    }

    // MARK: Theme menu (with live preview while hovering)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === themeMenu else { return }
        menu.removeAllItems()
        let current = daemon.state.theme.name
        var lastSource: String?
        for t in daemon.state.themes {
            if let l = lastSource, l != t.source { menu.addItem(.separator()) }
            lastSource = t.source
            let i = ClosureMenuItem(title: t.name) { [weak self] in
                self?.themeBeforePreview = nil
                self?.daemon.command(.setTheme(name: t.name, persist: true)) { [weak self] in self?.report($0) }
            }
            i.state = t.name == current ? .on : .off
            i.representedObject = t.name
            menu.addItem(i)
        }
        if daemon.state.themes.isEmpty {
            menu.addItem(NSMenuItem(title: "Not connected", action: nil, keyEquivalent: ""))
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === themeMenu { themeBeforePreview = daemon.state.theme.name }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === themeMenu, let name = item?.representedObject as? String, themeBeforePreview != nil else { return }
        daemon.command(.setTheme(name: name, persist: false))
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === themeMenu, let original = themeBeforePreview else { return }
        // Closed without choosing: put the original back. (Choosing clears themeBeforePreview first.)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.themeBeforePreview == original else { return }
                self.themeBeforePreview = nil
                self.daemon.command(.setTheme(name: original, persist: false))
            }
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
