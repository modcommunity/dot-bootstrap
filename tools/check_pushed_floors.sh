#!/usr/bin/env bash
# A game that was pushed while an addon it needs was only merged locally: a fresh clone then fails to parse
# (game-arena asked for dot_audio 14, DotHurtSound, and GitHub had 13; the editor named only the last script
# of the extends chain). Local links hide it, so this compares what is PUBLISHED on both sides:
#   1. every game's origin/main requires.floor.json against each addon's origin/main <addon>_api.gd LEVEL
#   2. every project whose local main is ahead of origin/main (merged, never pushed)
#
#   tools/check_pushed_floors.sh [--fetch] [--root DIR]     exit 1 on an unpublished floor; (2) is a warning
# --fetch runs `git fetch origin` in each repository first; otherwise the refs are as old as the last fetch.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; sib="$(cd "$here/.." && pwd)"; fetch=0
while [ $# -gt 0 ]; do
    case "$1" in --fetch) fetch=1 ;; --root) sib="$2"; shift ;; esac; shift
done
bad=0; ahead=0; seen=0
for d in "$sib"/*/; do
    d=${d%/}; g=${d##*/}; [ -e "$d/.git" ] || continue
    [ "$fetch" = 1 ] && { git -C "$d" fetch -q origin 2>/dev/null || echo "warn: $g: fetch failed, refs may be old"; }
    git -C "$d" rev-parse -q --verify origin/main >/dev/null 2>&1 || continue
    n=$(git -C "$d" rev-list --count origin/main..main 2>/dev/null || echo 0)
    [ "$n" -gt 0 ] && { echo "unpushed: $g main is $n commit(s) ahead of origin/main"; ahead=$((ahead+1)); }
    floors=$(git -C "$d" show origin/main:requires.floor.json 2>/dev/null) || continue
    while read -r addon want; do
        [ -n "$addon" ] || continue
        r="$sib/${addon//_/-}"; seen=$((seen+1))
        [ -e "$r/.git" ] || { echo "warn: $g needs $addon $want, ${addon//_/-} is not checked out"; continue; }
        have=$(git -C "$r" show "origin/main:addons/$addon/${addon}_api.gd" 2>/dev/null | sed -n 's/^const LEVEL := \([0-9]*\).*/\1/p' | head -1)
        [ -n "$have" ] || { echo "warn: $g needs $addon $want, no published ${addon}_api.gd LEVEL"; continue; }
        if [ "$want" -gt "$have" ]; then
            echo "FAIL $g (origin/main) needs $addon $want, ${addon//_/-} origin/main has $have: push ${addon//_/-}"; bad=$((bad+1))
        fi
    done < <(python3 -I -c 'import json,sys
for k,v in json.load(sys.stdin).get("addons",{}).items(): print(k,int(v))' <<<"$floors" 2>/dev/null)
done
echo "$seen floor(s) checked, $bad unpublished, $ahead project(s) with an unpushed main"
[ "$bad" -eq 0 ]
