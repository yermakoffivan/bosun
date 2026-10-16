import AppKit
import QuartzCore

/// An external, non-app tmux client (Moshi / TUI stand-in) driven over a FIFO.
final class ExternalClient {
    let fifo: String
    let proc = Process()
    init(session: String, cols: Int, rows: Int) {
        fifo = NSTemporaryDirectory() + "bosun-spike-ext-\(getpid()).fifo"
        unlink(fifo)
        mkfifo(fifo, 0o600)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", spikeDir + "/tools/pty_client.py", session, "\(cols)", "\(rows)", "600", "--ctl", fifo]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env
        try? proc.run()
    }
    func send(_ cmd: String) {
        let fd = open(fifo, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        let line = cmd + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
    func stop() {
        send("quit")
        proc.waitUntilExit()
        unlink(fifo)
    }
}

@MainActor
final class Q1Test {
    let ws: Workspace
    let window: NSWindow
    let r = Report("q1-app.txt")
    let S = "bosun-spike-6"
    let T = "bosun-spike-1"

    init(ws: Workspace, window: NSWindow) {
        self.ws = ws
        self.window = window
    }

    func state(_ label: String) {
        let v = ws.view(for: S)
        let grid = v.map { "\($0.gridSize.cols)x\($0.gridSize.rows)" } ?? "-"
        let hidden = v.map { $0.isHidden ? "hidden" : "shown" } ?? "-"
        r.say("[\(label)]")
        r.say("    \(S) window=\(Tmux.windowSize(S))   app view grid=\(grid) (\(hidden), tty \(v?.ttyName ?? "-"))")
        for line in Tmux.clients(S).split(separator: "\n") { r.say("    client: \(line)") }
    }

    func settle() async { await sleepMs(600) }

    func run() async {
        Tmux.run(["set", "-g", "focus-events", "off"])
        r.say("# Q1: hidden-client sizing, app views + an external client, window-size latest  \(Date())")
        r.say("tmux \(Tmux.run(["-V"]).out); window-size(\(S))=\(Tmux.run(["show", "-v", "-t", "=\(S):", "window-size"]).out); focus-events=\(Tmux.run(["show", "-gv", "focus-events"]).out)")
        ws.poolCapacity = 4
        ws.ignoreSizeOnHide = false

        // ---- Mapping a view to its tmux client.
        r.say("")
        r.say("## Mapping a view to its tmux client")
        ws.show(S, inTile: 0)
        await sleepMs(1500)
        if let v = ws.view(for: S) {
            let tty = v.ttyName ?? "nil"
            let fg = v.foregroundPID
            r.say("ghostty_surface_tty_name = \(tty)")
            r.say("ghostty_surface_foreground_pid = \(fg)")
            let fmt = "#{client_tty} #{client_pid}"
            let rows = Tmux.run(["list-clients", "-t", "=\(S)", "-F", fmt]).out
            r.say("list-clients -t =\(S) -F '\(fmt)':")
            for l in rows.split(separator: "\n") { r.say("    \(l)") }
            let ttyMatch = rows.split(separator: "\n").contains { $0.hasPrefix(tty + " ") }
            let pidMatch = rows.split(separator: "\n").contains { $0.hasSuffix(" \(fg)") }
            r.say("tty_name matches a client_tty: \(ttyMatch)   foreground_pid matches client_pid: \(pidMatch)")
            r.say("display -p -c \(tty) '#{client_pid} #{session_name}' -> \(Tmux.run(["display", "-p", "-c", tty, "#{client_pid} #{session_name}"]).out)")
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            let clientPid = Tmux.run(["display", "-p", "-c", tty, "#{client_pid}"]).out
            ps.arguments = ["-o", "pid,ppid,pgid,tty,command", "-p", "\(fg)", "-p", clientPid]
            let pipe = Pipe()
            ps.standardOutput = pipe
            try? ps.run()
            ps.waitUntilExit()
            r.say("processes (ghostty foreground pid, tmux client_pid):")
            for l in String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") { r.say("    \(l)") }
        }

        // ---- Phase A: no ignore-size toggling.
        r.say("")
        r.say("## A. Plain window-size latest, no ignore-size toggling")
        state("A1 \(S) shown in the single tile (sole client)")
        ws.show(T, inTile: 0)
        await settle()
        state("A2 \(S) hidden in the warm pool (still sole client)")
        let ext = ExternalClient(session: S, cols: 100, rows: 30)
        await sleepMs(1200)
        state("A3 external 100x30 client attached to \(S) (attach makes it latest)")
        ws.show(S, inTile: 0)
        await settle()
        state("A4 \(S) shown again in the app (no input yet)")
        ws.view(for: S)?.sendRaw("\\x1b[I")
        await settle()
        state("A5 app view wrote a focus-in report (ESC[I) to its tmux client (text: binding action)")
        ext.send("type")
        await settle()
        state("A6 external client typed (it is latest now) while \(S) is shown in the app")
        ws.show(T, inTile: 0)
        ws.view(for: S)?.sendRaw("\\x1b[I")  // hidden view: what if a hidden client is the latest?
        await settle()
        state("A7 \(S) hidden; hidden app client then became latest (wrote ESC[I) - the external client now sees the app's size")

        // ---- Phase B: ignore-size on hide, cleared on show.
        r.say("")
        r.say("## B. ignore-size on hide / cleared on show")
        ws.ignoreSizeOnHide = true
        ws.show(S, inTile: 0)
        ws.view(for: S)?.sendRaw("\\x1b[I")
        await settle()
        state("B1 \(S) shown (cleared ignore-size) and app client made latest")
        ws.show(T, inTile: 0)
        await settle()
        state("B2 \(S) hidden -> refresh-client -f ignore-size on the app client")
        ext.send("type")
        await settle()
        state("B3 external client typed while app view hidden")
        ws.view(for: S)?.sendRaw("\\x1b[I")
        await settle()
        state("B4 hidden+ignore-size app client wrote input (becomes latest by activity) - still ignored?")
        ws.setMode(.split)
        ws.show(T, inTile: 0)
        ws.show(S, inTile: 1)
        await settle()
        state("B5 \(S) shown into the right half tile (different size): ignore-size cleared + view resized, no input")
        ext.send("type")
        await settle()
        state("B6 external client typed while \(S) is shown in the app")
        ws.view(for: S)?.sendRaw("\\x1b[I")
        await settle()
        state("B7 app view sends focus-in report (what a focus event would send with focus-events on)")
        ws.setMode(.single)
        ws.show(T, inTile: 0)
        await settle()
        state("B8 \(S) hidden again (ignore-size)")
        ext.send("size 160 45")
        await settle()
        state("B9 external client resized to 160x45 while app view hidden")
        ext.stop()
        await settle()
        state("B10 external client detached; hidden ignore-size app client is the sole client")
        window.setContentSize(NSSize(width: window.contentView!.bounds.width - 200, height: window.contentView!.bounds.height - 100))
        await settle()
        state("B11 app window resized while \(S) hidden (hidden views keep their frame)")
        ws.show(S, inTile: 0)
        await settle()
        state("B12 \(S) shown in the (smaller) single tile: ignore-size cleared + resize")

        // ---- Phase C: focus-events on: does Ghostty's own focus report (on set_focus) make the client latest?
        r.say("")
        r.say("## C. focus-events on: Ghostty emits ESC[I itself on ghostty_surface_set_focus(true)")
        Tmux.run(["set", "-g", "focus-events", "on"])
        ws.evict(T)
        ws.show(T, inTile: 0)   // T's attach happens with focus-events on
        await sleepMs(1000)
        ws.show(S, inTile: 0)
        await settle()
        // S was attached before focus-events was turned on: reattach so tmux enables focus reporting on the client.
        ws.show(T, inTile: 0)
        ws.evict(S)
        ws.show(S, inTile: 0)
        await sleepMs(1200)
        let ext2 = ExternalClient(session: S, cols: 100, rows: 30)
        await sleepMs(1200)
        state("C1 fresh app view of \(S) (attached with focus-events on) + external 100x30 client attached after it")
        ws.view(for: S)?.setTerminalFocus(false)
        await sleepMs(100)
        ws.view(for: S)?.setTerminalFocus(true)
        await settle()
        state("C2 ghostty_surface_set_focus(false) then (true) on the app view")
        ext2.stop()
        Tmux.run(["set", "-g", "focus-events", "off"])
        r.save()
        r.say("saved \(r.path)")
    }

    func ppidOf(_ pid: Int) -> Int {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return Int(info.kp_eproc.e_ppid)
    }
}

@MainActor
final class MemTest {
    let ws: Workspace
    init(ws: Workspace) { self.ws = ws }

    func run(label: String) async {
        let r = Report("memtest-\(label).txt")
        r.say("# Memory per attached view (\(label)); scrollback-limit=\(GhosttyRuntime.shared.configUInt("scrollback-limit").map { String($0) } ?? "?")")
        ws.poolCapacity = 10
        await sleepMs(2000)
        let base = physFootprintMB()
        r.say(String(format: "baseline (window + sidebar, no views): %.1f MB", base))
        var prev = base
        var deltas: [Double] = []
        for s in ws.model.sessions {
            ws.show(s, inTile: 0)   // previous view stays attached, hidden + occluded
            await sleepMs(2500)
            let now = physFootprintMB()
            deltas.append(now - prev)
            let g = ws.view(for: s)?.gridSize
            r.say(String(format: "+ %@ (grid %dx%d)  footprint %.1f MB  delta %+.1f MB", s, g?.cols ?? 0, g?.rows ?? 0, now, now - prev))
            prev = now
        }
        let total = prev - base
        r.say(String(format: "views attached: %d  total %.1f MB  mean per view %.1f MB  (first view %.1f MB includes one-time renderer/font setup)",
                     deltas.count, total, total / Double(max(1, deltas.count)), deltas.first ?? 0))
        if deltas.count > 1 {
            let rest = deltas.dropFirst()
            r.say(String(format: "mean per additional view (excluding first): %.1f MB", rest.reduce(0, +) / Double(rest.count)))
        }
        r.save()
    }
}

@MainActor
final class IdleTest {
    let ws: Workspace
    init(ws: Workspace) { self.ws = ws }

    func phase(_ r: Report, _ label: String, seconds: Double) async {
        let views = ws.model.sessions.compactMap { ws.view(for: $0) }
        let frames0 = views.map { $0.contentsCount }
        let c0 = cpuSeconds(), t0 = CACurrentMediaTime()
        await sleepMs(seconds * 1000)
        let c1 = cpuSeconds(), t1 = CACurrentMediaTime()
        r.say(String(format: "%@: app CPU %.3f%% of one core over %.0f s (getrusage user+sys %.3f s)", label, (c1 - c0) / (t1 - t0) * 100, t1 - t0, c1 - c0))
        for (i, v) in views.enumerated() {
            r.say(String(format: "    %@ %@ frames committed: %d", v.session, v.isHidden ? "(hidden)" : "(shown) ", v.contentsCount - frames0[i]))
        }
    }

    func run(seconds: Double, sessions: [String]) async {
        let r = Report("idle.txt")
        let ss = sessions.count >= 4 ? sessions : Array(ws.model.sessions.prefix(4))
        r.say("# Idle CPU, 4 views attached (2 shown in split tiles, 2 hidden in the pool): \(ss.joined(separator: ", "))")
        ws.show(ss[2], inTile: 0)
        await sleepMs(500)
        ws.show(ss[3], inTile: 0)
        await sleepMs(500)
        ws.setMode(.split)
        ws.show(ss[0], inTile: 0)
        ws.show(ss[1], inTile: 1)
        await sleepMs(5000)
        print("IDLE-START pid \(getpid())")
        fflush(stdout)
        await phase(r, "A. focused tile (cursor blink on)", seconds: seconds / 2)
        ws.area.window?.makeFirstResponder(nil)
        for v in ws.visibleViews() { v.setTerminalFocus(false) }
        await phase(r, "B. no focused terminal", seconds: seconds / 2)
        r.say(String(format: "footprint: %.1f MB", physFootprintMB()))
        r.save()
    }
}
