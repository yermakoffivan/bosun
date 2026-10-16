import AppKit
import BosunCore
import Carbon
import GhosttyKit

/// The only class that talks to libghostty per terminal: one `ghostty_surface_t` running `tmux attach` for one session.
/// Keyboard and IME handling is a trimmed port of Ghostty's own SurfaceView_AppKit.swift.
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    /// The session this view's tmux client is on. Changes only when the client is moved inside the
    /// terminal and the app follows it (`TerminalPool.rekey`).
    var session: String
    private(set) var surface: ghostty_surface_t?
    var cellSize = CGSize(width: 8, height: 16)

    /// Called each time libghostty commits a frame to the layer (the "frame rendered" signal).
    var onContents: ((TerminalView) -> Void)?
    /// The tmux client exited on its own (session killed, client detached elsewhere).
    var onExit: ((TerminalView) -> Void)?
    private(set) var contentsCount = 0
    private var contentsObs: NSKeyValueObservation?

    private(set) var rendererVisible = true
    private(set) var hasTerminalFocus = false
    private(set) var exited = false
    /// Set while the app detaches this client itself, so the exit isn't reported as the session ending.
    private(set) var detaching = false
    private(set) var createdAt = CACurrentMediaTime()
    private var cachedTTY: String?

    // Pixel frames always follow layout; the pty size follows at most every `resizeThrottle` seconds.
    var resizeThrottle: TimeInterval = 0
    private var lastSizeSent: CFTimeInterval = 0
    private var pendingSizeTimer: Timer?

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?
    private var mouseCursor: NSCursor = .iBeam

    init(session: String, command: String, frame: NSRect) {
        self.session = session
        super.init(frame: frame.width > 1 ? frame : NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let app = GhosttyRuntime.shared.app else { return }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        command.withCString { cmd in
            cfg.command = cmd
            surface = ghostty_surface_new(app, &cfg)
        }
        if surface == nil { log.error("ghostty_surface_new failed for \(session, privacy: .public)") }
        // libghostty installs its IOSurfaceLayer on this view during ghostty_surface_new.
        if let layer {
            // libghostty may set the contents from its renderer thread; hop to main.
            contentsObs = layer.observe(\.contents, options: []) { @Sendable [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.contentsCount += 1
                        self.onContents?(self)
                    }
                }
            }
        }
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Free the libghostty terminal. libghostty SIGHUPs the client if it is still running (slow: prefer `detachThenFree`).
    func destroy() {
        pendingSizeTimer?.invalidate()
        contentsObs = nil
        onContents = nil
        onExit = nil
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        removeFromSuperview()
    }

    /// Detach the tmux client off the main thread, wait for it to exit, then free the libghostty terminal.
    /// Freeing a live one SIGHUPs and polls on the main thread (~12 ms); this keeps that off it.
    func detachThenFree(socket: String?) {
        detaching = true
        onExit = nil
        isHidden = true
        guard let tty = ttyName, !exited else { destroy(); return }
        DispatchQueue.global(qos: .utility).async {
            TmuxCLI.run(socket: socket, ["detach-client", "-t", tty])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let deadline = CACurrentMediaTime() + 1.0
                    func finish() {
                        if self.exited || CACurrentMediaTime() > deadline { self.destroy() }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { MainActor.assumeIsolated { finish() } } }
                    }
                    finish()
                }
            }
        }
    }

    func childExited() {
        guard !exited else { return }
        exited = true
        if !detaching { onExit?(self) }
    }

    // MARK: State

    func setRendererVisible(_ visible: Bool) {
        guard let surface, visible != rendererVisible else { return }
        rendererVisible = visible
        // The bool means "visible", not "occluded" (see Ghostty's BaseTerminalController).
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// tmux's `#{client_tty}` for this view's client, once the pty exists.
    var ttyName: String? {
        if let cachedTTY { return cachedTTY }
        guard let surface else { return nil }
        let s = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(s) }
        guard let p = s.ptr, s.len > 0 else { return nil }
        let name = String(decoding: UnsafeRawBufferPointer(start: p, count: Int(s.len)), as: UTF8.self)
        cachedTTY = name
        return name
    }

    var gridSize: (cols: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let s = ghostty_surface_size(surface)
        return (Int(s.columns), Int(s.rows))
    }

    private var painted = false

    /// Whether tmux has drawn yet: the viewport has visible text other than login(1)'s banner,
    /// which libghostty's login wrapper prints first unless ~/.hushlogin exists. Latches once true.
    var hasPaintedContent: Bool {
        if painted { return true }
        let lines = viewportText().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { !$0.isEmpty && !$0.hasPrefix("Last login:") && !$0.hasPrefix("You have new mail") && !$0.hasPrefix("You have mail") }) {
            painted = true
        }
        return painted
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

    /// Insert text the way a paste does (bracketed if the program asked for it). Used for drops.
    func paste(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        let len = text.utf8.count
        text.withCString { ghostty_surface_paste_text(surface, $0, UInt(len)) }
    }

    /// Type raw text into the terminal as if keyed (no paste brackets).
    func type(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        let len = text.utf8.count
        text.withCString { ghostty_surface_text(surface, $0, UInt(len)) }
    }

    func bindingAction(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    func completeClipboard(state: RawPtr, contents: [(String, Data)], available: [String], confirmed: Bool) {
        guard let surface else { return }
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var cDatas: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            cDatas.forEach { $0.deallocate() }
        }
        var cContents: [ghostty_clipboard_content_s] = []
        for (mime, data) in contents {
            guard let m = strdup(mime) else { continue }
            cStrings.append(m)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
            cDatas.append(buf)
            data.withUnsafeBytes { if let b = $0.baseAddress { buf.copyMemory(from: b, byteCount: $0.count) } }
            cContents.append(ghostty_clipboard_content_s(mime: m, data: buf.assumingMemoryBound(to: CChar.self), len: data.count))
        }
        var cAvail: [UnsafePointer<CChar>?] = []
        for a in available {
            guard let s = strdup(a) else { continue }
            cStrings.append(s)
            cAvail.append(UnsafePointer(s))
        }
        cContents.withUnsafeBufferPointer { cb in
            cAvail.withUnsafeBufferPointer { ab in
                var complete = ghostty_clipboard_complete_s(contents: cb.baseAddress, contents_len: cb.count,
                                                            available: ab.baseAddress, available_len: ab.count,
                                                            confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state.p)
            }
        }
    }

    func denyClipboard(state: RawPtr) {
        guard let surface else { return }
        ghostty_surface_deny_clipboard_request(surface, state.p)
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: mouseCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: mouseCursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: mouseCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: mouseCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: mouseCursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: mouseCursor = .operationNotAllowed
        default: mouseCursor = .iBeam
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mouseCursor)
    }

    // MARK: Sizing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestGridSize()
    }

    func requestGridSize() {
        guard resizeThrottle > 0 else { sendSize(); return }
        let since = CACurrentMediaTime() - lastSizeSent
        if since >= resizeThrottle {
            sendSize()
        } else if pendingSizeTimer == nil {
            let t = Timer(timeInterval: resizeThrottle - since, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pendingSizeTimer = nil
                    self?.sendSize()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            pendingSizeTimer = t
        }
    }

    /// The final resize at the end of a drag.
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
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window, let surface else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        let fb = convertToBacking(NSRect(origin: .zero, size: bounds.size))
        if bounds.width > 0 { ghostty_surface_set_content_scale(surface, fb.width / bounds.width, fb.height / bounds.height) }
        sendSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let surface, let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, id.uint32Value)
        }
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { surface != nil }

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
        guard let surface, f != hasTerminalFocus else { return }
        hasTerminalFocus = f
        ghostty_surface_set_focus(surface, f)
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { bindingAction("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { bindingAction("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { bindingAction("select_all") }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
                                owner: self, userInfo: nil)
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
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
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
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, TerminalView.mods(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, TerminalView.mods(event.modifierFlags))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, TerminalView.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, TerminalView.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // Tell libghostty the pointer left so hover effects (links) clear.
        ghostty_surface_mouse_pos(surface, -1, -1, TerminalView.mods(event.modifierFlags))
    }

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
        // The window offers key equivalents to every view; only the focused terminal answers.
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }
        // App shortcuts first: the menu owns every Cmd key it defines, so a Ghostty binding can never shadow one.
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        // Ghostty keybinds that survived the overrides (font size, copy mode...) go to libghostty.
        var ev = TerminalView.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var bflags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            ev.text = ptr
            return ghostty_surface_key_is_binding(surface, ev, &bflags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }
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
