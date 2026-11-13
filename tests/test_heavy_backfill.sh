#!/usr/bin/env bash
# heavy backfill: while the head of a lane's FIFO waits for more memory than is free, a smaller waiter
# may take the free build slot, and the head keeps its place. A bigger waiter, or one that does not fit
# either, still waits. Fake head tickets are live sleeps' pids, the cgroup (HEAVY_CGROUP) fixes free
# memory at 3 GB, HEAVY_JOB_MAX_GB=0 skips the systemd scope, and a fake sudo stops the cache reclaim
# from touching the real drop_caches. Nothing real is queued.
# Set HEAVY_BIN to run the same cases against another copy (the pre-backfill copy at
# /usr/local/bin/heavy.bak-20261113 fails case 1).
set -u
# Isolate from the caller. A suite run inside a heavy job exports HEAVY_HELD, and a nested heavy then runs
# straight through (no queue, no gate), and the VM's HEAVY_*/GPU_* settings would leak in. Clear them all;
# every knob the cases need is set in waiter() and head_ticket().
bin_override=${HEAVY_BIN:-}  # the one HEAVY_ setting this test takes from the caller
for v in $(compgen -e | grep -E '^(HEAVY_|GPU_)'); do unset "$v"; done
here=$(cd "$(dirname "$0")/.." && pwd)
src=${bin_override:-$here/tools/heavy}
tmp=$(mktemp -d); pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/dir" "$tmp/cg" "$tmp/bin"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/sudo"; chmod +x "$tmp/bin/sudo"
echo 4294967296 > "$tmp/cg/memory.max"; echo 1073741824 > "$tmp/cg/memory.current"; echo 0 > "$tmp/cg/memory.swap.current"
printf 'inactive_file 0\nactive_file 0\nslab_reclaimable 0\n' > "$tmp/cg/memory.stat"
# 3 GB free (cgroup 4 GB less 1 GB in use); the VM's MemAvailable is far above that.

# head_ticket NEEDMB: a head that is alive (a sleep) and queued first with NEEDMB in its ticket.
head_ticket() {
	sleep 600 & local p=$!; pids+=("$p")
	echo "$1" > "$tmp/dir/queue.build.0000000000000000001.$p"
}
# waiter MINGB MAXWAIT MARKER: run heavy for `touch MARKER` with a memory need of MINGB; prints its exit code.
waiter() {
	PATH="$tmp/bin:$PATH" HEAVY_DIR=$tmp/dir HEAVY_CGROUP=$tmp/cg HEAVY_JOB_MAX_GB=0 HEAVY_JOB_CPUS=1 \
	HEAVY_OFFLOAD= GPU_OFFLOAD=0 HEAVY_SLOTS_BUILD=1 HEAVY_SLOTS_CHECK=1 HEAVY_MIN_AVAIL_GB=$1 HEAVY_MAX_WAIT=$2 \
	timeout 60 "$src" -- touch "$3" >"$tmp/out" 2>&1
	local rc=$?; sed 's/^/    heavy: /' "$tmp/out" | head -5 >&2
	echo $rc
}

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# 1. Backfill: head needs 99999 MB (3 GB free), a 1 GB waiter runs at once while the head stays queued.
rm -f "$tmp/dir"/queue.build.*
head_ticket 99999
start=$(date +%s)
rc=$(waiter 1 30 "$tmp/small"); took=$(( $(date +%s) - start ))
if [ "$rc" = 0 ] && [ -e "$tmp/small" ] && [ "$took" -le 9 ]; then ok "backfill: 1 GB waiter ran in ${took}s behind a 99999 MB head"
else bad "backfill: rc=$rc took=${took}s marker=$([ -e "$tmp/small" ] && echo yes || echo no) (want rc 0 within 9s)"; fi
# the head still holds its ticket (it was not dropped to let the waiter through)
ls "$tmp/dir" | grep -q '^queue.build.0000000000000000001\.' && ok "backfill: head ticket kept its place" || bad "backfill: head ticket was removed"

# 2. Reverse: head needs 1 GB (fits), waiter needs 99 GB: the waiter must wait, not jump the head.
rm -f "$tmp/dir"/queue.build.* "$tmp/big"
head_ticket 1024
rc=$(waiter 99 6 "$tmp/big")
if [ "$rc" = 124 ] && [ ! -e "$tmp/big" ]; then ok "reverse: 99 GB waiter behind a 1 GB head waited out (rc 124, nothing ran)"
else bad "reverse: rc=$rc marker=$([ -e "$tmp/big" ] && echo yes || echo no) (want rc 124, no marker)"; fi

# 3. Bigger waiter: head needs 99999 MB, waiter needs 4 GB (more than the 3 GB free): must wait.
rm -f "$tmp/dir"/queue.build.* "$tmp/mid"
head_ticket 99999
rc=$(waiter 4 6 "$tmp/mid")
if [ "$rc" = 124 ] && [ ! -e "$tmp/mid" ]; then ok "no-fit: 4 GB waiter with 3 GB free waited out behind a 99999 MB head (rc 124)"
else bad "no-fit: rc=$rc marker=$([ -e "$tmp/mid" ] && echo yes || echo no) (want rc 124, no marker)"; fi

if [ "$fail" = 0 ]; then echo "PASS heavy backfill: 4 of 4 checks"; exit 0; fi
echo "FAIL heavy backfill"; exit 1
