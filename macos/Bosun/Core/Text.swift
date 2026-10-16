import Foundation

public enum ShellEscape {
    /// The characters Ghostty's own app escapes when it inserts a dropped path (Ghostty.Shell.escape).
    static let escapeCharacters: Set<Character> = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")

    /// Backslash-escape shell-sensitive characters, the way Ghostty inserts dropped paths.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if escapeCharacters.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Text inserted for dropped files: escaped paths separated by spaces.
    public static func dropText(paths: [String]) -> String {
        paths.map(escape).joined(separator: " ")
    }

    /// POSIX single-quote quoting, for building a command line.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0) }), s.allSatisfy(\.isASCII) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum Fuzzy {
    /// Subsequence match score (higher is better), nil when `query` isn't a subsequence of `text`.
    /// Rewards consecutive runs, word starts and a prefix match.
    public static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var qi = 0
        var score = 0
        var run = 0
        var prev: Character = " "
        for (i, c) in t.enumerated() {
            if qi < q.count, c == q[qi] {
                var s = 1 + run * 3
                if i == 0 { s += 8 }
                if !prev.isLetter && !prev.isNumber { s += 5 }
                score += s
                run += 1
                qi += 1
            } else {
                run = 0
            }
            prev = c
        }
        guard qi == q.count else { return nil }
        return score - t.count / 8
    }
}

public enum Stats {
    /// Nearest-rank percentile, `p` in 0...100.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let idx = min(s.count - 1, max(0, Int((p / 100.0 * Double(s.count)).rounded(.up)) - 1))
        return s[idx]
    }
}

public enum Slug {
    /// The TUI's branch slug: alphanumerics lowercased, runs of anything else become one dash.
    public static func make(_ s: String) -> String {
        var out = ""
        var pendingDash = false
        for c in s {
            if c.isLetter || c.isNumber {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(contentsOf: c.lowercased())
            } else {
                pendingDash = true
            }
        }
        return out
    }
}

/// `#rrggbb` → components in 0...1.
public struct RGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xff) / 255
        g = Double((v >> 8) & 0xff) / 255
        b = Double(v & 0xff) / 255
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func ch(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }

    public var isDark: Bool { luminance < 0.25 }

    public func mixed(with o: RGB, _ t: Double) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }
}

/// Whether a pane's foreground command (`pane_command`) is a shell, the same list Bosun uses
/// (agent_hooks `is_shell_command`): a login shell's leading `-` is ignored. A pane at a shell's
/// prompt can be closed without asking.
public enum ShellCommand {
    public static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "pwsh"]

    public static func isShell(_ command: String?) -> Bool {
        guard let command else { return false }
        return shells.contains(String(command.drop { $0 == "-" }))
    }
}
