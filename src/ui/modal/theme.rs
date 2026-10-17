//! Theme picker with live preview.
//!
//! Up/Down highlight a theme and **immediately** emit
//! `Command::SetTheme { persist: false }` so the whole UI — including
//! the modal itself — re-renders in the hovered theme's colors.
//! Enter commits (`persist: true`, which writes `theme = "<name>"` to
//! `config.toml`). Esc emits the remembered original name with
//! `persist: false` to revert.
//!
//! The modal stays open across preview keystrokes by returning
//! `ModalResult::EmitCommand(...)` — the same mechanism RecentsModal
//! uses for its live `^d` delete.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget};
use ratatui::Frame;

use crate::events::Command;
use crate::ui::Theme;

use super::{center_rect, Modal, ModalResult};

const MODAL_WIDTH: u16 = 50;

pub struct ThemeModal {
    /// Ordered list of theme names to show. Built-ins first, then
    /// any user themes from `$XDG_CONFIG_HOME/bosun/themes/`.
    themes: Vec<String>,
    /// Current highlight into `themes`.
    selected: usize,
    /// The theme that was active when the modal opened. On Esc we
    /// emit this back as a non-persistent `SetTheme` so the live
    /// preview reverts without writing to config.toml.
    original: String,
}

impl ThemeModal {
    pub fn new(themes: Vec<String>, original: String) -> Self {
        let selected = themes.iter().position(|n| *n == original).unwrap_or(0);
        Self {
            themes,
            selected,
            original,
        }
    }

    fn current(&self) -> Option<&str> {
        self.themes.get(self.selected).map(String::as_str)
    }

    /// Build a `SetTheme` command for the currently-highlighted
    /// theme. `persist` toggles whether config.toml gets updated.
    fn set_theme_cmd(&self, persist: bool) -> Option<Command> {
        self.current().map(|name| Command::SetTheme {
            name: name.to_string(),
            persist,
        })
    }

    fn move_up(&mut self) -> ModalResult {
        if self.selected > 0 {
            self.selected -= 1;
        }
        match self.set_theme_cmd(false) {
            Some(cmd) => ModalResult::EmitCommand(cmd),
            None => ModalResult::Consumed,
        }
    }

    fn move_down(&mut self) -> ModalResult {
        if self.selected + 1 < self.themes.len() {
            self.selected += 1;
        }
        match self.set_theme_cmd(false) {
            Some(cmd) => ModalResult::EmitCommand(cmd),
            None => ModalResult::Consumed,
        }
    }
}

impl Modal for ThemeModal {
    fn id(&self) -> &'static str {
        "theme"
    }

    fn handle(&mut self, key: KeyEvent) -> ModalResult {
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            return ModalResult::Close(Some(Command::SetTheme {
                name: self.original.clone(),
                persist: false,
            }));
        }
        match key.code {
            KeyCode::Esc => ModalResult::Close(Some(Command::SetTheme {
                name: self.original.clone(),
                persist: false,
            })),
            KeyCode::Enter => match self.set_theme_cmd(true) {
                Some(cmd) => ModalResult::Close(Some(cmd)),
                None => ModalResult::Close(None),
            },
            KeyCode::Up | KeyCode::Char('k') => self.move_up(),
            KeyCode::Down | KeyCode::Char('j') => self.move_down(),
            KeyCode::Home => {
                self.selected = 0;
                match self.set_theme_cmd(false) {
                    Some(cmd) => ModalResult::EmitCommand(cmd),
                    None => ModalResult::Consumed,
                }
            }
            KeyCode::End => {
                if !self.themes.is_empty() {
                    self.selected = self.themes.len() - 1;
                }
                match self.set_theme_cmd(false) {
                    Some(cmd) => ModalResult::EmitCommand(cmd),
                    None => ModalResult::Consumed,
                }
            }
            _ => ModalResult::Consumed,
        }
    }

    fn render(&self, frame: &mut Frame<'_>, area: Rect, theme: &Theme) {
        // Size the modal to fit the theme list + 4 rows of chrome
        // (title, spacer, hint, spacer). Clamps to a minimum height
        // so a tiny list still looks like a proper dialog.
        let list_rows = self.themes.len() as u16;
        let height = (list_rows + 6).clamp(10, 30);

        let rect = center_rect(area, MODAL_WIDTH, height);
        let body_bg = theme.panel_alt;
        let buf = frame.buffer_mut();

        // Shadow.
        if rect.x + rect.width < area.x + area.width && rect.y + rect.height < area.y + area.height
        {
            let shadow = Rect::new(rect.x + 1, rect.y + 1, rect.width, rect.height);
            let style = Style::default().bg(theme.shadow);
            crate::ui::paint::tint(buf, shadow, style);
        }

        // Body fill.
        let body_style = Style::default().bg(body_bg);
        crate::ui::paint::fill_opaque(buf, rect, body_style);

        // Left accent bar.
        let accent_style = Style::default().bg(theme.accent);
        crate::ui::paint::fill_opaque(buf, crate::ui::paint::left_edge(rect), accent_style);

        let inner = Rect::new(
            rect.x + 3,
            rect.y + 1,
            rect.width.saturating_sub(4),
            rect.height.saturating_sub(2),
        );

        // The list scrolls when the terminal is too short for every
        // theme: two of the inner rows go to the title and a spacer.
        let list_rows = (inner.height as usize).saturating_sub(2);
        let window = visible_window(self.selected, self.themes.len(), list_rows);

        let mut lines: Vec<Line<'static>> = Vec::with_capacity(list_rows + 2);
        lines.push(Line::from(vec![
            Span::styled(
                "Theme",
                Style::default()
                    .fg(theme.text)
                    .bg(body_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                "    ↑↓ preview · ↵ apply · esc revert",
                Style::default().fg(theme.text_muted).bg(body_bg),
            ),
        ]));
        lines.push(Line::from(""));

        for i in window {
            lines.push(render_row(
                &self.themes[i],
                i == self.selected,
                inner.width,
                theme,
            ));
        }

        Paragraph::new(lines)
            .style(Style::default().bg(body_bg))
            .render(inner, frame.buffer_mut());
    }
}

/// The slice of the theme list to draw when only `rows` fit: the whole
/// list if it fits, otherwise a window that keeps `selected` in the
/// middle, pinned at the start and end of the list. Worked out from
/// the selection alone so the modal needs no scroll state of its own.
fn visible_window(selected: usize, len: usize, rows: usize) -> std::ops::Range<usize> {
    if len <= rows {
        return 0..len;
    }
    let start = selected.saturating_sub(rows / 2).min(len - rows);
    start..start + rows
}

fn render_row(name: &str, selected: bool, width: u16, theme: &Theme) -> Line<'static> {
    let marker = if selected { "▸" } else { " " };
    let row_bg = if selected {
        theme.selection_bg
    } else {
        theme.panel_alt
    };
    let marker_style = if selected {
        Style::default().fg(theme.accent).bg(row_bg)
    } else {
        Style::default().fg(row_bg).bg(row_bg)
    };
    let name_style = if selected {
        Style::default()
            .fg(theme.text)
            .bg(row_bg)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(theme.text_muted).bg(row_bg)
    };

    // Pad the name portion out to the row width so the row bg
    // (highlight or panel) extends cleanly across the whole modal.
    let name_field_width = (width as usize).saturating_sub(4);
    let mut padded = name.to_string();
    while padded.chars().count() < name_field_width {
        padded.push(' ');
    }

    Line::from(vec![
        Span::styled(format!(" {} ", marker), marker_style),
        Span::styled(" ", Style::default().bg(row_bg)),
        Span::styled(padded, name_style),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn modal() -> ThemeModal {
        ThemeModal::new(
            vec!["opencode".into(), "dracula".into(), "nord".into()],
            "opencode".into(),
        )
    }

    #[test]
    fn window_shows_everything_when_it_fits() {
        assert_eq!(visible_window(0, 5, 5), 0..5);
        assert_eq!(visible_window(4, 5, 20), 0..5);
        assert_eq!(visible_window(0, 0, 0), 0..0);
    }

    #[test]
    fn window_follows_the_selection_and_pins_at_the_ends() {
        // 28 themes, 20 rows: the start and end of the list pin the window.
        assert_eq!(visible_window(0, 28, 20), 0..20);
        assert_eq!(visible_window(9, 28, 20), 0..20);
        assert_eq!(visible_window(15, 28, 20), 5..25);
        assert_eq!(visible_window(27, 28, 20), 8..28);
        for sel in 0..28 {
            let w = visible_window(sel, 28, 20);
            assert!(w.contains(&sel), "{sel} not in {w:?}");
            assert_eq!(w.len(), 20);
        }
        // Even one row keeps the selection on screen.
        assert_eq!(visible_window(7, 28, 1), 7..8);
    }

    /// Render the modal into a `w` x `h` terminal and return its text.
    fn draw(m: &ThemeModal, w: u16, h: u16) -> Vec<String> {
        use ratatui::backend::TestBackend;
        use ratatui::Terminal;
        let theme = Theme::default_opencode();
        let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
        terminal
            .draw(|f| m.render(f, Rect::new(0, 0, w, h), &theme))
            .unwrap();
        let buf = terminal.backend().buffer();
        (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol().to_string()).collect())
            .collect()
    }

    #[test]
    fn selection_stays_on_screen_in_a_24_row_terminal() {
        let names: Vec<String> = (0..28).map(|i| format!("theme-{i:02}")).collect();
        let mut m = ThemeModal::new(names.clone(), "theme-00".into());
        // Walk the whole list; the highlighted row must always be drawn.
        for i in 0..28 {
            let rows = draw(&m, 100, 24);
            let marker = rows
                .iter()
                .find(|r| r.contains('▸'))
                .unwrap_or_else(|| panic!("no selection marker with theme-{i:02} selected"));
            assert!(marker.contains(&names[i]), "{marker:?} for {}", names[i]);
            m.handle(key(KeyCode::Down));
        }
        // And walking back up from the end.
        for i in (0..28).rev() {
            let rows = draw(&m, 100, 24);
            assert!(rows
                .iter()
                .any(|r| r.contains('▸') && r.contains(&names[i])));
            m.handle(key(KeyCode::Up));
        }
        // A short terminal still shows the title.
        assert!(draw(&m, 100, 24).iter().any(|r| r.contains("Theme")));
    }

    #[test]
    fn selection_starts_at_original() {
        let m = modal();
        assert_eq!(m.current(), Some("opencode"));
    }

    #[test]
    fn down_previews_next_theme_without_closing() {
        let mut m = modal();
        match m.handle(key(KeyCode::Down)) {
            ModalResult::EmitCommand(Command::SetTheme { name, persist }) => {
                assert_eq!(name, "dracula");
                assert!(!persist);
            }
            _ => panic!("expected EmitCommand(SetTheme)"),
        }
        assert_eq!(m.current(), Some("dracula"));
    }

    #[test]
    fn up_previews_previous_theme() {
        let mut m = modal();
        m.handle(key(KeyCode::Down));
        m.handle(key(KeyCode::Down));
        assert_eq!(m.current(), Some("nord"));
        match m.handle(key(KeyCode::Up)) {
            ModalResult::EmitCommand(Command::SetTheme { name, .. }) => {
                assert_eq!(name, "dracula");
            }
            _ => panic!("expected EmitCommand"),
        }
    }

    #[test]
    fn down_clamps_at_end() {
        let mut m = modal();
        m.handle(key(KeyCode::Down));
        m.handle(key(KeyCode::Down));
        m.handle(key(KeyCode::Down)); // clamped
        assert_eq!(m.current(), Some("nord"));
    }

    #[test]
    fn up_clamps_at_start() {
        let mut m = modal();
        m.handle(key(KeyCode::Up)); // clamped
        assert_eq!(m.current(), Some("opencode"));
    }

    #[test]
    fn enter_commits_with_persist() {
        let mut m = modal();
        m.handle(key(KeyCode::Down));
        match m.handle(key(KeyCode::Enter)) {
            ModalResult::Close(Some(Command::SetTheme { name, persist })) => {
                assert_eq!(name, "dracula");
                assert!(persist);
            }
            _ => panic!("expected Close with persist=true"),
        }
    }

    #[test]
    fn esc_reverts_to_original_without_persist() {
        let mut m = modal();
        m.handle(key(KeyCode::Down));
        m.handle(key(KeyCode::Down));
        match m.handle(key(KeyCode::Esc)) {
            ModalResult::Close(Some(Command::SetTheme { name, persist })) => {
                assert_eq!(name, "opencode");
                assert!(!persist);
            }
            _ => panic!("expected Close reverting to original"),
        }
    }

    #[test]
    fn home_jumps_to_first() {
        let mut m = modal();
        m.handle(key(KeyCode::Down));
        m.handle(key(KeyCode::Down));
        m.handle(key(KeyCode::Home));
        assert_eq!(m.current(), Some("opencode"));
    }

    #[test]
    fn end_jumps_to_last() {
        let mut m = modal();
        m.handle(key(KeyCode::End));
        assert_eq!(m.current(), Some("nord"));
    }
}
