import Foundation

/// Terminal colours for the "match terminal colours to the Bosun theme" setting.
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

    /// Ghostty config lines that colour the terminal like `theme`, from the first of these that applies:
    /// 1. the theme's own `[terminal]` table, which the daemon sends with the theme;
    /// 2. the colours of the Ghostty counterpart in `ghosttyNames` (in `available`, read with `read`), for a daemon
    ///    that predates the table;
    /// 3. a palette generated from the Bosun colours.
    ///
    /// Colours are written out rather than as `theme = Name`: Ghostty applies a theme beneath every colour set
    /// explicitly in the user's config, so a `background` or `palette` line there would win.
    public static func configLines(for theme: ThemePalette, available: Set<String>,
                                   read: (String) -> String? = bundledTheme) -> [String] {
        if let table = theme.terminal, let lines = tableLines(table) { return lines }
        if let g = ghosttyNames[theme.name], available.contains(g), let text = read(g) {
            let lines = colorLines(text)
            if !lines.isEmpty { return lines }
        }
        return generated(theme)
    }

    /// The Ghostty config lines for a `[terminal]` table; nil when it isn't usable (not 16 palette colours, or a
    /// colour that isn't `#rrggbb`), so the next source gets a turn.
    public static func tableLines(_ t: TerminalPalette) -> [String]? {
        let colors = [t.background, t.foreground, t.cursor, t.selectionBg, t.selectionFg] + t.palette
        guard t.palette.count == 16, colors.allSatisfy({ RGB(hex: $0) != nil }) else { return nil }
        var lines = [
            "background = \(t.background)",
            "foreground = \(t.foreground)",
            "cursor-color = \(t.cursor)",
            "selection-background = \(t.selectionBg)",
            "selection-foreground = \(t.selectionFg)",
        ]
        for (i, c) in t.palette.enumerated() { lines.append("palette = \(i)=\(c)") }
        return lines
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
        var normal = [black, red, green, yellow, blue, magenta, cyan, white]
        let toward = dark ? RGB(r: 1, g: 1, b: 1) : RGB(r: 0, g: 0, b: 0)
        var bright = normal.map { $0.mixed(with: toward, 0.18) }
        bright[0] = muted
        // The mixed status colours can land under 2:1 on a dark background. Lift each hue (ANSI 1-6 and 9-14;
        // black and white are meant to sit near the background or the text) toward the text colour until it
        // reads at 3:1.
        func lifted(_ c: RGB) -> RGB {
            var out = c
            var step = 0.0
            while out.contrast(with: bg) < 3, step < 1 {
                step = min(1, step + 0.05)
                out = c.mixed(with: fg, step)
            }
            return out
        }
        for i in 1...6 {
            normal[i] = lifted(normal[i])
            bright[i] = lifted(bright[i])
        }
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
