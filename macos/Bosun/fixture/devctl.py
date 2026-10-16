#!/usr/bin/env python3
"""Tiny `bosun serve` protocol client for the dev fixture (docs/protocol.md).

  devctl.py SOCK fixture FAKE_AGENT   create the fixture sessions and sections
  devctl.py SOCK snapshot             print the snapshot as JSON
  devctl.py SOCK cmd '{"op":...}'     send one command, print its ack
"""
import json
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
    """A row's display name: its first tab's (container names are internal placeholders)."""
    return row["tabs"][0].get("display") or row["name"]


def spec(name, args, container=None):
    return {"name": name, "path": "~", "agent": "terminal", "args": args, "options": {},
            "container_id": container, "resume": False, "worktree_branch": None}


def fixture(c, agent):
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
    # A second tab in the "web" row.
    c.resync()
    sb = c.snapshot["sidebar"]
    web = next((r for r in sb["ungrouped"] + [m for s in sb["sections"] for m in s["members"]] if label(r) == "web"), None)
    if web and "web tests" not in have:
        c.cmd("create", spec=spec("web tests", f"python3 {agent} web-tests", container=web["id"]))
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
    # Make "web tests" a second tab of the "web" row (the daemon may not have regrouped it yet).
    if "web" in by_name and "web tests" in by_name and by_name["web tests"] is not by_name["web"]:
        extra = by_name.pop("web tests")
        by_name["web"]["tabs"] = by_name["web"]["tabs"] + extra["tabs"]
    placed = {"parser", "ticker", "web", "review-1", "review-2", "shell", "web tests"}
    out = {"ungrouped": rows(*[n for n in by_name if n not in placed]), "sections": []}
    for s in sb["sections"]:
        members = rows("parser", "ticker", "web") if s["name"] == "Work" else rows("review-1", "review-2", "shell") if s["name"] == "Reviews" else []
        out["sections"].append({"id": s["id"], "name": s["name"], "collapsed": False, "members": members})
    c.cmd("sidebar_save", sidebar=out)
    c.resync()
    print("fixture ready:", ", ".join(sorted(s["display"] for s in c.snapshot["sessions"])))
    print("sessions:", " ".join(s["name"] for s in c.snapshot["sessions"]))


def main():
    sock, what = sys.argv[1], sys.argv[2]
    c = Conn(sock)
    if what == "fixture":
        fixture(c, sys.argv[3])
    elif what == "snapshot":
        print(json.dumps(c.snapshot, indent=1))
    elif what == "cmd":
        body = json.loads(sys.argv[3])
        op = body.pop("op")
        print(json.dumps(c.cmd(op, **body)))


if __name__ == "__main__":
    main()
