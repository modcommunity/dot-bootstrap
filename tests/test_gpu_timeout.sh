#!/usr/bin/env bash
# gpu.sh against a box whose ssh connects but never answers (a remote loginctl that stalls): every probe,
# the offer handshake and status must give up inside their bound and count the box as unavailable, so
# heavy runs the job locally. A fake ssh/rsync/scp on PATH sleeps; no real box is touched.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
tmp=$(mktemp -d); trap 'pkill -P $$ 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/root/game-x" "$tmp/heavy"
: > "$tmp/root/game-x/project.godot"; printf '#!/bin/sh\n' > "$tmp/root/game-x/game.sh"; chmod +x "$tmp/root/game-x/game.sh"
for t in ssh rsync scp; do printf '#!/bin/sh\nexec sleep 120\n' > "$tmp/bin/$t"; chmod +x "$tmp/bin/$t"; done
fail=0
# check NAME MAXSECONDS EXPECT_RC EXPECT_OUTPUT_PATTERN cmd...
check() {
	local name=$1 max=$2 wantrc=$3 pat=$4; shift 4
	local t0=$SECONDS out rc
	out=$(cd "$tmp/root/game-x" && PATH="$tmp/bin:$PATH" GODOT_ROOT=$tmp/root WT_ROOT=$tmp/wt HEAVY_DIR=$tmp/heavy GPU_KEY=$tmp/nokey \
		GPU_PROBE_TIMEOUT=3 GPU_HANDSHAKE_TIMEOUT=3 GPU_SUITE_BOXES=staging02 \
		timeout 60 "$@" 2>&1); rc=$?
	local took=$(( SECONDS - t0 ))
	if (( took <= max )) && [[ $rc == "$wantrc" ]] && grep -Eq -- "$pat" <<<"$out"; then echo "ok   $name (${took}s)"
	else echo "FAIL $name: took ${took}s (max $max), rc $rc (want $wantrc), output: $out"; fail=$((fail+1)); fi
}
check "offer falls back to local (75) with one WARN" 12 75 'WARN staging02 did not answer' "$src" offer ./game.sh --no-parse test headless_a
check "offer skips a box that just timed out" 5 75 '^$' "$src" offer ./game.sh --no-parse test headless_a
check "capacity reports down" 12 0 'staging02 +0/0 .* down' env GPU_SUITE_BOXES=staging02 "$src" capacity
check "status reports unreachable" 12 0 'unreachable' env GPU_BOX=staging02 "$src" status
rm -rf "$tmp/heavy"/*
if grep -q 'ssh -i "\$KEY" -o BatchMode=yes -o ConnectTimeout=10 "\$HOST"' "$src" || ! grep -q ServerAliveInterval=5 "$src"; then
	echo "FAIL gpu.sh ssh options lack ServerAliveInterval/CountMax"; fail=$((fail+1)); else echo "ok   ServerAlive options present"; fi
exit $((fail>0))
