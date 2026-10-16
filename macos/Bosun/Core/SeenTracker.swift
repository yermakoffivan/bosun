import Foundation

/// The per-viewer "done" rule (protocol.md, Statuses): an idle session that ran and changed since
/// this viewer last looked at it shows as done. The daemon leaves this to each client.
///
/// "Ran" latches when the session is seen running, or reports done through its hook.
/// "Changed" latches on any status change or pane title change while nobody is looking.
/// Both clear when the session is looked at (shown in a tile).
public struct SeenTracker: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var ran = false
        var changed = false
        var lastState: AgentState
        var lastTitle: String?
    }

    private var entries: [String: Entry] = [:]
    private var viewed: Set<String> = []

    public init() {}

    /// Sessions currently on screen. Anything visible is "seen" continuously.
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

    /// Feed every state and title the client learns about. The first observation is a baseline.
    public mutating func observe(_ session: String, state: AgentState, title: String?) {
        guard var e = entries[session] else {
            entries[session] = Entry(ran: false, changed: false, lastState: state, lastTitle: title)
            return
        }
        if viewed.contains(session) {
            e.ran = false
            e.changed = false
        } else {
            if state == .running || (state == .done && e.lastState != .done) { e.ran = true }
            if state != e.lastState || title != e.lastTitle { e.changed = true }
        }
        e.lastState = state
        e.lastTitle = title
        entries[session] = e
    }

    public mutating func forget(_ session: String) { entries[session] = nil }

    /// What to draw for a session whose daemon state is `state`.
    public func display(_ session: String, state: AgentState) -> AgentState {
        guard state == .idle, let e = entries[session], e.ran, e.changed, !viewed.contains(session) else { return state }
        return .done
    }
}
