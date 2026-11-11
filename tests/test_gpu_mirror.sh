#!/usr/bin/env bash
# gpu.sh py --mirror: mirror_units finds the directories a scratch script names by absolute path (no box needed).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
d=$(mktemp -d); mkdir -p "$d/wt/w1/sub" "$d/godot/g1" "$d/tmpx/a"
fail=0
cat > "$d/s.sh" <<X
cat $d/tmpx/a/f.txt $d/wt/w1/sub/x $d/godot/g1/y
ls $d/wt $d/godot $d/nonexistent/z
X
got=$(WT_ROOT=$d/wt ROOT=$d/godot HOME=$d/h bash -c '
	eval "$(sed -n "/^mirror_units() {/,/^}/p" "$0")"
	mirror_units "$1"' "$src" "$d/s.sh" | sort | tr '\n' ' ')
want="$d/godot/g1 $d/wt/w1 "
# $d is under /tmp, so the /tmp unit is $d itself when it is not under WT_ROOT/ROOT; the two roots map one level deeper.
if [[ $got == *"$d/godot/g1"* && $got == *"$d/wt/w1"* && $got != *"$d/wt "* && $got != *nonexistent* ]]; then echo "ok   mirror_units: $got"; else echo "FAIL mirror_units: got '$got'"; fail=$((fail+1)); fi
rm -rf "$d"
[[ $fail == 0 ]] && echo "all passed" || { echo "$fail failed"; exit 1; }
