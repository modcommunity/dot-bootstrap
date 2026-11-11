#!/usr/bin/env bash
# Regression (2026-11-11): the suite logs must be snapshotted on the box while the job still holds the workspace
# lock, and dev02 must copy the snapshot, not the shared workspace dir (the next job of the same worktree wipes
# .godot/test-logs as soon as the lock is released, so hv shard merge jobs saw "every shard's log is there" fail).
set -u
src=$(cd "$(dirname "$0")/.." && pwd)/tools/gpu.sh
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
snap=$(grep -n 'echo "__GPU_LOGS=' "$src" | head -1 | cut -d: -f1)
rcl=$(grep -n '^echo "__GPU_SUITE_RC=\$rc"' "$src" | head -1 | cut -d: -f1)
ck "remote script snapshots logs before the exit code line" '[ -n "$snap" ] && [ -n "$rcl" ] && [ "$snap" -lt "$rcl" ]'
ck "dev02 reads the __GPU_LOGS line" 'grep -q "__GPU_LOGS=\*" "$src"'
ck "dev02 copies from the snapshot" 'grep -q "logsrc=\${logsnap:-" "$src"'
# Functional: the snapshot survives the next job wiping the workspace test-logs.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/ws/.godot/test-logs" "$tmp/home/gpu"; echo shard > "$tmp/ws/.godot/test-logs/a.log"
blk=$(sed -n '/^# Snapshot the logs while/,/^fi$/p' "$src")
out=$(cd "$tmp/ws" && HOME=$tmp/home wsid=w~2 kind=game bash -c "$blk")
rm -rf "$tmp/ws/.godot/test-logs"
d=${out#__GPU_LOGS=}
ck "snapshot line printed" '[[ $out == __GPU_LOGS=* ]]'
ck "snapshot keeps the log after the workspace is wiped" '[ -f "$d/a.log" ]'
exit $((fail>0))
