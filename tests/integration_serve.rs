//! End to end: `bosun serve` against a throwaway tmux socket, with a
//! throwaway HOME so the config, store and daemon socket never touch
//! the real ones. A plain blocking client speaks raw JSON frames, the
//! way a GUI would.

#![cfg(feature = "tmux-it")]

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

const BIN: &str = env!("CARGO_BIN_EXE_bosun");

fn unique_socket() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!("bosun-serve-it-{}-{}", std::process::id(), nanos)
}

/// The daemon process, its tmux server and its HOME, torn down on drop.
struct Fixture {
    home: tempfile::TempDir,
    sock: String,
    child: Option<Child>,
}

impl Fixture {
    fn command(&self, args: &[&str]) -> Command {
        let mut c = Command::new(BIN);
        c.args(args)
            .env("HOME", self.home.path())
            .env("BOSUN_TMUX_SOCKET", &self.sock)
            .env_remove("TMUX")
            .stdin(Stdio::null());
        for var in [
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "BOSUN_PREFIX",
            "BOSUN_THEME",
            "BOSUN_DEFAULT_AGENT",
            "BOSUN_REMOVE_DEAD_SESSIONS",
            "BOSUN_SHOW_GROUP_IN_TITLE",
            "BOSUN_HIDE_SINGLE_TAB_STRIP",
            "BOSUN_EMBED",
            "BOSUN_TMUX_CONTROL",
        ] {
            c.env_remove(var);
        }
        c
    }

    fn socket_path(&self) -> PathBuf {
        let out = self
            .command(&["serve", "--print-socket"])
            .output()
            .expect("print socket");
        PathBuf::from(String::from_utf8(out.stdout).unwrap().trim())
    }

    /// `config.toml` under the fixture's HOME. On macOS Bosun's config
    /// and data directories are the same (`~/Library/Application
    /// Support/dev.yetidevworks.bosun`); elsewhere it's `~/.config/bosun`
    /// (the fixture clears `XDG_CONFIG_HOME`).
    fn config_path(&self) -> PathBuf {
        let dir = if cfg!(target_os = "macos") {
            self.socket_path().parent().unwrap().to_path_buf()
        } else {
            self.home.path().join(".config").join("bosun")
        };
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("config.toml")
    }

    fn start(&mut self) -> PathBuf {
        let path = self.socket_path();
        self.child = Some(
            self.command(&["serve", "--idle-timeout", "3"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn bosun serve"),
        );
        path
    }

    fn tmux(&self, args: &[&str]) -> std::process::Output {
        Command::new("tmux")
            .arg("-L")
            .arg(&self.sock)
            .args(args)
            .output()
            .expect("tmux")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = self.tmux(&["kill-server"]);
    }
}

struct Conn {
    stream: UnixStream,
    last_seq: Option<u64>,
}

impl Conn {
    fn connect(path: &PathBuf) -> Self {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match UnixStream::connect(path) {
                Ok(stream) => {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(15)))
                        .unwrap();
                    return Self {
                        stream,
                        last_seq: None,
                    };
                }
                Err(e) => {
                    assert!(Instant::now() < deadline, "daemon never listened: {e}");
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        }
    }

    fn send(&mut self, v: Value) {
        let body = serde_json::to_vec(&v).unwrap();
        self.stream
            .write_all(&(body.len() as u32).to_be_bytes())
            .unwrap();
        self.stream.write_all(&body).unwrap();
    }

    /// Next message, or `None` at EOF. Checks that every `seq` is
    /// exactly one more than the last.
    fn recv(&mut self) -> Option<Value> {
        let mut len = [0u8; 4];
        if self.stream.read_exact(&mut len).is_err() {
            return None;
        }
        let mut body = vec![0u8; u32::from_be_bytes(len) as usize];
        self.stream.read_exact(&mut body).unwrap();
        let v: Value = serde_json::from_slice(&body).unwrap();
        if let Some(seq) = v.get("seq").and_then(Value::as_u64) {
            if v["t"] != "snapshot" {
                if let Some(last) = self.last_seq {
                    assert_eq!(seq, last + 1, "seq gap before {v}");
                }
            }
            self.last_seq = Some(seq);
        }
        Some(v)
    }

    /// Read until `pred` matches, returning everything seen.
    fn until(&mut self, what: &str, pred: impl Fn(&Value) -> bool) -> Vec<Value> {
        let mut seen = Vec::new();
        loop {
            let v = self
                .recv()
                .unwrap_or_else(|| panic!("EOF waiting for {what}; saw {seen:#?}"));
            let done = pred(&v);
            seen.push(v);
            if done {
                return seen;
            }
        }
    }
}

fn is_ack(v: &Value, id: u64) -> bool {
    v["t"] == "ack" && v["id"] == id
}

#[test]
fn serve_hello_snapshot_create_delta_kill() {
    let home = tempfile::Builder::new()
        .prefix("bsv")
        .tempdir_in("/tmp")
        .unwrap();
    let mut fx = Fixture {
        home,
        sock: unique_socket(),
        child: None,
    };
    let path = fx.socket_path();
    assert!(
        path.starts_with(fx.home.path()),
        "socket {path:?} outside HOME"
    );
    assert_eq!(path.file_name().unwrap(), "bosun.sock");

    fx.child = Some(
        fx.command(&["serve", "--idle-timeout", "3"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn bosun serve"),
    );
    let mut c = Conn::connect(&path);

    // A second daemon refuses to start.
    let second = fx.command(&["serve"]).output().expect("second serve");
    assert!(!second.status.success());
    assert!(
        String::from_utf8_lossy(&second.stderr).contains("already running"),
        "{second:?}"
    );

    // hello → snapshot
    c.send(json!({"t": "hello", "protocol": 1, "client": "integration-test"}));
    let snap = c.recv().expect("snapshot");
    assert_eq!(snap["t"], "snapshot", "{snap}");
    assert_eq!(snap["server"]["protocol"], 1);
    assert_eq!(snap["server"]["tmux_socket"], fx.sock.as_str());
    assert!(snap["sessions"].is_array());
    assert!(snap["statuses"].is_object());
    assert!(snap["sidebar"]["ungrouped"].is_array());
    assert!(snap["recents"].is_array());
    let settings = snap["config"]["settings"].as_array().unwrap();
    let theme_row = settings.iter().find(|s| s["key"] == "theme").unwrap();
    assert_eq!(theme_row["read_only"], false);
    assert!(settings
        .iter()
        .any(|s| s["key"] == "tmux_socket" && s["read_only"] == true));
    assert_eq!(snap["theme"]["name"], "opencode");
    assert!(snap["theme"]["status_done"]
        .as_str()
        .unwrap()
        .starts_with('#'));
    let themes = snap["themes"].as_array().unwrap();
    assert!(themes.len() >= 15);
    assert!(themes
        .iter()
        .all(|t| t["source"] == "bundled" || t["source"] == "user"));

    // Wrong protocol on another connection: readable error, then EOF.
    let mut bad = Conn::connect(&path);
    bad.send(json!({"t": "hello", "protocol": 99}));
    let err = bad.recv().expect("error frame");
    assert_eq!(err["t"], "error");
    assert_eq!(err["code"], "protocol_mismatch");
    assert!(err["message"].as_str().unwrap().contains("update bosun"));
    assert!(bad.recv().is_none(), "connection should close");

    // create → ack with the session name, and a sessions delta with it.
    c.send(json!({
        "t": "cmd", "id": 1, "op": "create",
        "spec": {"name": "itest", "path": "/tmp", "agent": "terminal"}
    }));
    let seen = c.until("create ack", |v| is_ack(v, 1));
    let ack = seen.last().unwrap();
    assert_eq!(ack["ok"], true, "{ack}");
    let name = ack["session"].as_str().expect("session in ack").to_string();
    assert!(name.starts_with("bosun-itest-"), "{name}");
    let has_row = |seen: &[Value]| {
        seen.iter().any(|v| {
            v["t"] == "sessions"
                && v["upsert"]
                    .as_array()
                    .is_some_and(|u| u.iter().any(|s| s["name"] == name.as_str()))
        })
    };
    if !has_row(&seen) {
        let more = c.until("sessions delta", |v| v["t"] == "sessions");
        assert!(has_row(&more), "{more:#?}");
    }
    let ls = fx.tmux(&["list-sessions", "-F", "#{session_name}"]);
    assert!(String::from_utf8_lossy(&ls.stdout)
        .lines()
        .any(|l| l == name));

    // rename → the row's display changes.
    c.send(json!({"t": "cmd", "id": 2, "op": "rename", "session": name, "display": "Renamed"}));
    let seen = c.until("rename delta", |v| {
        v["t"] == "sessions"
            && v["upsert"]
                .as_array()
                .is_some_and(|u| u.iter().any(|s| s["display"] == "Renamed"))
    });
    if !seen.iter().any(|v| is_ack(v, 2)) {
        let more = c.until("rename ack", |v| is_ack(v, 2));
        assert_eq!(more.last().unwrap()["ok"], true);
    }

    // A command the daemon refuses up front.
    c.send(json!({"t": "cmd", "id": 3, "op": "rename", "session": name, "display": "a\nb"}));
    let seen = c.until("bad rename ack", |v| is_ack(v, 3));
    assert_eq!(seen.last().unwrap()["ok"], false);

    // kill → ack, and the row is removed.
    c.send(json!({"t": "cmd", "id": 4, "op": "kill", "session": name}));
    let mut seen = c.until("kill ack", |v| is_ack(v, 4));
    assert_eq!(seen.last().unwrap()["ok"], true);
    let removed = |seen: &[Value]| {
        seen.iter().any(|v| {
            v["t"] == "sessions"
                && v["removed"]
                    .as_array()
                    .is_some_and(|r| r.iter().any(|s| s == name.as_str()))
        })
    };
    if !removed(&seen) {
        seen = c.until("removal delta", |v| v["t"] == "sessions");
        assert!(removed(&seen), "{seen:#?}");
    }
    let ls = fx.tmux(&["list-sessions", "-F", "#{session_name}"]);
    assert!(!String::from_utf8_lossy(&ls.stdout)
        .lines()
        .any(|l| l == name));

    // Last client gone → the daemon exits after its idle timeout and
    // removes its socket.
    drop(c);
    let mut child = fx.child.take().unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "daemon exit: {status:?}");
            break;
        }
        assert!(Instant::now() < deadline, "daemon did not exit when idle");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(!path.exists(), "socket left behind");
}

fn fixture() -> Fixture {
    let home = tempfile::Builder::new()
        .prefix("bsv")
        .tempdir_in("/tmp")
        .unwrap();
    Fixture {
        home,
        sock: unique_socket(),
        child: None,
    }
}

/// Write `config.toml` so its mtime moves even on a filesystem with
/// coarse timestamps; the daemon notices a changed mtime.
fn write_config(path: &PathBuf, contents: &str) {
    let before = std::fs::metadata(path).and_then(|m| m.modified()).ok();
    loop {
        std::fs::write(path, contents).unwrap();
        let after = std::fs::metadata(path).and_then(|m| m.modified()).ok();
        if after != before {
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn serve_keybindings_follow_config_toml() {
    let mut fx = fixture();
    let config = fx.config_path();
    write_config(
        &config,
        "[keybindings]\nnext_tab = 'ctrl+shift+right'\nprevious_tab = 'none'\n",
    );
    let path = fx.start();
    let mut c = Conn::connect(&path);
    c.send(json!({"t": "hello", "protocol": 1}));
    let snap = c.recv().expect("snapshot");
    assert_eq!(snap["t"], "snapshot", "{snap}");
    assert_eq!(
        snap["keybindings"],
        json!({
            "previous_tab": null, "next_tab": "Ctrl+Shift+Right",
            "previous_session": "Shift+Up", "next_session": "Shift+Down",
            "send_next_key": "Ctrl+v"
        })
    );

    // An edit made elsewhere arrives as a `keybindings` delta.
    write_config(&config, "[keybindings]\nnext_session = 'Alt+n'\n");
    let seen = c.until("keybindings delta", |v| v["t"] == "keybindings");
    assert_eq!(
        seen.last().unwrap()["keybindings"],
        json!({
            "previous_tab": "Shift+Left", "next_tab": "Shift+Right",
            "previous_session": "Shift+Up", "next_session": "Alt+n",
            "send_next_key": "Ctrl+v"
        })
    );

    // An invalid table falls back to the defaults, as the TUI does.
    write_config(&config, "[keybindings]\nnext_tab = 'Ctrl+q'\n");
    let seen = c.until("keybindings delta", |v| v["t"] == "keybindings");
    assert_eq!(
        seen.last().unwrap()["keybindings"],
        json!({
            "previous_tab": "Shift+Left", "next_tab": "Shift+Right",
            "previous_session": "Shift+Up", "next_session": "Shift+Down",
            "send_next_key": "Ctrl+v"
        })
    );

    // A config edit that leaves the shortcuts alone sends no delta: the
    // next one to arrive is for the edit after it.
    write_config(&config, "theme = 'nord'\n");
    let seen = c.until("theme delta", |v| v["t"] == "theme");
    assert!(!seen.iter().any(|v| v["t"] == "keybindings"), "{seen:#?}");
    write_config(
        &config,
        "theme = 'nord'\n[keybindings]\nnext_tab = 'Alt+Right'\n",
    );
    let seen = c.until("keybindings delta", |v| v["t"] == "keybindings");
    assert_eq!(
        seen.last().unwrap()["keybindings"]["next_tab"],
        "Alt+Right",
        "{seen:#?}"
    );
}

#[test]
fn serve_hook_state_reaches_clients_within_the_poll() {
    let mut fx = fixture();
    let path = fx.start();
    let mut c = Conn::connect(&path);
    c.send(json!({"t": "hello", "protocol": 1}));
    assert_eq!(c.recv().expect("snapshot")["t"], "snapshot");

    // A session whose foreground process isn't a shell, the way an
    // agent's is (hook state is ignored at a bare shell). The process is
    // started with send-keys rather than `launch_agent`: the actor spends
    // about 2 s after a launch refreshing on its own schedule, and the
    // poll waits for that, which isn't what this test measures.
    c.send(json!({
        "t": "cmd", "id": 1, "op": "create", "defer_launch": true,
        "spec": {"name": "hooked", "path": "/tmp", "agent": "terminal"}
    }));
    let seen = c.until("create ack", |v| is_ack(v, 1));
    let ack = seen.last().unwrap();
    assert_eq!(ack["ok"], true, "{ack}");
    let name = ack["session"].as_str().unwrap().to_string();
    fx.tmux(&["send-keys", "-t", &name, "exec sleep 600", "Enter"]);
    let running_sleep = |v: &Value| {
        v["t"] == "sessions"
            && v["upsert"].as_array().is_some_and(|u| {
                u.iter()
                    .any(|s| s["name"] == name.as_str() && s["pane_command"] == "sleep")
            })
    };
    if !seen.iter().any(running_sleep) {
        c.until("sleep in the pane", running_sleep);
    }

    let display = |format: &str| {
        let out = fx.tmux(&["display", "-p", "-t", &name, format]);
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    };
    let pane = display("#{pane_id}");
    let server = display("#{socket_path},#{pid},0");

    // Each report lands well inside the 1 s refresh: the 250 ms status
    // poll picks it up. Five in a row all under 600 ms would happen by
    // chance about 8 % of the time on a 1 s cadence.
    let mut took = Vec::new();
    for i in 0..5u64 {
        let tool = format!("Tool{i}");
        let start = Instant::now();
        let mut hook = Command::new(BIN)
            .args(["hook", "claude", "PermissionRequest"])
            .env("TMUX", &server)
            .env("TMUX_PANE", &pane)
            .env_remove("BOSUN_HOOK_LOG")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn bosun hook");
        hook.stdin
            .take()
            .unwrap()
            .write_all(json!({ "tool_name": tool }).to_string().as_bytes())
            .unwrap();
        assert!(hook.wait().unwrap().success());
        let detail = format!("permission: {tool}");
        c.until("hook status delta", |v| {
            v["t"] == "status"
                && v["session"] == name.as_str()
                && v["state"] == "waiting"
                && v["source"] == "hook"
                && v["detail"] == detail.as_str()
        });
        took.push(start.elapsed());
        // Land the next report at a different point in the poll cycle.
        std::thread::sleep(Duration::from_millis(150 + 70 * i));
    }
    assert!(
        took.iter().all(|t| *t < Duration::from_millis(600)),
        "hook → delta took {took:?}"
    );

    c.send(json!({"t": "cmd", "id": 2, "op": "kill", "session": name}));
    c.until("kill ack", |v| is_ack(v, 2));
}

/// Create a `terminal` session through the daemon and return its tmux
/// name. `args` is the command typed into its shell (empty: none).
fn create_terminal(c: &mut Conn, id: u64, name: &str, args: &str) -> String {
    c.send(json!({
        "t": "cmd", "id": id, "op": "create",
        "spec": {"name": name, "path": "/tmp", "agent": "terminal", "args": args}
    }));
    let seen = c.until("create ack", |v| is_ack(v, id));
    let ack = seen.last().unwrap();
    assert_eq!(ack["ok"], true, "{ack}");
    ack["session"].as_str().unwrap().to_string()
}

fn wait_for(what: &str, timeout: Duration, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + timeout;
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn serve_launch_types_only_the_command() {
    let mut fx = fixture();
    let path = fx.start();
    let mut c = Conn::connect(&path);
    c.send(json!({"t": "hello", "protocol": 1}));
    assert_eq!(c.recv().expect("snapshot")["t"], "snapshot");

    // `cat` reads its terminal in cooked mode, the way an agent's
    // terminal is until it switches to raw mode, so any key Bosun sends
    // after the launch is echoed where this test can see it (a Ctrl-L
    // shows as `^L`).
    let name = create_terminal(&mut c, 1, "launch", "cat");
    let display = |format: &str| {
        let out = fx.tmux(&["display", "-p", "-t", &name, format]);
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    };
    wait_for("cat in the pane", Duration::from_secs(15), || {
        display("#{pane_current_command}") == "cat"
    });
    std::thread::sleep(Duration::from_millis(1500));
    let out = fx.tmux(&["capture-pane", "-p", "-t", &name]);
    let pane = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(
        !pane.contains("^L"),
        "something was typed after the launch:\n{pane}"
    );
    assert!(pane.contains("cat"), "{pane}");
}

/// A terminfo directory holding `xterm-ghostty-bosun`, the terminal type
/// Bosun for Mac's terminals attach with (built from `xterm-256color`,
/// which every system has; only the name matters here).
fn app_terminfo(dir: &std::path::Path) {
    let src = Command::new("infocmp")
        .args(["-x", "xterm-256color"])
        .output()
        .expect("infocmp");
    assert!(src.status.success(), "{src:?}");
    let text = String::from_utf8(src.stdout).unwrap();
    let renamed: String = text
        .lines()
        .map(|l| {
            if l.starts_with("xterm-256color|") {
                format!("xterm-ghostty-bosun|bosun app test terminal,")
            } else {
                l.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    let file = dir.join("app.src");
    std::fs::write(&file, renamed + "\n").unwrap();
    let out = Command::new("tic")
        .args(["-x", "-o"])
        .arg(dir)
        .arg(&file)
        .output()
        .expect("tic");
    assert!(out.status.success(), "{out:?}");
}

/// A terminal client (`tmux attach` in a pty from `script`) with the
/// given TERM. Killed on drop.
struct TermClient(Child);

impl TermClient {
    fn attach(fx: &Fixture, session: &str, term: &str, terminfo: &std::path::Path) -> Self {
        let tmux = format!("tmux -L {} attach -t ={}", fx.sock, session);
        let mut cmd = Command::new("script");
        if cfg!(target_os = "macos") {
            cmd.args(["-q", "/dev/null", "sh", "-c", &tmux]);
        } else {
            cmd.args(["-qfec", &tmux, "/dev/null"]);
        }
        let child = cmd
            .env("TERM", term)
            .env("TERMINFO", terminfo)
            .env_remove("TMUX")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("script");
        Self(child)
    }
}

impl Drop for TermClient {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn serve_reports_client_moves_and_hides_the_status_line_for_app_clients() {
    let mut fx = fixture();
    let terminfo = tempfile::tempdir().unwrap();
    app_terminfo(terminfo.path());
    let path = fx.start();
    let mut c = Conn::connect(&path);
    c.send(json!({"t": "hello", "protocol": 1}));
    assert_eq!(c.recv().expect("snapshot")["t"], "snapshot");
    let a = create_terminal(&mut c, 1, "first", "");
    let b = create_terminal(&mut c, 2, "second", "");

    let clients = || {
        let out = fx.tmux(&[
            "list-clients",
            "-F",
            "#{client_tty}|||#{client_session}|||#{client_termname}|||#{E:status-right}",
        ]);
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(|l| l.split("|||").map(str::to_string).collect::<Vec<_>>())
            .collect::<Vec<_>>()
    };
    let status = |session: &str| {
        let out = fx.tmux(&["display", "-p", "-t", session, "#{status}"]);
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    };
    wait_for("status lines on", Duration::from_secs(10), || {
        status(&a) == "on" && status(&b) == "on"
    });

    // The app's terminal attaches to A: reported, and A's status line goes.
    let app = TermClient::attach(&fx, &a, "xterm-ghostty-bosun", terminfo.path());
    let seen = c.until("client_session for A", |v| {
        v["t"] == "client_session" && v["session"] == a.as_str()
    });
    let tty = seen.last().unwrap()["tty"].as_str().unwrap().to_string();
    assert!(tty.starts_with("/dev/"), "{tty}");
    let row = clients()
        .into_iter()
        .find(|r| r[0] == tty)
        .expect("app client");
    assert_eq!(row[2], "xterm-ghostty-bosun");
    assert_eq!(row[3], "", "TUI hints on an app client");
    wait_for("A's status line off", Duration::from_secs(5), || {
        status(&a) == "off"
    });

    // Something moves it to B (a jump key typed inside it does the same).
    fx.tmux(&["switch-client", "-c", &tty, "-t", &format!("={b}")]);
    let seen = c.until("client_session for B", |v| v["t"] == "client_session");
    let moved = seen.last().unwrap();
    assert_eq!(moved["tty"], tty.as_str());
    assert_eq!(moved["session"], b.as_str());
    wait_for(
        "status lines follow the move",
        Duration::from_secs(5),
        || status(&a) == "on" && status(&b) == "off",
    );

    // Another kind of client on B brings the line back, with its hints.
    let other = TermClient::attach(&fx, &b, "xterm-256color", terminfo.path());
    wait_for("B's status line back", Duration::from_secs(5), || {
        status(&b) == "on"
    });
    let rows = clients();
    let hint = rows
        .iter()
        .find(|r| r[0] != tty && r[0].starts_with('/'))
        .map(|r| r[3].clone())
        .unwrap_or_default();
    assert!(
        hint.contains("detach"),
        "hints missing for a TUI client: {rows:?}"
    );
    drop(other);
    wait_for("B's status line off again", Duration::from_secs(5), || {
        status(&b) == "off"
    });

    // A detach is reported too.
    fx.tmux(&["detach-client", "-t", &tty]);
    // (The other client's detach, from dropping it above, comes first.)
    c.until("client_detached", |v| {
        v["t"] == "client_detached" && v["tty"] == tty.as_str()
    });
    wait_for(
        "B's status line on with nobody attached",
        Duration::from_secs(5),
        || status(&b) == "on",
    );
    drop(app);
}
