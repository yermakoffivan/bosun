import Foundation

/// "Terminal colours: follow the Bosun theme" defaults to on. An install that never touched the setting gets the
/// new default, and hears about it once.
public enum TerminalSync {
    /// The setting's default.
    public static let defaultOn = true

    /// The title band's one-time note.
    public static let note = "Terminals now follow the Bosun theme (Settings → Theme to change)"

    /// The first launch with terminal sync switches it on for everyone, once, whatever was stored before
    /// (it used to be off by default, so a stored off mostly means "never changed it"). An existing install
    /// whose terminals change because of it is told. After that, an off chosen in Settings sticks.
    public static func migrate(stored: Bool?, alreadyMigrated: Bool, existingInstall: Bool) -> (turnOn: Bool, note: Bool) {
        guard !alreadyMigrated else { return (false, false) }
        return (stored == false, existingInstall && stored != true)
    }
}
