//! tmux commands over a control-mode connection instead of one `tmux`
//! process per command.
//!
//! ## Why
//!
//! Every `tmux` exec costs a fork + exec + server handshake, and on
//! macOS Gatekeeper re-scans each exec of an ad-hoc-signed binary
//! (Homebrew's tmux included), which is what pinned `syspolicyd` in
//! the past. A long-lived `tmux -C` client takes a command as one line
//! on its stdin and answers inside a `%begin` / `%end` (or `%error`)
//! block on its stdout, so a command costs a pipe write and a parse.
//!
//! ## Dedicated connection, not the monitor's
//!
//! This is a *second* control client, separate from the
//! `__bosun_monitor` notification client in [`super::control_client`].
//! Both attach to the same `__bosun_monitor` session. Sharing the
//! monitor's pipe would save one idle process, but:
//!
//! - The monitor's notification stream is consumed inside the tmux
//!   actor's `select!`, while commands come from any task holding the
//!   `Arc<dyn TmuxClient>` (the actor, and the app's embed path). A
//!   shared pipe would need one reader demultiplexing both, so a slow
//!   notification consumer could stall command replies and the other
//!   way round. Separate pipes keep each consumer simple.
//! - Failure isolation: a wedged or timed-out command tears down and
//!   reconnects this connection only. Lifecycle notifications keep
//!   flowing on the monitor, and its commands-only fallback is
//!   untouched.
//! - tmux runs one client's commands strictly in order, so a slow
//!   command on a shared client would delay the monitor's own work.
//!
//! The connection attaches with `attach-session -t =__bosun_monitor`
//! and never creates anything: a missing server or monitor session
//! just means "not up", and commands use exec. That keeps a bare
//! `TokioTmuxClient` (tests, a server that was killed) from starting a
//! tmux server as a side effect of a read like `list-sessions`.
//!
//! It never sends `refresh-client -C`: a control client with no size
//! is ignored by window-size negotiation, and setting one would make
//! it take part (spike finding Q5). It does send `refresh-client -f
//! no-output` so the monitor pane's output isn't streamed to it.
//!
//! ## Fallback and reconnection
//!
//! [`CommandChannel::execute`] returns [`Outcome::NotSent`] whenever
//! the connection isn't up yet (first use, between reconnects, or
//! disabled with `BOSUN_TMUX_CONTROL=0`), and the caller runs the
//! command with exec instead. The first call kicks off a connect in the
//! background; failures back off from 250 ms up to 30 s. A connection
//! that hits EOF, a write error, or a reply timeout is dropped, every
//! command waiting on it gets [`Outcome::Lost`], and the next call
//! starts a reconnect. `Lost` is ambiguous (tmux may or may not have
//! run the command), so callers only retry over exec for commands that
//! are safe to run twice.
//!
//! Commands that need a terminal (`attach-session`) never come here.
//!
//! ## Reply matching
//!
//! tmux numbers every command and writes `%begin <time> <number>
//! <flags>`, the output lines, then `%end` or `%error` with the same
//! three fields. Flag bit 1 marks a command that came from this
//! client's stdin; blocks without it (the initial `attach-session`
//! from the command line) aren't ours. tmux runs a client's commands
//! in order, so flagged blocks pair with written commands first-in,
//! first-out. One written line is always exactly one command: every
//! argument is quoted, so there is never an unquoted `;`, and a parse
//! error still produces one flagged `%error` block.
//!
//! Output is raw bytes: `capture-pane -p -e` passes pane content
//! through unescaped, including ESC and any `%` line the pane happens
//! to show. So a block only ends on a line equal to `%end` / `%error`
//! followed by the *exact* `<time> <number> <flags>` of its `%begin`;
//! a pane printing `%end 1 2 1` doesn't end the block. Notifications
//! (`%sessions-changed`, `%output`, …) arrive between blocks and are
//! ignored here.
//!
//! ## Quoting
//!
//! tmux parses each line with its own command parser, so this is an
//! injection boundary: a session name or path containing a newline or
//! `;` must never become a second command. [`quote_arg`] wraps every
//! argument in double quotes and escapes everything the parser treats
//! specially inside them: `\`, `"`, `$` (environment expansion), `~`
//! (home expansion, which tmux applies even inside double quotes at
//! the start of a word), and all control bytes as three-digit octal
//! escapes, so a newline can't end the line early. NUL can't be passed
//! through either transport and is rejected.

use std::collections::VecDeque;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::oneshot;
use tokio::time::Instant;

use crate::error::{BosunError, Result};
use crate::tmux::control_client::MONITOR_SESSION;

/// How long a command may wait for its reply before the connection is
/// considered wedged and torn down.
const REPLY_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a fresh connection may take to confirm its attach.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// Reconnect backoff bounds.
const BACKOFF_MIN: Duration = Duration::from_millis(250);
const BACKOFF_MAX: Duration = Duration::from_secs(30);

/// Quote one argument for tmux's command parser. See the module docs
/// for what gets escaped and why. NUL is not handled here; see
/// [`command_line`], which rejects it.
pub fn quote_arg(arg: &str) -> String {
    let mut out = String::with_capacity(arg.len() + 2);
    out.push('"');
    for c in arg.chars() {
        match c {
            '\\' | '"' | '$' | '~' => {
                out.push('\\');
                out.push(c);
            }
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                out.push_str(&format!("\\{:03o}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Build the single control-mode line for one command: the command
/// name bare, every argument quoted. Errors on an empty argv, a command
/// name that isn't a plain tmux command word, or a NUL byte anywhere
/// (exec can't pass one either).
pub fn command_line(args: &[&str]) -> Result<String> {
    let (name, rest) = args
        .split_first()
        .ok_or_else(|| BosunError::Tmux("empty tmux command".into()))?;
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_lowercase() || c == '-') {
        return Err(BosunError::Tmux(format!(
            "invalid tmux command name {name:?}"
        )));
    }
    let mut line = String::from(*name);
    for arg in rest {
        if arg.contains('\0') {
            return Err(BosunError::Tmux("tmux argument contains a NUL byte".into()));
        }
        line.push(' ');
        line.push_str(&quote_arg(arg));
    }
    Ok(line)
}

/// One closed `%begin` … `%end`/`%error` block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplyBlock {
    /// The `<time> <number> <flags>` fields, verbatim.
    pub header: String,
    /// Command number from the header.
    pub number: u64,
    /// Flags from the header; bit 1 means "sent by this client".
    pub flags: u32,
    /// `true` for `%end`, `false` for `%error`.
    pub ok: bool,
    /// Output lines, without their newlines.
    pub lines: Vec<Vec<u8>>,
}

impl ReplyBlock {
    /// Whether this block answers a command written to our stdin.
    pub fn is_ours(&self) -> bool {
        self.flags & 1 == 1
    }

    /// The output as an exec'd `tmux` would have printed it: each line
    /// followed by a newline.
    pub fn stdout(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for l in &self.lines {
            out.extend_from_slice(l);
            out.push(b'\n');
        }
        out
    }
}

/// Something the matcher recognized in the control stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MatcherEvent {
    Reply(ReplyBlock),
    /// A line outside any block: a notification like
    /// `%sessions-changed` or `%output …`.
    Notification(Vec<u8>),
}

/// Byte-level reply matcher. Feed it whatever chunks the pipe yields;
/// it buffers partial lines and emits events for complete ones.
#[derive(Debug, Default)]
pub struct ReplyMatcher {
    partial: Vec<u8>,
    open: Option<OpenBlock>,
}

#[derive(Debug)]
struct OpenBlock {
    header: String,
    number: u64,
    flags: u32,
    end_line: Vec<u8>,
    error_line: Vec<u8>,
    lines: Vec<Vec<u8>>,
}

impl ReplyMatcher {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed raw bytes from the control client's stdout.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<MatcherEvent> {
        let mut events = Vec::new();
        let mut start = 0;
        for (i, b) in bytes.iter().enumerate() {
            if *b == b'\n' {
                self.partial.extend_from_slice(&bytes[start..i]);
                let line = std::mem::take(&mut self.partial);
                if let Some(ev) = self.line(line) {
                    events.push(ev);
                }
                start = i + 1;
            }
        }
        self.partial.extend_from_slice(&bytes[start..]);
        events
    }

    fn line(&mut self, line: Vec<u8>) -> Option<MatcherEvent> {
        if let Some(open) = self.open.as_mut() {
            let ok = if line == open.end_line {
                true
            } else if line == open.error_line {
                false
            } else {
                open.lines.push(line);
                return None;
            };
            let open = self.open.take().expect("open block");
            return Some(MatcherEvent::Reply(ReplyBlock {
                header: open.header,
                number: open.number,
                flags: open.flags,
                ok,
                lines: open.lines,
            }));
        }
        if let Some(rest) = line.strip_prefix(b"%begin ") {
            if let Some((header, number, flags)) = parse_header(rest) {
                let end_line = format!("%end {header}").into_bytes();
                let error_line = format!("%error {header}").into_bytes();
                self.open = Some(OpenBlock {
                    header,
                    number,
                    flags,
                    end_line,
                    error_line,
                    lines: Vec::new(),
                });
                return None;
            }
        }
        if line.is_empty() {
            return None;
        }
        Some(MatcherEvent::Notification(line))
    }
}

/// Parse `<time> <number> <flags>` from a `%begin` line. Returns the
/// header text verbatim alongside the parsed number and flags.
fn parse_header(rest: &[u8]) -> Option<(String, u64, u32)> {
    let text = std::str::from_utf8(rest).ok()?;
    let mut parts = text.split(' ');
    let time = parts.next()?;
    let number = parts.next()?;
    let flags = parts.next()?;
    if parts.next().is_some() || time.parse::<i64>().is_err() {
        return None;
    }
    let number = number.parse::<u64>().ok()?;
    let flags = flags.parse::<u32>().ok()?;
    Some((text.to_string(), number, flags))
}

/// What happened to one command sent through the channel.
#[derive(Debug)]
pub enum Outcome {
    /// tmux answered. `ok` is false for an `%error` block, whose lines
    /// carry the error message (what exec would print on stderr).
    Replied(ReplyBlock),
    /// The command was never written; run it with exec.
    NotSent,
    /// The command was written but the connection died (or timed out)
    /// before the reply. tmux may or may not have run it.
    Lost,
}

/// Counters for measuring how commands were carried.
#[derive(Debug, Default)]
pub struct ChannelStats {
    pub control_commands: AtomicU64,
    pub exec_commands: AtomicU64,
    pub connects: AtomicU64,
    pub connect_failures: AtomicU64,
}

/// Snapshot of [`ChannelStats`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct StatsSnapshot {
    pub control_commands: u64,
    pub exec_commands: u64,
    pub connects: u64,
    pub connect_failures: u64,
}

enum State {
    Down {
        next_attempt: Instant,
        backoff: Duration,
        connecting: bool,
    },
    Up(Arc<Connection>),
}

/// The shared command channel for one tmux socket. Cheap to share via
/// `Arc`; every clone of `TokioTmuxClient` holds the same one.
pub struct CommandChannel {
    socket: Option<String>,
    enabled: bool,
    state: Mutex<State>,
    stats: ChannelStats,
}

impl std::fmt::Debug for CommandChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CommandChannel")
            .field("socket", &self.socket)
            .field("enabled", &self.enabled)
            .field("up", &self.is_up())
            .finish()
    }
}

impl CommandChannel {
    pub fn new(socket: Option<String>, enabled: bool) -> Self {
        Self {
            socket,
            enabled,
            state: Mutex::new(State::Down {
                next_attempt: Instant::now(),
                backoff: BACKOFF_MIN,
                connecting: false,
            }),
            stats: ChannelStats::default(),
        }
    }

    /// Whether a live connection is currently carrying commands.
    pub fn is_up(&self) -> bool {
        matches!(&*self.state.lock().expect("channel state"), State::Up(c) if c.alive())
    }

    pub fn stats(&self) -> StatsSnapshot {
        StatsSnapshot {
            control_commands: self.stats.control_commands.load(Ordering::Relaxed),
            exec_commands: self.stats.exec_commands.load(Ordering::Relaxed),
            connects: self.stats.connects.load(Ordering::Relaxed),
            connect_failures: self.stats.connect_failures.load(Ordering::Relaxed),
        }
    }

    /// Record a command that went over exec (called by the client).
    pub fn note_exec(&self) {
        self.stats.exec_commands.fetch_add(1, Ordering::Relaxed);
    }

    /// Run one command over the connection if it's up. See [`Outcome`].
    pub async fn execute(self: &Arc<Self>, args: &[&str]) -> Outcome {
        if !self.enabled {
            return Outcome::NotSent;
        }
        let Some(conn) = self.current() else {
            return Outcome::NotSent;
        };
        let Ok(line) = command_line(args) else {
            // Let exec produce its own error for a malformed argv.
            return Outcome::NotSent;
        };
        let rx = match conn.send(&line).await {
            Ok(rx) => rx,
            Err(()) => {
                self.mark_down(&conn);
                return Outcome::NotSent;
            }
        };
        match tokio::time::timeout(REPLY_TIMEOUT, rx).await {
            Ok(Ok(block)) => {
                self.stats.control_commands.fetch_add(1, Ordering::Relaxed);
                Outcome::Replied(block)
            }
            Ok(Err(_)) => {
                self.mark_down(&conn);
                Outcome::Lost
            }
            Err(_) => {
                tracing::warn!("tmux control command timed out; reconnecting: {}", line);
                conn.kill();
                self.mark_down(&conn);
                Outcome::Lost
            }
        }
    }

    /// The live connection, or `None` after kicking off a background
    /// connect if one is due.
    fn current(self: &Arc<Self>) -> Option<Arc<Connection>> {
        let mut state = self.state.lock().expect("channel state");
        if let State::Up(conn) = &*state {
            if conn.alive() {
                return Some(Arc::clone(conn));
            }
            *state = State::Down {
                next_attempt: Instant::now(),
                backoff: BACKOFF_MIN,
                connecting: false,
            };
        }
        if let State::Down {
            next_attempt,
            backoff,
            connecting,
        } = &mut *state
        {
            if !*connecting && Instant::now() >= *next_attempt {
                // A runtime is always present here: `execute` is async.
                if let Ok(handle) = tokio::runtime::Handle::try_current() {
                    *connecting = true;
                    let me = Arc::clone(self);
                    let prev_backoff = *backoff;
                    handle.spawn(async move { me.connect(prev_backoff).await });
                }
            }
        }
        None
    }

    async fn connect(self: Arc<Self>, prev_backoff: Duration) {
        let result = Connection::open(self.socket.as_deref()).await;
        let mut state = self.state.lock().expect("channel state");
        match result {
            Ok(conn) => {
                self.stats.connects.fetch_add(1, Ordering::Relaxed);
                tracing::debug!("tmux control command channel up");
                *state = State::Up(conn);
            }
            Err(e) => {
                self.stats.connect_failures.fetch_add(1, Ordering::Relaxed);
                tracing::debug!("tmux control command channel unavailable: {}", e);
                let backoff = (prev_backoff * 2).clamp(BACKOFF_MIN, BACKOFF_MAX);
                *state = State::Down {
                    next_attempt: Instant::now() + prev_backoff,
                    backoff,
                    connecting: false,
                };
            }
        }
    }

    fn mark_down(&self, conn: &Arc<Connection>) {
        let mut state = self.state.lock().expect("channel state");
        if let State::Up(cur) = &*state {
            if Arc::ptr_eq(cur, conn) {
                *state = State::Down {
                    next_attempt: Instant::now(),
                    backoff: BACKOFF_MIN,
                    connecting: false,
                };
            }
        }
    }
}

type Waiter = oneshot::Sender<ReplyBlock>;

/// Waiters for written commands, in write order. `closed` is set once
/// the reader has seen EOF, so a late writer can't park a waiter that
/// nobody will ever answer.
#[derive(Default)]
struct Pending {
    waiters: VecDeque<Waiter>,
    closed: bool,
}

struct Connection {
    writer: tokio::sync::Mutex<ChildStdin>,
    pending: Arc<Mutex<Pending>>,
    alive: Arc<AtomicBool>,
    child: Mutex<Child>,
}

impl Connection {
    fn alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }

    fn kill(&self) {
        self.alive.store(false, Ordering::Release);
        if let Ok(mut child) = self.child.lock() {
            let _ = child.start_kill();
        }
    }

    /// Spawn `tmux -C attach-session -t =__bosun_monitor` and wait for
    /// the attach's own reply block. Fails when the server or the
    /// monitor session isn't there.
    async fn open(socket: Option<&str>) -> Result<Arc<Self>> {
        let mut cmd = Command::new("tmux");
        if let Some(s) = socket {
            cmd.arg("-L").arg(s);
        }
        let target = format!("={MONITOR_SESSION}");
        cmd.arg("-C")
            .arg("attach-session")
            .arg("-t")
            .arg(&target)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let mut child = cmd
            .spawn()
            .map_err(|e| BosunError::Tmux(format!("spawn tmux -C: {e}")))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| BosunError::Tmux("tmux -C: missing stdin".into()))?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| BosunError::Tmux("tmux -C: missing stdout".into()))?;

        let pending = Arc::new(Mutex::new(Pending::default()));
        let alive = Arc::new(AtomicBool::new(true));
        let (ready_tx, ready_rx) = oneshot::channel::<bool>();

        let reader_pending = Arc::clone(&pending);
        let reader_alive = Arc::clone(&alive);
        tokio::spawn(async move {
            let mut matcher = ReplyMatcher::new();
            let mut ready_tx = Some(ready_tx);
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                let n = match stdout.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                for ev in matcher.feed(&buf[..n]) {
                    match ev {
                        MatcherEvent::Reply(block) if block.is_ours() => {
                            let waiter =
                                reader_pending.lock().expect("pending").waiters.pop_front();
                            match waiter {
                                Some(w) => {
                                    let _ = w.send(block);
                                }
                                None => {
                                    tracing::warn!(
                                        "tmux control reply {} with no waiting command",
                                        block.number
                                    );
                                }
                            }
                        }
                        MatcherEvent::Reply(block) => {
                            // The attach command's own block marks the
                            // connection as ready (or failed).
                            if let Some(tx) = ready_tx.take() {
                                let _ = tx.send(block.ok);
                            }
                        }
                        MatcherEvent::Notification(_) => {}
                    }
                }
            }
            reader_alive.store(false, Ordering::Release);
            let mut p = reader_pending.lock().expect("pending");
            p.closed = true;
            // Dropping the senders wakes every waiter with an error,
            // which `execute` reports as `Lost`.
            p.waiters.clear();
        });

        let ready = tokio::time::timeout(CONNECT_TIMEOUT, ready_rx).await;
        match ready {
            Ok(Ok(true)) => {}
            Ok(Ok(false)) => {
                let _ = child.start_kill();
                return Err(BosunError::Tmux("tmux -C attach failed".into()));
            }
            Ok(Err(_)) => {
                return Err(BosunError::Tmux(
                    "tmux -C exited before attaching (no server or monitor session)".into(),
                ));
            }
            Err(_) => {
                let _ = child.start_kill();
                return Err(BosunError::Tmux("tmux -C attach timed out".into()));
            }
        }

        let conn = Arc::new(Self {
            writer: tokio::sync::Mutex::new(stdin),
            pending,
            alive,
            child: Mutex::new(child),
        });
        // Don't stream the monitor pane's output to this client. A
        // flag, not a size: never `-C` here (see module docs).
        if let Ok(rx) = conn.send("refresh-client -f no-output").await {
            let _ = tokio::time::timeout(CONNECT_TIMEOUT, rx).await;
        }
        if !conn.alive() {
            return Err(BosunError::Tmux("tmux -C closed during setup".into()));
        }
        Ok(conn)
    }

    /// Write one command line and return the receiver for its reply.
    /// The waiter is queued under the writer lock, so queue order is
    /// write order.
    async fn send(&self, line: &str) -> std::result::Result<oneshot::Receiver<ReplyBlock>, ()> {
        let mut writer = self.writer.lock().await;
        if !self.alive() {
            return Err(());
        }
        let (tx, rx) = oneshot::channel();
        {
            let mut p = self.pending.lock().expect("pending");
            if p.closed {
                return Err(());
            }
            p.waiters.push_back(tx);
        }
        let mut bytes = Vec::with_capacity(line.len() + 1);
        bytes.extend_from_slice(line.as_bytes());
        bytes.push(b'\n');
        let wrote = async {
            writer.write_all(&bytes).await?;
            writer.flush().await
        }
        .await;
        if wrote.is_err() {
            // Ours is the newest waiter: nobody else can push while we
            // hold the writer. The line may be half-written, so this
            // connection is done either way.
            self.pending.lock().expect("pending").waiters.pop_back();
            self.kill();
            return Err(());
        }
        Ok(rx)
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.kill();
    }
}

/// Whether the command channel is enabled, from `BOSUN_TMUX_CONTROL`.
/// On unless set to `0`, `off`, `false` or `no`.
pub fn enabled_from_env() -> bool {
    match std::env::var("BOSUN_TMUX_CONTROL") {
        Ok(v) => !matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "0" | "off" | "false" | "no"
        ),
        Err(_) => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A reference implementation of how tmux's parser reads one
    /// double-quoted word (cmd-parse.y `yylex_token` with the escapes
    /// from `yylex_token_escape`). Returns the decoded bytes and the
    /// rest of the input after the closing quote. Panics on anything
    /// the quoting function must never produce.
    fn tmux_unquote(s: &str) -> (Vec<u8>, &str) {
        let b = s.as_bytes();
        assert_eq!(b[0], b'"', "word must start with a quote: {s:?}");
        let mut out = Vec::new();
        let mut i = 1;
        loop {
            let c = *b.get(i).expect("unterminated quote");
            match c {
                b'"' => return (out, &s[i + 1..]),
                b'\\' => {
                    let n = b[i + 1];
                    if (b'0'..=b'3').contains(&n) {
                        let o = std::str::from_utf8(&b[i + 1..i + 4]).unwrap();
                        out.push(u8::from_str_radix(o, 8).unwrap());
                        i += 4;
                    } else {
                        assert!(
                            !b"abefsvrntuU4567".contains(&n),
                            "escape \\{} would be interpreted",
                            n as char
                        );
                        out.push(n);
                        i += 2;
                    }
                }
                b'$' => panic!("unescaped $ would expand a variable: {s:?}"),
                b'~' => panic!("unescaped ~ would expand to $HOME: {s:?}"),
                c if c < 0x20 || c == 0x7f => panic!("raw control byte {c:#x} in {s:?}"),
                c => {
                    out.push(c);
                    i += 1;
                }
            }
        }
    }

    const HOSTILE: &[&str] = &[
        "",
        "plain",
        "with space",
        "dq\"inside",
        "sq'inside",
        "semi;colon; kill-server",
        "trailing;",
        "#{session_name} #(rm -rf ~) #[fg=red]",
        "{ braces }",
        "line1\nkill-server",
        "cr\rhere",
        "tab\there",
        "esc\x1b[31m",
        "del\x7f",
        "back\\slash\\",
        "\\",
        "\\\"",
        "$HOME ${HOME} $(id)",
        "~/path",
        "~root",
        "a~b",
        "unicode: héllo 漢字 🚀 \u{200b}",
        "%end 1 2 1",
        "\\0015",
        "-t",
        "--",
    ];

    #[test]
    fn quote_round_trips_hostile_inputs() {
        for input in HOSTILE {
            let q = quote_arg(input);
            let (decoded, rest) = tmux_unquote(&q);
            assert_eq!(rest, "", "quote left trailing text for {input:?}: {q:?}");
            assert_eq!(
                decoded,
                input.as_bytes(),
                "round trip of {input:?} via {q:?}"
            );
        }
    }

    #[test]
    fn quoted_output_has_no_raw_newline_or_control_bytes() {
        for input in HOSTILE {
            let q = quote_arg(input);
            assert!(
                !q.bytes().any(|b| b < 0x20 || b == 0x7f),
                "control byte leaked for {input:?}: {q:?}"
            );
        }
    }

    #[test]
    fn command_line_is_one_command() {
        let line =
            command_line(&["set-option", "-t", "bosun-a;b", "@x", "v\nkill-server"]).unwrap();
        assert!(!line.contains('\n'));
        assert_eq!(
            line,
            r#"set-option "-t" "bosun-a;b" "@x" "v\012kill-server""#
        );
        // Every argument decodes back to exactly what was passed.
        let mut rest = line.strip_prefix("set-option ").unwrap();
        let mut words = Vec::new();
        loop {
            let (w, r) = tmux_unquote(rest);
            words.push(String::from_utf8(w).unwrap());
            if r.is_empty() {
                break;
            }
            rest = r.strip_prefix(' ').unwrap();
        }
        assert_eq!(words, ["-t", "bosun-a;b", "@x", "v\nkill-server"]);
    }

    #[test]
    fn command_line_rejects_nul_and_bad_names() {
        assert!(command_line(&["set-option", "a\0b"]).is_err());
        assert!(command_line(&[]).is_err());
        assert!(command_line(&["kill-server; x"]).is_err());
        assert!(command_line(&["\"q\""]).is_err());
    }

    fn feed_all(m: &mut ReplyMatcher, s: &[u8]) -> Vec<MatcherEvent> {
        m.feed(s)
    }

    fn reply(ev: &MatcherEvent) -> &ReplyBlock {
        match ev {
            MatcherEvent::Reply(b) => b,
            other => panic!("expected reply, got {other:?}"),
        }
    }

    #[test]
    fn matcher_pairs_begin_and_end() {
        let mut m = ReplyMatcher::new();
        let ev = feed_all(
            &mut m,
            b"%begin 1792 10 1\nline one\n\nline three\n%end 1792 10 1\n",
        );
        assert_eq!(ev.len(), 1);
        let b = reply(&ev[0]);
        assert!(b.ok && b.is_ours());
        assert_eq!(b.number, 10);
        assert_eq!(
            b.lines,
            vec![b"line one".to_vec(), vec![], b"line three".to_vec()]
        );
        assert_eq!(b.stdout(), b"line one\n\nline three\n".to_vec());
    }

    #[test]
    fn matcher_reports_error_blocks() {
        let mut m = ReplyMatcher::new();
        let ev = feed_all(
            &mut m,
            b"%begin 5 7 1\ncan't find session: nope\n%error 5 7 1\n",
        );
        let b = reply(&ev[0]);
        assert!(!b.ok);
        assert_eq!(b.lines, vec![b"can't find session: nope".to_vec()]);
    }

    #[test]
    fn matcher_routes_interleaved_notifications() {
        // Real ordering from a tmux 3.8 transcript: the attach block
        // (flags 0), a notification, then pipelined commands with
        // notifications between their blocks.
        let mut m = ReplyMatcher::new();
        let ev = feed_all(
            &mut m,
            b"%begin 1 444 0\n%end 1 444 0\n%session-changed $0 __bosun_monitor\n\
%begin 1 446 1\n%end 1 446 1\n%unlinked-window-add @2\n%sessions-changed\n\
%begin 1 447 1\nbosun-a\n%end 1 447 1\n%output %0 \\033[1m\n%exit\n",
        );
        let kinds: Vec<String> = ev
            .iter()
            .map(|e| match e {
                MatcherEvent::Reply(b) => format!("reply {} {}", b.number, b.flags),
                MatcherEvent::Notification(n) => String::from_utf8_lossy(n).into_owned(),
            })
            .collect();
        assert_eq!(
            kinds,
            [
                "reply 444 0",
                "%session-changed $0 __bosun_monitor",
                "reply 446 1",
                "%unlinked-window-add @2",
                "%sessions-changed",
                "reply 447 1",
                "%output %0 \\033[1m",
                "%exit",
            ]
        );
        assert!(!reply(&ev[0]).is_ours());
    }

    #[test]
    fn matcher_handles_lines_split_across_reads() {
        let stream: &[u8] =
            b"%sessions-changed\n%begin 99 3 1\nhello \xe6\xbc\xa2\n%end 99 3 1\n%begin 99 4 1\n%error 99 4 1\n";
        // Every split point, including mid-UTF-8 and mid-header.
        for split in 0..=stream.len() {
            let mut m = ReplyMatcher::new();
            let mut ev = m.feed(&stream[..split]);
            ev.extend(m.feed(&stream[split..]));
            assert_eq!(ev.len(), 3, "split at {split}");
            assert_eq!(reply(&ev[1]).lines, vec![b"hello \xe6\xbc\xa2".to_vec()]);
            assert!(!reply(&ev[2]).ok);
        }
        // And byte by byte.
        let mut m = ReplyMatcher::new();
        let mut ev = Vec::new();
        for b in stream {
            ev.extend(m.feed(std::slice::from_ref(b)));
        }
        assert_eq!(ev.len(), 3);
    }

    #[test]
    fn matcher_keeps_forged_end_lines_inside_the_block() {
        // capture-pane passes pane text through raw. A pane showing an
        // `%end` line (or one for another command) must not close the
        // block; only the exact header does.
        let mut m = ReplyMatcher::new();
        let ev = m.feed(
            b"%begin 1700 20 1\n%end 1 2 1\n%end 1700 21 1\n%error 1700 20 0\n\x1b[31mred\n%end 1700 20 1\n",
        );
        assert_eq!(ev.len(), 1);
        let b = reply(&ev[0]);
        assert!(b.ok);
        assert_eq!(b.lines.len(), 4);
        assert_eq!(b.lines[3], b"\x1b[31mred".to_vec());
    }

    #[test]
    fn matcher_ignores_malformed_begin() {
        let mut m = ReplyMatcher::new();
        let ev = m.feed(b"%begin nonsense\n%begin 1 2\n%begin 1 2 1\n%end 1 2 1\n");
        assert_eq!(ev.len(), 3);
        assert!(matches!(&ev[0], MatcherEvent::Notification(_)));
        assert!(matches!(&ev[1], MatcherEvent::Notification(_)));
        assert!(reply(&ev[2]).ok);
    }

    #[tokio::test]
    async fn disabled_channel_never_sends() {
        let ch = Arc::new(CommandChannel::new(Some("unused".into()), false));
        assert!(matches!(
            ch.execute(&["list-sessions"]).await,
            Outcome::NotSent
        ));
        assert!(!ch.is_up());
    }
}
