#!/usr/bin/env python3
"""Fixture test for agent-watch.py: python3 -I tools/test_agent_watch.py"""
import importlib.util, json, os, sys, tempfile, time
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("aw", os.path.join(here, "agent-watch.py")); aw = importlib.util.module_from_spec(spec); spec.loader.exec_module(aw)

def asst(sr): return {"type": "assistant", "message": {"stop_reason": sr, "content": []}}
def user(txt="ok", err=False): return {"type": "user", "message": {"content": [{"type": "tool_result", "content": txt, "is_error": err}]}}

def mk(base, sess, name, recs, age=10, link=True):
    tasks = os.path.join(base, "proj", sess, "tasks"); os.makedirs(tasks, exist_ok=True)
    tr = os.path.join(base, "tr", sess); os.makedirs(tr, exist_ok=True)
    f = os.path.join(tr, name + ".jsonl")
    with open(f, "w") as fh: fh.write("\n".join(json.dumps(x) for x in recs) + "\n")
    t = time.time() - age; os.utime(f, (t, t))
    if link: os.symlink(f, os.path.join(tasks, name + ".output"))
    return tasks

fails = 0
def check(label, got, want):
    global fails
    ok = got == want; fails += not ok; print(("ok   " if ok else "FAIL ") + label + ("" if ok else f" got={got} want={want}"))

with tempfile.TemporaryDirectory() as b:
    mk(b, "S1", "aWORKING01", [asst("tool_use")])
    mk(b, "S1", "aWORKING02", [asst("tool_use"), user()])
    mk(b, "S1", "aPARKED001", [user(), asst("end_turn")])
    mk(b, "S1", "aSTALE0001", [asst("tool_use")], age=3000)
    mk(b, "S1", "aKILLED001", [asst("tool_use"), user("Exit code 137", True)])
    mk(b, "S1", "aINTERRUPT", [asst("tool_use"), user("[Request interrupted by user for tool use]")])
    mk(b, "S1", "aANCIENT01", [asst("tool_use")], age=4 * 3600)
    mk(b, "S1", "aNOTLINKED", [asst("tool_use")], link=False)
    # resumed after restart: link in the new session's tasks dir, transcript in the old session dir
    t1 = mk(b, "S1", "aRESUMED01", [asst("tool_use")], link=False)
    os.symlink(os.path.join(b, "tr", "S1", "aRESUMED01.jsonl"), os.path.join(t1, "aRESUMED01.output"))
    mk(b, "S2", "aOTHER0001", [asst("tool_use")]); mk(b, "S2", "aOTHER0002", [asst("tool_use")])
    mk(b, "S2", "aOTHERDEAD", [asst("tool_use"), user("Exit code 137", True)])
    d1 = os.path.join(b, "proj", "S1", "tasks")
    r = aw.classify(d1)
    check("working", sorted(r["working"]), ["aRESUMED01"[:9], "aWORKING01"[:9], "aWORKING02"[:9]])
    check("parked", r["parked"], ["aPARKED001"[:9]])
    check("stale", r["stale"], ["aSTALE0001"[:9]])
    check("stopped", sorted(r["stopped"]), ["aINTERRUPT"[:9], "aKILLED001"[:9]])
    check("others counts working only", aw.others_working(d1), 2)
    l1, l2 = aw.report(d1, 10)
    check("line1 default", l1.startswith("AGENTS working=3 (want 10) parked=1 stale=1 stopped=2 -> REFILL 7"), True)
    check("line2", l2, "others=2 (not counted)")
    l1, l2 = aw.report(d1, 10, True)
    check("include-others", (l1.split()[1], l2), ("working=5", "others=2 (included)"))
print("FAILED" if fails else "PASSED", fails)
sys.exit(1 if fails else 0)
