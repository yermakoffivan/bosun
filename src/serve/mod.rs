//! `bosun serve`: the tmux actor without the TUI, behind a Unix socket.
//!
//! A GUI (the planned Mac app) connects, says `hello`, gets one
//! `snapshot` of everything it needs to draw a sidebar, then a stream
//! of deltas, and sends commands that are acknowledged by id. The
//! protocol is described in `docs/protocol.md`; the wire types live in
//! [`protocol`] and the framing in [`frame`].
//!
//! The daemon reuses the TUI's own machinery rather than porting it:
//! the same [`tmux_actor`] does all tmux work, and a headless
//! [`AppState`] runs the same reducer the TUI uses for the session
//! list, so sidebar reconcile, section history and container handling
//! behave identically. Settings and sidebar changes are written to the
//! same `config.toml` through the same functions.
//!
//! Single instance: a `flock` on a lock file next to the socket. The
//! daemon exits [`ServeOptions::idle_timeout`] after its last client
//! disconnects (or after starting, if nobody connects).

pub mod frame;
pub mod protocol;

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio::time::Instant;

use crate::actors::tmux_actor;
use crate::app::AppState;
use crate::config::{Config, WorktreeLocation};
use crate::error::{BosunError, Result};
use crate::events::{AppMsg, Command, SettingChange};
use crate::sidebar::SidebarModel;
use crate::store::Store;
use crate::tmux::TokioTmuxClient;
use crate::ui::Theme;

use protocol::{
    Ack, ClientMsg, CmdEnvelope, CmdOp, ConfigWire, PendingLaunchWire, RecentWire, ServerInfo,
    ServerMsg, SessionWire, SettingWire, SidebarWire, Snapshot, SpecWire, StatusInfo, ThemeEntry,
    ThemeSource, ThemeWire, PROTOCOL_VERSION,
};

/// Default for [`ServeOptions::idle_timeout`].
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone)]
pub struct ServeOptions {
    /// Exit this long after the last client disconnects.
    pub idle_timeout: Duration,
}

impl Default for ServeOptions {
    fn default() -> Self {
        Self {
            idle_timeout: DEFAULT_IDLE_TIMEOUT,
        }
    }
}

/// The daemon's socket: `bosun.sock` in Bosun's data directory, next
/// to `bosun.db`. The one place this path is decided.
pub fn socket_path() -> Result<PathBuf> {
    Ok(crate::store::data_dir()?.join("bosun.sock"))
}

/// The single-instance lock file, next to the socket.
pub fn lock_path() -> Result<PathBuf> {
    Ok(crate::store::data_dir()?.join("bosun-serve.lock"))
}

/// Errors `bosun serve` reports to the user before it starts serving.
#[derive(Debug)]
pub enum StartError {
    AlreadyRunning { pid: Option<u32> },
    Other(BosunError),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StartError::AlreadyRunning { pid: Some(pid) } => {
                write!(f, "bosun serve is already running (pid {pid})")
            }
            StartError::AlreadyRunning { pid: None } => write!(f, "bosun serve is already running"),
            StartError::Other(e) => write!(f, "{e}"),
        }
    }
}

impl From<BosunError> for StartError {
    fn from(e: BosunError) -> Self {
        StartError::Other(e)
    }
}

impl From<std::io::Error> for StartError {
    fn from(e: std::io::Error) -> Self {
        StartError::Other(BosunError::Io(e))
    }
}

/// Run the daemon until it goes idle or gets SIGINT/SIGTERM.
pub async fn run(opts: ServeOptions) -> std::result::Result<(), StartError> {
    let sock_path = socket_path()?;
    let dir = sock_path
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| BosunError::Store("socket path has no parent".into()))?;
    std::fs::create_dir_all(&dir)?;
    let _lock = InstanceLock::acquire(&lock_path()?)?;

    // sun_path is 104 bytes on macOS, 108 on Linux.
    if sock_path.as_os_str().len() >= 104 {
        return Err(BosunError::Io(std::io::Error::other(format!(
            "socket path is too long for a Unix socket: {}",
            sock_path.display()
        )))
        .into());
    }
    // We hold the lock, so any socket file left over is stale.
    let _ = std::fs::remove_file(&sock_path);
    let listener = UnixListener::bind(&sock_path)?;
    set_owner_only(&sock_path);

    let config = Config::load();
    let store = Arc::new(match Store::open_default() {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("store open failed, using in-memory: {}", e);
            Store::in_memory().expect("in-memory store cannot fail")
        }
    });
    let client = Arc::new(match &config.tmux_socket {
        Some(s) => TokioTmuxClient::with_socket(s.clone()),
        None => TokioTmuxClient::new(),
    });

    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<Command>();
    let (evt_tx, evt_rx) = mpsc::unbounded_channel::<AppMsg>();
    // Every create defers the agent launch inside the actor; the
    // daemon then launches right away or leaves it to the client
    // (`defer_launch`). See `CmdOp::Create`.
    let mut actor_config = config.clone();
    actor_config.embed_enabled = true;
    let actor = tmux_actor::spawn(
        client.clone(),
        config.tmux_socket.clone(),
        actor_config,
        store.clone(),
        cmd_rx,
        evt_tx,
    );
    // No preview to keep live: park the actor's fast capture tick.
    let _ = cmd_tx.send(Command::EmbedActive(true));

    let mut daemon = Daemon::new(config, store, client, cmd_tx.clone());
    let result = daemon.serve(listener, evt_rx, opts).await;

    let _ = cmd_tx.send(Command::Shutdown);
    let _ = tokio::time::timeout(Duration::from_secs(3), actor).await;
    let _ = std::fs::remove_file(&sock_path);
    result.map_err(StartError::Other)
}

/// `flock`-based single-instance lock. Released when dropped (the fd
/// closes) or when the process dies, so a crash never leaves it stuck.
struct InstanceLock {
    _file: std::fs::File,
}

impl InstanceLock {
    fn acquire(path: &Path) -> std::result::Result<Self, StartError> {
        use std::io::{Read, Seek, Write};
        use std::os::unix::io::AsRawFd;
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)?;
        // SAFETY: `flock` on a valid fd we own; no memory involved.
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc != 0 {
            let mut s = String::new();
            let _ = file.read_to_string(&mut s);
            return Err(StartError::AlreadyRunning {
                pid: s.trim().parse().ok(),
            });
        }
        file.set_len(0)?;
        file.rewind()?;
        writeln!(file, "{}", std::process::id())?;
        Ok(Self { _file: file })
    }
}

fn set_owner_only(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    if let Err(e) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
        tracing::warn!("chmod 600 {}: {}", path.display(), e);
    }
}

/// Is this message from the actor a failure? The actor reports both
/// outcomes through `AppMsg::Warn`; these prefixes are its success and
/// background messages, everything else is an error.
fn is_error_message(m: &str) -> bool {
    const INFO: &[&str] = &[
        "created ",
        "restarted ",
        "modified ",
        "list: ",
        "live refresh off",
    ];
    !INFO.iter().any(|p| m.starts_with(p))
}

/// Everything the protocol publishes, in wire form. The daemon keeps
/// the last state it sent and diffs against it to produce deltas.
#[derive(Debug, Clone, PartialEq)]
struct Published {
    sessions: Vec<SessionWire>,
    statuses: BTreeMap<String, StatusInfo>,
    sidebar: SidebarWire,
    recents: Vec<RecentWire>,
    config: ConfigWire,
    theme: ThemeWire,
    themes: Vec<ThemeEntry>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InflightKind {
    Create { defer_launch: bool },
    Restart { defer_launch: bool },
    GetSpec,
    Other,
}

/// A command forwarded to the actor, waiting for its barrier.
struct Inflight {
    barrier: u64,
    client: u64,
    id: u64,
    kind: InflightKind,
    messages: Vec<String>,
    session: Option<String>,
    spec: Option<SpecWire>,
    pending_launch: Option<PendingLaunchWire>,
}

struct ClientConn {
    tx: mpsc::UnboundedSender<Vec<u8>>,
    ready: bool,
}

enum ClientEvent {
    Frame(Vec<u8>),
    Closed,
}

struct Daemon {
    app: AppState,
    config: Config,
    store: Arc<Store>,
    client: Arc<TokioTmuxClient>,
    cmd_tx: mpsc::UnboundedSender<Command>,
    theme: Theme,
    embed_enabled: bool,
    agent_hooks: bool,
    seq: u64,
    published: Option<Published>,
    clients: HashMap<u64, ClientConn>,
    next_client: u64,
    inflight: VecDeque<Inflight>,
    next_barrier: u64,
    /// `config.toml` mtime and contents at the last check, to notice
    /// edits made by someone else (the TUI, a text editor).
    config_mtime: Option<SystemTime>,
    file_config: Config,
}

impl Daemon {
    fn new(
        config: Config,
        store: Arc<Store>,
        client: Arc<TokioTmuxClient>,
        cmd_tx: mpsc::UnboundedSender<Command>,
    ) -> Self {
        let recents = store.list_recents(200).unwrap_or_default();
        let app = AppState {
            divider_x: config.divider_x,
            sidebar: config.sidebar.clone(),
            session_history: config.session_history.clone(),
            banner_font: config.banner_font.clone(),
            session_prefix: config.session_prefix.clone(),
            editor: config.editor.clone(),
            recents,
            single_window_mode: config.single_window_mode,
            sidebar_hidden: config.sidebar_hidden,
            show_group_in_title: config.show_group_in_title,
            hide_single_tab_strip: config.hide_single_tab_strip,
            worktree_location: config.worktree_location,
            default_agent: config.default_agent.clone(),
            remove_dead_sessions: config.remove_dead_sessions,
            ..Default::default()
        };
        let theme = Theme::load(&config.theme, crate::config::user_themes_dir().as_deref());
        Self {
            app,
            embed_enabled: config.embed_enabled,
            agent_hooks: config.agent_hooks,
            file_config: config.clone(),
            config,
            store,
            client,
            cmd_tx,
            theme,
            seq: 0,
            published: None,
            clients: HashMap::new(),
            next_client: 1,
            inflight: VecDeque::new(),
            next_barrier: 1,
            config_mtime: config_mtime(),
        }
    }

    async fn serve(
        &mut self,
        listener: UnixListener,
        mut evt_rx: mpsc::UnboundedReceiver<AppMsg>,
        opts: ServeOptions,
    ) -> Result<()> {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigterm = signal(SignalKind::terminate())?;
        let mut sigint = signal(SignalKind::interrupt())?;
        let (client_tx, mut client_rx) = mpsc::unbounded_channel::<(u64, ClientEvent)>();
        let mut idle_deadline = Some(Instant::now() + opts.idle_timeout);
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        // First state, so the first snapshot has something in it.
        self.publish();

        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (stream, _) = match accepted {
                        Ok(s) => s,
                        Err(e) => {
                            tracing::warn!("accept: {}", e);
                            continue;
                        }
                    };
                    if !same_user(&stream) {
                        tracing::warn!("refusing a connection from another user");
                        continue;
                    }
                    let id = self.next_client;
                    self.next_client += 1;
                    let tx = spawn_connection(id, stream, client_tx.clone());
                    self.clients.insert(id, ClientConn { tx, ready: false });
                    idle_deadline = None;
                }
                Some((id, ev)) = client_rx.recv() => {
                    match ev {
                        ClientEvent::Frame(bytes) => self.handle_frame(id, &bytes).await,
                        ClientEvent::Closed => {
                            self.clients.remove(&id);
                        }
                    }
                    if self.clients.is_empty() && idle_deadline.is_none() {
                        idle_deadline = Some(Instant::now() + opts.idle_timeout);
                    }
                }
                maybe = evt_rx.recv() => {
                    let Some(msg) = maybe else {
                        tracing::warn!("tmux actor exited");
                        break;
                    };
                    self.handle_app_msg(msg);
                    self.publish();
                }
                _ = tick.tick() => {
                    self.check_config_file();
                    self.publish();
                }
                _ = async {
                    match idle_deadline {
                        Some(d) => tokio::time::sleep_until(d).await,
                        None => std::future::pending::<()>().await,
                    }
                } => {
                    tracing::info!("no clients for {:?}; exiting", opts.idle_timeout);
                    break;
                }
                _ = sigterm.recv() => break,
                _ = sigint.recv() => break,
            }
        }
        Ok(())
    }

    // ── state → wire ───────────────────────────────────────────────

    fn current(&self) -> Published {
        let sessions: Vec<SessionWire> = self.app.sessions.iter().map(SessionWire::from).collect();
        let statuses = self
            .app
            .sessions
            .iter()
            .map(|v| (v.name().to_string(), StatusInfo::from(v)))
            .collect();
        let live: std::collections::HashSet<&str> =
            self.app.sessions.iter().map(|v| v.name()).collect();
        let sidebar = SidebarWire::from_model(
            &self.app.sidebar,
            |name| match self.app.session_by_name(name) {
                Some(v) => v.display().to_string(),
                None => self.app.dead_display_for(name),
            },
            |name| live.contains(name),
        );
        Published {
            sessions,
            statuses,
            sidebar,
            recents: self.app.recents.iter().map(RecentWire::from).collect(),
            config: self.config_view(),
            theme: ThemeWire::from(&self.theme),
            themes: theme_entries(),
        }
    }

    fn config_view(&self) -> ConfigWire {
        let pin = |k: &str| crate::config::env_pin(k).map(str::to_string);
        let row = |key: &str, value: serde_json::Value, choices: Option<Vec<String>>| {
            let pinned_by = pin(key);
            SettingWire {
                key: key.to_string(),
                value,
                choices,
                read_only: pinned_by.is_some(),
                pinned_by,
            }
        };
        let themes: Vec<String> = theme_entries().into_iter().map(|t| t.name).collect();
        let mut settings = vec![
            row("theme", self.theme.name.clone().into(), Some(themes)),
            row(
                "banner_font",
                self.app.banner_font.clone().into(),
                Some(crate::ui::banner::names().map(str::to_string).collect()),
            ),
            row(
                "default_agent",
                self.app.default_agent.clone().into(),
                Some(
                    crate::config::AGENTS
                        .iter()
                        .map(|s| s.to_string())
                        .collect(),
                ),
            ),
            row(
                "worktree_location",
                worktree_str(self.app.worktree_location).into(),
                Some(vec!["subdir".into(), "sibling".into()]),
            ),
            row("single_window", self.app.single_window_mode.into(), None),
            row(
                "show_group_in_title",
                self.app.show_group_in_title.into(),
                None,
            ),
            row(
                "hide_single_tab_strip",
                self.app.hide_single_tab_strip.into(),
                None,
            ),
            row(
                "remove_dead_sessions",
                self.app.remove_dead_sessions.into(),
                None,
            ),
            row("embed_enabled", self.embed_enabled.into(), None),
            row("agent_hooks", self.agent_hooks.into(), None),
        ];
        let install = |key: &str, value: serde_json::Value, var: &str| SettingWire {
            key: key.to_string(),
            value,
            choices: None,
            pinned_by: std::env::var(var).ok().map(|_| var.to_string()),
            read_only: true,
        };
        settings.push(install(
            "session_prefix",
            self.config.session_prefix.clone().into(),
            "BOSUN_PREFIX",
        ));
        settings.push(install(
            "tmux_socket",
            self.config
                .tmux_socket
                .clone()
                .map(serde_json::Value::from)
                .unwrap_or(serde_json::Value::Null),
            "BOSUN_TMUX_SOCKET",
        ));
        ConfigWire { settings }
    }

    fn snapshot(&self) -> ServerMsg {
        let p = self.published.clone().unwrap_or_else(|| self.current());
        ServerMsg::Snapshot(Box::new(Snapshot {
            seq: self.seq,
            server: ServerInfo {
                version: env!("CARGO_PKG_VERSION").to_string(),
                protocol: PROTOCOL_VERSION,
                tmux_socket: self.config.tmux_socket.clone(),
            },
            sessions: p.sessions,
            statuses: p.statuses,
            sidebar: p.sidebar,
            recents: p.recents,
            config: p.config,
            theme: p.theme,
            themes: p.themes,
        }))
    }

    /// Diff the current state against what was last sent and broadcast
    /// one delta per changed part.
    fn publish(&mut self) {
        let cur = self.current();
        let Some(prev) = self.published.take() else {
            self.seq = 1;
            self.published = Some(cur);
            return;
        };
        let prev_rows: HashMap<&str, &SessionWire> =
            prev.sessions.iter().map(|s| (s.name.as_str(), s)).collect();
        let upsert: Vec<SessionWire> = cur
            .sessions
            .iter()
            .filter(|s| prev_rows.get(s.name.as_str()) != Some(s))
            .cloned()
            .collect();
        let cur_names: std::collections::HashSet<&str> =
            cur.sessions.iter().map(|s| s.name.as_str()).collect();
        let removed: Vec<String> = prev
            .sessions
            .iter()
            .filter(|s| !cur_names.contains(s.name.as_str()))
            .map(|s| s.name.clone())
            .collect();
        if !upsert.is_empty() || !removed.is_empty() {
            let msg = ServerMsg::Sessions {
                seq: self.next_seq(),
                upsert,
                removed,
            };
            self.broadcast(&msg);
        }
        for (name, info) in &cur.statuses {
            if prev.statuses.get(name) != Some(info) {
                let msg = ServerMsg::Status {
                    seq: self.next_seq(),
                    session: name.clone(),
                    state: info.state,
                    source: info.source,
                    detail: info.detail.clone(),
                };
                self.broadcast(&msg);
            }
        }
        if cur.sidebar != prev.sidebar {
            let msg = ServerMsg::Sidebar {
                seq: self.next_seq(),
                sidebar: cur.sidebar.clone(),
            };
            self.broadcast(&msg);
        }
        if cur.recents != prev.recents {
            let msg = ServerMsg::Recents {
                seq: self.next_seq(),
                recents: cur.recents.clone(),
            };
            self.broadcast(&msg);
        }
        if cur.config != prev.config {
            let msg = ServerMsg::Config {
                seq: self.next_seq(),
                config: cur.config.clone(),
            };
            self.broadcast(&msg);
        }
        if cur.theme != prev.theme {
            let msg = ServerMsg::Theme {
                seq: self.next_seq(),
                theme: cur.theme.clone(),
            };
            self.broadcast(&msg);
        }
        if cur.themes != prev.themes {
            let msg = ServerMsg::Themes {
                seq: self.next_seq(),
                themes: cur.themes.clone(),
            };
            self.broadcast(&msg);
        }
        self.published = Some(cur);
    }

    fn next_seq(&mut self) -> u64 {
        self.seq += 1;
        self.seq
    }

    fn broadcast(&self, msg: &ServerMsg) {
        let frame = frame::encode(msg);
        for c in self.clients.values().filter(|c| c.ready) {
            let _ = c.tx.send(frame.clone());
        }
    }

    fn send_to(&self, client: u64, msg: &ServerMsg) {
        if let Some(c) = self.clients.get(&client) {
            let _ = c.tx.send(frame::encode(msg));
        }
    }

    fn ack(&self, client: u64, ack: Ack) {
        self.send_to(client, &ServerMsg::Ack(ack));
    }

    fn ack_result(&self, client: u64, id: u64, r: std::result::Result<(), String>) {
        let ack = match r {
            Ok(()) => Ack {
                id,
                ok: true,
                ..Default::default()
            },
            Err(e) => Ack {
                id,
                ok: false,
                error: Some(e),
                ..Default::default()
            },
        };
        self.ack(client, ack);
    }

    // ── client messages ────────────────────────────────────────────

    async fn handle_frame(&mut self, client: u64, bytes: &[u8]) {
        let msg: ClientMsg = match serde_json::from_slice(bytes) {
            Ok(m) => m,
            Err(e) => {
                self.send_to(
                    client,
                    &ServerMsg::Error {
                        code: "bad_message".into(),
                        message: e.to_string(),
                    },
                );
                return;
            }
        };
        let ready = self.clients.get(&client).is_some_and(|c| c.ready);
        match msg {
            ClientMsg::Hello { protocol, .. } => {
                if protocol != PROTOCOL_VERSION {
                    self.send_to(
                        client,
                        &ServerMsg::Error {
                            code: "protocol_mismatch".into(),
                            message: format!(
                                "bosun serve {} speaks protocol {} but this client speaks {}; \
                                 update bosun or the app so both match",
                                env!("CARGO_PKG_VERSION"),
                                PROTOCOL_VERSION,
                                protocol
                            ),
                        },
                    );
                    self.clients.remove(&client);
                    return;
                }
                self.publish();
                let snap = self.snapshot();
                if let Some(c) = self.clients.get_mut(&client) {
                    c.ready = true;
                }
                self.send_to(client, &snap);
            }
            _ if !ready => {
                self.send_to(
                    client,
                    &ServerMsg::Error {
                        code: "no_hello".into(),
                        message: "send hello first".into(),
                    },
                );
                self.clients.remove(&client);
            }
            ClientMsg::Resync => {
                self.publish();
                let snap = self.snapshot();
                self.send_to(client, &snap);
            }
            ClientMsg::Cmd(CmdEnvelope { id, op }) => {
                self.handle_cmd(client, id, op).await;
                self.publish();
            }
        }
    }

    /// Forward a command to the actor, followed by a barrier so we know
    /// when it's done.
    fn forward(&mut self, client: u64, id: u64, kind: InflightKind, cmds: Vec<Command>) {
        let barrier = self.next_barrier;
        self.next_barrier += 1;
        for c in cmds {
            let _ = self.cmd_tx.send(c);
        }
        let _ = self.cmd_tx.send(Command::Barrier(barrier));
        self.inflight.push_back(Inflight {
            barrier,
            client,
            id,
            kind,
            messages: Vec::new(),
            session: None,
            spec: None,
            pending_launch: None,
        });
    }

    async fn handle_cmd(&mut self, client: u64, id: u64, op: CmdOp) {
        use protocol::check_text;
        match op {
            CmdOp::Create { spec, defer_launch } => match spec.to_spec() {
                Ok(spec) => self.forward(
                    client,
                    id,
                    InflightKind::Create { defer_launch },
                    vec![Command::CreateSession(spec)],
                ),
                Err(e) => self.ack_result(client, id, Err(e)),
            },
            CmdOp::Kill { session } => {
                self.app.recently_killed.insert(session.clone());
                self.forward(
                    client,
                    id,
                    InflightKind::Other,
                    vec![Command::KillSession(session)],
                );
            }
            CmdOp::KillContainer { sessions } => {
                for s in &sessions {
                    self.app.recently_killed.insert(s.clone());
                }
                self.forward(
                    client,
                    id,
                    InflightKind::Other,
                    vec![Command::KillContainer { tabs: sessions }],
                );
            }
            CmdOp::KillRemoveWorktree {
                session,
                worktree_path,
                branch,
                merge,
            } => {
                self.app.recently_killed.insert(session.clone());
                self.forward(
                    client,
                    id,
                    InflightKind::Other,
                    vec![Command::KillSessionRemoveWorktree {
                        internal: session,
                        worktree_path,
                        branch,
                        merge,
                    }],
                );
            }
            CmdOp::Rename { session, display } => match check_text("display", &display, false) {
                Ok(()) => self.forward(
                    client,
                    id,
                    InflightKind::Other,
                    vec![Command::RenameSession {
                        internal: session,
                        new_display: display,
                    }],
                ),
                Err(e) => self.ack_result(client, id, Err(e)),
            },
            CmdOp::Restart {
                session,
                resume,
                defer_launch,
            } => self.forward(
                client,
                id,
                InflightKind::Restart { defer_launch },
                vec![Command::RestartSession {
                    internal: session,
                    continue_session: resume,
                }],
            ),
            CmdOp::LaunchAgent { session, resume } => self.forward(
                client,
                id,
                InflightKind::Other,
                vec![Command::LaunchAgent {
                    internal: session,
                    resume,
                }],
            ),
            CmdOp::GetSpec { session } => self.forward(
                client,
                id,
                InflightKind::GetSpec,
                vec![Command::OpenModifySession { internal: session }],
            ),
            CmdOp::Modify { session, spec } => match spec.to_spec() {
                Ok(spec) => self.forward(
                    client,
                    id,
                    InflightKind::Other,
                    vec![Command::ModifySession {
                        internal: session,
                        spec,
                    }],
                ),
                Err(e) => self.ack_result(client, id, Err(e)),
            },
            CmdOp::DeleteRecent { recent } => {
                let r = self.store.delete_recent(recent).map_err(|e| e.to_string());
                self.reload_recents();
                self.ack_result(client, id, r);
            }
            CmdOp::SidebarSave { sidebar } => {
                let r = sidebar
                    .to_model()
                    .map(|model| self.save_client_sidebar(model));
                self.ack_result(client, id, r);
            }
            CmdOp::InsertSection { name } => {
                let r = check_text("name", &name, false).map(|()| {
                    let mut out = Vec::new();
                    self.app.insert_section(name, &mut out);
                    self.run_local(out);
                });
                self.ack_result(client, id, r);
            }
            CmdOp::RenameSection { section, name } => {
                let r = check_text("name", &name, false).and_then(|()| {
                    if !self.app.sidebar.sections.iter().any(|s| s.id == section) {
                        return Err(format!("no section with id {section}"));
                    }
                    let mut out = Vec::new();
                    self.app.rename_section(&section, name, &mut out);
                    self.run_local(out);
                    Ok(())
                });
                self.ack_result(client, id, r);
            }
            CmdOp::SetTheme { name, persist } => {
                let r = self.set_theme(&name, persist);
                self.ack_result(client, id, r);
            }
            CmdOp::ApplySetting { key, value } => {
                let r = self.apply_setting(&key, &value);
                self.ack_result(client, id, r);
            }
            CmdOp::ClientFlags { tty, ignore_size } => {
                let r = self
                    .client
                    .set_client_ignore_size(&tty, ignore_size)
                    .await
                    .map_err(|e| e.to_string());
                self.ack_result(client, id, r);
            }
            CmdOp::MakeLatest { tty } => {
                let r = self
                    .client
                    .make_client_latest(&tty)
                    .await
                    .map_err(|e| e.to_string());
                self.ack_result(client, id, r);
            }
        }
    }

    fn set_theme(&mut self, name: &str, persist: bool) -> std::result::Result<(), String> {
        if !theme_entries().iter().any(|t| t.name == name) {
            return Err(format!("no theme named {name}"));
        }
        self.theme = Theme::load(name, crate::config::user_themes_dir().as_deref());
        if persist {
            crate::config::write_theme(name).map_err(|e| format!("theme: failed to save: {e}"))?;
            self.file_config.theme = name.to_string();
            self.config_mtime = config_mtime();
        }
        Ok(())
    }

    /// The settings panel's `apply_setting`, for the daemon's state.
    fn apply_setting(
        &mut self,
        key: &str,
        value: &serde_json::Value,
    ) -> std::result::Result<(), String> {
        if let Some(var) = crate::config::env_pin(key) {
            return Err(format!("{key} is pinned by {var}"));
        }
        let as_bool = || {
            value
                .as_bool()
                .ok_or_else(|| format!("{key} needs a boolean"))
        };
        let as_str = || {
            value
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| format!("{key} needs a string"))
        };
        let change = match key {
            "theme" => SettingChange::Theme(as_str()?),
            "banner_font" => {
                let v = as_str()?;
                if !crate::ui::banner::names().any(|n| n == v) {
                    return Err(format!("no banner font named {v}"));
                }
                SettingChange::BannerFont(v)
            }
            "default_agent" => {
                let v = as_str()?;
                if !crate::config::AGENTS.contains(&v.as_str()) {
                    return Err(format!("unknown agent {v}"));
                }
                SettingChange::DefaultAgent(v)
            }
            "worktree_location" => SettingChange::WorktreeLocation(match as_str()?.as_str() {
                "subdir" => WorktreeLocation::Subdir,
                "sibling" => WorktreeLocation::Sibling,
                other => return Err(format!("unknown worktree location {other}")),
            }),
            "single_window" => SettingChange::SingleWindow(as_bool()?),
            "show_group_in_title" => SettingChange::ShowGroupInTitle(as_bool()?),
            "hide_single_tab_strip" => SettingChange::HideSingleTabStrip(as_bool()?),
            "remove_dead_sessions" => SettingChange::RemoveDeadSessions(as_bool()?),
            "embed_enabled" => SettingChange::EmbedEnabled(as_bool()?),
            "agent_hooks" => SettingChange::AgentHooks(as_bool()?),
            "session_prefix" | "tmux_socket" => {
                return Err(format!("{key} is set by editing config.toml"))
            }
            other => return Err(format!("unknown setting {other}")),
        };
        let written = match change {
            SettingChange::Theme(name) => return self.set_theme(&name, true),
            SettingChange::BannerFont(name) => {
                self.app.banner_font = name.clone();
                crate::config::write_banner_font(&name)
            }
            SettingChange::DefaultAgent(agent) => {
                self.app.default_agent = agent.clone();
                crate::config::write_default_agent(&agent)
            }
            SettingChange::WorktreeLocation(loc) => {
                self.app.worktree_location = loc;
                crate::config::write_worktree_location(loc)
            }
            SettingChange::SingleWindow(on) => {
                self.app.single_window_mode = on;
                crate::config::write_single_window(on)
            }
            SettingChange::ShowGroupInTitle(on) => {
                self.app.show_group_in_title = on;
                crate::config::write_show_group_in_title(on)
            }
            SettingChange::HideSingleTabStrip(on) => {
                self.app.hide_single_tab_strip = on;
                crate::config::write_hide_single_tab_strip(on)
            }
            SettingChange::RemoveDeadSessions(on) => {
                self.app.remove_dead_sessions = on;
                crate::config::write_remove_dead_sessions(on)
            }
            SettingChange::EmbedEnabled(on) => {
                self.embed_enabled = on;
                crate::config::write_embed_enabled(on)
            }
            SettingChange::AgentHooks(on) => {
                // The actor owns launching and status, so it rebuilds
                // its hook files and starts or stops honoring hook state.
                self.agent_hooks = on;
                let _ = self.cmd_tx.send(Command::SetAgentHooks(on));
                crate::config::write_agent_hooks(on)
            }
        };
        // Our own write isn't an outside edit; don't reload it.
        self.config_mtime = config_mtime();
        self.file_config = Config::load();
        written.map_err(|e| format!("settings: failed to save: {e}"))
    }

    /// Adopt a sidebar a client sent. Section history follows, so a
    /// row moved out of a section isn't put back on the next refresh.
    fn save_client_sidebar(&mut self, model: SidebarModel) {
        self.app.sidebar = model;
        self.app.selected = 0;
        let mut history_changed = false;
        for v in &self.app.sessions {
            let display = v.display().to_string();
            let section = self
                .app
                .sidebar
                .sections
                .iter()
                .find(|s| s.members.iter().any(|c| c.contains_internal(v.name())));
            match section {
                Some(s) => {
                    let prev = self.app.session_history.insert(display, s.name.clone());
                    history_changed |= prev.as_deref() != Some(s.name.as_str());
                }
                None => history_changed |= self.app.session_history.remove(&display).is_some(),
            }
        }
        let mut out = vec![Command::SaveSidebar(self.app.sidebar.clone())];
        if history_changed {
            out.push(Command::SaveSessionHistory(
                self.app.session_history.clone(),
            ));
        }
        self.run_local(out);
    }

    /// Carry out the commands the reducer emits that the TUI's run
    /// loop would handle itself. Selection and preview commands mean
    /// nothing without a screen and are dropped.
    fn run_local(&mut self, out: Vec<Command>) {
        for c in out {
            match c {
                Command::SaveSidebar(model) => {
                    if let Err(e) = crate::config::write_sidebar(&model) {
                        tracing::warn!("sidebar: failed to save: {}", e);
                    }
                    self.file_config.sidebar = model;
                    self.config_mtime = config_mtime();
                }
                Command::SaveSessionHistory(h) => {
                    if let Err(e) = crate::config::write_session_history(&h) {
                        tracing::warn!("history: failed to save: {}", e);
                    }
                    self.file_config.session_history = h;
                    self.config_mtime = config_mtime();
                }
                _ => {}
            }
        }
    }

    fn reload_recents(&mut self) {
        self.app.recents = self.store.list_recents(200).unwrap_or_default();
    }

    // ── actor messages ─────────────────────────────────────────────

    fn handle_app_msg(&mut self, msg: AppMsg) {
        match msg {
            AppMsg::CommandDone(barrier) => self.finish(barrier),
            AppMsg::Warn(text) => {
                if let Some(f) = self.inflight.front_mut() {
                    f.messages.push(text.clone());
                }
                let msg = ServerMsg::Notice {
                    seq: self.next_seq(),
                    message: text,
                };
                self.broadcast(&msg);
            }
            AppMsg::DeferRelaunch { internal, resume } => {
                let defer = matches!(
                    self.inflight.front().map(|f| f.kind),
                    Some(InflightKind::Restart { defer_launch: true })
                );
                if defer {
                    if let Some(f) = self.inflight.front_mut() {
                        f.pending_launch = Some(PendingLaunchWire {
                            session: internal,
                            resume: Some(resume),
                        });
                    }
                } else {
                    let _ = self.cmd_tx.send(Command::LaunchAgent {
                        internal,
                        resume: Some(resume),
                    });
                }
            }
            AppMsg::ModifySpecReady { spec, .. } => {
                if let Some(f) = self.inflight.front_mut() {
                    if f.kind == InflightKind::GetSpec {
                        f.spec = Some(SpecWire::from(&spec));
                    }
                }
            }
            msg @ AppMsg::SessionsRefreshed { .. } => {
                if let AppMsg::SessionsRefreshed {
                    select_after: Some(name),
                    ..
                } = &msg
                {
                    if let Some(f) = self.inflight.front_mut() {
                        if matches!(f.kind, InflightKind::Create { .. }) {
                            f.session = Some(name.clone());
                        }
                    }
                }
                let out = self.app.apply(msg);
                self.run_local(out);
                self.reload_recents();
            }
            msg @ AppMsg::StatusRefreshed { .. } => {
                let _ = self.app.apply(msg);
            }
            AppMsg::Fatal(e) => tracing::error!("tmux actor: {}", e),
            _ => {}
        }
    }

    /// A barrier came back: acknowledge the command it closes.
    fn finish(&mut self, barrier: u64) {
        let Some(pos) = self.inflight.iter().position(|f| f.barrier == barrier) else {
            return;
        };
        let Some(f) = self.inflight.remove(pos) else {
            return;
        };
        let error = f.messages.iter().find(|m| is_error_message(m)).cloned();
        let mut ack = Ack {
            id: f.id,
            ok: error.is_none(),
            error,
            session: f.session.clone(),
            spec: f.spec,
            pending_launch: f.pending_launch,
            messages: f.messages,
        };
        if let InflightKind::Create { defer_launch } = f.kind {
            if let (true, Some(session)) = (ack.ok, f.session) {
                if defer_launch {
                    ack.pending_launch = Some(PendingLaunchWire {
                        session,
                        resume: None,
                    });
                } else {
                    let _ = self.cmd_tx.send(Command::LaunchAgent {
                        internal: session,
                        resume: None,
                    });
                }
            }
        }
        if f.kind == InflightKind::GetSpec && ack.ok && ack.spec.is_none() {
            ack.ok = false;
            ack.error = Some("no spec stored on this session".into());
        }
        self.ack(f.client, ack);
        if matches!(
            f.kind,
            InflightKind::Create { .. } | InflightKind::Restart { .. }
        ) {
            self.reload_recents();
        }
    }

    // ── config.toml edits made elsewhere ───────────────────────────

    /// Pick up `config.toml` changes made by someone else (the TUI's
    /// theme picker or settings panel, a sidebar edit, a text editor):
    /// one `stat` a second, a reload only when the mtime moved, and
    /// only fields whose file value changed are applied, so a live
    /// theme preview here isn't reverted by an unrelated edit.
    fn check_config_file(&mut self) {
        let mtime = config_mtime();
        if mtime == self.config_mtime {
            return;
        }
        self.config_mtime = mtime;
        let new = Config::load();
        let old = std::mem::replace(&mut self.file_config, new.clone());
        if new.theme != old.theme {
            self.theme = Theme::load(&new.theme, crate::config::user_themes_dir().as_deref());
        }
        if new.banner_font != old.banner_font {
            self.app.banner_font = new.banner_font.clone();
        }
        if new.default_agent != old.default_agent {
            self.app.default_agent = new.default_agent.clone();
        }
        if new.worktree_location != old.worktree_location {
            self.app.worktree_location = new.worktree_location;
        }
        if new.show_group_in_title != old.show_group_in_title {
            self.app.show_group_in_title = new.show_group_in_title;
        }
        if new.hide_single_tab_strip != old.hide_single_tab_strip {
            self.app.hide_single_tab_strip = new.hide_single_tab_strip;
        }
        if new.remove_dead_sessions != old.remove_dead_sessions {
            self.app.remove_dead_sessions = new.remove_dead_sessions;
        }
        if new.embed_enabled != old.embed_enabled {
            self.embed_enabled = new.embed_enabled;
        }
        if new.agent_hooks != old.agent_hooks {
            self.agent_hooks = new.agent_hooks;
            let _ = self.cmd_tx.send(Command::SetAgentHooks(new.agent_hooks));
        }
        if new.sidebar != old.sidebar && new.sidebar != self.app.sidebar {
            self.app.sidebar = new.sidebar.clone();
            self.app.selected = 0;
        }
        if new.session_history != old.session_history {
            self.app.session_history = new.session_history.clone();
        }
    }
}

fn config_mtime() -> Option<SystemTime> {
    let path = crate::config::config_dir()?.join("config.toml");
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

fn worktree_str(loc: WorktreeLocation) -> &'static str {
    match loc {
        WorktreeLocation::Subdir => "subdir",
        WorktreeLocation::Sibling => "sibling",
    }
}

/// Bundled themes plus the user's, in picker order. A user theme with
/// a bundled name replaces it (and is reported as `user`).
fn theme_entries() -> Vec<ThemeEntry> {
    let user_dir = crate::config::user_themes_dir();
    let is_user = |name: &str| {
        user_dir
            .as_ref()
            .is_some_and(|d| d.join(format!("{name}.toml")).is_file())
    };
    Theme::available(user_dir.as_deref())
        .into_iter()
        .map(|name| ThemeEntry {
            source: if is_user(&name) {
                ThemeSource::User
            } else {
                ThemeSource::Bundled
            },
            name,
        })
        .collect()
}

fn same_user(stream: &UnixStream) -> bool {
    match stream.peer_cred() {
        // SAFETY: geteuid has no preconditions.
        Ok(cred) => cred.uid() == unsafe { libc::geteuid() },
        Err(_) => false,
    }
}

/// Start the reader and writer tasks for one connection. Returns the
/// sender for outgoing frames; dropping it ends the writer, which
/// closes the socket after flushing what was queued.
fn spawn_connection(
    id: u64,
    stream: UnixStream,
    events: mpsc::UnboundedSender<(u64, ClientEvent)>,
) -> mpsc::UnboundedSender<Vec<u8>> {
    let (mut reader, mut writer) = stream.into_split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    tokio::spawn(async move {
        while let Some(f) = rx.recv().await {
            if frame::write_frame(&mut writer, &f).await.is_err() {
                break;
            }
        }
        let _ = writer.shutdown().await;
    });
    tokio::spawn(async move {
        // EOF or a read error both end the connection.
        while let Ok(Some(bytes)) = frame::read_frame(&mut reader).await {
            if events.send((id, ClientEvent::Frame(bytes))).is_err() {
                return;
            }
        }
        let _ = events.send((id, ClientEvent::Closed));
    });
    tx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actor_messages_classify_as_the_actor_means_them() {
        // Every Warn format in tmux_actor.rs, filled in.
        for ok in [
            "created bosun-x-1",
            "restarted api",
            "modified api — press Ctrl+R to apply",
            "list: tmux command failed: boom",
            "live refresh off: no tmux",
        ] {
            assert!(!is_error_message(ok), "{ok}");
        }
        for err in [
            "create: tmux command failed: duplicate session",
            "kill: tmux command failed: x",
            "kill container: a: x",
            "rename: x",
            "restart: x",
            "restart read: x",
            "cannot restart: session predates metadata support",
            "launch: x",
            "launch read: x",
            "modify display: x",
            "modify metadata: x",
            "modify read: x",
            "modify: session predates metadata support",
            "worktree cleanup: x",
            "worktree has uncommitted changes; not removed",
            "worktree status: x",
            "merge feat conflicted; aborted, worktree kept",
            "merge feat: x (also failed to abort: y)",
            "merged, but worktree remove failed: x",
            "worktree remove: x",
            "branch delete feat: x",
        ] {
            assert!(is_error_message(err), "{err}");
        }
    }

    #[test]
    fn socket_and_lock_live_in_the_data_dir() {
        let dir = crate::store::data_dir().unwrap();
        assert_eq!(socket_path().unwrap(), dir.join("bosun.sock"));
        assert_eq!(lock_path().unwrap(), dir.join("bosun-serve.lock"));
    }

    #[test]
    fn second_lock_reports_the_holder() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("lock");
        let first = InstanceLock::acquire(&path).expect("first lock");
        match InstanceLock::acquire(&path) {
            Err(StartError::AlreadyRunning { pid }) => {
                assert_eq!(pid, Some(std::process::id()))
            }
            other => panic!("expected AlreadyRunning, got {:?}", other.err()),
        }
        drop(first);
        InstanceLock::acquire(&path).expect("lock is free again");
    }
}
