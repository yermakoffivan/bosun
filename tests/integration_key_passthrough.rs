//! Exercise the real client key table: send-keys directly to a pane would
//! bypass the very bindings these tests need to verify.
#![cfg(feature = "tmux-it")]

use std::io::{Read, Write};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(0);

use bosun::keybindings::{BindingsConfig, KeyBindings};
use bosun::tmux::attach::{
    clear_session_cycle_bound, ensure_ctrl_q_bound, ensure_keybindings_bound,
};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};

struct Session {
    socket: String,
    dir: tempfile::TempDir,
    child: Option<Box<dyn Child + Send + Sync>>,
    writer: Option<Box<dyn Write + Send>>,
    master: Option<Box<dyn MasterPty + Send>>,
    original_root: String,
}

impl Session {
    fn new(keys: &KeyBindings) -> Self {
        let socket = format!(
            "bosun-quote-{}-{}-{}",
            std::process::id(),
            NEXT_SOCKET.fetch_add(1, Ordering::Relaxed),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let dir = tempfile::tempdir().unwrap();
        let mut s = Self {
            socket,
            dir,
            child: None,
            writer: None,
            master: None,
            original_root: String::new(),
        };
        let script = s.dir.path().join("record.py");
        std::fs::write(
            &script,
            r#"import os, pathlib, tty
root = pathlib.Path(__file__).parent
tty.setraw(0)
(root / 'ready').touch()
with (root / 'input').open('ab', buffering=0) as out:
    while True:
        out.write(os.read(0, 4096))
"#,
        )
        .unwrap();
        // TempDir paths are generated locally; single-quote for spaces on macOS.
        let command = format!("python3 '{}'", script.display());
        s.tmux(&[
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            "sink",
            &command,
        ]);
        // Feed synthetic keystrokes as a batch without tmux 3.4 treating
        // their sub-millisecond timing as a paste and skipping key bindings.
        s.tmux(&["set-option", "-t", "sink", "assume-paste-time", "0"]);
        wait_until(|| s.dir.path().join("ready").exists());
        ensure_ctrl_q_bound(Some(&s.socket));
        s.original_root = s.tmux(&["list-keys", "-T", "root"]);
        ensure_keybindings_bound(Some(&s.socket), keys);
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 120,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut command = CommandBuilder::new("tmux");
        command.args(["-L", &s.socket, "attach", "-t", "sink"]);
        command.env("TERM", "xterm-256color");
        s.child = Some(pair.slave.spawn_command(command).unwrap());
        drop(pair.slave);
        s.writer = Some(pair.master.take_writer().unwrap());
        let mut reader = pair.master.try_clone_reader().unwrap();
        std::thread::spawn(move || {
            let mut buf = [0; 8192];
            while matches!(reader.read(&mut buf), Ok(n) if n > 0) {}
        });
        s.master = Some(pair.master);
        wait_until(|| {
            !s.tmux(&["list-clients", "-F", "#{client_name}"])
                .trim()
                .is_empty()
        });
        s
    }

    fn tmux(&self, args: &[&str]) -> String {
        let out = Command::new("tmux")
            .args(["-L", &self.socket])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "tmux {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).to_string()
    }

    fn send(&mut self, input: &[u8], expected: &[u8]) {
        self.writer.as_mut().unwrap().write_all(input).unwrap();
        self.writer.as_mut().unwrap().flush().unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.input().len() < expected.len() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            self.input().len() >= expected.len(),
            "input={:?}, expected={expected:?}, root={}, table={}",
            self.input(),
            self.tmux(&["list-keys", "-T", "root"]),
            self.tmux(&["list-clients", "-F", "#{client_key_table}"])
        );
        assert_eq!(self.input(), expected);
    }

    fn input(&self) -> Vec<u8> {
        std::fs::read(self.dir.path().join("input")).unwrap_or_default()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = Command::new("tmux")
            .args(["-L", &self.socket, "kill-server"])
            .output();
    }
}

fn wait_until(mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !predicate() {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for tmux input"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn quoted_keys_bypass_root_bindings_exactly_once() {
    let mut s = Session::new(&KeyBindings::default());
    s.send(b"\x16\x1b[1;2C", b"\x1b[1;2C");
    // The table must reset: the next unquoted Shift+Right is consumed by
    // Bosun's cycle binding; the following ordinary character reaches the pane.
    s.send(b"\x1b[1;2Cx", b"\x1b[1;2Cx");
    s.send(b"\x16\x16", b"\x1b[1;2Cx\x16");
    s.send(b"\x16\x11", b"\x1b[1;2Cx\x16\x11");
    s.send(b"z", b"\x1b[1;2Cx\x16\x11z");
    assert_eq!(
        s.tmux(&["list-clients", "-F", "#{client_key_table}"])
            .trim(),
        "root"
    );
}

#[test]
fn remapped_and_disabled_arrows_reach_the_application() {
    let keys = BindingsConfig {
        previous_tab: "none".into(),
        next_tab: "Ctrl+Shift+Right".into(),
        previous_session: "none".into(),
        next_session: "none".into(),
        send_next_key: "F12".into(),
    }
    .resolve()
    .unwrap();
    let mut s = Session::new(&keys);
    s.send(
        b"\x1b[1;2D\x1b[1;2C\x1b[1;2A\x1b[1;2B",
        b"\x1b[1;2D\x1b[1;2C\x1b[1;2A\x1b[1;2B",
    );
    // Remapped prefix F12 quotes the remapped Ctrl+Shift+Right.
    s.send(
        b"\x1b[24~\x1b[1;6C",
        b"\x1b[1;2D\x1b[1;2C\x1b[1;2A\x1b[1;2B\x1b[1;6C",
    );
    ensure_keybindings_bound(Some(&s.socket), &keys);
    clear_session_cycle_bound(Some(&s.socket));
    let root = s.tmux(&["list-keys", "-T", "root"]);
    assert!(!root.contains("bosun-send-next"));
    assert_eq!(
        root, s.original_root,
        "original tmux root bindings restored"
    );
}

#[test]
fn cleanup_restores_existing_custom_bindings() {
    let s = Session::new(&KeyBindings::default());
    clear_session_cycle_bound(Some(&s.socket));
    s.tmux(&[
        "bind-key",
        "-n",
        "C-v",
        "display-message",
        "original quote binding",
    ]);
    for _ in 0..2 {
        ensure_keybindings_bound(Some(&s.socket), &KeyBindings::default());
    }
    clear_session_cycle_bound(Some(&s.socket));
    let binding = s.tmux(&["list-keys", "-T", "root"]);
    assert!(binding.contains("original quote binding"), "{binding}");
}

#[test]
fn changed_configuration_removes_old_shortcuts() {
    let mut s = Session::new(&KeyBindings::default());
    let keys = BindingsConfig {
        previous_tab: "Ctrl+Shift+Left".into(),
        next_tab: "Ctrl+Shift+Right".into(),
        previous_session: "none".into(),
        next_session: "none".into(),
        send_next_key: "Alt+Left".into(),
    }
    .resolve()
    .unwrap();
    ensure_keybindings_bound(Some(&s.socket), &keys);
    // Original Ctrl+V and Shift+Down are no longer intercepted; a quoted
    // Shift+Right with the new Alt+Left prefix still bypasses both layers.
    s.send(
        b"\x16\x1b[1;2B\x1b[1;3D\x1b[1;2C",
        b"\x16\x1b[1;2B\x1b[1;2C",
    );
    clear_session_cycle_bound(Some(&s.socket));
    assert_eq!(s.tmux(&["list-keys", "-T", "root"]), s.original_root);
}
