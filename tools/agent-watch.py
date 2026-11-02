#!/usr/bin/env python3
"""Counts this session's builders from their transcripts and prints a line whenever the picture changes.
working = last record is not an end_turn (mid-work); parked = ended its turn but may wait on its own job; stale = silent over 45 min."""
import glob, json, os, sys, time
d = sys.argv[1]; want = int(sys.argv[2]) if len(sys.argv) > 2 else 10; last = None
def state(p):
    try:
        with open(p, "rb") as f:
            f.seek(max(0, os.path.getsize(p) - 60000)); tail = f.read().decode("utf8", "ignore").splitlines()
    except OSError: return None
    stop = None
    for line in reversed(tail):
        try: j = json.loads(line)
        except ValueError: continue
        if j.get("type") == "assistant": stop = j["message"].get("stop_reason"); break
        if j.get("type") == "user": stop = "tool_use"; break
    return stop
while True:
    now = time.time(); w = []; parked = []; stale = []
    for p in glob.glob(d + "/a*.output"):
        age = now - os.path.getmtime(p)
        if age > 3 * 3600: continue
        s = state(p); n = os.path.basename(p)[:9]
        if s != "end_turn": (stale if age > 2700 else w).append(n)
        else: parked.append(n)
    cur = f"AGENTS working={len(w)} (want {want}) parked={len(parked)} stale={len(stale)}" + (" -> REFILL " + str(want - len(w)) if len(w) < want else "") + (" STALE: " + " ".join(stale) if stale else "")
    if cur != last: print(cur, flush=True); last = cur
    if len(sys.argv) > 3: break
    time.sleep(90)
