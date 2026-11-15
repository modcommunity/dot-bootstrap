#!/usr/bin/env bash
# gpu.sh unresolved_links: a dangling link and a looping link (maps/maps -> maps) are reported, good links and the
# excluded .godot/.git are not. Regression: zombie-zone-maps/maps/maps made rsync --copy-links stop with rc 23 and no hint.
# It is also run the way gpu.sh runs it, under `set -euo pipefail` inside $(...): 150052f let grep's exit 1 on a clean
# tree abort every caller, and the first version of this test (no set -e, no $(...)) passed anyway (2026-11-14).
# Real code only: the function and both call sites (sync_project, offer_on) are cut out of tools/gpu.sh.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/p/maps" "$root/p/.godot" "$root/p/sub" "$root/clean/sub" "$root/dang" "$root/loop/maps"
ln -s sub "$root/p/okdir"
ln -s missing "$root/p/dangling"
ln -s "$root/p/maps" "$root/p/maps/maps"
ln -s missing "$root/p/.godot/skipped"
ln -s sub "$root/clean/okdir"
ln -s missing "$root/dang/gone"
ln -s "$root/loop/maps" "$root/loop/maps/maps"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

fn=$(sed -n '/^unresolved_links() {/,/^}/p' "$src")
sp=$(sed -n '/^sync_project() {/,/^}/p' "$src")
[[ -n $fn && -n $sp ]] || { echo "FAIL could not cut unresolved_links/sync_project out of $src"; exit 1; }
# The offer_on call site as written: its `local bad; bad=$(unresolved_links ...)` line and the if that reads it.
offer=$(sed -n '/local bad; bad=\$(unresolved_links/,/^\tfi$/p' "$src")
[[ -n $offer ]] || { echo "FAIL could not cut the offer_on call site out of $src"; exit 1; }

# 1. content, plain mode
got=$(bash -c "$fn"'; unresolved_links "$1"' _ "$root/p" | sort)
grep -qx 'dangling: ./dangling' <<<"$got" && ok "dangling link listed" || bad "dangling link not listed: $got"
grep -qi 'loop.*maps/maps' <<<"$got" && ok "looping link listed" || bad "looping link not listed: $got"
grep -q 'okdir\|skipped' <<<"$got" && bad "good or excluded link listed: $got" || ok "good and excluded links not listed"

# 2. the bare function under set -euo pipefail inside $(...): the caller must survive on every tree
for t in clean dang loop; do
	out=$(bash -c 'set -euo pipefail; '"$fn"'; x=$(unresolved_links "$1"); echo "survived:[$x]"' _ "$root/$t" 2>&1); rc=$?
	[[ $rc == 0 && $out == survived:* ]] && ok "set -euo pipefail, $t tree: caller survives" || bad "set -euo pipefail, $t tree: rc=$rc out=$out"
done
[[ $(bash -c 'set -euo pipefail; '"$fn"'; echo "[$(unresolved_links "$1")]"' _ "$root/clean") == "[]" ]] && ok "clean tree reports nothing" || bad "clean tree reported something"

# 3. the real call sites under set -euo pipefail, stubbing everything but the links check
for t in clean dang loop; do
	out=$(ROOTT=$root/$t bash -c 'set -euo pipefail
die() { echo "DIED: $*" >&2; exit 2; }
project_dir() { :; }; proj_name() { echo n; }; proj_src() { echo "$ROOTT"; }
SSHQ=(true); BOX=b; HOST=h; REMOTE_ROOT=r; RSH=true
rsync() { echo RSYNC; }
'"$fn"'
'"$sp"'
sync_project x; echo done' 2>&1); rc=$?
	case $t in
		clean) [[ $rc == 0 && $out == *RSYNC* ]] && ok "sync_project, clean tree: reaches rsync" || bad "sync_project, clean tree: rc=$rc out=$out" ;;
		*) [[ $rc == 2 && $out == *"DIED: "*"dangle or loop"* ]] && ok "sync_project, $t tree: dies with the link message" || bad "sync_project, $t tree: rc=$rc out=$out" ;;
	esac
	out=$(PROJ_DIR=$root/$t bash -c 'set -euo pipefail
copyfail_bump() { :; }; copyfail_count() { echo 1; }; back_to_queue() { echo "QUEUED: $*"; exit 75; }
project=p; BOX=b; set --
'"$fn"'
f() {
'"$offer"'
echo past; }
f' 2>&1); rc=$?
	case $t in
		clean) [[ $rc == 0 && $out == *past* ]] && ok "offer_on check, clean tree: runs on" || bad "offer_on check, clean tree: rc=$rc out=$out" ;;
		*) [[ $rc == 75 && $out == *QUEUED* ]] && ok "offer_on check, $t tree: sent back to the queue" || bad "offer_on check, $t tree: rc=$rc out=$out" ;;
	esac
done
[[ $fail == 0 ]] && echo "all passed" || { echo failed; exit 1; }
