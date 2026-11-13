#!/usr/bin/env bash
# Keeps the shared addon/pack/map checkouts under ~/godot level with origin/main, and reports drift.
#
#   tools/sync_checkouts.sh [--apply] [--board] [--quiet]
#
# Why: every game's addons/ links point at the sibling checkouts here, and gpu.sh/hv stage those same
# working trees to PH and the staging boxes (no box keeps its own clone). Agents push from worktrees
# (`git push origin branch:main`), which never moves this checkout, so it fell behind (dot-player-char
# ran one commit old and a figure suite failed against stale code). Nothing updated them before this.
#
# Default is report only. --apply fast-forwards a checkout (git merge --ff-only origin/main) only when it
# is on main, has a clean tree, has no local commits, is strictly behind, and no live agent holds it on
# the board. Anything else is listed as DRIFT with the reason and never touched. Games (game-*, mg-*) are
# never fast-forwarded: they carry work and are merged by the fleet-merge flow.
# --board posts the DRIFT lines with `nightly agent say` (agent SYNC_AGENT, default checkout-sync, joined
# on demand). It also warns when a checkout lacks the tag a lock pins (addons.lock: "<repo><TAB><tag>"),
# since a game linked to it then runs older code than the pack it is built against.
# Cron: tools/sync_checkouts_cron.sh from christian's crontab (it reads the board, runs this as gamedev, posts drift);
# gamedev has no nightly command, so on its own it can neither see claims nor post.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="${SYNC_ROOT:-$(cd "$here/.." && pwd)}"
apply=0; board=0; quiet=0
for a in "$@"; do case "$a" in --apply) apply=1 ;; --board) board=1 ;; --quiet) quiet=1 ;; *) echo "usage: $0 [--apply] [--board] [--quiet]" >&2; exit 2 ;; esac; done
log=(); fixed=0; drift=0
say() { [ "$quiet" = 1 ] || echo "$*"; }
note_drift() { log+=("$*"); drift=$((drift+1)); echo "DRIFT $*"; }

# Repos a live agent holds: board "holds:" lists inside the LIVE AGENTS section.
held=""
if [ -n "${SYNC_HELD_FILE:-}" ]; then
    held="$(cat "$SYNC_HELD_FILE" 2>/dev/null)"   # written by sync_checkouts_cron.sh: gamedev cannot reach the board
elif command -v nightly >/dev/null 2>&1; then
    held="$(nightly agent board 2>/dev/null | sed '/^STALE CLAIMS/,$d' | grep -o 'godot/[A-Za-z0-9_.-]*' | sed 's|godot/||' | sort -u)"
fi

for d in "$root"/*/; do
    d="${d%/}"; r="$(basename "$d")"; [ -e "$d/.git" ] || continue
    case "$r" in game-*|mg-*) [[ "$r" == *-maps ]] || continue ;; esac
    timeout 60 git -C "$d" fetch -q origin 2>/dev/null || { note_drift "$r: fetch failed"; continue; }
    git -C "$d" rev-parse -q --verify origin/main >/dev/null || continue
    br="$(git -C "$d" branch --show-current)"
    behind="$(git -C "$d" rev-list --count HEAD..origin/main)"; ahead="$(git -C "$d" rev-list --count origin/main..HEAD)"
    dirty="$(git -C "$d" status --porcelain --untracked-files=no | wc -l)"
    [ "$behind" = 0 ] && continue
    why=""
    [ "$br" = main ] || why="on branch '$br'"
    [ "$dirty" = 0 ] || why="${why:+$why, }$dirty modified file(s)"
    [ "$ahead" = 0 ] || why="${why:+$why, }$ahead local commit(s) not on main"
    grep -qx "$r" <<< "$held" && why="${why:+$why, }held on the board"
    if [ -n "$why" ]; then note_drift "$r: $behind behind origin/main, not fast-forwarded ($why)"; continue; fi
    if [ "$apply" = 1 ]; then
        if git -C "$d" merge -q --ff-only origin/main >/dev/null 2>&1; then say "ff $r (+$behind)"; fixed=$((fixed+1)); else note_drift "$r: ff-only failed"; fi
    else note_drift "$r: $behind behind origin/main (clean, would fast-forward; run with --apply)"; fi
done

# Lock check: a checkout must contain the tag its consumer's lock pins.
for lockdir in "$root"/*/; do
    lockdir="${lockdir%/}"; lock="$lockdir/addons.lock"; [ -f "$lock" ] || continue; g="$(basename "$lockdir")"
    while IFS=$'\t' read -r repo tag; do
        case "$repo" in ''|'#'*) continue ;; esac
        [ -e "$root/$repo/.git" ] && [ -n "$tag" ] || continue
        git -C "$root/$repo" rev-parse -q --verify "refs/tags/$tag" >/dev/null || continue
        git -C "$root/$repo" merge-base --is-ancestor "$tag" HEAD 2>/dev/null ||
            note_drift "$g: addons.lock pins $repo $tag but the linked checkout $repo ($(git -C "$root/$repo" rev-parse --short HEAD)) does not contain it"
    done < "$lock"
done

say "$fixed fast-forwarded, $drift drift line(s)"
if [ "$board" = 1 ] && [ "$drift" -gt 0 ] && command -v nightly >/dev/null 2>&1; then
    ag="${SYNC_AGENT:-checkout-sync}"; nightly agent join "$ag" --task "fast-forwards shared checkouts, reports drift" >/dev/null 2>&1
    printf 'checkout drift (tools/sync_checkouts.sh):\n%s\n' "$(printf '%s\n' "${log[@]}")" | nightly agent say "$ag" >/dev/null 2>&1
fi
exit 0
