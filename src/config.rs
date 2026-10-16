//! Runtime configuration. Values are read once at startup and passed
//! around by value, so the rest of the code never touches `std::env`
//! or the config file on disk.
//!
//! Sources, in order of precedence (lowest to highest):
//!   1. Built-in defaults.
//!   2. `$XDG_CONFIG_HOME/bosun/config.toml` (`~/Library/Application
//!      Support/dev.yetidevworks.bosun/config.toml` on macOS).
//!   3. Environment variables (`BOSUN_PREFIX`, `BOSUN_TMUX_SOCKET`,
//!      `BOSUN_THEME`).
//!
//! Env vars always win. A missing or malformed config file is
//! non-fatal — we log a warning and fall through to defaults.

use std::env;
use std::path::PathBuf;

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};

use crate::sidebar::{Container, Section, SidebarModel};

/// Legacy Vec<SidebarEntry> shape from v0.2.8. Read-only, used for
/// one-time migration to the new explicit-membership `SidebarModel`.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum LegacySidebarEntry {
    Section { id: String, name: String },
    Session { internal: String },
}

fn migrate_legacy_sidebar(old: Vec<LegacySidebarEntry>) -> SidebarModel {
    // Pre-0.2.9 membership was implicit (session belongs to the
    // nearest section above). The new model is explicit — creating a
    // section claims no one. Safest upgrade: put every session in
    // ungrouped and preserve section headers as empty. The user can
    // then populate them with Shift-Right.
    let mut model = SidebarModel::default();
    for e in old {
        match e {
            LegacySidebarEntry::Section { id, name } => {
                model.sections.push(Section {
                    id,
                    name,
                    members: Vec::new(),
                    collapsed: false,
                    banner_font: None,
                });
            }
            LegacySidebarEntry::Session { internal } => {
                model
                    .ungrouped
                    .push(Container::single(internal.clone(), internal));
            }
        }
    }
    model
}

/// The default prefix that bosun considers "managed". Only tmux
/// sessions whose name starts with this prefix appear in bosun's UI
/// and get the bosun status bar applied. Set `BOSUN_PREFIX=` (empty)
/// to see every session on the server.
pub const DEFAULT_SESSION_PREFIX: &str = "bosun-";

/// Default tmux `-L <socket>` that bosun uses. Putting bosun on its
/// own socket means bosun's tmux server is a **child of the bosun
/// process**, which inherits whatever shell context bosun was
/// launched from — critically, including the macOS Keychain lineage
/// that lets Claude Code see its cached credentials. With the default
/// socket, bosun's sessions would live on some ancient server started
/// by some other context and Claude wouldn't see the user's auth.
///
/// Set `BOSUN_TMUX_SOCKET=default` to opt back into the shared
/// default socket (at the cost of the auth issue and of seeing every
/// other tmux session on the machine).
pub const DEFAULT_TMUX_SOCKET: &str = "bosun";

/// Default theme name — must match a built-in in `ui::theme`.
pub const DEFAULT_THEME: &str = "opencode";

/// Every agent the new-session form can launch, in the order its
/// selector cycles through them. Canonical list: the UI reads it for
/// the selector and `default_agent` validates against it, so adding an
/// agent here is enough for both.
pub const AGENTS: &[&str] = &["claude", "codex", "kimi", "opencode", "qwen", "terminal"];

/// Whether a session row is dropped from the sidebar once its tmux
/// session goes away. Off by default: the row keeps its place so `R`
/// can restart it, and losing a grouped layout is worse than leaving a
/// row labelled "exited".
pub const DEFAULT_REMOVE_DEAD_SESSIONS: bool = false;

/// Agent preselected when creating a session unless overridden in
/// `config.toml` with `default_agent`.
pub const DEFAULT_AGENT: &str = "claude";

/// A `theme_light` / `theme_dark` value: blank means unset ("same as
/// `theme`"), the same as leaving the key out.
fn optional_theme(name: Option<String>) -> Option<String> {
    name.map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
}

/// Turn the raw `[env]` table into the variables passed to every new
/// session. Names must be shell-valid (`[A-Za-z_][A-Za-z0-9_]*`) since
/// tmux splits `-e KEY=VALUE` at the first `=`. Strings pass through
/// as-is; numbers and booleans are stringified. `BOSUN` is reserved for
/// the marker bosun sets itself. Anything else is dropped with a warning
/// rather than failing the whole config.
fn session_env(
    raw: std::collections::BTreeMap<String, toml::Value>,
) -> std::collections::BTreeMap<String, String> {
    let mut env = std::collections::BTreeMap::new();
    for (key, value) in raw {
        let valid_name = key
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !valid_name {
            tracing::warn!(key = %key, "ignoring [env] entry with an invalid variable name");
            continue;
        }
        if key == "BOSUN" {
            tracing::warn!("ignoring [env] BOSUN; bosun always sets BOSUN=1 itself");
            continue;
        }
        let value = match value {
            toml::Value::String(s) => s,
            toml::Value::Integer(i) => i.to_string(),
            toml::Value::Float(f) => f.to_string(),
            toml::Value::Boolean(b) => b.to_string(),
            _ => {
                tracing::warn!(key = %key, "ignoring [env] entry that is not a string, number or boolean");
                continue;
            }
        };
        env.insert(key, value);
    }
    env
}

fn default_agent(value: Option<String>) -> String {
    let Some(value) = value else {
        return DEFAULT_AGENT.to_string();
    };
    let value = value.trim().to_ascii_lowercase();
    if AGENTS.contains(&value.as_str()) {
        value
    } else {
        tracing::warn!(
            configured_agent = %value,
            default_agent = DEFAULT_AGENT,
            "ignoring invalid default agent in config"
        );
        DEFAULT_AGENT.to_string()
    }
}

/// Where a new git worktree is placed relative to its repo root.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum WorktreeLocation {
    /// `<repo>/.worktrees/<branch>` — self-contained inside the repo.
    #[default]
    Subdir,
    /// `<repo>-<branch>` — a sibling directory next to the repo.
    Sibling,
}

#[derive(Debug, Clone)]
pub struct Config {
    /// Only sessions whose name starts with this prefix are shown in
    /// bosun's UI and get the bosun status bar applied. Empty string
    /// means "show everything".
    pub session_prefix: String,
    /// Tmux `-L` socket name. `None` means use tmux's default socket.
    /// `Some("bosun")` (the default) means `tmux -L bosun ...`.
    pub tmux_socket: Option<String>,
    /// Name of the tmux session bosun is currently running inside,
    /// if any. `None` if bosun was launched outside tmux. We exclude
    /// this session from bosun's own list so the preview doesn't
    /// capture bosun itself (which would create a visual feedback
    /// loop: bosun renders a preview of itself, which shows bosun
    /// rendering a preview of itself, etc).
    pub self_session: Option<String>,
    /// Theme name. Resolved against user themes first, then
    /// built-ins (`opencode`, `tokyonight`), then a hard-fallback.
    pub theme: String,
    /// Optional theme for the macOS Light appearance (`theme_light`).
    /// Only Bosun for Mac reads it, through `bosun serve`: the TUI
    /// can't tell the system appearance, so it always uses `theme`.
    /// `None` means "same as `theme`".
    pub theme_light: Option<String>,
    /// Optional theme for the macOS Dark appearance (`theme_dark`).
    /// See `theme_light`.
    pub theme_dark: Option<String>,
    /// Persisted divider position (absolute terminal column). `None`
    /// means use the default 38% split.
    pub divider_x: Option<u16>,
    /// User-defined sidebar ordering with explicit section
    /// membership. Empty on first launch. Persisted as the
    /// `[sidebar]` table in `config.toml` so ordering and group
    /// structure survive bosun restarts.
    pub sidebar: SidebarModel,
    /// Map from session display name → last-known section name.
    /// When a session is killed/restarted or a recent is opened,
    /// the new session is placed back into that section if one with
    /// the same name still exists. Persisted as `[session_history]`.
    pub session_history: std::collections::HashMap<String, String>,
    /// Global TDF banner font used for the section/empty preview
    /// banner. Per-section overrides live on `Section.banner_font`.
    /// Persisted in `config.toml` as `banner_font = "metalix"`.
    pub banner_font: String,
    /// External editor command launched by the `e` key on a highlighted
    /// session — bosun runs `<editor> <session_path>` detached. `None`
    /// means "no editor configured"; pressing `e` warns in the status
    /// bar. Set via `bosun editor <cmd>` or directly in `config.toml`
    /// as `editor = "zed"` (or `code`, `subl`, `nvim`, ...).
    pub editor: Option<String>,
    /// Fast preview tick (milliseconds): how often the tmux actor
    /// re-captures the *focused* session's pane to push a fresh
    /// preview to the UI. Independent of the 1Hz full-refresh tick
    /// that updates the session list + status detectors + statusbar.
    /// Default 200ms (5 fps) keeps the preview perceptually live for
    /// the cost of one `capture-pane` per tick. 0 disables the fast
    /// tick (falls back to v0.x behavior — preview only updates on
    /// full refresh). Override with `preview_tick_ms = 250` in
    /// `config.toml` or `BOSUN_PREVIEW_TICK_MS=300` in the env.
    pub preview_tick_ms: u64,
    /// Frame-rate cap for the UI's repaints, in frames per second.
    /// Default 60. `0` means uncapped — every event that changes the
    /// screen repaints the instant it lands, which is what bosun did
    /// before 2.1.12.
    ///
    /// Every byte an embedded session writes is an event, so a pane
    /// that scrolls continuously — a build, an agent streaming a long
    /// answer — drove the draw loop as fast as bosun could paint, and
    /// a full repaint is not cheap (issue #16). The cap doesn't slow
    /// the steady state so much as collapse bursts: chunks arriving
    /// within a frame of each other become one repaint instead of
    /// five. At 60fps that costs at most ~16ms — less than one
    /// refresh of a 60Hz display — and took a pathological case from
    /// ~20% of a core to ~4%. Raise it if you want, or set `0` to
    /// turn pacing off entirely. Set `max_fps = 0` in `config.toml`
    /// or `BOSUN_MAX_FPS=0` in the env.
    pub max_fps: u32,
    /// Embedded-terminal preview (2.0+): when true, the focused
    /// session's preview pane is a real `vt100`-parsed embedded
    /// terminal streaming from `tmux attach -r`, rather than a
    /// periodic `capture-pane` snapshot. Default true. Disable with
    /// `embed = false` in `config.toml` or `BOSUN_EMBED=0` /
    /// `BOSUN_EMBED=off` in the env to fall back to the v0.4 polled
    /// preview path. Non-focused sessions and section/empty-state
    /// previews are unaffected — they always use the polled path
    /// (they don't need a PTY).
    pub embed_enabled: bool,
    /// Single-window mode (2.0+): when true, `Enter` / `Right` on a
    /// session opens it *inside* the preview pane (focused embed)
    /// instead of tearing down ratatui and running a full-screen
    /// `tmux attach`. The sidebar stays visible the whole time.
    /// `Ctrl-Q` exits back to bosun navigation, same as it does
    /// from a real tmux attach. Default false (matches v0.4
    /// behavior). Toggled live with `s` and persisted to
    /// `config.toml` as `single_window = true`. Env override:
    /// `BOSUN_SINGLE_WINDOW=1|true|yes|on` enables, anything else
    /// disables.
    pub single_window_mode: bool,
    /// Sticky "hide the sidebar while focused on a session" preference
    /// (2.0.5+). Toggled live with `Ctrl+B` while the embed is
    /// focused; persisted to `config.toml` as `sidebar_hidden = true`.
    /// Only takes effect while focused — detaching always brings the
    /// sidebar back so the session list is reachable. Default false.
    pub sidebar_hidden: bool,
    /// When true, sessions that belong to a section render as
    /// `group/session` in the tab strip pills and the OSC terminal
    /// window title; ungrouped sessions stay bare. Display only — no
    /// persistence. Default false. Set `show_group_in_title = true` in
    /// `config.toml` or `BOSUN_SHOW_GROUP_IN_TITLE=1|true|yes|on`.
    pub show_group_in_title: bool,
    /// When true, the tab strip above the preview is only drawn for a
    /// row with more than one tab, and a single tab's name moves to the
    /// bottom status bar instead (issue #18). Default false. Set
    /// `hide_single_tab_strip = true` in `config.toml` or
    /// `BOSUN_HIDE_SINGLE_TAB_STRIP=1|true|yes|on`.
    pub hide_single_tab_strip: bool,
    /// Where `git worktree add` places new worktrees. See `WorktreeLocation`.
    pub worktree_location: WorktreeLocation,
    /// Agent preselected by the new-session form. Invalid or missing
    /// values fall back to `claude`.
    pub default_agent: String,
    /// Drop a session's sidebar row when its tmux session ends, rather
    /// than keeping it as an `exited` row that `R` can restart.
    pub remove_dead_sessions: bool,
    /// Exact shortcuts inside a focused session, loaded from [keybindings].
    pub keybindings: crate::keybindings::KeyBindings,
    /// Per-agent binary overrides from the `[agents]` table in
    /// `config.toml`, e.g. `opencode = "~/bin/opencode-wrapper"`.
    /// The value replaces the agent's binary in the launch command
    /// verbatim, so a wrapper script can fix up the environment
    /// before exec'ing the real binary. Missing entries fall back to
    /// the agent's own name resolved on the login-shell PATH.
    pub agent_binaries: std::collections::HashMap<String, String>,
    /// Extra environment variables for every new session's shell, from
    /// the `[env]` table in `config.toml`. Passed as `-e KEY=VALUE` on
    /// `new-session`, alongside the `BOSUN=1` marker bosun always sets.
    /// File-only, like `[agents]`. Entries with an invalid name, a
    /// `BOSUN` key, or a non-scalar value are dropped with a warning.
    pub session_env: std::collections::BTreeMap<String, String>,
    /// Let agents report their own state through hooks instead of
    /// leaving it all to the pane-scraping detectors. Bosun installs the
    /// hooks only through the launch command (for Claude Code, a
    /// `--settings` file in Bosun's data dir), never by editing the
    /// agent's own config, so it takes effect on a session's next launch
    /// or restart. Default true. Set `agent_hooks = false` in
    /// `config.toml` or `BOSUN_AGENT_HOOKS=0|false|off|no` to turn it off.
    pub agent_hooks: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            session_prefix: DEFAULT_SESSION_PREFIX.to_string(),
            tmux_socket: Some(DEFAULT_TMUX_SOCKET.to_string()),
            self_session: None,
            theme: DEFAULT_THEME.to_string(),
            theme_light: None,
            theme_dark: None,
            divider_x: None,
            sidebar: SidebarModel::default(),
            session_history: std::collections::HashMap::new(),
            banner_font: crate::ui::banner::default_name().to_string(),
            editor: None,
            preview_tick_ms: DEFAULT_PREVIEW_TICK_MS,
            max_fps: DEFAULT_MAX_FPS,
            embed_enabled: DEFAULT_EMBED_ENABLED,
            // v2.0.2+: focused single-window mode is the only mode.
            // The field is retained as `true` for callers that still
            // gate on it, but it is no longer user-toggleable or
            // persisted.
            single_window_mode: true,
            sidebar_hidden: false,
            show_group_in_title: DEFAULT_SHOW_GROUP_IN_TITLE,
            hide_single_tab_strip: DEFAULT_HIDE_SINGLE_TAB_STRIP,
            worktree_location: WorktreeLocation::default(),
            default_agent: DEFAULT_AGENT.to_string(),
            remove_dead_sessions: DEFAULT_REMOVE_DEAD_SESSIONS,
            keybindings: crate::keybindings::KeyBindings::default(),
            agent_binaries: std::collections::HashMap::new(),
            session_env: std::collections::BTreeMap::new(),
            agent_hooks: DEFAULT_AGENT_HOOKS,
        }
    }
}

/// Default for `Config::agent_hooks`: on, so hook-capable agents report
/// their own state out of the box.
pub const DEFAULT_AGENT_HOOKS: bool = true;

/// Default frame-rate cap. 60fps bounds what a chatty pane can cost
/// while staying under one refresh of a 60Hz display, so it reads as
/// immediate. `0` disables pacing. See `Config::max_fps`.
pub const DEFAULT_MAX_FPS: u32 = 60;

/// Default fast preview tick in milliseconds. 200ms = 5 fps on the
/// focused session's preview pane. See `Config::preview_tick_ms`.
pub const DEFAULT_PREVIEW_TICK_MS: u64 = 200;

/// Default for `Config::embed_enabled`. v2.0+ ships with the
/// embedded-terminal preview on; set to false here to invert the
/// default if early adopters report regressions.
pub const DEFAULT_EMBED_ENABLED: bool = true;

/// Default for `Config::show_group_in_title`. Off by default so the
/// tab pills and OSC title look unchanged for existing users until they
/// opt in via `show_group_in_title = true` or `BOSUN_SHOW_GROUP_IN_TITLE=1`.
pub const DEFAULT_SHOW_GROUP_IN_TITLE: bool = false;

/// Default for `Config::hide_single_tab_strip`. Off, so every row keeps
/// its tab strip until the user opts in.
pub const DEFAULT_HIDE_SINGLE_TAB_STRIP: bool = false;

/// Shape of `config.toml` on disk. All fields are optional and
/// defaulted independently so a half-written file still loads.
/// `Serialize` is used by `write_theme` to round-trip the file on
/// disk: read → update one field → write.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
struct ConfigFile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    keybindings: Option<crate::keybindings::BindingsConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session_prefix: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tmux_socket: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    theme: Option<String>,
    /// The Mac app's Light/Dark pair. See `Config::theme_light`. Kept
    /// here so every read-modify-write of the file carries them along.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    theme_light: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    theme_dark: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    divider_x: Option<u16>,
    /// Explicit-membership sidebar (v0.2.9+). Tables + arrays.
    /// `read_config_file` preprocesses the raw TOML so a legacy v0.2.8
    /// `sidebar = [...]` array is migrated in-place to the new shape
    /// before this field is deserialized.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sidebar: Option<SidebarModel>,
    /// Last-known section name per display name. Used to restore
    /// group membership across kill/restart/recents flows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session_history: Option<std::collections::HashMap<String, String>>,
    /// Legacy pre-0.2.8 flat list of internal names. Read-only for
    /// migration; never written back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session_order: Option<Vec<String>>,
    /// Global TDF banner font name (e.g. `"metalix"`). When absent,
    /// `Config::load` falls back to `banner::default_name()`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    banner_font: Option<String>,
    /// External editor command for the `e`-key launch. `None` means
    /// unset; `e` will warn until the user configures one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    editor: Option<String>,
    /// Fast preview tick in milliseconds. See `Config::preview_tick_ms`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    preview_tick_ms: Option<u64>,
    /// Repaint frame-rate cap. See `Config::max_fps`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    max_fps: Option<u32>,
    /// Embedded-terminal preview opt-out. See `Config::embed_enabled`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    embed: Option<bool>,
    /// Single-window mode persistence. See `Config::single_window_mode`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    single_window: Option<bool>,
    /// Sticky hide-sidebar-while-focused preference. See
    /// `Config::sidebar_hidden`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sidebar_hidden: Option<bool>,
    /// Group-in-title opt-in. See `Config::show_group_in_title`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    show_group_in_title: Option<bool>,
    /// Hide the tab strip on single-tab rows. See
    /// `Config::hide_single_tab_strip`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    hide_single_tab_strip: Option<bool>,
    /// Worktree placement scheme. See `Config::worktree_location`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    worktree_location: Option<WorktreeLocation>,
    /// Agent preselected by the new-session form. Must be one of
    /// `claude`, `codex`, `kimi`, `opencode`, `qwen`, or `terminal`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    default_agent: Option<String>,
    /// See `Config::remove_dead_sessions`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    remove_dead_sessions: Option<bool>,
    /// Per-agent binary overrides. See `Config::agent_binaries`.
    /// Persisted as the `[agents]` table:
    /// ```toml
    /// [agents]
    /// opencode = "/Users/me/bin/opencode-wrapper"
    /// ```
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agents: Option<std::collections::HashMap<String, String>>,
    /// Extra session environment. See `Config::session_env`.
    /// Persisted as the `[env]` table:
    /// ```toml
    /// [env]
    /// OPENCODE_CLI_CONFIG_CONTENT = '{"tabs":{"mode":"off"}}'
    /// ```
    /// Values are kept as raw TOML so a number or boolean written
    /// without quotes still loads instead of failing the whole file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    env: Option<std::collections::BTreeMap<String, toml::Value>>,
    /// Hook-reported agent state. See `Config::agent_hooks`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agent_hooks: Option<bool>,
}

impl Config {
    /// Full load path: defaults → config.toml → env vars. See the
    /// module-level doc comment for the precedence order.
    pub fn load() -> Self {
        let file = read_config_file().unwrap_or_default();

        let session_prefix = env::var("BOSUN_PREFIX")
            .ok()
            .or(file.session_prefix)
            .unwrap_or_else(|| DEFAULT_SESSION_PREFIX.to_string());

        let tmux_socket = match env::var("BOSUN_TMUX_SOCKET") {
            Ok(s) if s.is_empty() || s == "default" => None,
            Ok(s) => Some(s),
            Err(_) => match file.tmux_socket.as_deref() {
                Some("") | Some("default") => None,
                Some(s) => Some(s.to_string()),
                None => Some(DEFAULT_TMUX_SOCKET.to_string()),
            },
        };

        let theme = env::var("BOSUN_THEME")
            .ok()
            .or(file.theme)
            .unwrap_or_else(|| DEFAULT_THEME.to_string());
        let theme_light = optional_theme(file.theme_light);
        let theme_dark = optional_theme(file.theme_dark);

        // Only detect self-session if we're on the same socket as
        // the caller's tmux. If bosun uses a dedicated socket, the
        // parent tmux (if any) is on a different server and bosun
        // isn't "inside" any session on its own socket.
        let self_session = if tmux_socket.is_none() {
            detect_self_session()
        } else {
            None
        };

        let divider_x = file.divider_x;
        // Prefer the new `sidebar` field (explicit-membership model).
        // If absent, migrate the pre-0.2.8 flat `session_order` list.
        // Legacy v0.2.8 `sidebar = [...]` arrays are migrated by
        // `read_config_file` before we get here.
        let sidebar = match file.sidebar {
            Some(s) => s,
            None => {
                let ungrouped = file
                    .session_order
                    .unwrap_or_default()
                    .into_iter()
                    .map(|n| Container::single(n.clone(), n))
                    .collect();
                SidebarModel {
                    ungrouped,
                    sections: Vec::new(),
                }
            }
        };

        let session_history = file.session_history.unwrap_or_default();
        let banner_font = file
            .banner_font
            .unwrap_or_else(|| crate::ui::banner::default_name().to_string());
        // Editor is intentionally not env-overridable. It's a persistent
        // user preference, not a per-session knob, and putting it on
        // $EDITOR would conflict with the conventional terminal-editor
        // meaning ($EDITOR is usually `vim` / `nvim` — not what a user
        // wants the `e` key to spawn against a project path).
        let editor = file.editor.filter(|e| !e.trim().is_empty());

        // Env var wins over config file, both win over the default.
        // Parse failure of either falls through silently to the next
        // source — bad values shouldn't brick startup.
        let preview_tick_ms = env::var("BOSUN_PREVIEW_TICK_MS")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .or(file.preview_tick_ms)
            .unwrap_or(DEFAULT_PREVIEW_TICK_MS);

        // Same precedence for the repaint cap. 0 means no cap at all
        // — see `Config::max_fps`.
        let max_fps = env::var("BOSUN_MAX_FPS")
            .ok()
            .and_then(|s| s.parse::<u32>().ok())
            .or(file.max_fps)
            .unwrap_or(DEFAULT_MAX_FPS);

        // Embed opt-out: accept `0`, `false`, `off`, `no` (case-
        // insensitive) as disable; anything else as enable. Mirrors
        // the conventional shell-flag idiom. Env beats file beats
        // default.
        let embed_enabled = match env::var("BOSUN_EMBED") {
            Ok(s) => !matches!(
                s.trim().to_ascii_lowercase().as_str(),
                "0" | "false" | "off" | "no"
            ),
            Err(_) => file.embed.unwrap_or(DEFAULT_EMBED_ENABLED),
        };

        // v2.0.2+: focused single-window is the only mode. The
        // setting is no longer user-toggleable; we keep the field
        // wired as `true` for code paths that gate on it.
        let single_window_mode = true;

        // Sticky preference only — no env override. It's flipped at
        // runtime via Ctrl+B and read back on next launch.
        let sidebar_hidden = file.sidebar_hidden.unwrap_or(false);

        // Group-in-title opt-in. Same enable/disable idiom as
        // BOSUN_EMBED, except an empty value (`BOSUN_SHOW_GROUP_IN_TITLE=`)
        // disables here rather than enabling: this flag is off by
        // default, so a bare/empty set value should not silently flip it
        // on. Env beats file beats default.
        let show_group_in_title = match env::var("BOSUN_SHOW_GROUP_IN_TITLE") {
            Ok(s) => !matches!(
                s.trim().to_ascii_lowercase().as_str(),
                "" | "0" | "false" | "off" | "no"
            ),
            Err(_) => file
                .show_group_in_title
                .unwrap_or(DEFAULT_SHOW_GROUP_IN_TITLE),
        };

        // Same idiom as BOSUN_SHOW_GROUP_IN_TITLE: off by default, so an
        // empty value leaves it off.
        let hide_single_tab_strip = match env::var("BOSUN_HIDE_SINGLE_TAB_STRIP") {
            Ok(s) => !matches!(
                s.trim().to_ascii_lowercase().as_str(),
                "" | "0" | "false" | "off" | "no"
            ),
            Err(_) => file
                .hide_single_tab_strip
                .unwrap_or(DEFAULT_HIDE_SINGLE_TAB_STRIP),
        };

        let worktree_location = file.worktree_location.unwrap_or_default();

        // Env beats file for these two, like the flags above. Bosun
        // rewrites config.toml as you use it (sidebar layout, divider,
        // and now every settings-panel row), so a setup that manages
        // its config declaratively — Nix home-manager and friends —
        // can't rely on the file staying put. An environment variable
        // is somewhere bosun never writes, so it holds. See issue #15.
        let default_agent = match env::var("BOSUN_DEFAULT_AGENT") {
            Ok(s) => default_agent(Some(s)),
            Err(_) => default_agent(file.default_agent),
        };
        // Same enable/disable idiom as BOSUN_SHOW_GROUP_IN_TITLE: this
        // is off by default, so an empty value disables rather than
        // silently enabling.
        let remove_dead_sessions = match env::var("BOSUN_REMOVE_DEAD_SESSIONS") {
            Ok(s) => !matches!(
                s.trim().to_ascii_lowercase().as_str(),
                "" | "0" | "false" | "off" | "no"
            ),
            Err(_) => file
                .remove_dead_sessions
                .unwrap_or(DEFAULT_REMOVE_DEAD_SESSIONS),
        };

        let keybindings = file
            .keybindings
            .unwrap_or_default()
            .resolve()
            .unwrap_or_else(|e| {
                tracing::warn!("invalid [keybindings]: {e}; using default shortcuts");
                crate::keybindings::KeyBindings::default()
            });
        let agent_binaries = file.agents.unwrap_or_default();
        let session_env = session_env(file.env.unwrap_or_default());
        // On by default, so it follows BOSUN_EMBED's idiom: only an
        // explicit off value disables it.
        let agent_hooks = match env::var("BOSUN_AGENT_HOOKS") {
            Ok(s) => !matches!(
                s.trim().to_ascii_lowercase().as_str(),
                "0" | "false" | "off" | "no"
            ),
            Err(_) => file.agent_hooks.unwrap_or(DEFAULT_AGENT_HOOKS),
        };

        Self {
            session_prefix,
            tmux_socket,
            self_session,
            theme,
            theme_light,
            theme_dark,
            divider_x,
            sidebar,
            session_history,
            banner_font,
            editor,
            preview_tick_ms,
            max_fps,
            embed_enabled,
            single_window_mode,
            sidebar_hidden,
            show_group_in_title,
            hide_single_tab_strip,
            worktree_location,
            default_agent,
            remove_dead_sessions,
            keybindings,
            agent_binaries,
            session_env,
            agent_hooks,
        }
    }

    /// Back-compat shim for callers that only want env-driven config.
    /// Retained so tests and a few internal paths don't need to
    /// touch the filesystem.
    pub fn from_env() -> Self {
        Self::load()
    }

    /// Does `name` pass the managed-session filter?
    pub fn manages(&self, name: &str) -> bool {
        // Never manage the session bosun is running in — that causes
        // the recursive preview feedback loop.
        if self.self_session.as_deref() == Some(name) {
            return false;
        }
        self.session_prefix.is_empty() || name.starts_with(&self.session_prefix)
    }
}

/// Location of bosun's config directory. Same `ProjectDirs` entry
/// the SQLite store uses, so `config.toml` lives alongside
/// `bosun.db` on macOS.
pub fn config_dir() -> Option<PathBuf> {
    ProjectDirs::from("dev", "yetidevworks", "bosun").map(|d| d.config_dir().to_path_buf())
}

/// Where user-defined themes live — one `.toml` per theme, file name
/// without extension is the theme name.
pub fn user_themes_dir() -> Option<PathBuf> {
    config_dir().map(|d| d.join("themes"))
}

fn read_config_file() -> Option<ConfigFile> {
    read_config_file_at(&config_dir()?.join("config.toml"))
}

fn read_config_file_at(path: &std::path::Path) -> Option<ConfigFile> {
    let s = std::fs::read_to_string(path).ok()?;

    // Parse as a generic Value first so we can detect + migrate the
    // legacy v0.2.8 `sidebar = [...]` array shape. The v0.2.9 shape
    // is a `[sidebar]` table, so a sidebar Value that's an Array is
    // unambiguously the old form.
    let mut value: toml::Value = match toml::from_str(&s) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("failed to parse {:?}: {}", path, e);
            return None;
        }
    };

    if let Some(table) = value.as_table_mut() {
        if let Some(sidebar) = table.get("sidebar") {
            if sidebar.is_array() {
                let cloned = sidebar.clone();
                match cloned.try_into::<Vec<LegacySidebarEntry>>() {
                    Ok(legacy) => {
                        let migrated = migrate_legacy_sidebar(legacy);
                        match toml::Value::try_from(&migrated) {
                            Ok(v) => {
                                table.insert("sidebar".to_string(), v);
                            }
                            Err(e) => {
                                tracing::warn!("failed to serialize migrated sidebar: {}", e);
                                table.remove("sidebar");
                            }
                        }
                    }
                    Err(e) => {
                        tracing::warn!("failed to parse legacy sidebar: {}", e);
                        table.remove("sidebar");
                    }
                }
            }
        }
    }

    match value.try_into::<ConfigFile>() {
        Ok(f) => Some(f),
        Err(e) => {
            tracing::warn!("failed to deserialize {:?}: {}", path, e);
            None
        }
    }
}

/// Persist a new theme choice to `config.toml`. Read-modify-write:
/// existing file fields are preserved, only `theme` is updated. If
/// the file doesn't exist it's created. Returns `Err` if the config
/// dir can't be resolved or writing fails — callers (the theme
/// picker) surface this as a warning in the status bar but still
/// apply the change to the live UI.
/// Environment variable that pins a given setting, if one is set.
///
/// Env beats file for these, and bosun never writes to the environment
/// — which is the point for setups that manage config declaratively
/// (issue #15). The settings panel uses this to mark a row as pinned
/// rather than letting the user change something that would snap back
/// on the next launch.
pub fn env_pin(setting: &str) -> Option<&'static str> {
    let var = match setting {
        "theme" => "BOSUN_THEME",
        "default_agent" => "BOSUN_DEFAULT_AGENT",
        "remove_dead_sessions" => "BOSUN_REMOVE_DEAD_SESSIONS",
        "show_group_in_title" => "BOSUN_SHOW_GROUP_IN_TITLE",
        "hide_single_tab_strip" => "BOSUN_HIDE_SINGLE_TAB_STRIP",
        "embed_enabled" => "BOSUN_EMBED",
        "agent_hooks" => "BOSUN_AGENT_HOOKS",
        _ => return None,
    };
    std::env::var(var).ok().map(|_| var)
}

/// Read `config.toml`, hand the parsed form to `edit`, and write it
/// back atomically (temp file + rename, so a kill mid-write can't
/// leave a truncated config). Fields we don't touch survive because
/// the whole file round-trips through `ConfigFile`.
///
/// The older `write_*` functions each spell this out inline; new ones
/// go through here.
fn update_config_file(edit: impl FnOnce(&mut ConfigFile)) -> std::io::Result<()> {
    let dir =
        config_dir().ok_or_else(|| std::io::Error::other("cannot resolve bosun config dir"))?;
    std::fs::create_dir_all(&dir)?;
    update_config_file_at(&dir.join("config.toml"), edit)
}

/// [`update_config_file`] against an explicit `config.toml` path.
fn update_config_file_at(
    path: &std::path::Path,
    edit: impl FnOnce(&mut ConfigFile),
) -> std::io::Result<()> {
    let mut file = match std::fs::read_to_string(path) {
        Ok(s) => toml::from_str::<ConfigFile>(&s).unwrap_or_default(),
        Err(_) => ConfigFile::default(),
    };
    edit(&mut file);

    let body = toml::to_string(&file)
        .map_err(|e| std::io::Error::other(format!("toml serialize: {e}")))?;

    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Persist the Mac app's Light-appearance theme. `None` removes the key
/// ("same as `theme`").
pub fn write_theme_light(name: Option<&str>) -> std::io::Result<()> {
    update_config_file(|f| f.theme_light = name.map(str::to_string))
}

/// Persist the Mac app's Dark-appearance theme. `None` removes the key.
pub fn write_theme_dark(name: Option<&str>) -> std::io::Result<()> {
    update_config_file(|f| f.theme_dark = name.map(str::to_string))
}

/// Persist the agent preselected by the new-session form.
pub fn write_default_agent(agent: &str) -> std::io::Result<()> {
    update_config_file(|f| f.default_agent = Some(agent.to_string()))
}

/// Persist whether an ended session keeps its sidebar row.
pub fn write_remove_dead_sessions(on: bool) -> std::io::Result<()> {
    update_config_file(|f| f.remove_dead_sessions = Some(on))
}

/// Persist whether grouped sessions show `group/session` in tab pills
/// and the terminal title.
pub fn write_show_group_in_title(on: bool) -> std::io::Result<()> {
    update_config_file(|f| f.show_group_in_title = Some(on))
}

/// Persist whether single-tab rows hide their tab strip.
pub fn write_hide_single_tab_strip(on: bool) -> std::io::Result<()> {
    update_config_file(|f| f.hide_single_tab_strip = Some(on))
}

/// Persist where `git worktree add` places new worktrees.
pub fn write_worktree_location(loc: WorktreeLocation) -> std::io::Result<()> {
    update_config_file(|f| f.worktree_location = Some(loc))
}

/// Persist whether agents report their state through hooks.
pub fn write_agent_hooks(on: bool) -> std::io::Result<()> {
    update_config_file(|f| f.agent_hooks = Some(on))
}

/// Persist whether the preview embeds a live terminal.
pub fn write_embed_enabled(on: bool) -> std::io::Result<()> {
    update_config_file(|f| f.embed = Some(on))
}

pub fn write_theme(name: &str) -> std::io::Result<()> {
    update_config_file(|f| f.theme = Some(name.to_string()))
}

/// Persist the sticky hide-sidebar-while-focused preference to
/// `config.toml`. Same read-modify-write approach as `write_theme`.
/// Called from the `Ctrl+B` toggle; failure is surfaced as a status
/// bar warning but the live toggle still applies.
pub fn write_sidebar_hidden(hidden: bool) -> std::io::Result<()> {
    let dir =
        config_dir().ok_or_else(|| std::io::Error::other("cannot resolve bosun config dir"))?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("config.toml");

    let mut file = match std::fs::read_to_string(&path) {
        Ok(s) => toml::from_str::<ConfigFile>(&s).unwrap_or_default(),
        Err(_) => ConfigFile::default(),
    };
    file.sidebar_hidden = Some(hidden);

    let body = toml::to_string(&file)
        .map_err(|e| std::io::Error::other(format!("toml serialize: {e}")))?;

    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// Persist the global banner font to `config.toml`. Same
/// read-modify-write approach as `write_theme`.
pub fn write_banner_font(name: &str) -> std::io::Result<()> {
    let dir =
        config_dir().ok_or_else(|| std::io::Error::other("cannot resolve bosun config dir"))?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("config.toml");

    let mut file = match std::fs::read_to_string(&path) {
        Ok(s) => toml::from_str::<ConfigFile>(&s).unwrap_or_default(),
        Err(_) => ConfigFile::default(),
    };
    file.banner_font = Some(name.to_string());

    let body = toml::to_string(&file)
        .map_err(|e| std::io::Error::other(format!("toml serialize: {e}")))?;

    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// Persist the editor command to `config.toml`. Pass `None` to clear
/// the field. Same read-modify-write approach as `write_theme` so
/// other fields survive intact.
pub fn write_editor(editor: Option<&str>) -> std::io::Result<()> {
    let dir =
        config_dir().ok_or_else(|| std::io::Error::other("cannot resolve bosun config dir"))?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("config.toml");

    let mut file = read_config_file().unwrap_or_default();
    file.editor = editor
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let body = toml::to_string(&file)
        .map_err(|e| std::io::Error::other(format!("toml serialize: {e}")))?;

    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// Persist the single-window-mode flag to `config.toml`. Same
/// read-modify-write approach as `write_theme`. Writes `None`
/// (skipped via `skip_serializing_if`) when the value is the
/// default-false so the file stays clean of redundant entries.
pub fn write_single_window(on: bool) -> std::io::Result<()> {
    let dir =
        config_dir().ok_or_else(|| std::io::Error::other("cannot resolve bosun config dir"))?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("config.toml");

    let mut file = match std::fs::read_to_string(&path) {
        Ok(s) => toml::from_str::<ConfigFile>(&s).unwrap_or_default(),
        Err(_) => ConfigFile::default(),
    };
    file.single_window = if on { Some(true) } else { None };

    let body = toml::to_string(&file)
        .map_err(|e| std::io::Error::other(format!("toml serialize: {e}")))?;
    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// Persist the divider position to `config.toml`. Same
/// read-modify-write approach as `write_theme`.
pub fn write_divider_x(x: Option<u16>) -> std::io::Result<()> {
    let dir =
        config_dir().ok_or_else(|| std::io::Error::other("cannot resolve bosun config dir"))?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("config.toml");

    let mut file = match std::fs::read_to_string(&path) {
        Ok(s) => toml::from_str::<ConfigFile>(&s).unwrap_or_default(),
        Err(_) => ConfigFile::default(),
    };
    file.divider_x = x;

    let body = toml::to_string(&file)
        .map_err(|e| std::io::Error::other(format!("toml serialize: {e}")))?;

    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// Persist the session-history map (display_name → section_name) to
/// `config.toml`. An empty map clears the field.
pub fn write_session_history(
    history: &std::collections::HashMap<String, String>,
) -> std::io::Result<()> {
    let dir =
        config_dir().ok_or_else(|| std::io::Error::other("cannot resolve bosun config dir"))?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("config.toml");

    let mut file = read_config_file().unwrap_or_default();
    file.session_history = if history.is_empty() {
        None
    } else {
        Some(history.clone())
    };

    let body = toml::to_string(&file)
        .map_err(|e| std::io::Error::other(format!("toml serialize: {e}")))?;

    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// Persist the user-defined sidebar (explicit-membership model) to
/// `config.toml`. Same read-modify-write approach as `write_theme`.
/// An empty model clears the field from the file. Also drops the
/// legacy `session_order` so the config converges on the new shape.
pub fn write_sidebar(model: &SidebarModel) -> std::io::Result<()> {
    let dir =
        config_dir().ok_or_else(|| std::io::Error::other("cannot resolve bosun config dir"))?;
    std::fs::create_dir_all(&dir)?;
    write_sidebar_at(&dir.join("config.toml"), model)
}

/// [`write_sidebar`] against an explicit `config.toml` path.
pub fn write_sidebar_at(path: &std::path::Path, model: &SidebarModel) -> std::io::Result<()> {
    // Read via the migrating reader so a pre-existing legacy sidebar
    // is converted before we overwrite it. Otherwise the first save
    // after a legacy read-through would wipe the user's groups.
    let mut file = read_config_file_at(path).unwrap_or_default();
    file.sidebar = if model.ungrouped.is_empty() && model.sections.is_empty() {
        None
    } else {
        Some(model.clone())
    };
    file.session_order = None;

    let body = toml::to_string(&file)
        .map_err(|e| std::io::Error::other(format!("toml serialize: {e}")))?;

    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Notices when another process changes the sidebar in `config.toml`.
///
/// The TUI keeps the sidebar model in memory and writes the whole thing
/// back on every edit, never re-reading the file. With a second process
/// editing the same layout (another TUI, or the Mac app's daemon), the
/// TUI's next save would silently revert the other's change. So before
/// applying a local edit the app polls this: a cheap `stat`, and only
/// when the file's mtime or size moved, a read and parse. The sidebar
/// found there is compared with the last one this process knows is on
/// disk (what it loaded or last wrote), so the TUI's own writes and
/// edits to unrelated settings never count as an external change.
#[derive(Debug)]
pub struct SidebarWatch {
    path: PathBuf,
    stamp: Option<(std::time::SystemTime, u64)>,
    disk: SidebarModel,
}

impl SidebarWatch {
    /// Watch `path`, starting from the sidebar that was loaded from it.
    pub fn new(path: PathBuf, loaded: &SidebarModel) -> Self {
        let stamp = file_stamp(&path);
        Self {
            path,
            stamp,
            disk: loaded.clone(),
        }
    }

    /// Watch bosun's own `config.toml`. `None` if the config dir can't
    /// be resolved.
    pub fn for_config_file(loaded: &SidebarModel) -> Option<Self> {
        Some(Self::new(config_dir()?.join("config.toml"), loaded))
    }

    /// Record a sidebar this process just wrote, so reading it back
    /// isn't mistaken for someone else's change.
    pub fn wrote(&mut self, model: &SidebarModel) {
        self.disk = model.clone();
        self.stamp = file_stamp(&self.path);
    }

    /// The sidebar another process wrote since the last check, if any.
    pub fn poll(&mut self) -> Option<SidebarModel> {
        let stamp = file_stamp(&self.path);
        if stamp == self.stamp {
            return None;
        }
        self.stamp = stamp;
        // A missing or unparseable file isn't a layout change; keep
        // what we have rather than wiping the sidebar.
        let file = read_config_file_at(&self.path)?;
        let model = file.sidebar.unwrap_or_default();
        if model == self.disk {
            return None;
        }
        self.disk = model.clone();
        Some(model)
    }
}

fn file_stamp(path: &std::path::Path) -> Option<(std::time::SystemTime, u64)> {
    let meta = std::fs::metadata(path).ok()?;
    Some((meta.modified().ok()?, meta.len()))
}

/// If `$TMUX` is set, ask tmux for the current session name. Used to
/// exclude bosun's own session from its list.
fn detect_self_session() -> Option<String> {
    if env::var("TMUX").is_err() {
        return None;
    }
    let out = std::process::Command::new("tmux")
        .args(["display-message", "-p", "#{session_name}"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keybindings_survive_unrelated_config_edits() {
        let mut config: ConfigFile =
            toml::from_str("[keybindings]\nnext_tab = 'Ctrl+Shift+Right'\nprevious_tab = 'none'")
                .unwrap();
        config.theme = Some("opencode".into());
        let serialized = toml::to_string(&config).unwrap();
        let reloaded: ConfigFile = toml::from_str(&serialized).unwrap();
        let keys = reloaded.keybindings.unwrap().resolve().unwrap();
        assert_eq!(
            keys.label(crate::keybindings::Action::PreviousTab),
            "disabled"
        );
        assert_eq!(
            keys.label(crate::keybindings::Action::NextTab),
            "Ctrl+Shift+Right"
        );
    }

    /// The TUI never reads the Mac app's Light/Dark pair, but every one
    /// of its writes goes through `ConfigFile`, so the pair has to
    /// survive them all.
    #[test]
    fn theme_pair_survives_tui_writes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "theme = 'nord'\ntheme_light = 'github-light'\ntheme_dark = 'tokyonight'\n",
        )
        .unwrap();
        // The theme picker, a settings-panel row, a sidebar save.
        update_config_file_at(&path, |f| f.theme = Some("dracula".into())).unwrap();
        update_config_file_at(&path, |f| f.remove_dead_sessions = Some(true)).unwrap();
        write_sidebar_at(&path, &SidebarModel::default()).unwrap();
        let file = read_config_file_at(&path).unwrap();
        assert_eq!(file.theme.as_deref(), Some("dracula"));
        assert_eq!(file.theme_light.as_deref(), Some("github-light"));
        assert_eq!(file.theme_dark.as_deref(), Some("tokyonight"));

        // Clearing one side removes its key and leaves the other.
        update_config_file_at(&path, |f| f.theme_light = None).unwrap();
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(!body.contains("theme_light"), "{body}");
        assert!(body.contains("theme_dark = \"tokyonight\""), "{body}");
    }

    #[test]
    fn theme_pair_parses_and_empty_means_unset() {
        let file: ConfigFile =
            toml::from_str("theme_light = 'one-light'\ntheme_dark = ''\n").unwrap();
        assert_eq!(file.theme_light.as_deref(), Some("one-light"));
        assert_eq!(
            optional_theme(file.theme_light).as_deref(),
            Some("one-light")
        );
        assert_eq!(optional_theme(file.theme_dark), None);
        let none: ConfigFile = toml::from_str("theme = 'nord'\n").unwrap();
        assert!(none.theme_light.is_none() && none.theme_dark.is_none());
    }

    fn cfg(prefix: &str) -> Config {
        Config {
            session_prefix: prefix.to_string(),
            tmux_socket: Some(DEFAULT_TMUX_SOCKET.to_string()),
            self_session: None,
            theme: DEFAULT_THEME.to_string(),
            theme_light: None,
            theme_dark: None,
            divider_x: None,
            sidebar: SidebarModel::default(),
            session_history: std::collections::HashMap::new(),
            banner_font: crate::ui::banner::default_name().to_string(),
            editor: None,
            preview_tick_ms: DEFAULT_PREVIEW_TICK_MS,
            max_fps: DEFAULT_MAX_FPS,
            embed_enabled: DEFAULT_EMBED_ENABLED,
            single_window_mode: false,
            sidebar_hidden: false,
            show_group_in_title: DEFAULT_SHOW_GROUP_IN_TITLE,
            hide_single_tab_strip: DEFAULT_HIDE_SINGLE_TAB_STRIP,
            worktree_location: WorktreeLocation::default(),
            default_agent: DEFAULT_AGENT.to_string(),
            remove_dead_sessions: DEFAULT_REMOVE_DEAD_SESSIONS,
            keybindings: crate::keybindings::KeyBindings::default(),
            agent_binaries: std::collections::HashMap::new(),
            session_env: std::collections::BTreeMap::new(),
            agent_hooks: DEFAULT_AGENT_HOOKS,
        }
    }

    fn model(names: &[&str]) -> SidebarModel {
        SidebarModel {
            ungrouped: names
                .iter()
                .map(|n| Container::single(n.to_string(), n.to_string()))
                .collect(),
            sections: Vec::new(),
        }
    }

    /// Bump the file's mtime past the last stamp even on filesystems
    /// with coarse timestamps.
    fn touch_later(path: &std::path::Path) {
        let later = std::time::SystemTime::now() + std::time::Duration::from_secs(5);
        let f = std::fs::File::options().write(true).open(path).unwrap();
        f.set_modified(later).unwrap();
    }

    #[test]
    fn sidebar_watch_ignores_own_writes_and_unrelated_edits() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let a = model(&["a"]);
        write_sidebar_at(&path, &a).unwrap();
        let mut watch = SidebarWatch::new(path.clone(), &a);
        assert_eq!(watch.poll(), None, "nothing changed");

        // Our own save.
        let ab = model(&["a", "b"]);
        write_sidebar_at(&path, &ab).unwrap();
        touch_later(&path);
        watch.wrote(&ab);
        assert_eq!(watch.poll(), None);

        // Another process changes the theme only.
        let body = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, format!("theme = \"nord\"\n{body}")).unwrap();
        touch_later(&path);
        assert_eq!(
            watch.poll(),
            None,
            "unrelated setting is not a layout change"
        );
    }

    #[test]
    fn sidebar_watch_reports_another_processes_layout() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let a = model(&["a"]);
        write_sidebar_at(&path, &a).unwrap();
        let mut watch = SidebarWatch::new(path.clone(), &a);

        // Someone else reorders and adds a row.
        let ca = model(&["c", "a"]);
        write_sidebar_at(&path, &ca).unwrap();
        touch_later(&path);
        assert_eq!(watch.poll(), Some(ca));
        // Reported once.
        assert_eq!(watch.poll(), None);

        // An unreadable file mid-edit isn't a layout change.
        std::fs::write(&path, "[[[ not toml").unwrap();
        touch_later(&path);
        assert_eq!(watch.poll(), None);
    }

    #[test]
    fn default_prefix_matches_bosun_sessions() {
        let c = cfg(DEFAULT_SESSION_PREFIX);
        assert!(c.manages("bosun-work"));
        assert!(c.manages("bosun-"));
        assert!(!c.manages("agentdeck-work"));
        assert!(!c.manages("main"));
    }

    #[test]
    fn empty_prefix_matches_everything() {
        let c = cfg("");
        assert!(c.manages("anything"));
        assert!(c.manages(""));
    }

    #[test]
    fn custom_prefix_matches_its_namespace() {
        let c = cfg("work-");
        assert!(c.manages("work-api"));
        assert!(!c.manages("bosun-api"));
    }

    #[test]
    fn self_session_is_excluded_even_when_prefix_matches() {
        let c = Config {
            session_prefix: DEFAULT_SESSION_PREFIX.to_string(),
            tmux_socket: None,
            self_session: Some("bosun-mine-abc".to_string()),
            theme: DEFAULT_THEME.to_string(),
            theme_light: None,
            theme_dark: None,
            divider_x: None,
            sidebar: SidebarModel::default(),
            session_history: std::collections::HashMap::new(),
            banner_font: crate::ui::banner::default_name().to_string(),
            editor: None,
            preview_tick_ms: DEFAULT_PREVIEW_TICK_MS,
            max_fps: DEFAULT_MAX_FPS,
            embed_enabled: DEFAULT_EMBED_ENABLED,
            single_window_mode: false,
            sidebar_hidden: false,
            show_group_in_title: DEFAULT_SHOW_GROUP_IN_TITLE,
            hide_single_tab_strip: DEFAULT_HIDE_SINGLE_TAB_STRIP,
            worktree_location: WorktreeLocation::default(),
            default_agent: DEFAULT_AGENT.to_string(),
            remove_dead_sessions: DEFAULT_REMOVE_DEAD_SESSIONS,
            keybindings: crate::keybindings::KeyBindings::default(),
            agent_binaries: std::collections::HashMap::new(),
            session_env: std::collections::BTreeMap::new(),
            agent_hooks: DEFAULT_AGENT_HOOKS,
        };
        assert!(!c.manages("bosun-mine-abc"));
        assert!(c.manages("bosun-other-xyz"));
    }

    #[test]
    fn default_agent_accepts_opencode_and_falls_back_to_claude() {
        assert_eq!(default_agent(Some("opencode".to_string())), "opencode");
        assert_eq!(default_agent(None), DEFAULT_AGENT);
        assert_eq!(default_agent(Some("unknown".to_string())), DEFAULT_AGENT);
    }

    /// Validation reads `AGENTS`, so a newly added agent is
    /// automatically a valid `default_agent` — no second list to keep
    /// in sync.
    #[test]
    fn every_agent_is_a_valid_default() {
        for agent in AGENTS {
            assert_eq!(default_agent(Some((*agent).to_string())), *agent);
        }
    }

    #[test]
    fn default_agent_tolerates_case_and_whitespace() {
        assert_eq!(default_agent(Some("  OpenCode \n".to_string())), "opencode");
    }

    #[test]
    fn config_file_fields_parse() {
        let src = r#"
            session_prefix = "work-"
            tmux_socket = "scratch"
            theme = "tokyonight"
        "#;
        let parsed: ConfigFile = toml::from_str(src).unwrap();
        assert_eq!(parsed.session_prefix.as_deref(), Some("work-"));
        assert_eq!(parsed.tmux_socket.as_deref(), Some("scratch"));
        assert_eq!(parsed.theme.as_deref(), Some("tokyonight"));
    }

    #[test]
    fn empty_config_file_is_all_defaults() {
        let parsed: ConfigFile = toml::from_str("").unwrap();
        assert!(parsed.session_prefix.is_none());
        assert!(parsed.tmux_socket.is_none());
        assert!(parsed.theme.is_none());
    }

    #[test]
    fn editor_field_parses() {
        let parsed: ConfigFile = toml::from_str(r#"editor = "zed""#).unwrap();
        assert_eq!(parsed.editor.as_deref(), Some("zed"));
    }

    #[test]
    fn show_group_in_title_defaults_off() {
        assert!(!Config::default().show_group_in_title);
    }

    #[test]
    fn hide_single_tab_strip_defaults_off() {
        assert!(!Config::default().hide_single_tab_strip);
    }

    #[test]
    fn env_table_parses_and_normalizes() {
        let src = r#"
            [env]
            OPENCODE_CLI_CONFIG_CONTENT = '{"tabs":{"mode":"off"}}'
            RETRIES = 3
            VERBOSE = true
            _PRIVATE = "x"
        "#;
        let parsed: ConfigFile = toml::from_str(src).unwrap();
        let env = session_env(parsed.env.unwrap());
        assert_eq!(
            env.get("OPENCODE_CLI_CONFIG_CONTENT").map(String::as_str),
            Some(r#"{"tabs":{"mode":"off"}}"#)
        );
        assert_eq!(env.get("RETRIES").map(String::as_str), Some("3"));
        assert_eq!(env.get("VERBOSE").map(String::as_str), Some("true"));
        assert_eq!(env.get("_PRIVATE").map(String::as_str), Some("x"));
    }

    #[test]
    fn env_table_drops_invalid_entries() {
        let src = r#"
            [env]
            BOSUN = "0"
            "1BAD" = "x"
            "HAS=EQ" = "x"
            "has space" = "x"
            LIST = ["a", "b"]
            GOOD = "ok"
        "#;
        let parsed: ConfigFile = toml::from_str(src).unwrap();
        let env = session_env(parsed.env.unwrap());
        assert_eq!(env.len(), 1);
        assert_eq!(env.get("GOOD").map(String::as_str), Some("ok"));
    }

    #[test]
    fn env_table_absent_is_empty() {
        let parsed: ConfigFile = toml::from_str("").unwrap();
        assert!(parsed.env.is_none());
        assert!(Config::default().session_env.is_empty());
    }

    #[test]
    fn worktree_location_parses_and_defaults() {
        let parsed: ConfigFile = toml::from_str(r#"worktree_location = "sibling""#).unwrap();
        assert_eq!(parsed.worktree_location, Some(WorktreeLocation::Sibling));
        let empty: ConfigFile = toml::from_str("").unwrap();
        assert_eq!(empty.worktree_location, None);
        // Default when unset.
        assert_eq!(WorktreeLocation::default(), WorktreeLocation::Subdir);
    }
}
