//! Warnings for a tmux server that can't run Bosun's sessions, each
//! pointing at docs/troubleshooting.md (issue #21).

use std::time::Duration;

use tokio::process::Command;

/// Where the warnings send people: the page's path in the repository,
/// short enough to survive the TUI's one-line status bar.
pub const TROUBLESHOOTING_DOC: &str = "docs/troubleshooting.md";

/// The same page in full, for the log.
pub const TROUBLESHOOTING_URL: &str =
    "https://github.com/yetidevworks/bosun/blob/main/docs/troubleshooting.md";

/// How long a new session has to stay up before Bosun stops watching
/// for it to close by itself.
pub const STARTUP_GRACE: Duration = Duration::from_millis(1500);

/// The warning for a session that closed before anyone ended it.
pub fn closed_at_start(display: &str) -> String {
    format!("{display} closed as soon as it started. See {TROUBLESHOOTING_DOC}")
}

/// Compare the tmux an already-running server was started with against
/// `tmux -V`. Updating tmux leaves a running server on the old
/// version. A newer client often still works with it, but when it
/// can't, new sessions close as soon as they open, so the warning only
/// says what to do if that happens. None when they match, when
/// there's no server yet (the one Bosun starts will be current), or
/// when either can't be read.
pub async fn server_version_warning(socket: Option<&str>) -> Option<String> {
    let client = Command::new("tmux").arg("-V").output().await.ok()?;
    if !client.status.success() {
        return None;
    }
    let mut cmd = Command::new("tmux");
    if let Some(s) = socket {
        cmd.arg("-L").arg(s);
    }
    let server = cmd
        .args(["display-message", "-p", "#{version}"])
        .output()
        .await
        .ok()?;
    let reply = if server.status.success() {
        Ok(String::from_utf8_lossy(&server.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&server.stderr).into_owned())
    };
    mismatch_message(&String::from_utf8_lossy(&client.stdout), reply, socket)
}

/// The warning for `tmux -V`'s output against the server's reply to
/// `display-message -p '#{version}'` (its stdout, or its stderr when it
/// failed).
fn mismatch_message(
    client: &str,
    server: Result<String, String>,
    socket: Option<&str>,
) -> Option<String> {
    let client = client.trim();
    let client = client.strip_prefix("tmux ").unwrap_or(client);
    let server = match server {
        Ok(v) => v.trim().to_string(),
        // A client too new for the server refuses to talk to it.
        Err(e) if e.contains("protocol version mismatch") => "an older version".to_string(),
        Err(_) => return None,
    };
    if server.is_empty() || server == client {
        return None;
    }
    let kill = match socket {
        Some(s) => format!("tmux -L {s} kill-server"),
        None => "tmux kill-server".to_string(),
    };
    let server = if server.starts_with(|c: char| c.is_ascii_digit()) {
        format!("tmux {server}")
    } else {
        server
    };
    Some(format!(
        "Bosun's tmux server is still on {server} but tmux is now {client}. If new sessions \
         close, quit Bosun and run `{kill}` (ends its sessions). See {TROUBLESHOOTING_DOC}"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_versions_say_nothing() {
        assert_eq!(
            mismatch_message("tmux 3.8\n", Ok("3.8\n".into()), Some("bosun")),
            None
        );
    }

    #[test]
    fn an_older_server_names_both_versions_and_the_socket() {
        let m = mismatch_message("tmux 3.8\n", Ok("3.7c\n".into()), Some("bosun")).unwrap();
        assert!(m.contains("still on tmux 3.7c"), "{m}");
        assert!(m.contains("tmux is now 3.8"), "{m}");
        assert!(m.contains("`tmux -L bosun kill-server`"), "{m}");
        assert!(m.ends_with(TROUBLESHOOTING_DOC), "{m}");
    }

    #[test]
    fn the_shared_server_gets_a_plain_kill_server() {
        let m = mismatch_message("tmux 3.8", Ok("3.7c".into()), None).unwrap();
        assert!(m.contains("`tmux kill-server`"), "{m}");
    }

    #[test]
    fn a_refused_connection_is_a_mismatch_but_no_server_is_not() {
        let refused = Err("protocol version mismatch (client 9, server 8)\n".to_string());
        let m = mismatch_message("tmux 3.8", refused, Some("bosun")).unwrap();
        assert!(m.contains("still on an older version"), "{m}");
        let none = Err("no server running on /private/tmp/tmux-501/bosun\n".to_string());
        assert_eq!(mismatch_message("tmux 3.8", none, Some("bosun")), None);
    }

    #[test]
    fn the_closed_warning_names_the_session_and_the_page() {
        let m = closed_at_start("api");
        assert!(m.starts_with("api closed as soon as it started"), "{m}");
        assert!(m.ends_with(TROUBLESHOOTING_DOC), "{m}");
    }
}
