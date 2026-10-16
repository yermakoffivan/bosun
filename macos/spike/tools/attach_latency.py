#!/usr/bin/env python3
"""Time from fork to tmux's first full paint (status line for the session shows up) for a `tmux attach`
in a fresh pty, run directly vs. wrapped the way libghostty runs a surface command on macOS
(/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <cmd>")."""
import os, pty, sys, time, select, fcntl, termios, struct, signal, getpass, statistics

session = sys.argv[1] if len(sys.argv) > 1 else "bosun-spike-6"
n = int(sys.argv[2]) if len(sys.argv) > 2 else 15
cmd = f"tmux -L bosun-spike attach -t ={session}"
marker = f"[{session}]".encode()
variants = {
    "direct": ["tmux", "-L", "bosun-spike", "attach", "-t", "=" + session],
    "login-wrapped": ["/usr/bin/login", "-flp", getpass.getuser(), "/bin/bash", "--noprofile", "--norc", "-c", f"exec -l {cmd}"],
}
for name, argv in variants.items():
    xs = []
    for i in range(n):
        t0 = time.monotonic()
        pid, fd = pty.fork()
        if pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.execvp(argv[0], argv)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
        buf = b""
        while time.monotonic() - t0 < 3:
            r, _, _ = select.select([fd], [], [], 0.2)
            if not r: continue
            try: buf += os.read(fd, 65536)
            except OSError: break
            if marker in buf:
                xs.append(time.monotonic() - t0); break
        # Close the pty master (the tty hangs up, like a terminal closing), then reap without blocking forever.
        os.close(fd)
        for _ in range(200):
            if os.waitpid(pid, os.WNOHANG)[0]: break
            time.sleep(0.01)
        time.sleep(0.1)
    xs.sort()
    if not xs: print(f"{name}: no paint seen"); continue
    print(f"{name:14s} n={len(xs)} p50={statistics.median(xs)*1000:.1f} ms  min={xs[0]*1000:.1f} ms  max={xs[-1]*1000:.1f} ms")
