#!/usr/bin/env bash
# heavy (2026-11-15, laptop-oom-suites-1): an OOM-killed job is reported as an OOM kill whatever its exit code and teaches the
# next run (1.6 x its peak goes into the history, so the next start needs more); a job that needs more than the VM has fails
# loudly instead of queueing for ever. Fake systemd-run/journalctl/systemctl; no real cgroups.
set -u
bin_override=${HEAVY_BIN:-}
for v in $(compgen -e | grep -E '^(HEAVY_|GPU_)'); do unset "$v"; done
here=$(cd "$(dirname "$0")/.." && pwd)
src=${bin_override:-$here/tools/heavy}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/dir" "$tmp/cg" "$tmp/bin" "$tmp/run" "$tmp/proj"
touch "$tmp/proj/x"
python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$tmp/run/bus"
cat > "$tmp/bin/systemd-run" <<'F'
#!/bin/sh
while [ "$1" != -- ]; do shift; done; shift; shift 6; exec "$@"
F
cat > "$tmp/bin/journalctl" <<'F'
#!/bin/sh
[ -e "$OOMF" ] && echo "Memory cgroup out of memory: Killed process 1 (godot) oom-kill"
exit 0
F
cat > "$tmp/bin/systemctl" <<'F'
#!/bin/sh
echo 3000000000
F
chmod +x "$tmp/bin/"*
echo 0 > "$tmp/cg/memory.swap.current"; printf 'inactive_file 0\nactive_file 0\nslab_reclaimable 0\n' > "$tmp/cg/memory.stat"
echo $(( 8192 * 1048576 )) > "$tmp/cg/memory.max"; echo 1048576 > "$tmp/cg/memory.current"
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; sed 's/^/    /' "$tmp/out" | head -8; fail=$((fail+1)); fi; }
run() { # env... -- cmd...
	local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
	( cd "$tmp/proj" && env OOMF="$tmp/oom" PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR="$tmp/run" HEAVY_DIR="$tmp/dir" HEAVY_CGROUP="$tmp/cg" \
	  HEAVY_JOB_CPUS=1 HEAVY_JOB_MAX_GB=6 HEAVY_MIN_AVAIL_GB=1 HEAVY_GPU_LOCK=none GPU_OFFLOAD=0 HEAVY_NO_PREIMPORT=1 "${e[@]}" timeout 60 "$src" -- "$@" >"$tmp/out" 2>&1 )
}
# 1. OOM kill with a nonzero exit that is not 137 (143), after the job made the journal show an oom line.
run -- bash -c ': > "$OOMF"; exit 143'; rc=$?
ck "oom kill reported as OOM KILL even at rc 143 (rc $rc)" '[ $rc = 143 ] && grep -q "heavy: OOM KILL (rc 143)" "$tmp/out"'
learned=$(awk -F'\t' '{print $2}' "$tmp/dir/peaks" | tail -1)
ck "the history now holds 1.6 x the ceiling or peak ($learned MB)" '[ "${learned:-0}" -ge 3000 ]'
rm -f "$tmp/oom"
# 2. the next run of the same command: its need is learned x1.25 (>= 4 GB), shown in the start line as ceiling >= need
run -- true; rc=$?
ck "next run starts and its ceiling covers the learned need" '[ $rc = 0 ] && grep -qE "heavy: build/[0-9]+: ([4-9][0-9]{3}) MB" "$tmp/out"'
# 3. a plain failure (no oom in the journal) is not called an OOM kill
rm -f "$tmp/dir/peaks"
run -- bash -c 'exit 1'; rc=$?
ck "ordinary failure is not reported as OOM (rc $rc)" '[ $rc = 1 ] && ! grep -q "OOM KILL" "$tmp/out"'
# 4. a need above the VM's whole memory fails loudly
run HEAVY_MIN_AVAIL_GB=9999 -- true; rc=$?
ck "need above the VM total: exit 69 with a reason (rc $rc)" '[ $rc = 69 ] && grep -q "can never start here" "$tmp/out"'
run HEAVY_MIN_AVAIL_GB=9999 HEAVY_NEED_CHECK=0 HEAVY_MAX_WAIT=2 -- true; rc=$?
ck "HEAVY_NEED_CHECK=0 queues as before (rc $rc)" '[ $rc = 124 ]'
exit $((fail>0))
