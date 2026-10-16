import AppKit
import GhosttyKit

/// One libghostty app instance shared by every TerminalView (shared font atlas + config).
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t!
    private(set) var config: ghostty_config_t!
    var diagnostics: [String] = []
    var loadedOverrides = ""

    private var tickScheduled = false
    private let tickLock = NSLock()

    private init() {
        config = GhosttyRuntime.loadConfig(diagnostics: &diagnostics, overrides: &loadedOverrides)

        var rt = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.wakeup() },
            action_cb: { _, target, action in GhosttyRuntime.handleAction(target: target, action: action) },
            read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, contents, len, _ in
                guard let contents, len > 0 else { return }
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
            },
            close_surface_cb: { userdata, processAlive in
                guard let userdata else { return }
                let view = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async { view.childExited(processAlive: processAlive) }
            }
        )
        guard let app = ghostty_app_new(&rt, config) else {
            fatalError("ghostty_app_new failed")
        }
        self.app = app
        ghostty_app_set_focus(app, true)
    }

    /// Load the user's Ghostty config (same files Ghostty.app reads), then apply app overrides on top.
    static func loadConfig(diagnostics: inout [String], overrides: inout String) -> ghostty_config_t {
        guard let cfg = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)

        var lines = [
            "# Bosun spike overrides, applied after the user's config.",
            "confirm-close-surface = false",
            // The tmux client runs against our bundled terminfo, whatever TERM the user picked for shells.
            "term = xterm-ghostty",
            // App shortcuts own these; strip Ghostty's defaults so they never reach the surface.
            "keybind = super+d=unbind",
            "keybind = super+shift+d=unbind",
            "keybind = super+t=unbind",
            "keybind = super+n=unbind",
            "keybind = super+w=unbind",
            "keybind = super+digit_1=unbind",
            "keybind = super+digit_2=unbind",
            "keybind = super+digit_3=unbind",
            "keybind = super+digit_4=unbind",
            "keybind = super+digit_5=unbind",
            "keybind = super+digit_6=unbind",
        ]
        // tmux owns history; keep Ghostty's own scrollback tiny unless asked not to (memory A/B).
        if ProcessInfo.processInfo.environment["BOSUN_SPIKE_SCROLLBACK"] != "default" {
            lines.append("scrollback-limit = 0")
        }
        overrides = lines.joined(separator: "\n") + "\n"
        let path = NSTemporaryDirectory() + "bosun-spike-ghostty-overrides.conf"
        try? overrides.write(toFile: path, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)

        let n = ghostty_config_diagnostics_count(cfg)
        for i in 0..<n {
            let d = ghostty_config_get_diagnostic(cfg, i)
            if let msg = d.message { diagnostics.append(String(cString: msg)) }
        }
        return cfg
    }

    /// Read a config value (used to prove the user's config was loaded).
    func configString(_ key: String) -> String? {
        var ptr: UnsafePointer<CChar>? = nil
        guard ghostty_config_get(config, &ptr, key, UInt(key.utf8.count)), let ptr else { return nil }
        return String(cString: ptr)
    }

    func configUInt(_ key: String) -> UInt? {
        var v: UInt = 0
        guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)) else { return nil }
        return v
    }

    func configColor(_ key: String) -> String? {
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return String(format: "#%02x%02x%02x", c.r, c.g, c.b)
    }

    func configDouble(_ key: String) -> Double? {
        var v: Float = 0
        guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)) else { return nil }
        return Double(v)
    }

    static func wakeup() {
        let rt = GhosttyRuntime.shared
        rt.tickLock.lock()
        if rt.tickScheduled { rt.tickLock.unlock(); return }
        rt.tickScheduled = true
        rt.tickLock.unlock()
        DispatchQueue.main.async {
            rt.tickLock.lock(); rt.tickScheduled = false; rt.tickLock.unlock()
            ghostty_app_tick(rt.app)
        }
    }

    static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        var view: TerminalView? = nil
        if target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface, let ud = ghostty_surface_userdata(s) {
            view = Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
        }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let t = action.action.set_title.title {
                let title = String(cString: t)
                DispatchQueue.main.async { view?.title = title }
            }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cs = action.action.cell_size
            DispatchQueue.main.async { view?.cellSize = CGSize(width: Double(cs.width), height: Double(cs.height)) }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            DispatchQueue.main.async { view?.childExited(processAlive: false) }
            return true
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_MOUSE_SHAPE, GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_CONFIG_CHANGE:
            return true
        default:
            return false
        }
    }
}
