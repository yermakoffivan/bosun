import Foundation

/// The per-viewer "done" rule. The daemon reports a finished turn as `idle` and leaves "done" to each client
/// (protocol.md, Statuses). There are two rules, picked by where the session's status came from.
///
/// **Hook statuses** (the agent reports its own state, e.g. Claude Code): done means the agent finished its turn
/// and it's the user's turn. The daemon sends the hook's `done_at` with the idle status, and the session shows done
/// while that is newer than the last time the user gave the session input in this app (typed, pasted or dropped
/// into its terminal). Being on screen doesn't clear it, but reading it does: once the pane has been the active pane
/// of the front window for a moment, or Mark as Read was chosen, it shows as `seen` (done, and read) until the next
/// turn. A new status without `done_at` (the next prompt made it running, a permission prompt opened) ends it, and
/// so does seeing it running, so a stale `done_at` can't bring it back.
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
    /// The last time each session's done turn was read, Unix ms.
    private var lastRead: [String: UInt64] = [:]

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

    /// The session's done turn was read at `at` (Unix ms): focused for a moment, or marked read. A detector
    /// status has no turn to keep, so it's simply seen.
    public mutating func markRead(_ session: String, at: UInt64) {
        lastRead[session] = max(lastRead[session] ?? 0, at)
        if entries[session]?.hook == false { markSeen(session) }
    }

    /// The last input time of every session that has one, Unix ms (saved across launches).
    public var inputTimes: [String: UInt64] { lastInput }
    /// The last read time of every session that has one, Unix ms (saved across launches).
    public var readTimes: [String: UInt64] { lastRead }

    /// Input and read times saved by an earlier run. A newer time already noted wins.
    public mutating func restoreInputs(_ times: [String: UInt64], read: [String: UInt64] = [:]) {
        for (s, t) in times { lastInput[s] = max(lastInput[s] ?? 0, t) }
        for (s, t) in read { lastRead[s] = max(lastRead[s] ?? 0, t) }
    }

    /// Drop the input and read times of sessions that no longer exist.
    public mutating func pruneInputs(keeping sessions: Set<String>) {
        lastInput = lastInput.filter { sessions.contains($0.key) }
        lastRead = lastRead.filter { sessions.contains($0.key) }
    }

    public mutating func forget(_ session: String) {
        entries[session] = nil
        lastInput[session] = nil
        lastRead[session] = nil
    }

    /// What to draw for a session whose daemon state is `state`.
    public func display(_ session: String, state: AgentState) -> AgentState {
        guard state == .idle, let e = entries[session] else { return state }
        if e.hook {
            guard let d = e.doneAt, d > e.ranAfter, d > (lastInput[session] ?? 0) else { return state }
            return d > (lastRead[session] ?? 0) ? .done : .seen
        }
        guard e.ran, e.changed, !viewed.contains(session) else { return state }
        return .done
    }
}

/// The done rule's input and read times on disk (`inputs-<daemon>.json` in the app's Application Support folder),
/// so a relaunch doesn't show every finished session as done again.
public struct SavedInputs: Codable, Equatable, Sendable {
    public var version = 1
    public var inputs: [String: UInt64]
    /// Absent in files written before read marks.
    public var read: [String: UInt64]?

    public init(_ inputs: [String: UInt64], read: [String: UInt64] = [:]) {
        self.inputs = inputs
        self.read = read.isEmpty ? nil : read
    }

    public func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    public static func decode(_ data: Data) -> SavedInputs? {
        guard let s = try? JSONDecoder().decode(SavedInputs.self, from: data), s.version == 1 else { return nil }
        return s
    }
}
