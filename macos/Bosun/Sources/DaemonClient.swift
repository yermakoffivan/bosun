import AppKit
import BosunCore
import Darwin

/// One Unix socket connection to `bosun serve`: a reader thread decodes frames, a serial queue writes them.
final class SocketConnection: @unchecked Sendable {
    let fd: Int32
    private let writeQueue = DispatchQueue(label: "bosun.daemon.write", qos: .userInitiated)
    private let closed = NSLock()
    private var isClosed = false

    init(fd: Int32) { self.fd = fd }

    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    func startReading(onMessage: @escaping @Sendable (ServerMessage) -> Void, onClose: @escaping @Sendable (String) -> Void) {
        let fd = self.fd
        let t = Thread {
            var reader = FrameReader()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n <= 0 {
                    onClose(n == 0 ? "the daemon closed the connection" : String(cString: strerror(errno)))
                    return
                }
                reader.append(Data(buf[0..<n]))
                do {
                    while let frame = try reader.next() {
                        if let msg = try? ServerMessage.decode(frame) {
                            onMessage(msg)
                        } else {
                            log.error("undecodable frame: \(String(decoding: frame.prefix(200), as: UTF8.self), privacy: .public)")
                        }
                    }
                } catch {
                    onClose("bad frame from the daemon: \(error)")
                    return
                }
            }
        }
        t.name = "bosun.daemon.read"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func send(_ body: Data) {
        let frame = Frame.encode(body)
        writeQueue.async { [self] in
            closed.lock()
            let dead = isClosed
            closed.unlock()
            guard !dead else { return }
            frame.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { return }
                    off += n
                }
            }
        }
    }

    func close() {
        closed.lock()
        defer { closed.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        writeQueue.async { Darwin.close(self.fd) }
    }
}

/// The app's link to the daemon: connects (spawning `bosun serve` if needed), keeps `BosunState`
/// current from the snapshot and deltas, resyncs on a seq gap, and matches acks to commands.
@MainActor
final class DaemonClient {
    enum Status: Equatable {
        case connecting
        case connected
        case disconnected(String)
        /// Protocol major mismatch or a missing binary: needs a person, so no automatic retry.
        case failed(String)
    }

    private(set) var state = BosunState()
    private(set) var status: Status = .connecting
    /// When BOSUN_SERVE_SOCKET is set: connect there and never spawn a daemon.
    let socketOverride: String?
    var socketPath: String { socketOverride ?? Paths.defaultSocket }

    var onChanges: [([BosunState.Change]) -> Void] = []
    var onStatus: [(Status) -> Void] = []

    private var conn: SocketConnection?
    private var generation = 0
    private var nextID: UInt64 = 1
    private var pending: [UInt64: (Ack) -> Void] = [:]
    private var resyncPending = false
    private var retryDelay: TimeInterval = 0.25

    init() {
        socketOverride = Env.value("BOSUN_SERVE_SOCKET")
    }

    // MARK: Cache

    private var cacheURL: URL { Paths.cacheDir.appendingPathComponent("snapshot-\(Paths.key(for: socketPath)).json") }

    /// Draw the first frame from the snapshot written on the last quit.
    func loadCache() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        state.loadCached(snap)
        notify([.snapshot])
        return true
    }

    func writeCache() {
        guard let snap = state.snapshot(), let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: Connection

    func start() {
        connect()
    }

    func reconnectNow() {
        retryDelay = 0.25
        if case .connected = status { return }
        connect()
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatus.forEach { $0(s) }
    }

    private func connect() {
        generation += 1
        let gen = generation
        setStatus(.connecting)
        let override = socketOverride
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DaemonClient.establish(socketOverride: override)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.connected(result, generation: gen) }
            }
        }
    }

    private enum ConnectResult: Sendable {
        case ok(Int32)
        case retry(String)
        case fatal(String)
    }

    nonisolated private static func establish(socketOverride: String?) -> ConnectResult {
        let path = socketOverride ?? Paths.defaultSocket
        if let fd = SocketConnection.connect(path: path) { return .ok(fd) }
        if socketOverride != nil {
            return .retry("no daemon answers at \(path)")
        }
        guard let bin = Paths.bosunBinary() else {
            return .fatal("bosun isn't installed (looked in BOSUN_BIN, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)")
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ShellEnv.path()
        env["TMUX"] = nil
        env["TMUX_PANE"] = nil
        var target = path
        if let printed = ShellEnv.run(bin, ["serve", "--print-socket"], timeout: 3, env: env), !printed.isEmpty, printed != path {
            target = printed
            if let fd = SocketConnection.connect(path: target) { return .ok(fd) }
        }
        spawnDetached(bin, ["serve"], env: env)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let fd = SocketConnection.connect(path: target) { return .ok(fd) }
            usleep(40_000)
        }
        return .retry("bosun serve didn't start (socket \(target))")
    }

    /// Start a process in its own session so it outlives the app.
    nonisolated private static func spawnDetached(_ exe: String, _ args: [String], env: [String: String]) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, envp)
        if rc != 0 { log.error("spawning bosun serve failed: \(rc)") }
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
    }

    private func connected(_ result: ConnectResult, generation gen: Int) {
        guard gen == generation else {
            if case .ok(let fd) = result { Darwin.close(fd) }
            return
        }
        switch result {
        case .fatal(let why):
            setStatus(.failed(why))
        case .retry(let why):
            setStatus(.disconnected(why))
            scheduleRetry()
        case .ok(let fd):
            let c = SocketConnection(fd: fd)
            conn = c
            resyncPending = false
            c.startReading(onMessage: { msg in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(msg, generation: gen) } }
            }, onClose: { why in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.lost(why, generation: gen) } }
            })
            send(.hello(client: "bosun-mac/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"))
        }
    }

    private func scheduleRetry() {
        let gen = generation
        let delay = retryDelay
        retryDelay = min(5, retryDelay * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard gen == self.generation, self.conn == nil else { return }
                if case .failed = self.status { return }
                self.connect()
            }
        }
    }

    private func lost(_ why: String, generation gen: Int) {
        guard gen == generation else { return }
        conn?.close()
        conn = nil
        failPending("disconnected from the daemon")
        if case .failed = status { return }
        setStatus(.disconnected(why))
        scheduleRetry()
    }

    private func failPending(_ why: String) {
        let p = pending
        pending = [:]
        for (id, cb) in p { cb(Ack(id: id, ok: false, error: why)) }
    }

    private func send(_ msg: ClientMessage) {
        guard let conn, let body = try? msg.encoded() else { return }
        conn.send(body)
    }

    // MARK: Messages

    private func handle(_ msg: ServerMessage, generation gen: Int) {
        guard gen == generation else { return }
        switch msg {
        case .ack(let a):
            if let cb = pending.removeValue(forKey: a.id) { cb(a) }
            return
        case .error(let code, let message):
            log.error("daemon error \(code, privacy: .public): \(message, privacy: .public)")
            if code == "protocol_mismatch" || code == "no_hello" {
                setStatus(.failed(message))
                conn?.close()
                conn = nil
            }
            return
        default:
            break
        }
        switch state.apply(msg) {
        case .applied(let changes):
            if case .snapshot = msg {
                resyncPending = false
                retryDelay = 0.25
                if state.server?.protocolMajor ?? protocolVersion != protocolVersion {
                    setStatus(.failed("bosun serve speaks protocol \(state.server?.protocolMajor ?? 0), this app speaks \(protocolVersion): update bosun or the app so both match"))
                } else {
                    setStatus(.connected)
                }
            }
            if !changes.isEmpty { notify(changes) }
        case .gap:
            if !resyncPending {
                resyncPending = true
                send(.resync)
            }
        case .none:
            break
        }
    }

    private func notify(_ changes: [BosunState.Change]) {
        onChanges.forEach { $0(changes) }
    }

    /// Change the local sidebar straight away (a drag, a collapse), then tell the daemon.
    func saveSidebar(_ sidebar: Sidebar) {
        state.sidebar = sidebar
        notify([.sidebar])
        command(.sidebarSave(sidebar))
    }

    // MARK: Commands

    /// Send a command; `done` gets the ack (or a failed ack if the connection drops first).
    func command(_ cmd: Command, done: ((Ack) -> Void)? = nil) {
        let id = nextID
        nextID += 1
        guard conn != nil, status == .connected else {
            done?(Ack(id: id, ok: false, error: "not connected to bosun serve"))
            return
        }
        let sp = signposter.beginInterval("DaemonRoundTrip", id: signposter.makeSignpostID(), "\(cmd.op, privacy: .public)")
        pending[id] = { ack in
            signposter.endInterval("DaemonRoundTrip", sp)
            if !ack.ok { log.info("\(cmd.op, privacy: .public) failed: \(ack.error ?? "?", privacy: .public)") }
            done?(ack)
        }
        send(.cmd(id: id, cmd))
    }

    func request(_ cmd: Command) async -> Ack {
        await withCheckedContinuation { cont in
            command(cmd) { cont.resume(returning: $0) }
        }
    }
}
