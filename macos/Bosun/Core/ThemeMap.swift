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

    /// Ghostty config lines that colour the terminal like `theme`: a Ghostty theme when there is a
    /// counterpart (and it exists in `available`), otherwise a palette generated from the Bosun colours.
    public static func configLines(for theme: ThemePalette, available: Set<String>) -> [String] {
        if let g = ghosttyNames[theme.name], available.contains(g) {
            return ["theme = \(g)"]
        }
        return generated(theme)
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
