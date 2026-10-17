import BosunCore
import SwiftUI

/// The Settings window's Light/Dark theme pickers (design 7a). The values live in the daemon's config
/// (`theme_light` / `theme_dark` in config.toml); picking one sends `apply_setting`, never `set_theme`, so the
/// TUI's `theme` stays put.
@MainActor
final class ThemePairModel: ObservableObject {
    enum Side: String {
        case light = "theme_light", dark = "theme_dark"
    }

    @Published private(set) var names: [String] = []
    @Published private(set) var light: String?
    @Published private(set) var dark: String?
    @Published private(set) var theme = ""
    /// The daemon knows the pair (an older `bosun serve` doesn't list the keys).
    @Published private(set) var supported = false
    /// Sends the change: the config key and a theme name, or nil for "Same as Theme".
    var onSet: ((String, String?) -> Void)?

    func update(from st: BosunState) {
        let known = st.themes.map(\.name)
        func value(_ key: String) -> String? {
            guard let v = st.config.value(key)?.stringValue, known.contains(v) else { return nil }
            return v
        }
        let keys = Set(st.config.settings.map(\.key))
        if names != known { names = known }
        if light != value(Side.light.rawValue) { light = value(Side.light.rawValue) }
        if dark != value(Side.dark.rawValue) { dark = value(Side.dark.rawValue) }
        if theme != st.theme.name { theme = st.theme.name }
        let s = keys.contains(Side.light.rawValue) && keys.contains(Side.dark.rawValue)
        if supported != s { supported = s }
    }

    /// Set one side; nil (or "") is "Same as Theme". Shown straight away, confirmed by the daemon's config delta.
    func set(_ side: Side, _ name: String?) {
        let n = name.flatMap { $0.isEmpty ? nil : $0 }
        switch side {
        case .light: light = n
        case .dark: dark = n
        }
        onSet?(side.rawValue, n)
    }

    func binding(_ side: Side) -> Binding<String> {
        Binding(get: { [unowned self] in (side == .light ? self.light : self.dark) ?? "" },
                set: { [unowned self] in self.set(side, $0) })
    }
}

/// The "Theme" group of the Settings window.
struct ThemePairSection: View {
    @ObservedObject var model: ThemePairModel
    @AppStorage("matchTerminalTheme") private var matchTerminalTheme = TerminalSync.defaultOn

    var body: some View {
        Section("Theme") {
            picker("Light theme", .light)
            picker("Dark theme", .dark)
            Text(model.supported
                 ? "Bosun switches with the macOS appearance, including Auto. Same as Theme uses View → Theme (\(model.theme)), which the TUI always uses."
                 : "Needs a newer bosun: update it to pick a theme for each appearance.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Terminal colours", selection: $matchTerminalTheme) {
                Text("Follow the Bosun theme").tag(true)
                Text("Use my Ghostty config").tag(false)
            }
            .pickerStyle(.radioGroup)
            Text(matchTerminalTheme
                 ? "The terminals change colour with the theme above, including with Light and Dark mode. Your Ghostty config file is never changed; font, padding and everything else in it still apply."
                 : "The terminals keep the colours from your Ghostty config, and View → Theme changes only the app around them. Your Ghostty config file is never changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func picker(_ title: String, _ side: ThemePairModel.Side) -> some View {
        Picker(title, selection: model.binding(side)) {
            Text("Same as Theme").tag("")
            Divider()
            ForEach(model.names, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!model.supported)
    }
}
