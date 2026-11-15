#!/usr/bin/env bash
# gpu.sh suite_boxes and /etc/heavy.conf-style defaults: GPU_BOX and GPU_SUITE_BOXES from the caller constrain
# which boxes a suite job is offered to. No boxes needed.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
fail=0
boxes() { # expect, env assignments... (UW_KIND etc.)
	local want=$1; shift
	local got
	got=$(env -u GPU_BOX -u GPU_SUITE_BOXES -u GPU_REALTIME_BOXES -u GPU_TOOL_BOXES -u UW_KIND "$@" bash -c '
		eval "$(sed -n "/^suite_boxes() {/,/^}/p" "$0")"
		realtime_job() { return 1; }
		suite_boxes' "$src")
	if [[ $got == "$want" ]]; then echo "ok   [$want]: $*"; else echo "FAIL want [$want] got [$got]: $*"; fail=$((fail+1)); fi
}
boxes "ph staging02 staging" A=1
boxes "ph" GPU_SUITE_BOXES=ph
boxes "ph staging02" GPU_SUITE_BOXES="ph staging02"
boxes "ph" GPU_BOX=ph GPU_SUITE_BOXES="ph staging02 staging"
boxes "staging02" GPU_BOX=staging02 UW_KIND=tool
boxes "ph" UW_KIND=tool

# The installed heavy.conf must let the caller's GPU_SUITE_BOXES win.
conf=/etc/heavy.conf
if [[ -r $conf ]]; then
	got=$(env GPU_SUITE_BOXES=ph bash -c 'id() { echo gamedev; }; . "$0" >/dev/null 2>&1; echo "$GPU_SUITE_BOXES"' "$conf")
	if [[ $got == ph ]]; then echo "ok   heavy.conf keeps the caller's GPU_SUITE_BOXES"; else echo "FAIL heavy.conf overrode GPU_SUITE_BOXES (got [$got])"; fail=$((fail+1)); fi
fi
# Pinned box down: the real `offer`, against a host that cannot answer (.invalid never resolves). Down 600+ s: 69, never
# 75. Down only a moment (a flapping marker): 75, so heavy keeps the job; it exited 69 on one missed handshake (fc-sim-host-1).
h=$(mktemp -d); mkdir "$h/game-x"; : > "$h/game-x/project.godot"; printf '#!/bin/sh\n' > "$h/game-x/game.sh"; chmod +x "$h/game-x/game.sh"
now=$(date +%s)
for c in "$((now - 10000)) 69" "$now 75"; do
	set -- $c
	echo "$1 $now 5" > "$h/gpu-down.ph"
	rc=0; out=$(cd "$h/game-x" && GODOT_ROOT=$h WT_ROOT=$h/wt HEAVY_DIR=$h GPU_BOX=ph GPU_HOST=nobody@box.invalid timeout 60 "$src" offer ./game.sh --no-parse test headless_a 2>&1) || rc=$?
	if [[ $rc == "$2" ]]; then echo "ok   pinned-down offer, first miss $((now - $1)) s ago: rc=$rc"; else echo "FAIL pinned-down offer, first miss $((now - $1)) s ago: want $2, rc=$rc: $out"; fail=$((fail+1)); fi
done
rm -rf "$h"
exit $((fail > 0))
