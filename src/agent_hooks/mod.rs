//! Agent-reported status.
//!
//! The detectors in `tmux::detector` guess an agent's state from its
//! pane title and screen contents. Agents that support hooks can tell
//! us instead: Bosun launches them with hooks that run
//! `bosun hook <agent> <event>`, which maps the event to a [`Status`]
//! and writes it onto the agent's tmux pane as user options:
//!
//!   * `@bosun_state`        — `running` / `waiting` / `done` / `idle`
//!   * `@bosun_state_at`     — when it was written, epoch milliseconds
//!   * `@bosun_state_detail` — optional short note, e.g. `permission: Bash`
//!
//! The actor's poll reads the three options in the same `list-sessions`
//! call it already makes (see `tmux::parse::LIST_SESSIONS_FORMAT`), and
//! [`resolve`] decides when they win over the detectors.
//!
//! The hook path ([`run`]) is on the agent's critical path: Claude Code
//! waits for a synchronous hook before it carries on. So it does the
//! least possible: no config load, no SQLite, no async runtime, one
//! `tmux` exec, and nothing at all on stdout (Claude adds some hooks'
//! stdout to the conversation). It always lets the process exit 0, so a
//! broken hook can never break the agent.

pub mod claude;

use std::io::{IsTerminal, Read};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::tmux::detector::{title_is_working, Status};

/// Pane option holding the agent's reported state word.
pub const STATE_OPTION: &str = "@bosun_state";
/// Pane option holding when the state was written (epoch ms).
pub const AT_OPTION: &str = "@bosun_state_at";
/// Pane option holding an optional short detail string.
pub const DETAIL_OPTION: &str = "@bosun_state_detail";

/// Agents Bosun installs hooks for. Every other agent keeps using its
/// detector alone; see the README's "Agent status from hooks" section
/// for why each of the others has no clean injection path yet.
pub const HOOKED_AGENTS: &[&str] = &["claude"];

/// Longest detail string written to the pane. It's a status note, not a
/// message, and it rides every `list-sessions` poll.
const MAX_DETAIL_CHARS: usize = 48;

/// How long a freshly written `running` is trusted on its own before
/// the pane title can overrule it. Claude sets its spinner title a beat
/// after `UserPromptSubmit` fires, so checking the title immediately
/// would flicker the row back to the detector's answer.
pub const RUNNING_TITLE_GRACE_MS: u64 = 2_000;

/// A `running` state whose pane has produced no output for this long is
/// treated as stale. Every agent we launch animates something while it
/// works (spinner, elapsed timer), so a quiet pane means the turn ended
/// in a way that fired no hook (an API error, a crash, an interrupt).
pub const RUNNING_QUIET_STALE_MS: u64 = 60_000;

/// The state an agent last reported through a hook, as read back from
/// the pane's user options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookState {
    pub status: Status,
    /// When the hook wrote it, epoch milliseconds.
    pub at_ms: u64,
    pub detail: Option<String>,
}

impl HookState {
    /// Parse the three option values as `list-sessions` prints them.
    /// Unset options come through as empty strings. `None` when no
    /// state is set or the values are garbage.
    pub fn parse(state: &str, at: &str, detail: &str) -> Option<Self> {
        let status = status_from_word(state.trim())?;
        let at_ms = at.trim().parse::<u64>().ok()?;
        let detail = detail.trim();
        Some(Self {
            status,
            at_ms,
            detail: (!detail.is_empty()).then(|| detail.to_string()),
        })
    }
}

/// The word written to `@bosun_state` for a status. Only the four
/// states a hook can report have one.
pub fn status_word(status: Status) -> Option<&'static str> {
    match status {
        Status::Running => Some("running"),
        Status::Waiting => Some("waiting"),
        Status::Done => Some("done"),
        Status::Idle => Some("idle"),
        Status::Error | Status::Unknown => None,
    }
}

pub fn status_from_word(word: &str) -> Option<Status> {
    match word {
        "running" => Some(Status::Running),
        "waiting" => Some(Status::Waiting),
        "done" => Some(Status::Done),
        "idle" => Some(Status::Idle),
        _ => None,
    }
}

/// What a hook event does to the pane's state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookAction {
    /// Write this state (and detail, or clear the detail when `None`).
    Set {
        status: Status,
        detail: Option<String>,
    },
    /// Write `waiting`, but keep a detail the pane already has. For a
    /// report that says only that the agent is waiting (`permission`
    /// with no tool) arriving after a more specific one for the same
    /// wait (`question`, `permission: Bash`): the specific detail stays.
    /// A detail is only ever written alongside `waiting` and every other
    /// write clears it, so one that is already set belongs to this wait.
    /// `detail` is written only when none is set.
    WaitingKeepDetail { detail: String },
    /// Remove the state options: the agent session ended.
    Clear,
    /// The agent says it's sitting idle at its prompt. Demote a
    /// `running` or `waiting` state to `idle` (it missed an event, e.g.
    /// an interrupt), but leave `done` alone so an unread turn keeps its
    /// badge.
    SettleIdle,
    /// Nothing to record.
    Ignore,
}

impl HookAction {
    fn set(status: Status) -> Self {
        HookAction::Set {
            status,
            detail: None,
        }
    }

    fn set_with(status: Status, detail: impl Into<String>) -> Self {
        HookAction::Set {
            status,
            detail: Some(detail.into()),
        }
    }
}

/// Map one hook invocation to an action. `input` is whatever arrived on
/// stdin (possibly empty or not JSON).
pub fn map_event(agent: &str, event: &str, input: &[u8]) -> HookAction {
    match agent {
        "claude" => claude::map(event, input),
        _ => HookAction::Ignore,
    }
}

/// Entry point for `bosun hook <agent> <event>`. Never panics outward,
/// never writes to stdout, and returns normally on every error so the
/// caller can exit 0.
pub fn run(args: impl Iterator<Item = String>) {
    let args: Vec<String> = args.collect();
    let _ = std::panic::catch_unwind(|| run_inner(&args));
}

fn run_inner(args: &[String]) {
    let (Some(agent), Some(event)) = (args.first(), args.get(1)) else {
        return;
    };
    // Outside tmux there is no pane to write to.
    let Some((socket, pane)) = tmux_target(
        std::env::var("TMUX").ok().as_deref(),
        std::env::var("TMUX_PANE").ok().as_deref(),
    ) else {
        return;
    };
    let input = read_stdin();
    let action = map_event(agent, event, &input);
    let now = now_ms();
    log_invocation(agent, event, &action, now);
    match action {
        HookAction::Ignore => {}
        HookAction::SettleIdle => {
            let current = std::process::Command::new("tmux")
                .args([
                    "-S",
                    &socket,
                    "show-options",
                    "-pqv",
                    "-t",
                    &pane,
                    STATE_OPTION,
                ])
                .stdin(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .output()
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_default();
            if matches!(current.as_str(), "running" | "waiting") {
                let set = HookAction::set(Status::Idle);
                run_tmux(&socket, &tmux_args(&set, &pane, now));
            }
        }
        action => run_tmux(&socket, &tmux_args(&action, &pane, now)),
    }
}

/// Socket path and pane id from `$TMUX` / `$TMUX_PANE`. `$TMUX` is
/// `<socket path>,<server pid>,<session index>`.
pub fn tmux_target(tmux: Option<&str>, pane: Option<&str>) -> Option<(String, String)> {
    let socket = tmux?.split(',').next()?.trim();
    let pane = pane?.trim();
    if socket.is_empty() || !pane.starts_with('%') {
        return None;
    }
    Some((socket.to_string(), pane.to_string()))
}

/// The tmux argv (after `-S <socket>`) that applies `action` to `pane`.
/// One invocation, with `;` separating the commands, so the three
/// options change together. Empty for [`HookAction::Ignore`] and
/// [`HookAction::SettleIdle`], which need a read first.
/// [`HookAction::WaitingKeepDetail`] needs no read: `set-option -o`
/// writes the detail only if the pane has none, and fails ("already
/// set") otherwise. It goes last, so the state and time before it are
/// written either way.
pub fn tmux_args(action: &HookAction, pane: &str, now_ms: u64) -> Vec<String> {
    let s = |v: &str| v.to_string();
    match action {
        HookAction::Set { status, detail } => {
            let Some(mut argv) = state_args(*status, pane, now_ms) else {
                return Vec::new();
            };
            argv.extend([s(";"), s("set-option"), s("-p"), s("-t"), s(pane)]);
            match detail
                .as_deref()
                .map(sanitize_detail)
                .filter(|d| !d.is_empty())
            {
                Some(d) => argv.extend([s(DETAIL_OPTION), d]),
                None => argv.extend([s("-u"), s(DETAIL_OPTION)]),
            }
            argv
        }
        HookAction::WaitingKeepDetail { detail } => {
            let mut argv = state_args(Status::Waiting, pane, now_ms).unwrap_or_default();
            let detail = sanitize_detail(detail);
            if !detail.is_empty() {
                argv.extend(
                    [";", "set-option", "-p", "-o", "-t", pane, DETAIL_OPTION]
                        .iter()
                        .map(|v| s(v)),
                );
                argv.push(detail);
            }
            argv
        }
        HookAction::Clear => clear_args(pane),
        HookAction::SettleIdle | HookAction::Ignore => Vec::new(),
    }
}

/// The two commands that write the state word and its time. `None` for
/// a status a hook can't report.
fn state_args(status: Status, pane: &str, now_ms: u64) -> Option<Vec<String>> {
    let word = status_word(status)?;
    let mut argv: Vec<String> = ["set-option", "-p", "-t", pane, STATE_OPTION, word, ";"]
        .iter()
        .map(|v| v.to_string())
        .collect();
    argv.extend(
        ["set-option", "-p", "-t", pane, AT_OPTION]
            .iter()
            .map(|v| v.to_string()),
    );
    argv.push(now_ms.to_string());
    Some(argv)
}

/// tmux argv that unsets all three state options on `target`.
pub fn clear_args(target: &str) -> Vec<String> {
    let mut argv = Vec::new();
    for (i, opt) in [STATE_OPTION, AT_OPTION, DETAIL_OPTION].iter().enumerate() {
        if i > 0 {
            argv.push(";".to_string());
        }
        argv.extend(
            ["set-option", "-p", "-u", "-t", target, opt]
                .iter()
                .map(|s| s.to_string()),
        );
    }
    argv
}

/// Keep the detail a short single line: no control characters, no `|`
/// (the `list-sessions` field separator is `|||`), bounded length.
fn sanitize_detail(detail: &str) -> String {
    let cleaned: String = detail
        .chars()
        .map(|c| match c {
            '|' => '/',
            c if c.is_control() => ' ',
            c => c,
        })
        .collect();
    let cleaned = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.chars().count() <= MAX_DETAIL_CHARS {
        cleaned
    } else {
        let mut out: String = cleaned.chars().take(MAX_DETAIL_CHARS - 1).collect();
        out.push('…');
        out
    }
}

fn run_tmux(socket: &str, argv: &[String]) {
    if argv.is_empty() {
        return;
    }
    let _ = std::process::Command::new("tmux")
        .arg("-S")
        .arg(socket)
        .args(argv)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

/// Read the hook payload. A terminal on stdin means someone ran the
/// command by hand, so don't block waiting for input.
fn read_stdin() -> Vec<u8> {
    let mut stdin = std::io::stdin();
    if stdin.is_terminal() {
        return Vec::new();
    }
    let mut buf = Vec::new();
    let _ = stdin.read_to_end(&mut buf);
    buf
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// `BOSUN_HOOK_LOG=<file>` appends one line per hook invocation, for
/// checking which events an agent actually fires. Off unless set.
fn log_invocation(agent: &str, event: &str, action: &HookAction, now: u64) {
    let Some(path) = std::env::var_os("BOSUN_HOOK_LOG") else {
        return;
    };
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let pane = std::env::var("TMUX_PANE").unwrap_or_default();
        let _ = writeln!(f, "{now} {pane} {agent} {event} {action:?}");
    }
}

/// How a session's status was decided on this poll.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum StatusSource {
    /// Guessed by the detectors from the pane title and contents.
    #[default]
    Detector,
    /// Reported by the agent through a hook.
    Hook,
}

/// Everything [`resolve`] looks at besides the hook state itself.
pub struct ResolveInput<'a> {
    pub agent: Option<&'a str>,
    pub pane_title: Option<&'a str>,
    pub pane_command: Option<&'a str>,
    /// Claude's detector sees a permission or question prompt in the
    /// bottom of the pane right now. Only Claude's: the generic
    /// detector's Waiting just means the pane has been quiet a while.
    pub prompt_on_screen: bool,
    /// Claude's spinner line (`✶ Photosynthesizing… (1m 49s …)`) or a
    /// spinner title is on screen, in a capture taken after the hook
    /// report. Claude-only, like `prompt_on_screen`.
    pub working_on_screen: bool,
    /// Claude shows the Esc interrupt line (`⎿ Interrupted · …`), in a
    /// capture taken after the hook report.
    pub interrupted_on_screen: bool,
    /// Milliseconds since the pane last produced output.
    pub quiet_ms: u64,
    pub now_ms: u64,
}

/// Decide whether the hook state wins this poll. `Some(status)` means
/// it does (and the caller should skip hysteresis: the agent said so);
/// `None` means fall back to the detectors.
///
/// The detectors stay as a cross-check for what hooks can't see:
///
///   * The agent exited to a shell: whatever it last reported is stale.
///   * Claude fires no hook when you interrupt it with Esc, so a
///     `running` state can outlive the turn. Its interrupt line on
///     screen (with no spinner line under it) hands the row back to
///     the detector. The pane title can't be used for this: Claude
///     2.1.30x keeps its ✳ title while it works.
///   * A `done` or `idle` report while Claude's spinner line is on
///     screen is stale: another Stop hook (the user's own) can make
///     Claude carry on after Bosun's Stop hook said done, with no
///     prompt-submit hook to say it started again.
///   * A `running` pane that has been quiet for a minute is stale for
///     the same kind of reason (an API error or crash with no hook).
///   * Parallel tool calls can fire `PreToolUse` for one tool while
///     another's permission prompt is on screen; when Claude's detector
///     positively sees a prompt, it wins over `running`. (Only Claude's:
///     the generic detector calls any pane quiet for a few seconds
///     Waiting, which says nothing about a prompt.)
///   * A `waiting` state whose agent visibly resumed (spinner title)
///     missed the event that ended the wait.
pub fn resolve(hook: Option<&HookState>, input: &ResolveInput<'_>) -> Option<Status> {
    let hook = hook?;
    if input.pane_command.is_some_and(is_shell_command) {
        return None;
    }
    // The screen cross-checks read Claude's own UI, so only Claude
    // sessions get them.
    let claude = input.agent == Some("claude");
    let title_signal = if claude { input.pane_title } else { None };
    let working = claude && input.working_on_screen;
    let age = input.now_ms.saturating_sub(hook.at_ms);
    match hook.status {
        Status::Running => {
            if claude && input.prompt_on_screen {
                return None;
            }
            if input.quiet_ms >= RUNNING_QUIET_STALE_MS {
                return None;
            }
            if claude && input.interrupted_on_screen && !working {
                return None;
            }
            Some(Status::Running)
        }
        Status::Waiting => {
            if age >= RUNNING_TITLE_GRACE_MS
                && (working || title_signal.is_some_and(title_is_working))
            {
                return None;
            }
            Some(Status::Waiting)
        }
        Status::Done | Status::Idle => {
            if working {
                return None;
            }
            Some(hook.status)
        }
        Status::Error | Status::Unknown => None,
    }
}

/// A login shell, i.e. the agent has exited back to the prompt.
pub fn is_shell_command(cmd: &str) -> bool {
    matches!(
        cmd.trim_start_matches('-'),
        "zsh" | "bash" | "fish" | "sh" | "dash" | "ksh" | "tcsh" | "csh" | "nu" | "pwsh"
    )
}

/// Paths and flags the launch command needs to install hooks. Built
/// once when the actor starts (it writes the Claude settings file) and
/// passed to the launch-command builder.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LaunchHooks {
    /// Bosun-owned Claude settings file holding the hooks, passed as
    /// `--settings <file>`. `None` when hooks are off or the file
    /// couldn't be written.
    pub claude_settings: Option<PathBuf>,
}

impl LaunchHooks {
    /// No hooks: the launch command is exactly what it was before
    /// hooks existed.
    pub fn none() -> Self {
        Self::default()
    }

    /// Write the per-agent hook files under `dir` for `bosun_bin` and
    /// return the flags that point at them. Failures leave that agent
    /// without hooks (its detector still works) and are logged.
    pub fn prepare(dir: &Path, bosun_bin: &Path) -> Self {
        let claude_settings = match claude::write_settings_file(dir, bosun_bin) {
            Ok(p) => Some(p),
            Err(e) => {
                tracing::warn!("agent hooks: could not write claude settings: {e}");
                None
            }
        };
        Self { claude_settings }
    }
}

/// Directory Bosun keeps its generated hook files in: `hooks/` under the
/// same data dir as `bosun.db`.
pub fn hooks_dir() -> Option<PathBuf> {
    directories::ProjectDirs::from("dev", "yetidevworks", "bosun")
        .map(|d| d.data_dir().join("hooks"))
}

/// Absolute path of the running bosun binary, preferring a `PATH` entry
/// that resolves to the same file. A Homebrew install runs from a
/// versioned `Cellar/` path that disappears on upgrade, while its
/// `bin/` symlink stays put, so the symlink is the better thing to bake
/// into hook commands that outlive this process.
pub fn bosun_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let real = std::fs::canonicalize(&exe).unwrap_or_else(|_| exe.clone());
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join("bosun");
            if candidate.is_absolute() && std::fs::canonicalize(&candidate).is_ok_and(|c| c == real)
            {
                return Some(candidate);
            }
        }
    }
    Some(exe)
}

/// Shell-quote one argument for a command line typed into a pane or run
/// by `sh -c`. Plain words pass through untouched so the common case
/// stays readable.
pub fn shell_quote(s: &str) -> String {
    let plain = !s.is_empty()
        && s.chars().all(|c| {
            c.is_ascii_alphanumeric()
                || matches!(c, '/' | '.' | '_' | '-' | '+' | ':' | ',' | '@' | '=')
        });
    if plain {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

/// Unset the hook state on a session's active pane, so a relaunch
/// starts clean even if the previous agent died without its
/// end-of-session hook. Best effort.
pub fn clear_session_state(socket: Option<&str>, session: &str) {
    let mut cmd = std::process::Command::new("tmux");
    if let Some(s) = socket {
        cmd.arg("-L").arg(s);
    }
    let _ = cmd
        .args(clear_args(session))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tmux_target_takes_socket_from_first_field() {
        assert_eq!(
            tmux_target(Some("/private/tmp/tmux-501/bosun,1234,0"), Some("%7")),
            Some(("/private/tmp/tmux-501/bosun".into(), "%7".into()))
        );
    }

    #[test]
    fn tmux_target_needs_both_vars() {
        assert_eq!(tmux_target(None, Some("%1")), None);
        assert_eq!(tmux_target(Some("/tmp/s,1,0"), None), None);
        assert_eq!(tmux_target(Some(""), Some("%1")), None);
        assert_eq!(tmux_target(Some("/tmp/s,1,0"), Some("bogus")), None);
    }

    #[test]
    fn set_args_write_all_three_options_in_one_call() {
        let argv = tmux_args(
            &HookAction::set_with(Status::Waiting, "permission: Bash"),
            "%3",
            42,
        );
        assert_eq!(
            argv.join(" "),
            "set-option -p -t %3 @bosun_state waiting ; set-option -p -t %3 @bosun_state_at 42 ; set-option -p -t %3 @bosun_state_detail permission: Bash"
        );
    }

    #[test]
    fn waiting_keep_detail_writes_the_detail_only_if_unset() {
        let argv = tmux_args(
            &HookAction::WaitingKeepDetail {
                detail: "permission".into(),
            },
            "%3",
            42,
        );
        assert_eq!(
            argv.join(" "),
            "set-option -p -t %3 @bosun_state waiting ; set-option -p -t %3 @bosun_state_at 42 ; set-option -p -o -t %3 @bosun_state_detail permission"
        );
        let argv = tmux_args(
            &HookAction::WaitingKeepDetail { detail: " ".into() },
            "%3",
            42,
        );
        assert_eq!(
            argv.join(" "),
            "set-option -p -t %3 @bosun_state waiting ; set-option -p -t %3 @bosun_state_at 42"
        );
    }

    #[test]
    fn set_without_detail_unsets_it() {
        let argv = tmux_args(&HookAction::set(Status::Running), "%3", 42);
        assert!(argv.ends_with(&["-u".into(), DETAIL_OPTION.into()]));
    }

    #[test]
    fn clear_unsets_everything() {
        let argv = tmux_args(&HookAction::Clear, "%3", 42);
        assert_eq!(
            argv.join(" "),
            "set-option -p -u -t %3 @bosun_state ; set-option -p -u -t %3 @bosun_state_at ; set-option -p -u -t %3 @bosun_state_detail"
        );
    }

    #[test]
    fn ignore_and_settle_produce_no_direct_write() {
        assert!(tmux_args(&HookAction::Ignore, "%3", 1).is_empty());
        assert!(tmux_args(&HookAction::SettleIdle, "%3", 1).is_empty());
    }

    #[test]
    fn detail_is_sanitized_and_bounded() {
        assert_eq!(sanitize_detail("a|||b\nc"), "a///b c");
        let long = "x".repeat(200);
        assert_eq!(sanitize_detail(&long).chars().count(), MAX_DETAIL_CHARS);
    }

    #[test]
    fn hook_state_parses_list_sessions_fields() {
        assert_eq!(
            HookState::parse("waiting", "1700000000000", "permission: Bash"),
            Some(HookState {
                status: Status::Waiting,
                at_ms: 1_700_000_000_000,
                detail: Some("permission: Bash".into()),
            })
        );
        assert_eq!(HookState::parse("", "", ""), None);
        assert_eq!(HookState::parse("running", "", ""), None);
        assert_eq!(HookState::parse("bogus", "1", ""), None);
        assert_eq!(
            HookState::parse("done", "5", "").unwrap().detail,
            None,
            "an empty detail is no detail"
        );
    }

    fn hook(status: Status, at_ms: u64) -> HookState {
        HookState {
            status,
            at_ms,
            detail: None,
        }
    }

    fn input<'a>(
        title: Option<&'a str>,
        cmd: Option<&'a str>,
        detected: Status,
    ) -> ResolveInput<'a> {
        ResolveInput {
            agent: Some("claude"),
            pane_title: title,
            pane_command: cmd,
            prompt_on_screen: detected == Status::Waiting,
            working_on_screen: detected == Status::Running,
            interrupted_on_screen: false,
            quiet_ms: 0,
            now_ms: 100_000,
        }
    }

    #[test]
    fn no_hook_state_falls_back_to_detector() {
        assert_eq!(resolve(None, &input(None, None, Status::Idle)), None);
    }

    #[test]
    fn fresh_hook_state_wins_over_detector() {
        let h = hook(Status::Running, 99_500);
        // Detector thinks it's idle (no spinner caught yet); hook wins.
        assert_eq!(
            resolve(
                Some(&h),
                &input(Some("✳ task"), Some("2_1_301"), Status::Idle)
            ),
            Some(Status::Running)
        );
        let h = hook(Status::Done, 1_000);
        assert_eq!(
            resolve(
                Some(&h),
                &input(Some("✳ task"), Some("2_1_301"), Status::Idle)
            ),
            Some(Status::Done),
            "done never goes stale on its own"
        );
        let h = hook(Status::Waiting, 1_000);
        assert_eq!(
            resolve(
                Some(&h),
                &input(Some("✳ task"), Some("2_1_301"), Status::Idle)
            ),
            Some(Status::Waiting),
            "a long wait for permission is still a wait"
        );
    }

    #[test]
    fn esc_interrupt_line_retires_running() {
        // Running written 10s ago; the user hit Esc (no Stop hook fires)
        // and Claude shows its interrupt line.
        let h = hook(Status::Running, 90_000);
        let mut i = input(Some("✳ task"), Some("2.1.301"), Status::Idle);
        i.interrupted_on_screen = true;
        assert_eq!(resolve(Some(&h), &i), None);
        // A new turn's spinner under an old interrupt line: still running.
        i.working_on_screen = true;
        assert_eq!(resolve(Some(&h), &i), Some(Status::Running));
    }

    #[test]
    fn a_resting_title_doesnt_retire_running() {
        // Claude 2.1.30x keeps its ✳ title while it works, so the title
        // says nothing about a turn ending.
        let h = hook(Status::Running, 90_000);
        for title in ["✳ grav", "hades-2.local", "claude", ""] {
            assert_eq!(
                resolve(Some(&h), &input(Some(title), Some("2.1.301"), Status::Idle)),
                Some(Status::Running),
                "{title:?}"
            );
        }
    }

    #[test]
    fn done_with_the_spinner_line_on_screen_is_stale() {
        // The user's own Stop hook made Claude carry on after Bosun's
        // Stop hook reported done; no hook says it started again.
        for state in [Status::Done, Status::Idle] {
            let h = hook(state, 50_000);
            assert_eq!(
                resolve(
                    Some(&h),
                    &input(Some("✳ grav"), Some("2.1.301"), Status::Running)
                ),
                None,
                "{state:?}"
            );
            assert_eq!(
                resolve(
                    Some(&h),
                    &input(Some("✳ grav"), Some("2.1.301"), Status::Idle)
                ),
                Some(state)
            );
        }
    }

    #[test]
    fn title_cross_check_is_claude_only() {
        let h = hook(Status::Running, 90_000);
        let mut i = input(Some("codex"), Some("node"), Status::Idle);
        i.agent = Some("codex");
        assert_eq!(resolve(Some(&h), &i), Some(Status::Running));
    }

    #[test]
    fn running_on_a_quiet_pane_is_stale() {
        let h = hook(Status::Running, 90_000);
        let mut i = input(None, Some("2_1_301"), Status::Idle);
        i.quiet_ms = RUNNING_QUIET_STALE_MS;
        assert_eq!(resolve(Some(&h), &i), None);
    }

    #[test]
    fn exited_agent_ignores_hook_state() {
        for state in [Status::Running, Status::Waiting, Status::Done, Status::Idle] {
            let h = hook(state, 99_900);
            assert_eq!(
                resolve(Some(&h), &input(None, Some("zsh"), Status::Idle)),
                None,
                "{state:?}"
            );
        }
        assert!(is_shell_command("-zsh"));
        assert!(!is_shell_command("2_1_301"));
        assert!(!is_shell_command("node"));
    }

    #[test]
    fn detector_prompt_beats_running() {
        let h = hook(Status::Running, 99_900);
        assert_eq!(
            resolve(
                Some(&h),
                &input(Some("⠙ task"), Some("2_1_301"), Status::Waiting)
            ),
            None
        );
        // Another agent's detector Waiting is just "quiet for a bit".
        let mut i = input(None, Some("node"), Status::Waiting);
        i.agent = Some("codex");
        assert_eq!(resolve(Some(&h), &i), Some(Status::Running));
    }

    #[test]
    fn waiting_that_visibly_resumed_falls_back() {
        let h = hook(Status::Waiting, 90_000);
        assert_eq!(
            resolve(
                Some(&h),
                &input(Some("⠙ task"), Some("2_1_301"), Status::Running)
            ),
            None
        );
    }

    #[test]
    fn shell_quote_leaves_plain_paths_alone() {
        assert_eq!(shell_quote("/usr/local/bin/bosun"), "/usr/local/bin/bosun");
        assert_eq!(
            shell_quote("/Users/a/Library/Application Support/x.json"),
            "'/Users/a/Library/Application Support/x.json'"
        );
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
    }
}
