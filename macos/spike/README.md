# Bosun for Mac: Phase 0 spike

Throwaway code that answers the spike questions in `docs/mac-app-design.md` (section 12) with evidence. Results and the write-up are in `results/FINDINGS.md`. Nothing here is meant to survive into the real app except what the findings say.

Everything runs against the throwaway tmux socket `-L bosun-spike`. Nothing in here touches the default socket or `-L bosun`.

## Prerequisites

- Xcode (tested with Xcode 27.0, Swift 6.4), `xcodegen` (Homebrew), tmux 3.8, python3.
- A libghostty xcframework built from the pinned Ghostty commit, next to the bosun checkout:

```
cd /Users/rhuk/Projects/yetidevworks
git clone https://github.com/ghostty-org/ghostty.git && cd ghostty
git checkout b3dc3d794513c11633e7c3347935693957744e83
# Ghostty main needs Zig 0.16.x exactly; Homebrew's 0.17 is refused. Use a local toolchain:
mkdir -p .zig-toolchain && cd .zig-toolchain
curl -LO https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz   # sha256 b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
tar xf zig-aarch64-macos-0.16.0.tar.xz && cd ..
./.zig-toolchain/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native
```

That produces `ghostty/macos/GhosttyKit.xcframework` (static lib + `ghostty.h`) and `ghostty/zig-out/share/{terminfo,ghostty}`, which the app build copies into its Resources.

## Build (one command)

```
macos/spike/build.sh
```

It runs `xcodegen generate` and `xcodebuild` (Release, arm64) and copies the result to `macos/spike/build/BosunSpike.app`. Xcode prints a spurious "error: the following command failed with exit code 0 but produced no further output" line; the build still succeeds.

## Fixture

```
macos/spike/fixture.sh     # creates bosun-spike-1..6 on -L bosun-spike (window-size latest)
macos/spike/teardown.sh    # kills ONLY the -L bosun-spike server
```

Sessions: 1 idle `zsh -f`, 2 and 3 a spinner + timestamp ticker (5 lines/s), 4 `top -s 1`, 5 `fixture/reflow.py` (redraws a full-screen box on every SIGWINCH and appends each one to `results/sigwinch.log`), 6 a plain `bash`. No real agents are launched.

## Run

```
APP=macos/spike/build/BosunSpike.app/Contents/MacOS/BosunSpike
$APP                                   # interactive: sidebar lists sessions, click to show; Cmd+D split, Cmd+] other tile, Cmd+1..9 jump
$APP --selftest                        # 100 warm swaps, 20 cold attaches, 4 scripted divider drags -> results/selftest.txt, then quits
$APP --q1test                          # hidden-client sizing experiment with an external client -> results/q1-app.txt
$APP --memtest --memtest-label scrollback0                                         # -> results/memtest-scrollback0.txt
BOSUN_SPIKE_SCROLLBACK=default $APP --memtest --memtest-label scrollback-default   # same with Ghostty's default scrollback
$APP --idle 60 --sessions bosun-spike-1,bosun-spike-6,bosun-spike-5,bosun-spike-7  # idle CPU (needs a 7th idle session) -> results/idle.txt
$APP --demo split:bosun-spike-5,bosun-spike-2,bosun-spike-1,bosun-spike-6         # fixed layout for screenshots (extra names are warmed in the pool)
```

Every mode writes the window id to `results/window-id.txt`, so `screencapture -x -o -l "$(cat macos/spike/results/window-id.txt)" out.png` captures the window.

`--selftest` emits `os_signpost` intervals (subsystem `dev.yetidevworks.bosun-spike`, category PointsOfInterest): `WarmSwap`, `ColdAttach`, `WarmupAttach`, `DividerDrag`, plus a `first-frame` event. Open Instruments with the Points of Interest instrument to see them.

## Tools

- `tools/ctl_probe.py <session> <secs> <script>`: drives a `tmux -C` client and prints every notification with timestamps (Q2, Q5).
- `tools/pty_client.py`: a non-app tmux client in a real pty (Moshi/TUI stand-in), scriptable over a FIFO (`type`, `focus`, `size C R`, `quit`).
- `tools/attach_latency.py`: direct vs `login`-wrapped `tmux attach` time to first paint.

## Layout

- `Sources/TerminalView.swift`: the only file that calls libghostty per view (surface, sizing with throttle, occlusion, keys/IME, mouse, frame signal).
- `Sources/Ghostty.swift`: the single shared `ghostty_app_t`, config loading + overrides, runtime callbacks.
- `Sources/Workspace.swift`: sidebar (SwiftUI), manual-layout main area, warm pool (LRU), two-tile split with divider.
- `Sources/SelfTest.swift`, `Sources/OtherTests.swift`: the automated measurements.
