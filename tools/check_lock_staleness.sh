#!/usr/bin/env bash
# Reports games whose addons.lock pins an addon more than N commits behind its newest tag/main.
#
#   tools/check_lock_staleness.sh [--max-behind N] [--fail]    default N=20, report only
#
# Same version rule as dot-game-template/tools/check-lock.sh (sort -V); distances come from the
# sibling addon checkouts. Never edits a lock: bump with the game's tools/sync-lock.sh.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; sib="$(cd "$here/.." && pwd)"
max=20; fail=0; stale=0
while [ $# -gt 0 ]; do
    case "$1" in --max-behind) max="$2"; shift ;; --fail) fail=1 ;; esac; shift
done
games=${LOCK_GAMES:-$(grep -v "^[[:space:]]*#" "$here/projects.tsv" | cut -f1 | grep -E "^(game|mg)-" | grep -v -- "-maps$")}
for g in $games; do
    [ -d "$sib/$g" ] || { echo "$g: not checked out"; continue; }
    lock="$(git -C "$sib/$g" show HEAD:addons.lock 2>/dev/null)" || { echo "$g: no committed addons.lock"; continue; }
    while IFS=$'\t' read -r repo have; do
        case "$repo" in ''|'#'*) continue ;; esac
        d="$sib/$repo"; [ -d "$d/.git" ] || continue
        newest="$(git -C "$d" tag --list 'v*' | sort -V | tail -1)"
        [ "$(printf '%s\n%s\n' "$have" "${newest:-$have}" | sort -V | head -1)" = "$have" ] && [ "$have" != "$newest" ] || newest=""
        tip="$(git -C "$d" rev-parse -q --verify main 2>/dev/null || git -C "$d" rev-parse HEAD)"
        n="$(git -C "$d" rev-list --count "$have..$tip" 2>/dev/null)" || { echo "$g: $repo pin $have not found"; continue; }
        if [ "$n" -gt "$max" ]; then
            echo "stale: $g pins $repo $have, $n commits behind main${newest:+ (newest tag $newest)}"; stale=$((stale+1))
        fi
    done <<< "$lock"
done
echo "$stale stale pin(s) over $max commits"
[ "$fail" = 1 ] && [ "$stale" -gt 0 ] && exit 1
exit 0
