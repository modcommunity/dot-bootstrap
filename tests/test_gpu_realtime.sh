#!/usr/bin/env bash
# gpu.sh suite_boxes: real-time suites (REALTIME_SUITES) are never offered to ph; every other suite still is. No boxes needed.
# Leaves its small scratch project (two empty files) in $TMPDIR.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
proj=$(mktemp -d); mkdir -p "$proj/game-x"; : > "$proj/game-x/project.godot"; printf "#!/bin/sh\n" > "$proj/game-x/game.sh"; chmod +x "$proj/game-x/game.sh"
fail=0
run() { # expected boxes, command...
	local want=$1; shift
	local got
	got=$(cd "$proj/game-x" && ROOT=$proj WT_ROOT=$proj/wt bash -c '
		eval "$(sed -n "/^unwrap() {/,/^}/p;/^offer_eligible() {/,/^}/p;/^REALTIME_SUITES=/p;/^realtime_job() {/,/^}/p;/^suite_boxes() {/,/^}/p" "$0")"
		offer_eligible "$@" && suite_boxes || echo not-eligible' "$src" "$@")
	if [[ $got == "$want" ]]; then echo "ok   [$want]: $*"; else echo "FAIL want [$want] got [$got]: $*"; fail=$((fail+1)); fi
}
all="ph staging02 staging"
run staging02 ./game.sh --no-parse test headless_lossy
run staging02 timeout 900 ./game.sh --no-parse test headless_lossy_22
run staging02 ./game.sh --no-parse test headless_lossy_33
run staging02 env SOAK_SECONDS=30 ./game.sh test headless_lossy_66
run staging02 ./game.sh --no-parse test headless_net headless_lossy
run staging02 ./game.sh --no-parse test headless_lossy.tscn
run staging02 timeout 600 godot --headless --path . res://examples/headless_lossy.tscn
run staging02 godot --headless --path . res://examples/headless_lossy_22.tscn -- --rounds=2
run staging02 ./game.sh --no-parse test headless_lossy.a
run staging02 ./game.sh --no-parse test headless_lossy_22.b
run "$all" ./game.sh --no-parse test headless_bots.hard
run "$all" ./game.sh --no-parse test headless_net
run "$all" ./game.sh --no-parse test headless_latency
run "$all" ./game.sh --no-parse test headless_lossyish
run "$all" ./game.sh --no-parse test my_headless_lossy
run "$all" ./game.sh test
run "$all" ./game.sh --no-parse test headless_maps -- --map=headless_lossy
run "$all" godot --headless --path . res://examples/headless_net.tscn -- --x=headless_lossy.tscn
run "$all" godot --headless --path . --script res://tools/headless_lossy.gd
GPU_REALTIME_BOXES="staging02 staging" run "staging02 staging" ./game.sh --no-parse test headless_lossy
GPU_REALTIME_SUITES="headless_latency" run staging02 ./game.sh --no-parse test headless_latency
GPU_REALTIME_SUITES="headless_latency" run "$all" ./game.sh --no-parse test headless_lossy
GPU_SUITE_BOXES=ph run staging02 ./game.sh --no-parse test headless_lossy
GPU_SUITE_BOXES=ph run ph ./game.sh --no-parse test headless_net
run not-eligible tools/check_pinned_parse.sh headless_lossy
[[ $fail == 0 ]] && echo "all passed" || { echo "$fail failed"; exit 1; }
