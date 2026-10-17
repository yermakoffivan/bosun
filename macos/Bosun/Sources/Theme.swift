import AppKit
import BosunCore

/// The Bosun theme palette as AppKit colours, for the app chrome.
struct AppTheme {
    let palette: ThemePalette
    let bg, panel, panelAlt, selection, text, textMuted, accent, shadow, dimFg: NSColor
    let running, waiting, idle, error, done: NSColor
    let isDark: Bool

    init(_ p: ThemePalette) {
        palette = p
        func c(_ hex: String) -> NSColor {
            guard let rgb = RGB(hex: hex) else { return .magenta }
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
        bg = c(p.bg); panel = c(p.panel); panelAlt = c(p.panelAlt); selection = c(p.selectionBg)
        text = c(p.text); textMuted = c(p.textMuted); accent = c(p.accent); shadow = c(p.shadow); dimFg = c(p.dimFg)
        running = c(p.statusRunning); waiting = c(p.statusWaiting); idle = c(p.statusIdle)
        error = c(p.statusError); done = c(p.statusDone)
        isDark = RGB(hex: p.bg)?.isDark ?? true
    }

    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    func color(for state: AgentState) -> NSColor {
        switch state {
        case .running: running
        case .waiting: waiting
        case .done: done
        case .error: error
        case .idle, .unknown: idle
        }
    }

    /// Ink for a glyph on `accent` (the header's anchor tile), by the TUI's luminance rule.
    var inkOnAccent: NSColor {
        let ink = RGB(hex: palette.accent)?.ink ?? RGB(r: 1, g: 1, b: 1)
        return NSColor(srgbRed: ink.r, green: ink.g, blue: ink.b, alpha: 1)
    }

    /// A colour between two others, in sRGB.
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t, alpha: 1)
    }
}

/// The status dot. "running" is a spinning arc animated by Core Animation in the render server,
/// so a working agent costs the app no CPU per frame.
final class StatusBadge: NSView {
    private let ring = CAShapeLayer()
    private let dot = CAShapeLayer()
    private(set) var state: AgentState?
    private(set) var exited = false
    /// When the badge last changed what it shows (for the status → badge measurement).
    private(set) var lastApplied: CFTimeInterval = 0
    var onApplied: ((AgentState) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
        ring.fillColor = nil
        ring.lineCap = .round
        dot.lineWidth = 1.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let b = bounds
        let d = min(b.width, b.height)
        let r = CGRect(x: (b.width - d) / 2, y: (b.height - d) / 2, width: d, height: d)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = r
        dot.frame = r
        ring.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: d - 2, height: d - 2), transform: nil)
        dot.path = CGPath(ellipseIn: CGRect(x: 1.5, y: 1.5, width: d - 3, height: d - 3), transform: nil)
        CATransaction.commit()
    }

    func set(_ state: AgentState, exited: Bool, theme: AppTheme) {
        let changed = state != self.state || exited != self.exited
        self.state = state
        self.exited = exited
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let color = exited ? theme.dimFg : theme.color(for: state)
        if state == .running && !exited {
            dot.isHidden = true
            ring.isHidden = false
            ring.strokeColor = color.cgColor
            ring.lineWidth = 1.8
            ring.strokeStart = 0
            ring.strokeEnd = 0.7
            if ring.animation(forKey: "spin") == nil {
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = -2 * Double.pi
                a.duration = 0.9
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                ring.add(a, forKey: "spin")
            }
        } else {
            ring.removeAnimation(forKey: "spin")
            ring.isHidden = true
            dot.isHidden = false
            switch (exited, state) {
            case (true, _), (_, .idle), (_, .unknown):
                // Hollow: nothing needs you.
                dot.fillColor = nil
                dot.strokeColor = color.cgColor
            default:
                dot.fillColor = color.cgColor
                dot.strokeColor = color.cgColor
            }
        }
        CATransaction.commit()
        if changed {
            lastApplied = CACurrentMediaTime()
            onApplied?(state)
        }
    }
}
