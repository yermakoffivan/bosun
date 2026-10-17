import AppKit
import BosunCore
import Darwin
import os

let appSubsystem = "dev.yetidevworks.bosun-mac"
let signposter = OSSignposter(subsystem: appSubsystem, category: .pointsOfInterest)
let log = Logger(subsystem: appSubsystem, category: "app")

/// BOSUN_DEBUG_KEYS=1 logs every key routing decision to stdout.
let debugKeys = ProcessInfo.processInfo.environment["BOSUN_DEBUG_KEYS"] != nil
/// BOSUN_DEBUG_FRAMES=1 logs every frame a terminal draws, and every focus and occlusion change it's given, to stdout.
let debugFrames = ProcessInfo.processInfo.environment["BOSUN_DEBUG_FRAMES"] != nil
/// A scripted test mode (--focustest, --selftest, --launchprobe) is running.
let testMode = CommandLine.arguments.contains { ["--focustest", "--selftest", "--launchprobe"].contains($0) }
/// A staged run for screenshots (`dev.sh demo`): the status line has no "dev" tag and notifications go to
/// the recorder, so the demo sessions never post for real.
let demoMode = ProcessInfo.processInfo.environment["BOSUN_DEMO"] != nil
/// --no-activate: open the window without activating the app, so a test run never takes the keyboard from whatever you're using.
let noActivate = CommandLine.arguments.contains("--no-activate")

enum Env {
    static func value(_ key: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }
        return v
    }
}

enum Paths {
    static var fm: FileManager { .default }
    static var home: String { NSHomeDirectory() }

    /// `bosun` to run: BOSUN_BIN, else the usual install locations.
    static func bosunBinary() -> String? {
        if let b = Env.value("BOSUN_BIN") { return fm.isExecutableFile(atPath: b) ? b : nil }
        for p in ["\(home)/.local/bin/bosun", "/opt/homebrew/bin/bosun", "/usr/local/bin/bosun"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// tmux, by absolute path: an app started from Finder has no Homebrew directory on its PATH.
    static let tmux: String = {
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        if let path = Env.value("PATH") {
            candidates += path.split(separator: ":").map { "\($0)/tmux" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "tmux"
    }()

    /// The terminal type the app's tmux clients attach with: Ghostty's `xterm-ghostty` entry under
    /// a name of its own (the bundle's post-build step makes the copy). Matches `APP_CLIENT_TERM`
    /// in the daemon's status_bar.rs.
    static let appTerm = "xterm-ghostty-bosun"

    /// The bundle's terminfo directory, when it has the `appTerm` entry (nil: attach as plain xterm-ghostty).
    static let appTerminfo: String? = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("terminfo").path else { return nil }
        return fm.fileExists(atPath: "\(dir)/78/\(appTerm)") ? dir : nil
    }()

    /// The daemon's default socket (protocol.md): Bosun's data directory on macOS.
    static var defaultSocket: String {
        "\(home)/Library/Application Support/dev.yetidevworks.bosun/bosun.sock"
    }

    static var cacheDir: URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "\(home)/Library/Caches")
        let dir = base.appendingPathComponent(appSubsystem, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var supportDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "\(home)/Library/Application Support")
        let dir = base.appendingPathComponent(appSubsystem, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A short stable key for a socket path, so state for a test daemon never mixes with the real one.
    static func key(for socket: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in socket.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }
}

/// PATH for processes the app starts (the daemon): the login shell's PATH when it can be read quickly,
/// so tmux and the agents resolve the same way they do in a terminal.
enum ShellEnv {
    nonisolated(unsafe) private static var cached: String?
    private static let lock = NSLock()

    static func path() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var result = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = Env.value("SHELL") ?? "/bin/zsh"
        if let login = run(shell, ["-l", "-c", "printf %s \"$PATH\""], timeout: 2), !login.isEmpty {
            result = login
        }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "\(Paths.home)/.local/bin"] where !result.split(separator: ":").contains(Substring(extra)) {
            result += ":\(extra)"
        }
        cached = result
        return result
    }

    /// Run a program and return its stdout, or nil on failure or timeout.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval, env: [String: String]? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning {
            p.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// tmux commands the app runs itself (detaching an evicted client). Always against the daemon's socket.
enum TmuxCLI {
    static func run(socket: String?, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.tmux)
        p.arguments = (socket.map { ["-L", $0] } ?? []) + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
    }
}

/// App preferences (not Bosun settings, which live in config.toml via the daemon).
@MainActor
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard
    var onChange: [() -> Void] = []

    private init() {
        d.register(defaults: ["focusFollowsMouse": true, "matchTerminalTheme": TerminalSync.defaultOn, "poolSize": AppSettings.defaultPoolSize, "sidebarWidth": 248.0,
                              Key.notifyWhenWaiting: true, Key.notifyWhenDone: true, Key.showDockBadge: true])
    }

    enum Key {
        static let notifyWhenWaiting = "notifyWhenWaiting"
        static let notifyWhenDone = "notifyWhenDone"
        static let showDockBadge = "showDockBadge"
        static let matchTerminalTheme = "matchTerminalTheme"
        static let terminalSyncNoted = "terminalSyncNoted"
    }

    /// The test modes share the installed app's defaults (same bundle id), so their changes to these stay in memory.
    private var testFlags: [String: Bool] = [:]

    private func flag(_ key: String) -> Bool { testMode ? testFlags[key] ?? true : d.bool(forKey: key) }

    private func setFlag(_ key: String, _ v: Bool) {
        if testMode { testFlags[key] = v } else { d.set(v, forKey: key) }
        changed()
    }

    /// A macOS notification when an agent you can't see starts waiting on you.
    var notifyWhenWaiting: Bool {
        get { flag(Key.notifyWhenWaiting) }
        set { setFlag(Key.notifyWhenWaiting, newValue) }
    }

    /// A macOS notification when an agent you can't see finishes its turn (from its hook).
    var notifyWhenDone: Bool {
        get { flag(Key.notifyWhenDone) }
        set { setFlag(Key.notifyWhenDone, newValue) }
    }

    /// The number of sessions waiting on you, on the Dock icon.
    var showDockBadge: Bool {
        get { flag(Key.showDockBadge) }
        set { setFlag(Key.showDockBadge, newValue) }
    }

    var focusFollowsMouse: Bool {
        get { d.bool(forKey: "focusFollowsMouse") }
        set { d.set(newValue, forKey: "focusFollowsMouse"); changed() }
    }

    /// Terminals follow the Bosun theme (on by default, for existing installs too); off means "use my Ghostty
    /// config". In the test modes it stays in memory and starts off, so the sections that read the terminals'
    /// colours see the user's Ghostty theme.
    var matchTerminalTheme: Bool {
        get { testMode ? testFlags[Key.matchTerminalTheme] ?? false : d.bool(forKey: Key.matchTerminalTheme) }
        set {
            if testMode { testFlags[Key.matchTerminalTheme] = newValue } else { d.set(newValue, forKey: Key.matchTerminalTheme) }
            changed()
        }
    }

    /// Run once at launch, before the theme is applied: the first launch with terminal sync switches it on
    /// (see `TerminalSync.migrate`). True when the caller should show `TerminalSync.note`.
    func migrateTerminalSync() -> Bool {
        guard !testMode else { return false }
        let domain = Bundle.main.bundleIdentifier.flatMap { d.persistentDomain(forName: $0) } ?? [:]
        let stored = domain[Key.matchTerminalTheme] as? Bool
        let migrated = domain[Key.terminalSyncNoted] as? Bool ?? false
        let existing = !domain.keys.filter { $0 != Key.terminalSyncNoted }.isEmpty
        let m = TerminalSync.migrate(stored: stored, alreadyMigrated: migrated, existingInstall: existing)
        if !migrated { d.set(true, forKey: Key.terminalSyncNoted) }
        if m.turnOn { d.set(true, forKey: Key.matchTerminalTheme) }
        return m.note
    }

    /// Terminal views kept attached, visible ones included. 12 holds the shown row and two or three
    /// more rows of three panes (about 13–14 MB a view, so roughly 170 MB when full).
    nonisolated static let defaultPoolSize = 12
    nonisolated static let poolSizeRange = 4...27

    var poolSize: Int {
        get { max(AppSettings.poolSizeRange.lowerBound, min(AppSettings.poolSizeRange.upperBound, d.integer(forKey: "poolSize"))) }
        set { d.set(newValue, forKey: "poolSize"); changed() }
    }

    var sidebarWidth: CGFloat {
        get { CGFloat(d.double(forKey: "sidebarWidth")) }
        set { d.set(Double(newValue), forKey: "sidebarWidth") }
    }

    private func changed() { onChange.forEach { $0() } }
}

/// When the process started, for the launch measurements.
enum ProcessClock {
    static let start: Date = {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, 4, &kp, &size, nil, 0) == 0 {
            let tv = kp.kp_proc.p_un.__p_starttime
            return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
        }
        return Date()
    }()

    static func sinceLaunch() -> Double { Date().timeIntervalSince(start) }
}

func fmtMs(_ s: Double) -> String { String(format: "%.1f ms", s * 1000) }
