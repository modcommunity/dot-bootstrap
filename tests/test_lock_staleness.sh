#!/usr/bin/env bash
# check_lock_staleness.sh against throwaway repositories under a fresh mktemp directory (left for the system to clear):
# clean pin, behind the newest tag, over the commit limit, limit 0, bad values, unreadable (addon missing, pin unknown).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
mkdir -p "$tmp/root"; root="$tmp/root"
g init -q "$root/dot-thing"; a="$root/dot-thing"
c() { echo "$1" >> "$a/f"; g -C "$a" add -A; g -C "$a" commit -qm "$1"; }
c one; g -C "$a" tag v0.1.0; c two; g -C "$a" tag v0.2.0
printf 'game-x\ngame-y\n' > "$tmp/projects.tsv"
mkgame() { g init -q "$root/$1"; printf 'dot-thing\t%s\n' "$2" > "$root/$1/addons.lock"; g -C "$root/$1" add -A; g -C "$root/$1" commit -qm lock; }
run() { out=$("$here/tools/check_lock_staleness.sh" --root "$root" --projects "$tmp/projects.tsv" "$@" 2>&1); rc=$?; echo "$out"; }
mkgame game-x v0.2.0; printf 'game-x\n' > "$tmp/projects.tsv"
run --fail; ck "clean pin exits 0" '[ $rc -eq 0 ]'; ck "clean summary" 'grep -q "1 pin(s), 0 behind, 0 unreadable" <<<"$out"'
g -C "$root/game-x" rm -q addons.lock; printf 'dot-thing\tv0.1.0\n' > "$root/game-x/addons.lock"; g -C "$root/game-x" add -A; g -C "$root/game-x" commit -qm old
run --fail; ck "behind newest tag exits 1" '[ $rc -eq 1 ]'; ck "names game, addon, pin and tag" 'grep -q "FLAG lock-behind: game-x pins dot-thing v0.1.0, newest tag v0.2.0" <<<"$out"'
run; ck "behind without --fail exits 0" '[ $rc -eq 0 ]'
printf 'dot-thing\tmain\n' > "$root/game-x/addons.lock"; g -C "$root/game-x" commit -qam m
run --fail; ck "pin on main is behind the tag" '[ $rc -eq 1 ]'
# commit distance: pin the newest tag, then add 3 commits to the addon
printf 'dot-thing\tv0.2.0\n' > "$root/game-x/addons.lock"; g -C "$root/game-x" commit -qam new
c three; c four; c five
run --fail --max-behind 2; ck "3 commits behind, limit 2 exits 1" '[ $rc -eq 1 ]'; ck "names the distance" 'grep -q "3 commits behind main (limit 2)" <<<"$out"'
run --fail --max-behind 3; ck "3 commits behind, limit 3 exits 0" '[ $rc -eq 0 ]'
run --fail --max-behind 0; ck "limit 0 disables the distance rule" '[ $rc -eq 0 ]'
run --fail --max-behind -1; ck "negative limit exits 2" '[ $rc -eq 2 ]'
run --fail --max-behind abc; ck "non-numeric limit exits 2" '[ $rc -eq 2 ]'
run --fail --max-behind; ck "missing limit value exits 2" '[ $rc -eq 2 ]'
run --bogus; ck "unknown argument exits 2" '[ $rc -eq 2 ]'
run --projects "$tmp/none.tsv"; ck "no project list exits 2" '[ $rc -eq 2 ]'
run --root "$tmp/none"; ck "no checkout root exits 2" '[ $rc -eq 2 ]'
printf 'dot-gone\tv1.0.0\n' > "$root/game-x/addons.lock"; g -C "$root/game-x" commit -qam gone
run --fail; ck "addon not checked out exits 2" '[ $rc -eq 2 ]'; ck "names the missing addon" 'grep -q "dot-gone is not checked out" <<<"$out"'
printf 'dot-thing\tdeadbeef\n' > "$root/game-x/addons.lock"; g -C "$root/game-x" commit -qam unk
run --fail; ck "unknown pin exits 2" '[ $rc -eq 2 ]'
run --fail --max-behind 0; ck "non-tag pin with limit 0 still trips the tag rule" '[ $rc -eq 1 ]'
echo "$fail failure(s)"; [ "$fail" -eq 0 ]
