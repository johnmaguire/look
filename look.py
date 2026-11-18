#!/usr/bin/env python3
"""Show code in the user's Neovim viewer.

look.py FILE[:START[-END]] [NOTE...]   show a range with an optional note
look.py --tour TITLE < STOPS           ordered stops, one per line: FILE:START[-END] NOTE
look.py --where                        print what the user is looking at
look.py --history                      open the history list (also :LookHistory)
look.py --clear
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time

SOCK = os.environ.get("LOOK_SOCK", "/tmp/look.sock")
HIST = os.environ.get("LOOK_HISTORY", os.path.expanduser("~/.local/state/look/history.jsonl"))
LUA = os.path.join(os.path.dirname(os.path.realpath(__file__)), "look.lua")
SPEC = re.compile(r"^(?P<file>.+?)(?::(?P<start>\d+)(?:-(?P<end>\d+))?)?$")


def nvim(*args):
    try:
        return subprocess.run(["nvim", "--server", SOCK, *args], capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        # Calls block while the viewer shows a prompt (hit-enter, swap file)
        sys.exit("viewer is stuck at a prompt - ask the user to check the Neovide window")


def alive():
    return nvim("--remote-expr", "1").returncode == 0


def ensure_viewer(launch=True):
    if alive():
        return
    if not launch:
        sys.exit("no viewer running")
    # Sessions racing here would each remove the other's fresh socket; the
    # second one in re-checks after the first has launched
    with open(SOCK + ".lock", "w") as lock:
        for _ in range(100):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(0.1)
        else:
            sys.exit("viewer launch is stuck in another session")
        if alive():
            return
        # A crashed viewer leaves its socket file behind and nvim --listen refuses to reuse it
        if os.path.exists(SOCK):
            os.remove(SOCK)
        # -n: a separate Neovide instance, so the user's own Neovide windows are left alone
        subprocess.run(["open", "-n", "-a", "Neovide", "--args", "--", "--listen", SOCK], check=True, timeout=10)
        for _ in range(50):
            if alive():
                return
            time.sleep(0.1)
    sys.exit("viewer did not start")


def parse(spec):
    m = SPEC.match(spec)
    path = os.path.realpath(m["file"])
    if not os.path.isfile(path):
        sys.exit(f"no such file: {m['file']}")
    stop = {"file": path}
    if m["start"]:
        stop["start"] = int(m["start"])
        stop["end"] = int(m["end"] or m["start"])
        if stop["end"] < stop["start"]:
            sys.exit(f"bad range: {spec}")
    return stop


def call(args, keys=True):
    # Leave insert/cmdline mode and dismiss any hit-enter prompt so the edit is
    # allowed. Not for --where: it would end the visual selection it reports.
    if keys:
        nvim("--remote-send", "<C-\\><C-N>")
    args["src"] = LUA
    args["hist"] = HIST
    ns = os.stat(LUA).st_mtime_ns
    args["mtime"] = f"{ns // 10**9}.{ns % 10**9:09d}"
    # Vim single-quoted string: only ' needs escaping, by doubling
    payload = json.dumps(args).replace("'", "''")
    expr = (
        "luaeval('(function(a) if not _G.Look or _G.Look.mtime ~= a.mtime then dofile(a.src) end "
        f"return _G.Look.run(a) end)(_A)', json_decode('{payload}'))"
    )
    r = nvim("--remote-expr", expr)
    out = (r.stdout + r.stderr).strip()
    if r.returncode != 0 or out.startswith(("E5", "Vim:", "Error")):
        sys.exit(out or "viewer call failed")
    return out


def warn(out):
    if out != "ok":
        print(out, file=sys.stderr)


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.exit(__doc__)
    cmd = argv[0]
    if cmd == "--where":
        ensure_viewer(launch=False)
        print(call({"cmd": "where"}, keys=False))
    elif cmd == "--history":
        ensure_viewer()
        print(call({"cmd": "history"}))
    elif cmd == "--clear":
        ensure_viewer(launch=False)
        print(call({"cmd": cmd[2:]}))
    elif cmd == "--tour":
        if len(argv) < 2:
            sys.exit("usage: look.py --tour TITLE < STOPS")
        stops = []
        for line in sys.stdin:
            if not line.strip():
                continue
            spec, _, note = line.strip().partition(" ")
            stop = parse(spec)
            if "start" not in stop:
                sys.exit(f"tour stop needs a line: {spec}")
            stop["note"] = note.strip()
            stops.append(stop)
        if not stops:
            sys.exit("tour has no stops")
        ensure_viewer()
        warn(call({"cmd": "tour", "title": " ".join(argv[1:]), "stops": stops}))
    else:
        stop = parse(cmd)
        stop["note"] = " ".join(" ".join(argv[1:]).split())
        ensure_viewer()
        warn(call({"cmd": "show", **stop}))


if __name__ == "__main__":
    main(sys.argv[1:])
