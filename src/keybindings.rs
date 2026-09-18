//! Configurable shortcuts for a focused session. Matching uses exact modifiers
//! so keys released by a remap really reach the application.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    PreviousTab,
    NextTab,
    PreviousSession,
    NextSession,
    SendNextKey,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shortcut {
    pub event: KeyEvent,
    pub label: String,
    pub tmux: String,
}

impl Shortcut {
    pub fn parse(value: &str) -> Result<Option<Self>, String> {
        let value = value.trim();
        if value.is_empty() || value.eq_ignore_ascii_case("none") {
            return Ok(None);
        }
        let parts: Vec<_> = value.split('+').map(str::trim).collect();
        let mut modifiers = KeyModifiers::NONE;
        for part in &parts[..parts.len() - 1] {
            modifiers |= match part.to_ascii_lowercase().as_str() {
                "ctrl" | "control" => KeyModifiers::CONTROL,
                "alt" | "option" => KeyModifiers::ALT,
                "shift" => KeyModifiers::SHIFT,
                _ => return Err(format!("unknown modifier in {value:?}")),
            };
        }
        let key = parts.last().unwrap().to_ascii_lowercase();
        let (code, name) = match key.as_str() {
            "left" => (KeyCode::Left, "Left".to_string()),
            "right" => (KeyCode::Right, "Right".to_string()),
            "up" => (KeyCode::Up, "Up".to_string()),
            "down" => (KeyCode::Down, "Down".to_string()),
            k if k.starts_with('f') && k[1..].parse::<u8>().is_ok() => {
                let n = k[1..].parse::<u8>().unwrap();
                if !(1..=12).contains(&n) {
                    return Err("only F1 through F12 are supported".into());
                }
                (KeyCode::F(n), format!("F{n}"))
            }
            k if k.len() == 1 && k.as_bytes()[0].is_ascii_alphabetic() => {
                // Ctrl+Shift+letter collapses to Ctrl+letter in ordinary
                // terminals. Don't advertise a binding we can't distinguish.
                if !modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
                    || modifiers.contains(KeyModifiers::SHIFT)
                {
                    return Err("letter shortcuts require Ctrl or Alt, without Shift".into());
                }
                if modifiers.contains(KeyModifiers::CONTROL) && matches!(k, "h" | "i" | "j" | "m") {
                    return Err(
                        "Ctrl+H/I/J/M are terminal aliases for Backspace, Tab, or Enter".into(),
                    );
                }
                (KeyCode::Char(k.chars().next().unwrap()), k.to_string())
            }
            _ => {
                return Err(format!(
                    "unsupported key in {value:?}; use arrows, F1–F12, or Ctrl/Alt+letter"
                ))
            }
        };
        let mut label = String::new();
        let mut tmux = String::new();
        for (flag, long, short) in [
            (KeyModifiers::CONTROL, "Ctrl+", "C-"),
            (KeyModifiers::ALT, "Alt+", "M-"),
            (KeyModifiers::SHIFT, "Shift+", "S-"),
        ] {
            if modifiers.contains(flag) {
                label.push_str(long);
                tmux.push_str(short);
            }
        }
        label.push_str(&name);
        tmux.push_str(&name);
        Ok(Some(Self {
            event: KeyEvent::new(code, modifiers),
            label,
            tmux,
        }))
    }

    pub fn matches(&self, event: KeyEvent) -> bool {
        event.kind != KeyEventKind::Release
            && event.code == self.event.code
            && event.modifiers == self.event.modifiers
    }
}

/// Strings are retained on disk so updating an unrelated preference preserves
/// the user's spelling. Missing entries retain their defaults; "none" disables.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct BindingsConfig {
    pub previous_tab: String,
    pub next_tab: String,
    pub previous_session: String,
    pub next_session: String,
    pub send_next_key: String,
}

impl Default for BindingsConfig {
    fn default() -> Self {
        Self {
            previous_tab: "Shift+Left".into(),
            next_tab: "Shift+Right".into(),
            previous_session: "Shift+Up".into(),
            next_session: "Shift+Down".into(),
            send_next_key: "Ctrl+v".into(),
        }
    }
}

impl BindingsConfig {
    pub fn resolve(&self) -> Result<KeyBindings, String> {
        let mut bindings = Vec::new();
        for (action, value) in [
            (Action::PreviousTab, &self.previous_tab),
            (Action::NextTab, &self.next_tab),
            (Action::PreviousSession, &self.previous_session),
            (Action::NextSession, &self.next_session),
            (Action::SendNextKey, &self.send_next_key),
        ] {
            if let Some(shortcut) = Shortcut::parse(value)? {
                if shortcut.event.modifiers.contains(KeyModifiers::CONTROL)
                    && matches!(shortcut.event.code, KeyCode::Char('q' | 'b' | 'l'))
                {
                    return Err(format!("{} is reserved by Bosun", shortcut.label));
                }
                if bindings
                    .iter()
                    .any(|(_, other): &(Action, Shortcut)| other.matches(shortcut.event))
                {
                    return Err(format!("{} is assigned more than once", shortcut.label));
                }
                bindings.push((action, shortcut));
            }
        }
        Ok(KeyBindings(bindings))
    }
}

#[derive(Debug, Clone)]
pub struct KeyBindings(pub Vec<(Action, Shortcut)>);

impl Default for KeyBindings {
    fn default() -> Self {
        BindingsConfig::default().resolve().unwrap()
    }
}

impl KeyBindings {
    pub fn action(&self, event: KeyEvent) -> Option<Action> {
        self.0
            .iter()
            .find(|(_, key)| key.matches(event))
            .map(|(action, _)| *action)
    }

    pub fn get(&self, action: Action) -> Option<&Shortcut> {
        self.0
            .iter()
            .find(|(a, _)| *a == action)
            .map(|(_, key)| key)
    }

    pub fn label(&self, action: Action) -> &str {
        self.get(action)
            .map(|s| s.label.as_str())
            .unwrap_or("disabled")
    }
}

/// Local one-shot state. The tmux prefix is sent only together with the next
/// key, so clicking away or changing sessions cannot leave tmux half-armed.
#[derive(Debug, Default)]
pub struct KeyRouter {
    pub pending: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    Ignore,
    Arm,
    Quoted,
    Action(Action),
    Forward,
}

impl KeyRouter {
    pub fn route(&mut self, bindings: &KeyBindings, event: KeyEvent) -> Route {
        if event.kind == KeyEventKind::Release {
            return Route::Ignore;
        }
        if std::mem::take(&mut self.pending) {
            return Route::Quoted;
        }
        match bindings.action(event) {
            Some(Action::SendNextKey) => {
                self.pending = true;
                Route::Arm
            }
            Some(action) => Route::Action(action),
            None => Route::Forward,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(s: &str) -> KeyEvent {
        Shortcut::parse(s).unwrap().unwrap().event
    }

    #[test]
    fn remapping_and_disabling_release_original_keys() {
        let config = BindingsConfig {
            next_tab: "Ctrl+Shift+Right".into(),
            previous_tab: "none".into(),
            ..Default::default()
        };
        let keys = config.resolve().unwrap();
        assert_eq!(keys.action(event("Shift+Right")), None);
        assert_eq!(keys.action(event("Shift+Left")), None);
        assert_eq!(
            keys.action(event("Ctrl+Shift+Right")),
            Some(Action::NextTab)
        );
        assert_eq!(keys.action(event("Alt+Ctrl+Shift+Right")), None);
    }

    #[test]
    fn quote_is_one_shot_and_can_send_itself_or_detach_key() {
        let keys = KeyBindings::default();
        let mut router = KeyRouter::default();
        for quoted in ["Shift+Right", "Ctrl+v", "Ctrl+q"] {
            assert_eq!(router.route(&keys, event("Ctrl+v")), Route::Arm);
            let mut release = event("Ctrl+v");
            release.kind = KeyEventKind::Release;
            assert_eq!(router.route(&keys, release), Route::Ignore);
            assert!(router.pending);
            assert_eq!(router.route(&keys, event(quoted)), Route::Quoted);
            assert!(!router.pending);
            assert_eq!(
                router.route(&keys, event("Shift+Right")),
                Route::Action(Action::NextTab)
            );
        }
    }

    #[test]
    fn rejects_conflicts_and_ambiguous_keys() {
        for key in [
            "Ctrl+q",
            "Ctrl+Alt+q",
            "Ctrl+i",
            "Ctrl+b",
            "Ctrl+l",
            "Shift+Left",
            "Cmd+Right",
            "Ctrl+Shift+a",
            "a",
            "F13",
        ] {
            assert!(
                BindingsConfig {
                    next_tab: key.into(),
                    ..Default::default()
                }
                .resolve()
                .is_err(),
                "{key}"
            );
        }
    }

    #[test]
    fn partial_config_keeps_defaults_and_roundtrips() {
        let config: BindingsConfig =
            toml::from_str("next_tab = 'Alt+Right'\nprevious_tab = 'none'").unwrap();
        let roundtrip: BindingsConfig = toml::from_str(&toml::to_string(&config).unwrap()).unwrap();
        let keys = roundtrip.resolve().unwrap();
        assert_eq!(keys.label(Action::NextTab), "Alt+Right");
        assert_eq!(keys.label(Action::PreviousTab), "disabled");
        assert_eq!(keys.label(Action::SendNextKey), "Ctrl+v");
    }
}
