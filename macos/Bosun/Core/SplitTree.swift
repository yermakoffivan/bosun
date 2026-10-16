import CoreGraphics
import Foundation

public typealias TileID = Int

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

/// The main area's tiles: the tree, which session each tile shows, and the active tile.
/// Keeps the "a session is in at most one tile" rule.
public struct TileLayout: Codable, Equatable, Sendable {
    public private(set) var root: SplitNode
    public private(set) var sessions: [TileID: String]
    public private(set) var active: TileID
    private var nextID: TileID

    public static let maxTiles = 9

    public init() {
        root = .leaf(1)
        sessions = [:]
        active = 1
        nextID = 2
    }

    public var tiles: [TileID] { root.leaves }
    public var count: Int { tiles.count }
    public var activeSession: String? { sessions[active] }

    public func session(in tile: TileID) -> String? { sessions[tile] }

    public func tile(showing session: String) -> TileID? {
        sessions.first { $0.value == session }?.key
    }

    public var visibleSessions: Set<String> { Set(sessions.values) }

    public mutating func activate(_ tile: TileID) {
        if root.contains(tile) { active = tile }
    }

    /// Show `session` in `tile`. If another tile shows it, that tile is emptied first
    /// (callers that prefer to activate the other tile check `tile(showing:)` before calling).
    /// Returns the session the tile showed before, if any.
    @discardableResult
    public mutating func assign(_ session: String?, to tile: TileID) -> String? {
        guard root.contains(tile) else { return nil }
        let old = sessions[tile]
        if let session, let other = self.tile(showing: session), other != tile { sessions[other] = nil }
        sessions[tile] = session
        return old == session ? nil : old
    }

    /// Split the active tile; the new tile becomes active. Returns its id, or nil at the tile cap.
    @discardableResult
    public mutating func splitActive(_ axis: SplitAxis) -> TileID? {
        guard count < TileLayout.maxTiles else { return nil }
        let id = nextID
        nextID += 1
        root = root.splitting(active, axis: axis, newTile: id)
        active = id
        return id
    }

    /// Close a tile. The last tile can't close; it's emptied instead.
    /// Returns the session it showed. The new active tile is the closed tile's neighbour in the tree.
    @discardableResult
    public mutating func close(_ tile: TileID) -> String? {
        guard root.contains(tile) else { return nil }
        let old = sessions[tile]
        guard count > 1, let newRoot = root.removing(tile) else {
            sessions[tile] = nil
            return old
        }
        let order = tiles
        let idx = order.firstIndex(of: tile) ?? 0
        root = newRoot
        sessions[tile] = nil
        if active == tile {
            let remaining = root.leaves
            active = remaining[min(max(0, idx - 1), remaining.count - 1)]
        }
        return old
    }

    /// Move a tile beside another, or swap them (see `SplitNode.moving`). The moved tile becomes
    /// active and keeps its session. Returns false when nothing changed.
    @discardableResult
    public mutating func move(_ tile: TileID, to target: TileID, zone: TileDropZone) -> Bool {
        guard let r = root.moving(tile, to: target, zone: zone) else { return false }
        root = r
        active = tile
        return true
    }

    public mutating func setRatio(at path: [Int], _ ratio: Double) {
        root = root.settingRatio(at: path, to: ratio)
    }

    /// Drop sessions that no longer exist from their tiles.
    public mutating func prune(keeping alive: (String) -> Bool) -> [String] {
        var gone: [String] = []
        for (t, s) in sessions where !alive(s) {
            sessions[t] = nil
            gone.append(s)
        }
        return gone
    }
}
