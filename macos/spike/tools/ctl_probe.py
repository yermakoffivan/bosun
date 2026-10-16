#!/usr/bin/env python3
"""Drive a tmux control-mode client on -L bosun-spike and print every line it emits with a timestamp.
Usage: ctl_probe.py <session> <seconds> <script-file>
The script file has one line per action: `ctl <tmux command>` (written to the control client's stdin),
`sh <shell command>` (run in a shell, e.g. an out-of-band tmux command), or `sleep <s>`."""
import subprocess, sys, threading, time

session, seconds, script = sys.argv[1], float(sys.argv[2]), sys.argv[3]
t0 = time.monotonic()
def ts(): return f"{time.monotonic() - t0:7.3f}"
p = subprocess.Popen(["tmux", "-L", "bosun-spike", "-C", "attach-session", "-t", session],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
def reader():
    for line in p.stdout:
        line = line.rstrip("\n")
        if line.startswith("%output"):
            continue  # pane output is noise for these probes
        print(f"[{ts()}] < {line}", flush=True)
threading.Thread(target=reader, daemon=True).start()
time.sleep(0.3)
for raw in open(script):
    raw = raw.rstrip("\n")
    if not raw or raw.startswith("#"): continue
    kind, _, rest = raw.partition(" ")
    if kind == "ctl":
        print(f"[{ts()}] > {rest}", flush=True)
        p.stdin.write(rest + "\n"); p.stdin.flush()
    elif kind == "sh":
        print(f"[{ts()}] $ {rest}", flush=True)
        out = subprocess.run(rest, shell=True, capture_output=True, text=True)
        for l in (out.stdout + out.stderr).splitlines(): print(f"[{ts()}]   {l}", flush=True)
    elif kind == "sleep":
        time.sleep(float(rest))
end = t0 + seconds
while time.monotonic() < end: time.sleep(0.05)
p.stdin.close()
try: p.wait(timeout=2)
except Exception: p.kill()
