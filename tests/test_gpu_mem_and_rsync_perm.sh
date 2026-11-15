#!/usr/bin/env bash
# gpu.sh (2026-11-15, laptop-oom-suites-1): (1) the rsync slot locks must work for a user who cannot write them (another
# user's file in the shared /tmp dir) -- the old `exec >` failed and the caller waited for ever; (2) learned_need_gb: a
# command's start need is its recent peaks x1.25 (an OOM-killed run counts 1.6x), never below SUITE_MIN_GB, off with GPU_MEM_LEARN=0.
set -u
src=$(cd "$(dirname "$0")/.." && pwd)/tools/gpu.sh
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/q"
printf '#!/bin/sh\necho ran >> "$LOG"\n' > "$tmp/bin/rsync"; chmod +x "$tmp/bin/rsync"
for i in 1 2; do : > "$tmp/q/slot.$i.lock"; chmod 444 "$tmp/q/slot.$i.lock"; done   # not writable by us, as another user's would be
fn=$(sed -n '/^rsync() {$/,/^}$/p' "$src")
LOG=$tmp/log GPU_RSYNC_DIR=$tmp/q GPU_RSYNC_SLOTS=2 PATH=$tmp/bin:$PATH timeout 20 bash -c "$fn"$'\n'"rsync x" 2>"$tmp/err"; rc=$?
ck "rsync runs with read-only slot locks (rc $rc)" '[ $rc = 0 ] && [ "$(cat "$tmp/log" 2>/dev/null)" = ran ]'
rm -rf "$tmp/q2"; LOG=$tmp/log GPU_RSYNC_DIR=$tmp/q2 GPU_RSYNC_SLOTS=2 PATH=$tmp/bin:$PATH timeout 20 bash -c "$fn"$'\n'"rsync x" 2>/dev/null
ck "fresh queue dir: slot locks are world-writable" '[ "$(stat -c %a "$tmp/q2/slot.1.lock")" = 666 ]'

fn=$(sed -n '/^learned_need_gb() {/,/^}/p' "$src")
stats=$tmp/stats.tsv
row() { printf '2026-11-15T00:00:00\tph\tw\tpeak_mb=%s cpu_s=1 oom_kill=%s wall_s=1\t%s\n' "$1" "$2" "$3" >> "$stats"; }
need() { env "$@" GPU_STATS_FILE=$stats SUITE_MIN_GB=2 bash -c "$fn"$'\n''learned_need_gb "./game.sh test big"'; }
row 1100 0 "./game.sh test small"
ck "no history: SUITE_MIN_GB (2)" '[ "$(need A=1)" = 2 ]'
row 3800 0 "./game.sh test big"; row 1000 0 "./game.sh test big"
ck "3800 MB peak x1.25 = 5 GB" '[ "$(need A=1)" = 5 ]'
ck "GPU_MEM_LEARN=0 -> 2" '[ "$(need GPU_MEM_LEARN=0)" = 2 ]'
row 2000 3 "./game.sh test oomed"
ck "oom-killed run counts 1.6x: 2000 -> 4 GB" '[ "$(env GPU_STATS_FILE=$stats SUITE_MIN_GB=2 bash -c "$fn"$'"'"'\nlearned_need_gb "./game.sh test oomed"'"'"')" = 4 ]'
for i in 1 2 3 4 5 6 7 8; do row 500 0 "./game.sh test big"; done
ck "only the last 8 runs count: the old 3800 peak aged out -> 2" '[ "$(need A=1)" = 2 ]'
exit $((fail>0))
