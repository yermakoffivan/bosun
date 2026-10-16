import AppKit
import GhosttyKit

// Point libghostty at the resources bundled in this app (themes + terminfo). In release builds
// GHOSTTY_RESOURCES_DIR wins over bundle discovery, so an inherited value (e.g. when launched
// from a Ghostty terminal) would otherwise point at Ghostty.app's copy.
if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path {
    setenv("GHOSTTY_RESOURCES_DIR", res, 1)
}
// Don't leak the launching terminal's identity into the tmux clients we spawn.
unsetenv("TMUX")
unsetenv("TMUX_PANE")

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    FileHandle.standardError.write("ghostty_init failed\n".data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
