import AppKit
import Carbon
import GhosttyKit

/// The single class that talks to libghostty for a terminal: one surface attached to one tmux session.
/// Keyboard/IME handling is a trimmed port of Ghostty's own SurfaceView_AppKit.swift.
final class TerminalView: NSView, NSTextInputClient {
    static var nextID = 1

    let session: String
    let viewID: Int
    private(set) var surface: ghostty_surface_t?
    var title = ""
    var cellSize = CGSize(width: 8, height: 16)

    /// Called on the main thread each time libghostty commits a rendered frame to the layer
    /// (the IOSurfaceLayer's `contents` is set). Used as the "frame rendered" signal.
    var onContents: ((TerminalView) -> Void)?
    var onClick: ((TerminalView) -> Void)?
    private(set) var contentsCount = 0
    private var contentsObs: NSKeyValueObservation?

    private(set) var rendererVisible = true
    private(set) var isFocusedTerminal = false
    private(set) var exited = false

    // Grid-resize throttle: pixel frames always follow layout, the pty winsize follows at most every `resizeThrottle` s.
    var resizeThrottle: TimeInterval = 0
    private var lastSizeSent: CFTimeInterval = 0
    private var pendingSizeTimer: Timer?
    private(set) var sizeCallsSent = 0

    // Text input state
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?

    init(session: String, socket: String, frame: NSRect) {
        self.session = session
        self.viewID = TerminalView.nextID
        TerminalView.nextID += 1
        super.init(frame: frame.width > 0 ? frame : NSRect(x: 0, y: 0, width: 800, height: 600))

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        let command = "tmux -L \(socket) attach -t =\(session)"
        let k = strdup("BOSUN_SPIKE_VIEW"), v = strdup("\(viewID)")
        defer { free(k); free(v) }
        var env = [ghostty_env_var_s(key: k, value: v)]
        command.withCString { cmd in
            env.withUnsafeMutableBufferPointer { buf in
                cfg.command = cmd
                cfg.env_vars = buf.baseAddress
                cfg.env_var_count = 1
                surface = ghostty_surface_new(GhosttyRuntime.shared.app, &cfg)
            }
        }
        if surface == nil { NSLog("ghostty_surface_new failed for \(session)") }

        // libghostty installs its IOSurfaceLayer on this view during ghostty_surface_new.
        if let layer = self.layer {
            contentsObs = layer.observe(\.contents, options: []) { [weak self] _, _ in
                guard let self else { return }
                self.contentsCount += 1
                self.onContents?(self)
            }
        }
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Detach: freeing the surface SIGHUPs the tmux client (it detaches; the session lives on).
    func destroy() {
        pendingSizeTimer?.invalidate()
        contentsObs = nil
        onContents = nil
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        removeFromSuperview()
    }

    func childExited(processAlive: Bool) {
        exited = true
    }

    // MARK: Spike-facing API

    func setRendererVisible(_ visible: Bool) {
        guard let surface, visible != rendererVisible else { return }
        rendererVisible = visible
        // NB: despite the name, the bool is "visible", not "occluded" (see Ghostty's BaseTerminalController).
        ghostty_surface_set_occlusion(surface, visible)
    }

    var ttyName: String? {
        guard let surface else { return nil }
        let s = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(s) }
        guard let p = s.ptr, s.len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(s.len)), as: UTF8.self)
    }

    var foregroundPID: Int {
        guard let surface else { return 0 }
        return Int(ghostty_surface_foreground_pid(surface))
    }

    var gridSize: (cols: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let s = ghostty_surface_size(surface)
        return (Int(s.columns), Int(s.rows))
    }

    func viewportText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Write raw bytes to the pty as if typed (Ghostty's `text:` binding action).
    func sendRaw(_ escaped: String) {
        guard let surface else { return }
        let action = "text:\(escaped)"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Sizing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestGridSize()
    }

    func requestGridSize() {
        guard resizeThrottle > 0 else { sendSize(); return }
        let now = CACurrentMediaTime()
        let since = now - lastSizeSent
        if since >= resizeThrottle {
            sendSize()
        } else if pendingSizeTimer == nil {
            let t = Timer(timeInterval: resizeThrottle - since, repeats: false) { [weak self] _ in
                self?.pendingSizeTimer = nil
                self?.sendSize()
            }
            RunLoop.main.add(t, forMode: .common)
            pendingSizeTimer = t
        }
    }

    /// Final resize (mouse-up): send the current size now.
    func flushGridSize() {
        pendingSizeTimer?.invalidate()
        pendingSizeTimer = nil
        sendSize()
    }

    private func sendSize() {
        guard let surface, bounds.width > 1, bounds.height > 1 else { return }
        let px = convertToBacking(NSRect(origin: .zero, size: bounds.size)).size
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
        lastSizeSent = CACurrentMediaTime()
        sizeCallsSent += 1
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window, let surface else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        let fb = convertToBacking(NSRect(origin: .zero, size: bounds.size))
        if bounds.width > 0 {
            ghostty_surface_set_content_scale(surface, fb.width / bounds.width, fb.height / bounds.height)
        }
        sendSize()
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setTerminalFocus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setTerminalFocus(false) }
        return ok
    }

    func setTerminalFocus(_ f: Bool) {
        guard let surface, f != isFocusedTerminal else { return }
        isFocusedTerminal = f
        ghostty_surface_set_focus(surface, f)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
        super.updateTrackingAreas()
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, TerminalView.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onClick?(self)
        guard let surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, TerminalView.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, TerminalView.mods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, TerminalView.mods(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, TerminalView.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        var mods: Int32 = precise ? 1 : 0
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: Keyboard (ported from Ghostty's SurfaceView_AppKit.swift)

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    static func keyEvent(_ event: NSEvent, _ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(event.keyCode)
        k.text = nil
        k.composing = false
        k.mods = mods(event.modifierFlags)
        k.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        k.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []), let cp = chars.unicodeScalars.first {
            k.unshifted_codepoint = cp.value
        }
        return k
    }

    static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    static func keyboardLayoutID() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func suppressComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let s = text.unicodeScalars
        guard let first = s.first, s.index(after: s.startIndex) == s.endIndex else { return false }
        return first.value < 0x20
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }
        let translationGhostty = TerminalView.flags(ghostty_surface_key_translation_mods(surface, TerminalView.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        let layoutBefore: String? = markedBefore ? nil : TerminalView.keyboardLayoutID()
        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])
        if !markedBefore && layoutBefore != TerminalView.keyboardLayoutID() { return }
        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if markedBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !TerminalView.suppressComposingControl(text, composing: composing) {
                _ = committedText(action, text: text)
            }
            return
        }
        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !TerminalView.suppressComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if TerminalView.suppressComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: TerminalView.ghosttyCharacters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let m = TerminalView.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if m.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocusedTerminal, let surface else { return false }
        // Ghostty keybinds (copy/paste etc.) that survived our overrides go to the surface.
        var ev = TerminalView.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var bflags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            ev.text = ptr
            return ghostty_surface_key_is_binding(surface, ev, &bflags)
        }
        if isBinding { keyDown(with: event); return true }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            if !event.modifierFlags.contains(.control) { return false }
            equivalent = "\r"
        case "/":
            if !event.modifierFlags.contains(.control) || !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp { equivalent = event.characters ?? ""; break }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }
        if let final = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                        timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                        characters: equivalent, charactersIgnoringModifiers: equivalent,
                                        isARepeat: event.isARepeat, keyCode: event.keyCode) {
            keyDown(with: final)
        }
        return true
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var k = TerminalView.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        k.composing = composing
        if let text, !text.isEmpty {
            return text.withCString { ptr in k.text = ptr; return ghostty_surface_key(surface, k) }
        }
        return ghostty_surface_key(surface, k)
    }

    private func committedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var k = ghostty_input_key_s()
        k.action = action
        k.mods = GHOSTTY_MODS_NONE
        k.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in k.text = ptr; return ghostty_surface_key(surface, k) }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange { NSRange() }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: break
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: range.length == 0 ? 0 : w, height: max(h, Double(cellSize.height)))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if !chars.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
