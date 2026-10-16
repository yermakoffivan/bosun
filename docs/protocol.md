# `bosun serve` protocol, version 1

`bosun serve` runs Bosun's tmux actor without the TUI and lets other programs (the planned Mac app first) drive it over a Unix socket. A client connects, says `hello`, receives one `snapshot` of everything it needs to draw Bosun's sidebar, then a stream of deltas. Commands go the other way and are acknowledged by id. The client never polls.

The Rust types for every message live in `src/serve/protocol.rs`. This document and that module change together.

## Running the daemon

```
bosun serve [--idle-timeout <secs>]
bosun serve --print-socket
```

- **Socket:** `bosun.sock` in Bosun's data directory, next to `bosun.db`. On macOS that is `~/Library/Application Support/dev.yetidevworks.bosun/bosun.sock`; on Linux `$XDG_DATA_HOME/bosun/bosun.sock` (usually `~/.local/share/bosun/`). `bosun serve --print-socket` prints the exact path. The socket is created with mode `0600`, and connections from another user id are refused.
- **Single instance:** the daemon holds an exclusive `flock` on `bosun-serve.lock` in the same directory (the file holds its pid). A second `bosun serve` exits with status 1 and `bosun serve is already running (pid N)` on stderr. A client that finds no socket, or a socket that refuses connections, starts `bosun serve` itself and then connects; if two clients race, one daemon wins and both connect to it.
- **Lifetime:** the daemon exits 30 seconds after its last client disconnects (or after starting, if nobody connects). `--idle-timeout` changes that. SIGINT and SIGTERM stop it at once. It removes its socket on the way out. Nothing is lost when it exits: sessions live in tmux and Bosun's state lives in `config.toml` and SQLite.
- **tmux socket and settings:** the same as the TUI, from `config.toml` and the `BOSUN_*` environment variables (`BOSUN_TMUX_SOCKET` and so on).
- **Logs:** `BOSUN_LOG=info` (or any tracing filter) writes logs to stderr. Off by default.

## Framing

Every message, in both directions, is one frame: a 4-byte big-endian unsigned length, followed by that many bytes of UTF-8 JSON. Frames larger than 16 MiB are rejected. Each message is a JSON object whose `"t"` field names its kind. Unknown fields must be ignored by both sides, so later versions can add fields without a version bump.

```
00 00 00 2e  {"t":"hello","protocol":1,"client":"bosun-mac/0.1"}
```

## Session

```
→ {"t":"hello","protocol":1,"client":"bosun-mac/0.1"}
← {"t":"snapshot","seq":1,"server":{…},"sessions":[…],"statuses":{…},"sidebar":{…},"recents":[…],"config":{…},"theme":{…},"themes":[…],"keybindings":{…}}
← {"t":"status","seq":2,"session":"bosun-api-1a2b3c4d","state":"running","source":"hook"}
→ {"t":"cmd","id":7,"op":"restart","session":"bosun-api-1a2b3c4d","resume":true}
← {"t":"notice","seq":3,"message":"restarted api"}
← {"t":"ack","id":7,"ok":true,"messages":["restarted api"]}
```

1. The client sends `hello` first. Anything else before it gets an `error` with code `no_hello` and the connection is closed.
2. The daemon answers with a `snapshot`.
3. From then on the daemon pushes deltas whenever something changes, and the client sends commands whenever it likes.

### Sequence numbers

Every message from the daemon except `ack` and `error` carries a `seq`. The `snapshot` carries the current value; each later message carries exactly one more than the one before it on that connection. A client that sees a gap (it shouldn't happen on a stream socket, but a client that drops messages under load could cause one) sends `resync` and gets a fresh `snapshot`. Apply deltas in order onto the last snapshot and the result always equals what a new snapshot would contain.

### Versioning

`protocol` is the major version, currently `1`. The daemon refuses any other value with an `error` whose `code` is `protocol_mismatch` and whose `message` is meant for a person, then closes the connection:

```
← {"t":"error","code":"protocol_mismatch","message":"bosun serve 2.1.16 speaks protocol 1 but this client speaks 2; update bosun or the app so both match"}
```

New message kinds, new commands and new optional fields do not change the major version. Clients ignore message kinds they don't know.

## Client → daemon

### `hello`

```json
{"t":"hello","protocol":1,"client":"bosun-mac/0.1"}
```

`client` is optional and free-form; it's only for logs. Sending `hello` again on a live connection just returns a new snapshot.

### `resync`

```json
{"t":"resync"}
```

Ask for a fresh `snapshot`.

### `cmd`

```json
{"t":"cmd","id":12,"op":"kill","session":"bosun-api-1a2b3c4d"}
```

`id` is chosen by the client (any unsigned 64-bit number; use a counter) and comes back in the `ack`. `op` names the command; its arguments sit next to it in the same object. Commands are carried out in the order they arrive. Commands that change tmux state are run by the same actor the TUI uses, one at a time, so an `ack` can take a moment (a `restart` waits for the old agent to stop). The deltas a command causes are sent before its `ack`.

Text fields that end up in tmux (display names, section names, paths, args) may not contain control characters; such a command is refused with `ok: false` before anything runs. Session names are the internal tmux names from `sessions[].name`.

#### `create`

```json
{"t":"cmd","id":1,"op":"create","defer_launch":true,
 "spec":{"name":"api","path":"~/work/api","agent":"claude","args":"--model opus",
         "options":{"claude":{"session_mode":"continue","skip_permissions":false,"remote_control":false}},
         "container_id":null,"resume":false,"worktree_branch":null}}
```

Creates a session from a spec (see [Spec](#spec)). The display name is made unique the same way the TUI does it ("api" becomes "api 2"). The `ack` carries the new internal name in `session`.

The agent command is typed into the new shell straight away, unless `defer_launch` is `true`. Then the session starts as a bare shell, the `ack` carries `pending_launch`, and the client sends `launch_agent` with those values once its terminal view is attached. Agents like Codex probe the terminal's background color at startup; deferring the launch until a terminal is there to answer is what lets them pick the right palette (Bosun issue #2). A GUI that shows the session right away should defer.

```json
{"t":"ack","id":1,"ok":true,"session":"bosun-api-1a2b3c4d","pending_launch":{"session":"bosun-api-1a2b3c4d","resume":null},"messages":["created bosun-api-1a2b3c4d"]}
```

#### `kill`

```json
{"t":"cmd","id":2,"op":"kill","session":"bosun-api-1a2b3c4d"}
```

Kills the tmux session. Killing a session that's already gone succeeds. Whether the sidebar row stays (as an exited row that can be restarted) or goes follows the `remove_dead_sessions` setting, as in the TUI.

#### `kill_container`

```json
{"t":"cmd","id":3,"op":"kill_container","sessions":["bosun-api-1a2b3c4d","bosun-api-2-9f8e7d6c"]}
```

Kills every tab of a sidebar row. Failures on one tab don't stop the others; they're reported together in `error`.

#### `kill_remove_worktree`

```json
{"t":"cmd","id":4,"op":"kill_remove_worktree","session":"bosun-feat-1a2b3c4d",
 "worktree_path":"/w/api/.worktrees/feat","branch":"feat","merge":false}
```

Kills a worktree-backed session (the row's `worktree_path` and `branch`) and removes its worktree. With `merge: true` the branch is merged into the repo's current branch first and deleted afterwards. A worktree with uncommitted changes is never removed, and a conflicted merge is aborted; both come back as `ok: false` with the reason, and the worktree is left as it was.

#### `rename`

```json
{"t":"cmd","id":5,"op":"rename","session":"bosun-api-1a2b3c4d","display":"API server"}
```

Changes the display name. The internal name never changes.

#### `restart`

```json
{"t":"cmd","id":6,"op":"restart","session":"bosun-api-1a2b3c4d","resume":true,"defer_launch":false}
```

Stops the agent (Ctrl-C until the pane is back at a shell) and launches it again in the same session, from the spec stored on it. `resume: true` relaunches into the agent's resume command (`claude --continue`, `codex resume --last`, …) for this launch only. The `ack` arrives once the old agent has stopped; the relaunch follows. With `defer_launch: true` the relaunch waits for the client, as with `create`, and the `ack` carries `pending_launch` with the `resume` value to pass back.

#### `launch_agent`

```json
{"t":"cmd","id":7,"op":"launch_agent","session":"bosun-api-1a2b3c4d","resume":null}
```

Types the agent's launch command into a session sitting at a bare shell, rebuilt from the spec stored on the session. `resume: null` uses the stored session mode; `true` or `false` overrides it for this launch. Send the `pending_launch` values from a deferred `create` or `restart` here.

#### `get_spec`

```json
{"t":"cmd","id":8,"op":"get_spec","session":"bosun-api-1a2b3c4d"}
```

Reads the spec stored on a live session, to pre-fill a modify form. The `ack` carries it in `spec`. Sessions Bosun didn't create have none (`ok: false`).

#### `modify`

```json
{"t":"cmd","id":9,"op":"modify","session":"bosun-api-1a2b3c4d","spec":{…}}
```

Stores a new spec on a live session (and its display name if that changed). The running agent is left alone; the next `restart` uses the new spec.

#### `delete_recent`

```json
{"t":"cmd","id":10,"op":"delete_recent","recent":42}
```

Removes one row from the recents list, by its `id`.

#### `sidebar_save`

```json
{"t":"cmd","id":11,"op":"sidebar_save","sidebar":{
  "ungrouped":[{"id":"con-1","name":"api","active":"bosun-api-1a2b3c4d","tabs":[{"session":"bosun-api-1a2b3c4d"}]}],
  "sections":[{"id":"sec-1","name":"Work","collapsed":false,"members":[]}]}}
```

Replaces the sidebar model after a drag and drop reorder, a move between sections, a collapse toggle or a tab reorder. Send back the [sidebar](#sidebar) from the last snapshot or delta, changed; a row's `name` and, on tabs, everything but `session` are ignored. Ids must be unique, every row needs at least one tab, `active` must be one of its tabs, and a session may appear only once. Sections and rows keep their ids. The change is written to `config.toml` (where the TUI reads it), and section membership is remembered by display name as it is in the TUI, so a session that is restarted or recreated lands back in its section. Sessions the model leaves out are added back as ungrouped rows on the next refresh.

#### `insert_section`

```json
{"t":"cmd","id":12,"op":"insert_section","name":"Reviews"}
```

Adds an empty section at the end.

#### `rename_section`

```json
{"t":"cmd","id":13,"op":"rename_section","section":"sec-1","name":"Work (old)"}
```

Renames a section by id. Remembered section membership follows the new name.

#### `set_theme`

```json
{"t":"cmd","id":14,"op":"set_theme","name":"nord","persist":true}
```

Switches the theme. `persist: false` is a live preview (while a picker is open) that isn't written to `config.toml`; send the original name with `persist: false` to cancel it. `persist` defaults to `true`. The name must be one of `themes`.

#### `apply_setting`

```json
{"t":"cmd","id":15,"op":"apply_setting","key":"remove_dead_sessions","value":true}
```

Changes one settings-panel option and writes it to `config.toml`, the same as the TUI's settings panel. `key` is one of the `config.settings` keys; booleans take JSON booleans and choices take one of the listed `choices`. Pinned settings (an environment variable is set) and the read-only install settings are refused with the reason in `error`.

#### `client_flags`

```json
{"t":"cmd","id":16,"op":"client_flags","tty":"/dev/ttys026","ignore_size":true}
```

Sets or clears tmux's `ignore-size` flag on the tmux client attached through `tty`, using `refresh-client -t <tty> -f ignore-size` (or `-f '!ignore-size'`). A terminal view that is hidden in a warm pool sets it so it stops taking part in window-size negotiation; clear it when the view is shown again. `tty` is the client's terminal, which libghostty reports with `ghostty_surface_tty_name()` and tmux shows as `#{client_tty}`. It must be a `/dev/…` path of a client that is attached.

#### `make_latest`

```json
{"t":"cmd","id":17,"op":"make_latest","tty":"/dev/ttys026"}
```

Makes the client on `tty` tmux's latest client for its session, so under `window-size latest` the session takes that client's size straight away. This is what a view needs when it's shown again after another client (Moshi, the TUI) resized the session: clearing `ignore-size` alone isn't enough if the other client acted more recently and the view is the same size as before. `refresh-client` can't do this; the daemon runs `switch-client -c <tty> -t =<session>:` to the session the client is already on, which makes it latest without changing its last-session.

It has the side effects of a keypress in that client: tmux redraws the client and bumps the session's activity time, which can make an activity-based status read briefly as running. The alternative is for the view to write a focus-in report (`ESC [ I`) into its own pty, which tmux swallows and treats as input from that client; with tmux's `focus-events on`, Ghostty already does this when the view gains focus. Use `make_latest` when the view is shown without taking focus.

### Spec

What the new-session form collects:

| Field | Type | Notes |
|---|---|---|
| `name` | string | Display name. Required, no control characters. |
| `path` | string | Working directory. `~` is expanded. Empty means tmux's default. |
| `agent` | string | `claude`, `codex`, `kimi`, `opencode`, `qwen` or `terminal`. |
| `args` | string | Extra arguments appended to the agent command (for `terminal`, the whole command). |
| `options` | object | Per-agent options, below. Every field defaults to off / `new`. |
| `container_id` | string or null | Join this sidebar row as a new tab. |
| `resume` | bool | One-shot resume for this launch only (recreating an exited session). |
| `worktree_branch` | string or null | Create the session in a new git worktree on this branch, placed by the `worktree_location` setting. |

```json
"options": {
  "claude":   {"session_mode":"new","skip_permissions":false,"remote_control":false},
  "codex":    {"session_mode":"new","yolo":false},
  "kimi":     {"session_mode":"new","yolo":false},
  "opencode": {"session_mode":"new","auto":false},
  "qwen":     {"session_mode":"new","yolo":false}
}
```

`session_mode` is `new`, `continue` (resume the directory's last session) or `resume` (the agent's session picker). Only the block for the chosen agent matters.

## Daemon → client

### `snapshot`

```json
{"t":"snapshot","seq":1,
 "server":{"version":"2.1.16","protocol":1,"tmux_socket":"bosun"},
 "sessions":[…],"statuses":{…},"sidebar":{…},"recents":[…],"config":{…},"theme":{…},"themes":[…],
 "keybindings":{…}}
```

The whole state. `server.tmux_socket` is the `-L` socket name terminal views attach with (`tmux -L <socket> attach -t =<session>`); it's absent when Bosun uses tmux's default socket.

#### Sessions

One entry per live tmux session that Bosun manages, in tmux's order:

```json
{"name":"bosun-api-1a2b3c4d","display":"api","agent":"claude","path":"/w/api",
 "windows":1,"attached":true,"created":1792130862,
 "container_id":"con-1","worktree_path":"/w/api/.worktrees/feat","branch":"feat",
 "pane_title":"✳ Fix the flaky test","pane_command":"2_1_220"}
```

`name` is the key for every command. `path` is the path the session was created with, or the shell's working directory for sessions Bosun didn't create. `attached` is whether any tmux client is attached. `created` is Unix seconds. `pane_title` and `pane_command` are the active pane's title and foreground command. Optional fields are left out when unknown.

#### Statuses

```json
{"bosun-api-1a2b3c4d":{"state":"waiting","source":"hook","detail":"permission: Bash"},
 "bosun-docs-5e6f7a8b":{"state":"idle","source":"detector"}}
```

The agent state per session. `state` is `running`, `waiting` (blocked on you: a permission or question prompt), `done` (finished a turn), `idle`, `error` or `unknown`. `source` is `hook` when the agent reported the state itself through the hooks Bosun installs at launch (see the README's "Agent status from hooks"), or `detector` when Bosun worked it out from the pane title and contents. `detail` comes only with hook states and says what the state is about, e.g. `permission: Bash`, `question` or `plan approval` while waiting. A session that's removed from `sessions` is removed from here too.

This is the state Bosun detects for the session itself. The TUI also shows an idle row as done when it ran and changed since you last looked at it; that depends on what each viewer has seen, so the daemon leaves it to the client.

#### Sidebar

```json
{"ungrouped":[
   {"id":"con-1","name":"api","active":"bosun-api-1a2b3c4d",
    "tabs":[{"session":"bosun-api-1a2b3c4d","display":"api","alive":true},
            {"session":"bosun-api-2-9f8e7d6c","display":"api 2","alive":false}]}],
 "sections":[
   {"id":"sec-1","name":"Work","collapsed":false,"banner_font":"metalix",
    "members":[…rows like the ones above…]}]}
```

Ungrouped rows come first, then each section's header and rows, the same order as the TUI. Each row has one or more tabs; `active` is the session name of the shown tab. A row's `name` is its label as the TUI shows it: the display name of its active tab (for an exited tab, the name recovered from recents), so it changes when the active tab changes or is renamed. A tab with `alive: false` is a session that has ended; the TUI keeps such rows (as "exited") so they can be restarted, unless `remove_dead_sessions` is on. Its `display` is the best name Bosun can recover from the recents list. `banner_font` is left out when the section uses the global one.

#### Recents

```json
[{"id":42,"name":"api","path":"/w/api","agent":"claude","args":"","options":{…},"last_used_at":1792130862123,"use_count":7}]
```

Specs used before, most recent first (up to 200). `last_used_at` is Unix milliseconds. Use them to pre-fill a new-session form, or recreate an exited row whose display name matches.

#### Config

```json
{"settings":[
  {"key":"theme","value":"opencode","choices":["opencode","tokyonight",…],"read_only":false},
  {"key":"default_agent","value":"claude","choices":["claude","codex","kimi","opencode","qwen","terminal"],"pinned_by":"BOSUN_DEFAULT_AGENT","read_only":true},
  {"key":"remove_dead_sessions","value":false,"read_only":false},
  {"key":"tmux_socket","value":"bosun","read_only":true}]}
```

The settings panel as data. Keys: `theme`, `banner_font`, `default_agent`, `worktree_location` (`subdir` or `sibling`), `single_window`, `show_group_in_title`, `hide_single_tab_strip`, `remove_dead_sessions`, `embed_enabled`, plus the read-only install settings `session_prefix` and `tmux_socket` (null for tmux's default socket). `choices` is present for choice settings. `pinned_by` names the environment variable that pins a setting; environment variables beat `config.toml`, so a pinned setting is read-only, as it is in the TUI.

#### Theme

```json
{"name":"nord","bg":"#2e3440","panel":"#3b4252","panel_alt":"#434c5e","selection_bg":"#4c566a",
 "text":"#d8dee9","text_muted":"#6d7a90","accent":"#88c0d0","shadow":"#1a1f28","dim_fg":"#4c566a",
 "status_running":"#a3be8c","status_waiting":"#ebcb8b","status_idle":"#6d7a90","status_error":"#bf616a","status_done":"#8fbcbb"}
```

Every color slot of the active theme as `#rrggbb`: backgrounds (`bg` the deepest, then `panel`, `panel_alt`, `selection_bg` for the selected row), text (`text`, `text_muted`), `accent`, `shadow`, `dim_fg` (text dimmed behind a modal) and one color per status. `status_done` is already resolved: themes that don't set it use `accent`, as the TUI does.

#### Themes

```json
[{"name":"opencode","source":"bundled"},{"name":"my-theme","source":"user"}]
```

Every theme `set_theme` accepts, in picker order. `user` themes are `.toml` files in Bosun's `themes` config directory; one with a bundled name replaces the bundled theme.

#### Keybindings

```json
{"previous_tab":"Shift+Left","next_tab":"Shift+Right","previous_session":"Shift+Up","next_session":"Shift+Down","send_next_key":"Ctrl+v"}
```

The TUI's navigation shortcuts from the `[keybindings]` table in `config.toml`, so a remap applies to the TUI and the app alike. Each value is written the way a user writes it in that table: the modifiers `Ctrl`, `Alt` and `Shift` (in that order) joined to the key with `+`, where the key is `Left`, `Right`, `Up`, `Down`, `F1` to `F12`, or a lowercase letter (a letter always comes with `Ctrl` or `Alt`). A disabled action is `null`, and every field is always present. When the table is invalid the TUI falls back to the defaults shown above, and so does this. `send_next_key` is the TUI's key for passing the next key straight through to the agent.

### Deltas

Each delta replaces one part of the snapshot.

```json
{"t":"sessions","seq":3,"upsert":[{…full session…}],"removed":["bosun-old-0f0f0f0f"]}
{"t":"status","seq":4,"session":"bosun-api-1a2b3c4d","state":"waiting","source":"hook","detail":"permission: Bash"}
{"t":"sidebar","seq":5,"sidebar":{…whole sidebar…}}
{"t":"recents","seq":6,"recents":[…whole list…]}
{"t":"config","seq":7,"config":{…whole config…}}
{"t":"theme","seq":8,"theme":{…whole palette…}}
{"t":"themes","seq":9,"themes":[…whole list…]}
{"t":"keybindings","seq":10,"keybindings":{…whole object…}}
```

- `sessions`: `upsert` holds full rows that are new or changed, `removed` the names of sessions that are gone (their statuses go with them). Either may be absent. Row order follows tmux's; a client that cares about order uses the sidebar.
- `status`: one session's state, source or detail changed. The fields are the same as one entry in the snapshot's `statuses`. A state an agent reports through its hook goes out within about 250 ms: the daemon re-reads every session's hook state, pane title and command four times a second over its control-mode connection. States the detectors work out from the pane's contents follow the once-a-second refresh, as in the TUI. (If the control-mode connection is down, hook states fall back to the once-a-second refresh too.)
- The others replace that part of the snapshot whole. These are small and change rarely (on a command, a reconcile, or an edit to `config.toml`). `keybindings` is sent when an edit to `config.toml` changes what the shortcuts resolve to.

The daemon picks up changes to `config.toml` made elsewhere (the TUI's theme picker or settings panel, a text editor) within a second and sends the matching deltas, so a theme change in either the TUI or the app shows in both.

### `notice`

```json
{"t":"notice","seq":11,"message":"created bosun-api-1a2b3c4d"}
```

A message for a person, the same text the TUI shows in its status bar: confirmations and errors from Bosun's own work. Show it as a toast or ignore it. Messages caused by a command are also listed in that command's `ack`.

### `ack`

```json
{"t":"ack","id":7,"ok":false,"error":"worktree has uncommitted changes; not removed","messages":["worktree has uncommitted changes; not removed"]}
```

The reply to one `cmd`. `ok` says whether it worked; `error` is a human-readable reason when it didn't. Optional fields: `session` (`create`), `spec` (`get_spec`), `pending_launch` (`create` and `restart` with `defer_launch`) and `messages` (every `notice` the command caused).

### `error`

```json
{"t":"error","code":"bad_message","message":"unknown variant `nuke`, expected one of …"}
```

A protocol problem rather than a command failure. Codes: `protocol_mismatch` and `no_hello` close the connection; `bad_message` (unparseable JSON, an unknown `t` or `op`, a missing field) doesn't.

## Debugging with socat or nc

Frames have a binary length prefix, so typing them by hand is awkward, but watching works. This sends a `hello` and prints what comes back for a few seconds (`socat - UNIX-CONNECT:"$SOCK"` works the same as `nc -U "$SOCK"`):

```sh
SOCK="$(bosun serve --print-socket)"
(python3 -c 'import json,struct,sys; b=json.dumps({"t":"hello","protocol":1}).encode(); sys.stdout.buffer.write(struct.pack(">I",len(b))+b)'; sleep 5) \
  | nc -U "$SOCK" | LC_ALL=C strings
```

## How commands reach tmux

The daemon (and the TUI) send tmux commands over a `tmux -C` control-mode connection rather than starting a `tmux` process for each one, and match replies by their `%begin`/`%end` numbers. See `src/tmux/command_channel.rs` for the details, including how arguments are quoted. Terminal views never go through the daemon: each one runs its own `tmux attach` in its own pty, so typing never touches it.
