import AppKit
import GhosttyKit

// libghostty reads its themes and terminfo from GHOSTTY_RESOURCES_DIR, and an inherited value
// (launched from a Ghostty terminal) would win over this app's own bundle in release builds.
if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path {
    setenv("GHOSTTY_RESOURCES_DIR", res, 1)
}
// Don't leak the launching terminal's tmux identity into the tmux clients the app starts.
unsetenv("TMUX")
unsetenv("TMUX_PANE")

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    FileHandle.standardError.write(Data("ghostty_init failed\n".utf8))
    exit(1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
