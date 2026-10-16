import Foundation

/// Maps Bosun themes onto Ghostty themes for the optional "match terminal to Bosun theme" setting.
public enum ThemeMap {
    /// Bundled Bosun theme → Ghostty theme of the same family (names from Ghostty's themes directory).
    public static let ghosttyNames: [String: String] = [
        "tokyonight": "TokyoNight",
        "dracula": "Dracula",
        "catppuccin-mocha": "Catppuccin Mocha",
        "one-dark-pro": "Atom One Dark",
        "ayu-mirage": "Ayu Mirage",
        "nord": "Nord",
        "gruvbox-dark": "Gruvbox Dark",
        "rose-pine": "Rose Pine",
        "github-dark": "GitHub Dark",
        "github-light": "GitHub Light Default",
        "one-light": "Atom One Light",
        "solarized-light": "iTerm2 Solarized Light",
        "ayu-light": "Ayu Light",
    ]

    /// Ghostty config lines that colour the terminal like `theme`: the colours of its Ghostty counterpart when
    /// there is one (in `available`, read with `read`), otherwise a palette generated from the Bosun colours.
    ///
    /// The counterpart's colours are written out rather than as `theme = Name`: Ghostty applies a theme beneath
    /// every colour set explicitly in the user's config, so a `background` or `palette` line there would win.
    public static func configLines(for theme: ThemePalette, available: Set<String>,
                                   read: (String) -> String? = bundledTheme) -> [String] {
        if let g = ghosttyNames[theme.name], available.contains(g), let text = read(g) {
            let lines = colorLines(text)
            if !lines.isEmpty { return lines }
        }
        return generated(theme)
    }

    /// The colour settings of a Ghostty theme file, one `key = value` per line (comments and other keys dropped).
    public static func colorLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard colorKeys.contains(key), !value.isEmpty else { return nil }
            return "\(key) = \(value)"
        }
    }

    static let colorKeys: Set<String> = [
        "palette", "background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground",
    ]

    /// A Ghostty theme file from the app bundle (Resources/ghostty/themes).
    public static func bundledTheme(_ name: String) -> String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes") else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    public static func generated(_ t: ThemePalette) -> [String] {
        let bg = RGB(hex: t.bg) ?? RGB(r: 0, g: 0, b: 0)
        let fg = RGB(hex: t.text) ?? RGB(r: 1, g: 1, b: 1)
        let muted = RGB(hex: t.textMuted) ?? fg.mixed(with: bg, 0.5)
        let red = RGB(hex: t.statusError) ?? RGB(r: 0.88, g: 0.42, b: 0.46)
        let green = RGB(hex: t.statusRunning) ?? RGB(r: 0.5, g: 0.85, b: 0.56)
        let yellow = RGB(hex: t.statusWaiting) ?? RGB(r: 0.96, g: 0.65, b: 0.26)
        let blue = RGB(hex: t.statusDone) ?? RGB(r: 0.36, g: 0.61, b: 0.96)
        let accent = RGB(hex: t.accent) ?? blue
        let cyan = blue.mixed(with: green, 0.5)
        let magenta = red.mixed(with: blue, 0.5)
        let dark = bg.isDark
        let black = dark ? bg.mixed(with: fg, 0.12) : fg
        let white = dark ? fg : bg.mixed(with: fg, 0.12)
        let normal = [black, red, green, yellow, blue, magenta, cyan, white]
        let toward = dark ? RGB(r: 1, g: 1, b: 1) : RGB(r: 0, g: 0, b: 0)
        var bright = normal.map { $0.mixed(with: toward, 0.18) }
        bright[0] = muted
        var lines = [
            "background = \(t.bg)",
            "foreground = \(t.text)",
            "cursor-color = \(accent.hex)",
            "selection-background = \(t.selectionBg)",
            "selection-foreground = \(t.text)",
        ]
        for (i, c) in (normal + bright).enumerated() { lines.append("palette = \(i)=\(c.hex)") }
        return lines
    }
}
