#!/usr/bin/env python3
"""A stand-in for an AI agent in fixture sessions: no network, no model.

  fake_agent.py NAME            prompt loop: echoes every line it reads ("got: ...")
  fake_agent.py NAME --ticker   prints a timestamped line every second (a busy agent)

It runs as python, not a shell, so Bosun's hook status options apply to its pane.
"""
import sys
import time

name = sys.argv[1] if len(sys.argv) > 1 else "agent"
ticker = "--ticker" in sys.argv

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
