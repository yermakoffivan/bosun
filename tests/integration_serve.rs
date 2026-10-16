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
