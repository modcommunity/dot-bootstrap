#!/usr/bin/env bash
# A renamed repository's checkout, in bootstrap.sh: a sync moves a checkout still under
# an old name (projects.tsv column 3) to the listed name, dirty tree and all, points the
# links that went through the old name at the new one, and leaves the old name as a link.
# It refuses, and clones no second copy, when the folder is in use or DOT_NO_RENAME=1;
# leaves both alone when both names exist; and leaves a foreign checkout under the old
# name alone while cloning the listed one. Local bare remotes only; nothing leaves $T.
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

T="$(mktemp -d)"; trap 'kill $holder 2>/dev/null; rm -rf "$T"' EXIT
holder=
mkdir -p "$T/bs" "$T/remote"
cp "$H/bootstrap.sh" "$T/bs/"
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# Three repositories: a game that still names the old ones in its .gitignore, an addon
# repository and a maps repository, all renamed.
mk() { # <repo> <setup in the seed>
    g init -q --bare "$T/remote/$1.git"
    g clone -q "$T/remote/$1.git" "$T/seed-$1" 2>/dev/null
    (cd "$T/seed-$1" && eval "$2")
    g -C "$T/seed-$1" add -A && g -C "$T/seed-$1" commit -q -m one && g -C "$T/seed-$1" push -q origin HEAD:main 2>/dev/null
    git -C "$T/remote/$1.git" symbolic-ref HEAD refs/heads/main
}
mk fc-weapons 'mkdir -p addons/arena_weapons && echo "extends Node" > addons/arena_weapons/w.gd'
mk new-maps   'mkdir -p maps && echo a > maps/a.txt'
mk game-fc    'printf "/addons/arena_weapons\n# bootstrap-link: old-maps/maps\n/maps/imported\n" > .gitignore && echo "[app]" > project.godot'
mk other      'echo x > x.txt'
printf 'game-fc\t%s\tgame-old\nfc-weapons\t%s\tarena-weapons\nnew-maps\t%s\told-maps\n' \
    "$T/remote/game-fc.git" "$T/remote/fc-weapons.git" "$T/remote/new-maps.git" > "$T/bs/projects.tsv"

# Checkouts made before the rename, under the old names, linked the old way.
old_tree() { # <projects dir>
    mkdir -p "$1"
    g clone -q "$T/remote/game-fc.git" "$1/game-old" 2>/dev/null
    g clone -q "$T/remote/fc-weapons.git" "$1/arena-weapons" 2>/dev/null
    g clone -q "$T/remote/new-maps.git" "$1/old-maps" 2>/dev/null
    mkdir -p "$1/game-old/addons" && ln -s ../../arena-weapons/addons/arena_weapons "$1/game-old/addons/arena_weapons"
    mkdir -p "$1/game-old/maps" && ln -s ../../old-maps/maps "$1/game-old/maps/imported"
}
run() { # <projects dir> <VAR=value or ""> [bootstrap arguments]
    local p="$1" e="$2"; shift 2
    (cd "$T" && env DOT_PROJECTS="$p" DOT_NATIVES=none DOT_STORES_FROM=none NO_COLOR=1 DOT_JOBS=1 $e ./bs/bootstrap.sh "$@" 2>&1)
}

# 1. The move: dirty work kept, links repointed, old names left as links, --check clean.
P="$T/p1"; old_tree "$P"
echo work > "$P/game-old/uncommitted.txt"
out="$(run "$P" "")"; rc=$?
check 'sync succeeds'                       '[ $rc -eq 0 ]'
check 'the game is under its new name'      '[ -d "$P/game-fc/.git" ] && [ ! -L "$P/game-fc" ]'
check 'the addon repository too'            '[ -d "$P/fc-weapons/.git" ] && [ -d "$P/new-maps/.git" ]'
check 'uncommitted work moved with it'      '[ "$(cat "$P/game-fc/uncommitted.txt")" = work ]'
check 'the rename is said, with the dirt'   'printf "%s" "$out" | grep -q "renamed from game-old (with its 1 uncommitted"'
check 'the old name is a link to the new'   '[ "$(readlink "$P/game-old")" = game-fc ] && [ "$(readlink "$P/arena-weapons")" = fc-weapons ]'
check 'the addon link goes through fc-weapons' 'readlink "$P/game-fc/addons/arena_weapons" | grep -q "/fc-weapons/" && [ -f "$P/game-fc/addons/arena_weapons/w.gd" ]'
check 'the content link goes through new-maps' 'readlink "$P/game-fc/maps/imported" | grep -q "/new-maps/" && [ -f "$P/game-fc/maps/imported/a.txt" ]'
check 'no second clone under an old name'   '[ "$(find "$P" -mindepth 2 -maxdepth 2 -name .git | wc -l)" -eq 3 ]'
chk="$(run "$P" "" --check)"; crc=$?
check '--check agrees after the move'       '[ $crc -eq 0 ] && printf "%s" "$chk" | grep -q "agrees with the disk"'
[ $crc -eq 0 ] || printf "%s\n" "$chk" | tail -15
out2="$(run "$P" "")"
check 'a second sync moves nothing'         '! printf "%s" "$out2" | grep -q "renamed from"'

# 2. A process working in the old folder: not moved, and the new name is not cloned.
P="$T/p2"; old_tree "$P"
(cd "$P/arena-weapons" && exec sleep 300) & holder=$!
sleep 0.3
chk="$(run "$P" "" --check)"
check '--check names the old checkout'      'printf "%s" "$chk" | grep -q "checked out under its old name arena-weapons"'
out="$(run "$P" "")"
kill $holder 2>/dev/null; wait $holder 2>/dev/null; holder=
check 'in use: left at the old name'        '[ -d "$P/arena-weapons/.git" ] && [ ! -L "$P/arena-weapons" ]'
check 'in use: no second clone'             '[ ! -e "$P/fc-weapons" ]'
check 'in use: the reason is said'          'printf "%s" "$out" | grep -q "in use by process"'
check 'in use: the addon still links'       '[ -f "$P/game-fc/addons/arena_weapons/w.gd" ]'
check 'the others still moved'              '[ -d "$P/game-fc/.git" ] && [ -d "$P/new-maps/.git" ]'

# 3. DOT_NO_RENAME=1 refuses every move and clones nothing beside them.
P="$T/p3"; old_tree "$P"
out="$(run "$P" DOT_NO_RENAME=1)"
check 'DOT_NO_RENAME: nothing moved'        '[ -d "$P/game-old/.git" ] && [ -d "$P/arena-weapons/.git" ] && [ -d "$P/old-maps/.git" ]'
check 'DOT_NO_RENAME: nothing cloned'       '[ ! -e "$P/game-fc" ] && [ ! -e "$P/fc-weapons" ] && [ ! -e "$P/new-maps" ]'

# 4. Both names already there: neither is touched, and the old one is reported.
P="$T/p4"; old_tree "$P"
g clone -q "$T/remote/fc-weapons.git" "$P/fc-weapons" 2>/dev/null
echo mine > "$P/arena-weapons/mine.txt"
out="$(run "$P" "")"
check 'both: the old checkout is kept'      '[ -f "$P/arena-weapons/mine.txt" ] && [ ! -L "$P/arena-weapons" ]'
check 'both: and reported'                  'printf "%s" "$out" | grep -q "an old checkout is still at arena-weapons"'

# 5. A different repository under an old name is left alone; the listed one is cloned.
P="$T/p5"; mkdir -p "$P"
g clone -q "$T/remote/other.git" "$P/old-maps" 2>/dev/null
out="$(run "$P" "")"
check 'foreign: left alone'                 '[ -f "$P/old-maps/x.txt" ] && [ ! -L "$P/old-maps" ]'
check 'foreign: the listed one is cloned'   '[ -f "$P/new-maps/maps/a.txt" ]'

[ $fail -eq 0 ] || printf '%s\n' "$out" | tail -25
echo "rename dirs: $pass passed, $fail failed"
[ $fail -eq 0 ]
