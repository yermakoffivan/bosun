import AppKit
import BosunCore

/// The warm pool (design section 5): an LRU of attached terminal views keyed by session.
/// Showing a pooled session is a view swap. Hidden views are occluded (their renderer stops,
/// their pty keeps draining) and marked `ignore-size` so they never size a session.
@MainActor
final class TerminalPool {
    private(set) var views: [String: TerminalView] = [:]
    /// Least recently used first.
    private(set) var lru: [String] = []
    var capacity: Int
    weak var container: NSView?
    let daemon: DaemonClient
    /// tmux `-L` socket name terminals attach with (nil: tmux's default socket).
    var tmuxSocket: String?
    var onExit: ((String) -> Void)?
    /// Views whose client currently has tmux's ignore-size flag set.
    private var ignoringSize: Set<String> = []

    init(daemon: DaemonClient, capacity: Int) {
        self.daemon = daemon
        self.capacity = capacity
    }

    func view(for session: String) -> TerminalView? { views[session] }
    func isWarm(_ session: String) -> Bool { views[session].map { !$0.exited } ?? false }

    func attachCommand(for session: String) -> String {
        var parts: [String] = []
        // tmux knows the app's clients by this terminal type: it hides Bosun's TUI key hints and,
        // when only the app shows a session, its status line (docs/protocol.md, "Terminal clients").
        if let terminfo = Paths.appTerminfo {
            parts += ["/usr/bin/env", "TERM=\(Paths.appTerm)", ShellEscape.quote("TERMINFO=\(terminfo)")]
        }
        parts.append(ShellEscape.quote(Paths.tmux))
        if let s = tmuxSocket { parts += ["-L", ShellEscape.quote(s)] }
        parts += ["attach", "-t", ShellEscape.quote("=\(session)")]
        return parts.joined(separator: " ")
    }

    /// A view for `session`, creating (cold attach) if needed. Returns whether it was warm.
    func acquire(_ session: String, frame: NSRect, hidden: Bool) -> (TerminalView, warm: Bool) {
        if let v = views[session], !v.exited {
            touch(session)
            return (v, true)
        }
        if let dead = views.removeValue(forKey: session) { dead.destroy() }
        let v = TerminalView(session: session, command: attachCommand(for: session), frame: frame)
        v.isHidden = hidden
        if hidden { v.setRendererVisible(false) }
        v.onExit = { [weak self] view in
            guard let self, self.views[view.session] === view else { return }
            self.onExit?(view.session)
        }
        container?.addSubview(v, positioned: .below, relativeTo: nil)
        v.frame = frame
        views[session] = v
        touch(session)
        if hidden { setIgnoreSize(session, true) }
        return (v, false)
    }

    /// Make a pooled view visible: renderer on, sizing back to it, and tmux's latest client for its session.
    func reveal(_ session: String, wasWarm: Bool) {
        guard let v = views[session] else { return }
        v.isHidden = false
        v.setRendererVisible(true)
        if wasWarm {
            setIgnoreSize(session, false)
            withTTY(v) { [daemon] tty in daemon.command(.makeLatest(tty: tty)) }
            repin(session)
        }
    }

    /// tmux can move a client to another session behind the app's back (Bosun's `C-b 1-9` and
    /// `switch-client` bindings typed inside a terminal). Put it back when its view is shown.
    func repin(_ session: String) {
        guard let v = views[session], let tty = v.ttyName else { return }
        let socket = tmuxSocket
        DispatchQueue.global(qos: .userInitiated).async {
            let args = (socket.map { ["-L", $0] } ?? []) + ["list-clients", "-F", "#{client_tty} #{session_name}"]
            let out = ShellEnv.run(Paths.tmux, args, timeout: 1) ?? ""
            guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix(tty + " ") }) else { return }
            let on = String(line.dropFirst(tty.count + 1))
            guard !on.isEmpty, on != session else { return }
            log.info("client \(tty, privacy: .public) was on \(on, privacy: .public); moving it back to \(session, privacy: .public)")
            TmuxCLI.run(socket: socket, ["switch-client", "-c", tty, "-t", "=\(session)"])
        }
    }

    /// The pooled view whose tmux client is on terminal `tty`, if it's one of ours and still running.
    func view(onTTY tty: String) -> TerminalView? {
        views.values.first { !$0.exited && !$0.detaching && $0.ttyName == tty }
    }

    /// The view for `old` now shows `new` (its tmux client was moved there inside the terminal):
    /// key it by `new`, and detach any other view of `new`, since a session has one view.
    func rekey(_ old: String, to new: String) {
        guard old != new, let v = views.removeValue(forKey: old) else { return }
        if let other = views.removeValue(forKey: new) {
            lru.removeAll { $0 == new }
            ignoringSize.remove(new)
            other.detachThenFree(socket: tmuxSocket)
        }
        v.session = new
        views[new] = v
        lru = lru.map { $0 == old ? new : $0 }
        if ignoringSize.remove(old) != nil { ignoringSize.insert(new) }
    }

    /// Put the tmux client on `tty` back on `session`.
    func moveClient(_ tty: String, to session: String) {
        let socket = tmuxSocket
        DispatchQueue.global(qos: .userInitiated).async {
            TmuxCLI.run(socket: socket, ["switch-client", "-c", tty, "-t", "=\(session)"])
        }
    }

    func hide(_ session: String) {
        guard let v = views[session] else { return }
        v.isHidden = true
        v.setRendererVisible(false)
        v.setTerminalFocus(false)
        setIgnoreSize(session, true)
    }

    /// Start attaching a session in the background so a later switch is warm.
    func prewarm(_ session: String, size: NSSize) {
        guard views[session] == nil || views[session]?.exited == true else { return }
        let state = signposter.beginInterval("Prewarm", id: signposter.makeSignpostID(), "\(session, privacy: .public)")
        _ = acquire(session, frame: NSRect(origin: .zero, size: size), hidden: true)
        signposter.endInterval("Prewarm", state)
    }

    func touch(_ session: String) {
        lru.removeAll { $0 == session }
        lru.append(session)
    }

    /// Detach least recently used hidden views beyond capacity. Visible views are never evicted.
    func evict(keeping visible: Set<String>) {
        while views.count > capacity, let victim = lru.first(where: { !visible.contains($0) && views[$0] != nil }) {
            drop(victim)
        }
    }

    /// Detach and free one view (off the main thread for the slow part).
    func drop(_ session: String) {
        guard let v = views.removeValue(forKey: session) else { return }
        lru.removeAll { $0 == session }
        ignoringSize.remove(session)
        v.detachThenFree(socket: tmuxSocket)
    }

    func dropAll() {
        for s in Array(views.keys) { drop(s) }
    }

    private func setIgnoreSize(_ session: String, _ on: Bool) {
        guard let v = views[session], ignoringSize.contains(session) != on else { return }
        if on { ignoringSize.insert(session) } else { ignoringSize.remove(session) }
        withTTY(v) { [weak self] tty in self?.sendFlags(session, tty: tty, on: on, attempts: 10) }
    }

    /// A client that is still attaching isn't known to tmux yet, so a refused flag is retried briefly.
    private func sendFlags(_ session: String, tty: String, on: Bool, attempts: Int) {
        daemon.command(.clientFlags(tty: tty, ignoreSize: on)) { [weak self] ack in
            guard let self, !ack.ok, attempts > 0, self.ignoringSize.contains(session) == on,
                  let v = self.views[session], !v.exited, ack.error != "not connected to bosun serve" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { self.sendFlags(session, tty: tty, on: on, attempts: attempts - 1) }
            }
        }
    }

    /// Run `body` once the view's pty exists (immediately for a live view, a few ms after a cold one).
    private func withTTY(_ v: TerminalView, attempts: Int = 100, _ body: @escaping (String) -> Void) {
        if let tty = v.ttyName { body(tty); return }
        guard attempts > 0, !v.exited else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak v] in
            MainActor.assumeIsolated {
                guard let v else { return }
                self.withTTY(v, attempts: attempts - 1, body)
            }
        }
    }
}
