#!/usr/bin/env bash
# dot-workbench travels with the games: every game and the template ignores /addons/dot_workbench,
# a plan clones dot-workbench and links it, and a real (local, offline) bootstrap run links it into
# a fresh projects directory. Changes nothing outside a temp directory under ~/.cache.
#
# Clones come from the sibling checkouts through git's insteadOf, so this tests the working trees,
# not what GitHub holds. A game whose .gitignore change is not committed fails the real run.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
sib="$(cd "$here/.." && pwd)"
tmp="$(mktemp -d -p "${XDG_CACHE_HOME:-$HOME/.cache}" wb-smoke.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT
fail=0
bad() { echo "FAIL $*"; fail=1; }

games=$(grep -v '^[[:space:]]*#' "$here/projects.tsv" | cut -f1 | grep -E '^(game|mg)-' | grep -v -- '-maps$')
for g in $games dot-game-template; do
    [ -d "$sib/$g" ] || { bad "$g is not checked out"; continue; }
    grep -qx '/addons/dot_workbench' "$sib/$g/.gitignore" || bad "$g/.gitignore lacks /addons/dot_workbench"
done

mkdir -p "$tmp/empty"
plan="$(DOT_PROJECTS="$tmp/empty" DOT_PLAN_FROM="$sib" "$here/bootstrap.sh" --plan arena 2>&1)"
grep -qx 'clone dot-workbench' <<<"$plan" || bad "plan arena does not clone dot-workbench"
grep -qx 'link game-arena addon dot_workbench' <<<"$plan" || bad "plan arena does not link dot_workbench"

# A real run for dot-workbench itself (small): clone, then its four links.
mkdir -p "$tmp/src" "$tmp/out"
for d in "$sib"/*/; do n="$(basename "$d")"; [ -d "$d/.git" ] && ln -sfn "${d%/}" "$tmp/src/$n.git"; done
export GIT_CONFIG_COUNT=4
for i in 0 1 2 3; do export "GIT_CONFIG_KEY_$i=url.$tmp/src/.insteadOf"; done
export GIT_CONFIG_VALUE_0="git@github.com:modcommunity/" GIT_CONFIG_VALUE_1="git@github.com:zees-games/" \
       GIT_CONFIG_VALUE_2="https://github.com/modcommunity/" GIT_CONFIG_VALUE_3="https://github.com/zees-games/"
DOT_PROJECTS="$tmp/out" "$here/bootstrap.sh" --only workbench >"$tmp/run.log" 2>&1 || { bad "bootstrap --only workbench failed"; tail -5 "$tmp/run.log"; }
for a in dot_core dot_ui dot_menu dot_settings; do
    [ -L "$tmp/out/dot-workbench/addons/$a" ] || bad "dot-workbench did not get $a"
done
[ -f "$tmp/out/dot-workbench/addons/dot_workbench/plugin.cfg" ] || bad "dot-workbench source not cloned with its addon"

[ $fail = 0 ] && echo "ok: dot-workbench is in every game's addon list and bootstrap links it"
exit $fail
