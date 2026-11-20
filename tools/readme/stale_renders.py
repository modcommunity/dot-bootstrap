#!/usr/bin/env python3
"""Warn when a README render is older than the newest model or texture file it depicts.

  stale_renders.py [pack_root]      warns on stderr; exits 0 (a stale render is a to-do, not a broken build);
                                    with --strict exits 1 when anything is stale

A render is a docs/img/*.webp or *.png. Age is the git commit time (a checkout sets every mtime to now), falling back
to mtime for untracked files. A render depicts the model and texture files (glb, gltf, obj, fbx, dae, png, jpg, webp,
tga, exr, under any directory except docs/, screenshots/, art-src/ and .godot/) whose path contains the render's item
id: its file name up to the first '_' or '-' suffix word that is not part of an id, tried longest first (hero_thumb ->
hero; zz_m4_bite -> zz_m4). A render with no match is compared with every model and texture in the pack.
gen_readme.py --check calls this, so every pack that checks its README gets the warning.
"""
import os
import subprocess
import sys

MODELS = {".glb", ".gltf", ".obj", ".fbx", ".dae", ".png", ".jpg", ".jpeg", ".webp", ".tga", ".exr"}
SKIP = {"docs", "screenshots", "art-src", ".godot", ".git", "tools", "examples"}


def commit_times(root):
    """{path: unix time of the last commit touching it} for every tracked file, from one git log."""
    out = subprocess.run(["git", "-C", root, "log", "--format=@%ct", "--name-only", "--no-renames"],
                         capture_output=True, text=True).stdout
    times, t = {}, 0
    for line in out.splitlines():
        if line.startswith("@"):
            t = int(line[1:])
        elif line and line not in times:
            times[line] = t
    return times


def age(root, rel, times):
    return times.get(rel) or int(os.path.getmtime(os.path.join(root, rel)))


def candidates(stem):
    parts = stem.replace("-", "_").split("_")
    return ["_".join(parts[:n]) for n in range(len(parts), 0, -1)]


def stale(root):
    """[(render, newest source, source time, render time)] for each stale render."""
    times = commit_times(root)
    renders, sources = [], []
    for dp, dn, fn in os.walk(root):
        rel_dir = os.path.relpath(dp, root)
        top = rel_dir.split(os.sep)[0]
        if top == ".git" or top == ".godot":
            dn[:] = []
            continue
        for f in fn:
            rel = os.path.normpath(os.path.join(rel_dir, f))
            ext = os.path.splitext(f)[1].lower()
            if top == "docs" and rel.startswith(os.path.join("docs", "img")) and ext in (".webp", ".png"):
                renders.append(rel)
            elif ext in MODELS and top not in SKIP:
                sources.append(rel)
    src_age = {s: age(root, s, times) for s in sources}
    found = []
    for r in sorted(renders):
        stem = os.path.splitext(os.path.basename(r))[0]
        match = []
        for c in candidates(stem):
            match = [s for s in sources if c in s.lower().replace("-", "_").replace(os.sep, "/")]
            if match:
                break
        match = match or sources
        if not match:
            continue
        newest = max(match, key=lambda s: src_age[s])
        if src_age[newest] > age(root, r, times):
            found.append((r, newest, src_age[newest], age(root, r, times)))
    return found


def warn(root):
    found = stale(root)
    for r, s, st, rt in found:
        print("stale_renders: WARNING %s is older than %s (%d days); re-shoot it with tools/gen_readme.sh --ids"
              % (r, s, max(0, (st - rt) // 86400)), file=sys.stderr)
    return found


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    res = warn(os.path.abspath(args[0] if args else "."))
    if not res:
        print("stale_renders: no stale README renders")
    sys.exit(1 if res and "--strict" in sys.argv else 0)
