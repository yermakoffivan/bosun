import Foundation

/// When the app tells you about a session through a macOS notification, and when it takes one back
/// (design section 10). No UI here: the app feeds it statuses and says whether you can see the session.
///
/// Two moments need you:
/// - **waiting:** the agent moved into `waiting` (a permission prompt or a question). One notification per
///   waiting stretch, however many waiting statuses arrive during it (Claude's PermissionRequest hook and its
///   permission_prompt Notification are the same wait).
/// - **done:** a hook-reported turn finished, i.e. a `done_at` newer than any this session had before, and the
///   session shows done (you haven't typed into it since).
///
/// Neither is posted when you can already see the session (the app is active, its window on screen and the
/// session in the row it shows); that wait or `done_at` still counts as handled, so it never turns up later.
/// A session's notifications are taken back once you see it or type into it, or its state moves on (a wait
/// ends; the done turn is followed by anything else).
public struct Attention: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case waiting, done
    }

    /// A notification to post. One per session and kind at a time: a newer one replaces it (same id).
    public struct Note: Equatable, Sendable {
        public var session: String
        public var kind: Kind
        /// The hook's detail while waiting, e.g. `permission: Bash` or `question`.
        public var detail: String?
        public var id: String { Attention.id(kind, session) }
    }

    public enum Action: Equatable, Sendable {
        case post(Note)
        /// Take back these delivered notifications (by id).
        case remove([String])
    }

    /// The two "Notify When…" settings.
    public struct Enabled: Equatable, Sendable {
        public var waiting: Bool
        public var done: Bool
        public init(waiting: Bool = true, done: Bool = true) {
            self.waiting = waiting
            self.done = done
        }
    }

    struct Entry: Equatable, Sendable {
        /// The session is in a waiting stretch that has been handled (notified, or seen as it began).
        var waiting = false
        /// The newest `done_at` handled.
        var doneAt: UInt64 = 0
    }

    private var entries: [String: Entry] = [:]
    /// Ids of notifications posted and not taken back yet.
    public private(set) var delivered: Set<String> = []

    public init() {}

    public static func id(_ kind: Kind, _ session: String) -> String { "\(kind.rawValue):\(session)" }

    /// Sessions that have a notification out.
    public var outstanding: Set<String> {
        Set(delivered.compactMap { id in id.firstIndex(of: ":").map { String(id[id.index(after: $0)...]) } })
    }

    public func isKnown(_ session: String) -> Bool { entries[session] != nil }

    /// Record a session's status without notifying: what was already there when the app connected, so a
    /// launch never posts a burst for every session that was waiting or done before.
    public mutating func baseline(_ session: String, status: StatusInfo?) {
        var e = Entry()
        e.waiting = status?.state == .waiting
        if let s = status, s.isHook, let d = s.doneAt { e.doneAt = d }
        entries[session] = e
    }

    /// A status for `session` arrived. `done`: the session shows done now (`SeenTracker.display`).
    /// `visible`: you can see the session right now.
    public mutating func observe(_ session: String, status: StatusInfo?, done: Bool, visible: Bool, enabled: Enabled = Enabled()) -> [Action] {
        var e = entries[session] ?? Entry()
        var out: [Action] = []
        if status?.state == .waiting {
            if !e.waiting {
                e.waiting = true
                if enabled.waiting && !visible { out.append(post(Note(session: session, kind: .waiting, detail: status?.detail))) }
            }
        } else if e.waiting {
            e.waiting = false
            out += take(.waiting, session)
        }
        let doneAt = status.flatMap { $0.isHook ? $0.doneAt : nil }
        if let d = doneAt, d > e.doneAt {
            e.doneAt = d
            if enabled.done && done && !visible { out.append(post(Note(session: session, kind: .done))) }
        }
        if doneAt == nil || !done { out += take(.done, session) }
        entries[session] = e
        return out
    }

    /// You saw the session (on screen in the active app, or you opened its notification) or typed into it:
    /// its notifications go.
    public mutating func seen(_ session: String) -> [Action] {
        take(.waiting, session) + take(.done, session)
    }

    /// The session's done turn was read (typed into): only its done notification goes.
    public mutating func doneRead(_ session: String) -> [Action] {
        take(.done, session)
    }

    /// The session went away.
    public mutating func forget(_ session: String) -> [Action] {
        entries[session] = nil
        return seen(session)
    }

    private mutating func post(_ n: Note) -> Action {
        delivered.insert(n.id)
        return .post(n)
    }

    private mutating func take(_ kind: Kind, _ session: String) -> [Action] {
        let id = Attention.id(kind, session)
        guard delivered.remove(id) != nil else { return [] }
        return [.remove([id])]
    }

    /// The Dock badge: the number of live sessions waiting on you. Done turns don't count: they stay done
    /// until you type into the session, so a session you looked at and left would keep the badge up.
    public static func badgeCount(statuses: [String: StatusInfo], alive: (String) -> Bool) -> Int {
        statuses.filter { $0.value.state == .waiting && alive($0.key) }.count
    }

    /// The badge's text: nil (no badge) at zero.
    public static func badgeLabel(_ count: Int) -> String? { count > 0 ? "\(count)" : nil }
}
