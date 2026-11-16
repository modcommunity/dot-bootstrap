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
sp=$(sed -n '/^sync_dir_once() {/,/^}/p;/^sync_project() {/,/^}/p' "$src")
[[ -n $fn && -n $sp ]] || { echo "FAIL could not cut unresolved_links/sync_project out of $src"; exit 1; }
# The offer_on call site as written: its `local bad; bad=$(unresolved_links ...)` line and the if that reads it.
offer=$(sed -n '/local loops=() ll$/,/^\tfi$/p' "$src")
fn2=$(sed -n '/^loop_links() {/,/^}/p;/^unresolved_except_loops() {/,/^}/p' "$src")
[[ -n $fn2 ]] || { echo "FAIL could not cut loop_links/unresolved_except_loops out of $src"; exit 1; }
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
rsync() { echo "RSYNC $*"; }
sync_tree() { shift 3; echo "RSYNC sync_tree $*"; }
'"$fn"'
'"$fn2"'
'"$sp"'
sync_project x; echo done' 2>&1); rc=$?
	case $t in
		clean) [[ $rc == 0 && $out == *RSYNC* && $out != *"--exclude /"* ]] && ok "sync_project, clean tree: reaches rsync, nothing excluded" || bad "sync_project, clean tree: rc=$rc out=$out" ;;
		loop) [[ $rc == 0 && $out == *"left out of the copy"* && $out == *"RSYNC "*"--exclude /maps/maps"* && $out == *done* ]] && ok "sync_project, loop tree: loop link excluded with a warning, rsync runs" || bad "sync_project, loop tree: rc=$rc out=$out" ;;
		*) [[ $rc == 2 && $out == *"DIED: "*"dangle or loop"* ]] && ok "sync_project, $t tree: dies with the link message" || bad "sync_project, $t tree: rc=$rc out=$out" ;;
	esac
	out=$(PROJ_DIR=$root/$t bash -c 'set -euo pipefail
copyfail_bump() { :; }; copyfail_count() { echo 1; }; back_to_queue() { echo "QUEUED: $*"; exit 75; }
project=p; BOX=b; set --
'"$fn"'
'"$fn2"'
f() {
ex=()
'"$offer"'
echo past; }
f' 2>&1); rc=$?
	case $t in
		clean) [[ $rc == 0 && $out == *past* ]] && ok "offer_on check, clean tree: runs on" || bad "offer_on check, clean tree: rc=$rc out=$out" ;;
		loop) [[ $rc == 0 && $out == *past* && $out == *"left out of the copy"* && $out != *QUEUED* ]] && ok "offer_on check, loop tree: the loop link is left out, the job runs on" || bad "offer_on check, loop tree: rc=$rc out=$out" ;;
		*) [[ $rc == 75 && $out == *QUEUED* ]] && ok "offer_on check, $t tree: sent back to the queue" || bad "offer_on check, $t tree: rc=$rc out=$out" ;;
	esac
done
# 4. the dot-sql case: games/addons/dot_sql -> the dot-sql repo's addons/dot_sql, which holds dot_sql -> itself. The loop
# lives inside the other link's target, so only find -L reaches it. It is found, excluded, and rsync (--copy-links, the
# gpu.sh options) then copies the rest and not the loop; a second tree has a loop AND a dangling link, which still queues.
mkdir -p "$root/dot-sql/addons/dot_sql/core" "$root/game/addons" "$root/game2/addons"
: > "$root/dot-sql/addons/dot_sql/core/a.gd"
ln -s "$root/dot-sql/addons/dot_sql" "$root/dot-sql/addons/dot_sql/dot_sql"
ln -s "$root/dot-sql/addons/dot_sql" "$root/game/addons/dot_sql"
ln -s "$root/dot-sql/addons/dot_sql" "$root/game2/addons/dot_sql"; ln -s missing "$root/game2/gone"
got=$(bash -c "$fn"'; '"$fn2"'; loop_links "$1"' _ "$root/game")
[[ $got == addons/dot_sql/dot_sql ]] && ok "loop_links finds the loop inside a linked addon" || bad "loop_links: [$got]"
[[ -z $(bash -c "$fn"'; '"$fn2"'; loop_links "$1"' _ "$root/clean") ]] && ok "loop_links on a clean tree: nothing" || bad "loop_links on a clean tree found something"
rest=$(bash -c 'set -euo pipefail; '"$fn"'; '"$fn2"'; unresolved_except_loops "$1" addons/dot_sql/dot_sql' _ "$root/game")
[[ -z $rest ]] && ok "the loop is not reported as unresolved once excluded" || bad "still reported: $rest"
rest2=$(bash -c 'set -euo pipefail; '"$fn"'; '"$fn2"'; unresolved_except_loops "$1" addons/dot_sql/dot_sql' _ "$root/game2")
[[ $rest2 == "dangling: ./gone" ]] && ok "a dangling link next to a loop is still reported" || bad "dangling not reported: [$rest2]"
if command -v rsync >/dev/null; then
	rsync -a --copy-links --exclude /addons/dot_sql/dot_sql "$root/game/" "$root/out/" 2>"$root/rs.err"; rc=$?
	[[ $rc == 0 && -f $root/out/addons/dot_sql/core/a.gd && ! -e $root/out/addons/dot_sql/dot_sql ]] && ok "rsync --copy-links with the exclude copies the addon and not the loop" || bad "rsync rc=$rc: $(head -3 "$root/rs.err")"
fi
# 5. a link chain that never resolves: A -> B -> A, and a ring of three. find -L calls these "Too many levels of symbolic
# links", not a directory loop, so neither the loop list nor the report had them: rsync --copy-links stopped with rc 23.
mkdir -p "$root/pp" "$root/ring" "$root/pp-dang" "$root/rs-raw" "$root/rs-pp" "$root/rs-ring"
: > "$root/pp/ok.gd"; : > "$root/ring/ok.gd"; : > "$root/pp-dang/ok.gd"
ln -s B "$root/pp/A"; ln -s A "$root/pp/B"
ln -s B "$root/ring/A"; ln -s C "$root/ring/B"; ln -s A "$root/ring/C"
ln -s B "$root/pp-dang/A"; ln -s A "$root/pp-dang/B"; ln -s missing "$root/pp-dang/gone"
got=$(timeout 20 bash -c "$fn2"'; loop_links "$1"' _ "$root/pp" | sort | tr '\n' ' ')
[[ $got == "A B " ]] && ok "loop_links finds the two-link chain" || bad "loop_links, two-link chain: [$got]"
got=$(timeout 20 bash -c "$fn2"'; loop_links "$1"' _ "$root/ring" | sort | tr '\n' ' ')
[[ $got == "A B C " ]] && ok "loop_links finds the three-link ring" || bad "loop_links, three-link ring: [$got]"
bad2=$(timeout 20 bash -c 'set -euo pipefail; '"$fn"'; '"$fn2"'; unresolved_except_loops "$1" A B' _ "$root/pp-dang")
[[ $bad2 == "dangling: ./gone" ]] && ok "a dangling link next to a chain is still reported" || bad "dangling next to chain: [$bad2]"
if command -v rsync >/dev/null; then
	timeout 30 rsync -a --copy-links "$root/pp/" "$root/rs-raw/" 2>/dev/null; rc=$?
	[[ $rc == 23 ]] && ok "fixture: rsync --copy-links without the exclusion stops with rc 23" || bad "fixture: rsync rc=$rc without the exclusion"
	timeout 30 rsync -a --copy-links --exclude /A --exclude /B "$root/pp/" "$root/rs-pp/" 2>"$root/rs.err"; rc=$?
	[[ $rc == 0 && -f $root/rs-pp/ok.gd && ! -e $root/rs-pp/A ]] && ok "rsync with the two-link chain excluded copies the rest, rc 0" || bad "rsync two-link chain excluded: rc=$rc $(head -2 "$root/rs.err")"
	timeout 30 rsync -a --copy-links --exclude /A --exclude /B --exclude /C "$root/ring/" "$root/rs-ring/" 2>"$root/rs.err"; rc=$?
	[[ $rc == 0 && -f $root/rs-ring/ok.gd ]] && ok "rsync with the three-link ring excluded copies the rest, rc 0" || bad "rsync ring excluded: rc=$rc $(head -2 "$root/rs.err")"
fi
for t in pp ring; do
	out=$(ROOTT=$root/$t timeout 60 bash -c 'set -euo pipefail
die() { echo "DIED: $*" >&2; exit 2; }
project_dir() { :; }; proj_name() { echo n; }; proj_src() { echo "$ROOTT"; }
SSHQ=(true); BOX=b; HOST=h; REMOTE_ROOT=r; RSH=true
rsync() { echo "RSYNC $*"; }
sync_tree() { shift 3; echo "RSYNC sync_tree $*"; }
'"$fn"'
'"$fn2"'
'"$sp"'
sync_project x; echo done' 2>&1); rc=$?
	[[ $rc == 0 && $out == *"left out of the copy"* && $out == *"--exclude /A"* && $out == *done* ]] && ok "sync_project, $t chain: left out with a warning, the copy goes on" || bad "sync_project, $t chain: rc=$rc out=$out"
	out=$(PROJ_DIR=$root/$t timeout 60 bash -c 'set -euo pipefail
copyfail_bump() { :; }; copyfail_count() { echo 1; }; back_to_queue() { echo "QUEUED: $*"; exit 75; }
project=p; BOX=b; set --
'"$fn"'
'"$fn2"'
f() {
ex=()
'"$offer"'
echo past; }
f' 2>&1); rc=$?
	[[ $rc == 0 && $out == *past* && $out == *"left out of the copy"* && $out != *QUEUED* ]] && ok "offer_on check, $t chain: left out, the job runs on" || bad "offer_on check, $t chain: rc=$rc out=$out"
done
[[ $fail == 0 ]] && echo "all passed" || { echo failed; exit 1; }
