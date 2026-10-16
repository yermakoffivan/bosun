# Phase 0 spike findings

Test machine: macOS 27.0.1 arm64, 60 Hz display at 2x (nothing measured at 120 Hz), tmux 3.8, Xcode 27.0. Ghostty pinned at `b3dc3d794513c11633e7c3347935693957744e83` (main, 2026-10-15), built with the official Zig 0.16.0 tarball in `ghostty/.zig-toolchain/` because Ghostty main refuses Homebrew's 0.17. Raw evidence is in the files listed at the end.

## Summary

| Question | Answer | Plan impact |
|---|---|---|
| Q1 hidden-client sizing | Works, but a newly shown view must be made tmux's "latest" client explicitly. Match views to clients by tty name, not pid. | Section 5 holds, with the changes under Q1 |
| Q2 subscriptions in other sessions | Targeting another session's pane or window: no. A looping format in a subscription on the monitor's own session: yes, but tmux only checks about once a second. | Keep the 250 ms poll for the badge budget |
| Q3 libghostty embedding | Everything needed is in the C API, with four gotchas | Section 4 holds, plus the workarounds |
| Q4 live resize | The reflow script got 5 SIGWINCHs per 1 s drag with or without the app throttle, so tmux paces pane resizes itself. The throttle still cut tmux window resizes from 29 to 10. The drag held 60 Hz. | Keep the throttle, retuned to about 50 ms or optional. It isn't what protects the agents. |
| Q5 control client and sizing | A control client with no size set is ignored, even when attached to the same session and sending commands. One that sends `refresh-client -C WxH` does take part. | Plan holds. Rule: never send `-C` from the monitor. |
| Warm swap | p50 4.2 ms, p99 9.8 ms to first fresh frame | Meets 1 frame at 60 Hz; p90 (8.4 ms) is right at a 120 Hz frame |
| Cold attach | p50 59 ms, p99 73 ms to tmux's first paint (an earlier run: p50 64, p99 82) | Close to the 80 ms budget. Removing Ghostty's `login` wrapper saves about 28 ms. |
| Memory per view | About 13 to 14 MB per extra view. The first view costs about 258 MB once, mostly GPU memory. | Meets the 15 MB budget; add the one-time cost to the plan |
| Idle CPU, 4 views | 0.43% of one core with a focused tile (cursor blink), 0.22% with none | Meets the 0.5% budget |

## Q1. Hidden-client sizing

**Matching a view to its tmux client:** `ghostty_surface_tty_name()` returns exactly tmux's `#{client_tty}` (for example `/dev/ttys026`), and tmux accepts that as a `-t` target, so `refresh-client -t <tty>` works directly with no exec wrapper and no pid matching. `ghostty_surface_foreground_pid()` returns the pid of Ghostty's `login` wrapper (the tmux client is its child); libghostty doesn't expose the direct child pid.

**How tmux 3.8 chooses the size under `window-size latest`:**

- The window follows whichever client most recently sent input, resized its pty, or attached. A pty resize counts even though `#{client_activity}` doesn't change.
- `refresh-client`, with or without `-f`, does not make a client latest.
- A client marked `ignore-size` is skipped while any other client is attached, even if it typed last.
- If the only client left is `ignore-size` and it was the latest, tmux still sizes the window to it. If the latest client detaches and only an ignored client remains, the window keeps its last size.

**What happens to hidden pool views:**

- App only, one view per session (the plan's model): a hidden view never resizes and never sends input, so it can't change its session's size. Verified by hiding a view, and by resizing the window while a view was hidden.
- With a second client (a stand-in for Moshi or the TUI):
  - Without `ignore-size`, a hidden app client that was latest keeps the session at the app's size, and the other client sees the wrong size until it types or resizes.
  - Setting `-f ignore-size` on hide hands sizing to the other client straight away (130x41 to 100x29), and the session then follows that client's resizes.
  - Clearing the flag with `-f '!ignore-size'` on show is not enough if the other client acted more recently and the tile is the same size: the session stayed 100x29 inside a 130x42 view. Showing into a tile of a different size does take the size back, because the pty resize makes the app client latest.
  - What reliably takes the size back is the view writing a focus-in report, `ESC [ I`, via `ghostty_surface_binding_action(surface, "text:\\x1b[I")`. tmux swallows it: a `cat -v` pane received nothing with `focus-events` off or on.
  - With `focus-events on` (Andy's `~/.tmux.conf` sets it), Ghostty sends that report itself when the view gains focus. This only works for clients that attached after `focus-events` was turned on.
- Inherent to `latest`: if a Moshi user types while the session is visible in the app, the session resizes to Moshi until the app view gets input or focus again.

**Plan change for section 5:** keep `window-size latest` and per-client `ignore-size`, and match clients by tty name, dropping the pid and wrapper ideas. On hide, send `refresh-client -t <tty> -f ignore-size`. On show, send `-f '!ignore-size'` and then make the client latest with a focus report. Each is one tmux command and can go over the daemon's control channel.

## Q2. Subscriptions from the monitor session

Tested from a control client attached to `__bosun_monitor`:

- Targets in other sessions (`%0`, `%5`, `@1`) are accepted silently and never fire.
- `%*` only covers the monitor's own session.
- This looping format, on the monitor's own session, fires with every pane of every session: `refresh-client -B 'loop_all::#{S:#{session_name}[#{W:#{P:#{pane_id}=#{pane_title}/#{pane_current_command};}}] }'`. The format must be single-quoted, or tmux returns `parse error: syntax error`.

Changes arrive 0.5 to 1.0 s after they happen, and each notification is the whole string. A braille spinner keeps changing, so while any agent is working this becomes about one notification per second. That can't meet the 250 ms badge budget, so keep the `list-panes -a` poll. The subscription could let the poll back off when everything is idle.

## Q3. libghostty embedding

One app object with one view per session works, and libghostty installs its own render layer on the view. The gotchas:

- **Occlusion:** in `ghostty_surface_set_occlusion(surface, bool)` the bool means "visible", not "occluded". Hidden views drew 0 frames in the idle test while their pty kept draining.
- **Custom command:** it always runs through a shell, and on macOS that is `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <cmd>"`. It also forces `wait-after-command`. The wrapper costs about 28 ms per spawn (direct `tmux attach` p50 13.5 ms vs wrapped p50 41.8 ms), and it prints "Last login" unless `~/.hushlogin` exists. Avoiding it needs a small libghostty patch, and that is the main lever for the cold-attach budget.
- **Detaching:** `ghostty_surface_free` sends SIGHUP and then polls `waitpid` with 10 ms sleeps on the main thread (p50 12.5 ms). Running `tmux detach-client -t <tty>` off the main thread first, then freeing once the client has exited, takes p50 1.4 ms.
- **User config:** loading the default and recursive files reads it correctly (font size 15, theme One Dark Two, 0 diagnostics). App overrides are layered on top from a second config file.
  - Andy's config sets `term = "xterm-256color"`, so the app must override it with `term = xterm-ghostty` or the bundled terminfo goes unused.
  - The app must also set `GHOSTTY_RESOURCES_DIR` to its own bundle, because an inherited value wins in release builds. TERMINFO is then derived from it, and the themes have to be bundled too.
- **Sizing:** libghostty already coalesces pty resizes on a 25 ms timer. Its render layer throws away frames whose size doesn't match the view, so a throttled tile freezes on its last correct frame until the next resize.
- **Text input and IME:** all the needed API exists (`ghostty_surface_key`, `ghostty_surface_key_translation_mods`, `ghostty_surface_key_is_binding`, `ghostty_surface_preedit`, `ghostty_surface_ime_point`). The view ports Ghostty's own key handling and IME client code.
- **Frame timing:** there is no "frame presented" callback. The timings use a KVO observation on the view's layer `contents` as the proxy; the screen shows the frame at the next refresh after that.
- **API churn:** the clipboard callbacks at this commit take MIME lists, which is newer than older embedders use. That supports pinning the commit and keeping all libghostty calls in one class.
- `ghostty_config_get("scrollback-limit")` returned false; other keys read back fine.

## Q4. Live resize

The left tile ran the SIGWINCH stand-in script. A display link moved the divider from 50% to 25% over 1 s, with a final resize at the end. A control client counted tmux's window resizes.

| Drag | Throttle | Ghostty resize calls | tmux window resizes | SIGWINCH to the script | Left tile frames | Late frames |
|---|---|---|---|---|---|---|
| 1 | 100 ms | 11 | 10 | 5 | 83 | 1 |
| 2 | off | 60 | 29 | 5 | 108 | 1 |
| 3 | 100 ms | 11 | 10 | 5 | 85 | 1 |
| 4 | off | 60 | 29 | 5 | 108 | 1 |

Each drag was 61 steps over 1017 ms at 60 Hz. Layout work per step was under 0.4 ms at p99, and the one late frame per drag (33 ms) came at the start. tmux paced the script at about 4 resizes a second plus the final one, with or without the throttle. That was observed but the mechanism wasn't confirmed in tmux's source.

## Q5. Control client and sizing

With a 100x30 client attached and a control client sending `send-keys`, `display` and `list-clients` to the same session, the window stayed 100x29. After that control client sent `refresh-client -C 200x50`, the window went to 200x50. A monitor client on `__bosun_monitor` sending commands to other sessions left their size alone. Target syntax needs the `=name:` form; `=name` alone fails as a pane target.

## Memory and idle

- **Memory:** an empty window is 28 MB. The first view adds about 258 MB once, of which about 197 MB is GPU memory and about 47 MB is render buffers. Ghostty.app itself measured 314 MB with one tmux window and the same GPU line, so this is normal libghostty cost. Each extra view adds 13.2 MB with scrollback at 0, or 14.0 MB with Ghostty's default; scrollback made no real difference because a fresh attach only paints one screen. During the idle run the app sat at 123 MB.
- **Idle CPU:** 4 views attached (2 shown, 2 hidden) on quiet sessions. 0.43% of one core with a focused tile, where the blinking cursor drew 53 frames in 31 s; 0.22% with nothing focused; `top` averaged 0.30%. Cursor blink is the largest idle cost, so consider turning it off when the window isn't focused.

## Not verified

- Typing feel, IME, dead keys and Option-as-Meta in the embedded view (needs Andy at the keyboard).
- 120 Hz behaviour (the display used was 60 Hz).
- How a throttled resize looks with a real Claude Code session mid-render.
- The tmux mechanism that limits pane resizes.
- Real Moshi; a scripted pty client stood in for it.

## Evidence files

`selftest.txt`, `q1-app.txt`, `q1-tmux-level.log`, `q1-tmux-level-v4.log`, `q2-subscriptions.log`, `q5-control-client-sizing.log`, `attach-latency.txt`, `memtest-scrollback0.txt`, `memtest-scrollback-default.txt`, `idle.txt`, `idle-top.txt`, `sigwinch.log`, `ghostty-build.log`, `screenshot-single.png`, `screenshot-split.png`.
