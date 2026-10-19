import Foundation

/// The folders a typed path could go on to, for the new-session sheet's Path field: what Finder's Go to Folder
/// lists, and the same matching as the TUI's dropdown (src/ui/modal/new_session.rs), except that only folders are
/// offered (a session starts in one) and case doesn't matter (as on the Mac's own disks).
public enum PathCompletion {
    public struct Entry: Equatable, Sendable {
        /// The folder's own name.
        public let name: String
        /// The typed path with this folder chosen: the typed directory, the name and a slash.
        public let path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// `typed` split at its last slash: the directory as typed (ending in "/") and the start of a name after it.
    /// "~" alone is the home folder. Nil when there's nothing to look in: no slash, or "~user".
    public static func split(_ typed: String) -> (dir: String, prefix: String)? {
        if typed == "~" { return ("~/", "") }
        guard let slash = typed.lastIndex(of: "/") else { return nil }
        let dir = String(typed[...slash])
        guard dir.hasPrefix("/") || dir.hasPrefix("~/") else { return nil }
        return (dir, String(typed[typed.index(after: slash)...]))
    }

    /// The folder `dir` (as typed) names on disk.
    public static func expand(_ dir: String, home: String) -> String {
        dir.hasPrefix("~/") ? home + dir.dropFirst() : dir
    }

    /// The folders in the typed directory whose names start with what's typed after it, sorted as Finder sorts them,
    /// following links to folders. Hidden folders only once the name typed starts with a dot.
    public static func folders(matching typed: String, home: String, limit: Int = 50) -> [Entry] {
        let fm = FileManager.default
        guard let (dir, prefix) = split(typed) else { return [] }
        let base = URL(fileURLWithPath: expand(dir, home: home))
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        let hidden = prefix.hasPrefix(".")
        let p = prefix.lowercased()
        var out: [Entry] = []
        // Matched by name first, so only the matches are looked at on disk.
        for name in names.filter({ (hidden || !$0.hasPrefix(".")) && $0.lowercased().hasPrefix(p) })
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: base.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(Entry(name: name, path: dir + name + "/"))
            if out.count == limit { break }
        }
        return out
    }

    /// What Right (or a shell's Tab) completes `typed` to from `entries`, its matches: the one match whole, or the
    /// longest start they share when that's longer than what's typed. Nil when it would add nothing.
    public static func completion(of typed: String, entries: [Entry]) -> String? {
        guard let (dir, prefix) = split(typed), let first = entries.first else { return nil }
        if entries.count == 1 { return first.path }
        var shared = Array(first.name)
        for e in entries.dropFirst() {
            let n = Array(e.name)
            var i = 0
            while i < shared.count, i < n.count, String(shared[i]).lowercased() == String(n[i]).lowercased() { i += 1 }
            shared.removeSubrange(i...)
        }
        return shared.count > prefix.count ? dir + String(shared) : nil
    }
}
