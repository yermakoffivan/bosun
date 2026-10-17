import Foundation

/// How a file link opens in the editor set in config.toml (`editor`, which the TUI's `e` key runs too).
public enum EditorCommand {
    /// The editors Settings offers when one is installed: its name and its command.
    public static let known: [(name: String, command: String)] = [
        ("Zed", "zed"), ("Visual Studio Code", "code"), ("Cursor", "cursor"), ("Windsurf", "windsurf"),
        ("VSCodium", "codium"), ("Sublime Text", "subl"), ("Xcode", "xed"), ("BBEdit", "bbedit"),
    ]

    /// The program and arguments that open `path` at `line` and `column` in `editor`. The setting's first word is
    /// the program and any more are passed first; each known editor gets the line its own way, and any other
    /// command gets the bare path. Nil for an empty setting.
    public static func arguments(editor: String, path: String, line: Int?, column: Int?) -> (program: String, args: [String])? {
        let words = editor.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first else { return nil }
        var args = Array(words.dropFirst())
        let at = line.map { l in column.map { "\(path):\(l):\($0)" } ?? "\(path):\(l)" }
        switch (program as NSString).lastPathComponent {
        case "code", "code-insiders", "cursor", "windsurf", "codium":
            args += at.map { ["-g", $0] } ?? [path]
        case "zed", "zeditor", "subl":
            args.append(at ?? path)
        case "xed":
            if let line { args += ["-l", String(line)] }
            args.append(path)
        case "bbedit":
            if let line { args.append("+\(line)") }
            args.append(path)
        default:
            args.append(path)
        }
        return (program, args)
    }

    /// `program` as an executable path: as given when it has a slash, else the first match in `searchPath`
    /// (a PATH string). Nil when there's none.
    public static func resolve(_ program: String, searchPath: String,
                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if program.contains("/") {
            let p = (program as NSString).expandingTildeInPath
            return isExecutable(p) ? p : nil
        }
        return searchPath.split(separator: ":").map { "\($0)/\(program)" }.first(where: isExecutable)
    }
}
