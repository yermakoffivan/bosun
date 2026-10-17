#!/usr/bin/env python3
"""Tiny `bosun serve` protocol client for the dev fixture (docs/protocol.md).

  devctl.py SOCK fixture FAKE_AGENT   create the fixture sessions and sections
  devctl.py SOCK demo DEMO_AGENT CODE create the demo's staged sessions (dev.sh demo), in CODE/<project>
  devctl.py SOCK snapshot             print the snapshot as JSON
  devctl.py SOCK cmd '{"op":...}'     send one command, print its ack
"""
import json
import os
import socket
import struct
import sys
import time


class Conn:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.buf = b""
        self.next_id = 1
        self.send({"t": "hello", "protocol": 1, "client": "bosun-mac-devctl"})
        self.snapshot = self.wait(lambda m: m["t"] == "snapshot")

    def send(self, obj):
        b = json.dumps(obj).encode()
        self.s.sendall(struct.pack(">I", len(b)) + b)

    def recv(self):
        while len(self.buf) < 4 or len(self.buf) < 4 + struct.unpack(">I", self.buf[:4])[0]:
            chunk = self.s.recv(65536)
            if not chunk:
                raise SystemExit("daemon closed the connection")
            self.buf += chunk
        n = struct.unpack(">I", self.buf[:4])[0]
        body, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
        msg = json.loads(body)
        if msg["t"] == "snapshot":
            self.snapshot = msg
        elif msg["t"] == "sidebar" and hasattr(self, "snapshot"):
            self.snapshot["sidebar"] = msg["sidebar"]
        elif msg["t"] == "sessions" and hasattr(self, "snapshot"):
            rows = {s["name"]: s for s in self.snapshot["sessions"]}
            for s in msg.get("upsert", []):
                rows[s["name"]] = s
            for n in msg.get("removed", []):
                rows.pop(n, None)
            self.snapshot["sessions"] = list(rows.values())
        return msg

    def resync(self):
        time.sleep(0.3)
        self.send({"t": "resync"})
        self.wait(lambda m: m["t"] == "snapshot")

    def wait(self, pred, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            m = self.recv()
            if pred(m):
                return m
        raise SystemExit("timed out")

    def cmd(self, op, **kw):
        i = self.next_id
        self.next_id += 1
        self.send({"t": "cmd", "id": i, "op": op, **kw})
        ack = self.wait(lambda m: m["t"] == "ack" and m["id"] == i)
        if not ack["ok"]:
            print(f"{op} failed: {ack.get('error')}", file=sys.stderr)
        return ack


def label(row):
    """A row's fixture name: its first tab's display name (a row's `name` follows its active tab)."""
    return row["tabs"][0].get("display") or row["name"]


def spec(name, args, container=None):
    return {"name": name, "path": "~", "agent": "terminal", "args": args, "options": {},
            "container_id": container, "resume": False, "worktree_branch": None}


def fixture(c, agent):
    # A daemon that just started may not have found the sessions already on the tmux server yet: wait for
    # them, or every one of them would be created a second time ("api 2"…).
    want = int(os.environ.get("BOSUN_FIXTURE_EXISTING", "0"))
    for _ in range(50):
        if len(c.snapshot["sessions"]) >= want:
            break
        c.resync()
    have = {s["display"] for s in c.snapshot["sessions"]}
    plan = [
        ("api", f"python3 {agent} api"),
        ("docs", f"python3 {agent} docs"),
        ("parser", f"python3 {agent} parser"),
        ("ticker", f"python3 {agent} ticker --ticker"),
        ("web", f"python3 {agent} web"),
        ("review-1", f"python3 {agent} review-1"),
        ("review-2", f"python3 {agent} review-2"),
        ("shell", ""),
    ]
    for name, args in plan:
        if name not in have:
            c.cmd("create", spec=spec(name, args))
    # The "web" row gets two more tabs (it opens as three panes side by side in the app): a fake
    # agent and a plain shell.
    c.resync()
    sb = c.snapshot["sidebar"]
    web = next((r for r in sb["ungrouped"] + [m for s in sb["sections"] for m in s["members"]] if label(r) == "web"), None)
    if web:
        for name, args in (("web tests", f"python3 {agent} web-tests"), ("web shell", "")):
            if name not in have:
                c.cmd("create", spec=spec(name, args, container=web["id"]))
    c.resync()
    sections = {s["name"]: s["id"] for s in c.snapshot["sidebar"]["sections"]}
    for name in ("Work", "Reviews"):
        if name not in sections:
            c.cmd("insert_section", name=name)
    c.resync()
    sb = c.snapshot["sidebar"]
    by_name = {}
    for row in sb["ungrouped"] + [m for s in sb["sections"] for m in s["members"]]:
        by_name[label(row)] = row
    def rows(*names):
        return [{"id": by_name[n]["id"], "name": by_name[n]["name"], "active": by_name[n]["active"],
                 "tabs": [{"session": t["session"]} for t in by_name[n]["tabs"]]} for n in names if n in by_name]
    # Make "web tests" and "web shell" tabs of the "web" row (the daemon may not have regrouped them yet).
    for extra_name in ("web tests", "web shell"):
        if "web" in by_name and extra_name in by_name and by_name[extra_name] is not by_name["web"]:
            extra = by_name.pop(extra_name)
            known = {t["session"] for t in by_name["web"]["tabs"]}
            by_name["web"]["tabs"] = by_name["web"]["tabs"] + [t for t in extra["tabs"] if t["session"] not in known]
    placed = {"parser", "ticker", "web", "review-1", "review-2", "shell", "web tests", "web shell"}
    out = {"ungrouped": rows(*[n for n in by_name if n not in placed]), "sections": []}
    for s in sb["sections"]:
        members = rows("parser", "ticker", "web") if s["name"] == "Work" else rows("review-1", "review-2", "shell") if s["name"] == "Reviews" else []
        out["sections"].append({"id": s["id"], "name": s["name"], "collapsed": False, "members": members})
    c.cmd("sidebar_save", sidebar=out)
    c.resync()
    print("fixture ready:", ", ".join(sorted(s["display"] for s in c.snapshot["sessions"])))
    print("sessions:", " ".join(s["name"] for s in c.snapshot["sessions"]))


def demo(c, agent, code):
    """The staged sessions for screenshots: a made-up storefront project, its agents played by demo_agent.py."""
    have = {s["display"] for s in c.snapshot["sessions"]}
    store, platform = os.path.join(code, "storefront"), os.path.join(code, "platform")
    for d in (store, platform):
        os.makedirs(d, exist_ok=True)

    def agent_spec(name, kind, path, container=None):
        s = spec(name, "", container)
        s.update(path=path, agent=kind)
        if kind == "claude":
            s["options"] = {"claude": {"session_mode": "new", "skip_permissions": False, "remote_control": False}}
        return s

    plan = [
        ("checkout-v2", "claude", store), ("auth-refresh", "claude", store), ("product-search", "codex", store),
        ("pr-218 review", "claude", platform), ("billing-webhooks", "claude", platform), ("docs-site", "codex", platform),
    ]
    for name, kind, path in plan:
        if name not in have:
            c.cmd("create", spec=agent_spec(name, kind, path))
    c.resync()
    rows = {label(r): r for r in c.snapshot["sidebar"]["ungrouped"] + [m for s in c.snapshot["sidebar"]["sections"] for m in s["members"]]}
    # checkout-v2 is the row on screen, as four panes: two Claude sessions, a test watcher and a shell.
    if "promo-tests" not in have and "checkout-v2" in rows:
        c.cmd("create", spec=agent_spec("promo-tests", "claude", store, rows["checkout-v2"]["id"]))
    for name in ("tests", "shell"):
        if name not in have and "checkout-v2" in rows:
            c.cmd("create", spec={**spec(name, f"python3 {agent} '{name}'", rows["checkout-v2"]["id"]), "path": store})
    c.resync()
    sections = {s["name"]: s["id"] for s in c.snapshot["sidebar"]["sections"]}
    for name in ("Storefront", "Platform"):
        if name not in sections:
            c.cmd("insert_section", name=name)
    c.resync()
    sb = c.snapshot["sidebar"]
    by_name = {label(r): r for r in sb["ungrouped"] + [m for s in sb["sections"] for m in s["members"]]}
    for extra in ("promo-tests", "tests", "shell"):
        if "checkout-v2" in by_name and extra in by_name and by_name[extra] is not by_name["checkout-v2"]:
            known = {t["session"] for t in by_name["checkout-v2"]["tabs"]}
            by_name["checkout-v2"]["tabs"] += [t for t in by_name.pop(extra)["tabs"] if t["session"] not in known]

    def rows_of(*names):
        return [{"id": by_name[n]["id"], "name": by_name[n]["name"], "active": by_name[n]["tabs"][0]["session"],
                 "tabs": [{"session": t["session"]} for t in by_name[n]["tabs"]]} for n in names if n in by_name]
    members = {"Storefront": ("checkout-v2", "auth-refresh", "product-search"),
               "Platform": ("pr-218 review", "billing-webhooks", "docs-site")}
    out = {"ungrouped": [], "sections": [
        {"id": s["id"], "name": s["name"], "collapsed": False, "members": rows_of(*members.get(s["name"], ()))}
        for s in sb["sections"]]}
    c.cmd("sidebar_save", sidebar=out)
    c.resync()
    print("demo ready:", ", ".join(sorted(s["display"] for s in c.snapshot["sessions"])))
    # The app's layout for that row: the two agents on the left and right, each over a terminal.
    if "checkout-v2" in by_name:
        tabs = {}
        for s in c.snapshot["sessions"]:
            tabs[s["display"]] = s["name"]
        leaf = lambda n: {"leaf": {"_0": tabs[n]}}
        root = {"split": {"axis": "horizontal", "ratio": 0.5,
                          "first": {"split": {"axis": "vertical", "ratio": 0.64, "first": leaf("checkout-v2"), "second": leaf("shell")}},
                          "second": {"split": {"axis": "vertical", "ratio": 0.56, "first": leaf("promo-tests"), "second": leaf("tests")}}}}
        row = by_name["checkout-v2"]["id"]
        layouts = {"version": 2, "current": row, "rows": {row: {"root": root, "active": tabs["checkout-v2"]}}}
        with open(os.path.join(code, "..", "demo-layout.json"), "w") as f:
            json.dump(layouts, f)


def main():
    sock, what = sys.argv[1], sys.argv[2]
    c = Conn(sock)
    if what == "fixture":
        fixture(c, sys.argv[3])
    elif what == "demo":
        demo(c, sys.argv[3], sys.argv[4])
    elif what == "snapshot":
        print(json.dumps(c.snapshot, indent=1))
    elif what == "cmd":
        body = json.loads(sys.argv[3])
        op = body.pop("op")
        print(json.dumps(c.cmd(op, **body)))


if __name__ == "__main__":
    main()
