#!/usr/bin/env bash
# bootstrap.ps1's and bootstrap.sh's update of an existing checkout never ends in "resolve by hand": a
# network failure is retried and reported as one (exit 0, listed under "not updated"), and
# a checkout that diverged, lost or never had its upstream, or sits on a detached HEAD or a
# local-only branch is moved onto origin with every local commit kept on a branch and
# uncommitted edits stashed and re-applied. Local bare repositories stand in for GitHub;
# a refused port on 127.0.0.1 stands in for the network. The same scenario runs against
# bootstrap.sh and, when pwsh exists, bootstrap.ps1.
# Run: tests/test_pull_repair.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T0="$(mktemp -d)"; trap 'rm -rf "$T0"' EXIT
pass=0; fail=0
# The sync installs the Valve-origin hook, which needs the dot-cloud guard (set DOT_CLOUD; default: sibling checkout).
DOT_CLOUD="${DOT_CLOUD:-$H/../dot-cloud}"
[ -f "$DOT_CLOUD/tools/check_valve_files.py" ] || { echo "FAIL: no dot-cloud guard at $DOT_CLOUD (set DOT_CLOUD)" >&2; exit 2; }
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: [$impl] $1"; fi; }
g() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

scenario() {
    local impl="$1"; T="$T0/$impl"; mkdir -p "$T"
    # The script reads projects.tsv beside itself: a copy with its own list.
    mkdir -p "$T/bs/tools" "$T/o" "$T/p"
    cp "$H/bootstrap.ps1" "$H/bootstrap.sh" "$T/bs/"; cp "$H"/tools/*.ps1 "$H/tools/install-valve-hooks.sh" "$T/bs/tools/"
    names="behind diverged divdirty noupstream detached localbranch netfail"
    : > "$T/bs/projects.tsv"
    for n in $names; do
        git init -q --bare -b main "$T/o/$n.git"
        git clone -q "$T/o/$n.git" "$T/seed-$n" 2>/dev/null
        echo one > "$T/seed-$n/a.txt"; echo keep > "$T/seed-$n/b.txt"
        g "$T/seed-$n" add -A; g "$T/seed-$n" commit -qm one; g "$T/seed-$n" push -q origin main
        git clone -q "$T/o/$n.git" "$T/p/$n"
        echo two > "$T/seed-$n/a.txt"; g "$T/seed-$n" commit -qam two; g "$T/seed-$n" push -q origin main
        url="$T/o/$n.git"; [ "$n" = netfail ] && url="https://127.0.0.1:9/netfail.git"
        printf '%s\t%s\n' "$n" "$url" >> "$T/bs/projects.tsv"
    done
    up() { git -C "$T/o/$1.git" rev-parse main; }
    
    # diverged: a local commit, plus an uncommitted edit to a file the update does not touch.
    echo mine > "$T/p/diverged/c.txt"; g "$T/p/diverged" add c.txt; g "$T/p/diverged" commit -qm local
    echo edited > "$T/p/diverged/b.txt"
    # divdirty: a local commit, plus an uncommitted edit to the very file the update changes.
    echo mine > "$T/p/divdirty/c.txt"; g "$T/p/divdirty" add c.txt; g "$T/p/divdirty" commit -qm local
    echo local-edit > "$T/p/divdirty/a.txt"
    # noupstream: on main, tracking nothing.
    g "$T/p/noupstream" branch -q --unset-upstream
    # detached: a commit made on a detached HEAD.
    g "$T/p/detached" checkout -q --detach; echo d > "$T/p/detached/d.txt"; g "$T/p/detached" add d.txt; g "$T/p/detached" commit -qm det
    det_sha="$(git -C "$T/p/detached" rev-parse HEAD)"
    # localbranch: on a branch origin never had, with a commit of its own.
    g "$T/p/localbranch" checkout -q -b task; echo t > "$T/p/localbranch/t.txt"; g "$T/p/localbranch" add t.txt; g "$T/p/localbranch" commit -qm task
    task_sha="$(git -C "$T/p/localbranch" rev-parse HEAD)"
    # netfail: origin is a port nothing listens on.
    g "$T/p/netfail" remote set-url origin "https://127.0.0.1:9/netfail.git"
    net_before="$(git -C "$T/p/netfail" rev-parse HEAD)"
    
    run() { # run <names> <jobs>
        if [ "$impl" = sh ]; then
            (cd "$T" && DOT_PROJECTS="$T/p" DOT_CLOUD="$DOT_CLOUD" DOT_RETRY_SLEEP=0 timeout 300 "$T/bs/bootstrap.sh" --only "$1" --no-deps --copy --no-stores --jobs "$2" 2>&1)
        else
            (cd "$T" && timeout 300 pwsh -NoProfile -NonInteractive -File "$T/bs/bootstrap.ps1" -Projects "$T/p" -Only "$1" -NoDeps -Copy -NoStores -Jobs "$2" 2>&1)
        fi
    }
    out="$(run "${names// /,}" 4)"; rc=$?
    
    check "exit 0 ($rc)" '[ $rc -eq 0 ]'
    check 'never "Resolve by hand"' '! grep -q "by hand" <<<"$out"'
    check 'behind updated' '[ "$(git -C "$T/p/behind" rev-parse HEAD)" = "$(up behind)" ] && grep -q "behind .*updated" <<<"$out"'
    
    check 'diverged: on origin' '[ "$(git -C "$T/p/diverged" rev-parse HEAD)" = "$(up diverged)" ]'
    bk="$(git -C "$T/p/diverged" for-each-ref --format='%(refname:short)' 'refs/heads/bootstrap-backup/*')"
    check "diverged: local commit on a backup branch ($bk)" '[ -n "$bk" ] && git -C "$T/p/diverged" cat-file -e "$bk:c.txt"'
    check 'diverged: edit re-applied' '[ "$(cat "$T/p/diverged/b.txt")" = edited ]'
    check 'diverged: one line says what was done' 'grep -q "^diverged .*diverged from upstream.*moved to it; 1 local commit(s) kept on branch bootstrap-backup/" <<<"$out"'
    
    check 'divdirty: on origin' '[ "$(git -C "$T/p/divdirty" rev-parse HEAD)" = "$(up divdirty)" ]'
    check 'divdirty: the edit kept in a named stash' 'git -C "$T/p/divdirty" stash list | grep -q "bootstrap-backup-" && git -C "$T/p/divdirty" stash show -p | grep -q "+local-edit"'
    check 'divdirty: says where the edit is' 'grep -q "^divdirty .*diverged from origin/main: moved to origin/main; 1 local commit(s) kept on branch bootstrap-backup/.*kept in stash" <<<"$out"'
    
    check 'noupstream: updated' '[ "$(git -C "$T/p/noupstream" rev-parse HEAD)" = "$(up noupstream)" ]'
    check 'noupstream: upstream set' '[ "$(git -C "$T/p/noupstream" rev-parse --abbrev-ref "@{u}")" = origin/main ]'
    
    check 'detached: on main at origin' '[ "$(git -C "$T/p/detached" symbolic-ref --short HEAD)" = main ] && [ "$(git -C "$T/p/detached" rev-parse HEAD)" = "$(up detached)" ]'
    check 'detached: its commit kept on a branch' 'git -C "$T/p/detached" for-each-ref --format="%(objectname)" "refs/heads/bootstrap-backup/*" | grep -q "$det_sha"'
    
    check 'localbranch: switched to main at origin' '[ "$(git -C "$T/p/localbranch" symbolic-ref --short HEAD)" = main ] && [ "$(git -C "$T/p/localbranch" rev-parse HEAD)" = "$(up localbranch)" ]'
    check 'localbranch: task branch untouched' '[ "$(git -C "$T/p/localbranch" rev-parse task)" = "$task_sha" ]'
    
    check 'netfail: reported as network, retried 3x' 'grep -q "netfail .*network, retried 3x, not updated: fatal: unable to access" <<<"$out"'
    check 'netfail: never called diverged' '! grep "^netfail" <<<"$out" | grep -qi "diverged\|refused"'
    check 'netfail: checkout untouched' '[ "$(git -C "$T/p/netfail" rev-parse HEAD)" = "$net_before" ]'
    check 'summary lists netfail only' 'grep -q "not updated (1):" <<<"$out" && grep -A1 "not updated (1):" <<<"$out" | grep -q "netfail .*network failure after 3 tries"'
    
    # Serial (one job) takes the same path outside the runspaces: a second run is all up to date.
    out2="$(run behind,diverged,detached 1)"; rc2=$?
    check "serial rerun exit 0 ($rc2)" '[ $rc2 -eq 0 ]'
    check 'serial rerun: up to date' '[ "$(grep -c "up to date" <<<"$out2")" -eq 3 ]'
}
scenario sh
command -v pwsh >/dev/null 2>&1 && scenario ps1 || echo "test_pull_repair: no pwsh, ps1 half skipped"

echo "test_pull_repair: $pass passed, $fail failed"
exit $((fail > 0))
