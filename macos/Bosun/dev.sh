#!/bin/bash
# Run Bosun.app against an isolated test daemon with fixture sessions. Never touches tmux's
# default socket, `-L bosun`, or your real Bosun config: the daemon gets its own HOME and
# tmux socket, and the app connects only to that daemon's socket (BOSUN_SERVE_SOCKET).
#
#   ./dev.sh up                      start the test daemon and create the fixture sessions
#   ./dev.sh run [app args]          launch $BOSUN_BUILD_DIR/Bosun.app (default build/) against it (e.g. --selftest, --focustest)
#   ./dev.sh status SESSION STATE [DETAIL]   set a fixture's hook status (running|waiting|done|idle)
#   ./dev.sh tmux ARGS...            run tmux against the test socket (e.g. capture-pane -p -t =api:)
#   ./dev.sh env                     print the variables the app needs, for running it yourself
#   ./dev.sh down                    stop the test daemon and kill ONLY the test tmux server
#   ./dev.sh reset                   down, then delete the throwaway home (its config.toml, sidebar, recents)
#
# Settings (env): BOSUN_DEV_HOME (default /tmp/bosun-mac-dev-$USER; kept short because Unix socket
# paths max out at 104 bytes), BOSUN_DEV_TMUX (tmux socket name, default bosun-mac-dev),
# BOSUN_DEV_BIN (the bosun binary; default: built from this checkout into build/cargo-target),
# BOSUN_BUILD_DIR (where build.sh put the Bosun.app that `run` launches; default build).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEV_HOME="${BOSUN_DEV_HOME:-/tmp/bosun-mac-dev-$USER}"
TMUX_SOCK="${BOSUN_DEV_TMUX:-bosun-mac-dev}"
TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"

case "$TMUX_SOCK" in
  ""|bosun|default) echo "refusing to use tmux socket '$TMUX_SOCK': pick a throwaway name" >&2; exit 1 ;;
esac

# Always build the dev bosun once per run: cargo is a quick no-op when nothing
# changed, and a stale binary silently runs an old daemon against new code.
DEV_TARGET="$HERE/build/cargo-target"
APP_DIR="${BOSUN_BUILD_DIR:-build}"
[[ "$APP_DIR" == /* ]] || APP_DIR="$HERE/$APP_DIR"
if [[ -z "${BOSUN_DEV_BIN:-}" ]]; then
  (cd "$REPO" && CARGO_TARGET_DIR="$DEV_TARGET" cargo build --release --locked --quiet >&2) || exit 1
fi

bin() { echo "${BOSUN_DEV_BIN:-$DEV_TARGET/release/bosun}"; }

denv() {
  env -u TMUX -u TMUX_PANE -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u BOSUN_PREFIX -u BOSUN_THEME \
      -u BOSUN_DEFAULT_AGENT -u BOSUN_REMOVE_DEAD_SESSIONS -u BOSUN_EMBED -u BOSUN_TMUX_CONTROL \
      HOME="$DEV_HOME" BOSUN_TMUX_SOCKET="$TMUX_SOCK" "$@"
}

sock() { denv "$(bin)" serve --print-socket; }

up() {
  mkdir -p "$DEV_HOME"
  local s; s="$(sock)"
  if [[ ${#s} -ge 104 ]]; then echo "socket path too long (${#s} bytes): $s; set a shorter BOSUN_DEV_HOME" >&2; exit 1; fi
  # Bosun's own config and data live in the throwaway HOME, but the sessions get the
  # real one, so a real agent started in a test session finds its login and settings
  # (Claude's OAuth token is in the login keychain under ~/Library/Keychains). Panes
  # inherit the tmux server's global environment, so start the server here and set it.
  env -u TMUX -u TMUX_PANE "$TMUX_BIN" -L "$TMUX_SOCK" start-server \; set -g exit-empty off \; set-environment -g HOME "$HOME"
  # A daemon started before the binary was last rebuilt is running old code: restart it.
  if [[ -f "$LOCK" && "$(bin)" -nt "$LOCK" ]]; then
    echo "restarting the test daemon on the rebuilt bosun" >&2
    stop_daemon
  fi
  if ! python3 -c 'import socket,sys; c=socket.socket(socket.AF_UNIX); c.connect(sys.argv[1])' "$s" 2>/dev/null; then
    # Keep the daemon alive between app runs (it normally exits 30 s after its last client).
    denv nohup "$(bin)" serve --idle-timeout 86400 >"$DEV_HOME/serve.log" 2>&1 &
    local ok=""
    for _ in $(seq 1 100); do
      python3 -c 'import socket,sys; c=socket.socket(socket.AF_UNIX); c.connect(sys.argv[1])' "$s" 2>/dev/null && { ok=1; break; }
      sleep 0.05
    done
    if [[ -z "$ok" ]]; then echo "bosun serve didn't start:" >&2; tail -5 "$DEV_HOME/serve.log" >&2; exit 1; fi
  fi
  python3 "$HERE/fixture/devctl.py" "$s" fixture "$HERE/fixture/fake_agent.py"
  # The generic detector reads a quiet agent's pane (the fake agents) as waiting; start them idle via their hook state.
  local now; now="$(python3 -c 'import time; print(int(time.time()*1000))')"
  for name in $("$TMUX_BIN" -L "$TMUX_SOCK" list-sessions -F '#{session_name}' | grep '^bosun-'); do
    "$TMUX_BIN" -L "$TMUX_SOCK" set-option -p -t "=$name:" @bosun_state idle \; set-option -p -t "=$name:" @bosun_state_at "$now"
  done
  echo "daemon socket: $s"
  echo "tmux socket:   -L $TMUX_SOCK"
}

LOCK="$DEV_HOME/Library/Application Support/dev.yetidevworks.bosun/bosun-serve.lock"

stop_daemon() {
  if [[ -f "$LOCK" ]]; then
    local pid; pid="$(tr -dc 0-9 < "$LOCK")"
    if [[ -n "$pid" ]] && ps -p "$pid" -o command= | grep -q "bosun serve"; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 60); do ps -p "$pid" >/dev/null || break; sleep 0.05; done
    fi
  fi
}

down() {
  stop_daemon
  "$TMUX_BIN" -L "$TMUX_SOCK" kill-server 2>/dev/null || true
  echo "stopped the test daemon and tmux -L $TMUX_SOCK"
}

app_env() { echo "BOSUN_SERVE_SOCKET=$(sock) BOSUN_BIN=$(bin)"; }

case "${1:-}" in
  up) up ;;
  down) down ;;
  reset)
    down
    case "$DEV_HOME" in
      *bosun*|*bmdev*) rm -rf "$DEV_HOME"; echo "removed $DEV_HOME" ;;
      *) echo "not removing $DEV_HOME (doesn't look like a throwaway bosun dev home)" >&2 ;;
    esac ;;
  env) app_env ;;
  run)
    shift
    exec env -u TMUX -u TMUX_PANE BOSUN_SERVE_SOCKET="$(sock)" BOSUN_BIN="$(bin)" \
      "$APP_DIR/Bosun.app/Contents/MacOS/Bosun" -ApplePersistenceIgnoreState YES "$@" ;;
  status)
    [[ $# -ge 3 ]] || { echo "usage: $0 status SESSION running|waiting|done|idle [DETAIL]" >&2; exit 1; }
    name="$2"; state="$3"; detail="${4:-}"
    internal="$("$TMUX_BIN" -L "$TMUX_SOCK" list-sessions -F '#{session_name} #{@bosun_display}' | awk -v d="$name" '$1==d || substr($0, index($0," ")+1)==d {print $1; exit}')"
    [[ -n "$internal" ]] || { echo "no fixture session '$name'" >&2; exit 1; }
    now="$(python3 -c 'import time; print(int(time.time()*1000))')"
    "$TMUX_BIN" -L "$TMUX_SOCK" set-option -p -t "=$internal:" @bosun_state "$state" \; \
      set-option -p -t "=$internal:" @bosun_state_at "$now" \; \
      set-option -p -t "=$internal:" @bosun_state_detail "$detail"
    ;;
  tmux) shift; exec "$TMUX_BIN" -L "$TMUX_SOCK" "$@" ;;
  *) sed -n '2,18p' "$0"; exit 1 ;;
esac
