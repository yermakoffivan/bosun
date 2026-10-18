import AppKit
import BosunCore

/// The main window. Every first-responder change goes through the controller's policy, so nothing
/// but the active terminal (or an open rename/palette/sheet) can hold the keyboard (design 7b).
final class MainWindow: NSWindow {
    var responderPolicy: ((NSResponder?) -> NSResponder?)?
    private var redirecting = false

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let policy = responderPolicy, !redirecting else { return super.makeFirstResponder(responder) }
        let target = policy(responder)
        if target === responder { return super.makeFirstResponder(responder) }
        redirecting = true
        defer { redirecting = false }
        _ = super.makeFirstResponder(target)
        return false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Content view: sidebar | (title band over the main area). Manual layout, sidebar resizable by its edge.
final class RootView: NSView {
    let sidebar: NSView
    let band = TitleBand()
    let main: NSView
    var sidebarWidth: CGFloat {
        didSet { needsLayout = true }
    }
    var titlebarHeight: CGFloat = 28
    var onSidebarResized: ((CGFloat) -> Void)?
    /// Dragging the sidebar's edge resizes the main area: true when it starts, false when it ends.
    var onSidebarDrag: ((Bool) -> Void)?
    private var resizing = false

    override var isFlipped: Bool { true }

    init(sidebar: NSView, main: NSView, sidebarWidth: CGFloat) {
        self.sidebar = sidebar
        self.main = main
        self.sidebarWidth = sidebarWidth
        super.init(frame: .zero)
        addSubview(sidebar)
        addSubview(band)
        addSubview(main)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let sw = min(max(180, sidebarWidth), max(180, bounds.width * 0.5))
        sidebar.frame = NSRect(x: 0, y: 0, width: sw, height: bounds.height)
        band.frame = NSRect(x: sw, y: 0, width: max(0, bounds.width - sw), height: titlebarHeight)
        let mainFrame = NSRect(x: sw, y: titlebarHeight, width: max(0, bounds.width - sw), height: max(0, bounds.height - titlebarHeight))
        if main.frame != mainFrame { main.frame = mainFrame }
    }

    private var edgeRect: NSRect { NSRect(x: sidebar.frame.maxX - 3, y: titlebarHeight, width: 6, height: bounds.height - titlebarHeight) }

    override func resetCursorRects() { addCursorRect(edgeRect, cursor: .resizeLeftRight) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if edgeRect.contains(p) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        resizing = edgeRect.contains(convert(event.locationInWindow, from: nil))
        if resizing { onSidebarDrag?(true) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard resizing else { return }
        sidebarWidth = min(480, max(180, convert(event.locationInWindow, from: nil).x))
        layoutSubtreeIfNeeded()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        if resizing {
            onSidebarResized?(sidebarWidth)
            onSidebarDrag?(false)
        }
        resizing = false
    }
}

/// The strip in the titlebar over the main area: the active session's name and path, plus short notices.
final class TitleBand: NSView {
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private var noteTimer: Timer?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        note.alignment = .right
        note.lineBreakMode = .byTruncatingTail
        addSubview(title)
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let h = bounds.height
        title.sizeToFit()
        let tw = min(title.frame.width, bounds.width * 0.6)
        title.frame = NSRect(x: (bounds.width - tw) / 2, y: (h - title.frame.height) / 2, width: tw, height: title.frame.height)
        note.sizeToFit()
        let nw = min(note.frame.width, max(0, bounds.width - title.frame.maxX - 24))
        note.frame = NSRect(x: bounds.width - nw - 12, y: (h - note.frame.height) / 2, width: nw, height: note.frame.height)
    }

    func set(title t: String, theme: AppTheme) {
        title.font = Fonts.ui(12.5, .semibold)
        note.font = Fonts.ui(11.5)
        title.stringValue = t
        title.textColor = theme.text
        note.textColor = theme.textMuted
        layer?.backgroundColor = theme.bg.cgColor
        needsLayout = true
    }

    var noteText: String { note.stringValue }

    /// Change the current notice's text without restarting its timer, if it is still showing `old`.
    func replaceNote(_ old: String, with new: String) {
        guard note.stringValue == old, old != new else { return }
        note.stringValue = new
        needsLayout = true
    }

    /// A transient message (a daemon notice, "next key goes to the terminal"). nil clears it.
    func flash(_ text: String?, color: NSColor? = nil, seconds: TimeInterval = 4) {
        noteTimer?.invalidate()
        note.stringValue = text ?? ""
        if let color { note.textColor = color }
        needsLayout = true
        guard text != nil, seconds > 0 else { return }
        noteTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flash(nil) }
        }
    }
}

/// Cmd+K: a fuzzy quick-jump over sessions. It borrows the keyboard while open (design 7b).
final class PaletteView: NSView, NSTextFieldDelegate {
    struct Entry {
        var title: String
        var subtitle: String
        var state: AgentState?
        var exited: Bool
        var action: () -> Void
    }

    let field = NSTextField()
    private var all: [Entry] = []
    private var shown: [Entry] = []
    private var selected = 0
    private var rows: [PaletteRow] = []
    var theme: AppTheme
    var onClose: (() -> Void)?
    var source: ((String) -> [Entry])?
    static let width: CGFloat = 560
    static var rowHeight: CGFloat { max(34, Fonts.height(34)) }
    static let maxRows = 9

    override var isFlipped: Bool { true }

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Fonts.ui(17, scaled: false)
        field.placeholderString = "Go to session…"
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        addSubview(field)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = theme.panel.cgColor
        layer?.borderColor = AppTheme.mix(theme.panelAlt, theme.text, 0.12).cgColor
        layer?.shadowColor = theme.shadow.cgColor
        field.textColor = theme.text
        field.placeholderAttributedString = NSAttributedString(string: "Go to session…",
            attributes: [.foregroundColor: theme.textMuted, .font: Fonts.ui(17, scaled: false)])
        rows.forEach { $0.needsDisplay = true }
    }

    func refresh() {
        shown = source?(field.stringValue) ?? []
        selected = min(selected, max(0, shown.count - 1))
        rebuildRows()
    }

    var preferredHeight: CGFloat { 52 + CGFloat(min(shown.count, PaletteView.maxRows)) * PaletteView.rowHeight + (shown.isEmpty ? 0 : 8) }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        for (i, e) in shown.prefix(PaletteView.maxRows).enumerated() {
            let r = PaletteRow(entry: e, theme: theme)
            r.isSelected = i == selected
            r.onClick = { [weak self] in self?.choose(i) }
            r.onHover = { [weak self] in self?.select(i) }
            rows.append(r)
            addSubview(r)
        }
        if let sv = superview { frame.size.height = preferredHeight; sv.needsLayout = true }
        needsLayout = true
    }

    private func select(_ i: Int) {
        guard i != selected, i < rows.count else { return }
        selected = i
        for (j, r) in rows.enumerated() { r.isSelected = j == i }
    }

    private func choose(_ i: Int) {
        guard i < shown.count else { return }
        let e = shown[i]
        onClose?()
        e.action()
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 18, y: 14, width: bounds.width - 36, height: 24)
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 6, y: 50 + CGFloat(i) * PaletteView.rowHeight, width: bounds.width - 12, height: PaletteView.rowHeight)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        selected = 0
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            select(min(selected + 1, rows.count - 1)); return true
        case #selector(NSResponder.moveUp(_:)):
            select(max(selected - 1, 0)); return true
        case #selector(NSResponder.insertNewline(_:)):
            choose(selected); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?(); return true
        default:
            return false
        }
    }
}

final class PaletteRow: NSView {
    let entry: PaletteView.Entry
    let theme: AppTheme
    private let badge = StatusBadge(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(entry: PaletteView.Entry, theme: AppTheme) {
        self.entry = entry
        self.theme = theme
        super.init(frame: .zero)
        title.stringValue = entry.title
        title.font = Fonts.ui(13.5, .medium)
        title.textColor = entry.exited ? theme.textMuted : theme.text
        title.lineBreakMode = .byTruncatingTail
        subtitle.stringValue = entry.subtitle
        subtitle.font = Fonts.ui(11.5)
        subtitle.textColor = theme.textMuted
        subtitle.alignment = .right
        subtitle.lineBreakMode = .byTruncatingMiddle
        addSubview(title)
        addSubview(subtitle)
        if let s = entry.state {
            addSubview(badge)
            badge.set(s, exited: entry.exited, theme: theme)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        badge.frame = NSRect(x: 14, y: (h - 10) / 2, width: 10, height: 10)
        subtitle.sizeToFit()
        let sw = min(subtitle.frame.width, bounds.width * 0.45)
        subtitle.frame = NSRect(x: bounds.width - sw - 14, y: (h - subtitle.frame.height) / 2, width: sw, height: subtitle.frame.height)
        title.sizeToFit()
        let tx: CGFloat = entry.state == nil ? 14 : 34
        title.frame = NSRect(x: tx, y: (h - title.frame.height) / 2, width: max(0, subtitle.frame.minX - tx - 10), height: title.frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
