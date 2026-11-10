#!/usr/bin/env bash
# check_pushed_floors.sh against two throwaway repositories: a game whose pushed floor is above the addon's
# pushed level fails and names the addon; pushing the addon clears it; an unpushed main is reported.
# The repositories are made under a fresh mktemp directory, which is left for the system to clear.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
mk() { # name: a bare origin and a checkout of it under $tmp/root
    g init -q --bare "$tmp/origin/$1.git"; g init -q "$tmp/root/$1"; g -C "$tmp/root/$1" remote add origin "$tmp/origin/$1.git"
}
mkdir -p "$tmp/origin" "$tmp/root"; mk dot-thing; mk game-x
a="$tmp/root/dot-thing"; mkdir -p "$a/addons/dot_thing"
echo "const LEVEL := 3" > "$a/addons/dot_thing/dot_thing_api.gd"; g -C "$a" add -A; g -C "$a" commit -qm one; g -C "$a" push -q origin main
echo "const LEVEL := 4" > "$a/addons/dot_thing/dot_thing_api.gd"; g -C "$a" commit -qam two    # merged, not pushed
x="$tmp/root/game-x"; echo '{"format":1,"addons":{"dot_thing":4}}' > "$x/requires.floor.json"
g -C "$x" add -A; g -C "$x" commit -qm floor; g -C "$x" push -q origin main; g -C "$x" fetch -q origin; g -C "$a" fetch -q origin
out=$("$here/tools/check_pushed_floors.sh" --root "$tmp/root" 2>&1); rc=$?; echo "$out"
ck "unpublished floor exits 1" '[ $rc -eq 1 ]'
ck "names game, addon and both levels" 'grep -q "FAIL game-x (origin/main) needs dot_thing 4, dot-thing origin/main has 3" <<<"$out"'
ck "reports the unpushed main" 'grep -q "unpushed: dot-thing main is 1 commit" <<<"$out"'
g -C "$a" push -q origin main
out=$("$here/tools/check_pushed_floors.sh" --root "$tmp/root" 2>&1); rc=$?; echo "$out"
ck "published floor exits 0" '[ $rc -eq 0 ]'
ck "one floor checked, none unpublished" 'grep -q "1 floor(s) checked, 0 unpublished, 0 project" <<<"$out"'
echo "$fail failure(s)"; [ "$fail" -eq 0 ]
