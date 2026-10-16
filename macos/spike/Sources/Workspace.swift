import AppKit
import SwiftUI

/// Sidebar model.
final class SidebarModel: ObservableObject {
    @Published var sessions: [String] = []
    @Published var pooled: Set<String> = []
    @Published var displayed: [String] = []
    var onSelect: ((String) -> Void)?
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    var body: some View {
        List {
            Section("tmux -L \(spikeSocket)") {
                ForEach(model.sessions, id: \.self) { s in
                    Button(action: { model.onSelect?(s) }) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.displayed.contains(s) ? Color.green : (model.pooled.contains(s) ? Color.orange : Color.gray.opacity(0.3)))
                                .frame(width: 7, height: 7)
                            Text(s).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            if model.displayed.contains(s) { Text("shown").font(.caption2).foregroundStyle(.secondary) }
                            else if model.pooled.contains(s) { Text("warm").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Thin draggable divider between the two tiles.
final class DividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?   // x in superview coordinates
    var onDragEnd: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

/// Main area: manual frame layout, no Auto Layout.
final class MainArea: NSView {
    weak var workspace: Workspace?
    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) { workspace?.layoutTiles() }
}

/// Root content view: sidebar + main area, manual layout.
final class RootView: NSView {
    let sidebar: NSView
    let main: MainArea
    let sidebarWidth: CGFloat = 220
    init(sidebar: NSView, main: MainArea) {
        self.sidebar = sidebar
        self.main = main
        super.init(frame: .zero)
        addSubview(sidebar)
        addSubview(main)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        main.frame = NSRect(x: sidebarWidth, y: 0, width: max(0, bounds.width - sidebarWidth), height: bounds.height)
    }
}

final class Workspace {
    enum Mode { case single, split }

    let area = MainArea()
    let divider = DividerView()
    let model = SidebarModel()

    private(set) var pool: [String: TerminalView] = [:]
    private(set) var lru: [String] = []          // least recent first
    var poolCapacity = 4
    private(set) var mode: Mode = .single
    private(set) var tiles: [String?] = [nil]
    var focusedTile = 0
    var ratio: CGFloat = 0.5
    let dividerWidth: CGFloat = 4

    /// Grid resize throttle applied to visible views during a divider drag (0 = off).
    var dragThrottle: TimeInterval = 0.1
    private(set) var dragging = false
    /// Q1: mark hidden pooled clients `ignore-size` and clear it on show.
    var ignoreSizeOnHide = false
    var log: ((String) -> Void)?
    private(set) var lastFreeDurations: [Double] = []

    init() {
        area.workspace = self
        divider.isHidden = true
        area.addSubview(divider)
        divider.onDrag = { [weak self] x in self?.dragDivider(toX: x) }
        divider.onDragEnd = { [weak self] in self?.endDrag() }
        model.onSelect = { [weak self] s in
            guard let self else { return }
            _ = self.show(s, inTile: self.focusedTile)
        }
    }

    func refreshSessions() {
        model.sessions = Tmux.sessions()
    }

    private func syncModel() {
        model.pooled = Set(pool.keys)
        model.displayed = tiles.compactMap { $0 }
    }

    // MARK: Layout

    func tileRects() -> [NSRect] {
        let b = area.bounds
        switch mode {
        case .single:
            return [b]
        case .split:
            let leftW = floor((b.width - dividerWidth) * ratio)
            return [NSRect(x: 0, y: 0, width: leftW, height: b.height),
                    NSRect(x: leftW + dividerWidth, y: 0, width: b.width - leftW - dividerWidth, height: b.height)]
        }
    }

    func layoutTiles() {
        let rects = tileRects()
        for (i, s) in tiles.enumerated() {
            guard let s, let v = pool[s] else { continue }
            if v.frame != rects[i] { v.frame = rects[i] }
        }
        if mode == .split {
            divider.isHidden = false
            divider.frame = NSRect(x: rects[0].maxX, y: 0, width: dividerWidth, height: area.bounds.height)
        } else {
            divider.isHidden = true
        }
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        if m == .split {
            if tiles.count < 2 { tiles.append(nil) }
        } else {
            if tiles.count > 1, let s = tiles[1] { hide(s) }
            tiles = [tiles[0]]
            focusedTile = 0
        }
        layoutTiles()
        syncModel()
    }

    // MARK: Pool

    func isWarm(_ s: String) -> Bool { pool[s] != nil }

    /// Shows `session` in tile `t`. Returns the view and whether it came from the warm pool.
    @discardableResult
    func show(_ session: String, inTile t: Int, prepare: ((TerminalView) -> Void)? = nil) -> (TerminalView, Bool) {
        // One tile per session: if it's already in another tile, swap the two.
        if let other = tiles.firstIndex(where: { $0 == session }), other != t {
            tiles[other] = tiles[t]
            tiles[t] = session
            layoutTiles()
            focus(tile: t)
            syncModel()
            return (pool[session]!, true)
        }
        let rect = tileRects()[t]
        let warm = pool[session] != nil
        let view: TerminalView
        if let v = pool[session] {
            view = v
            prepare?(view)
            if view.frame != rect { view.frame = rect }
            view.isHidden = false
            view.setRendererVisible(true)
            if ignoreSizeOnHide, let tty = view.ttyName {
                Tmux.run(["refresh-client", "-t", tty, "-f", "!ignore-size"])
            }
        } else {
            view = TerminalView(session: session, socket: spikeSocket, frame: rect)
            prepare?(view)
            view.onClick = { [weak self] v in
                guard let self, let i = self.tiles.firstIndex(where: { $0 == v.session }) else { return }
                self.focusedTile = i
            }
            area.addSubview(view, positioned: .below, relativeTo: divider)
            view.frame = rect
            pool[session] = view
        }
        view.resizeThrottle = 0
        let old = tiles[t]
        tiles[t] = session
        if let old, old != session { hide(old) }
        touch(session)
        evictIfNeeded()
        focus(tile: t)
        syncModel()
        return (view, warm)
    }

    private func hide(_ session: String) {
        guard let v = pool[session] else { return }
        v.isHidden = true
        v.setRendererVisible(false)
        v.setTerminalFocus(false)
        if ignoreSizeOnHide, let tty = v.ttyName {
            Tmux.run(["refresh-client", "-t", tty, "-f", "ignore-size"])
        }
    }

    func focus(tile t: Int) {
        focusedTile = t
        if t < tiles.count, let s = tiles[t], let v = pool[s] {
            v.window?.makeFirstResponder(v)
        }
    }

    private func touch(_ s: String) {
        lru.removeAll { $0 == s }
        lru.append(s)
    }

    private func evictIfNeeded() {
        while pool.count > poolCapacity {
            guard let victim = lru.first(where: { !tiles.contains($0) }) else { return }
            evict(victim)
        }
    }

    func evict(_ s: String) {
        guard let v = pool[s], !tiles.contains(s) else { return }
        let t0 = CACurrentMediaTime()
        v.destroy()
        lastFreeDurations.append(CACurrentMediaTime() - t0)
        pool[s] = nil
        lru.removeAll { $0 == s }
        syncModel()
    }

    /// Detach the tmux client first (off the main thread), wait for the child to exit, then free:
    /// ghostty_surface_free no longer has to SIGHUP + poll waitpid in 10 ms sleeps on the main thread.
    private(set) var lastFreeAfterDetachDurations: [Double] = []
    func evictDetachingFirst(_ s: String) async {
        guard let v = pool[s], !tiles.contains(s) else { return }
        let tty = v.ttyName
        pool[s] = nil
        lru.removeAll { $0 == s }
        syncModel()
        if let tty {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    Tmux.run(["detach-client", "-t", tty])
                    c.resume()
                }
            }
            let end = CACurrentMediaTime() + 1.0
            while !v.exited && CACurrentMediaTime() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        let t0 = CACurrentMediaTime()
        v.destroy()
        lastFreeAfterDetachDurations.append(CACurrentMediaTime() - t0)
    }

    func resetFreeDurations() { lastFreeDurations = []; lastFreeAfterDetachDurations = [] }

    func evictAllHidden() {
        for s in Array(pool.keys) where !tiles.contains(s) { evict(s) }
    }

    func view(for s: String) -> TerminalView? { pool[s] }

    func visibleViews() -> [TerminalView] { tiles.compactMap { $0 }.compactMap { pool[$0] } }

    // MARK: Divider drag

    func beginDrag() {
        dragging = true
        for v in visibleViews() { v.resizeThrottle = dragThrottle }
    }

    func dragDivider(toX x: CGFloat) {
        if !dragging { beginDrag() }
        let w = area.bounds.width - dividerWidth
        guard w > 0 else { return }
        ratio = min(0.85, max(0.15, x / w))
        layoutTiles()
    }

    func setRatio(_ r: CGFloat) {
        if !dragging { beginDrag() }
        ratio = r
        layoutTiles()
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        for v in visibleViews() {
            v.flushGridSize()
            v.resizeThrottle = 0
        }
    }
}
