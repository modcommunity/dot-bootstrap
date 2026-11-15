#!/usr/bin/env bash
# Flags a game whose addons.lock pin of an addon is stale: behind the addon's newest v* tag, OR more than N
# commits behind the addon's main. This is the one implementation of the rule (nightly's chk-lock-staleness.sh calls it).
#
#   tools/check_lock_staleness.sh [--max-behind N] [--fail] [--root DIR] [--projects FILE]
#     --max-behind N   commit-distance limit, default 20; 0 disables the distance rule (the tag rule stays on).
#                      N must be a non-negative integer, anything else is an error (exit 2), never clamped.
#     --fail           exit 1 when a pin is stale (default: report only, exit 0)
#     --root DIR       directory holding the game and addon checkouts (default: the parent of this repo)
#     --projects FILE  tab-separated project list, first column the repo name (default: this repo's projects.tsv)
#   env: LOCK_GAMES overrides the game list (space separated).
# Default list: game-*, mg-*, dot-game-template, dot-server-deploy (not *-maps).
# Tag rule: a pin below the newest v* tag of the addon checkout (sort -V, as dot-game-template tools/check-lock.sh,
# copied on purpose: the template is copied by third parties) or a pin that is not a v* tag (main, a branch) is
# behind. A pin ahead of the local tags is a stale checkout, not a stale pin. Tags are as new as the last fetch.
# Output: a "FLAG lock-behind: ..." line per stale pin, "FLAG lock-unreadable: ..." per unreadable one, "skip:" notes.
# Exit 0 nothing flagged (or flagged without --fail), 1 stale pin and --fail, 2 unreadable (bad option or value, no
# project list, no checkout root, a pinned addon not checked out, a pin the addon does not contain). With --fail a stale pin
# wins over unreadable (1 before 2), as nightly's check always did.
# Never edits a lock: bump with the game's tools/sync-lock.sh.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root=""; tsv="$here/projects.tsv"; max=20; fail=0
die() { echo "FLAG lock-unreadable: $*"; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --max-behind) [ $# -ge 2 ] || die "--max-behind needs a value"; max="$2"; shift ;;
        --fail) fail=1 ;;
        --root) [ $# -ge 2 ] || die "--root needs a value"; root="$2"; shift ;;
        --projects) [ $# -ge 2 ] || die "--projects needs a value"; tsv="$2"; shift ;;
        *) die "unknown argument '$1'" ;;
    esac; shift
done
case "$max" in ''|*[!0-9]*) die "--max-behind '$max' is not a non-negative integer" ;; esac
max=$((10#$max))
[ -n "$root" ] || root="$(cd "$here/.." && pwd)"
[ -d "$root" ] || die "no checkout directory '$root'"
if [ -n "${LOCK_GAMES:-}" ]; then games=$LOCK_GAMES
else
    [ -r "$tsv" ] || die "no project list '$tsv'"
    games=$(grep -v "^[[:space:]]*#" "$tsv" | cut -f1 | grep -E "^((game|mg)-|dot-game-template$|dot-server-deploy$)" | grep -v -- "-maps$")
fi
stale=0; unreadable=0; locked=0; pins=0
for g in $games; do
    gd="$root/$g"
    [ -e "$gd/.git" ] || { echo "skip: $g is not checked out"; continue; }
    ref=origin/main; git -C "$gd" rev-parse -q --verify "$ref" >/dev/null 2>&1 || ref=HEAD
    lock="$(git -C "$gd" show "$ref:addons.lock" 2>/dev/null)" || { echo "skip: $g commits no addons.lock"; continue; }
    locked=$((locked+1))
    while IFS=$'\t' read -r repo have; do
        case "$repo" in ''|'#'*) continue ;; esac
        [ -n "$have" ] || continue
        pins=$((pins+1))
        d="$root/$repo"
        if [ ! -e "$d/.git" ]; then
            echo "FLAG lock-unreadable: $g pins $repo $have, $repo is not checked out"; unreadable=$((unreadable+1)); continue
        fi
        why=""
        newest="$(git -C "$d" tag --list 'v*' | sort -V | tail -1)"
        if [ -n "$newest" ] && [ "$have" != "$newest" ]; then
            case "$have" in
                v*) [ "$(printf '%s\n%s\n' "$have" "$newest" | sort -V | head -1)" = "$have" ] && why="newest tag $newest" ;;
                *)  why="newest tag $newest" ;;
            esac
        fi
        if [ "$max" -gt 0 ]; then
            tip="$(git -C "$d" rev-parse -q --verify origin/main 2>/dev/null || git -C "$d" rev-parse -q --verify main 2>/dev/null || git -C "$d" rev-parse HEAD)"
            n="$(git -C "$d" rev-list --count "$have..$tip" 2>/dev/null)" || { echo "FLAG lock-unreadable: $g pins $repo $have, not found in $repo"; unreadable=$((unreadable+1)); continue; }
            [ "$n" -gt "$max" ] && why="${why:+$why, }$n commits behind main (limit $max)"
        fi
        [ -n "$why" ] || continue
        echo "FLAG lock-behind: $g pins $repo $have, $why"; stale=$((stale+1))
    done <<< "$lock"
done
echo "summary: $locked game lock(s), $pins pin(s), $stale behind, $unreadable unreadable (max-behind $max)"
[ "$fail" = 1 ] && [ "$stale" -gt 0 ] && exit 1
[ "$unreadable" -gt 0 ] && exit 2
exit 0
