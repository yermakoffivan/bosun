import Foundation

/// Which Bosun theme the app chrome shows: `theme` (what the TUI uses and View → Theme sets), or one side of the
/// optional Light/Dark pair (`theme_light` / `theme_dark` in config.toml) that follows the macOS appearance.
public enum ThemeChoice {
    public enum Appearance: Equatable, Sendable {
        case light, dark
    }

    /// The pair by name; nil is "same as Theme".
    public struct Pair: Equatable, Sendable {
        public var light: String?
        public var dark: String?
        public init(light: String?, dark: String?) { self.light = light; self.dark = dark }

        /// Either side is set, so the chrome follows the appearance.
        public var isActive: Bool { light != nil || dark != nil }

        /// The menu's note, e.g. "Following macOS appearance (Light: github-light, Dark: nord)"; nil when inactive.
        public func note(theme: String) -> String? {
            guard isActive else { return nil }
            return "Following macOS appearance (Light: \(light ?? theme), Dark: \(dark ?? theme))"
        }

        /// What View → Theme's list sets while the pair is active: always the TUI's theme, and the app's
        /// for a side that's "Same as Theme".
        public var listHeader: String {
            switch (light, dark) {
            case (nil, nil), (.some, .some): "Theme for the TUI"
            case (nil, .some): "Theme for the TUI and Light mode"
            case (.some, nil): "Theme for the TUI and Dark mode"
            }
        }

        /// The theme shown for `appearance`.
        public func name(for appearance: Appearance, theme: String) -> String {
            (appearance == .dark ? dark : light) ?? theme
        }
    }

    /// The palette for `appearance`: that side of the pair when it's set, otherwise `theme`.
    public static func palette(for appearance: Appearance, theme: ThemePalette, light: ThemePalette?,
                               dark: ThemePalette?) -> ThemePalette {
        switch appearance {
        case .light: light ?? theme
        case .dark: dark ?? theme
        }
    }
}
