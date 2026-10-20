//! Pure parsers for tmux CLI output. No I/O, no allocations we can avoid.
//! Every parser gets unit-tested against fixtures in `#[cfg(test)]` so the
//! shell-out layer (`client.rs`) can stay thin.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::error::{BosunError, Result};
use crate::tmux::session::TmuxSession;

/// The format string we pass to `tmux list-sessions -F`. Fields are
/// separated by the printable sequence `|||`. We can't use a control
/// character (like `\x1f`) because tmux 3.4+ escapes all control
/// characters in format output as octal sequences (`\037` for 0x1f)
/// as a security measure against terminal-injection via session
/// names — that broke the Ubuntu CI job, which ships tmux 3.4. `|||`
/// is printable ASCII, so tmux passes it through unmodified, and
/// three pipes is vanishingly unlikely to appear in a real session
/// name, display name, or filesystem path.
///
/// The trailing `@bosun_*` fields read user options we set at create time:
/// - `@bosun_display`       — pretty UI name (e.g. "rasterfox" for internal `bosun-rasterfox-a1b2c3d4`)
/// - `@bosun_agent`         — agent kind (claude / codex / terminal)
/// - `@bosun_path`          — spec path the user typed into the new-session modal
/// - `@bosun_container_id`  — sidebar container this session belongs to (tabs feature)
/// - `@bosun_worktree_path` — git worktree backing this session (worktree feature)
/// - `@bosun_branch`        — branch checked out in that worktree (worktree feature)
///
/// All six are empty strings for non-bosun sessions and get parsed as
/// `None` so the UI renders them only when available.
///
/// The final two fields are tmux's own view of the active pane, and are
/// what the status detectors prefer over scraping the pane body:
/// - `pane_title`           — the OSC title the app set. Claude Code writes
///   `<glyph> <task>`, braille while working and `✳` when not, and only
///   rewrites it on a state change — so unlike the pane body it doesn't
///   churn frame-by-frame.
/// - `pane_current_command` — the running process. Claude Code renames
///   itself to its version (`2_1_220`), so this separates a live agent
///   from a bare `zsh`.
///
/// The last four are pane user options an agent's hooks write through
/// `bosun hook` (see `agent_hooks`): the state it reported, when, an
/// optional detail, and how many background agents its turn is waiting
/// on. tmux resolves them against the session's active
/// pane, the same pane `pane_title` describes. Empty when no hook has
/// run.
pub const LIST_SESSIONS_FORMAT: &str = "#{session_name}|||#{session_windows}|||#{session_attached}|||#{session_created}|||#{session_activity}|||#{session_path}|||#{@bosun_display}|||#{@bosun_agent}|||#{@bosun_path}|||#{@bosun_container_id}|||#{@bosun_worktree_path}|||#{@bosun_branch}|||#{pane_width}|||#{pane_title}|||#{pane_current_command}|||#{@bosun_state}|||#{@bosun_state_at}|||#{@bosun_state_detail}|||#{@bosun_background}";

const FIELD_SEP: &str = "|||";

/// The `list-sessions -F` format for `bosun serve`'s 250 ms status poll:
/// only what a hook-reported status depends on (see
/// `agent_hooks::resolve`). Every field costs the tmux server time on
/// each of the four polls a second, and the full
/// [`LIST_SESSIONS_FORMAT`] costs it about 40 % more than this one
/// (`list-panes -a` with the same fields costs more again: it walks
/// every pane, the monitor session's included).
pub const STATUS_POLL_FORMAT: &str = "#{session_name}|||#{session_activity}|||#{@bosun_agent}|||#{pane_title}|||#{pane_current_command}|||#{@bosun_state}|||#{@bosun_state_at}|||#{@bosun_state_detail}|||#{@bosun_background}";

/// Parse `tmux list-sessions -F <STATUS_POLL_FORMAT>` output. Only the
/// fields that format reads are filled in (name, activity, agent, pane
/// title and command, hook state); everything else is left at its
/// empty value, so these rows are for working out a status and nothing
/// else.
pub fn parse_status_rows(input: &str) -> Result<Vec<TmuxSession>> {
    let mut out = Vec::new();
    for (idx, line) in input.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split(FIELD_SEP).collect();
        let [name, activity, agent, title, command, state, at, detail, background] = f[..] else {
            return Err(BosunError::Parse(format!(
                "status row {}: expected 9 fields, got {} — raw: {:?}",
                idx + 1,
                f.len(),
                line
            )));
        };
        let some = |v: &str| (!v.is_empty()).then(|| v.to_string());
        out.push(TmuxSession {
            name: name.to_string(),
            display_name: None,
            windows: 0,
            attached: false,
            created: None,
            last_activity: parse_epoch(activity),
            current_path: None,
            agent: some(agent),
            spec_path: None,
            container_id: None,
            worktree_path: None,
            branch: None,
            pane_width: 0,
            pane_title: some(title),
            pane_command: some(command),
            hook: crate::agent_hooks::HookState::parse(state, at, detail, background),
        });
    }
    Ok(out)
}

/// Parse the full `tmux list-sessions -F <LIST_SESSIONS_FORMAT>` output.
/// One session per line; empty input is valid (no sessions).
pub fn parse_list_sessions(input: &str) -> Result<Vec<TmuxSession>> {
    let mut out = Vec::new();
    for (idx, line) in input.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        out.push(parse_session_line(line).map_err(|e| {
            // Include the raw line (with control chars debug-escaped so
            // the ASCII-31 `\x1f` separators are visible) in the error —
            // when this fires on CI the message tells us exactly what
            // tmux output instead of leaving us guessing.
            BosunError::Parse(format!("line {}: {} — raw: {:?}", idx + 1, e, line))
        })?);
    }
    Ok(out)
}

fn parse_session_line(line: &str) -> std::result::Result<TmuxSession, String> {
    let mut parts = line.split(FIELD_SEP);

    let name = parts
        .next()
        .ok_or_else(|| "missing session name".to_string())?
        .to_string();
    let windows_raw = parts
        .next()
        .ok_or_else(|| "missing session_windows".to_string())?;
    let attached_raw = parts
        .next()
        .ok_or_else(|| "missing session_attached".to_string())?;
    let created_raw = parts
        .next()
        .ok_or_else(|| "missing session_created".to_string())?;
    let activity_raw = parts
        .next()
        .ok_or_else(|| "missing session_activity".to_string())?;
    let path = parts.next().map(|s| s.to_string());
    let display_raw = parts.next().map(|s| s.to_string());
    // `@bosun_agent`, `@bosun_path`, and `@bosun_container_id` are
    // optional trailing fields — older tmux list-sessions outputs
    // (from before we added them to LIST_SESSIONS_FORMAT) may not
    // include them, and fixtures in tests sometimes omit them for
    // brevity.
    let agent_raw = parts.next().map(|s| s.to_string());
    let spec_path_raw = parts.next().map(|s| s.to_string());
    let container_id_raw = parts.next().map(|s| s.to_string());
    // Worktree path and branch (worktree feature). Optional trailing
    // fields for the same back-compat reasons as the other `@bosun_*`
    // options above — older outputs and terse fixtures omit them.
    let worktree_path_raw = parts.next().map(|s| s.to_string());
    let branch_raw = parts.next().map(|s| s.to_string());
    // Current pane width. Used to tell a genuine content change from a
    // mere reflow (resize / embed / a second bosun instance attaching),
    // so a layout change doesn't read as unread. Optional trailing
    // field: older outputs and terse test fixtures omit it → 0.
    let pane_width_raw = parts.next();
    // Pane title + running command. Both are first-party state signals
    // the agent TUI publishes about itself, far steadier than scraping
    // the pane body. Optional trailing fields for the same back-compat
    // reasons as the fields above.
    let pane_title_raw = parts.next().map(|s| s.to_string());
    let pane_command_raw = parts.next().map(|s| s.to_string());
    // Agent-reported state from `bosun hook`. Optional trailing fields;
    // empty (unset) on panes whose agent has no hooks.
    let hook_state_raw = parts.next().unwrap_or("");
    let hook_at_raw = parts.next().unwrap_or("");
    let hook_detail_raw = parts.next().unwrap_or("");
    let hook_background_raw = parts.next().unwrap_or("");

    if parts.next().is_some() {
        return Err("unexpected extra field".into());
    }

    let windows: u32 = windows_raw
        .parse()
        .map_err(|e| format!("session_windows '{}': {}", windows_raw, e))?;

    let attached = match attached_raw {
        "0" => false,
        "1" => true,
        // tmux gives the attached-client count; >0 means attached.
        other => other.parse::<u32>().map(|n| n > 0).unwrap_or(false),
    };

    let created = parse_epoch(created_raw);
    let last_activity = parse_epoch(activity_raw);
    let pane_width: u16 = pane_width_raw.and_then(|s| s.parse().ok()).unwrap_or(0);

    Ok(TmuxSession {
        name,
        windows,
        attached,
        created,
        last_activity,
        current_path: path.filter(|p| !p.is_empty()),
        display_name: display_raw.filter(|s| !s.is_empty()),
        agent: agent_raw.filter(|s| !s.is_empty()),
        spec_path: spec_path_raw.filter(|s| !s.is_empty()),
        container_id: container_id_raw.filter(|s| !s.is_empty()),
        worktree_path: worktree_path_raw.filter(|s| !s.is_empty()),
        branch: branch_raw.filter(|s| !s.is_empty()),
        pane_width,
        pane_title: pane_title_raw.filter(|s| !s.is_empty()),
        pane_command: pane_command_raw.filter(|s| !s.is_empty()),
        hook: crate::agent_hooks::HookState::parse(
            hook_state_raw,
            hook_at_raw,
            hook_detail_raw,
            hook_background_raw,
        ),
    })
}

fn parse_epoch(s: &str) -> Option<SystemTime> {
    if s.is_empty() {
        return None;
    }
    let secs: u64 = s.parse().ok()?;
    Some(UNIX_EPOCH + Duration::from_secs(secs))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_empty_input() {
        assert!(parse_list_sessions("").unwrap().is_empty());
    }

    #[test]
    fn status_rows_carry_the_status_inputs() {
        let rows = parse_status_rows(
            "bosun-a-1|||1792130862|||claude|||⠙ Fix it|||2_1_301|||waiting|||1792130862123|||permission: Bash|||\n\
             bosun-b-2|||1792130800|||||||||zsh||||||||||||\n\
             bosun-c-3|||1792130800|||claude|||✳ Build|||2_1_303|||running|||1792130862123||||||2\n",
        )
        .unwrap();
        assert_eq!(rows.len(), 3);
        let a = &rows[0];
        assert_eq!(a.name, "bosun-a-1");
        assert_eq!(
            a.last_activity,
            Some(UNIX_EPOCH + Duration::from_secs(1792130862))
        );
        assert_eq!(a.agent.as_deref(), Some("claude"));
        assert_eq!(a.pane_title.as_deref(), Some("⠙ Fix it"));
        assert_eq!(a.pane_command.as_deref(), Some("2_1_301"));
        let hook = a.hook.as_ref().unwrap();
        assert_eq!(hook.status, crate::tmux::detector::Status::Waiting);
        assert_eq!(hook.at_ms, 1792130862123);
        assert_eq!(hook.detail.as_deref(), Some("permission: Bash"));
        let b = &rows[1];
        assert_eq!((b.agent.as_ref(), b.pane_title.as_ref()), (None, None));
        assert_eq!(b.pane_command.as_deref(), Some("zsh"));
        assert!(b.hook.is_none());
        let c = rows[2].hook.as_ref().unwrap();
        assert_eq!((c.detail.as_deref(), c.background), (None, 2));
        // The format and the parser agree on the field count.
        assert_eq!(STATUS_POLL_FORMAT.split(FIELD_SEP).count(), 9);
        assert!(parse_status_rows("bosun-a|||1").is_err());
    }

    #[test]
    fn parses_single_session() {
        let line = "main|||3|||1|||1712000000|||1712003600|||/tmp/code";
        let sessions = parse_list_sessions(line).unwrap();
        assert_eq!(sessions.len(), 1);
        let s = &sessions[0];
        assert_eq!(s.name, "main");
        assert_eq!(s.windows, 3);
        assert!(s.attached);
        assert_eq!(s.current_path.as_deref(), Some("/tmp/code"));
        assert!(s.created.is_some());
        assert!(s.last_activity.is_some());
    }

    #[test]
    fn parses_pane_width() {
        // Full format including the two worktree fields and the trailing
        // pane_width field (pane_width stays last after the insert).
        let line =
            "main|||1|||1|||1712000000|||1712003600|||/tmp|||Main|||claude|||/tmp|||cid|||/wt|||br|||128";
        let s = &parse_list_sessions(line).unwrap()[0];
        assert_eq!(s.pane_width, 128);
    }

    #[test]
    fn missing_pane_width_defaults_to_zero() {
        // Terse fixtures / older tmux output omit the field.
        let line = "main|||1|||1|||1712000000|||1712003600|||/tmp";
        let s = &parse_list_sessions(line).unwrap()[0];
        assert_eq!(s.pane_width, 0);
    }

    #[test]
    fn parses_pane_title_and_command() {
        // A real line off `tmux -L bosun list-sessions`, spinner glyph
        // and all — the title is what the Claude detector reads to
        // decide Running vs Idle.
        let line = concat!(
            "main|||1|||1|||1712000000|||1712003600|||/tmp|||Main|||claude|||/tmp|||cid|||/wt|||br",
            "|||95|||⠐ Ensure forum-pro CSS works|||2_1_220"
        );
        let s = &parse_list_sessions(line).unwrap()[0];
        assert_eq!(s.pane_width, 95);
        assert_eq!(
            s.pane_title.as_deref(),
            Some("⠐ Ensure forum-pro CSS works")
        );
        assert_eq!(s.pane_command.as_deref(), Some("2_1_220"));
    }

    #[test]
    fn parses_hook_state_fields() {
        let line = "bosun-a|||1|||0|||1700000000|||1700000100|||/tmp|||a|||claude|||/tmp|||c1|||||||||80|||✳ task|||2_1_301|||waiting|||1700000100123|||permission: Bash";
        let s = &parse_list_sessions(line).unwrap()[0];
        let hook = s.hook.as_ref().expect("hook state");
        assert_eq!(hook.status, crate::tmux::detector::Status::Waiting);
        assert_eq!(hook.at_ms, 1_700_000_100_123);
        assert_eq!(hook.detail.as_deref(), Some("permission: Bash"));
        assert_eq!(hook.background, 0, "no background count from older output");
        assert_eq!(s.pane_command.as_deref(), Some("2_1_301"));
        let line = "bosun-a|||1|||0|||1700000000|||1700000100|||/tmp|||a|||claude|||/tmp|||c1|||||||||80|||✳ task|||2_1_303|||running|||1700000100123||||||1";
        let hook = parse_list_sessions(line).unwrap()[0].hook.clone().unwrap();
        assert_eq!(
            (hook.status, hook.background),
            (crate::tmux::detector::Status::Running, 1)
        );
    }

    #[test]
    fn unset_hook_options_are_no_hook_state() {
        let line = "bosun-a|||1|||0|||1700000000|||1700000100|||/tmp|||a|||claude|||/tmp|||c1|||||||||80|||✳ task|||2_1_301|||||||||";
        let s = &parse_list_sessions(line).unwrap()[0];
        assert_eq!(s.hook, None);
        // Older output without the trailing fields parses too.
        let line = "bosun-a|||1|||0|||1700000000|||1700000100|||/tmp|||a|||claude|||/tmp|||c1|||||||||80|||✳ task|||2_1_301";
        assert_eq!(parse_list_sessions(line).unwrap()[0].hook, None);
    }

    #[test]
    fn missing_pane_title_and_command_default_to_none() {
        // Back-compat: terse fixtures stop at pane_width.
        let line =
            "main|||1|||1|||1712000000|||1712003600|||/tmp|||Main|||claude|||/tmp|||cid|||/wt|||br|||95";
        let s = &parse_list_sessions(line).unwrap()[0];
        assert_eq!(s.pane_title, None);
        assert_eq!(s.pane_command, None);
    }

    #[test]
    fn empty_pane_title_is_none_not_blank() {
        // A pane that never set a title yields an empty field; that's
        // "unknown", not a title of "".
        let line = concat!(
            "main|||1|||1|||1712000000|||1712003600|||/tmp|||Main|||claude|||/tmp|||cid|||/wt|||br",
            "|||95||||||zsh"
        );
        let s = &parse_list_sessions(line).unwrap()[0];
        assert_eq!(s.pane_title, None);
        assert_eq!(s.pane_command.as_deref(), Some("zsh"));
    }

    #[test]
    fn parses_multiple_sessions() {
        let input = concat!(
            "alpha|||1|||0|||1700000000|||1700000100|||/tmp\n",
            "beta|||2|||1|||1700001000|||1700002000|||/home/rhuk\n",
            "gamma|||5|||0|||1700003000|||1700004000|||\n",
        );
        let sessions = parse_list_sessions(input).unwrap();
        assert_eq!(sessions.len(), 3);
        assert_eq!(sessions[0].name, "alpha");
        assert!(!sessions[0].attached);
        assert_eq!(sessions[1].name, "beta");
        assert!(sessions[1].attached);
        assert_eq!(sessions[2].name, "gamma");
        assert!(sessions[2].current_path.is_none());
    }

    #[test]
    fn names_with_special_chars_survive_separator() {
        // Colons, single pipes, and spaces must all pass through —
        // the separator is specifically `|||` (three pipes) so a
        // lone `|` in a name doesn't trip the split.
        let line = "work: proj | v2|||1|||1|||1700000000|||1700000100|||/srv";
        let sessions = parse_list_sessions(line).unwrap();
        assert_eq!(sessions[0].name, "work: proj | v2");
    }

    #[test]
    fn unicode_name_preserved() {
        let line = "日本語セッション|||1|||0|||1700000000|||1700000100|||/tmp";
        let sessions = parse_list_sessions(line).unwrap();
        assert_eq!(sessions[0].name, "日本語セッション");
    }

    #[test]
    fn attached_client_count_treated_as_bool() {
        let line = "multi|||1|||3|||1700000000|||1700000100|||/tmp";
        let sessions = parse_list_sessions(line).unwrap();
        assert!(sessions[0].attached);
    }

    #[test]
    fn empty_lines_skipped() {
        let input = "\nalpha|||1|||0|||1700000000|||1700000100|||/tmp\n\n";
        let sessions = parse_list_sessions(input).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].name, "alpha");
    }

    #[test]
    fn malformed_line_errors_with_line_number() {
        let input = "alpha|||1|||0\nbroken_but_no_seps";
        let err = parse_list_sessions(input).unwrap_err();
        let msg = format!("{}", err);
        assert!(
            msg.contains("line 1") || msg.contains("line 2"),
            "msg was: {}",
            msg
        );
    }

    #[test]
    fn missing_activity_ok_but_none() {
        let line = "alpha|||1|||0|||1700000000||||||/tmp";
        let sessions = parse_list_sessions(line).unwrap();
        assert!(sessions[0].created.is_some());
        assert!(sessions[0].last_activity.is_none());
    }

    #[test]
    fn bosun_user_options_parse_when_present() {
        let line = "bosun-foo|||1|||0|||1700000000|||1700000100|||/srv|||foo|||claude|||~/proj";
        let sessions = parse_list_sessions(line).unwrap();
        assert_eq!(sessions[0].display_name.as_deref(), Some("foo"));
        assert_eq!(sessions[0].agent.as_deref(), Some("claude"));
        assert_eq!(sessions[0].spec_path.as_deref(), Some("~/proj"));
    }

    #[test]
    fn parses_worktree_fields() {
        // Full format: ...|@bosun_container_id|@bosun_worktree_path|@bosun_branch|pane_width
        let line = "bosun-foo|||1|||0|||1700000000|||1700000100|||/srv|||foo|||claude|||~/proj|||cid|||/srv/.worktrees/feat|||feat|||120";
        let s = &parse_list_sessions(line).unwrap()[0];
        assert_eq!(s.worktree_path.as_deref(), Some("/srv/.worktrees/feat"));
        assert_eq!(s.branch.as_deref(), Some("feat"));
        assert_eq!(s.pane_width, 120);
    }

    #[test]
    fn missing_worktree_fields_are_none() {
        let line = "plain|||1|||0|||1700000000|||1700000100|||/srv";
        let s = &parse_list_sessions(line).unwrap()[0];
        assert!(s.worktree_path.is_none());
        assert!(s.branch.is_none());
    }

    #[test]
    fn missing_bosun_options_are_none_not_error() {
        // Non-bosun session: `@bosun_*` all return empty strings,
        // which we parse as None. Also covers the back-compat case
        // where `@bosun_agent`/`@bosun_path` were added later.
        let line = "plain|||1|||0|||1700000000|||1700000100|||/srv|||||||||";
        let sessions = parse_list_sessions(line).unwrap();
        assert!(sessions[0].display_name.is_none());
        assert!(sessions[0].agent.is_none());
        assert!(sessions[0].spec_path.is_none());
    }
}
