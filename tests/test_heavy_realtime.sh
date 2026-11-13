#!/usr/bin/env bash
# heavy's real-time suites (tools/realtime_suites.conf, 2026-11-13): a real-time job needs HEAVY_RT_MIN_MB free
# (whatever HEAVY_MIN_AVAIL_GB says), at most HEAVY_RT_MAX run at once, a real-time head waiting for that cap lets
# other jobs backfill, while one runs other jobs need HEAVY_RT_GUARD_MB more, and two imports of one directory
# run one after the other. Scaled down (RT_MIN 2048 MB, guard 1024 MB) so the VM's own MemAvailable never decides;
# the fake cgroup (HEAVY_CGROUP) sets what is free. Nothing real is queued.
set -u
bin_override=${HEAVY_BIN:-}
for v in $(compgen -e | grep -E '^(HEAVY_|GPU_)'); do unset "$v"; done
here=$(cd "$(dirname "$0")/.." && pwd)
src=${bin_override:-$here/tools/heavy}
tmp=$(mktemp -d); pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap 'cleanup; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/dir" "$tmp/cg" "$tmp/bin" "$tmp/proj"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/sudo"; chmod +x "$tmp/bin/sudo"
printf '#!/bin/sh\ntouch "$MARK"\n' > "$tmp/proj/game.sh"; chmod +x "$tmp/proj/game.sh"
echo 0 > "$tmp/cg/memory.swap.current"; printf 'inactive_file 0\nactive_file 0\nslab_reclaimable 0\n' > "$tmp/cg/memory.stat"
free_mb() { echo $(( ($1 + 1024) * 1048576 )) > "$tmp/cg/memory.max"; echo 1073741824 > "$tmp/cg/memory.current"; }
hold() { ( exec 3>>"$tmp/dir/$1"; flock 3; exec sleep 300 ) & pids+=($!); sleep 0.3; }
release() { cleanup; pids=(); }
head_ticket() { sleep 600 & local p=$!; pids+=("$p"); echo "$1" > "$tmp/dir/queue.build.0000000000000000001.$p"; }
# run MAXWAIT MARKER cmd...: heavy with a 1 GB need; prints its exit code.
run() {
	local w=$1 m=$2; shift 2
	( cd "$tmp/proj" && MARK=$m PATH="$tmp/bin:$PATH" HEAVY_DIR=$tmp/dir HEAVY_CGROUP=$tmp/cg HEAVY_JOB_MAX_GB=0 HEAVY_JOB_CPUS=1 \
	  HEAVY_OFFLOAD= GPU_OFFLOAD=0 HEAVY_SLOTS_BUILD=4 HEAVY_SLOTS_CHECK=4 HEAVY_MIN_AVAIL_GB=1 HEAVY_MAX_WAIT=$w \
	  HEAVY_RT_MIN_MB=2048 HEAVY_RT_GUARD_MB=1024 HEAVY_REALTIME_CONF=$here/tools/realtime_suites.conf \
	  timeout 60 "$src" -- "$@" >"$tmp/out" 2>&1 ); echo $?
}
fail=0 n=0
expect() { # name want-rc marker want-marker(yes/no) rc
	n=$((n+1)); local have=no; [ -e "$3" ] && have=yes
	if [ "$5" = "$2" ] && [ "$have" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: rc=$5 marker=$have (want rc $2, marker $4)"; sed 's/^/    /' "$tmp/out" | head -4; fail=1; fi
	rm -f "$3"
}
free_mb 1536
expect "1.5 GB free: real-time lossy shard waits for the 2 GB floor" 124 "$tmp/m" no "$(run 5 "$tmp/m" timeout 900 ./game.sh --no-parse test headless_lossy.windows)"
expect "1.5 GB free: real-time latency scene waits" 124 "$tmp/m" no "$(run 5 "$tmp/m" sh -c 'touch "$MARK"' res://examples/headless_latency.tscn)"
expect "1.5 GB free: headless_combatfeel is not real-time, runs" 0 "$tmp/m" yes "$(run 5 "$tmp/m" ./game.sh --no-parse test headless_combatfeel)"
free_mb 2560
expect "2.5 GB free: real-time lossy_22 runs" 0 "$tmp/m" yes "$(run 5 "$tmp/m" ./game.sh --no-parse test headless_lossy_22)"
hold rt.1.lock; hold rt.2.lock
expect "both real-time slots held: lossy_33 waits" 124 "$tmp/m" no "$(run 5 "$tmp/m" ./game.sh --no-parse test headless_lossy_33)"
head_ticket "2048 rt"
expect "real-time head waiting for the cap: a plain suite backfills" 0 "$tmp/m" yes "$(run 8 "$tmp/m" ./game.sh --no-parse test headless_net)"
release; rm -f "$tmp/dir"/queue.*
hold rt.1.lock; free_mb 1536
expect "a real-time suite runs, 1.5 GB free: a 1 GB plain suite waits for need + guard" 124 "$tmp/m" no "$(run 5 "$tmp/m" ./game.sh --no-parse test headless_net)"
free_mb 2560
expect "a real-time suite runs, 2.5 GB free: the plain suite runs" 0 "$tmp/m" yes "$(run 5 "$tmp/m" ./game.sh --no-parse test headless_net)"
release
# Two imports of one directory: the second waits for the first.
lk="$tmp/dir/import.$(cd "$tmp/proj" && printf '%s' "$PWD" | md5sum | cut -c1-12).lock"
( exec 3>>"$lk"; flock 3; sleep 3 ) & pids+=($!); sleep 0.3
t0=$(date +%s); rc=$(run 0 "$tmp/m" sh -c 'touch "$MARK"' --import); took=$(( $(date +%s) - t0 ))
n=$((n+1))
if [ "$rc" = 0 ] && [ "$took" -ge 2 ] && grep -q 'another import' "$tmp/out"; then echo "ok   a second import of one directory waited ${took}s for the first"
else echo "FAIL import serialization: rc=$rc took=${took}s"; sed 's/^/    /' "$tmp/out" | head -4; fail=1; fi
release
if [ "$fail" = 0 ]; then echo "PASS heavy real-time: $n of $n checks"; exit 0; fi
echo "FAIL heavy real-time"; exit 1
