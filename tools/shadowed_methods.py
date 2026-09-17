#!/usr/bin/env python3
"""Find GDScript methods that silently shadow an engine method.

GDScript accepts a `func` whose name a native class already defines with no warning and
no parse error, and the call then binds to the ENGINE's implementation -- so the code is
present, reachable, called, and inert. It is invisible to every other detector this family
runs: the name occurs more than once, it has callers, and the body reads correctly.

    godot/dot-bootstrap/tools/shadowed_methods.py            # every project
    godot/dot-bootstrap/tools/shadowed_methods.py --self-test # prove it fires first

Why this lives in dot-bootstrap: it is the repository that already owns the family as a
whole -- `projects.tsv` is "the one list" -- and this detector has to read every project
at once to resolve a `class_name` in one repository against an `extends` in another.

Why it is Python and not a grep: the list of names to check for has to come from ClassDB
rather than from memory. `Resource` alone has 76 methods and `reset_state` is not one
anybody would guess, which is exactly how the bug that prompted this survived review.

Exit codes:
    0  nothing shadows an engine method
    1  at least one does
    2  could not ask the engine (no `godot` on PATH, or no project to ask from)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

CLASSNAME = re.compile(r"^class_name\s+([A-Za-z_0-9]+)", re.M)
EXTENDS = re.compile(r"^extends\s+([A-Za-z_0-9\"./]+)", re.M)
FUNC = re.compile(r"^func\s+([a-z_][A-Za-z_0-9]*)\s*\(", re.M)

DUMP = """extends SceneTree

func _init() -> void:
\tvar out := {}
\tfor c in ClassDB.get_class_list():
\t\tvar names: Array = []
\t\tfor m in ClassDB.class_get_method_list(c, true):
\t\t\tnames.append(m["name"])
\t\tout[c] = {"parent": ClassDB.get_parent_class(c), "methods": names}
\tvar f := FileAccess.open("user://classdb.json", FileAccess.WRITE)
\tf.store_string(JSON.stringify(out))
\tf.close()
\tquit()
"""


def classdb(root, godot):
    """Ask the engine for its own method names, from any project in the tree.

    Any project will do: ClassDB is the engine's, not the project's. The first one found
    is used so this keeps working when projects are added or renamed.
    """
    projects = sorted(
        os.path.join(root, d)
        for d in os.listdir(root)
        if os.path.isfile(os.path.join(root, d, "project.godot"))
    )
    if not projects:
        sys.exit("no Godot project under %s to ask ClassDB from" % root)

    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, "dump.gd")
        with open(script, "w") as fh:
            fh.write(DUMP)

        for project in projects:
            try:
                subprocess.run(
                    [godot, "--headless", "--path", project, "--script", script],
                    capture_output=True,
                    timeout=180,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                continue

            name = os.path.basename(project)
            for base in (
                os.path.expanduser("~/.local/share/godot/app_userdata"),
                os.path.expanduser("~/Library/Application Support/Godot/app_userdata"),
                os.path.expanduser("~/AppData/Roaming/Godot/app_userdata"),
            ):
                out = os.path.join(base, name, "classdb.json")
                if os.path.exists(out):
                    with open(out) as fh:
                        data = json.load(fh)
                    os.remove(out)
                    return data

    sys.exit(2)


def scripts(root):
    """Every .gd in the tree, read once.

    Symlinks are NOT followed: `addons/` is a symlink per addon, so following them would
    read every shared addon once per consumer and report each hit a dozen times.
    """
    out = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in (".godot", ".git", "__pycache__")]
        for fn in filenames:
            if not fn.endswith(".gd"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
            except (OSError, UnicodeDecodeError):
                continue
            cn = CLASSNAME.search(text)
            ex = EXTENDS.search(text)
            out[path] = (cn.group(1) if cn else None, ex.group(1) if ex else None, text)
    return out


def find(root, cdb, src):
    by_name = {c: p for p, (c, _, _) in src.items() if c}

    def native_base(name):
        """Walk an `extends` chain down to the native class it ultimately rests on."""
        seen = set()
        while name and name not in cdb:
            if name in seen or name not in by_name:
                return None
            seen.add(name)
            name = src[by_name[name]][1]
        return name

    def native_methods(cls):
        out = set()
        while cls:
            entry = cdb.get(cls)
            if not entry:
                break
            out.update(entry["methods"])
            cls = entry["parent"] or None
        return out

    cache = {}
    hits = []

    for path, (_, ex, text) in src.items():
        if not ex:
            continue
        base = native_base(ex)
        if not base:
            continue
        if base not in cache:
            cache[base] = native_methods(base)
        names = cache[base]

        for m in FUNC.finditer(text):
            name = m.group(1)
            # A leading underscore is the engine's own override mechanism and is the
            # intended way to replace a virtual. Only a PUBLIC name can shadow silently.
            if name.startswith("_") or name not in names:
                continue
            hits.append(
                (
                    os.path.relpath(path, root),
                    text[: m.start()].count("\n") + 1,
                    name,
                    base,
                )
            )

    return sorted(hits)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(here)))
    ap.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="plant a known shadow and check this reports it, then remove it",
    )
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    cdb = classdb(root, args.godot)
    src = scripts(root)

    if args.self_test:
        # docs/detectors.md: "Before trusting a detector, add a known-dead setting to a
        # file and check that it fires." A detector that reports a clean tree and a broken
        # detector are the same output, so this is the only way to tell them apart.
        victim = next(
            (p for p, (_, ex, _) in src.items() if ex == "Resource"), None
        )
        if victim is None:
            sys.exit("no script extending Resource to plant a shadow in")
        planted = dict(src)
        planted[victim] = (
            src[victim][0],
            src[victim][1],
            src[victim][2] + "\n\nfunc reset_state() -> void:\n\tpass\n",
        )
        if not any(h[2] == "reset_state" for h in find(root, cdb, planted)):
            print("SELF-TEST FAILED: a planted Resource.reset_state was not reported")
            return 1
        print("self-test ok: a planted shadow is reported")

    hits = find(root, cdb, src)

    for rel, line, name, base in hits:
        print("%s:%d  func %s()  shadows %s.%s" % (rel, line, name, base, name))

    print(
        "\n%d shadowed method%s over %d scripts"
        % (len(hits), "" if len(hits) == 1 else "s", len(src))
    )
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
