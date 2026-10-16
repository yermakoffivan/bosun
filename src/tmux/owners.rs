//! Shared ownership of bosun's server-global bindings.
//!
//! Each bosun process (the TUI, and later the Mac app's daemon) installs
//! the same global key bindings on the tmux server — C-q, the
//! navigation keys, M-O and prefix-1..9 — and removes them when it
//! exits. With two processes on one server, the first to exit would
//! strip the bindings out from under the other. So each process records
//! its pid in a server user option, and only the last live owner
//! uninstalls. Pids of processes that died without cleaning up are
//! pruned whenever the list is touched.
//!
//! With a single bosun running this is the old behavior plus two cheap
//! tmux calls: register at start, find no other owner at exit, and
//! uninstall.

use crate::tmux::client::sync_tmux;

/// Server-global user option holding the owners' pids, space separated.
pub const OWNERS_OPTION: &str = "@bosun_owners";

/// Record this process as an owner of the global bindings. Idempotent,
/// so the binding self-heal can call it again to recover from a server
/// that lost the option.
pub fn register(socket: Option<&str>) {
    let current = read(socket);
    let next = next_owners(&current, Some(std::process::id()), None, pid_alive);
    if next != current {
        write(socket, &next);
    }
}

/// Drop this process from the owners and report whether it should
/// uninstall the global bindings: true when no other live owner remains.
pub fn release(socket: Option<&str>) -> bool {
    let current = read(socket);
    let next = next_owners(&current, None, Some(std::process::id()), pid_alive);
    if next != current {
        write(socket, &next);
    }
    next.is_empty()
}

/// The owner list after adding `add` and removing `remove`, with dead
/// pids pruned. Order is kept so the option stays readable. Pure.
pub fn next_owners(
    current: &[u32],
    add: Option<u32>,
    remove: Option<u32>,
    alive: impl Fn(u32) -> bool,
) -> Vec<u32> {
    let mut out: Vec<u32> = Vec::with_capacity(current.len() + 1);
    for &pid in current {
        if Some(pid) == remove || out.contains(&pid) {
            continue;
        }
        if Some(pid) == add || alive(pid) {
            out.push(pid);
        }
    }
    if let Some(pid) = add {
        if !out.contains(&pid) {
            out.push(pid);
        }
    }
    out
}

pub fn parse_owners(value: &str) -> Vec<u32> {
    value
        .split_whitespace()
        .filter_map(|p| p.parse::<u32>().ok())
        .filter(|&p| p > 0)
        .collect()
}

fn read(socket: Option<&str>) -> Vec<u32> {
    sync_tmux(socket, ["show-options", "-gqv", OWNERS_OPTION])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| parse_owners(&String::from_utf8_lossy(&o.stdout)))
        .unwrap_or_default()
}

fn write(socket: Option<&str>, owners: &[u32]) {
    let out = if owners.is_empty() {
        sync_tmux(socket, ["set-option", "-gu", OWNERS_OPTION]).output()
    } else {
        let value = owners
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(" ");
        sync_tmux(socket, ["set-option", "-g", OWNERS_OPTION, &value]).output()
    };
    if let Ok(o) = out {
        if !o.status.success() {
            tracing::warn!(
                "tmux {}: {}",
                OWNERS_OPTION,
                String::from_utf8_lossy(&o.stderr).trim()
            );
        }
    }
}

/// Whether a process with this pid exists. `kill(pid, 0)` delivers no
/// signal; EPERM still means the process is there (another user's).
#[cfg(unix)]
pub fn pid_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return false;
    };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 performs only the existence/permission check.
    let rc = unsafe { libc::kill(pid, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
pub fn pid_alive(_pid: u32) -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_alive(_: u32) -> bool {
        true
    }

    #[test]
    fn single_owner_registers_and_is_last_out() {
        let after_start = next_owners(&[], Some(100), None, all_alive);
        assert_eq!(after_start, vec![100]);
        let after_exit = next_owners(&after_start, None, Some(100), all_alive);
        assert!(after_exit.is_empty(), "sole owner uninstalls");
    }

    #[test]
    fn second_owner_keeps_the_bindings_alive() {
        let owners = next_owners(&[100], Some(200), None, all_alive);
        assert_eq!(owners, vec![100, 200]);
        // 100 exits first: 200 is still there, so 100 must not uninstall.
        let owners = next_owners(&owners, None, Some(100), all_alive);
        assert_eq!(owners, vec![200]);
        // 200 exits last and uninstalls.
        assert!(next_owners(&owners, None, Some(200), all_alive).is_empty());
    }

    #[test]
    fn dead_owners_are_pruned() {
        // 300 crashed without releasing; it must not hold the bindings
        // hostage for the next process that exits.
        let alive = |p: u32| p != 300;
        assert_eq!(
            next_owners(&[300, 100], Some(200), None, alive),
            vec![100, 200]
        );
        assert!(next_owners(&[300, 200], None, Some(200), alive).is_empty());
    }

    #[test]
    fn registering_twice_is_idempotent() {
        assert_eq!(
            next_owners(&[100, 100], Some(100), None, all_alive),
            vec![100]
        );
    }

    #[test]
    fn parse_ignores_garbage() {
        assert_eq!(parse_owners(" 12 abc 0 34\n"), vec![12, 34]);
        assert!(parse_owners("").is_empty());
    }

    #[test]
    fn own_pid_is_alive_and_a_bogus_one_is_not() {
        assert!(pid_alive(std::process::id()));
        assert!(!pid_alive(0));
        assert!(!pid_alive(u32::MAX));
    }
}
