import AppKit
import Darwin
import os

let spikeSocket = "bosun-spike"
/// macos/spike, derived from this source file's location at compile time.
let spikeDir: String = {
    if let d = ProcessInfo.processInfo.environment["BOSUN_SPIKE_DIR"] { return d }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
}()
let resultsDir = spikeDir + "/results"

let signposter = OSSignposter(subsystem: "dev.yetidevworks.bosun-spike", category: .pointsOfInterest)

enum Tmux {
    /// Run `tmux -L bosun-spike <args>` synchronously. Never touches any other socket.
    @discardableResult
    static func run(_ args: [String]) -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        p.arguments = ["-L", spikeSocket] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("spawn failed: \(error)", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
    }

    static let tmuxPath: String = {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/env"
    }()

    static func sessions() -> [String] {
        run(["list-sessions", "-F", "#{session_name}"]).out
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("bosun-spike-") }
            .sorted { a, b in
                let ia = Int(a.split(separator: "-").last ?? "") ?? 0
                let ib = Int(b.split(separator: "-").last ?? "") ?? 0
                return ia < ib
            }
    }

    static func windowSize(_ session: String) -> String {
        run(["display", "-p", "-t", "=\(session):", "#{window_width}x#{window_height}"]).out
    }

    static func clients(_ session: String? = nil) -> String {
        var args = ["list-clients", "-F", "#{client_tty} pid=#{client_pid} #{client_width}x#{client_height} session=#{session_name} flags=#{client_flags} activity=#{client_activity}"]
        if let session { args += ["-t", "=\(session)"] }
        return run(args).out
    }
}

/// Process-wide physical footprint (what Activity Monitor / `footprint` report).
func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
}

/// Total user+system CPU seconds consumed by this process so far.
func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let idx = min(s.count - 1, max(0, Int((p / 100.0 * Double(s.count)).rounded(.up)) - 1))
    return s[idx]
}

func fmtMs(_ s: Double) -> String { String(format: "%.2f ms", s * 1000) }

/// Collects report lines, echoes to stdout, writes to a results file.
final class Report {
    private(set) var lines: [String] = []
    let path: String
    init(_ name: String) { path = resultsDir + "/" + name }
    func say(_ s: String) {
        lines.append(s)
        print(s)
        fflush(stdout)
    }
    func save() {
        try? FileManager.default.createDirectory(atPath: resultsDir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@MainActor
func sleepMs(_ ms: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
}
