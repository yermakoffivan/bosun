#!/bin/bash
# Creates the spike fixture on the throwaway tmux socket -L bosun-spike.
# Never touches the default socket or -L bosun.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T=(tmux -L bosun-spike -f "$HERE/fixture/spike.tmux.conf")
mkdir -p "$HERE/results"
SIGLOG="$HERE/results/sigwinch.log"
: > "$SIGLOG"

new() { # name, command...
  local name=$1; shift
  if "${T[@]}" has-session -t "=$name" 2>/dev/null; then return; fi
  "${T[@]}" new-session -d -s "$name" -x 120 -y 36 "$@"
  "${T[@]}" set-option -t "$name" window-size latest >/dev/null
}

new bosun-spike-1 zsh -f                                   # idle zsh
new bosun-spike-2 "$HERE/fixture/ticker.sh" alpha          # continuous output
new bosun-spike-3 "$HERE/fixture/ticker.sh" beta           # continuous output
new bosun-spike-4 top -s 1                                 # full-screen reflowing TUI
new bosun-spike-5 "$HERE/fixture/reflow.py" "$SIGLOG"      # SIGWINCH full redraw, logs count
new bosun-spike-6 /bin/bash --norc --noprofile             # plain shell
"${T[@]}" list-sessions -F '#{session_name} #{window_width}x#{window_height} #{window_size}'
