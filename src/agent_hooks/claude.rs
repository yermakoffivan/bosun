//! Claude Code hooks.
//!
//! Bosun never edits `~/.claude/settings.json` or a project's
//! `.claude/` files. It writes its own settings file holding only the
//! hooks below and launches Claude with `--settings <file>`. Claude
//! merges hook lists across settings sources (managed, `--settings`,
//! local, project, user) rather than letting one replace another, so the
//! user's own hooks keep running alongside these.
//!
//! Event → state, per <https://code.claude.com/docs/en/hooks>:
//!
//! | event                                   | state                        |
//! |-----------------------------------------|------------------------------|
//! | `SessionStart`                          | idle                         |
//! | `UserPromptSubmit`                      | running                      |
//! | `PreToolUse` (most tools)               | running                      |
//! | `PreToolUse` `AskUserQuestion`          | waiting, "question"          |
//! | `PreToolUse` `ExitPlanMode`             | waiting, "plan approval"     |
//! | `PostToolUse`                           | running (ends a wait too)    |
//! | `PermissionRequest`                     | waiting, "permission: Tool"  |
//! | `Notification` `permission_prompt`      | waiting, "permission: Tool"  |
//! | `Notification` `elicitation_dialog` …   | waiting, "input requested"   |
//! | `Notification` `idle_prompt`            | running/waiting → idle only  |
//! | `Stop`                                  | done                         |
//! | `SessionEnd`                            | cleared                      |
//!
//! Only long-established events are registered: an older Claude that
//! doesn't know an event name could reject the whole settings file.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use super::{shell_quote, HookAction};
use crate::tmux::detector::Status;

/// Events Bosun registers a hook for, in the order they're written.
pub const EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Notification",
    "Stop",
    "SessionEnd",
];

/// Seconds Claude gives each hook before cancelling it. The hook
/// normally takes a few milliseconds; this only bounds a wedged tmux
/// server, so it can't stall a turn for Claude's 10-minute default.
const HOOK_TIMEOUT_SECS: u64 = 5;

/// The handful of payload fields the mapping reads. Everything else in
/// the hook's stdin JSON is ignored.
#[derive(Debug, Default, Deserialize)]
struct Input {
    #[serde(default)]
    tool_name: Option<String>,
    #[serde(default)]
    notification_type: Option<String>,
    #[serde(default)]
    message: Option<String>,
}

fn parse(input: &[u8]) -> Input {
    serde_json::from_slice(input).unwrap_or_default()
}

/// Map a Claude Code hook event and its stdin payload to an action.
pub fn map(event: &str, input: &[u8]) -> HookAction {
    match event {
        "SessionStart" => HookAction::set(Status::Idle),
        "UserPromptSubmit" | "PostToolUse" => HookAction::set(Status::Running),
        "PreToolUse" => match parse(input).tool_name.as_deref() {
            // These two tools are the agent asking the user something,
            // and the dialog appears as soon as the tool starts.
            Some("AskUserQuestion") => HookAction::set_with(Status::Waiting, "question"),
            Some("ExitPlanMode") => HookAction::set_with(Status::Waiting, "plan approval"),
            _ => HookAction::set(Status::Running),
        },
        "PermissionRequest" => {
            let detail = match parse(input).tool_name {
                Some(tool) if !tool.is_empty() => format!("permission: {tool}"),
                _ => "permission".to_string(),
            };
            HookAction::set_with(Status::Waiting, detail)
        }
        "Notification" => {
            let input = parse(input);
            match input.notification_type.as_deref() {
                Some("permission_prompt") => HookAction::set_with(
                    Status::Waiting,
                    permission_detail(input.message.as_deref()),
                ),
                Some("elicitation_dialog" | "elicitation_url_dialog" | "agent_needs_input") => {
                    HookAction::set_with(Status::Waiting, "input requested")
                }
                Some("elicitation_complete" | "elicitation_response") => {
                    HookAction::set(Status::Running)
                }
                // Claude has sat at an empty prompt for a while. That
                // can't be a running turn or an open dialog, so it
                // settles a state an interrupt left behind, but leaves an
                // unread `done` alone.
                Some("idle_prompt") => HookAction::SettleIdle,
                _ => HookAction::Ignore,
            }
        }
        "Stop" => HookAction::set(Status::Done),
        "SessionEnd" => HookAction::Clear,
        _ => HookAction::Ignore,
    }
}

/// `permission: Bash` from Claude's "Claude needs your permission to
/// use Bash" notification text, or plain `permission` if the text isn't
/// in that form.
fn permission_detail(message: Option<&str>) -> String {
    message
        .and_then(|m| m.rsplit_once(" to use "))
        .map(|(_, tool)| tool.trim().trim_end_matches('.'))
        .filter(|t| !t.is_empty())
        .map(|t| format!("permission: {t}"))
        .unwrap_or_else(|| "permission".to_string())
}

/// The settings JSON Bosun passes with `--settings`: one command hook
/// per event in [`EVENTS`], each running `bosun hook claude <event>`.
///
/// Shell form (a single `command` string) rather than exec form
/// (`command` + `args`): an older Claude that predates `args` would run
/// the bare binary, which starts the TUI.
pub fn settings_json(bosun_bin: &Path) -> String {
    let bin = shell_quote(&bosun_bin.to_string_lossy());
    let mut hooks = serde_json::Map::new();
    for event in EVENTS {
        hooks.insert(
            (*event).to_string(),
            serde_json::json!([{
                "hooks": [{
                    "type": "command",
                    "command": format!("{bin} hook claude {event}"),
                    "timeout": HOOK_TIMEOUT_SECS,
                }]
            }]),
        );
    }
    let root = serde_json::json!({ "hooks": hooks });
    serde_json::to_string_pretty(&root).expect("settings json serializes")
}

/// File name for the settings generated for `bosun_bin`. Keyed by the
/// binary path so a development build and the installed bosun can't
/// overwrite each other's file (each session's hooks keep calling the
/// binary that launched it).
fn settings_file_name(bosun_bin: &Path) -> String {
    // FNV-1a: stable across builds and Rust versions, unlike
    // `DefaultHasher`.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bosun_bin.to_string_lossy().bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("claude-settings-{:08x}.json", h as u32)
}

/// Write the settings file under `dir` (if its content changed) and
/// return its path.
pub fn write_settings_file(dir: &Path, bosun_bin: &Path) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let path = dir.join(settings_file_name(bosun_bin));
    let body = settings_json(bosun_bin);
    if std::fs::read_to_string(&path).is_ok_and(|cur| cur == body) {
        return Ok(path);
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, &body)?;
    std::fs::rename(&tmp, &path)?;
    Ok(path)
}

/// Whether the user's extra args already pass `--settings`. Claude takes
/// one `--settings`, so adding ours would override theirs; Bosun leaves
/// the user's in charge and that session falls back to the detector.
pub fn args_set_settings(args: &str) -> bool {
    args.split_whitespace()
        .any(|t| t == "--settings" || t.starts_with("--settings="))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(status: Status) -> HookAction {
        HookAction::set(status)
    }

    // Recorded stdin payloads, trimmed to the common fields plus the
    // event-specific ones, as Claude Code 2.1.x sends them.
    const SESSION_START: &str = r#"{"session_id":"abc123","transcript_path":"/Users/a/.claude/projects/x/abc123.jsonl","cwd":"/Users/a/proj","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-4-5"}"#;
    const USER_PROMPT_SUBMIT: &str = r#"{"session_id":"abc123","transcript_path":"/t.jsonl","cwd":"/Users/a/proj","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"Write a function to calculate the factorial of a number"}"#;
    const PRE_TOOL_USE_BASH: &str = r#"{"session_id":"abc123","transcript_path":"/t.jsonl","cwd":"/Users/a/proj","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests"},"tool_use_id":"toolu_01ABC"}"#;
    const PRE_TOOL_USE_ASK: &str = r#"{"session_id":"abc123","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which db?","options":[{"label":"sqlite"}]}]},"tool_use_id":"toolu_02"}"#;
    const PRE_TOOL_USE_PLAN: &str = r#"{"session_id":"abc123","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"1. do it"},"tool_use_id":"toolu_03"}"#;
    const POST_TOOL_USE: &str = r#"{"session_id":"abc123","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/path/to/file.txt","content":"x"},"tool_response":{"filePath":"/path/to/file.txt","type":"create"},"tool_use_id":"toolu_01ABC","duration_ms":12}"#;
    const PERMISSION_REQUEST: &str = r#"{"session_id":"abc123","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules directory"},"permission_suggestions":[]}"#;
    const NOTIFY_PERMISSION: &str = r#"{"session_id":"abc123","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","title":"Permission needed","notification_type":"permission_prompt"}"#;
    const NOTIFY_IDLE: &str = r#"{"session_id":"abc123","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#;
    const NOTIFY_ELICITATION: &str = r#"{"session_id":"abc123","hook_event_name":"Notification","message":"my-mcp-server needs input","notification_type":"elicitation_dialog"}"#;
    const NOTIFY_AUTH: &str = r#"{"session_id":"abc123","hook_event_name":"Notification","message":"Signed in","notification_type":"auth_success"}"#;
    const STOP: &str = r#"{"session_id":"abc123","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done. The tests pass.","background_tasks":[],"session_crons":[]}"#;
    const SESSION_END: &str = r#"{"session_id":"abc123","transcript_path":"/t.jsonl","cwd":"/Users/a/proj","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#;

    #[test]
    fn recorded_payloads_map_to_states() {
        let cases: &[(&str, &str, HookAction)] = &[
            ("SessionStart", SESSION_START, set(Status::Idle)),
            ("UserPromptSubmit", USER_PROMPT_SUBMIT, set(Status::Running)),
            ("PreToolUse", PRE_TOOL_USE_BASH, set(Status::Running)),
            (
                "PreToolUse",
                PRE_TOOL_USE_ASK,
                HookAction::set_with(Status::Waiting, "question"),
            ),
            (
                "PreToolUse",
                PRE_TOOL_USE_PLAN,
                HookAction::set_with(Status::Waiting, "plan approval"),
            ),
            ("PostToolUse", POST_TOOL_USE, set(Status::Running)),
            (
                "PermissionRequest",
                PERMISSION_REQUEST,
                HookAction::set_with(Status::Waiting, "permission: Bash"),
            ),
            (
                "Notification",
                NOTIFY_PERMISSION,
                HookAction::set_with(Status::Waiting, "permission: Bash"),
            ),
            ("Notification", NOTIFY_IDLE, HookAction::SettleIdle),
            (
                "Notification",
                NOTIFY_ELICITATION,
                HookAction::set_with(Status::Waiting, "input requested"),
            ),
            ("Notification", NOTIFY_AUTH, HookAction::Ignore),
            ("Stop", STOP, set(Status::Done)),
            ("SessionEnd", SESSION_END, HookAction::Clear),
        ];
        for (event, json, want) in cases {
            assert_eq!(&map(event, json.as_bytes()), want, "{event}: {json}");
        }
    }

    #[test]
    fn empty_or_invalid_stdin_still_maps() {
        assert_eq!(map("Stop", b""), set(Status::Done));
        assert_eq!(map("PreToolUse", b"not json"), set(Status::Running));
        assert_eq!(
            map("PermissionRequest", b""),
            HookAction::set_with(Status::Waiting, "permission")
        );
        assert_eq!(map("Notification", b"{"), HookAction::Ignore);
        assert_eq!(map("UnknownEvent", b"{}"), HookAction::Ignore);
    }

    #[test]
    fn permission_detail_falls_back_to_plain() {
        assert_eq!(
            permission_detail(Some("Claude needs your permission to use Bash")),
            "permission: Bash"
        );
        assert_eq!(
            permission_detail(Some(
                "Claude needs your permission to use mcp__github__create_issue."
            )),
            "permission: mcp__github__create_issue"
        );
        assert_eq!(permission_detail(Some("Permission needed")), "permission");
        assert_eq!(permission_detail(None), "permission");
    }

    #[test]
    fn settings_register_every_event_with_the_absolute_binary() {
        let json = settings_json(Path::new("/opt/homebrew/bin/bosun"));
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let hooks = v["hooks"].as_object().unwrap();
        assert_eq!(hooks.len(), EVENTS.len());
        for event in EVENTS {
            let h = &hooks[*event][0]["hooks"][0];
            assert_eq!(h["type"], "command");
            assert_eq!(
                h["command"],
                format!("/opt/homebrew/bin/bosun hook claude {event}")
            );
            assert_eq!(h["timeout"], HOOK_TIMEOUT_SECS);
            assert!(
                hooks[*event][0].get("matcher").is_none(),
                "match every tool/type"
            );
        }
    }

    #[test]
    fn settings_quote_a_binary_path_with_spaces() {
        let json = settings_json(Path::new("/Users/a b/bin/bosun"));
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            v["hooks"]["Stop"][0]["hooks"][0]["command"],
            "'/Users/a b/bin/bosun' hook claude Stop"
        );
    }

    #[test]
    fn settings_file_is_written_once_and_named_per_binary() {
        let dir = tempfile::tempdir().unwrap();
        let a = write_settings_file(dir.path(), Path::new("/a/bosun")).unwrap();
        let b = write_settings_file(dir.path(), Path::new("/b/bosun")).unwrap();
        assert_ne!(a, b);
        let before = std::fs::metadata(&a).unwrap().modified().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        let again = write_settings_file(dir.path(), Path::new("/a/bosun")).unwrap();
        assert_eq!(a, again);
        assert_eq!(
            std::fs::metadata(&a).unwrap().modified().unwrap(),
            before,
            "unchanged content is not rewritten"
        );
        assert!(std::fs::read_to_string(&a)
            .unwrap()
            .contains("/a/bosun hook claude Stop"));
    }

    #[test]
    fn detects_user_settings_flag() {
        assert!(args_set_settings("--settings my.json"));
        assert!(args_set_settings("--model opus --settings={}"));
        assert!(!args_set_settings("--setting-sources user"));
        assert!(!args_set_settings(""));
    }
}
