#!/usr/bin/env bash
# A renamed addon directory, in bootstrap.sh: fc-weapons holds addons/fc_weapons, its old tags
# (up to v1.4.51) addons/arena_weapons. A game is linked under the directory its .gitignore
# names while the fc-weapons checkout holds it (the legacy one with a deprecation warning
# naming the checkout's ref); a game and a checkout on different sides of the rename fail
# the sync, and nothing is aliased. Local bare remotes only; nothing leaves $T.
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

T="$(mktemp -d)"; trap 'kill $holder 2>/dev/null; rm -rf "$T"' EXIT
holder=
mkdir -p "$T/bs/tools" "$T/remote" "$T/dot-cloud/tools"
cp "$H/bootstrap.sh" "$T/bs/"
cp "$H/tools/install-valve-hooks.sh" "$T/bs/tools/"
cat > "$T/dot-cloud/tools/check_valve_files.py" <<'PY'
# Stand-in for GameSpice Cloud's guard: --install-hook writes a pre-commit hook that names this file.
import os, subprocess, sys
if len(sys.argv) != 3 or sys.argv[1] != "--install-hook": sys.exit(2)
repo = sys.argv[2]
common = subprocess.run(["git", "-C", repo, "rev-parse", "--git-common-dir"], capture_output=True, text=True).stdout.strip()
if not common: sys.exit(1)
common = os.path.join(repo, common)
os.makedirs(os.path.join(common, "hooks"), exist_ok=True)
with open(os.path.join(common, "hooks", "pre-commit"), "w") as f:
    f.write("#!/bin/sh\nexec python3 -I '%s' --git --staged \"$@\"\n" % os.path.abspath(__file__))
PY
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }


mk() { # <repo> <setup in the seed>
    g init -q --bare "$T/remote/$1.git"
    g clone -q "$T/remote/$1.git" "$T/seed-$1" 2>/dev/null
    (cd "$T/seed-$1" && eval "$2")
    g -C "$T/seed-$1" add -A && g -C "$T/seed-$1" commit -q -m one && g -C "$T/seed-$1" push -q origin HEAD:main 2>/dev/null
    git -C "$T/remote/$1.git" symbolic-ref HEAD refs/heads/main
}
run() { # <projects dir> [bootstrap arguments]
    local p="$1"; shift
    (cd "$T" && env GS_PROJECTS="$p" GS_CLOUD="$T/dot-cloud" GS_NATIVES=none GS_STORES_FROM=none NO_COLOR=1 GS_JOBS=1 ./bs/bootstrap.sh "$@" 2>&1)
}
# setup <dir fc-weapons holds> <dir the game names>
setup() {
    rm -rf "$T/remote" "$T"/seed-*; mkdir -p "$T/remote"
    mk fc-weapons "mkdir -p addons/$1 && echo 'extends Node' > addons/$1/w.gd"
    mk game-fc    "printf '/addons/$2\n' > .gitignore && echo '[app]' > project.godot"
    printf 'game-fc\t%s\nfc-weapons\t%s\tarena-weapons\n' "$T/remote/game-fc.git" "$T/remote/fc-weapons.git" > "$T/bs/projects.tsv"
}

# 1. Both on the new name: linked, no warning.
setup fc_weapons fc_weapons; P="$T/p1"
out="$(run "$P")"; rc=$?
check 'new: sync succeeds'                  '[ $rc -eq 0 ]'
check 'new: addons/fc_weapons is linked'    '[ -f "$P/game-fc/addons/fc_weapons/w.gd" ]'
check 'new: no legacy warning'              '! printf "%s" "$out" | grep -q "legacy name"'

# 2. Both still on the legacy name: linked while the checkout holds it, and warned about.
setup arena_weapons arena_weapons; P="$T/p2"
out="$(run "$P")"; rc=$?
check 'legacy: sync succeeds'               '[ $rc -eq 0 ]'
check 'legacy: addons/arena_weapons linked' '[ -f "$P/game-fc/addons/arena_weapons/w.gd" ]'
check 'legacy: deprecation names the dir'   'printf "%s" "$out" | grep -q "addons/arena_weapons is a legacy name (deprecated; fc-weapons at "'

# 3. A game on the legacy name, a checkout on the new one: an error, not an alias.
setup fc_weapons arena_weapons; P="$T/p3"
out="$(run "$P")"; rc=$?
check 'split: sync fails'                   '[ $rc -ne 0 ]'
check 'split: nothing aliased'              '[ ! -e "$P/game-fc/addons/arena_weapons" ] && [ ! -e "$P/game-fc/addons/fc_weapons" ]'
check 'split: says which side is which'     'printf "%s" "$out" | grep -q "asks for addons/arena_weapons, but fc-weapons at .* holds addons/fc_weapons"'

# 4. The other way round.
setup arena_weapons fc_weapons; P="$T/p4"
out="$(run "$P")"; rc=$?
check 'split back: sync fails'              '[ $rc -ne 0 ]'
check 'split back: says which side'         'printf "%s" "$out" | grep -q "asks for addons/fc_weapons, but fc-weapons at .* holds addons/arena_weapons"'

echo "test_renamed_addon_dir_sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
