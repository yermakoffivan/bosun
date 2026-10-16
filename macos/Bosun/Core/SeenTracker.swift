import Foundation

/// The per-viewer "done" rule. The daemon reports a finished turn as `idle` and leaves "done" to each client
/// (protocol.md, Statuses). There are two rules, picked by where the session's status came from.
///
/// **Hook statuses** (the agent reports its own state, e.g. Claude Code): done means the agent finished its turn
/// and it's the user's turn. The daemon sends the hook's `done_at` with the idle status, and the session shows done
/// while that is newer than the last time the user gave the session input in this app (typed, pasted or dropped
/// into its terminal). Being on screen doesn't clear it. A new status without `done_at` (the next prompt made it
/// running, a permission prompt opened) ends it, and so does seeing it running, so a stale `done_at` can't bring
/// it back.
///
/// **Detector statuses** (Bosun guesses from the pane): an idle session that ran and changed since this viewer
/// last looked at it shows as done. "Ran" latches when the session is seen running, or reports done through its
/// hook. "Changed" latches on any status change or pane title change while nobody is looking. Both clear when the
/// session is looked at (shown in a tile).
public struct SeenTracker: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var ran = false
        var changed = false
        var lastState: AgentState
        var lastTitle: String?
        /// The status came from the agent's hook.
        var hook = false
        /// The hook's `done_at` on the last status, Unix ms.
        var doneAt: UInt64?
        /// A `done_at` at or before this was followed by a running status, so it no longer counts.
        var ranAfter: UInt64 = 0
    }

    private var entries: [String: Entry] = [:]
    private var viewed: Set<String> = []
    /// The last time the user gave each session input in this app, Unix ms.
    private var lastInput: [String: UInt64] = [:]

    public init() {}

    /// Sessions currently on screen. Anything visible is "seen" continuously (detector rule).
    public mutating func setViewed(_ sessions: Set<String>) {
        viewed = sessions
        for s in sessions { markSeen(s) }
    }

    public mutating func markSeen(_ session: String) {
        guard var e = entries[session] else { return }
        e.ran = false
        e.changed = false
        entries[session] = e
    }

    /// The user typed, pasted or dropped into the session's terminal at `at` (Unix ms).
    public mutating func noteInput(_ session: String, at: UInt64) {
        lastInput[session] = max(lastInput[session] ?? 0, at)
    }

    /// Feed every status and title the client learns about. The first observation is a baseline.
    public mutating func observe(_ session: String, status: StatusInfo?, title: String?) {
        observe(session, state: status?.state ?? .unknown, title: title, hook: status?.isHook ?? false, doneAt: status?.doneAt)
    }

    /// Feed every state and title the client learns about. The first observation is a baseline for the detector
    /// rule; a hook's `doneAt` counts from the first sight.
    public mutating func observe(_ session: String, state: AgentState, title: String?, hook: Bool = false, doneAt: UInt64? = nil) {
        var e = entries[session] ?? Entry(lastState: state, lastTitle: title)
        let first = entries[session] == nil
        if !first {
            if viewed.contains(session) {
                e.ran = false
                e.changed = false
            } else {
                if state == .running || (state == .done && e.lastState != .done) { e.ran = true }
                if state != e.lastState || title != e.lastTitle { e.changed = true }
            }
        }
        if state == .running, let d = e.doneAt { e.ranAfter = max(e.ranAfter, d) }
        e.lastState = state
        e.lastTitle = title
        e.hook = hook
        e.doneAt = hook ? doneAt : nil
        entries[session] = e
    }

    public mutating func forget(_ session: String) {
        entries[session] = nil
        lastInput[session] = nil
    }

    /// What to draw for a session whose daemon state is `state`.
    public func display(_ session: String, state: AgentState) -> AgentState {
        guard state == .idle, let e = entries[session] else { return state }
        if e.hook {
            guard let d = e.doneAt, d > e.ranAfter, d > (lastInput[session] ?? 0) else { return state }
            return .done
        }
        guard e.ran, e.changed, !viewed.contains(session) else { return state }
        return .done
    }
}
