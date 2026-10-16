//! The control-mode command channel against a real throwaway tmux
//! server: commands carried over `tmux -C` must behave exactly like
//! the exec path, hostile values must arrive byte-for-byte, and the
//! client must fall back to exec and reconnect when the connection
//! goes away.

#![cfg(feature = "tmux-it")]

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bosun::tmux::client::Retry;
use bosun::tmux::{CreateSpec, SessionMetadata, TmuxClient, TokioTmuxClient};

fn unique_socket(tag: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!("bosun-chan-{}-{}-{}", tag, std::process::id(), nanos)
}

fn tmux(socket: &str, args: &[&str]) -> std::process::Output {
    std::process::Command::new("tmux")
        .arg("-L")
        .arg(socket)
        .args(args)
        .output()
        .expect("spawn tmux")
}

/// Kills the throwaway server even when an assertion fails.
struct Server(String);
impl Drop for Server {
    fn drop(&mut self) {
        let _ = tmux(&self.0, &["kill-server"]);
    }
}

fn start_server(tag: &str) -> Server {
    let sock = unique_socket(tag);
    let out = tmux(&sock, &["new-session", "-d", "-s", "__bosun_monitor"]);
    assert!(out.status.success(), "monitor: {:?}", out);
    Server(sock)
}

/// Make a call to kick off the background connect, then wait for it.
async fn wait_up(client: &TokioTmuxClient) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !client.command_channel().is_up() {
        let _ = client.list_sessions().await;
        assert!(Instant::now() < deadline, "command channel never came up");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

const HOSTILE: &[&str] = &[
    "plain",
    "dq\"inside and 'sq'",
    "semi;colon; kill-server",
    "trailing;",
    "#{session_name} #(echo pwned) #[fg=red]",
    "line1\nkill-server",
    "tab\tand esc\x1b[31m",
    "back\\slash\\",
    "$HOME ${HOME} $(id)",
    "~/path",
    "unicode héllo 漢字 🚀",
    "%end 1 2 1",
    "-t",
];

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn control_commands_match_exec_byte_for_byte() {
    let server = start_server("match");
    let sock = &server.0;
    let client = TokioTmuxClient::with_socket(sock.clone());
    let exec = client.clone().exec_only();

    exec.create_session(&CreateSpec {
        name: "bosun-chan-a".into(),
        display_name: Some("A".into()),
        path: "/tmp".into(),
        command: String::new(),
        metadata: None,
        env: Vec::new(),
    })
    .await
    .expect("create");

    wait_up(&client).await;
    let before = client.command_channel().stats();

    // Hostile values written over the control channel read back the
    // same as values written by exec.
    for value in HOSTILE {
        client
            .set_display_name("bosun-chan-a", value)
            .await
            .expect("control set");
        let via_control = tmux(
            sock,
            &["show-options", "-v", "-t", "bosun-chan-a", "@bosun_display"],
        );
        exec.set_display_name("bosun-chan-a", value)
            .await
            .expect("exec set");
        let via_exec = tmux(
            sock,
            &["show-options", "-v", "-t", "bosun-chan-a", "@bosun_display"],
        );
        if value.ends_with(';') {
            // tmux's argv parser reads a trailing `;` as a command
            // separator, so exec silently drops it. The quoted control
            // line keeps the value intact.
            assert_eq!(via_control.stdout, format!("{value}\n").into_bytes());
            assert_ne!(via_control.stdout, via_exec.stdout);
        } else {
            assert_eq!(via_control.stdout, via_exec.stdout, "value {value:?}");
        }
    }

    // A hostile session name: created over control, found by exec.
    // (No `#{` here: tmux format-expands `new-session -s` itself, on
    // either transport. Internal names are slugs, so it never applies.)
    let nasty = "bosun-x;kill-server \"q\" ~ $HOME";
    client
        .create_session(&CreateSpec {
            name: nasty.into(),
            display_name: Some("$HOME ~ \"d\"".into()),
            path: "/tmp".into(),
            command: String::new(),
            metadata: Some(SessionMetadata {
                display_name: "$HOME ~ \"d\"".into(),
                path: "/tmp/a b;c".into(),
                agent: "terminal".into(),
                args: "--flag \"x\" $Y".into(),
                ..Default::default()
            }),
            env: vec![("ODD".into(), "a;b \"c\" $d\ne".into())],
        })
        .await
        .expect("create hostile session over control");
    let names =
        String::from_utf8(tmux(sock, &["list-sessions", "-F", "#{session_name}"]).stdout).unwrap();
    assert!(names.lines().any(|l| l == nasty), "names: {names}");
    let env = tmux(sock, &["show-environment", "-t", nasty, "ODD"]);
    assert_eq!(
        String::from_utf8_lossy(&env.stdout).trim_end(),
        "ODD=a;b \"c\" $d\ne"
    );
    let meta_c = client.get_session_metadata(nasty).await.unwrap().unwrap();
    let meta_e = exec.get_session_metadata(nasty).await.unwrap().unwrap();
    assert_eq!(meta_c.path, "/tmp/a b;c");
    assert_eq!(meta_c.args, meta_e.args);
    assert_eq!(meta_c.display_name, meta_e.display_name);

    // Reads: same parsed sessions and the same pane bytes.
    let a = client.list_sessions().await.unwrap();
    let b = exec.list_sessions().await.unwrap();
    assert_eq!(
        a.iter().map(|s| &s.name).collect::<Vec<_>>(),
        b.iter().map(|s| &s.name).collect::<Vec<_>>()
    );
    tmux(
        sock,
        &[
            "send-keys",
            "-t",
            "bosun-chan-a",
            "printf '\\033[31mred\\033[0m\\n%%end 1 2 1\\n'",
            "Enter",
        ],
    );
    tokio::time::sleep(Duration::from_millis(400)).await;
    let cap_c = client.capture_pane("bosun-chan-a").await.unwrap();
    let cap_e = exec.capture_pane("bosun-chan-a").await.unwrap();
    assert_eq!(cap_c, cap_e);
    assert!(String::from_utf8_lossy(&cap_c).contains("%end 1 2 1"));

    // Error paths read the same: missing session kill is Ok, a capture
    // of a missing pane is an error with tmux's own message.
    client
        .kill_session("bosun-nope-0")
        .await
        .expect("idempotent kill");
    let err_c = client.capture_pane("nope").await.unwrap_err().to_string();
    let err_e = exec.capture_pane("nope").await.unwrap_err().to_string();
    assert_eq!(err_c, err_e);

    let after = client.command_channel().stats();
    assert!(
        after.control_commands > before.control_commands + 20,
        "commands should have gone over control: {before:?} -> {after:?}"
    );
    assert_eq!(after.exec_commands, before.exec_commands, "no exec once up");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn falls_back_to_exec_and_reconnects() {
    let server = start_server("fallback");
    let sock = &server.0;
    let client = TokioTmuxClient::with_socket(sock.clone());
    client
        .create_session(&CreateSpec {
            name: "bosun-keep".into(),
            display_name: None,
            path: "/tmp".into(),
            command: String::new(),
            metadata: None,
            env: Vec::new(),
        })
        .await
        .expect("create");
    wait_up(&client).await;

    // Killing the monitor session ends the control connection. Commands
    // keep working over exec.
    tmux(sock, &["kill-session", "-t", "=__bosun_monitor"]);
    tokio::time::sleep(Duration::from_millis(200)).await;
    let s = client.list_sessions().await.expect("exec fallback");
    assert!(s.iter().any(|s| s.name == "bosun-keep"));
    assert!(!client.command_channel().is_up());
    let exec_before = client.command_channel().stats().exec_commands;
    client
        .run(&["set-option", "-t", "bosun-keep", "@x", "1"], Retry::Safe)
        .await
        .expect("exec set");
    assert!(client.command_channel().stats().exec_commands > exec_before);

    // Bring the monitor back: the channel reconnects on its own.
    tmux(sock, &["new-session", "-d", "-s", "__bosun_monitor"]);
    wait_up(&client).await;
    assert!(client.command_channel().stats().connects >= 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn never_starts_a_server_and_never_sizes_the_monitor() {
    // No server at all: reads stay on exec, and nothing gets started.
    let sock = unique_socket("noserver");
    let client = TokioTmuxClient::with_socket(sock.clone());
    for _ in 0..5 {
        assert!(client.list_sessions().await.unwrap().is_empty());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!client.command_channel().is_up());
    let ls = tmux(&sock, &["list-sessions"]);
    assert!(!ls.status.success(), "a server was started: {ls:?}");

    // With a monitor: the command client attaches but sets no size, so
    // it isn't counted in window-size negotiation (spike Q5).
    let server = start_server("size");
    let client = TokioTmuxClient::with_socket(server.0.clone());
    wait_up(&client).await;
    let clients = tmux(
        &server.0,
        &[
            "list-clients",
            "-F",
            "#{client_control_mode} #{client_flags}",
        ],
    );
    let text = String::from_utf8_lossy(&clients.stdout).to_string();
    assert!(text.lines().any(|l| l.starts_with("1 ")), "clients: {text}");
    assert!(text.contains("no-output"), "clients: {text}");
}
