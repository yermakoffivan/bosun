#!/usr/bin/env python3
"""A stand-in for an AI agent in fixture sessions: no network, no model.

  fake_agent.py NAME            prompt loop: echoes every line it reads ("got: ...")
  fake_agent.py NAME --ticker   prints a timestamped line every second (a busy agent)
  fake_agent.py NAME --ink      redraws like Claude Code's ink renderer: a status block 30 times a
                                second, and the whole screen (history included) on every SIGWINCH

It runs as python, not a shell, so Bosun's hook status options apply to its pane.
"""
import os
import signal
import sys
import textwrap
import time

name = sys.argv[1] if len(sys.argv) > 1 else "agent"
ticker = "--ticker" in sys.argv
ink = "--ink" in sys.argv


def run_ink():
    words = ("the parser walks each token and the resolver checks every binding against the scope "
             "it came from before the type checker runs over the whole module again").split()
    history = [" ".join(words[(i * 7) % len(words):] + words[:(i * 7) % len(words)]) + f" ({i})" for i in range(60)]
    out = sys.stdout
    spin = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    block = 6
    start = time.time()
    resized = [True]
    signal.signal(signal.SIGWINCH, lambda *_: resized.__setitem__(0, True))

    def status(cols, n):
        bar = max(4, cols - 24)
        filled = n % (bar + 1)
        lines = [
            f"\x1b[38;5;208m{spin[n % len(spin)]}\x1b[0m Working… ({time.time() - start:4.1f}s · esc to interrupt)",
            "",
            "  [" + "█" * filled + "·" * (bar - filled) + "]",
            f"  {name}: step {n}".ljust(cols)[:cols],
            "─" * cols,
            "> ",
        ]
        return "".join("\x1b[2K" + l[:cols + 20] + ("\r\n" if i < block - 1 else "") for i, l in enumerate(lines))

    n = 0
    while True:
        cols = max(10, os.get_terminal_size().columns)
        if resized[0]:
            # What ink does on a resize: clear everything and render the static output again, wrapped to the new width.
            resized[0] = False
            body = "\r\n".join(l for h in history for l in textwrap.wrap(h, cols - 1))
            out.write("\x1b[2J\x1b[3J\x1b[H" + f"\x1b[1mfake agent · {name}\x1b[0m   (busy fixture)\r\n" + body + "\r\n" + status(cols, n))
        else:
            out.write(f"\x1b[{block - 1}A\r" + status(cols, n))
        out.flush()
        n += 1
        time.sleep(1 / 30)


if ink:
    run_ink()

print(f"\x1b[1mfake agent · {name}\x1b[0m   (fixture session, no real agent)")
if ticker:
    i = 0
    while True:
        print(f"{time.strftime('%H:%M:%S')}  working… step {i}", flush=True)
        i += 1
        time.sleep(1)
else:
    print("type a line and press Return; it is echoed back")
    while True:
        try:
            line = input("› ")
        except EOFError:
            time.sleep(0.2)
            continue
        except KeyboardInterrupt:
            print()
            continue
        # Drop control characters (a stray Ctrl-L from the launch, escape sequences) from the echo.
        line = "".join(ch for ch in line if ch >= " " and ch != "\x7f")
        print(f"got: {line}", flush=True)
