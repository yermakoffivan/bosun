import AppKit
import BosunCore

/// What the links section saw opened (LinkOpener's test recorder): nothing is ever really opened.
@MainActor
final class OpenedLinks {
    var targets: [LinkTarget] = []
}

extension FocusTest {
    /// Cmd+click on a URL, an absolute path and a relative path with `:line`, printed by a plain
    /// shell inside tmux (which has the mouse). Events go through the app's own queue: Cmd down,
    /// the pointer over the text with Cmd held, then a click with Cmd held.
    func links() async {
        r.say("")
        r.say("## Cmd+click on links")
        let opened = OpenedLinks()
        LinkOpener.recorder = { opened.targets.append($0) }
        defer { LinkOpener.recorder = nil }
        guard let shell = session("shell"), await waitShell(shell) else {
            r.check("the fixture's plain shell row is at its prompt", false)
            return
        }
        await showRow(shell)
        let dir = "/tmp/bosun-links-\(getpid())"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        fm.createFile(atPath: dir + "/abs.txt", contents: Data("abs\n".utf8))
        fm.createFile(atPath: dir + "/src/app.rs", contents: Data("fn main() {}\n".utf8))
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let url = "https://example.com/bosun-link-test", abs = dir + "/abs.txt", rel = "src/app.rs:42", missing = "src/missing.rs:7"
        tmux(["send-keys", "-t", "=\(shell):", "-l", "cd \(dir) && clear && printf '%s\\n' '\(url)' '\(abs)' '\(rel)' '\(missing)'"])
        tmux(["send-keys", "-t", "=\(shell):", "Enter"])
        guard let v = ws.activeTerminal, await waitUntil(4, { v.viewportText().contains(missing) && !v.viewportText().contains("printf") }) else {
            r.check("the shell printed the links", false, ws.activeTerminal?.viewportText().prefix(300).description ?? "no terminal")
            return
        }
        await sleep(200)
        let cursor = tmuxOut(["display", "-p", "-t", "=\(shell):", "#{cursor_x} #{cursor_y}"])
            .split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        /// The middle of `text` on screen, in window coordinates.
        func point(_ text: String) -> NSPoint? {
            let lines = v.viewportText().components(separatedBy: "\n")
            guard cursor.count == 2, let row = lines.firstIndex(where: { $0.contains(text) }),
                  let range = lines[row].range(of: text) else { return nil }
            let col = lines[row].distance(from: lines[row].startIndex, to: range.lowerBound) + text.count / 2
            return v.cellCenter(col: col, row: row, cursorCol: cursor[0], cursorRow: cursor[1]).map { v.convert($0, to: nil) }
        }

        func flags(_ mods: NSEvent.ModifierFlags) async {
            if let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: 0x37) {
                NSApp.postEvent(e, atStart: false)
            }
            await sleep(60)
        }

        /// Cmd+click `text`; `cmdFirst` presses Cmd with the pointer already there (no move with it held).
        func cmdClick(_ text: String, cmdFirst: Bool = false) async -> (hand: Bool, opened: [LinkTarget], inMode: Bool) {
            guard let p = point(text) else { return (false, [], false) }
            let before = opened.targets.count
            // Start from no hover: Cmd up, the pointer off the text.
            if let e = mouse(.mouseMoved, NSPoint(x: p.x, y: p.y - 400)) { NSApp.postEvent(e, atStart: false) }
            await sleep(80)
            if v.mouseCursor == .pointingHand { return (false, [], false) }
            if cmdFirst {
                if let e = mouse(.mouseMoved, p) { NSApp.postEvent(e, atStart: false) }
                await sleep(80)
                await flags(.command)
            } else {
                await flags(.command)
                if let e = mouse(.mouseMoved, p, mods: .command) { NSApp.postEvent(e, atStart: false) }
            }
            await waitUntil(1) { v.mouseCursor == .pointingHand }
            let hand = v.mouseCursor == .pointingHand
            if text == url { shot("14-link-hover") }
            if let d = mouse(.leftMouseDown, p, mods: .command), let u = mouse(.leftMouseUp, p, mods: .command) {
                NSApp.postEvent(d, atStart: false)
                NSApp.postEvent(u, atStart: false)
            }
            await waitUntil(1.5) { opened.targets.count > before }
            await sleep(150)
            await flags([])
            let inMode = tmuxOut(["display", "-p", "-t", "=\(shell):", "#{pane_in_mode}"]).hasPrefix("1")
            if inMode { tmux(["send-keys", "-t", "=\(shell):", "-X", "cancel"]) }
            return (hand, Array(opened.targets[before...]), inMode)
        }

        let u = await cmdClick(url)
        r.check("Cmd+hover on a URL shows the hand", u.hand)
        r.check("Cmd+click on a URL opens it", u.opened == [.url(URL(string: url)!)], "\(u.opened)")
        r.check("…and the click never reaches tmux (no copy mode)", !u.inMode)

        let a = await cmdClick(abs, cmdFirst: true)
        r.check("Cmd pressed with the pointer already on an absolute path shows the hand", a.hand)
        r.check("Cmd+click on an absolute path opens the file", a.opened.map { if case .file(let p) = $0 { real(p) } else { "\($0)" } } == [real(abs)],
                "\(a.opened)")

        let rl = await cmdClick(rel)
        r.check("Cmd+click on a relative path with :line opens the file in the shell's directory",
                rl.opened.map { if case .file(let p) = $0 { real(p) } else { "\($0)" } } == [real(dir + "/src/app.rs")], "\(rl.opened)")

        let m = await cmdClick(missing)
        r.check("Cmd+click on a path that doesn't exist opens nothing", m.opened.isEmpty, "\(m.opened)")

        // A plain click on a link is the program's (tmux's), and opens nothing.
        if let p = point(url) {
            let before = opened.targets.count
            await click(p)
            await sleep(300)
            r.check("a click without Cmd opens nothing", opened.targets.count == before)
            if tmuxOut(["display", "-p", "-t", "=\(shell):", "#{pane_in_mode}"]).hasPrefix("1") { tmux(["send-keys", "-t", "=\(shell):", "-X", "cancel"]) }
        }

        // An inactive pane: Cmd+click activates it and opens the link too.
        if let web = session("web"), let webShell = session("web shell"), let webRow = rowID(web) {
            ws.selectRow(webRow, pane: web)
            await waitPanesPainted()
            if await waitShell(webShell), let ts = ws.pool.view(for: webShell) {
                tmux(["send-keys", "-t", "=\(webShell):", "-l", "clear && printf '%s\\n' '\(url)'"])
                tmux(["send-keys", "-t", "=\(webShell):", "Enter"])
                await waitUntil(3) { ts.viewportText().contains(url) && !ts.viewportText().contains("printf") }
                await sleep(200)
                let c = tmuxOut(["display", "-p", "-t", "=\(webShell):", "#{cursor_x} #{cursor_y}"])
                    .split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let lines = ts.viewportText().components(separatedBy: "\n")
                if c.count == 2, let row = lines.firstIndex(where: { $0.contains(url) }), let range = lines[row].range(of: url),
                   let cp = ts.cellCenter(col: lines[row].distance(from: lines[row].startIndex, to: range.lowerBound) + url.count / 2,
                                          row: row, cursorCol: c[0], cursorRow: c[1]) {
                    let p = ts.convert(cp, to: nil)
                    let before = opened.targets.count
                    r.check("(web is the active pane before the click)", ws.activeSession == web)
                    // Click-only, so the pointer moving in doesn't activate the pane first.
                    let follows = app.focus.followsMouse
                    app.focus.followsMouse = false
                    defer { app.focus.followsMouse = follows }
                    await flags(.command)
                    if let e = mouse(.mouseMoved, p, mods: .command) { NSApp.postEvent(e, atStart: false) }
                    await sleep(150)
                    if let d = mouse(.leftMouseDown, p, mods: .command), let up = mouse(.leftMouseUp, p, mods: .command) {
                        NSApp.postEvent(d, atStart: false)
                        NSApp.postEvent(up, atStart: false)
                    }
                    await waitUntil(1.5) { opened.targets.count > before }
                    await flags([])
                    r.check("Cmd+click on a link in an inactive pane opens it", Array(opened.targets[before...]) == [.url(URL(string: url)!)],
                            "\(opened.targets[before...])")
                    r.check("…and activates that pane", ws.activeSession == webShell)
                } else {
                    r.check("found the link in the inactive pane", false)
                }
                tmux(["send-keys", "-t", "=\(webShell):", "-l", "clear"])
                tmux(["send-keys", "-t", "=\(webShell):", "Enter"])
            }
        }

        tmux(["send-keys", "-t", "=\(shell):", "-l", "cd ~ && clear"])
        tmux(["send-keys", "-t", "=\(shell):", "Enter"])
        try? fm.removeItem(atPath: dir)
    }
}
