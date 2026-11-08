#!/usr/bin/env bash
# gpu.sh clean against a fake box (ssh runs the command locally with HOME in a temp dir): the dry run lists old
# ~/gpu/suite/<project>/ directories without removing, --apply removes them, a running project, .shim and the
# lock/log files are left alone.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/gpu/suite/"{old-a,old-b,busy,.shim} "$tmp/heavy"
echo x > "$tmp/home/gpu/suite/old-a/f"; : > "$tmp/home/gpu/suite/old-a.lock"; : > "$tmp/home/gpu/suite/busy.lock"; : > "$tmp/home/gpu/suite/old-a.import.log"
printf '#!/bin/sh\nfor last; do :; done\nexec env HOME=%s bash -c "$last"\n' "$tmp/home" > "$tmp/bin/ssh"; chmod +x "$tmp/bin/ssh"
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
run() { PATH="$tmp/bin:$PATH" HEAVY_DIR=$tmp/heavy GPU_KEY=$tmp/nokey GPU_SUITE_BOXES=staging GPU_PROBE_TIMEOUT=10 "$src" clean "$@" 2>&1; }
( exec 9>>"$tmp/home/gpu/suite/busy.lock"; flock -n 9; sleep 20 ) & holder=$!
sleep 1
out=$(run); echo "$out"
ck "dry run lists old-a" 'grep -q "would remove old-a" <<<"$out"'
ck "dry run lists old-b" 'grep -q "would remove old-b" <<<"$out"'
ck "dry run removes nothing" '[ -d "$tmp/home/gpu/suite/old-a" ]'
ck "running project skipped" 'grep -q "skip busy (running)" <<<"$out"'
out=$(run --apply); echo "$out"
ck "apply removes old dirs" '[ ! -d "$tmp/home/gpu/suite/old-a" ] && [ ! -d "$tmp/home/gpu/suite/old-b" ]'
ck "apply keeps busy, .shim, lock and log files" '[ -d "$tmp/home/gpu/suite/busy" ] && [ -d "$tmp/home/gpu/suite/.shim" ] && [ -e "$tmp/home/gpu/suite/old-a.lock" ] && [ -e "$tmp/home/gpu/suite/old-a.import.log" ]'
kill "$holder" 2>/dev/null
exit $((fail>0))
