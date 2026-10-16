import AppKit
import BosunCore
import Darwin
import os

let appSubsystem = "dev.yetidevworks.bosun-mac"
let signposter = OSSignposter(subsystem: appSubsystem, category: .pointsOfInterest)
let log = Logger(subsystem: appSubsystem, category: "app")

/// BOSUN_DEBUG_KEYS=1 logs every key routing decision to stdout.
let debugKeys = ProcessInfo.processInfo.environment["BOSUN_DEBUG_KEYS"] != nil

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
        d.register(defaults: ["focusFollowsMouse": true, "matchTerminalTheme": false, "poolSize": 8, "sidebarWidth": 248.0])
    }

    var focusFollowsMouse: Bool {
        get { d.bool(forKey: "focusFollowsMouse") }
        set { d.set(newValue, forKey: "focusFollowsMouse"); changed() }
    }

    var matchTerminalTheme: Bool {
        get { d.bool(forKey: "matchTerminalTheme") }
        set { d.set(newValue, forKey: "matchTerminalTheme"); changed() }
    }

    var poolSize: Int {
        get { max(2, min(16, d.integer(forKey: "poolSize"))) }
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
