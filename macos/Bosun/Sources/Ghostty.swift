import AppKit
import BosunCore
import GhosttyKit
import Synchronization
import UniformTypeIdentifiers

/// A raw pointer handed between threads (libghostty callback state).
struct RawPtr: @unchecked Sendable {
    let p: UnsafeMutableRawPointer?
}

/// The single libghostty app shared by every terminal view: one font atlas and one config.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var diagnostics: [String] = []
    /// Ghostty theme names bundled in Resources/ghostty/themes.
    let availableThemes: Set<String>
    private var terminalThemeLines: [String] = []

    nonisolated(unsafe) static var appHandle: ghostty_app_t?
    nonisolated static let tickScheduled = Atomic<Bool>(false)

    /// App shortcuts own these; Ghostty's defaults for them never reach a terminal.
    static let unbinds: [String] = {
        var keys = [
            "super+d", "super+shift+d", "super+t", "super+shift+t", "super+n", "super+shift+n",
            "super+w", "super+alt+w", "super+shift+w", "super+shift+alt+w", "super+k", "super+shift+k", "super+shift+u",
            "super+enter", "super+shift+enter", "super+comma", "super+shift+comma",
            "super+bracket_left", "super+bracket_right", "super+shift+bracket_left", "super+shift+bracket_right",
            "super+ctrl+bracket_left", "super+ctrl+bracket_right", "super+ctrl+equal",
            "super+f", "super+shift+f", "super+e", "super+g", "super+shift+g", "super+alt+i", "super+shift+p",
            "ctrl+tab", "ctrl+shift+tab",
        ]
        for arrow in ["arrow_up", "arrow_down", "arrow_left", "arrow_right"] {
            keys += ["super+alt+\(arrow)", "super+ctrl+\(arrow)", "super+ctrl+shift+\(arrow)"]
        }
        for i in 1...9 { keys += ["super+digit_\(i)", "super+\(i)"] }
        return keys
    }()

    private init() {
        let themesDir = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes").path ?? ""
        availableThemes = Set((try? FileManager.default.contentsOfDirectory(atPath: themesDir)) ?? [])
        config = buildConfig()

        var rt = GhosttyRuntime.callbacks()
        app = ghostty_app_new(&rt, config)
        GhosttyRuntime.appHandle = app
        if let app { ghostty_app_set_focus(app, NSApp.isActive) }
    }

    /// The runtime callbacks. Built outside the main actor: libghostty calls them from its own threads.
    nonisolated private static func callbacks() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.wakeup() },
            action_cb: { _, target, action in GhosttyRuntime.handleAction(target: target, action: action) },
            read_clipboard_cb: { ud, location, state, mimes, count, list in
                GhosttyRuntime.readClipboard(ud, location: location, state: state, mimes: mimes, count: count, list: list)
            },
            confirm_read_clipboard_cb: { ud, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(ud, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { _, location, contents, len, _ in
                GhosttyRuntime.writeClipboard(location: location, contents: contents, len: len)
            },
            close_surface_cb: { ud, _ in
                guard let view = GhosttyRuntime.view(fromUserdata: ud) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { view.childExited() } }
            }
        )
    }

    /// The user's Ghostty config, then the app's overrides (and an optional terminal theme) on top.
    private func buildConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        var lines = [
            "# Bosun for Mac overrides, applied after the user's Ghostty config.",
            "confirm-close-surface = false",
            "term = xterm-ghostty",
            "shell-integration = none",
            "scrollback-limit-bytes = 0",
        ]
        lines += GhosttyRuntime.unbinds.map { "keybind = \($0)=unbind" }
        lines += terminalThemeLines
        let path = Paths.cacheDir.appendingPathComponent("ghostty-overrides.conf").path
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        diagnostics = (0..<ghostty_config_diagnostics_count(cfg)).compactMap { i in
            ghostty_config_get_diagnostic(cfg, i).message.map { String(cString: $0) }
        }
        return cfg
    }

    /// Recolour every terminal (the "match terminal to Bosun theme" setting). nil restores the user's theme.
    func setTerminalTheme(_ palette: ThemePalette?) {
        let lines = palette.map { ThemeMap.configLines(for: $0, available: availableThemes) } ?? []
        guard lines != terminalThemeLines, let app else { return }
        terminalThemeLines = lines
        guard let newConfig = buildConfig() else { return }
        ghostty_app_update_config(app, newConfig)
        let old = config
        config = newConfig
        if let old { ghostty_config_free(old) }
    }

    func setAppFocus(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
    }

    func configColor(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    // MARK: Callbacks (any thread)

    nonisolated static func wakeup() {
        if tickScheduled.exchange(true, ordering: .acquiringAndReleasing) { return }
        DispatchQueue.main.async {
            tickScheduled.store(false, ordering: .releasing)
            if let a = appHandle { ghostty_app_tick(a) }
        }
    }

    nonisolated static func view(fromUserdata ud: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let ud else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    nonisolated static func view(for target: ghostty_target_s) -> TerminalView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface else { return nil }
        return view(fromUserdata: ghostty_surface_userdata(s))
    }

    nonisolated static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view = view(for: target)
        switch action.tag {
        case GHOSTTY_ACTION_CELL_SIZE:
            let cs = action.action.cell_size
            let size = CGSize(width: Double(cs.width), height: Double(cs.height))
            DispatchQueue.main.async { MainActor.assumeIsolated { view?.cellSize = size } }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            DispatchQueue.main.async { MainActor.assumeIsolated { view?.childExited() } }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { MainActor.assumeIsolated { view?.setMouseShape(shape) } }
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let p = u.url else { return false }
            let s = String(decoding: UnsafeRawBufferPointer(start: p, count: Int(u.len)), as: UTF8.self)
            DispatchQueue.main.async {
                if let url = URL(string: s), url.scheme != nil { NSWorkspace.shared.open(url) }
                else { NSWorkspace.shared.open(URL(fileURLWithPath: s)) }
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            return true
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE, GHOSTTY_ACTION_SELECTION_CHANGED,
             GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_COMMAND_FINISHED, GHOSTTY_ACTION_PROGRESS_REPORT,
             GHOSTTY_ACTION_DESKTOP_NOTIFICATION, GHOSTTY_ACTION_SECURE_INPUT:
            return true
        default:
            // Window, tab and split management belongs to the app, not to libghostty's keybinds.
            return false
        }
    }

    nonisolated static func writeClipboard(location: ghostty_clipboard_e, contents: UnsafePointer<ghostty_clipboard_content_s>?, len: Int) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let contents, len > 0 else { return }
        for i in 0..<len {
            let c = contents[i]
            guard let mime = c.mime, String(cString: mime).hasPrefix("text/plain"), let data = c.data else { continue }
            let str = String(decoding: UnsafeRawBufferPointer(start: data, count: c.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
            return
        }
    }

    nonisolated static func readClipboard(_ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?,
                                          mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int, list: Bool) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let view = view(fromUserdata: ud) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        var wanted: [String] = []
        if let mimes { for i in 0..<count { if let m = mimes[i] { wanted.append(String(cString: m)) } } }
        let st = RawPtr(p: state)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var reps: [(String, Data)] = []
                let pb = NSPasteboard.general
                for mime in wanted where mime.hasPrefix("text/plain") {
                    if let s = PasteboardText.opinionated(pb) { reps.append(("text/plain", Data(s.utf8))) }
                    break
                }
                view.completeClipboard(state: st, contents: reps, available: list ? ["text/plain"] : [], confirmed: false)
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    nonisolated static func confirmReadClipboard(_ ud: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                                                 state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let view = view(fromUserdata: ud) else { return }
        let st = RawPtr(p: state)
        // Only a paste the user asked for can be confirmed; programs reading the clipboard (OSC 52) are refused.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let confirm else {
            DispatchQueue.main.async { MainActor.assumeIsolated { view.denyClipboard(state: st) } }
            return
        }
        let c = confirm.pointee
        var reps: [(String, Data)] = []
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let x = contents[i]
                let data = x.len > 0 && x.data != nil ? Data(bytes: x.data, count: x.len) : Data()
                reps.append((x.mime.map { String(cString: $0) } ?? "text/plain", data))
            }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let text = reps.first { $0.0 == "text/plain" }.map { String(decoding: $0.1, as: UTF8.self) } ?? ""
                let alert = NSAlert()
                alert.messageText = "Paste text that may run commands?"
                alert.informativeText = String(text.prefix(600))
                alert.addButton(withTitle: "Paste")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    view.completeClipboard(state: st, contents: reps, available: [], confirmed: true)
                } else {
                    view.denyClipboard(state: st)
                }
            }
        }
    }
}

enum PasteboardText {
    /// What a paste or drop inserts: shell-escaped paths for files (space separated), otherwise the text.
    @MainActor
    static func opinionated(_ pb: NSPasteboard) -> String? {
        let strings: [String] = (pb.pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL), let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                return ShellEscape.escape(url.path)
            }
            return item.string(forType: .string)
        }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }
}
