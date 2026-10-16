import Foundation

/// What a Cmd+click on a terminal link opens: a URL, or a file or directory on disk.
public enum LinkTarget: Equatable, Sendable {
    case url(URL)
    case file(String)

    /// The URL schemes libghostty's link regex matches (src/config/url.zig). Anything else it
    /// matches is a path, even when it looks like `name.rs:42` (a valid URL scheme to Foundation).
    public static let schemes = [
        "https://", "http://", "mailto:", "ftp://", "file:", "ssh://", "ssh:", "git://", "tel:", "magnet:",
        "ipfs://", "ipns://", "gemini://", "gopher://", "news:",
    ]

    public static func isURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return schemes.contains { lower.hasPrefix($0) }
    }

    /// A path needs the shell's directory to resolve: it's neither absolute nor under `~` or `$HOME`.
    public static func isRelativePath(_ text: String) -> Bool {
        !isURL(text) && !text.hasPrefix("/") && text != "~" && !text.hasPrefix("~/") && !text.hasPrefix("$HOME/")
    }

    /// Resolve the matched text. A path is tried as is, then without a trailing `:line` or
    /// `:line:col`; relative ones against `cwd`. Returns nil for a path that doesn't exist (or a
    /// relative one with no `cwd`), so nothing opens rather than the wrong thing.
    public static func resolve(_ text: String, cwd: String?, home: String,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> LinkTarget? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if isURL(text) { return URL(string: text).map { .url($0) } }
        var candidates = [text]
        let stripped = stripLineSuffix(text)
        if stripped != text { candidates.append(stripped) }
        for c in candidates {
            guard let full = absolute(c, cwd: cwd, home: home) else { continue }
            if exists(full) { return .file(full) }
        }
        return nil
    }

    /// `src/app.rs:42` and `src/app.rs:42:7` become `src/app.rs`.
    public static func stripLineSuffix(_ text: String) -> String {
        var s = Substring(text)
        for _ in 0..<2 {
            guard let colon = s.lastIndex(of: ":") else { break }
            let digits = s[s.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), colon > s.startIndex else { break }
            s = s[..<colon]
        }
        return String(s)
    }

    static func absolute(_ path: String, cwd: String?, home: String) -> String? {
        var p = path
        if p == "~" { p = home }
        else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        else if p.hasPrefix("$HOME/") { p = home + p.dropFirst(5) }
        if !p.hasPrefix("/") {
            // `$OTHER/...` can't be expanded without the shell's environment.
            guard let cwd, !cwd.isEmpty, !p.hasPrefix("$") else { return nil }
            p = cwd + "/" + p
        }
        return (p as NSString).standardizingPath
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
