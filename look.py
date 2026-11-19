#!/usr/bin/env python3
"""Show code in the user's Neovim viewer.

look.py FILE[:START[-END]] [NOTE...]   show a range with an optional note
look.py --tour TITLE < STOPS           ordered stops, one per line: FILE:START[-END] NOTE
look.py --where                        print what the user is looking at
look.py --history                      open the history list (also :LookHistory)
look.py --clear
look.py --listen                       wait for the user's comments to this session (run in the background)
"""
import fcntl
import json
import os
import calendar
import re
import select
import shutil
import subprocess
import sys
import time

SOCK = os.environ.get("LOOK_SOCK", "/tmp/look.sock")
HIST = os.environ.get("LOOK_HISTORY", os.path.expanduser("~/.local/state/look/history.jsonl"))
SESSIONS = os.path.abspath(os.environ.get("LOOK_SESSIONS", os.path.expanduser("~/.local/state/look/sessions")))
LUA = os.path.join(os.path.dirname(os.path.realpath(__file__)), "look.lua")
SPEC = re.compile(r"^(?P<file>.+?)(?::(?P<start>\d+)(?:-(?P<end>\d+))?)?$")


def nvim(*args):
    try:
        return subprocess.run(["nvim", "--server", SOCK, *args], capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        # Calls block while the viewer shows a prompt (hit-enter, swap file)
        sys.exit("viewer is stuck at a prompt - ask the user to check the Neovide window")


def viewer_up():
    return nvim("--remote-expr", "1").returncode == 0


def ensure_viewer(launch=True):
    if viewer_up():
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
        if viewer_up():
            return
        # A crashed viewer leaves its socket file behind and nvim --listen refuses to reuse it
        if os.path.exists(SOCK):
            os.remove(SOCK)
        # -n: a separate Neovide instance, so the user's own Neovide windows are left alone
        subprocess.run(["open", "-n", "-a", "Neovide", "--args", "--", "--listen", SOCK], check=True, timeout=10)
        for _ in range(50):
            if viewer_up():
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


# Sessions --------------------------------------------------------------------
#
# A session's comments queue as files in SESSIONS/<sid>/pending/. The viewer
# writes them; the session's one listener (holding `lock`) prints and deletes
# them. Nothing else is shared: the viewer learns where to write from the tag
# on each look.
#
# sid = <claude pid>-<its start, epoch>-<conversation id>, from what Claude Code
# exports to every command. The start time tells a reused pid apart; the
# conversation id keeps a /clear'd conversation off the previous one's queue.

SID = re.compile(r"^(\d+)-(\d+)-[0-9A-Za-z-]+$")


def lstart(pid):
    """Process start as ps prints it in UTC, so every caller gets the same text."""
    r = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                       env={**os.environ, "LC_ALL": "C", "TZ": "UTC"})
    return r.stdout.strip() or None


def epoch(start):
    return calendar.timegm(time.strptime(start, "%a %b %d %H:%M:%S %Y"))


def session():
    """This conversation: (sid, pid, lstart), or None outside Claude Code."""
    pid, conv = os.environ.get("CLAUDE_PID"), os.environ.get("CLAUDE_CODE_SESSION_ID")
    start = pid and conv and lstart(pid)
    if not start:
        return None
    return f"{pid}-{epoch(start)}-{conv}", int(pid), start


def alive(sid):
    m = SID.match(sid)
    start = m and lstart(m[1])
    return bool(start) and epoch(start) == int(m[2])


def listening(sid):
    with open(os.path.join(SESSIONS, sid, "lock"), "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
        except BlockingIOError:
            return True


def sweep():
    """Remove queues of sessions that ended without a listener running.
    Only names this script creates are touched."""
    for sid in os.listdir(SESSIONS):
        if not SID.match(sid) or alive(sid):
            continue
        d = os.path.join(SESSIONS, sid)
        try:
            with open(os.path.join(d, "lock"), "a") as f:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                shutil.rmtree(d)
        except OSError:
            # Gone already (another listener swept it), or held: skip
            continue


def drain(pending):
    """Print every pending comment, then delete it. Returns how many."""
    names = sorted(n for n in os.listdir(pending) if not n.startswith("."))
    for n in names:
        path = os.path.join(pending, n)
        try:
            # The captured code may hold bytes that are not UTF-8; keep the comment anyway
            with open(path, encoding="utf-8", errors="replace") as f:
                c = json.load(f)
            print(f"look comment on {c['file']}:{c['start']}-{c['end']}:\n{c['text']}\n--- code as shown ---")
            print("\n".join(c["code"]))
            total = c["end"] - c["start"] + 1
            if len(c["code"]) < total:
                print(f"(first {len(c['code'])} of {total} lines)")
            print()
        except (ValueError, KeyError, TypeError):
            print(f"look: skipped unreadable comment {n}")
        # Delete only once the text is out: a listener killed in between repeats
        # the comment rather than losing it
        sys.stdout.flush()
        os.remove(path)
    if names:
        print("Restart look.py --listen in the background, then answer.", flush=True)
    return len(names)


def listen():
    s = session()
    if not s:
        sys.exit("look.py --listen: not running under a Claude Code session")
    sid, pid, _ = s
    d = os.path.join(SESSIONS, sid)
    pending = os.path.join(d, "pending")
    os.makedirs(pending, exist_ok=True)
    lock = open(os.path.join(d, "lock"), "a")
    # listening() probes take the lock for an instant; only a lock held
    # throughout means another listener
    for _ in range(10):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            time.sleep(0.05)
    else:
        print("already listening")
        return
    sweep()
    kq = select.kqueue()
    dfd = os.open(pending, os.O_RDONLY)
    # Watch first, then check: a comment arriving between the two is still seen
    try:
        kq.control([
            select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT),
            select.kevent(dfd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR, select.KQ_NOTE_WRITE),
        ], 0)
        gone = not alive(sid)
    except ProcessLookupError:
        gone = True
    while not gone and not drain(pending):
        gone = any(ev.filter == select.KQ_FILTER_PROC for ev in kq.control(None, 1))
    if gone:
        # The session ended: take no comments nobody will read, and remove its
        # queue (we hold its lock, so no other listener is using it)
        shutil.rmtree(d, ignore_errors=True)
        sys.exit(1)


# Viewer ----------------------------------------------------------------------

def call(args, keys=True):
    # Leave insert/cmdline mode and dismiss any hit-enter prompt so the edit is
    # allowed. Not for --where: it would end the visual selection it reports.
    if keys:
        # Those keys would cancel a comment the user is typing and lose it
        busy = nvim("--remote-expr", "luaeval('_G.Look ~= nil and _G.Look.commenting == true')")
        if "true" in busy.stdout:
            sys.exit("the user is writing a comment in the viewer - try again in a moment")
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


def tag(args):
    """Tag a look with this session so comments on it come back here."""
    s = session()
    if s:
        sid, pid, start = s
        d = os.path.join(SESSIONS, sid)
        os.makedirs(os.path.join(d, "pending"), exist_ok=True)
        args["session"] = {"sid": sid, "pid": pid, "lstart": start, "dir": d, "label": os.path.basename(os.getcwd())}
        if not listening(sid):
            print("no listener for this session: the main conversation runs look.py --listen in the background"
                  " (a subagent tells its caller instead)", file=sys.stderr)
    return args


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
    elif cmd == "--listen":
        listen()
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
        warn(call(tag({"cmd": "tour", "title": " ".join(argv[1:]), "stops": stops})))
    else:
        stop = parse(cmd)
        stop["note"] = " ".join(" ".join(argv[1:]).split())
        ensure_viewer()
        warn(call(tag({"cmd": "show", **stop})))


if __name__ == "__main__":
    main(sys.argv[1:])
