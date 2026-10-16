#!/usr/bin/env python3
"""Stand-in for an Ink/Claude Code style app: on every SIGWINCH it redraws a full-screen box.
Every SIGWINCH is appended to the log file given as argv[1] as: <monotonic_ns> <count> <cols>x<rows>."""
import os, signal, sys, time, shutil

log_path = sys.argv[1]
count = 0
pending = False

def on_winch(signum, frame):
    global count, pending
    count += 1
    pending = True
    cols, rows = os.get_terminal_size(sys.stdout.fileno())
    with open(log_path, "a") as f:
        f.write(f"{time.monotonic_ns()} {count} {cols}x{rows}\n")

def redraw():
    cols, rows = os.get_terminal_size(sys.stdout.fileno())
    out = ["\x1b[H\x1b[2J"]
    out.append("+" + "-" * (cols - 2) + "+\r\n")
    for r in range(1, rows - 1):
        label = f" reflow stand-in  {cols}x{rows}  sigwinch={count}  row {r}"
        out.append("|" + label[: cols - 2].ljust(cols - 2) + "|\r\n")
    out.append("+" + "-" * (cols - 2) + "+")
    sys.stdout.write("".join(out))
    sys.stdout.flush()

signal.signal(signal.SIGWINCH, on_winch)
with open(log_path, "a") as f:
    f.write(f"# start pid={os.getpid()}\n")
redraw()
while True:
    if pending:
        pending = False
        redraw()
    time.sleep(0.01)
