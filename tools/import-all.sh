#!/usr/bin/env bash
# Import every game project headless, so the editor never has to do the first import.
# The editor crashes on a first import of some projects; --headless does not.
#   tools/import-all.sh <projects dir> <godot> [project ...]
# With no project names, every game-*, mg-* directory (not *-maps) that has a project.godot.
# A project that fails is imported once more (the first pass registers class_name globals).
set -u
dir="${1:?projects dir}"; bin="${2:?godot}"; shift 2
if [ $# -gt 0 ]; then names=("$@")
else names=(); for d in "$dir"/game-* "$dir"/mg-*; do case "$d" in *-maps) continue ;; esac; [ -f "$d/project.godot" ] && names+=("$(basename "$d")"); done; fi
cap=(); command -v timeout >/dev/null && cap=(timeout 900)
bad=0
for p in "${names[@]}"; do
    [ -f "$dir/$p/project.godot" ] || { echo "skip $p (not a project here)"; continue; }
    echo "importing $p"
    ok=0
    for pass in 1 2; do
        if ${cap[@]+"${cap[@]}"} "$bin" --headless --path "$dir/$p" --import >"$dir/$p/import-run.txt" 2>&1; then ok=1; break; fi
    done
    if [ $ok = 1 ]; then rm -f "$dir/$p/import-run.txt"; else echo "  FAILED twice, output in $dir/$p/import-run.txt"; bad=1; fi
done
exit $bad
