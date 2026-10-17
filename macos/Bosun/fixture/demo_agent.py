#!/usr/bin/env python3
"""Staged agent screens for `dev.sh demo`: plausible Claude Code, Codex, test runner and dev server
output for a made-up project, so screenshots never show anyone's real sessions.

  demo_agent.py [SCENE]   SCENE defaults to the tmux session's Bosun display name

It also stands in for the `claude` and `codex` binaries (the demo's config.toml points `[agents]` at
it), so it ignores any other arguments. Each screen is redrawn to fit the pane on every resize, using
only the 16 ANSI colours so it follows the theme. It never exits.
"""
import os
import shutil
import signal
import subprocess
import sys
import time

R, B, D, I = "\033[0m", "\033[1m", "\033[2m", "\033[3m"
RED, GRN, YEL, BLU, MAG, CYN = "\033[31m", "\033[32m", "\033[33m", "\033[34m", "\033[35m", "\033[36m"


def ok(tool, arg):
    return f"{GRN}⏺{R} {B}{tool}{R}({arg})"


def out(text):
    return f"  {D}⎿{R}  {text}"


def more(text):
    return f"     {text}"


def box(cols, text=""):
    w = max(20, cols - 2)
    return [f"{D}╭{'─' * (w - 2)}╮{R}", f"{D}│{R} {text}{' ' * max(0, w - 4 - visible(text))} {D}│{R}", f"{D}╰{'─' * (w - 2)}╯{R}"]


def visible(s):
    n, esc = 0, False
    for ch in s:
        if ch == "\033":
            esc = True
        elif esc:
            esc = ch != "m"
        else:
            n += 1
    return n


def fit(line, cols):
    """`line` cut to `cols` visible characters (escape sequences kept), so nothing wraps in a narrow pane."""
    if visible(line) <= cols:
        return line
    out, n, esc = [], 0, False
    for ch in line:
        if ch == "\033":
            esc = True
        if esc:
            out.append(ch)
            esc = ch != "m"
            continue
        if n >= cols - 1:
            break
        out.append(ch)
        n += 1
    return "".join(out) + "…" + R


SPIN = "·✢✳✶✻✽✻✶✳✢"


def checkout(cols, tick):
    spin = SPIN[tick % len(SPIN)]
    secs = 112 + tick // 8
    lines = [
        f"{D}> Pull the checkout totals out of CartSummary into a pure function,{R}",
        f"{D}  and cover the promo code edge cases with tests{R}",
        "",
        "⏺ I'll find where the totals are worked out first.",
        "",
        ok("Search", 'pattern: "subtotal|discount", path: "src/checkout"'),
        out("Found 5 files"),
        "",
        ok("Read", "src/checkout/CartSummary.tsx"),
        out("Read 214 lines"),
        "",
        "⏺ The totals are computed inline in CartSummary, and promo codes",
        "  are applied after tax, so a percentage code also discounts the",
        "  tax. I'll move the maths into totals.ts and discount before tax.",
        "",
        ok("Write", "src/checkout/totals.ts"),
        out("Wrote 64 lines to src/checkout/totals.ts"),
        more(f"{D}export interface Totals {{{R}"),
        more(f"{D}  subtotal: number; discount: number{R}"),
        more(f"{D}  tax: number; total: number{R}"),
        more(f"{D}}}{R}"),
        more(f"{D}… +59 lines (ctrl+r to expand){R}"),
        "",
        ok("Update", "src/checkout/CartSummary.tsx"),
        out("Updated src/checkout/CartSummary.tsx with 4 additions and 27 removals"),
        more(f"{D}12{R} {RED}-  const subtotal = items.reduce((s, i) => s + i.price * i.qty, 0){R}"),
        more(f"{D}13{R} {RED}-  const tax = subtotal * region.taxRate{R}"),
        more(f"{D}14{R} {RED}-  const discount = promo ? applyPromo(promo, subtotal + tax) : 0{R}"),
        more(f"{D}12{R} {GRN}+  const {{ subtotal, discount, tax, total }} ={R}"),
        more(f"{D}13{R} {GRN}+    totals(items, region, promo){R}"),
        "",
        ok("Bash", "npm test -- --run src/checkout"),
        out(f"{GRN}✓{R} src/checkout/totals.test.ts (9 tests) 21ms"),
        more(f"{GRN}✓{R} src/checkout/CartSummary.test.tsx (12 tests) 88ms"),
        more(f"Tests  {GRN}21 passed{R} (21)"),
        "",
        f"{GRN}⏺{R} {B}Update Todos{R}",
        out(f"{D}☒ Move the totals into a pure function{R}"),
        more(f"{D}☒ Apply promo codes before tax{R}"),
        more(f"☐ {B}Tests for stacked and expired promo codes{R}"),
        more("☐ Round each line to cents before summing"),
        "",
        f"{YEL}{spin} Writing promo code edge case tests…{R} {D}({secs // 60}m {secs % 60:02d}s · ↓ 4.1k tokens · esc to interrupt){R}",
        "",
        *box(cols, f"{D}>{R} "),
        f"  {MAG}⏵⏵ accept edits on{R} {D}(shift+tab to cycle){R}",
    ]
    return lines


def auth(cols, tick):
    return [
        f"{D}> The refresh token isn't rotated when a session is resumed. Fix it{R}",
        f"{D}  and add a regression test{R}",
        "",
        ok("Read", "src/auth/session.ts"),
        out("Read 156 lines"),
        "",
        ok("Update", "src/auth/session.ts"),
        out("Updated src/auth/session.ts with 9 additions and 2 removals"),
        "",
        "⏺ Now the integration test, which needs the local Postgres.",
        "",
        *box(cols, f"{B}Bash command{R}"),
        "",
        f"   {CYN}docker compose up -d db && npm run test:int -- auth{R}",
        f"   {D}Start the test database and run the auth integration tests{R}",
        "",
        " Do you want to proceed?",
        f" {CYN}❯ 1. Yes{R}",
        "   2. Yes, and don't ask again for docker compose commands",
        "   3. No, and tell Claude what to do differently (esc)",
    ]


def search(cols, tick):
    spin = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[tick % 10]
    return [
        f"{D}>_{R} {B}OpenAI Codex{R} {D}(v0.46.0){R}",
        "",
        f"{D}▌{R} Add typo tolerance to product search, max edit distance 1 for",
        f"{D}▌{R} words of 5+ letters",
        "",
        f"{D}•{R} Explored",
        f"  {D}└{R} Read {B}search/index.ts{R}, {B}search/query.ts{R}",
        f"    Search {B}fuzzy{R} in src",
        "",
        f"{D}•{R} Edited {B}src/search/query.ts{R} {GRN}(+42{R} {RED}-6){R}",
        "",
        f"{D}•{R} Ran {B}npm run bench:search{R}",
        f"  {D}└{R} p95 18.4ms → 21.1ms (12k products)",
        "",
        f"{CYN}{spin}{R} Working… {D}(2m 07s · esc to interrupt){R}",
        "",
        f"{D}▌{R} {D}Ask Codex to do anything{R}",
    ]


def review(cols, tick):
    return [
        f"{D}> Review PR #218 (webhook retries){R}",
        "",
        ok("Bash", "gh pr diff 218"),
        out("+311 -48 across 9 files"),
        "",
        "⏺ Looks good overall. Three things before merging:",
        "",
        f"  1. {B}Retries aren't idempotent.{R} handleInvoicePaid() inserts a",
        "     ledger row on every attempt; key it on the event id.",
        f"  2. {B}Backoff has no ceiling.{R} attempt 12 waits 68 minutes.",
        f"  3. {B}No test for an out-of-order event{R} (paid before created).",
        "",
        *box(cols, f"{D}>{R} "),
    ]


def webhooks(cols, tick):
    return [
        f"{D}> Verify Stripe-style webhook signatures before parsing the body{R}",
        "",
        ok("Update", "src/billing/webhooks.ts"),
        out("Updated src/billing/webhooks.ts with 23 additions and 4 removals"),
        "",
        ok("Bash", "npm test -- --run billing"),
        out(f"Tests  {GRN}34 passed{R} (34)"),
        "",
        "⏺ Done. Signatures are checked against the raw body with a",
        "  5 minute tolerance, and a bad signature returns 400 early.",
        "",
        *box(cols, f"{D}>{R} "),
    ]


def docs(cols, tick):
    return [
        f"{D}>_{R} {B}OpenAI Codex{R} {D}(v0.46.0){R}",
        "",
        f"{D}▌{R} Write the API reference page for the orders endpoints",
        "",
        f"{D}•{R} Added {B}docs/api/orders.md{R} {GRN}(+186){R}",
        "",
        f"{D}•{R} The page covers list, get, create and refund, with a curl",
        "  example and the error codes for each.",
        "",
        f"{D}▌{R} {D}Ask Codex to do anything{R}",
    ]


def promo(cols, tick):
    return [
        f"{D}> Add tests for stacked and expired promo codes in totals.ts{R}",
        "",
        ok("Read", "src/checkout/totals.ts"),
        out("Read 64 lines"),
        "",
        ok("Write", "src/checkout/promo.test.ts"),
        out("Wrote 7 tests to src/checkout/promo.test.ts"),
        more(f"{D}it('ignores an expired code'){R}"),
        more(f"{D}it('applies the larger of two stacked codes'){R}"),
        more(f"{D}it('never discounts below zero'){R}"),
        "",
        ok("Bash", "npm test -- --run promo"),
        out(f"Tests  {GRN}7 passed{R} (7)"),
        "",
        "⏺ All 7 pass. Stacked codes now take the larger",
        "  discount instead of adding up, which matches the",
        "  rule in docs/promotions.md.",
        "",
        *box(cols, f"{D}>{R} "),
    ]


def tests(cols, tick):
    return [
        f" {B}{YEL}RERUN{R} {D}src/checkout/totals.test.ts x3{R}",
        "",
        f" {GRN}✓{R} src/checkout/totals.test.ts {D}(9 tests) 21ms{R}",
        f" {GRN}✓{R} src/checkout/CartSummary.test.tsx {D}(12 tests) 88ms{R}",
        f" {GRN}✓{R} src/checkout/promo.test.ts {D}(7 tests) 14ms{R}",
        f" {GRN}✓{R} src/api/orders.test.ts {D}(31 tests) 204ms{R}",
        "",
        f" {D}Test Files{R}  {B}{GRN}4 passed{R} {D}(4){R}",
        f" {D}     Tests{R}  {B}{GRN}59 passed{R} {D}(59){R}",
        f" {D}  Start at{R}  14:02:31",
        f" {D}  Duration{R}  1.31s",
        "",
        f" {B}{GRN}PASS{R} {GRN}Waiting for file changes...{R}",
        f"       {D}press{R} h {D}to show help, press{R} q {D}to quit{R}",
    ]


def devserver(cols, tick):
    return [
        "",
        f"  {B}{GRN}VITE{R} {GRN}v6.0.3{R}  {D}ready in{R} 412 ms",
        "",
        f"  {GRN}➜{R}  {B}Local{R}:   {CYN}http://localhost:5173/{R}",
        f"  {GRN}➜{R}  {D}Network: use{R} --host {D}to expose{R}",
        "",
        f"{D}14:01:58{R} {CYN}{B}[vite]{R} {GRN}hmr update{R} {D}/src/checkout/CartSummary.tsx{R}",
        f"{D}14:02:30{R} {CYN}{B}[vite]{R} {GRN}hmr update{R} {D}/src/checkout/totals.ts{R}",
        f"{D}14:02:31{R} {CYN}{B}[vite]{R} {GRN}hmr update{R} {D}/src/checkout/CartSummary.tsx{R}",
    ]


def scratch(cols, tick):
    return [
        f"{BLU}~/code/storefront{R} {D}on{R} {MAG}checkout-v2{R}",
        f"{GRN}❯{R} git log --oneline -4",
        f"{YEL}a41c9e2{R} checkout: totals move into totals.ts",
        f"{YEL}7f03b18{R} search: index product variants",
        f"{YEL}e5d2c40{R} auth: shorter access token lifetime",
        f"{YEL}19bb7aa{R} billing: webhook retry queue",
        "",
        f"{BLU}~/code/storefront{R} {D}on{R} {MAG}checkout-v2{R}",
        f"{GRN}❯{R} ",
    ]


SCENES = {
    "checkout-v2": (checkout, True),
    "auth-refresh": (auth, False),
    "product-search": (search, True),
    "pr-218 review": (review, False),
    "billing-webhooks": (webhooks, False),
    "docs-site": (docs, False),
    "promo-tests": (promo, False),
    "tests": (tests, False),
    "shell": (scratch, False),
    "dev server": (devserver, False),
    "scratch": (scratch, False),
}


def scene_name():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if len(sys.argv) == 2 and args:
        return args[0]
    # Started as `claude`/`codex` with Bosun's own arguments: ask tmux which session this is.
    for _ in range(30):
        try:
            name = subprocess.run(["tmux", "display-message", "-p", "#{@bosun_display}"], capture_output=True, text=True, timeout=2).stdout.strip()
        except Exception:
            name = ""
        if name:
            return name
        time.sleep(0.1)
    return "scratch"


def main():
    name = scene_name()
    render, animated = SCENES.get(name, (scratch, False))
    dirty = [True]
    signal.signal(signal.SIGWINCH, lambda *_: dirty.__setitem__(0, True))
    # No cursor except at the shell's prompt: an inactive pane would draw it as an outline mid-screen.
    sys.stdout.write("" if render is scratch else "\033[?25l")
    tick = 0
    while True:
        # The pane title, as the agents set it: a braille spinner while working (Bosun's detectors read it),
        # Claude's ✳ otherwise. It also keeps the pane from being titled with the machine's hostname.
        title = f"{'⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'[tick % 10]} {name}" if animated else f"✳ {name}"
        sys.stdout.write(f"\033]2;{title}\007")
        if dirty[0] or animated:
            cols, rows = shutil.get_terminal_size((80, 24))
            lines = [fit(line, cols) for line in render(cols, tick)][-rows:]
            frame = "\033[H" + "".join(f"{line}\033[K\r\n" for line in lines[:-1]) + (lines[-1] + "\033[K" if lines else "") + "\033[J"
            if dirty[0]:
                frame = "\033[2J" + frame
            sys.stdout.write(frame)
            sys.stdout.flush()
            dirty[0] = False
        tick += 1
        time.sleep(0.12 if animated else 0.5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        signal.pause()
