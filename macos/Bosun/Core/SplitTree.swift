import CoreGraphics
import Foundation

/// A pane in a row's split tree. A pane always shows one tab of its row, so it is that tab's
/// tmux session name: stable for the tab's life (renames change only the display name).
public typealias TileID = String

public enum SplitAxis: String, Codable, Sendable {
    /// Children side by side (a vertical divider), as Cmd+D makes.
    case horizontal
    /// Children stacked (a horizontal divider), as Cmd+Shift+D makes.
    case vertical
}

public enum Direction: Sendable {
    case left, right, up, down
}

/// Binary split tree of tiles: pure data, laid out with plain arithmetic.
public indirect enum SplitNode: Codable, Equatable, Sendable {
    case leaf(TileID)
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)

    public var leaves: [TileID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, let a, let b): a.leaves + b.leaves
        }
    }

    public func contains(_ id: TileID) -> Bool { leaves.contains(id) }

    /// Split `target` along `axis`; the new tile goes second (right or below).
    public func splitting(_ target: TileID, axis: SplitAxis, newTile: TileID, ratio: Double = 0.5) -> SplitNode {
        switch self {
        case .leaf(let id) where id == target:
            return .split(axis: axis, ratio: ratio, first: .leaf(id), second: .leaf(newTile))
        case .leaf:
            return self
        case .split(let ax, let r, let a, let b):
            return .split(axis: ax, ratio: r, first: a.splitting(target, axis: axis, newTile: newTile, ratio: ratio),
                          second: b.splitting(target, axis: axis, newTile: newTile, ratio: ratio))
        }
    }

    /// Remove a tile; its sibling takes the parent's place. Returns nil when the last tile goes.
    public func removing(_ target: TileID) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let ax, let r, let a, let b):
            let na = a.removing(target)
            let nb = b.removing(target)
            switch (na, nb) {
            case (nil, nil): return nil
            case (nil, let x?): return x
            case (let x?, nil): return x
            case (let x?, let y?): return .split(axis: ax, ratio: r, first: x, second: y)
            }
        }
    }

    /// Set the ratio of the split at `path` (a list of 0/1 child choices from the root).
    public func settingRatio(at path: [Int], to ratio: Double) -> SplitNode {
        guard case .split(let ax, let r, let a, let b) = self else { return self }
        guard let head = path.first else {
            return .split(axis: ax, ratio: SplitNode.clamp(ratio), first: a, second: b)
        }
        let rest = Array(path.dropFirst())
        return head == 0
            ? .split(axis: ax, ratio: r, first: a.settingRatio(at: rest, to: ratio), second: b)
            : .split(axis: ax, ratio: r, first: a, second: b.settingRatio(at: rest, to: ratio))
    }

    public static func clamp(_ r: Double) -> Double { min(0.9, max(0.1, r)) }

    // MARK: Layout

    public struct Divider: Equatable, Sendable {
        public var path: [Int]
        public var axis: SplitAxis
        /// The gap between the two children.
        public var rect: CGRect
        /// The rect the split occupies (to turn a pointer position into a ratio).
        public var container: CGRect
    }

    public struct Layout: Equatable, Sendable {
        public var tiles: [TileID: CGRect] = [:]
        public var dividers: [Divider] = []
        public init() {}
    }

    /// Frames for every tile and divider inside `rect`. `gap` is the divider thickness.
    /// Frames are pixel-aligned (whole points) so tiles never blur or overlap.
    public func layout(in rect: CGRect, gap: CGFloat) -> Layout {
        var out = Layout()
        place(in: rect, gap: gap, path: [], into: &out)
        return out
    }

    private func place(in rect: CGRect, gap: CGFloat, path: [Int], into out: inout Layout) {
        switch self {
        case .leaf(let id):
            out.tiles[id] = rect
        case .split(let ax, let r, let a, let b):
            switch ax {
            case .horizontal:
                let avail = max(0, rect.width - gap)
                let w = (avail * r).rounded()
                let ra = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
                let rb = CGRect(x: rect.minX + w + gap, y: rect.minY, width: max(0, rect.width - w - gap), height: rect.height)
                out.dividers.append(Divider(path: path, axis: ax, rect: CGRect(x: ra.maxX, y: rect.minY, width: gap, height: rect.height), container: rect))
                a.place(in: ra, gap: gap, path: path + [0], into: &out)
                b.place(in: rb, gap: gap, path: path + [1], into: &out)
            case .vertical:
                // Flipped coordinates: first child on top.
                let avail = max(0, rect.height - gap)
                let h = (avail * r).rounded()
                let ra = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
                let rb = CGRect(x: rect.minX, y: rect.minY + h + gap, width: rect.width, height: max(0, rect.height - h - gap))
                out.dividers.append(Divider(path: path, axis: ax, rect: CGRect(x: rect.minX, y: ra.maxY, width: rect.width, height: gap), container: rect))
                a.place(in: ra, gap: gap, path: path + [0], into: &out)
                b.place(in: rb, gap: gap, path: path + [1], into: &out)
            }
        }
    }

    /// Ratio for a divider dragged to `point` (flipped coordinates).
    public static func ratio(for divider: Divider, at point: CGPoint, gap: CGFloat) -> Double {
        let c = divider.container
        switch divider.axis {
        case .horizontal:
            let avail = max(1, c.width - gap)
            return clamp(Double((point.x - c.minX - gap / 2) / avail))
        case .vertical:
            let avail = max(1, c.height - gap)
            return clamp(Double((point.y - c.minY - gap / 2) / avail))
        }
    }

    /// The tile next to `from` in `direction`, by geometry: the closest tile whose span overlaps
    /// on the other axis, preferring the most overlap. Flipped coordinates (y grows down).
    public static func neighbor(of from: TileID, _ direction: Direction, in layout: Layout) -> TileID? {
        guard let src = layout.tiles[from] else { return nil }
        var best: (id: TileID, dist: CGFloat, overlap: CGFloat)?
        for (id, r) in layout.tiles where id != from {
            let dist: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                guard r.maxX <= src.minX + 0.5 else { continue }
                dist = src.minX - r.maxX
                overlap = min(r.maxY, src.maxY) - max(r.minY, src.minY)
            case .right:
                guard r.minX >= src.maxX - 0.5 else { continue }
                dist = r.minX - src.maxX
                overlap = min(r.maxY, src.maxY) - max(r.minY, src.minY)
            case .up:
                guard r.maxY <= src.minY + 0.5 else { continue }
                dist = src.minY - r.maxY
                overlap = min(r.maxX, src.maxX) - max(r.minX, src.minX)
            case .down:
                guard r.minY >= src.maxY - 0.5 else { continue }
                dist = r.minY - src.maxY
                overlap = min(r.maxX, src.maxX) - max(r.minX, src.minX)
            }
            guard overlap > 0 else { continue }
            if let b = best {
                if dist < b.dist - 0.5 || (abs(dist - b.dist) <= 0.5 && overlap > b.overlap) { best = (id, dist, overlap) }
            } else {
                best = (id, dist, overlap)
            }
        }
        return best?.id
    }
}

/// Where a tile dragged by its header lands on another tile: beside it on one side, or in its place.
public enum TileDropZone: Equatable, Sendable {
    case edge(Direction)
    case swap

    /// The zone for a point in `rect` (flipped coordinates, y grows down): the middle half of the
    /// tile each way swaps, anywhere else picks the nearest edge.
    public static func at(_ p: CGPoint, in rect: CGRect) -> TileDropZone {
        guard rect.width > 0, rect.height > 0 else { return .swap }
        let fx = (p.x - rect.minX) / rect.width
        let fy = (p.y - rect.minY) / rect.height
        if fx > 0.25, fx < 0.75, fy > 0.25, fy < 0.75 { return .swap }
        let d: [(Direction, CGFloat)] = [(.left, fx), (.right, 1 - fx), (.up, fy), (.down, 1 - fy)]
        return .edge(d.min { $0.1 < $1.1 }!.0)
    }

    /// The part of the target tile the drop indicator covers: the half the tile will take, or all of it.
    public func indicatorRect(in r: CGRect) -> CGRect {
        switch self {
        case .swap: return r
        case .edge(.left): return CGRect(x: r.minX, y: r.minY, width: (r.width / 2).rounded(), height: r.height)
        case .edge(.right): return CGRect(x: r.minX + (r.width / 2).rounded(), y: r.minY, width: r.width - (r.width / 2).rounded(), height: r.height)
        case .edge(.up): return CGRect(x: r.minX, y: r.minY, width: r.width, height: (r.height / 2).rounded())
        case .edge(.down): return CGRect(x: r.minX, y: r.minY + (r.height / 2).rounded(), width: r.width, height: r.height - (r.height / 2).rounded())
        }
    }
}

extension SplitNode {
    /// Exchange two leaves; everything else, ratios included, stays.
    public func swapping(_ a: TileID, _ b: TileID) -> SplitNode {
        switch self {
        case .leaf(let id): return id == a ? .leaf(b) : id == b ? .leaf(a) : self
        case .split(let ax, let r, let x, let y): return .split(axis: ax, ratio: r, first: x.swapping(a, b), second: y.swapping(a, b))
        }
    }

    /// Split `target` and put `tile` on `side` of it.
    public func inserting(_ tile: TileID, beside target: TileID, on side: Direction, ratio: Double = 0.5) -> SplitNode {
        switch self {
        case .leaf(let id) where id == target:
            switch side {
            case .left: return .split(axis: .horizontal, ratio: ratio, first: .leaf(tile), second: self)
            case .right: return .split(axis: .horizontal, ratio: ratio, first: self, second: .leaf(tile))
            case .up: return .split(axis: .vertical, ratio: ratio, first: .leaf(tile), second: self)
            case .down: return .split(axis: .vertical, ratio: ratio, first: self, second: .leaf(tile))
            }
        case .leaf:
            return self
        case .split(let ax, let r, let a, let b):
            return .split(axis: ax, ratio: r, first: a.inserting(tile, beside: target, on: side, ratio: ratio),
                          second: b.inserting(tile, beside: target, on: side, ratio: ratio))
        }
    }

    /// The same tiles in the same arrangement, whatever the ratios.
    public func sameArrangement(as other: SplitNode) -> Bool {
        switch (self, other) {
        case (.leaf(let a), .leaf(let b)): return a == b
        case (.split(let ax, _, let a1, let b1), .split(let bx, _, let a2, let b2)):
            return ax == bx && a1.sameArrangement(as: a2) && b1.sameArrangement(as: b2)
        default: return false
        }
    }

    /// Move `tile` onto `target`: take it out of the tree and split `target` on that side, or swap the
    /// two. nil when nothing would change (onto itself, or onto an edge that rebuilds the same layout).
    public func moving(_ tile: TileID, to target: TileID, zone: TileDropZone) -> SplitNode? {
        guard tile != target, contains(tile), contains(target) else { return nil }
        let out: SplitNode
        switch zone {
        case .swap:
            out = swapping(tile, target)
        case .edge(let side):
            guard let rest = removing(tile) else { return nil }
            out = rest.inserting(tile, beside: target, on: side)
        }
        return out.sameArrangement(as: self) ? nil : out
    }
}

extension SplitNode {
    /// The pane that takes over when `target` closes: the nearest leaf of its sibling subtree (the
    /// sibling's first leaf when `target` was the first child, its last leaf when it was the second).
    /// nil when `target` is the only pane or isn't in the tree.
    public func nearestSiblingLeaf(of target: TileID) -> TileID? {
        guard case .split(_, _, let a, let b) = self else { return nil }
        if case .leaf(let id) = a, id == target { return b.leaves.first }
        if case .leaf(let id) = b, id == target { return a.leaves.last }
        if a.contains(target) { return a.nearestSiblingLeaf(of: target) }
        if b.contains(target) { return b.nearestSiblingLeaf(of: target) }
        return nil
    }
}

/// Where the next pane of a row goes when the app itself asked for it (Cmd+D, Cmd+Shift+D, New Tab…):
/// split `from` (or the active pane) along `axis`.
public struct PendingSplit: Equatable, Sendable {
    public var from: TileID?
    public var axis: SplitAxis
    public init(from: TileID?, axis: SplitAxis) {
        self.from = from
        self.axis = axis
    }
}

/// One sidebar row's main area (design section 6): its split tree, whose panes are the row's live
/// tabs, and the pane that has the keyboard when the row is shown. Pure data.
public struct RowLayout: Codable, Equatable, Sendable {
    public private(set) var root: SplitNode?
    public private(set) var active: TileID?
    /// The pane shown full size (Cmd+Return), like tmux's `resize-pane -Z`: the tree stays as it is.
    /// Zoom follows the active pane, and ends when the row gains or loses a pane.
    public private(set) var zoomed: TileID?

    /// The supported maximum (design section 6). Only the app's own new-pane commands stop here.
    public static let maxPanes = 9

    public init(root: SplitNode? = nil, active: TileID? = nil) {
        self.root = root
        self.active = active.flatMap { root?.contains($0) == true ? $0 : nil } ?? root?.leaves.first
    }

    public var panes: [TileID] { root?.leaves ?? [] }
    public var count: Int { panes.count }
    public var isEmpty: Bool { root == nil }
    public func contains(_ pane: TileID) -> Bool { root?.contains(pane) ?? false }

    /// The tree on screen: the zoomed pane alone, else the whole tree.
    public var shownRoot: SplitNode? { zoomed.map { .leaf($0) } ?? root }
    /// The panes on screen (all of them, or the zoomed one).
    public var shown: [TileID] { zoomed.map { [$0] } ?? panes }
    public var isZoomed: Bool { zoomed != nil }

    public mutating func activate(_ pane: TileID) {
        guard contains(pane) else { return }
        active = pane
        if zoomed != nil { zoomed = pane }
    }

    /// Zoom the active pane, or end the zoom. Returns false when there's nothing to zoom (one pane).
    @discardableResult
    public mutating func toggleZoom() -> Bool {
        if zoomed != nil {
            zoomed = nil
            return true
        }
        guard count > 1, let active else { return false }
        zoomed = active
        return true
    }

    /// Split `pane` (or the active pane) along `axis` for `newPane`, which goes right or below and becomes active.
    public mutating func split(_ pane: TileID?, axis: SplitAxis, newPane: TileID) {
        guard !contains(newPane) else { activate(newPane); return }
        zoomed = nil
        guard let root else {
            self.root = .leaf(newPane)
            active = newPane
            return
        }
        let target = pane.flatMap { contains($0) ? $0 : nil } ?? active.flatMap { contains($0) ? $0 : nil } ?? root.leaves.last!
        self.root = root.splitting(target, axis: axis, newTile: newPane)
        active = newPane
    }

    /// Remove a pane. Its sibling takes the space, and if the pane was active, the sibling's nearest
    /// pane becomes active. Returns false when the pane isn't in the row.
    @discardableResult
    public mutating func close(_ pane: TileID) -> Bool {
        guard let root, root.contains(pane) else { return false }
        let sibling = root.nearestSiblingLeaf(of: pane)
        zoomed = nil
        self.root = root.removing(pane)
        if active == pane || active.map({ !contains($0) }) ?? true {
            active = sibling ?? self.root?.leaves.first
        }
        return true
    }

    /// Give `newPane` a pane by the automatic rule: split the biggest pane in half along its longer
    /// side (ties go to the first in `order`, the row's tab order). Sizes are taken in a rect of the
    /// given width/height `aspect`, so the direction alternates as the panes get narrower or flatter,
    /// and 2, 3 and 4 tabs open as side by side, a column and a stack, and a 2×2 grid.
    public mutating func place(_ newPane: TileID, order: [String], aspect: Double) {
        guard !contains(newPane) else { return }
        zoomed = nil
        guard let root else {
            self.root = .leaf(newPane)
            return
        }
        let h: CGFloat = 1000
        let l = root.layout(in: CGRect(x: 0, y: 0, width: CGFloat(max(0.2, min(5, aspect))) * h, height: h), gap: 0)
        let leaves = root.leaves
        let ranked = leaves.enumerated().sorted { a, b in
            let ra = order.firstIndex(of: a.element) ?? Int.max, rb = order.firstIndex(of: b.element) ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        var best: (pane: TileID, area: CGFloat)?
        for p in ranked {
            guard let r = l.tiles[p] else { continue }
            let area = r.width * r.height
            if best == nil || area > best!.area * 1.01 { best = (p, area) }
        }
        guard let target = best?.pane, let r = l.tiles[target] else { return }
        self.root = root.inserting(newPane, beside: target, on: r.width >= r.height ? .right : .down)
    }

    public struct Change: Equatable, Sendable {
        public var added: [TileID] = []
        public var removed: [TileID] = []
        /// The first added pane went where `pending` said (and became active).
        public var usedPending = false
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
        public init() {}
    }

    /// Match the panes to the row's live tabs (in tab order): panes of tabs that ended go, and their
    /// space goes to their sibling; live tabs without a pane get one, the first by `pending` when the
    /// app asked for it, the rest by `place`. A row seen for the first time lays all its tabs out this
    /// way. The active pane stays unless it went, falling back to `preferredActive` (the row's active
    /// tab in the sidebar), then to the first pane.
    @discardableResult
    public mutating func reconcile(liveTabs: [String], preferredActive: String?, aspect: Double, pending: PendingSplit? = nil) -> Change {
        var change = Change()
        let live = Set(liveTabs)
        for p in panes where !live.contains(p) {
            close(p)
            change.removed.append(p)
        }
        var pending = pending
        for t in liveTabs where !contains(t) {
            if let ps = pending {
                split(ps.from, axis: ps.axis, newPane: t)
                pending = nil
                change.usedPending = true
            } else {
                place(t, order: liveTabs, aspect: aspect)
            }
            change.added.append(t)
        }
        if active.map({ !contains($0) }) ?? true {
            active = preferredActive.flatMap { contains($0) ? $0 : nil } ?? panes.first
        }
        return change
    }

    /// The pane after (or before) the active one in tab order, wrapping. nil with fewer than two panes.
    public func step(forward: Bool, order: [String]) -> TileID? {
        let seq = order.filter { contains($0) } + panes.filter { !order.contains($0) }
        guard seq.count > 1 else { return nil }
        return Sidebar.cycle(seq, from: active.flatMap { seq.contains($0) ? $0 : nil }, forward: forward)
    }

    /// Move a pane beside another, or swap them (see `SplitNode.moving`). The moved pane becomes
    /// active. Returns false when nothing changed.
    @discardableResult
    public mutating func move(_ pane: TileID, to target: TileID, zone: TileDropZone) -> Bool {
        guard let r = root?.moving(pane, to: target, zone: zone) else { return false }
        root = r
        zoomed = nil
        active = pane
        return true
    }

    public mutating func setRatio(at path: [Int], _ ratio: Double) {
        root = root?.settingRatio(at: path, to: ratio)
    }
}

/// What the app keeps between runs (Application Support JSON): every row's layout by container id,
/// and the row that was shown.
public struct SavedLayouts: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public var version: Int
    public var current: String?
    public var rows: [String: RowLayout]

    public init(current: String? = nil, rows: [String: RowLayout] = [:]) {
        version = SavedLayouts.currentVersion
        self.current = current
        self.rows = rows
    }

    /// nil for anything this version can't read (including the old one-tree-per-window file).
    public static func decode(_ data: Data) -> SavedLayouts? {
        guard let s = try? JSONDecoder().decode(SavedLayouts.self, from: data), s.version == currentVersion else { return nil }
        return s
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Forget rows that no longer exist.
    public mutating func prune(keeping ids: Set<String>) {
        rows = rows.filter { ids.contains($0.key) }
        if let c = current, !ids.contains(c) { current = nil }
    }

    /// The session the old single-tree layout file had active (`{"root":…,"sessions":{"1":"name",…},"active":1}`),
    /// so the first run after the change opens that session's row. The tree itself can't be carried
    /// over: its tiles mixed sessions from different rows.
    public static func legacyActiveSession(_ data: Data) -> String? {
        struct Legacy: Decodable {
            var sessions: [Int: String]
            var active: Int
        }
        guard let l = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        return l.sessions[l.active]
    }
}
