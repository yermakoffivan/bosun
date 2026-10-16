import Foundation

/// The client's copy of the daemon's state: the last snapshot with every delta applied in order.
public struct BosunState: Sendable {
    public private(set) var seq: UInt64?
    public private(set) var server: ServerInfo?
    public private(set) var sessionOrder: [String] = []
    public private(set) var sessions: [String: SessionInfo] = [:]
    public private(set) var statuses: [String: StatusInfo] = [:]
    public var sidebar = Sidebar()
    public private(set) var recents: [Recent] = []
    public private(set) var config = ConfigView()
    public private(set) var theme: ThemePalette = .fallback
    /// The Light/Dark pair's palettes; nil sides use `theme`. See `ThemeChoice`.
    public private(set) var themeLight: ThemePalette?
    public private(set) var themeDark: ThemePalette?
    public private(set) var themes: [ThemeEntry] = []
    public private(set) var keybindings: KeyBindingsWire?
    /// True once a live snapshot (not the on-disk cache) has been applied.
    public private(set) var live = false

    public enum Change: Equatable, Sendable {
        case snapshot
        case sessions(changed: Set<String>, removed: Set<String>)
        case status(String)
        case sidebar
        case recents
        case config
        case theme
        case themes
        case themePair
        case keybindings
        case notice(String)
        /// A tmux client moved to `session`, or detached (nil). See `ServerMessage.client`.
        case client(tty: String, session: String?)
    }

    public enum ApplyResult: Equatable, Sendable {
        case applied([Change])
        /// A `seq` arrived out of order. The caller sends `resync`.
        case gap(expected: UInt64, got: UInt64)
        /// Not a state message (ack, error) or nothing to do.
        case none
    }

    public init() {}

    /// Load a cached snapshot (drawn before the daemon answers). It never counts as live.
    public mutating func loadCached(_ s: Snapshot) {
        install(s)
        seq = nil
        live = false
    }

    public mutating func apply(_ msg: ServerMessage) -> ApplyResult {
        if case .snapshot(let s) = msg {
            install(s)
            live = true
            return .applied([.snapshot])
        }
        guard let q = msg.seq else { return .none }
        if let last = seq, q != last + 1 {
            return .gap(expected: last + 1, got: q)
        }
        guard seq != nil else {
            // Deltas before any snapshot on this connection can't be applied.
            return .gap(expected: 0, got: q)
        }
        seq = q
        switch msg {
        case .sessions(_, let upsert, let removed):
            var changed = Set<String>()
            for s in upsert {
                if sessions[s.name] == nil { sessionOrder.append(s.name) }
                sessions[s.name] = s
                changed.insert(s.name)
            }
            var gone = Set<String>()
            for name in removed where sessions[name] != nil || statuses[name] != nil {
                sessions[name] = nil
                statuses[name] = nil
                gone.insert(name)
            }
            if !gone.isEmpty { sessionOrder.removeAll { gone.contains($0) } }
            return .applied([.sessions(changed: changed, removed: gone)])
        case .status(_, let session, let info):
            statuses[session] = info
            return .applied([.status(session)])
        case .sidebar(_, let s):
            sidebar = s
            return .applied([.sidebar])
        case .recents(_, let r):
            recents = r
            return .applied([.recents])
        case .config(_, let c):
            config = c
            return .applied([.config])
        case .theme(_, let t):
            theme = t
            return .applied([.theme])
        case .themes(_, let t):
            themes = t
            return .applied([.themes])
        case .themePair(_, let light, let dark):
            themeLight = light
            themeDark = dark
            return .applied([.themePair])
        case .keybindings(_, let k):
            keybindings = k
            return .applied([.keybindings])
        case .notice(_, let m):
            return .applied([.notice(m)])
        case .client(_, let tty, let session):
            return .applied([.client(tty: tty, session: session)])
        default:
            return .applied([])
        }
    }

    private mutating func install(_ s: Snapshot) {
        seq = s.seq
        server = s.server
        sessionOrder = s.sessions.map(\.name)
        sessions = Dictionary(s.sessions.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        statuses = s.statuses
        sidebar = s.sidebar
        recents = s.recents
        config = s.config
        theme = s.theme
        themeLight = s.themeLight
        themeDark = s.themeDark
        themes = s.themes
        keybindings = s.keybindings
    }

    /// The current state as a snapshot, for the on-disk cache.
    public func snapshot() -> Snapshot? {
        guard let server else { return nil }
        return Snapshot(seq: seq ?? 0, server: server, sessions: sessionOrder.compactMap { sessions[$0] }, statuses: statuses,
                        sidebar: sidebar, recents: recents, config: config, theme: theme, themeLight: themeLight,
                        themeDark: themeDark, themes: themes, keybindings: keybindings)
    }

    public func state(of session: String) -> AgentState { statuses[session]?.state ?? .unknown }

    public func isAlive(_ session: String) -> Bool { sessions[session] != nil }

    public var defaultAgent: String {
        if case .string(let s)? = config.value("default_agent"), agentNames.contains(s) { return s }
        return "claude"
    }

    public var worktreeLocation: String {
        if case .string(let s)? = config.value("worktree_location") { return s }
        return "subdir"
    }

    /// The active theme name the daemon reports in config (falls back to the palette's own name).
    public var themeName: String { theme.name }

    /// What the chrome shows for an appearance: the pair's side when it's set, else `theme`.
    public func palette(for appearance: ThemeChoice.Appearance) -> ThemePalette {
        ThemeChoice.palette(for: appearance, theme: theme, light: themeLight, dark: themeDark)
    }

    /// The Light/Dark pair as names, for menus and settings.
    public var themePair: ThemeChoice.Pair { ThemeChoice.Pair(light: themeLight?.name, dark: themeDark?.name) }
}
