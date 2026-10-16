import AppKit
import BosunCore

/// Help → Keyboard Shortcuts (Cmd+/): every app shortcut, read from the menus themselves, grouped.
/// It never takes the keyboard: the terminal stays first responder while it's open, Esc or Cmd+/
/// closes it, and so does a click anywhere.
final class ShortcutsPanel: NSView {
    struct Row {
        var title: String
        var keys: String
    }

    struct Group {
        var name: String
        var rows: [Row]
    }

    private let theme: AppTheme
    private let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private var columns: [[(NSTextField, [(NSTextField, NSTextField)])]] = []
    /// Everything but the heading, so a short window scrolls the list instead of cutting it off.
    private let scroll = NSScrollView()
    private let body = FlippedView()
    private(set) var groups: [Group]
    static let rowHeight: CGFloat = 22
    static let columnWidth: CGFloat = 300

    override var isFlipped: Bool { true }

    init(groups: [Group], footnote: String, theme: AppTheme) {
        self.groups = groups
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.backgroundColor = theme.panel.cgColor
        layer?.borderColor = AppTheme.mix(theme.panelAlt, theme.text, 0.12).cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowColor = theme.shadow.cgColor
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = theme.text
        addSubview(heading)
        footer.stringValue = footnote
        footer.font = .systemFont(ofSize: 11.5)
        footer.textColor = theme.textMuted
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = body
        addSubview(scroll)
        body.addSubview(footer)
        // Two columns, groups kept whole, split where the row counts balance best.
        let sizes = groups.map { $0.rows.count + 2 }
        let total = sizes.reduce(0, +)
        var split = groups.count
        var best = Int.max
        for i in 0...groups.count {
            let left = sizes.prefix(i).reduce(0, +)
            if abs(total - 2 * left) < best { best = abs(total - 2 * left); split = i }
        }
        for part in [groups.prefix(split), groups.dropFirst(split)] {
            var col: [(NSTextField, [(NSTextField, NSTextField)])] = []
            for g in part {
                let h = NSTextField(labelWithString: g.name.uppercased())
                h.font = .systemFont(ofSize: 10.5, weight: .semibold)
                h.textColor = theme.textMuted
                body.addSubview(h)
                var rows: [(NSTextField, NSTextField)] = []
                for r in g.rows {
                    let t = NSTextField(labelWithString: r.title)
                    t.font = .systemFont(ofSize: 12.5)
                    t.textColor = theme.text
                    t.lineBreakMode = .byTruncatingTail
                    let k = NSTextField(labelWithString: r.keys)
                    k.font = .systemFont(ofSize: 12.5, weight: .medium)
                    k.textColor = r.keys == "off" ? theme.textMuted : theme.accent
                    k.alignment = .right
                    k.lineBreakMode = .byTruncatingHead
                    body.addSubview(t)
                    body.addSubview(k)
                    rows.append((t, k))
                }
                col.append((h, rows))
            }
            columns.append(col)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The panel's size for a given available width (one column when two don't fit).
    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let two = maxWidth >= 2 * ShortcutsPanel.columnWidth + 3 * 24
        let w = two ? 2 * ShortcutsPanel.columnWidth + 3 * 24 : min(maxWidth, ShortcutsPanel.columnWidth + 2 * 24)
        let colHeights = columns.map { col in col.reduce(CGFloat(0)) { $0 + 26 + CGFloat($1.1.count) * ShortcutsPanel.rowHeight + 10 } }
        let body = two ? (colHeights.max() ?? 0) : colHeights.reduce(0, +)
        let fh = footer.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w - 48, height: 1000)).height ?? 30
        return NSSize(width: w, height: ceil(20 + 24 + 14 + body + fh + 20))
    }

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    override func layout() {
        super.layout()
        let m: CGFloat = 24
        heading.sizeToFit()
        heading.frame.origin = NSPoint(x: m, y: 20)
        let top: CGFloat = 20 + 24 + 14
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - 8))
        let two = bounds.width >= 2 * ShortcutsPanel.columnWidth + 3 * m - 1
        let cw = two ? ShortcutsPanel.columnWidth : bounds.width - 2 * m
        var y: CGFloat = 0
        var maxY: CGFloat = 0
        for (ci, col) in columns.enumerated() {
            let x = two ? m + CGFloat(ci) * (cw + m) : m
            if two { y = 0 }
            for (h, rows) in col {
                h.sizeToFit()
                h.frame = NSRect(x: x, y: y, width: cw, height: h.frame.height)
                y += 26
                for (t, k) in rows {
                    k.sizeToFit()
                    let kw = min(k.frame.width, cw * 0.5)
                    k.frame = NSRect(x: x + cw - kw, y: y, width: kw, height: ShortcutsPanel.rowHeight - 4)
                    t.frame = NSRect(x: x, y: y, width: max(0, cw - kw - 10), height: ShortcutsPanel.rowHeight - 4)
                    y += ShortcutsPanel.rowHeight
                }
                y += 10
            }
            maxY = max(maxY, y)
        }
        let fh = footer.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width - 2 * m, height: 1000)).height ?? 30
        footer.frame = NSRect(x: m, y: maxY, width: bounds.width - 2 * m, height: fh)
        body.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: maxY + fh + 12)
    }

    /// Whether the list is taller than the panel (so it scrolls).
    var scrolls: Bool { body.frame.height > scroll.contentSize.height + 0.5 }

    override func scrollWheel(with event: NSEvent) { scroll.scrollWheel(with: event) }

    /// Clicks stop here (so they never reach a terminal underneath); the controller closes the panel on any click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// "⇧⌘N" for a menu item's key equivalent, nil when it has none.
    static func keyLabel(_ item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard let scalar = key.unicodeScalars.first else { return nil }
        let m = item.keyEquivalentModifierMask
        // macOS gives Enter Full Screen the Globe (fn) key.
        var s = m.contains(.function) ? "fn " : ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) || (key.count == 1 && key != key.lowercased()) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch scalar.value {
        case 0xF700: s += "↑"
        case 0xF701: s += "↓"
        case 0xF702: s += "←"
        case 0xF703: s += "→"
        case 0xF704...0xF71B: s += "F\(scalar.value - 0xF704 + 1)"
        case 0x0D: s += "↩"
        case 0x1B: s += "⎋"
        case 0x20: s += "Space"
        default: s += key.uppercased()
        }
        return s
    }
}
