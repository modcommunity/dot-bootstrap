#!/usr/bin/env python3
"""List projects whose scripts use an addon dot-ci will not clone.

dot-ci clones only `/addons/<name>` lines of .gitignore (or addons.lock). An addon
ignored without the leading slash, or not listed, is missing in CI. Usage: check_ci_addons.py [godot-dir] [--all]
(addon repos are skipped unless --all: their selftests use optional siblings on purpose)
"""
import os, re, sys
ALL = "--all" in sys.argv
args = [a for a in sys.argv[1:] if a != "--all"]
root = os.path.expanduser(args[0] if args else "~/godot")
repos = sorted(d for d in os.listdir(root) if os.path.isdir(f"{root}/{d}/.git"))
# class_name -> addon dir, from every addon source tree
cls = {}
for r in repos:
    ad = f"{root}/{r}/addons"
    if not os.path.isdir(ad): continue
    for a in os.listdir(ad):
        p = f"{ad}/{a}"
        if os.path.islink(p) or not os.path.isdir(p): continue
        for dp, dn, fn in os.walk(p):
            for f in fn:
                if f.endswith(".gd"):
                    try: t = open(f"{dp}/{f}", errors="ignore").read()
                    except OSError: continue
                    for m in re.finditer(r"^class_name\s+(\w+)", t, re.M): cls[m.group(1)] = a
real = set(cls.values())
bad = 0
for r in repos:
    base = f"{root}/{r}"
    if not os.path.exists(f"{base}/project.godot"): continue
    if r.startswith("dot-") and not ALL: continue
    listed = set()
    gi = f"{base}/.gitignore"
    if os.path.exists(gi):
        listed = set(re.findall(r"^/addons/([a-z0-9_]+)$", open(gi).read(), re.M))
    lock = f"{base}/addons.lock"
    if os.path.exists(lock): continue  # resolved from the lock
    own = set(os.listdir(f"{base}/addons")) if os.path.isdir(f"{base}/addons") else set()
    tracked = set()
    used = {}
    guarded = set()
    for dp, dn, fn in os.walk(base):
        dn[:] = [d for d in dn if d not in (".git", ".godot", "addons") and not os.path.islink(f"{dp}/{d}")]
        for f in fn:
            if not f.endswith((".gd", ".tscn", ".tres", ".cfg")): continue
            try: t = open(f"{dp}/{f}", errors="ignore").read()
            except OSError: continue
            if f.endswith(".gd"): t = re.sub(r"(?m)^\s*#.*$|\s#\s.*$", "", t)
            guarded.update(re.findall(r"exists\(\"res://addons/([a-z0-9_]+)/", t))
            t = "\n".join(l for l in t.split("\n") if "exists(" not in l)
            for m in re.finditer(r"res://addons/([a-z0-9_]+)/", t):
                if m.group(1) in real: used.setdefault(m.group(1), f)
            if f.endswith(".gd"):
                for m in re.finditer(r"\b(Dot\w+|[A-Z]\w+)\b", t):
                    a = cls.get(m.group(1))
                    if a: used.setdefault(a, f)
    optional = set(re.findall(r"^addons/([a-z0-9_]+)$", open(gi).read(), re.M)) if os.path.exists(gi) else set()
    for a, f in sorted(used.items()):
        if a in optional:
            print(f"{r}: {a} is ignored without a slash (optional in CI); fine only if its users skip when absent")
            continue
        if a in guarded: continue  # the project tests for it and skips
        if a in listed or a == r.replace("-", "_"): continue
        # own addon of this repo: tracked dir inside addons/
        if os.path.isdir(f"{base}/addons/{a}") and not os.path.islink(f"{base}/addons/{a}"): continue
        bad += 1
        print(f"{r}: uses {a} (e.g. {f}) but .gitignore has no '/addons/{a}' line")
sys.exit(1 if bad else 0)
