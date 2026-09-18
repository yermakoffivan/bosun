//! Attach / detach orchestration.
//!
//! The trick: we install `tmux bind-key -T root C-q detach-client` on the
//! bosun socket, and re-assert it on every refresh tick (see
//! `tmux_actor::do_refresh`). Re-asserting matters because some workflows
//! re-source tmux config or otherwise clobber the root key table mid-session;
//! a one-shot bind can silently disappear over the course of a long attach.
//! The binding is cleared when the tmux actor exits and by the panic hook.
//!
//! Alongside C-q we also install prefix-less S-Left / S-Right bindings that
//! walk recently-used sessions in MRU order (see `ensure_session_cycle_bound`).
//! Same lifecycle: re-asserted every refresh tick, cleared on shutdown and
//! by the panic hook.
//!
//! This module uses synchronous `std::process::Command` for attach because
//! we're handing the controlling tty over to tmux — there is no async to do
//! while blocked in `attach-session`.

use std::process::Command;

use crate::error::{BosunError, Result};
use crate::tmux::client::sync_tmux;

/// Block on `tmux attach-session -t <name>`. The `C-q -> detach-client`
/// root binding is owned by the tmux actor's lifecycle — it's re-asserted
/// on every refresh tick — so this function no longer installs/removes it.
///
/// This function **takes over the controlling tty** until the user detaches.
/// The caller must have torn down its ratatui Terminal (`disable_raw_mode`,
/// `LeaveAlternateScreen`) before calling, and restored it after.
pub fn attach_with_ctrl_q_detach(socket: Option<&str>, name: &str) -> Result<()> {
    // Belt-and-braces: re-assert right before attach in case the last
    // tick was long enough ago that the binding could have been lost.
    // `bind-key` is idempotent in tmux (repeated binds overwrite).
    ensure_ctrl_q_bound(socket);
    run_attach(socket, name)
}

/// Install (or re-assert) the `C-q -> detach-client` root binding.
/// Idempotent — `bind-key` silently overwrites an existing binding.
/// Failure is logged but not returned: we don't want a transient tmux
/// hiccup to turn into a surfaced error on every refresh tick.
pub fn ensure_ctrl_q_bound(socket: Option<&str>) {
    let out = sync_tmux(socket, ["bind-key", "-T", "root", "C-q", "detach-client"]).output();
    match out {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            tracing::warn!("bind-key C-q: {}", stderr.trim());
        }
        Err(e) => tracing::warn!("bind-key C-q: {}", e),
    }
}

/// Remove the `C-q -> detach-client` root binding. Called on clean
/// actor shutdown so we don't leave the bosun socket's tmux server
/// with a stray binding.
pub fn clear_ctrl_q_bound(socket: Option<&str>) {
    let out = sync_tmux(socket, ["unbind-key", "-T", "root", "C-q"]).output();
    if let Ok(o) = out {
        if !o.status.success() {
            let stderr = String::from_utf8_lossy(&o.stderr);
            tracing::warn!("unbind-key C-q: {}", stderr.trim());
        }
    }
}

fn run_attach(socket: Option<&str>, name: &str) -> Result<()> {
    let status = sync_tmux(socket, ["attach-session", "-t", name])
        .status()
        .map_err(BosunError::Io)?;
    if !status.success() {
        return Err(BosunError::Tmux(format!(
            "attach-session -t {} failed: {}",
            name, status
        )));
    }
    Ok(())
}

/// Panic-safe cleanup: call this from a `std::panic::set_hook` to make sure
/// we don't leave a dangling `C-q` binding (or the S-Left / S-Right cycle
/// binds) if Bosun crashes.
/// Uses `output()` so any error text is captured instead of spilled.
pub fn emergency_unbind(socket: Option<&str>) {
    clear_session_cycle_bound(socket);
    let runs: &[&[&str]] = &[
        &["unbind-key", "-T", "root", "C-q"],
        &["unbind-key", "-T", "prefix", "o"],
    ];
    for args in runs {
        let mut argv: Vec<&str> = Vec::with_capacity(args.len() + 2);
        if let Some(s) = socket {
            argv.push("-L");
            argv.push(s);
        }
        argv.extend_from_slice(args);
        let _ = Command::new("tmux").args(&argv).output();
    }
}

/// Install (or re-assert) the S-Left / S-Right prefix-less bindings that
/// cycle between sessions in most-recently-attached order.
///
/// We use shift+arrow instead of option+arrow because tmux's default
/// `M-Left`/`M-Right` bindings (pane navigation) are still useful even
/// inside bosun's tmux server. Applications may also use these keys;
/// configured navigation and send-next-key let them reach the application.
///
/// - `S-Left` (shift+left) → the single most-recently-attached session
///   other than the current one. Acts as a fast A↔B toggle.
/// - `S-Right` (shift+right) → the **second** most-recently-attached
///   non-current session, so repeated taps walk a 3-session active set.
///   Falls back to the most-recent-non-current if only one candidate
///   exists.
///
/// The bindings are prefix-less (`-n`) so they work from inside any tmux
/// session without needing the bosun prefix. The socket flag is baked into
/// the `run-shell` body so the inner tmux invocations talk to the same
/// server the bind lives on.
///
/// Idempotent — `bind-key` overwrites. Failures are logged but not
/// returned: a transient hiccup on a refresh tick shouldn't bubble up.
pub fn ensure_session_cycle_bound(socket: Option<&str>) {
    ensure_keybindings_bound(socket, &crate::keybindings::KeyBindings::default());
}

/// Install configured navigation and a one-key tmux bypass. Save overwritten
/// root bindings on the server so shutdown (including panic cleanup) restores
/// them, and repeated self-healing never mistakes our bindings for originals.
pub fn ensure_keybindings_bound(socket: Option<&str>, keys: &crate::keybindings::KeyBindings) {
    use crate::keybindings::Action;
    let tmux = match socket {
        Some(s) => format!("tmux -L {}", shell_quote(s)),
        None => "tmux".to_string(),
    };

    // tmux's `session_last_attached` is empty for never-attached
    // sessions, which makes default awk field-splitting return the
    // name in $1 instead of $2. Wrap it in a `?:,0` conditional so
    // every row starts with a numeric timestamp, even if it's just 0.
    //
    // Why the doubled `##`: `run-shell` format-expands its argument
    // when the key fires, so a literal `#{session_name}` in the bind
    // body would get substituted against the current session before
    // /bin/sh ever runs. We need the inner `list-sessions -F` to do
    // the per-row expansion, so we write `##{...}` here — tmux's
    // expansion at trigger time collapses each `##` to `#`, leaving
    // the actual format string intact for the nested tmux invocation.
    // Same trick for `##S` in display-message.
    let fmt = "##{?session_last_attached,##{session_last_attached},0} ##{session_name}";
    // Excluded from cycle nav: bosun's internal control-mode monitor
    // session (see `tmux::control_client::MONITOR_SESSION`). Users
    // should never end up looking at its single inert pane.
    let exclude = crate::tmux::control_client::MONITOR_SESSION;

    // shift+Left → 1st non-current in MRU desc order.
    let left_cmd = format!(
        "T=$({tmux} list-sessions -F '{fmt}' \
         | sort -rnk1 \
         | awk -v cur=\"$({tmux} display-message -p '##S')\" \
               '$2 != cur && $2 != \"{exclude}\" {{print $2; exit}}'); \
         if [ -n \"$T\" ]; then {tmux} switch-client -t \"$T\"; fi"
    );

    // shift+Right → 2nd non-current in MRU desc order, fall back to 1st.
    let right_cmd = format!(
        "cur=$({tmux} display-message -p '##S'); \
         L=$({tmux} list-sessions -F '{fmt}' \
         | sort -rnk1 \
         | awk -v cur=\"$cur\" \
               '$2 != cur && $2 != \"{exclude}\" {{print $2}}'); \
         T=$(printf '%s\\n' \"$L\" | sed -n '2p'); \
         [ -z \"$T\" ] && T=$(printf '%s\\n' \"$L\" | sed -n '1p'); \
         if [ -n \"$T\" ]; then {tmux} switch-client -t \"$T\"; fi"
    );

    let mut plan: std::collections::BTreeMap<String, Vec<String>> =
        std::collections::BTreeMap::new();
    // tmux ships root S-Left/S-Right window bindings. Explicit forwarding
    // releases those keys when navigation is disabled or moved elsewhere.
    for key in ["S-Left", "S-Right"] {
        plan.insert(key.into(), vec!["send-keys".into()]);
    }
    for (action, key) in &keys.0 {
        let command = match action {
            Action::PreviousTab | Action::PreviousSession => {
                vec!["run-shell".into(), left_cmd.clone()]
            }
            Action::NextTab | Action::NextSession => vec!["run-shell".into(), right_cmd.clone()],
            Action::SendNextKey => vec![
                "switch-client".into(),
                "-T".into(),
                QUOTE_TABLE.into(),
                "\\;".into(),
                "display-message".into(),
                "Send next key to app…".into(),
            ],
        };
        plan.insert(key.tmux.clone(), command);
    }

    let mut saved = saved_bindings(socket);
    // A previous process may have stopped before cleanup. Restore keys no
    // longer owned by this configuration before installing the new mapping.
    let removed: Vec<_> = saved
        .keys()
        .filter(|key| !plan.contains_key(*key))
        .cloned()
        .collect();
    for key in removed {
        if let Some(original) = saved.remove(&key) {
            restore_binding(socket, &key, &original);
        }
    }
    let current = sync_tmux(socket, ["list-keys", "-T", "root"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    for key in plan.keys() {
        if !saved.contains_key(key) {
            let old = current
                .lines()
                .find(|line| {
                    line.split_whitespace().skip_while(|s| *s != "-T").nth(2) == Some(key.as_str())
                })
                .map(|line| format!("{line}\n"))
                .unwrap_or_default();
            saved.insert(key.clone(), old);
        }
    }
    // Persist before any mutation so cleanup can recover after a partial install.
    let serialized = serde_json::to_string(&saved).expect("serialize binding map");
    if !binding_command(socket, &["set-option", "-g", RESTORE_OPTION, &serialized]) {
        return;
    }
    binding_command(socket, &["bind-key", "-T", QUOTE_TABLE, "Any", "send-keys"]);
    for (key, command) in plan {
        let mut args = vec!["bind-key", "-T", "root", key.as_str()];
        args.extend(command.iter().map(String::as_str));
        binding_command(socket, &args);
    }
    let hint = format!(
        "{} / {} cycle · {} send next",
        keys.label(Action::PreviousTab),
        keys.label(Action::NextTab),
        keys.label(Action::SendNextKey)
    );
    binding_command(socket, &["set-option", "-g", HINT_OPTION, &hint]);
}

const QUOTE_TABLE: &str = "bosun-send-next";
const RESTORE_OPTION: &str = "@bosun_input_restore";
pub const HINT_OPTION: &str = "@bosun_input_hint";

fn binding_command(socket: Option<&str>, args: &[&str]) -> bool {
    match sync_tmux(socket, args.iter().copied()).output() {
        Ok(o) if o.status.success() => true,
        Ok(o) => {
            tracing::warn!(
                "tmux input binding: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            );
            false
        }
        Err(e) => {
            tracing::warn!("tmux input binding: {e}");
            false
        }
    }
}

fn saved_bindings(socket: Option<&str>) -> std::collections::BTreeMap<String, String> {
    sync_tmux(socket, ["show-options", "-gqv", RESTORE_OPTION])
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice(&o.stdout).ok())
        .unwrap_or_default()
}

/// Restore the root table, including tmux's original Shift+arrow bindings,
/// and remove our one-shot table. Used on normal shutdown and by the panic hook.
pub fn clear_session_cycle_bound(socket: Option<&str>) {
    for (key, original) in saved_bindings(socket) {
        restore_binding(socket, &key, &original);
    }
    binding_command(socket, &["unbind-key", "-a", "-T", QUOTE_TABLE]);
    binding_command(socket, &["set-option", "-gu", RESTORE_OPTION]);
    binding_command(socket, &["set-option", "-gu", HINT_OPTION]);
}

fn restore_binding(socket: Option<&str>, key: &str, original: &str) {
    use std::io::Write;
    use std::process::Stdio;
    binding_command(socket, &["unbind-key", "-T", "root", key]);
    if original.is_empty() {
        return;
    }
    // list-keys emits tmux source syntax; feed it directly to tmux,
    // without interpreting the user's original command in a shell.
    match sync_tmux(socket, ["source-file", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(mut child) => {
            if let Some(mut stdin) = child.stdin.take() {
                if let Err(e) = stdin.write_all(original.as_bytes()) {
                    tracing::warn!("restoring tmux {key}: {e}");
                }
            }
            match child.wait_with_output() {
                Ok(o) if o.status.success() => {}
                Ok(o) => tracing::warn!(
                    "restoring tmux {key}: {}",
                    String::from_utf8_lossy(&o.stderr)
                ),
                Err(e) => tracing::warn!("restoring tmux {key}: {e}"),
            }
        }
        Err(e) => tracing::warn!("restoring tmux {key}: {e}"),
    }
}

/// Install (or re-assert) the `prefix + o` quick-jump binding. Opens
/// a floating tmux popup running `choose-tree -Zs` — built-in fuzzy
/// session picker with type-ahead. Enter switches to the chosen
/// session, Escape closes the popup.
///
/// We bind under the user's prefix (typically C-a) rather than a
/// modifier-key combo so it works without any terminal-emulator
/// configuration. shift+option+o would require iTerm's "Left Option
/// Key" to be set to Esc+/Meta, which we can't expect — and on most
/// macOS terminals it renders as `Ø` by default.
///
/// `__bosun_monitor` is filtered out so it never appears in the
/// chooser.
///
/// Idempotent — `bind-key` overwrites. Failures are logged, not
/// returned.
pub fn ensure_quick_jump_bound(socket: Option<&str>) {
    let tmux = match socket {
        Some(s) => format!("tmux -L {}", shell_quote(s)),
        None => "tmux".to_string(),
    };
    let exclude = crate::tmux::control_client::MONITOR_SESSION;
    // `display-popup -E` format-expands its argument at trigger time
    // (same gotcha as `run-shell` for S-Left/S-Right). We want the
    // `#{!=:#{session_name},__bosun_monitor}` filter to reach
    // `choose-tree -f` literally and be evaluated per-row there, so
    // we double-hash. tmux's expansion collapses each `##` to `#`,
    // leaving the format spec intact for the inner tmux invocation.
    let cmd = format!("{tmux} choose-tree -Zs -f '##{{!=:##{{session_name}},{exclude}}}'");
    let out = sync_tmux(
        socket,
        [
            "bind-key",
            "-T",
            "prefix",
            "o",
            "display-popup",
            "-E",
            "-h",
            "70%",
            "-w",
            "60%",
            "-T",
            " bosun · quick switch ",
            &cmd,
        ],
    )
    .output();
    match out {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            tracing::warn!("bind-key prefix o: {}", stderr.trim());
        }
        Err(e) => tracing::warn!("bind-key prefix o: {}", e),
    }
}

/// Remove the `prefix + o` quick-jump binding.
pub fn clear_quick_jump_bound(socket: Option<&str>) {
    let out = sync_tmux(socket, ["unbind-key", "-T", "prefix", "o"]).output();
    if let Ok(o) = out {
        if !o.status.success() {
            let stderr = String::from_utf8_lossy(&o.stderr);
            tracing::warn!("unbind-key prefix o: {}", stderr.trim());
        }
    }
}

/// Minimal POSIX shell single-quote escaper. Wraps the value in `'…'`,
/// turning any embedded `'` into `'\''`. Good enough for tmux socket
/// names — typically just `[A-Za-z0-9_-]+`, but we don't want a surprise
/// command injection if someone puts a quote in `BOSUN_TMUX_SOCKET`.
fn shell_quote(s: &str) -> String {
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
