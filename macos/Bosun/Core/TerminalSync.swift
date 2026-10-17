import Foundation

/// "Terminal colours: follow the Bosun theme" defaults to on. An install that never touched the setting gets the
/// new default, and hears about it once.
public enum TerminalSync {
    /// The setting's default.
    public static let defaultOn = true

    /// The title band's one-time note.
    public static let note = "Terminals now follow the Bosun theme (Settings → Theme to change)"

    /// Whether this launch shows the note: the setting was never stored (so it is on only because of the
    /// default), the note hasn't been shown, and the install isn't brand new (a first launch has nothing to
    /// announce).
    public static func shouldNote(stored: Bool?, alreadyNoted: Bool, existingInstall: Bool) -> Bool {
        stored == nil && !alreadyNoted && existingInstall
    }
}
