import AppKit
import QuartzCore
import os

final class FrameBox {
    var first: CFTimeInterval?
    var content: CFTimeInterval?
}

@MainActor
func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
    let end = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < end {
        if cond() { return true }
        await sleepMs(0.5)
    }
    return cond()
}

/// Drives a divider drag from a display link: one layout step per display refresh.
final class DragDriver: NSObject {
    var start: CFTimeInterval = 0
    var duration: CFTimeInterval = 1.0
    var callbackTimes: [CFTimeInterval] = []
    var stepCosts: [CFTimeInterval] = []
    var nominal: CFTimeInterval = 0
    var done = false
    var step: ((Double) -> Void)?
    var link: CADisplayLink?
    var timer: Timer?

    @objc func tick(_ link: CADisplayLink) {
        nominal = link.duration
        advance()
    }

    func advance() {
        let now = CACurrentMediaTime()
        if start == 0 { start = now }
        callbackTimes.append(now)
        let p = min(1.0, (now - start) / duration)
        step?(p)
        stepCosts.append(CACurrentMediaTime() - now)
        if p >= 1.0 {
            done = true
            link?.invalidate()
            timer?.invalidate()
        }
    }
}

@MainActor
final class SelfTest {
    let ws: Workspace
    let window: NSWindow
    let r = Report("selftest.txt")

    init(ws: Workspace, window: NSWindow) {
        self.ws = ws
        self.window = window
    }

    /// Show `s` in tile `t` and time request -> first frame committed to the view's layer
    /// (and -> first frame whose terminal state contains tmux's status line for `s`).
    func timedShow(_ s: String, tile t: Int, label: StaticString) async -> (first: Double?, content: Double?, warm: Bool) {
        let box = FrameBox()
        let marker = "[\(s)]"
        let warm = ws.isWarm(s)
        let state = signposter.beginInterval(label, id: signposter.makeSignpostID(), "\(s, privacy: .public)")
        let t0 = CACurrentMediaTime()
        let (v, _) = ws.show(s, inTile: t, prepare: { v in
            v.onContents = { v in
                let now = CACurrentMediaTime()
                if box.first == nil { box.first = now; signposter.emitEvent("first-frame") }
                if box.content == nil, v.viewportText().contains(marker) { box.content = now }
            }
        })
        _ = await waitUntil(3.0) { box.first != nil && box.content != nil }
        signposter.endInterval(label, state)
        v.onContents = nil
        return (box.first.map { $0 - t0 }, box.content.map { $0 - t0 }, warm)
    }

    func sigwinchCount() -> Int {
        guard let s = try? String(contentsOfFile: resultsDir + "/sigwinch.log", encoding: .utf8) else { return -1 }
        return s.split(separator: "\n").filter { !$0.hasPrefix("#") }.count
    }

    func summarize(_ name: String, _ xs: [Double]) {
        r.say(String(format: "%@: n=%d  p50=%@  p90=%@  p99=%@  min=%@  max=%@", name, xs.count,
                     fmtMs(percentile(xs, 50)), fmtMs(percentile(xs, 90)), fmtMs(percentile(xs, 99)),
                     fmtMs(xs.min() ?? .nan), fmtMs(xs.max() ?? .nan)))
    }

    func run() async {
        let sessions = ws.model.sessions
        r.say("# Bosun spike selftest  \(Date())")
        r.say("display refresh: \(window.screen?.maximumFramesPerSecond ?? 0) Hz max, backing scale \(window.backingScaleFactor)")
        let rt = GhosttyRuntime.shared
        r.say("ghostty config: font-size=\(rt.configDouble("font-size").map { String($0) } ?? "?") background=\(rt.configColor("background") ?? "?") scrollback-limit=\(rt.configUInt("scrollback-limit").map { String($0) } ?? "?") diagnostics=\(rt.diagnostics.count)")
        for d in rt.diagnostics { r.say("  config diagnostic: \(d)") }
        guard sessions.count >= 6 else {
            r.say("ERROR: expected 6 bosun-spike sessions, found \(sessions)")
            r.save()
            return
        }
        ws.poolCapacity = 4
        await sleepMs(300)

        // ---- Warm pool: attach 4 sessions, then 100 swaps among them.
        let warmSet = Array(sessions[0..<4])
        for s in warmSet { _ = await timedShow(s, tile: 0, label: "WarmupAttach"); await sleepMs(150) }
        await sleepMs(500)
        var warmFirst: [Double] = [], warmContent: [Double] = [], misses = 0
        for i in 0..<100 {
            let s = warmSet[(i + 1) % warmSet.count]
            let res = await timedShow(s, tile: 0, label: "WarmSwap")
            if !res.warm { misses += 1 }
            if let f = res.first { warmFirst.append(f) }
            if let c = res.content { warmContent.append(c) }
            await sleepMs(40)
        }
        r.say("")
        r.say("## Warm swaps (single tile, pool of 4: \(warmSet.joined(separator: ", ")))")
        r.say("pool misses (should be 0): \(misses)")
        summarize("warm swap -> first frame committed to layer", warmFirst)
        summarize("warm swap -> frame with session's status line", warmContent)

        // ---- Cold attaches.
        var coldFirst: [Double] = [], coldContent: [Double] = []
        ws.lastFreeDurationsReset()
        var idx = 0
        for _ in 0..<20 {
            var s = sessions[idx % sessions.count]
            idx += 1
            if ws.tiles.contains(s) { s = sessions[idx % sessions.count]; idx += 1 }
            ws.evict(s)
            // Make room up front so eviction (SIGHUP + surface free) is not inside the timed interval.
            ws.evictAllHidden()
            await sleepMs(150)
            let res = await timedShow(s, tile: 0, label: "ColdAttach")
            if let f = res.first { coldFirst.append(f) }
            if let c = res.content { coldContent.append(c) }
            await sleepMs(200)
        }
        r.say("")
        r.say("## Cold attaches (new libghostty view + `tmux attach` spawn)")
        summarize("cold attach -> first frame committed to layer", coldFirst)
        summarize("cold attach -> first frame showing tmux's paint (status line)", coldContent)
        summarize("ghostty_surface_free (detach) on main thread", ws.lastFreeDurations)
        // Same eviction, but detach the tmux client first and free after the child has exited.
        for s in sessions where !ws.tiles.contains(s) { ws.show(s, inTile: 0); await sleepMs(300) }
        for _ in 0..<2 {
            for s in sessions where !ws.tiles.contains(s) && ws.isWarm(s) {
                await ws.evictDetachingFirst(s)
            }
            for s in sessions where !ws.tiles.contains(s) { ws.show(s, inTile: 0); await sleepMs(300) }
        }
        summarize("ghostty_surface_free after `detach-client` + child exit", ws.lastFreeAfterDetachDurations)

        // ---- Divider drag (Q4).
        r.say("")
        r.say("## Divider drag: left tile = bosun-spike-5 (SIGWINCH full-redraw stand-in), right = bosun-spike-3 (ticker)")
        ws.setMode(.split)
        ws.show("bosun-spike-5", inTile: 0)
        ws.show("bosun-spike-3", inTile: 1)
        await sleepMs(800)
        for (n, throttle) in [true, false, true, false].enumerated() {
            await dragRun(n: n + 1, throttle: throttle)
        }
        r.say("")
        r.say("tmux window size of bosun-spike-5 after drags: \(Tmux.windowSize("bosun-spike-5"))  view grid: \(ws.view(for: "bosun-spike-5").map { "\($0.gridSize.cols)x\($0.gridSize.rows)" } ?? "?")")
        r.save()
        r.say("saved \(r.path)")
    }

    func dragRun(n: Int, throttle: Bool) async {
        ws.ratio = 0.5
        ws.layoutTiles()
        ws.view(for: "bosun-spike-5")?.flushGridSize()
        await sleepMs(1000)
        guard let left = ws.view(for: "bosun-spike-5") else { return }
        ws.dragThrottle = throttle ? 0.1 : 0
        let ctl = ControlCounter(session: "bosun-spike-5")
        await sleepMs(300)
        let winBefore = sigwinchCount()
        let framesBefore = left.contentsCount
        let sizeBefore = left.sizeCallsSent
        let colsBefore = left.gridSize.cols
        let d = DragDriver()
        d.duration = 1.0
        let wsRef = ws
        d.step = { p in wsRef.setRatio(0.5 - 0.25 * p) }
        let state = signposter.beginInterval("DividerDrag", id: signposter.makeSignpostID(), "throttle=\(throttle)")
        let link = ws.area.displayLink(target: d, selector: #selector(DragDriver.tick(_:)))
        d.link = link
        link.add(to: .main, forMode: .common)
        // Fallback if the display link doesn't fire (e.g. display asleep): drive at 120 Hz from a timer.
        if !(await waitUntil(0.25) { d.start != 0 }) {
            link.invalidate()
            let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in d.advance() }
            d.timer = t
            RunLoop.main.add(t, forMode: .common)
            r.say("  (display link did not fire; drove the drag from a 120 Hz timer)")
        }
        _ = await waitUntil(3.0) { d.done }
        ws.endDrag()
        signposter.endInterval("DividerDrag", state)
        let dragFrames = left.contentsCount - framesBefore
        await sleepMs(1200)
        let winAfter = sigwinchCount()
        let layoutChanges = ctl.stop()
        var intervals: [Double] = []
        for i in 1..<max(1, d.callbackTimes.count) { intervals.append(d.callbackTimes[i] - d.callbackTimes[i - 1]) }
        let nominal = d.nominal > 0 ? d.nominal : 1.0 / Double(window.screen?.maximumFramesPerSecond ?? 60)
        let late = intervals.filter { $0 > nominal * 1.5 }.count
        r.say(String(format: "drag %d  throttle=%@  steps=%d over %.0f ms  nominal frame=%.2f ms  late intervals(>1.5x)=%d  max interval=%@  step cost p50=%@ p99=%@",
                     n, throttle ? "100ms" : "off", d.callbackTimes.count,
                     ((d.callbackTimes.last ?? 0) - (d.callbackTimes.first ?? 0)) * 1000, nominal * 1000, late,
                     fmtMs(intervals.max() ?? 0), fmtMs(percentile(d.stepCosts, 50)), fmtMs(percentile(d.stepCosts, 99))))
        r.say("        SIGWINCH received by reflow script: \(winAfter - winBefore)   ghostty_surface_set_size calls: \(left.sizeCallsSent - sizeBefore)   tmux %layout-change (window resizes) seen by a control client: \(layoutChanges)   left view frames committed during drag: \(dragFrames)   cols \(colsBefore) -> \(left.gridSize.cols)")
    }
}

extension Workspace {
    func lastFreeDurationsReset() { resetFreeDurations() }
}

/// A size-less control-mode client on a session; counts %layout-change notifications (tmux window resizes).
final class ControlCounter {
    let proc = Process()
    let inPipe = Pipe()
    let outPipe = Pipe()
    private var count = 0
    private let lock = NSLock()
    init(session: String) {
        proc.executableURL = URL(fileURLWithPath: Tmux.tmuxPath)
        proc.arguments = ["-L", spikeSocket, "-C", "attach", "-t", "=\(session)"]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        var partial = ""
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            partial += chunk
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            let n = lines.filter { $0.hasPrefix("%layout-change") }.count
            self.lock.lock(); self.count += n; self.lock.unlock()
        }
        try? proc.run()
    }
    func stop() -> Int {
        try? inPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
