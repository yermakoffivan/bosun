# Bosun for Mac

A native macOS front end for Bosun: a sidebar of your Bosun sessions and live terminals (libghostty) attached to them, side by side in split tiles. It is a client of `bosun serve` and doesn't replace the TUI; both can run at once against the same daemon.

macOS 15 or later, Apple Silicon.

## Building

You need Xcode 16 or later, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and a Ghostty checkout next to this repo (`../ghostty` relative to the bosun repo root) with the xcframework and resources built:

```sh
cd ../ghostty
git checkout b3dc3d794513c11633e7c3347935693957744e83
zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false
```

That leaves `macos/GhosttyKit.xcframework` and `zig-out/share/{terminfo,ghostty}` in the Ghostty checkout. The app pins that commit because libghostty's embedding API isn't stable.

Then, from `macos/Bosun`:

```sh
./build.sh          # Release build into build/Bosun.app
./build.sh test     # unit tests (BosunCoreTests), log in build/test.log
```

`build.sh` regenerates `Bosun.xcodeproj` from `project.yml` each time, so edit `project.yml`, not the project.

## Running

Launched normally, the app looks for `bosun` in `$BOSUN_BIN`, `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, connects to the daemon's socket (`bosun serve --print-socket`), and starts `bosun serve` itself if nothing answers. The daemon outlives the app.

Environment variables:

- `BOSUN_SERVE_SOCKET=<path>` connects to that socket only and never starts a daemon. Use this for development.
- `BOSUN_BIN=<path>` picks the `bosun` binary.
- `BOSUN_DEBUG_KEYS=1` prints every key event and where it was routed.

The window paints the sidebar and the last layout from a cached snapshot before the daemon answers, then switches to live data.

## Developing against a test daemon

Never point a development build at your real Bosun setup. `dev.sh` runs a throwaway daemon with its own HOME and its own tmux socket (`-L bosun-mac-dev`), creates eight fixture sessions running a fake agent (no AI agents are started), and runs the app against it:

```sh
./dev.sh up                 # start the test daemon and the fixture sessions
./dev.sh run                # launch build/Bosun.app against it
./dev.sh status api waiting "needs input"   # set a fixture's hook status
./dev.sh tmux list-clients  # tmux, on the test socket
./dev.sh down               # stop the test daemon and kill only the test tmux server
./dev.sh reset              # down, then delete the throwaway home
```

`BOSUN_DEV_HOME` (default `/tmp/bosun-mac-dev-$USER`, short because Unix socket paths max out at 104 bytes), `BOSUN_DEV_TMUX` and `BOSUN_DEV_BIN` change where it lives, the tmux socket name and the `bosun` binary. Without `BOSUN_DEV_BIN` it builds `bosun` from this checkout into `build/cargo-target`.

The fixture: `api` and `docs` ungrouped; a Work section with `parser`, `ticker` (prints a line a second) and `web` (two tabs: `web`, `web tests`); a Reviews section with `review-1`, `review-2` and `shell` (a plain shell, which reads as idle).

## Test modes

Both run inside the app against the fixture (`./dev.sh up` first) and drive it through AppKit's real event path. They work with the screen locked: events are posted into the app's own queue and screenshots are rendered in-process.

```sh
./dev.sh run --focustest --shots /some/dir --results /some/file.txt
./dev.sh run --selftest --results /some/file.txt
```

`--focustest` checks the focus model end to end: where keys land after sidebar clicks, rename, the palette and the sheet; splits and tile focus; focus following the mouse and its guards; drops on tiles, dividers and sidebar rows; every app shortcut and the `[keybindings]` nav keys (and that they never reach tmux's Shift+arrow bindings); create and kill, with nothing but the launch command typed into a new session; themes; the tmux status line (no TUI hints, and no line at all on a session only the app shows); tiles following a tmux client that something moved (Bosun's `prefix 1-9` typed inside a terminal), moving it back when its new session is in another tile or the view is hidden, and attaching again after a detach (`Ctrl+q`); and that no tmux client is left on another session than its tile says. It saves screenshots of the main states when `--shots` is given.

`--selftest` reports p50/p90/p99 for warm switch, cold attach, status change to badge, daemon round trip, divider drag layout, launch to sidebar painted and launch to first live terminal (from ten fresh processes), plus idle CPU and memory, against the budgets in the design doc.

The intervals are also emitted as signposts (subsystem `dev.yetidevworks.bosun-mac`), so Instruments' os_signpost track shows them in a normal run.

## Keyboard

The terminal keeps the keyboard. Only the rename field, the palette and the new-session sheet borrow it, and closing them hands it back.

| Keys | Action |
| --- | --- |
| Cmd+K | Go to session (fuzzy palette) |
| Cmd+Shift+N | New session |
| Cmd+Shift+U | Oldest waiting session |
| Cmd+1…9 | Sidebar row 1…9 |
| Cmd+D / Cmd+Shift+D | Split right / down |
| Cmd+Option+arrows | Focus the tile in that direction |
| Cmd+W | Close tile |
| Shift+Up / Shift+Down | Previous / next session (from `[keybindings]`) |
| Shift+Left / Shift+Right | Previous / next tab (from `[keybindings]`) |
| Ctrl+v | Send the next key to the terminal as is (from `[keybindings]`) |

The nav keys follow the `[keybindings]` table in Bosun's config.toml and update live when it changes. Everything else goes to the terminal; Ghostty's own bindings that would clash with these are removed.

Bosun's tmux bindings for the TUI and Moshi still work inside a terminal (`prefix 1-9` jumps, `Ctrl+q` detaches). The app follows them: when a terminal's tmux client is moved to another session, its tile shows that session (header, sidebar and all), or, if another tile already shows it, the client goes back and that tile becomes active. After a detach the tile attaches again.

## tmux's status line

The app's terminals attach to tmux as `xterm-ghostty-bosun`, a copy of Ghostty's terminfo entry under its own name that the build puts in the bundle. That's how Bosun tells them from other tmux clients: they get none of the TUI's key hints, and a session that only the app is showing has no status line at all, so the terminal gets that row back. tmux has no per-client status line, so while the TUI's preview, Moshi or another `tmux attach` also shows a session, its status line is on and the app's terminal has an empty last row.

## Settings

Bosun → Settings (Cmd+,): focus follows the mouse (on by default, only with two or more tiles), match the terminal to the Bosun theme (off by default), and the number of terminals kept attached in the background (8). The chrome follows Bosun's theme; View → Theme changes it for every client.

## Layout of the code

- `Core/` (BosunCore, no AppKit): protocol types and decoding, the state store, sidebar operations, the split tree, key chords, the focus state machine, the done rule, shell escaping. Unit tested in `Tests/`.
- `Sources/`: the app. `DaemonClient` (socket, framing, reconnect, snapshot cache), `Ghostty` and `TerminalView` (libghostty), `TerminalPool` (warm pool), `Workspace` (tiles, dividers, drops), `Sidebar`, `NewSessionSheet`, `AppController` (menus, commands, key routing), `Tests` (the test modes).
- `fixture/`: the fake agent and the fixture builder used by `dev.sh`.
