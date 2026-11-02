#!/usr/bin/env python3
"""Counts this session's builders from their transcripts and prints a line whenever the picture changes.
Usage: agent-watch.py <tasks dir> [want=10] [once] [--include-others]
working = last record is mid-work and not stopped; parked = ended its turn; stale = silent over 45 min; stopped = killed/interrupted (never working).
Only a*.output files in the given tasks dir count; other sessions' tasks dirs are reported as others=N and added only with --include-others."""
import glob, json, os, sys, time

STALE = 2700; OLD = 3 * 3600
STOP_MARKS = ("Exit code 137", "Exit code 143", "Request interrupted", "interrupted by user", "was stopped", "Agent stopped", "killed")


def _text(c):
    if isinstance(c, str): return c
    if isinstance(c, list): return " ".join(_text(x.get("content", x.get("text", "")) if isinstance(x, dict) else x) for x in c)
    return ""


def state(p):
    """end_turn, tool_use (mid-work), stopped, or None when unreadable."""
    try:
        with open(p, "rb") as f:
            f.seek(max(0, os.path.getsize(p) - 60000)); tail = f.read().decode("utf8", "ignore").splitlines()
    except OSError: return None
    for line in reversed(tail):
        try: j = json.loads(line)
        except ValueError: continue
        t = j.get("type")
        if t == "assistant":
            sr = j["message"].get("stop_reason")
            return sr if sr else "tool_use"
        if t == "user":
            m = j.get("message", {}); c = m.get("content")
            txt = _text(c) + " " + str(j.get("toolUseResult", ""))[:200]
            err = isinstance(c, list) and any(isinstance(x, dict) and x.get("is_error") for x in c)
            if "Request interrupted" in txt or (err and any(k in txt for k in STOP_MARKS)): return "stopped"
            return "tool_use"
    return None


def classify(d, now=None):
    """Returns dict of lists of agent ids for one tasks dir."""
    now = now or time.time(); r = {"working": [], "parked": [], "stale": [], "stopped": []}; seen = set()
    for p in sorted(glob.glob(os.path.join(d, "a*.output"))):
        try: age = now - os.path.getmtime(p)
        except OSError: continue
        real = os.path.realpath(p)
        if real in seen or age > OLD: continue
        seen.add(real); s = state(p); n = os.path.basename(p)[:9]
        if s == "stopped": r["stopped"].append(n)
        elif s == "end_turn": r["parked"].append(n)
        elif age > STALE: r["stale"].append(n)
        else: r["working"].append(n)
    return r


def others_working(d, now=None):
    """Working agents in sibling sessions' tasks dirs (other Claude sessions of this user)."""
    base = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(d)))); me = os.path.abspath(d); n = 0
    for o in glob.glob(os.path.join(base, "*", "*", "tasks")):
        if os.path.abspath(o) != me and os.path.isdir(o): n += len(classify(o, now)["working"])
    return n


def report(d, want, include_others=False, now=None):
    r = classify(d, now); o = others_working(d, now); w = len(r["working"]) + (o if include_others else 0)
    l1 = (f"AGENTS working={w} (want {want}) parked={len(r['parked'])} stale={len(r['stale'])} stopped={len(r['stopped'])}"
          + (" -> REFILL " + str(want - w) if w < want else "") + (" STALE: " + " ".join(r["stale"]) if r["stale"] else ""))
    return l1, f"others={o}" + (" (included)" if include_others else " (not counted)")


def main(argv):
    inc = "--include-others" in argv; a = [x for x in argv if x != "--include-others"]
    d = a[0]; want = int(a[1]) if len(a) > 1 else 10; last = None
    while True:
        cur = report(d, want, inc)
        if cur != last: print(cur[0]); print(cur[1], flush=True); last = cur
        if len(a) > 2: break
        time.sleep(90)


if __name__ == "__main__": main(sys.argv[1:])
