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
# Stale state is saved, never destroyed: a local tag whose commit differs from origin's (a tag moved after it was
# pulled; plain `git fetch` keeps the old one) is re-pointed to origin's after the old target is kept under
# refs/salvage/tags/<tag>-<sha>. A checkout whose only local commits are already on origin/main (git cherry: all "-")
# and whose only local edits are file-mode flips is reset to origin/main after those commits are kept on branch
# salvage/<date>-<sha>. Local commits with new content, or content edits, are reported with the salvage branch
# already created and the exact reset command, but not reset: someone has to judge them.
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
savedmsg=''; log=(); fixed=0; drift=0
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
    # Tags: origin's wins. Only under --apply; the old target stays reachable under refs/salvage/tags/.
    git -C "$d" ls-remote --tags origin 2>/dev/null | grep -v '\^{}$' | while read -r sha ref; do
        t="${ref#refs/tags/}"; cur="$(git -C "$d" rev-parse -q --verify "refs/tags/$t" 2>/dev/null)" || continue
        [ "$cur" = "$sha" ] && continue
        echo "$t $cur $sha"
    done > "${TMPDIR:-/tmp}/sync.tags.$$"
    while read -r t cur sha; do
        [ -n "$t" ] || continue
        if [ "$apply" = 1 ] && git -C "$d" update-ref "refs/salvage/tags/$t-${cur:0:9}" "$cur" &&
           git -C "$d" fetch -q --force origin "refs/tags/$t:refs/tags/$t" 2>/dev/null; then
            say "retag $r $t ${cur:0:9} -> ${sha:0:9} (old kept at refs/salvage/tags/$t-${cur:0:9})"
        else note_drift "$r: local tag $t is ${cur:0:9} but origin has ${sha:0:9} (run with --apply)"; fi
    done < "${TMPDIR:-/tmp}/sync.tags.$$"; rm -f "${TMPDIR:-/tmp}/sync.tags.$$"
    savedmsg=""
    br="$(git -C "$d" branch --show-current)"
    behind="$(git -C "$d" rev-list --count HEAD..origin/main)"; ahead="$(git -C "$d" rev-list --count origin/main..HEAD)"
    dirty="$(git -C "$d" -c core.fileMode=false status --porcelain --untracked-files=no | wc -l)"
    modeonly="$(git -C "$d" status --porcelain --untracked-files=no | wc -l)"
    [ "$behind" = 0 ] && continue
    # Stale local state on main: only commits origin already has (or none) plus mode-only edits is safe to drop.
    if [ "$br" = main ] && [ "$dirty" = 0 ] && ! grep -qx "$r" <<< "$held" &&
       { [ "$ahead" = 0 ] || [ -z "$(git -C "$d" cherry origin/main HEAD | grep '^+')" ]; } &&
       { [ "$ahead" != 0 ] || [ "$modeonly" != 0 ]; }; then
        if [ "$apply" = 1 ]; then
            [ "$ahead" = 0 ] || git -C "$d" branch -f "salvage/$(date +%Y%m%d)-$(git -C "$d" rev-parse --short HEAD)" HEAD
            if git -C "$d" reset -q --hard origin/main; then say "reset $r to origin/main (+$behind; $ahead local commit(s) were already upstream, kept on a salvage branch)"; fixed=$((fixed+1)); else note_drift "$r: reset failed"; fi
        else note_drift "$r: $behind behind origin/main, local state is stale (already upstream or mode-only); run with --apply"; fi
        continue
    fi
    if [ "$br" = main ] && [ "$ahead" != 0 ]; then   # content not upstream: keep it findable, do not reset
        sv="salvage/$(date +%Y%m%d)-$(git -C "$d" rev-parse --short HEAD)"
        [ "$apply" = 1 ] && git -C "$d" branch -f "$sv" HEAD 2>/dev/null
        savedmsg=" saved as $sv; after review: git reset --hard origin/main"
    fi
    why=""
    [ "$br" = main ] || why="on branch '$br'"
    [ "$dirty" = 0 ] || why="${why:+$why, }$dirty modified file(s)"
    [ "$ahead" = 0 ] || why="${why:+$why, }$ahead local commit(s) not on main"
    grep -qx "$r" <<< "$held" && why="${why:+$why, }held on the board"
    if [ -n "$why" ]; then note_drift "$r: $behind behind origin/main, not fast-forwarded ($why)${savedmsg:-}"; continue; fi
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
