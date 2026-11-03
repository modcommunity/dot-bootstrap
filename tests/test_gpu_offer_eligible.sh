#!/usr/bin/env bash
# Routing table for gpu.sh offer_eligible: which waiting heavy commands a box may take. No boxes needed.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
proj=$(mktemp -d); mkdir -p "$proj/game-x"; : > "$proj/game-x/project.godot"; printf '#!/bin/sh\n' > "$proj/game-x/game.sh"; chmod +x "$proj/game-x/game.sh"
fail=0
run() { # expect, command...
	local want=$1; shift
	local got=no
	got=$(cd "$proj/game-x" && ROOT=$proj WT_ROOT=$proj/wt bash -c '
		eval "$(sed -n "/^unwrap() {/,/^}/p;/^offer_eligible() {/,/^}/p" "$0")"
		offer_eligible "$@" && echo yes || echo no' "$src" "$@")
	if [[ $got == "$want" ]]; then echo "ok   $want: $*"; else echo "FAIL want $want got $got: $*"; fail=$((fail+1)); fi
}
run yes ./game.sh --no-parse test headless_a
run yes timeout 900 ./game.sh --no-parse test headless_a headless_b
run yes env SOAK_SECONDS=30 ./game.sh --no-parse test headless_a
run yes godot --headless --path . res://tools/spot_probe.tscn -- --survival --maps=zm_a
run yes godot --headless --path . --script res://tools/smooth_bench.gd
run yes timeout 600 env ZZ_SEED=7 godot --headless --path . --script res://tools/x.gd -- --n=3
run no env GPU_OFFLOAD=1 ./game.sh --no-parse test headless_a
run no env PATH=/tmp ./game.sh --no-parse test headless_a
run no env TMC_TOKEN=abc ./game.sh --no-parse test headless_a
run no env X='a b' ./game.sh --no-parse test headless_a
run no godot --headless --path . --import
run no godot --headless --path . --script res://../x.gd
run no tools/check_pinned_parse.sh game-x
run no ./game.sh shot
rm -rf "$proj"
[[ $fail == 0 ]] && echo "all passed" || { echo "$fail failed"; exit 1; }
