//! When each session's current turn started, for the clients' working
//! timer.
//!
//! A turn starts when a session is first seen running or waiting, and
//! carries on through permission waits until the agent is done. The
//! hook's own `@bosun_state_at` can't stand in for it: every tool call
//! rewrites it.

use std::collections::HashMap;

use super::protocol::{StatusSourceWire, StatusWire};

/// A detector's guess can drop out of running for a moment (a quiet
/// second between spinner frames); a turn that comes back within this
/// long is the same turn. A hook's done or idle ends the turn at once.
pub const GRACE_MS: u64 = 5_000;

#[derive(Debug, Clone, Copy)]
struct Turn {
    started: u64,
    last_busy: u64,
    busy: bool,
}

#[derive(Debug, Default)]
pub struct TurnClock {
    turns: HashMap<String, Turn>,
}

impl TurnClock {
    /// Note `session`'s state at `now` (Unix ms).
    pub fn observe(
        &mut self,
        session: &str,
        state: StatusWire,
        source: StatusSourceWire,
        now: u64,
    ) {
        let busy = matches!(state, StatusWire::Running | StatusWire::Waiting);
        if !busy {
            if source == StatusSourceWire::Hook {
                self.turns.remove(session);
            } else if let Some(t) = self.turns.get_mut(session) {
                t.busy = false;
            }
            return;
        }
        match self.turns.get_mut(session) {
            Some(t) if t.busy || now.saturating_sub(t.last_busy) <= GRACE_MS => {
                t.last_busy = now;
                t.busy = true;
            }
            _ => {
                self.turns.insert(
                    session.to_string(),
                    Turn {
                        started: now,
                        last_busy: now,
                        busy: true,
                    },
                );
            }
        }
    }

    /// When `session`'s turn started, while it's running or waiting.
    pub fn started(&self, session: &str) -> Option<u64> {
        self.turns
            .get(session)
            .filter(|t| t.busy)
            .map(|t| t.started)
    }

    /// Forget sessions that are gone.
    pub fn retain(&mut self, live: impl Fn(&str) -> bool) {
        self.turns.retain(|s, _| live(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use StatusSourceWire::{Detector, Hook};
    use StatusWire::{Idle, Running, Waiting};

    #[test]
    fn a_turn_runs_through_waits_until_done() {
        let mut c = TurnClock::default();
        c.observe("a", Idle, Hook, 1_000);
        assert_eq!(c.started("a"), None);
        c.observe("a", Running, Hook, 2_000);
        assert_eq!(c.started("a"), Some(2_000));
        c.observe("a", Waiting, Hook, 30_000);
        c.observe("a", Running, Hook, 90_000);
        assert_eq!(c.started("a"), Some(2_000));
        // The hook says done (idle with done_at): the turn is over, and
        // the next prompt starts a new one even straight away.
        c.observe("a", Idle, Hook, 91_000);
        assert_eq!(c.started("a"), None);
        c.observe("a", Running, Hook, 92_000);
        assert_eq!(c.started("a"), Some(92_000));
    }

    #[test]
    fn a_detector_blip_keeps_the_turn_and_a_long_pause_starts_a_new_one() {
        let mut c = TurnClock::default();
        c.observe("a", Running, Detector, 10_000);
        c.observe("a", Running, Detector, 11_000);
        c.observe("a", Idle, Detector, 12_000);
        assert_eq!(c.started("a"), None);
        c.observe("a", Running, Detector, 11_000 + GRACE_MS);
        assert_eq!(c.started("a"), Some(10_000));
        c.observe("a", Idle, Detector, 20_000);
        c.observe("a", Running, Detector, 30_000);
        assert_eq!(c.started("a"), Some(30_000));
    }

    #[test]
    fn retain_forgets_gone_sessions() {
        let mut c = TurnClock::default();
        c.observe("a", Running, Hook, 1);
        c.observe("b", Running, Hook, 1);
        c.retain(|s| s == "b");
        assert_eq!(c.started("a"), None);
        assert_eq!(c.started("b"), Some(1));
    }
}
