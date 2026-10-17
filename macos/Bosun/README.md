# Bosun for Mac

A native macOS front end for Bosun: a sidebar of your Bosun sessions and live terminals (libghostty) attached to them. It is a client of `bosun serve` and doesn't replace the TUI; both can run at once against the same daemon.

Each sidebar row is a workspace, and the row's tabs are its panes. Selecting a row replaces the whole main area with that row's own split layout, so one row can hold an agent, a test watcher and a shell for the same project side by side, while another row is a single agent. In the TUI a row's tabs hide each other; here they sit next to each other.

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
BOSUN_BUILD_DIR=build-mine ./build.sh   # the same into build-mine/, leaving build/Bosun.app alone
```

`BOSUN_BUILD_DIR` (relative to this directory, or absolute) moves the app, DerivedData and the test log. Use it for a second build while a copy of the app is running from `build/`: a build replaces `Bosun.app` in its directory, which kills a copy running from there.

`build.sh` regenerates `Bosun.xcodeproj` from `project.yml` each time, so edit `project.yml`, not the project.

## Running

To use it day to day, run `make install-mac` from the repo root. It builds into `build-release/` (so it never replaces a dev copy running from `build/`) and installs `~/Applications/Bosun.app`. Quit the installed app first.

Launched normally, the app looks for `bosun` in `$BOSUN_BIN`, `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, connects to the daemon's socket (`bosun serve --print-socket`), and starts `bosun serve` itself if nothing answers. The daemon outlives the app.

Environment variables:

- `BOSUN_SERVE_SOCKET=<path>` connects to that socket only and never starts a daemon. Use this for development.
- `BOSUN_BIN=<path>` picks the `bosun` binary.
- `BOSUN_DEBUG_KEYS=1` prints every key event and where it was routed.
- `BOSUN_DEBUG_FRAMES=1` prints every frame a terminal draws, and every focus and occlusion change the app gives libghostty, with timestamps. Use it to find out what keeps an idle pane drawing.

The window paints the sidebar and the last shown row from a cached snapshot before the daemon answers, then switches to live data.

## Developing against a test daemon

Never point a development build at your real Bosun setup. `dev.sh` runs a throwaway daemon with its own HOME and its own tmux socket (`-L bosun-mac-dev`), creates eight fixture sessions running a fake agent (no AI agents are started), and runs the app against it:

```sh
./dev.sh up                 # start the test daemon and the fixture sessions
./dev.sh run                # launch build/Bosun.app against it ($BOSUN_BUILD_DIR/Bosun.app when that's set)
./dev.sh status api waiting "needs input"   # set a fixture's hook status
./dev.sh tmux list-clients  # tmux, on the test socket
./dev.sh down               # stop the test daemon and kill only the test tmux server
./dev.sh reset              # down, then delete the throwaway home
```

`BOSUN_DEV_HOME` (default `/tmp/bosun-mac-dev-$USER`, short because Unix socket paths max out at 104 bytes), `BOSUN_DEV_TMUX` and `BOSUN_DEV_BIN` change where it lives, the tmux socket name and the `bosun` binary. Without `BOSUN_DEV_BIN` it builds `bosun` from this checkout into `build/cargo-target`.

The fixture: `api` and `docs` ungrouped; a Work section with `parser`, `ticker` (prints a line a second) and `web` (three tabs, so three panes: `web`, `web tests` and `web shell`, a plain shell); a Reviews section with `review-1`, `review-2` and `shell` (a plain shell, which reads as idle).

## Test modes

Both run inside the app against the fixture (`./dev.sh up` first) and drive it through AppKit's real event path. They work with the screen locked: events are posted into the app's own queue and screenshots are rendered in-process.

```sh
./dev.sh run --focustest --shots /some/dir --results /some/file.txt
./dev.sh run --selftest --results /some/file.txt
```

`--no-activate` opens the window without activating the app, so a test run never takes the keyboard from what you're doing. `--focustest --only rows,panes,zoom,windows,newpanes,clientmoves,done,notify,appearance,links,sheet,empty,tiledrag,sidebardrag,shortcuts` runs just those sections. In the test modes the real pointer's moves are dropped, so someone using the Mac during a run can't move focus between panes. Test modes never save their window frame.

`--focustest` checks the focus model end to end: where keys land after sidebar clicks, rename, the palette and the sheet. Rows as workspaces: a three-tab row opens as three panes; switching to a single-pane row replaces them all (the views stay warm and hidden); switching back brings the same views back with the keyboard in the pane that was active; Cmd+1…9, Shift+Up/Down and Cmd+K switch whole rows; clicking a tab under a row activates its pane. Panes: Shift+Left/Right walk them in tab order, Cmd+Option+arrows move by position. Zoom: Cmd+Return shows the active pane alone at full size with the others attached and hidden, the zoom follows Shift+Right and Cmd+Option+arrows, survives a row switch, Cmd+Return again brings back the same views, a header double-click zooms and unzooms, and Cmd+D ends the zoom. New and closed panes: Cmd+D and Cmd+Shift+D add a terminal tab to the row (checked in the daemon's sidebar) as a split beside the active pane, and typing reaches it; Cmd+W on a shell at its prompt closes without asking and the tab ends, Cmd+W on a busy pane or a row's last pane asks; Cmd+T opens the sheet for a tab of the row in its directory and the result opens as a split; a tab created behind the app's back appears as a pane, and loses it when it ends. Then focus following the mouse and its guards; drops on panes, dividers and sidebar rows; every app shortcut and the `[keybindings]` nav keys (and that they never reach tmux's Shift+arrow bindings); create and kill, with nothing but the launch command typed into a new session; an exited row's placeholder; themes; the Light/Dark theme pair (with `theme_light` and `theme_dark` set, switching `NSApp.appearance` between aqua and darkAqua inside the app recolours the window and titlebar, sidebar, title band and active ring live, and the terminals too with "match terminal" on, even over colours set in your Ghostty config; "Same as Theme" falls back to `theme`, which never changes; View → Theme says what it's following; the system appearance is never touched); done from Claude's hooks (`bosun hook claude Stop` run inside a fixture pane shows done on the visible pane's header, its sidebar row and a multi-tab row's badge, typing into the pane clears it, the next prompt shows running and the next Stop shows done again); notifications (a fixture session driven to waiting with `bosun hook claude PermissionRequest`, and to done with `Stop`, while it isn't on screen: the request's title, body and session, no repeat for the same wait, a click showing that row with the pane active and the keyboard in it, no notification for a pane on screen in the frontmost app, the Dock badge and its count, the three toggles, Cmd+Shift+U across rows, and the saved input times; notifications go to a recorder in the test modes, never to Notification Center, and whether the window is in front of you is injected); the tmux status line (no TUI hints, and no line at all on a session only the app shows); tmux clients that something moved (Bosun's `prefix 1-9` typed inside a terminal, or `switch-client`) going back to their own tab while the app shows the target's row or pane; attaching again after a detach (`Ctrl+q`); Cmd+hover and Cmd+click on a URL, an absolute path, a relative path with `:line` and a missing path, in the active pane and an inactive one (nothing is really opened: a recorder takes the place of NSWorkspace); and that no tmux client is left on another session than its pane says, and at most one terminal has libghostty's focus. Then layout and dragging: every control in the new-session sheet lies inside it, with 1, 3 and 4 panes and in the smallest window; the exited-row and no-rows placeholders keep their text inside at every width; panes dragged by their header to each edge and swapped, cancelled with Esc or by letting go outside, with the same terminal views and the keyboard following the dragged pane; sidebar rows, sections and tabs dragged through AppKit's own table tracking (a test hook keeps the drag session from the window server, so it never follows the real mouse) and dropped through the outline's own drop code; and the keyboard shortcuts panel. Then windows: Cmd+N opens a second window on a row the first doesn't show, with the keyboard in it; selecting a row the other window shows brings that window forward; each sidebar marks the other window's row; Shift+Down skips it; Cmd+Shift+W closes the window and its terminals stay warm; a row dragged out of the sidebar opens in a new window with the same three terminal views while the first window moves on; a pane dragged out of its window by its header shows the new-window card, becomes a row of its own in the daemon's sidebar and opens in a third window with the same view; the layouts file keeps the other windows; and a torn-off tab moved back into its row is a pane of that row's window again. It saves screenshots of the main states when `--shots` is given.

`--selftest` reports p50/p90/p99 for warm switch, warm row switch (a three-pane row: the main-thread swap, and every pane's first frame), cold attach, status change to badge, daemon round trip, divider drag layout, launch to sidebar painted and launch to first live terminal (from ten fresh processes), plus idle CPU and memory, against the budgets in the design doc. Idle CPU is measured twice, with the window key and with it not key, each with the frames every pane drew, and checks that only the active pane blinks. Before it, 80 pane and row switches in about 4 s check that afterwards only the active pane blinks and has libghostty's focus (and how often the blink guard stepped in). `--selftest --only idle` runs just the idle part.

It also measures dragging a divider with four busy agents on screen: it makes a temporary row of four tabs running the fake agent's `--ink` mode (a status block redrawn 30 times a second and the whole screen again on every SIGWINCH, as Claude Code does), drags the row's main divider for 2 s through AppKit's event path at the display's rate, once per grid-size throttle (0, 50, 100 and 150 ms), and reports for each the steps handled, pointer-to-layout time, the gap between steps, layout time, SIGWINCHes and frames per pane, and the CPU the agents and the tmux server used. Then it resizes the window for 1 s the same way, and kills the row. `--selftest --only busy` runs just that.

The intervals are also emitted as signposts (subsystem `dev.yetidevworks.bosun-mac`), so Instruments' os_signpost track shows them in a normal run.

## Keyboard

The terminal keeps the keyboard. Only the rename field, the palette and the new-session sheet borrow it, and closing them hands it back.

| Keys | Action |
| --- | --- |
| Cmd+K | Go to session (fuzzy palette): shows its row, with that tab's pane active |
| Cmd+Shift+N | New session (a new row) |
| Cmd+Shift+U | Oldest waiting session: shows its row, with that tab's pane active |
| Cmd+1…9 | Sidebar row 1…9 |
| Cmd+D / Cmd+Shift+D | New terminal tab in this row, split right / down of the active pane |
| Cmd+T | New tab (the new-session sheet, for an agent), split right |
| Cmd+Option+arrows | Focus the pane in that direction |
| Cmd+Return | Zoom the active pane (show it alone, full size), or show the whole row again |
| Cmd+W | Close the active pane and end its tab |
| Cmd+N | New window, on the first row no window shows |
| Cmd+Shift+W | Close the window (its rows' sessions keep running) |
| Drag a pane's header | Move it beside another pane (near an edge) or swap the two (the middle) |
| Cmd+/ | Keyboard shortcuts |
| Shift+Up / Shift+Down | Previous / next row (from `[keybindings]`) |
| Shift+Left / Shift+Right | Previous / next pane, in tab order (from `[keybindings]`) |
| Ctrl+v | Send the next key to the terminal as is (from `[keybindings]`) |

Help → Keyboard Shortcuts (Cmd+/) lists all of these, and every key is also on its menu item. The nav keys follow the `[keybindings]` table in Bosun's config.toml and update live when it changes. Everything else goes to the terminal; Ghostty's own bindings that would clash with these are removed.

## Done

For an agent that reports its state through hooks (Claude Code), a row and its pane header show **done** when the agent finished its turn and it's your turn: from the agent's Stop hook until you type, paste or drop something into that session's terminal, or the agent starts running again. It shows whether or not the pane is on screen. App shortcuts don't count as input. For other agents, whose state Bosun works out from the pane, done means the session ran and changed since you last had it on screen.

## Notifications

Bosun posts a macOS notification at the two moments that need you:

- **Waiting:** an agent starts waiting on you (a permission prompt or a question). The body says what for, e.g. "Waiting — permission: Bash".
- **Done:** an agent that reports through hooks (Claude Code) finishes its turn.

The title is the session's name, with its row (for a tab of a multi-tab row) and section beneath. Clicking it brings Bosun forward on that row, with the session's pane active and the keyboard in it.

Nothing is posted when you can already see the session: Bosun is the active app, its window is on screen (not minimized, not on another Space) and the session is a pane of the row it shows. A wait gets one notification however long it lasts, and a finished turn one per turn. A session's notifications are taken back once you see it or type into it, or its state moves on (the wait ends, the next turn starts).

macOS asks whether Bosun may post notifications the first time it has one to post, not at launch. If you say no, nothing is posted; change it in System Settings → Notifications. The ad-hoc signed build works with Notification Center as long as it runs as a normal app from a normal folder (`~/Applications`, or a build directory).

The Dock icon shows the number of sessions waiting on you. Done turns don't count: a done session stays done until you type into it, so one you looked at and left would keep the badge up for good.

Bosun → Notify When Waiting, Notify When Done and Show Dock Badge (all on by default) turn each off; they're in Settings too. The done rule's "last typed into" times are kept per daemon in `inputs-<daemon>.json` next to the row layouts, so a relaunch doesn't show every finished session as done again.

## Links

Cmd+hover underlines a URL or a file path in a terminal and shows the hand; Cmd+click opens it, in an inactive pane too. A relative path (`src/app.rs:42`) is resolved against the pane's current directory, which the app asks tmux for, and a trailing `:line` or `:line:col` is dropped. A path that doesn't exist opens nothing. tmux has the mouse, so the app gives libghostty Shift along with Cmd: that's what libghostty needs to look for links while a program has the mouse, and the click never reaches tmux.

## Rows and panes

- **Selecting a row** (a click, Cmd+1…9, Shift+Up/Down, Cmd+K) replaces the whole main area with that row's panes, as you left them, and the keyboard goes to the pane that was active there. The sidebar highlights the row; when it has several tabs, the active pane's tab is marked under it, and clicking a tab activates its pane.
- **A row seen for the first time** lays its tabs out by splitting the biggest pane in half along its longer side, so two tabs sit side by side, three make a column and a stack, and four make a 2×2 grid. A tab created elsewhere (the TUI, or `bosun serve`'s `create` with the row's `container_id`) gets a pane the same way, without taking the keyboard.
- **Cmd+D / Cmd+Shift+D** create a plain terminal tab in the row, in the active pane's directory, straight away and with no sheet, and split the active pane for it. Its name is the row's own (its first tab's), which the daemon makes unique the way the TUI does ("web" becomes "web 2"). Cmd+T opens the new-session sheet for a tab of the row instead, for when the pane should run an agent. At 9 panes these beep.
- **Cmd+Return** zooms the active pane: it fills the main area on its own and the row's other panes stay attached but hidden, so the row's layout is untouched and unzooming is instant. Double-clicking a pane's header does the same. The zoom follows the active pane, so Shift+Left/Right, Cmd+Option+arrows (by the row's whole layout) and clicking a tab under the row flip through the row's panes full size. A new pane (Cmd+D, a tab from elsewhere) or a closed one ends the zoom. Each row keeps its own zoom, across row switches and relaunches.
- **Cmd+W** closes the active pane and kills that tab's session. It asks first unless the pane's foreground command is a shell at its prompt (zsh, bash, fish, sh and the other shells Bosun knows, with or without a login shell's leading `-`). Closing a row's last pane always asks, since it kills the row's session. The closed pane's space and the keyboard go to its sibling.
- **A tab that ends** (killed in the TUI, or its program exits) loses its pane, and its sibling takes the space. A row whose tabs have all ended shows its exited state, with Restart and Resume.
- **Layouts are the app's own:** each row's split tree, active pane and zoom, plus the other windows and their rows, are kept in `~/Library/Application Support/dev.yetidevworks.bosun-mac/rows-<daemon>.json`, keyed by container id. The daemon's idea of a row's active tab (what the TUI shows) is updated when you leave a row and when the app quits, not on every pane change.

Bosun's tmux bindings for the TUI and Moshi still work inside a terminal (`prefix 1-9` jumps, `Ctrl+q` detaches). The app follows them, and every pane keeps showing its own tab: when a terminal's tmux client is moved to another session, the client is put back, and the app activates that session's pane if it's a tab of the same row, or shows its row if it's in another. A pooled terminal that isn't on screen is just put back. After a detach the pane attaches again.

## Windows

Every window is a full Bosun window, with its own sidebar and main area, and can show any row. A row is on screen in one window at most: selecting a row another window shows (a click, Cmd+1…9, Cmd+K, a notification) brings that window forward with the keyboard in that row's pane instead. Each sidebar marks the rows other windows show with ⧉, and previous/next row (Shift+Up/Down) skips them. Menus and keys act on the key window.

- **Window → New Window** (Cmd+N) opens a window on the first row no window shows.
- **Tear-off:** drag a row out of the sidebar and let go outside every Bosun window, and that row opens in a new window there, with the same terminal views (nothing reattaches). The window that showed it moves on to the next row no window shows. Drag a pane out of its window by its header and it moves out into a row of its own (the TUI sees that row too) in a new window; a card follows the pointer while it's outside the window to say so. A tab dragged out of the sidebar does the same. The row and tab menus have Open in New Window and Move to New Window, and Window → Move Pane to New Window does it for the active pane.
- **Closing** a window (Cmd+Shift+W or its close button) leaves its rows in the sidebar and their sessions running; its terminal views stay warm in another window. A window whose row ends, or is merged into a row another window shows, moves on to a row no window shows, and closes if there isn't one. Closing the last window quits.
- **Saved:** the other windows and their rows are kept with the row layouts, and come back where they were on the next launch (a window whose row has gone doesn't).

## tmux's status line

The app's terminals attach to tmux as `xterm-ghostty-bosun`, a copy of Ghostty's terminfo entry under its own name that the build puts in the bundle. That's how Bosun tells them from other tmux clients: they get none of the TUI's key hints, and a session that only the app is showing has no status line at all, so the terminal gets that row back. tmux has no per-client status line, so while the TUI's preview, Moshi or another `tmux attach` also shows a session, its status line is on and the app's terminal has an empty last row.

## Settings

Bosun → Settings (Cmd+,): focus follows the mouse (on by default, only with two or more panes), the number of terminal views kept attached (12, from 4 to 27), the Light and Dark themes and matching the terminal to the Bosun theme (off by default; see Themes), and the notification settings (see Notifications). The warm pool counts views, not rows: the shown row's panes count, and a row's panes are used together, so recently shown rows stay warm as a whole and switch back in one frame. 12 holds the shown row plus two or three more rows of three panes; each view costs about 13–14 MB. The chrome follows Bosun's theme; View → Theme changes it for every client.

## Themes

The window, titlebar, sidebar, pane headers and rings use the Bosun theme from View → Theme, the same `theme` the TUI uses, so changing it in either changes both.

To follow the macOS appearance instead, pick a **Light theme** and a **Dark theme** in Settings. Bosun then shows the light one while macOS is in Light mode and the dark one in Dark mode, and switches the moment the appearance changes, including on the Auto schedule. They're saved as `theme_light` and `theme_dark` in Bosun's `config.toml`. "Same as Theme" leaves a side unset, so that side uses `theme`. Picking them never changes `theme`, so the TUI, which can't tell the macOS appearance, keeps its own. While a pair is set, View → Theme starts with a note saying which theme is showing and why, and its list still sets `theme`.

With **Match terminal colours to the Bosun theme** on, the terminals switch with it, using the theme's Ghostty counterpart (or colours generated from the Bosun theme). They're applied as the app's own Ghostty override, after your Ghostty config and taking precedence over any colours it sets, and your Ghostty config file is never changed.

## Layout of the code

- `Core/` (BosunCore, no AppKit): protocol types and decoding, the state store, sidebar operations, the split tree and each row's layout (`RowLayout`: reconciling panes with tabs, placing new ones, closing, tab-order steps, persistence), key chords, the focus state machine, the done rule and its saved input times, when to notify and the Dock badge count (`Attention`), which theme the chrome shows for the appearance (`ThemeChoice`), shell escaping. Unit tested in `Tests/`.
- `Sources/`: the app. `DaemonClient` (socket, framing, reconnect, snapshot cache), `Ghostty` and `TerminalView` (libghostty), `TerminalPool` (warm pool), `Workspace` (rows and their panes, dividers, drops, moving panes), `Sidebar`, `NewSessionSheet`, `ThemePairSettings` (the Light/Dark pickers), `ShortcutsPanel`, `Notifier` (UserNotifications, and the recorder the test modes use), `AppController` (menus, commands, key routing, notifications and the Dock badge), `Tests`, `LayoutTests`, `NotifyTests` and `AppearanceTests` (the test modes).
- `fixture/`: the fake agent and the fixture builder used by `dev.sh`.
