#!/usr/bin/env bash
# gpu.sh unresolved_links: a dangling link and a looping link (maps/maps -> maps) are reported, good links and the
# excluded .godot/.git are not. Regression: zombie-zone-maps/maps/maps made rsync --copy-links stop with rc 23 and no hint.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
root=$(mktemp -d)
mkdir -p "$root/p/maps" "$root/p/.godot" "$root/p/sub"
ln -s sub "$root/p/okdir"
ln -s missing "$root/p/dangling"
ln -s "$root/p/maps" "$root/p/maps/maps"
ln -s missing "$root/p/.godot/skipped"
got=$(bash -c 'eval "$(sed -n "/^unresolved_links() {/,/^}/p" "$0")"; unresolved_links "$1"' "$src" "$root/p" | sort)
fail=0
grep -qx 'dangling: ./dangling' <<<"$got" && echo "ok   dangling link listed" || { echo "FAIL dangling link not listed: $got"; fail=1; }
grep -qi 'loop.*maps/maps' <<<"$got" && echo "ok   looping link listed" || { echo "FAIL looping link not listed: $got"; fail=1; }
grep -q 'okdir\|skipped' <<<"$got" && { echo "FAIL good or excluded link listed: $got"; fail=1; } || echo "ok   good and excluded links not listed"
[[ $fail == 0 ]] && echo "all passed" || { echo failed; exit 1; }
rm -rf "$root"
