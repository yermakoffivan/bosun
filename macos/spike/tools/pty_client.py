#!/usr/bin/env python3
"""A non-app tmux client: runs `tmux -L bosun-spike attach -t =<session>` inside a real pty of a fixed size
and drains its output (like a terminal would), so tmux sees an ordinary attached client (a stand-in for
Moshi or the Bosun TUI).

Usage: pty_client.py <session> <cols> <rows> <seconds> [--type-at S] [--focus-at S] [--ctl FIFO]
  --type-at S   at S seconds, send a harmless key pair (space, backspace): makes this client the most recently active
  --focus-at S  at S seconds, send a focus-out/focus-in report (ESC[O ESC[I), as a terminal does when it gains focus
  --ctl FIFO    read commands from a FIFO, one per line: `type`, `focus`, `size <cols> <rows>`, `quit`
"""
import os, pty, sys, time, fcntl, termios, struct, select, signal

session, cols, rows, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
def opt(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None
type_at = float(opt("--type-at")) if opt("--type-at") else None
focus_at = float(opt("--focus-at")) if opt("--focus-at") else None
ctl_path = opt("--ctl")

pid, fd = pty.fork()
if pid == 0:
    os.execvp("tmux", ["tmux", "-L", "bosun-spike", "attach", "-t", "=" + session])

def set_size(c, r):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", r, c, 0, 0))
    os.kill(pid, signal.SIGWINCH)

set_size(cols, rows)
print(f"pty_client pid={os.getpid()} tmux_client_pid={pid} {cols}x{rows}", flush=True)
ctl = os.open(ctl_path, os.O_RDWR | os.O_NONBLOCK) if ctl_path else None
buf = b""
t0 = time.monotonic(); typed = focused = False
while time.monotonic() - t0 < secs:
    rl = [fd] + ([ctl] if ctl is not None else [])
    r, _, _ = select.select(rl, [], [], 0.05)
    if fd in r:
        try:
            os.read(fd, 65536)
        except OSError:
            break
    if ctl is not None and ctl in r:
        data = os.read(ctl, 4096)
        if not data:
            os.close(ctl)
            ctl = os.open(ctl_path, os.O_RDWR | os.O_NONBLOCK)
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            cmd = line.decode().split()
            if not cmd:
                continue
            if cmd[0] == "type":
                os.write(fd, b" \x7f")
            elif cmd[0] == "focus":
                os.write(fd, b"\x1b[O\x1b[I")
            elif cmd[0] == "size":
                set_size(int(cmd[1]), int(cmd[2]))
            elif cmd[0] == "quit":
                secs = 0
    if type_at is not None and not typed and time.monotonic() - t0 >= type_at:
        os.write(fd, b" \x7f"); typed = True
    if focus_at is not None and not focused and time.monotonic() - t0 >= focus_at:
        os.write(fd, b"\x1b[O\x1b[I"); focused = True
try:
    os.kill(pid, signal.SIGHUP)
except ProcessLookupError:
    pass
