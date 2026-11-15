#!/usr/bin/env bash
# gpu.sh remote_shared: CPU-only preparation (run's headless --import, the release export) holds ~/gpu/.lock shared and
# never takes ~/gpu/.gate. Regression: both went through remote_locked, which holds the gate, so a box that was only
# importing refused every suite ("BUSY a GPU job is running or waiting") and PH showed 0/30 free with its CPU idle.
# The real remote_locked/remote_shared run against a local ~/gpu (SSH is a local bash with HOME pointed at a temp dir).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
h=$(mktemp -d); mkdir -p "$h/gpu"
pids=()
cleanup() { local p; for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$h"; }
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cut_fn() { awk -v f="$1() {" 'index($0, f) == 1 { on = 1; if ($0 ~ /}$/) { print; exit } } on { print } on && /^}$/ { exit }' "$src"; }
fns=$(cut_fn remote_locked)$'\n'$(cut_fn remote_shared)
[[ $fns == *remote_locked*remote_shared* ]] || { echo "FAIL could not cut remote_locked/remote_shared out of $src"; exit 1; }
printf '%s\n' "$fns" >"$h/fns.sh"
# box <GATE_WAIT> function args...: one call as gpu.sh makes it, ending "rc=N".
box() { local gw=$1; shift; HOME=$h GATE_WAIT=$gw timeout 10 bash -c 'set -euo pipefail; SSH=(env HOME="$HOME" bash -c); . "$HOME/fns.sh"
rc=0; "$@" || rc=$?; echo "rc=$rc"' _ "$@" 2>&1; }
# What a suite's admission checks on the box (REMOTE_SUITE): the gate free and .lock takeable shared.
probe='cd ~/gpu; flock -n .gate true && echo GATE-FREE || echo GATE-HELD; exec 9>>.lock; flock -n -s 9 && echo SHARED-OK || echo SHARED-BLOCKED'
# hold <flock mode> <file>: a holder whose pid is the process holding the lock, so killing it frees the lock.
hold() { (cd "$h/gpu" && exec 9>>"$2" && flock "$1" 9 && exec sleep 30) & pids+=($!); sleep 0.3; }
release() { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; pids=(); }

# 1. with a suite running (shared .lock), the import runs at once and a second suite could still start
hold -s .lock
out=$(box 0 remote_shared import.p bash -c "$probe")
[[ $out == *GATE-FREE*SHARED-OK*rc=0 ]] && ok "remote_shared beside a running suite: runs, gate free, suites still admitted" || bad "remote_shared: $out"
# remote_locked, which import and export used before, waits the suite out holding the gate
out=$(box 1 remote_locked true)
[[ $out == *rc=197 ]] && ok "remote_locked beside a running suite waits for it (197 with GATE_WAIT)" || bad "remote_locked: $out"
release

# 2. an exclusive holder (a GPU run) still keeps the import out: 197 with GATE_WAIT, so excl picks again
hold -x .lock
out=$(box 1 remote_shared import.p true)
[[ $out == *rc=197 ]] && ok "remote_shared behind an exclusive job: 197 with GATE_WAIT" || bad "behind exclusive: $out"
release

# 3. two preparations of the same key wait for each other; different keys do not
hold -x prep.import.p.lock
out=$(box 1 remote_shared import.p true)
[[ $out == *rc=197 ]] && ok "same key: waits for the other import" || bad "same key: $out"
out=$(box 1 remote_shared import.q echo ran)
[[ $out == $'ran\nrc=0' ]] && ok "other key: runs" || bad "other key: $out"
release

# 4. the call sites
grep -q 'remote_shared "import.\$project" bash -c .*--import' "$src" && ok "run's headless import uses remote_shared" || bad "run's import is not shared"
grep -q 'remote_shared rel bash .*gpu-release-export.sh' "$src" && ok "the release export uses remote_shared" || bad "release export is not shared"
grep -n '^[^#]*remote_locked.*\(--import\|gpu-release-export\)' "$src" && bad "an import/export still takes the gate" || ok "no import/export through remote_locked"
exit $fail
