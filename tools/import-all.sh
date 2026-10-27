#!/usr/bin/env bash
# Import every game project headless, so the editor never has to do the first import.
# The editor crashes on a first import of some projects; --headless does not.
#   tools/import-all.sh [-j N] <projects dir> <godot> [project ...]
# With no project names, every game-*, mg-* directory (not *-maps) that has a project.godot.
# A project that fails is imported once more (the first pass registers class_name globals).
# -j N imports N projects at once (default: the CPU count); each project is its own Godot process.
set -u
jobs_n="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
[ "${1:-}" = "-j" ] && { jobs_n="${2:?-j needs a number}"; shift 2; }
dir="${1:?projects dir}"; bin="${2:?godot}"; shift 2
if [ $# -gt 0 ]; then names=("$@")
else names=(); for d in "$dir"/game-* "$dir"/mg-*; do case "$d" in *-maps) continue ;; esac; [ -f "$d/project.godot" ] && names+=("$(basename "$d")"); done; fi
cap=(); command -v timeout >/dev/null && cap=(timeout 900)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

import_one() {
    local p="$1"
    [ -f "$dir/$p/project.godot" ] || { echo "skip $p (not a project here)"; return 0; }
    local ok=0 pass
    for pass in 1 2; do
        if ${cap[@]+"${cap[@]}"} "$bin" --headless --path "$dir/$p" --import >"$dir/$p/import-run.txt" 2>&1; then ok=1; break; fi
    done
    if [ $ok = 1 ]; then rm -f "$dir/$p/import-run.txt"; echo "imported  $p"
    else echo "FAILED twice: $p, output in $dir/$p/import-run.txt"; return 1; fi
}

for p in "${names[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$jobs_n" ]; do wait -n 2>/dev/null || true; done
    ( import_one "$p" || : > "$tmp/$p.failed" ) &
done
wait
compgen -G "$tmp/*.failed" >/dev/null && exit 1
exit 0
