//! Generic activity-based detector. Last-resort priority.
//!
//! Heuristic: we don't know what tool is running, so we use the
//! session's `session_activity` age to guess.
//!   * < 2s since last activity → Running
//!   * 2s – 30s                 → Waiting (might be a prompt)
//!   * > 30s                    → Idle
//!
//! A pane whose foreground process is a shell has nothing running: it
//! is sitting at a prompt (or the user is typing at one), so it reads
//! as Idle whatever its activity. Without this, every plain terminal
//! session read as Waiting for 30 s after each keystroke or prompt
//! redraw, which made Waiting mean nothing. A command started from
//! that shell (`cargo build`, a REPL) is the foreground process
//! instead, and gets the activity heuristic as before.
//!
//! This is intentionally simple. Agent-specific detectors (claude,
//! codex) register at higher priority and will override it when
//! they're confident.

use std::time::Duration;

use super::{DetectContext, Status, StatusDetector};
use crate::agent_hooks::is_shell_command;

pub struct GenericDetector;

impl StatusDetector for GenericDetector {
    fn name(&self) -> &'static str {
        "generic"
    }

    fn priority(&self) -> u8 {
        10
    }

    fn detect(&self, ctx: &DetectContext<'_>) -> Status {
        if ctx.pane_command.is_some_and(is_shell_command) {
            Status::Idle
        } else if ctx.activity_age < Duration::from_secs(2) {
            Status::Running
        } else if ctx.activity_age < Duration::from_secs(30) {
            Status::Waiting
        } else {
            Status::Idle
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use super::*;

    fn ctx_with_age(secs: u64) -> DetectContext<'static> {
        let now = SystemTime::now();
        let ago = now - Duration::from_secs(secs);
        DetectContext::from_parts(b"", "", Some(ago), now, None, "s", None, None)
    }

    #[test]
    fn recent_activity_is_running() {
        assert_eq!(GenericDetector.detect(&ctx_with_age(0)), Status::Running);
        assert_eq!(GenericDetector.detect(&ctx_with_age(1)), Status::Running);
    }

    #[test]
    fn mid_range_is_waiting() {
        assert_eq!(GenericDetector.detect(&ctx_with_age(5)), Status::Waiting);
        assert_eq!(GenericDetector.detect(&ctx_with_age(20)), Status::Waiting);
    }

    fn ctx_with_command(secs: u64, command: &'static str) -> DetectContext<'static> {
        let now = SystemTime::now();
        let ago = now - Duration::from_secs(secs);
        DetectContext::from_parts(b"", "", Some(ago), now, None, "s", None, Some(command))
    }

    #[test]
    fn shell_at_its_prompt_is_idle_not_waiting() {
        for shell in ["zsh", "-zsh", "bash", "fish", "sh"] {
            for secs in [0, 1, 5, 20, 60] {
                assert_eq!(
                    GenericDetector.detect(&ctx_with_command(secs, shell)),
                    Status::Idle,
                    "{shell} quiet for {secs}s"
                );
            }
        }
    }

    #[test]
    fn command_started_from_a_shell_keeps_the_activity_heuristic() {
        assert_eq!(
            GenericDetector.detect(&ctx_with_command(0, "cargo")),
            Status::Running
        );
        assert_eq!(
            GenericDetector.detect(&ctx_with_command(5, "python3")),
            Status::Waiting
        );
        assert_eq!(
            GenericDetector.detect(&ctx_with_command(60, "node")),
            Status::Idle
        );
    }

    #[test]
    fn old_activity_is_idle() {
        assert_eq!(GenericDetector.detect(&ctx_with_age(60)), Status::Idle);
        assert_eq!(GenericDetector.detect(&ctx_with_age(3600)), Status::Idle);
    }
}
