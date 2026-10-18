import Foundation

/// Where a row lives in the sidebar: ungrouped (section nil) or in a section, at an index.
public struct RowLocation: Equatable, Sendable {
    public var section: String?
    public var index: Int
    public init(section: String?, index: Int) {
        self.section = section
        self.index = index
    }
}

extension Sidebar {
    /// Every row, ungrouped first, then each section's members (collapsed sections included).
    public var allRows: [Container] { ungrouped + sections.flatMap(\.members) }

    /// Rows a person can see: collapsed sections hide their members.
    public var visibleRows: [Container] { ungrouped + sections.filter { !$0.collapsed }.flatMap(\.members) }

    public func container(id: String) -> Container? { allRows.first { $0.id == id } }

    public func container(holding session: String) -> Container? {
        allRows.first { c in c.tabs.contains { $0.session == session } }
    }

    public func location(ofRow id: String) -> RowLocation? {
        if let i = ungrouped.firstIndex(where: { $0.id == id }) { return RowLocation(section: nil, index: i) }
        for s in sections {
            if let i = s.members.firstIndex(where: { $0.id == id }) { return RowLocation(section: s.id, index: i) }
        }
        return nil
    }

    public func section(holdingRow id: String) -> Section? {
        sections.first { $0.members.contains { $0.id == id } }
    }

    /// Snoozed or Docked, for a parked row.
    public func role(ofRow id: String) -> SectionRole? { section(holdingRow: id)?.role }

    /// A row snoozed until a time (not until it needs you): it stays quiet, no notifications.
    public func isQuietlySnoozed(_ c: Container) -> Bool {
        role(ofRow: c.id) == .snoozed && c.parked?.untilNeeded != true
    }

    /// The order previous/next session walks: each row's active tab, live sessions only, as the TUI does.
    public func cycleOrder(isAlive: (String) -> Bool) -> [String] {
        allRows.map(\.active).filter(isAlive)
    }

    public static func cycle(_ order: [String], from current: String?, forward: Bool) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else {
            return forward ? order.first : order.last
        }
        return order[forward ? (i + 1) % order.count : (i + order.count - 1) % order.count]
    }

    /// The next/previous live tab in `session`'s row, wrapping.
    public func cycleTab(from session: String, forward: Bool, isAlive: (String) -> Bool) -> String? {
        guard let c = container(holding: session) else { return nil }
        let live = c.tabs.map(\.session).filter { isAlive($0) || $0 == session }
        guard live.count > 1 else { return nil }
        return Sidebar.cycle(live, from: session, forward: forward)
    }

    // MARK: Mutations (each returns whether anything changed)

    @discardableResult
    public mutating func setActive(_ session: String) -> Bool {
        func fix(_ c: inout Container) -> Bool {
            guard c.tabs.contains(where: { $0.session == session }), c.active != session else { return false }
            c.active = session
            return true
        }
        for i in ungrouped.indices where fix(&ungrouped[i]) { return true }
        for s in sections.indices {
            for i in sections[s].members.indices where fix(&sections[s].members[i]) { return true }
        }
        return false
    }

    /// Take an ended tab out of its row (a pane closed in the app ends its tab for good, whatever
    /// `remove_dead_sessions` says). A row's only tab stays: the row would go with it.
    @discardableResult
    public mutating func removeTab(session: String) -> Bool {
        func drop(_ c: inout Container) -> Bool {
            guard c.tabs.count > 1, let i = c.tabs.firstIndex(where: { $0.session == session }) else { return false }
            c.tabs.remove(at: i)
            if c.active == session { c.active = c.tabs[min(i, c.tabs.count - 1)].session }
            return true
        }
        for i in ungrouped.indices where ungrouped[i].tabs.contains(where: { $0.session == session }) { return drop(&ungrouped[i]) }
        for s in sections.indices {
            for i in sections[s].members.indices where sections[s].members[i].tabs.contains(where: { $0.session == session }) {
                return drop(&sections[s].members[i])
            }
        }
        return false
    }

    @discardableResult
    public mutating func setCollapsed(section id: String, _ collapsed: Bool) -> Bool {
        guard let i = sections.firstIndex(where: { $0.id == id }), sections[i].collapsed != collapsed else { return false }
        sections[i].collapsed = collapsed
        return true
    }

    @discardableResult
    public mutating func removeRow(id: String) -> Container? {
        if let i = ungrouped.firstIndex(where: { $0.id == id }) { return ungrouped.remove(at: i) }
        for s in sections.indices {
            if let i = sections[s].members.firstIndex(where: { $0.id == id }) { return sections[s].members.remove(at: i) }
        }
        return nil
    }

    /// Move a row to `index` within `section` (nil = ungrouped). `index` is in the destination's
    /// coordinates before the row is removed, the way NSOutlineView reports drop indexes.
    @discardableResult
    public mutating func moveRow(id: String, toSection section: String?, index: Int) -> Bool {
        guard let from = location(ofRow: id) else { return false }
        if let section, !sections.contains(where: { $0.id == section }) { return false }
        var target = max(0, index)
        if from.section == section, from.index < target { target -= 1 }
        if from.section == section, from.index == target { return false }
        guard let row = removeRow(id: id) else { return false }
        if let section, let s = sections.firstIndex(where: { $0.id == section }) {
            sections[s].members.insert(row, at: min(target, sections[s].members.count))
        } else {
            ungrouped.insert(row, at: min(target, ungrouped.count))
        }
        return true
    }

    @discardableResult
    public mutating func moveSection(id: String, toIndex index: Int) -> Bool {
        guard let from = sections.firstIndex(where: { $0.id == id }) else { return false }
        var target = max(0, min(index, sections.count))
        if from < target { target -= 1 }
        if from == target { return false }
        let s = sections.remove(at: from)
        sections.insert(s, at: target)
        return true
    }

    @discardableResult
    public mutating func moveTab(session: String, toIndex index: Int) -> Bool {
        func move(_ c: inout Container) -> Bool {
            guard let from = c.tabs.firstIndex(where: { $0.session == session }) else { return false }
            var target = max(0, min(index, c.tabs.count))
            if from < target { target -= 1 }
            if from == target { return false }
            let t = c.tabs.remove(at: from)
            c.tabs.insert(t, at: target)
            return true
        }
        for i in ungrouped.indices where ungrouped[i].tabs.contains(where: { $0.session == session }) { return move(&ungrouped[i]) }
        for s in sections.indices {
            for i in sections[s].members.indices where sections[s].members[i].tabs.contains(where: { $0.session == session }) {
                return move(&sections[s].members[i])
            }
        }
        return false
    }
}
