import AppKit
import BosunCore

/// One node in the sidebar outline. Reused across reloads (keyed by `key`) so expansion state holds.
@MainActor
final class SidebarItem: NSObject {
    enum Kind: Equatable {
        case section(String)
        case row(String)
        case tab(String)
    }

    let kind: Kind
    var children: [SidebarItem] = []
    weak var parent: SidebarItem?

    init(kind: Kind) { self.kind = kind }

    var key: String {
        switch kind {
        case .section(let id): "s:\(id)"
        case .row(let id): "r:\(id)"
        case .tab(let s): "t:\(s)"
        }
    }
}

private let rowDragType = NSPasteboard.PasteboardType("dev.yetidevworks.bosun.sidebar-item")

@MainActor
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    unowned let app: AppController
    let view = SidebarContainerView()
    let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private var roots: [SidebarItem] = []
    private var cache: [String: SidebarItem] = [:]
    private var updatingSelection = false
    private var reloading = false
    private var hoverTimer: Timer?
    private var hoverRow: String?
    private var renameTimer: Timer?
    private var renaming: (item: SidebarItem, field: NSTextField, original: String)?
    /// Rows whose badge changed state recently (selftest hook): session → state.
    var onBadgeApplied: ((String, AgentState) -> Void)?

    init(app: AppController) {
        self.app = app
        super.init()
        outline.controller = self
        outline.headerView = nil
        outline.refusesFirstResponder = true
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.indentationPerLevel = 0
        outline.indentationMarkerFollowsCell = false
        outline.autoresizesOutlineColumn = false
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.backgroundColor = .clear
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .custom
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([rowDragType] + DropReader.types)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .gap

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        view.scroll = scroll
        view.addSubview(scroll)
        view.footer.onNew = { [weak self] in self?.app.newSession() }
        view.footer.onNewSection = { [weak self] in self?.app.newSection() }
        view.footer.onReconnect = { [weak self] in self?.app.daemon.reconnectNow() }
    }

    // MARK: Model

    func reload() {
        let sb = app.daemon.state.sidebar
        var used = Set<String>()
        func item(_ kind: SidebarItem.Kind) -> SidebarItem {
            let probe = SidebarItem(kind: kind)
            let it = cache[probe.key] ?? probe
            cache[it.key] = it
            used.insert(it.key)
            return it
        }
        func rowItem(_ c: Container, parent: SidebarItem?) -> SidebarItem {
            let r = item(.row(c.id))
            r.parent = parent
            r.children = c.tabs.count > 1 ? c.tabs.map { t in
                let ti = item(.tab(t.session))
                ti.parent = r
                ti.children = []
                return ti
            } : []
            return r
        }
        var newRoots: [SidebarItem] = sb.ungrouped.map { rowItem($0, parent: nil) }
        for s in sb.sections {
            let si = item(.section(s.id))
            si.parent = nil
            si.children = s.members.map { rowItem($0, parent: si) }
            newRoots.append(si)
        }
        cache = cache.filter { used.contains($0.key) }
        roots = newRoots
        reloading = true
        outline.reloadData()
        for r in roots { expandAsModel(r, sidebar: sb) }
        reloading = false
        syncSelection()
        view.footer.isHidden = false
    }

    private func expandAsModel(_ item: SidebarItem, sidebar sb: Sidebar) {
        switch item.kind {
        case .section(let id):
            let collapsed = sb.sections.first { $0.id == id }?.collapsed ?? false
            if collapsed { outline.collapseItem(item) } else { outline.expandItem(item) }
            if !collapsed { for c in item.children { expandAsModel(c, sidebar: sb) } }
        case .row:
            if !item.children.isEmpty { outline.expandItem(item) }
        case .tab:
            break
        }
    }

    /// Redraw status and names without reloading structure (status deltas land here).
    func refreshRows(_ sessions: Set<String>? = nil) {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let item = outline.item(atRow: row) as? SidebarItem else { return }
            if let sessions, !sessions.isEmpty {
                let mine = self.sessions(of: item)
                if mine.isDisjoint(with: sessions) && !self.isSection(item) { return }
            }
            (rowView as? SidebarRowView)?.theme = app.theme
            rowView.needsDisplay = true
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) {
                configure(cell, item)
            }
        }
    }

    private func isSection(_ item: SidebarItem) -> Bool { if case .section = item.kind { return true }; return false }

    private func sessions(of item: SidebarItem) -> Set<String> {
        switch item.kind {
        case .tab(let s): return [s]
        case .row(let id): return Set(app.daemon.state.sidebar.container(id: id)?.tabs.map(\.session) ?? [])
        case .section: return []
        }
    }

    /// The session a click on this item makes the active pane: a tab's own, or the row's remembered pane.
    func session(for item: SidebarItem) -> String? {
        switch item.kind {
        case .tab(let s): return s
        case .row(let id): return app.workspace.rememberedPane(row: id)
        case .section: return nil
        }
    }

    /// The row (container id) an item belongs to.
    func rowID(for item: SidebarItem) -> String? {
        switch item.kind {
        case .row(let id): return id
        case .tab(let s): return app.daemon.state.sidebar.container(holding: s)?.id
        case .section: return nil
        }
    }

    /// Whether a click on this item's name renames it (Finder style: it's already what's selected):
    /// the shown row, or the active pane's tab under it.
    func isSelectedForRename(_ item: SidebarItem) -> Bool {
        switch item.kind {
        case .row(let id): return id == app.workspace.currentRow
        case .tab(let s): return rowID(for: item) == app.workspace.currentRow && s == app.workspace.layout.active
        case .section: return false
        }
    }

    /// Select the shown row (selection follows the main area, never the other way). Its tab rows show
    /// which pane is active (drawn by `SidebarRowView`).
    func syncSelection() {
        updatingSelection = true
        defer { updatingSelection = false }
        guard let id = app.workspace.currentRow, let item = cache["r:\(id)"] else {
            outline.deselectAll(nil)
            return
        }
        let row = outline.row(forItem: item)
        if row >= 0 {
            if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        outline.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
    }

    func itemFor(session: String) -> SidebarItem? {
        let sb = app.daemon.state.sidebar
        guard let c = sb.container(holding: session) else { return nil }
        if c.tabs.count > 1 { return cache["t:\(session)"] }
        return cache["r:\(c.id)"]
    }

    func applyTheme() {
        view.theme = app.theme
        refreshRows()
        outline.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
    }

    func setStatus(_ text: String?, reconnect: Bool) {
        view.footer.setStatus(text, reconnect: reconnect, theme: app.theme)
    }

    // MARK: Clicks

    /// Set when a click turned into a drag, so it isn't also treated as a click.
    var dragStarted = false

    func rowClicked(_ row: Int) {
        guard let item = outline.item(atRow: row) as? SidebarItem else { return }
        if case .section(let id) = item.kind {
            // A click anywhere on a section header toggles it.
            app.setSectionCollapsed(id, outline.isItemExpanded(item))
            return
        }
        switch item.kind {
        case .row(let id): app.sidebarActivated(row: id)
        case .tab(let s): app.sidebarActivated(session: s)
        case .section: break
        }
    }

    /// Finder-style rename: a click on the name of the row that's already selected, after the double-click interval.
    func clickedSelected(row: Int, onName: Bool) {
        renameTimer?.invalidate()
        guard onName, let item = outline.item(atRow: row) as? SidebarItem, !isSection(item) else { return }
        renameTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginRename(item) }
        }
    }

    func cancelPendingRename() { renameTimer?.invalidate() }

    // MARK: Hover prewarm

    /// Hovering a row (or one of its tabs) for 50 ms warms every pane of that row.
    func hovered(row: Int) {
        let id = row >= 0 ? (outline.item(atRow: row) as? SidebarItem).flatMap { rowID(for: $0) } : nil
        guard id != hoverRow else { return }
        hoverRow = id
        hoverTimer?.invalidate()
        guard let id else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.app.workspace.prewarm(row: id) }
        }
    }

    // MARK: Rename

    func beginRename(_ item: SidebarItem) {
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView,
              let window = outline.window else { return }
        endRename(commit: false)
        let field = cell.nameField
        let original = field.stringValue
        renaming = (item, field, original)
        app.focus.begin(.rename)
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.drawsBackground = true
        field.backgroundColor = app.theme.bg
        field.textColor = app.theme.text
        field.focusRingType = .none
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func beginRename(session: String) {
        if let item = itemFor(session: session) { beginRename(item) }
    }

    var isRenaming: Bool { renaming != nil }

    private func endRename(commit: Bool) {
        guard let r = renaming else { return }
        renaming = nil
        let newName = r.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        r.field.isEditable = false
        r.field.isSelectable = false
        r.field.drawsBackground = false
        r.field.delegate = nil
        if commit, !newName.isEmpty, newName != r.original {
            app.rename(item: r.item, to: newName)
        } else {
            r.field.stringValue = r.original
        }
        if app.focus.end(.rename) { app.workspace.focusActiveTerminal() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endRename(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking anywhere else ends the edit and keeps the new name.
        endRename(commit: true)
    }

    // MARK: Context menu

    func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return app.sidebarBackgroundMenu() }
        switch item.kind {
        case .section(let id): return app.sectionMenu(for: id)
        case .row(let id):
            guard let c = app.daemon.state.sidebar.container(id: id) else { return nil }
            return app.sessionMenu(for: c.active, rowItem: item)
        case .tab(let s): return app.sessionMenu(for: s, rowItem: item)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let it = item as? SidebarItem else { return false }
        if case .section = it.kind { return true }
        return !it.children.isEmpty
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let it = item as? SidebarItem else { return 26 }
        switch it.kind {
        case .section: return 30
        case .row: return 28
        case .tab: return 24
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rv = SidebarRowView()
        rv.theme = app.theme
        rv.item = item as? SidebarItem
        rv.controller = self
        return rv
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let it = item as? SidebarItem else { return nil }
        let cell: NSView
        if case .section = it.kind {
            cell = outlineView.makeView(withIdentifier: SectionCellView.id, owner: nil) ?? SectionCellView()
        } else {
            cell = outlineView.makeView(withIdentifier: SidebarCellView.id, owner: nil) ?? SidebarCellView()
        }
        configure(cell, it)
        return cell
    }

    func configure(_ cell: NSView, _ item: SidebarItem) {
        let theme = app.theme
        let st = app.daemon.state
        switch item.kind {
        case .section(let id):
            guard let c = cell as? SectionCellView, let s = st.sidebar.sections.first(where: { $0.id == id }) else { return }
            let waiting = s.members.flatMap(\.tabs).contains { app.displayState($0.session) == .waiting }
            c.configure(name: s.name, count: s.members.count, collapsed: s.collapsed, waiting: waiting, theme: theme)
        case .row(let id):
            guard let c = cell as? SidebarCellView, let con = st.sidebar.container(id: id) else { return }
            let multi = con.tabs.count > 1
            let session = con.active
            let alive = con.tabs.contains { app.isAlive($0.session) }
            let name = app.rowLabel(con)
            let state: AgentState = multi ? aggregate(con) : app.displayState(session)
            if renaming?.item !== item { c.nameField.stringValue = name }
            c.configure(state: state, exited: !alive, trailing: multi ? "\(con.tabs.count) tabs" : trailing(for: session),
                        trailingColor: state == .waiting && !multi ? theme.waiting : theme.textMuted, indent: 0, theme: theme, tooltip: tooltip(session))
            c.badge.onApplied = { [weak self] s in self?.onBadgeApplied?(session, s) }
        case .tab(let s):
            guard let c = cell as? SidebarCellView else { return }
            let alive = app.isAlive(s)
            if renaming?.item !== item { c.nameField.stringValue = app.displayName(s) }
            let state = app.displayState(s)
            c.configure(state: state, exited: !alive, trailing: trailing(for: s), trailingColor: state == .waiting ? theme.waiting : theme.textMuted,
                        indent: 16, theme: theme, tooltip: tooltip(s))
            c.badge.onApplied = { [weak self] st in self?.onBadgeApplied?(s, st) }
        }
    }

    private func aggregate(_ c: Container) -> AgentState {
        let states = c.tabs.map { app.displayState($0.session) }
        for s in [AgentState.waiting, .error, .running, .done] where states.contains(s) { return s }
        return states.first ?? .unknown
    }

    private func trailing(for session: String) -> String {
        let st = app.daemon.state
        guard let info = st.sessions[session] else { return "exited" }
        let state = app.displayState(session)
        if state == .waiting { return "waiting" }
        if let b = info.branch, !b.isEmpty { return "⎇ \(b)" }
        if let a = info.agent, a != "terminal" { return a }
        return ""
    }

    private func tooltip(_ session: String) -> String? {
        guard let info = app.daemon.state.sessions[session] else { return nil }
        var parts = [info.display]
        if let p = info.path { parts.append((p as NSString).abbreviatingWithTildeInPath) }
        if let d = app.statusDetail(session) { parts.append(d) }
        return parts.joined(separator: "\n")
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let it = item as? SidebarItem else { return false }
        if case .section = it.kind { return false }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Selection mirrors the active tile; a click goes through `rowClicked` instead.
        guard !updatingSelection else { return }
        outline.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !reloading, let it = notification.userInfo?["NSObject"] as? SidebarItem, case .section(let id) = it.kind else { return }
        app.setSectionCollapsed(id, false)
        for c in it.children where !c.children.isEmpty { outline.expandItem(c) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let it = notification.userInfo?["NSObject"] as? SidebarItem, case .section(let id) = it.kind else { return }
        app.setSectionCollapsed(id, true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let it = item as? SidebarItem else { return false }
        if case .section = it.kind { return true }
        return reloading
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let it = item as? SidebarItem, renaming == nil else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(it.key, forType: rowDragType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        dragStarted = true
        cancelPendingRename()
    }

    private func draggedItem(_ info: NSDraggingInfo) -> SidebarItem? {
        guard let key = info.draggingPasteboard.string(forType: rowDragType) else { return nil }
        return cache[key]
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let target = item as? SidebarItem
        guard let dragged = draggedItem(info) else {
            // Files: only onto a session row. Anywhere else is refused, so the cursor says so before the drop.
            guard DropReader.canRead(info.draggingPasteboard) else { return [] }
            let p = outlineView.convert(info.draggingLocation, from: nil)
            let row = outlineView.row(at: p)
            guard row >= 0, let under = outlineView.item(atRow: row) as? SidebarItem, let s = session(for: under), app.isAlive(s) else { return [] }
            outlineView.setDropItem(under, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        let ungroupedCount = app.daemon.state.sidebar.ungrouped.count
        let pointerY = outlineView.convert(info.draggingLocation, from: nil).y
        /// Whether the pointer is in the lower half of `item`'s own row.
        func below(_ item: SidebarItem) -> Bool {
            let row = outlineView.row(forItem: item)
            return row >= 0 && pointerY > outlineView.rect(ofRow: row).midY
        }
        /// The row under the pointer while it's over the middle of that row (or of one of its tabs), which
        /// means "merge into it"; nearer a row's top or bottom edge means "put it here" as before.
        func mergeTarget() -> SidebarItem? {
            let p = outlineView.convert(info.draggingLocation, from: nil)
            let r = outlineView.row(at: p)
            guard r >= 0, let under = outlineView.item(atRow: r) as? SidebarItem else { return nil }
            let rect = outlineView.rect(ofRow: r)
            guard abs(p.y - rect.midY) < rect.height * 0.3 else { return nil }
            switch under.kind {
            case .row: return under
            case .tab: return under.parent
            case .section: return nil
            }
        }
        switch dragged.kind {
        case .row:
            if let m = mergeTarget(), m !== dragged {
                outlineView.setDropItem(m, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            }
            // Over a multi-tab row or one of its tabs (the outline proposes dropping inside it): drop beside
            // that row in its own list instead, above or below by the pointer.
            var over = target
            if let t = over, case .tab = t.kind { over = t.parent }
            if let t = over, case .row = t.kind {
                let list = t.parent?.children ?? roots
                guard let i = list.firstIndex(where: { $0 === t }) else { return [] }
                outlineView.setDropItem(t.parent, dropChildIndex: i + (below(t) ? 1 : 0))
                return .move
            }
            if over == nil {
                if index == NSOutlineViewDropOnItemIndex { return [] }
                if index <= ungroupedCount { return .move }
                // Between sections: land at the end of the section above.
                let sectionIdx = index - ungroupedCount - 1
                if sectionIdx >= 0, sectionIdx < roots.count - ungroupedCount {
                    let sec = roots[ungroupedCount + sectionIdx]
                    outlineView.setDropItem(sec, dropChildIndex: sec.children.count)
                    return .move
                }
                return []
            }
            if let t = over, case .section = t.kind {
                if index == NSOutlineViewDropOnItemIndex { outlineView.setDropItem(t, dropChildIndex: t.children.count) }
                return .move
            }
            return []
        case .section:
            // Sections only go between top-level items, but the outline proposes drops inside whatever is
            // under the pointer: take the top-level item there and go before or after it.
            var top = target
            while let p = top?.parent { top = p }
            if let top {
                guard let i = roots.firstIndex(where: { $0 === top }) else { return [] }
                outlineView.setDropItem(nil, dropChildIndex: max(ungroupedCount, i + (below(top) ? 1 : 0)))
                return .move
            }
            guard index != NSOutlineViewDropOnItemIndex, index >= 0 else { return [] }
            if index < ungroupedCount { outlineView.setDropItem(nil, dropChildIndex: ungroupedCount) }
            return .move
        case .tab:
            guard let row = dragged.parent else { return [] }
            if let m = mergeTarget(), m !== row {
                outlineView.setDropItem(m, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            }
            if let target, target === row {
                return index == NSOutlineViewDropOnItemIndex ? [] : .move
            }
            // Out of its row: it becomes a row of its own, which goes right after the old one, so show the gap there.
            let list = row.parent?.children ?? roots
            guard let i = list.firstIndex(where: { $0 === row }) else { return [] }
            outlineView.setDropItem(row.parent, dropChildIndex: i + 1)
            return .move
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let target = item as? SidebarItem
        guard let dragged = draggedItem(info) else {
            guard let target, let s = session(for: target) else { return false }
            app.dropOnSidebar(session: s, pasteboard: info.draggingPasteboard)
            return true
        }
        // Merges and moves out of a row go to the daemon, which owns the tmux side of them too.
        if index == NSOutlineViewDropOnItemIndex, let target, case .row(let into) = target.kind {
            switch dragged.kind {
            case .row(let from): DispatchQueue.main.async { [app] in MainActor.assumeIsolated { app.mergeRow(from, into: into) } }
            case .tab(let s): DispatchQueue.main.async { [app] in MainActor.assumeIsolated { app.moveTab(s, into: into) } }
            case .section: return false
            }
            return true
        }
        if case .tab(let s) = dragged.kind, target !== dragged.parent {
            DispatchQueue.main.async { [app] in MainActor.assumeIsolated { app.moveTabToOwnRow(s) } }
            return true
        }
        var sb = app.daemon.state.sidebar
        let ungroupedCount = sb.ungrouped.count
        var changed = false
        switch dragged.kind {
        case .row(let id):
            if let target, case .section(let sid) = target.kind {
                changed = sb.moveRow(id: id, toSection: sid, index: index)
            } else if target == nil {
                changed = sb.moveRow(id: id, toSection: nil, index: min(index, ungroupedCount))
            }
        case .section(let id):
            changed = sb.moveSection(id: id, toIndex: max(0, index - ungroupedCount))
        case .tab(let s):
            changed = sb.moveTab(session: s, toIndex: index)
        }
        // Saved on the next turn: saving reloads the outline, which mustn't happen inside its own drop handling.
        if changed { DispatchQueue.main.async { [app] in MainActor.assumeIsolated { app.daemon.saveSidebar(sb) } } }
        return changed
    }
}

// MARK: - Views

final class SidebarOutlineView: NSOutlineView {
    weak var controller: SidebarController?
    private var tracking: NSTrackingArea?
    /// Focus test hook: a drag that AppKit's own tracking starts is handed here instead of to the
    /// window server, so the test plays the drop side in-process and the drag never follows the real mouse.
    var dragCapture: ((NSDraggingSession, [NSDraggingItem], NSEvent) -> Void)?

    override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource) -> NSDraggingSession {
        guard let capture = dragCapture else { return super.beginDraggingSession(with: items, event: event, source: source) }
        let session = NSDraggingSession()
        source.draggingSession?(session, willBeginAt: window?.convertPoint(toScreen: event.locationInWindow) ?? .zero)
        capture(session, items, event)
        return session
    }

    override var acceptsFirstResponder: Bool { false }
    /// A click on a row in a background window acts straight away (the keyboard stays in the terminal anyway).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        let wasSelected = row >= 0 && (item(atRow: row) as? SidebarItem).map { controller?.isSelectedForRename($0) ?? false } ?? false
        var onName = false
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView {
            let q = cell.convert(event.locationInWindow, from: nil)
            onName = cell.nameField.frame.insetBy(dx: -2, dy: -3).contains(q)
                && q.x <= cell.nameField.frame.minX + cell.nameField.intrinsicContentSize.width + 4
        }
        if event.clickCount > 1 { controller?.cancelPendingRename() }
        controller?.dragStarted = false
        let onDisclosure = row >= 0 && frameOfOutlineCell(atRow: row).contains(p)
        // super runs AppKit's tracking loop (selection, drag start, disclosure) and returns on mouse up.
        super.mouseDown(with: event)
        guard row >= 0, controller?.dragStarted == false, !onDisclosure else { return }
        controller?.rowClicked(row)
        if event.clickCount == 1, wasSelected {
            controller?.clickedSelected(row: row, onName: onName)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return controller?.menu(forRow: row)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.hovered(row: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { controller?.hovered(row: -1) }

    /// No disclosure triangles on rows (their tabs are always shown); sections keep theirs.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        guard let item = item(atRow: row) as? SidebarItem, case .section = item.kind else { return .zero }
        let f = super.frameOfOutlineCell(atRow: row)
        return NSRect(x: bounds.width - f.width - 10, y: f.minY, width: f.width, height: f.height)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let f = super.frameOfCell(atColumn: column, row: row)
        return NSRect(x: 8, y: f.minY, width: bounds.width - 16, height: f.height)
    }

    override func drawBackground(inClipRect clipRect: NSRect) {}
}

final class SidebarRowView: NSTableRowView {
    var theme: AppTheme?
    weak var item: SidebarItem?
    weak var controller: SidebarController?

    override func drawSelection(in dirtyRect: NSRect) {
        guard let theme else { return }
        theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let theme, let item, let controller, !isSelected else { return }
        // The shown row's tabs each have a pane on screen; the active pane's tab is marked (a fill and
        // an accent bar), so the row says which pane has the keyboard.
        guard case .tab(let s) = item.kind, let ws = controller.app.workspace else { return }
        guard controller.rowID(for: item) == ws.currentRow, s == ws.layout.active, ws.layout.count > 1 else { return }
        let r = bounds.insetBy(dx: 6.5, dy: 0.5)
        theme.panelAlt.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        theme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 3, y: r.minY + 5, width: 3, height: r.height - 10), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override var isEmphasized: Bool { get { false } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

final class SidebarCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("row")
    let badge = StatusBadge(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    let nameField = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private var indent: CGFloat = 0

    init() {
        super.init(frame: .zero)
        identifier = SidebarCellView.id
        textField = nameField
        nameField.font = .systemFont(ofSize: 13, weight: .regular)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.isSelectable = false
        nameField.isEditable = false
        nameField.drawsBackground = false
        nameField.isBezeled = false
        nameField.cell?.isScrollable = true
        trailing.font = .systemFont(ofSize: 11, weight: .regular)
        trailing.alignment = .right
        trailing.lineBreakMode = .byTruncatingHead
        addSubview(badge)
        addSubview(nameField)
        addSubview(trailing)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        badge.frame = NSRect(x: 8 + indent, y: (h - 10) / 2, width: 10, height: 10)
        trailing.sizeToFit()
        let tw = min(trailing.frame.width, bounds.width * 0.4)
        trailing.frame = NSRect(x: bounds.width - tw - 8, y: (h - trailing.frame.height) / 2, width: tw, height: trailing.frame.height)
        let nx = 26 + indent
        let nameH = nameField.intrinsicContentSize.height
        nameField.frame = NSRect(x: nx, y: (h - nameH) / 2, width: max(10, trailing.frame.minX - nx - 6), height: nameH)
    }

    func configure(state: AgentState, exited: Bool, trailing t: String, trailingColor: NSColor, indent: CGFloat, theme: AppTheme, tooltip: String?) {
        self.indent = indent
        badge.set(state, exited: exited, theme: theme)
        if !nameField.isEditable {
            nameField.textColor = exited ? theme.textMuted : theme.text
            nameField.font = .systemFont(ofSize: indent > 0 ? 12.5 : 13, weight: state == .waiting || state == .done ? .medium : .regular)
        }
        trailing.stringValue = t
        trailing.textColor = trailingColor
        toolTip = tooltip
        needsLayout = true
    }
}

final class SectionCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("section")
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let dot = CALayer()

    init() {
        super.init(frame: .zero)
        identifier = SectionCellView.id
        wantsLayer = true
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        addSubview(label)
        addSubview(count)
        layer?.addSublayer(dot)
        dot.cornerRadius = 3
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.sizeToFit()
        count.sizeToFit()
        let y = bounds.height - label.frame.height - 5
        label.frame = NSRect(x: 8, y: y, width: max(0, min(label.frame.width, bounds.width - 70)), height: label.frame.height)
        count.frame = NSRect(x: label.frame.maxX + 6, y: y, width: count.frame.width, height: count.frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = NSRect(x: count.frame.maxX + 6, y: y + (label.frame.height - 6) / 2, width: 6, height: 6)
        CATransaction.commit()
    }

    func configure(name: String, count n: Int, collapsed: Bool, waiting: Bool, theme: AppTheme) {
        label.stringValue = name.uppercased()
        label.textColor = theme.textMuted
        count.stringValue = collapsed ? "\(n)" : ""
        count.textColor = theme.dimFg
        dot.backgroundColor = theme.waiting.cgColor
        dot.isHidden = !(collapsed && waiting)
        needsLayout = true
    }
}

/// Sidebar column: titlebar spacer, the outline, and a footer with "+" and the connection status.
final class SidebarContainerView: NSView {
    var scroll: NSScrollView?
    let footer = SidebarFooter()
    private let edge = CALayer()
    var theme: AppTheme? {
        didSet {
            guard let theme else { return }
            layer?.backgroundColor = theme.panel.cgColor
            edge.backgroundColor = theme.shadow.cgColor
            footer.theme = theme
        }
    }
    static let titlebarInset: CGFloat = 38
    static let footerHeight: CGFloat = 34

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(footer)
        layer?.addSublayer(edge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let fh = SidebarContainerView.footerHeight
        scroll?.frame = NSRect(x: 0, y: SidebarContainerView.titlebarInset, width: bounds.width,
                               height: max(0, bounds.height - SidebarContainerView.titlebarInset - fh))
        footer.frame = NSRect(x: 0, y: bounds.height - fh, width: bounds.width, height: fh)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        CATransaction.commit()
    }

    /// Drops on the sidebar background are refused (rows handle their own).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
}

final class SidebarFooter: NSView {
    private let add = NSButton()
    private let addSection = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let reconnect = NSButton(title: "Reconnect", target: nil, action: nil)
    private let line = CALayer()
    var onNew: (() -> Void)?
    var onNewSection: (() -> Void)?
    var onReconnect: (() -> Void)?
    var theme: AppTheme? {
        didSet {
            guard let theme else { return }
            line.backgroundColor = theme.shadow.cgColor
            add.contentTintColor = theme.textMuted
            addSection.contentTintColor = theme.textMuted
            status.textColor = theme.textMuted
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(line)
        for (b, symbol, tip, sel) in [(add, "plus", "New Session (⇧⌘N)", #selector(newClicked)),
                                      (addSection, "folder.badge.plus", "New Section", #selector(sectionClicked))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.toolTip = tip
            b.refusesFirstResponder = true
            b.target = self
            b.action = sel
            addSubview(b)
        }
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)
        reconnect.bezelStyle = .push
        reconnect.controlSize = .small
        reconnect.refusesFirstResponder = true
        reconnect.target = self
        reconnect.action = #selector(reconnectClicked)
        reconnect.isHidden = true
        addSubview(reconnect)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
        add.frame = NSRect(x: 10, y: (h - 22) / 2, width: 24, height: 22)
        addSection.frame = NSRect(x: 36, y: (h - 22) / 2, width: 26, height: 22)
        var right = bounds.width - 10
        if !reconnect.isHidden {
            reconnect.sizeToFit()
            reconnect.frame = NSRect(x: right - reconnect.frame.width, y: (h - reconnect.frame.height) / 2, width: reconnect.frame.width, height: reconnect.frame.height)
            right = reconnect.frame.minX - 6
        }
        status.sizeToFit()
        let sw = min(status.frame.width, right - 70)
        status.frame = NSRect(x: right - sw, y: (h - status.frame.height) / 2, width: max(0, sw), height: status.frame.height)
    }

    func setStatus(_ text: String?, reconnect show: Bool, theme: AppTheme) {
        status.stringValue = text ?? ""
        status.toolTip = text
        reconnect.isHidden = !show
        needsLayout = true
    }

    @objc private func newClicked() { onNew?() }
    @objc private func sectionClicked() { onNewSection?() }
    @objc private func reconnectClicked() { onReconnect?() }
}
