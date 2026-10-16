//! Real-tmux checks for agent hooks and shared binding ownership.
//!
//! Each test spawns its own throwaway tmux server on a unique `-L`
//! socket and kills it at the end; nothing touches the default or
//! `bosun` sockets.

#![cfg(feature = "tmux-it")]

use std::io::Write;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use bosun::tmux::detector::Status;
use bosun::tmux::parse::{parse_list_sessions, LIST_SESSIONS_FORMAT};

fn unique_socket(tag: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!("bosun-hooks-{}-{}-{}", tag, std::process::id(), nanos)
}

fn tmux(socket: &str, args: &[&str]) -> String {
    let out = Command::new("tmux")
        .arg("-L")
        .arg(socket)
        .args(args)
        .output()
        .expect("spawn tmux");
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

struct Server(String);

impl Server {
    fn start(tag: &str) -> Self {
        let s = Server(unique_socket(tag));
        tmux(
            &s.0,
            &["new-session", "-d", "-s", "bosun-a", "-x", "80", "-y", "20"],
        );
        s
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        tmux(&self.0, &["kill-server"]);
    }
}

/// Run `bosun hook <args>` as if from inside the session's pane.
fn hook(server: &Server, args: &[&str], stdin: &str) -> std::process::Output {
    let pane = tmux(&server.0, &["display", "-p", "-t", "bosun-a", "#{pane_id}"]);
    let socket_path = tmux(
        &server.0,
        &["display", "-p", "-t", "bosun-a", "#{socket_path}"],
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_bosun"))
        .arg("hook")
        .args(args)
        .env("TMUX", format!("{socket_path},1,0"))
        .env("TMUX_PANE", pane)
        .env_remove("BOSUN_HOOK_LOG")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn bosun hook");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn session(server: &Server) -> bosun::tmux::TmuxSession {
    let out = tmux(&server.0, &["list-sessions", "-F", LIST_SESSIONS_FORMAT]);
    parse_list_sessions(&out)
        .unwrap()
        .into_iter()
        .find(|s| s.name == "bosun-a")
        .unwrap()
}

#[test]
fn hook_writes_state_the_poll_reads_back() {
    let server = Server::start("rw");

    let out = hook(
        &server,
        &["claude", "PermissionRequest"],
        r#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
    );
    assert!(out.status.success());
    assert!(out.stdout.is_empty(), "a hook must print nothing");
    let h = session(&server).hook.expect("hook state");
    assert_eq!(h.status, Status::Waiting);
    assert_eq!(h.detail.as_deref(), Some("permission: Bash"));
    assert!(h.at_ms > 0);

    hook(&server, &["claude", "PostToolUse"], "{}");
    let h = session(&server).hook.expect("hook state");
    assert_eq!(h.status, Status::Running);
    assert_eq!(h.detail, None, "a new state drops the old detail");

    hook(&server, &["claude", "Stop"], "");
    assert_eq!(session(&server).hook.unwrap().status, Status::Done);

    // idle_prompt leaves an unread Done alone…
    hook(
        &server,
        &["claude", "Notification"],
        r#"{"notification_type":"idle_prompt"}"#,
    );
    assert_eq!(session(&server).hook.unwrap().status, Status::Done);
    // …but settles a Running that an interrupt left behind.
    hook(&server, &["claude", "UserPromptSubmit"], "");
    hook(
        &server,
        &["claude", "Notification"],
        r#"{"notification_type":"idle_prompt"}"#,
    );
    assert_eq!(session(&server).hook.unwrap().status, Status::Idle);

    hook(&server, &["claude", "SessionEnd"], r#"{"reason":"other"}"#);
    assert_eq!(session(&server).hook, None);
}

#[test]
fn hook_outside_tmux_or_with_bad_input_exits_zero() {
    let out = Command::new(env!("CARGO_BIN_EXE_bosun"))
        .args(["hook", "claude", "Stop"])
        .env_remove("TMUX")
        .env_remove("TMUX_PANE")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(out.stdout.is_empty());

    let server = Server::start("bad");
    let out = hook(&server, &["claude", "PreToolUse"], "not json at all");
    assert!(out.status.success());
    assert_eq!(session(&server).hook.unwrap().status, Status::Running);
    let out = hook(&server, &["nosuchagent", "Whatever"], "{}");
    assert!(out.status.success());
    let out = hook(&server, &[], "");
    assert!(out.status.success());
}

#[test]
fn clear_session_state_targets_the_sessions_pane() {
    let server = Server::start("clear");
    hook(&server, &["claude", "Stop"], "");
    assert!(session(&server).hook.is_some());
    bosun::agent_hooks::clear_session_state(Some(&server.0), "bosun-a");
    assert_eq!(session(&server).hook, None);
}

#[test]
fn only_the_last_owner_uninstalls() {
    use bosun::tmux::owners;
    let server = Server::start("owners");
    let sock = Some(server.0.as_str());
    let me = std::process::id();

    // Alone: register, then release says "uninstall" and clears the option.
    owners::register(sock);
    assert_eq!(
        tmux(&server.0, &["show-options", "-gqv", owners::OWNERS_OPTION]),
        me.to_string()
    );
    assert!(owners::release(sock));
    assert_eq!(
        tmux(&server.0, &["show-options", "-gqv", owners::OWNERS_OPTION]),
        ""
    );

    // Another live process (our parent stands in for a second bosun)
    // still owns the bindings: releasing must not uninstall.
    let other = std::os::unix::process::parent_id();
    tmux(
        &server.0,
        &[
            "set-option",
            "-g",
            owners::OWNERS_OPTION,
            &other.to_string(),
        ],
    );
    owners::register(sock);
    assert!(!owners::release(sock));
    assert_eq!(
        tmux(&server.0, &["show-options", "-gqv", owners::OWNERS_OPTION]),
        other.to_string()
    );

    // A dead pid left by a crashed bosun doesn't count.
    tmux(
        &server.0,
        &["set-option", "-g", owners::OWNERS_OPTION, "999999"],
    );
    owners::register(sock);
    assert!(owners::release(sock));
}
