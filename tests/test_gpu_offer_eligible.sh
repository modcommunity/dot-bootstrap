#!/usr/bin/env bash
# Routing table for gpu.sh offer_eligible: which waiting heavy commands a box may take. No boxes needed.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
proj=$(mktemp -d); mkdir -p "$proj/game-x"; : > "$proj/game-x/project.godot"; printf '#!/bin/sh\n' > "$proj/game-x/game.sh"; chmod +x "$proj/game-x/game.sh"
mkdir -p "$proj/game-x/tools"
printf '#!/bin/sh\ngit ls-files -co --exclude-standard\n' > "$proj/game-x/tools/check_ls.sh"
printf '#!/bin/sh\ngit diff --stat\n' > "$proj/game-x/tools/check_diff.sh"
printf 'parse_all() {\n:\n}\n' > "$proj/game-x/game.sh"
chmod +x "$proj/game-x/tools/"*.sh
fail=0
run() { # expect, command...
	local want=$1; shift
	local got=no
	got=$(cd "$proj/game-x" && ROOT=$proj WT_ROOT=$proj/wt bash -c '
		eval "$(sed -n "/^unwrap() {/,/^}/p;/^offer_eligible() {/,/^}/p;/^TOOL_ALLOW=/p;/^TOOL_DENY=/p;/^tool_job() {/,/^}/p" "$0")"
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
run yes bash tools/check_ls.sh --quick
run no bash tools/check_diff.sh --quick
run yes bash -c 'echo snippet' hv-parse-pass
run no bash -c 'echo snippet' other-name
run yes ./game.sh --no-parse test headless_maps -- --map=sunken_resort
run yes timeout 900 ./game.sh --no-parse test headless_maps -- --map=a-b.c_1
run no ./game.sh --no-parse test headless_maps -- --map=a/b
run no ./game.sh --no-parse test headless_maps -- '--map=a;b'
run no ./game.sh --no-parse test headless_maps -- --map=
run no ./game.sh --no-parse test headless_maps -- --other=x
run no ./game.sh --no-parse test headless_maps -- --map=a extra
run no ./game.sh --no-parse test a b -- --map=x
run no ./game.sh --no-parse test -- --map=x
run no ./game.sh shot
# suite_shards: hv shard runs each shard (SUITE.SHARD) as its own job; the merge reads local logs, so it stays here.
run yes timeout 1800 ./game.sh --no-parse test headless_bots.hard
run yes ./game.sh --no-parse test headless_bots.easy_2 headless_a
run yes ./game.sh --no-parse test headless_bots.hard.tscn
run no ./game.sh --no-parse test headless_bots.merge
run no ./game.sh --no-parse test headless_bots.merge.tscn
run no ./game.sh --no-parse test headless_bots.a.b
run no ./game.sh --no-parse test headless_bots.
run no ./game.sh --no-parse test .hard
run no './game.sh' --no-parse test 'headless_bots.a;b'
# An addon's native build.sh (2026-11-13): offered when the addon is the project's own directory, never through a link.
mkdir -p "$proj/game-x/addons/own/native" "$proj/other/native"
printf '#!/bin/sh\ngit clone x "$HOME/.cache/y"\n' > "$proj/game-x/addons/own/native/build.sh"; cp "$proj/game-x/addons/own/native/build.sh" "$proj/other/native/"
chmod +x "$proj/game-x/addons/own/native/build.sh" "$proj/other/native/build.sh"; ln -s "$proj/other" "$proj/game-x/addons/linked"
native() { # expect, command...: offer_eligible's answer and UW_NATIVE
	local want=$1; shift
	local got
	got=$(cd "$proj/game-x" && ROOT=$proj WT_ROOT=$proj/wt bash -c '
		eval "$(sed -n "/^unwrap() {/,/^}/p;/^offer_eligible() {/,/^}/p;/^TOOL_ALLOW=/p;/^TOOL_DENY=/p;/^tool_job() {/,/^}/p" "$0")"
		offer_eligible "$@" && echo "yes:${UW_KIND}:${UW_NATIVE:-}" || echo no' "$src" "$@")
	if [[ $got == "$want" ]]; then echo "ok   $want: $*"; else echo "FAIL want $want got $got: $*"; fail=$((fail+1)); fi
}
native yes:tool:own addons/own/native/build.sh release
native yes:tool:own bash ./addons/own/native/build.sh all -j8 use_lto=yes
native yes:tool: bash tools/check_ls.sh
native no addons/linked/native/build.sh release
native no addons/own/native/build.sh /tmp/x
native no addons/own/native/build.sh ../x
native no python3 addons/own/native/build.sh
native no addons/own/native/other.sh
rm -rf "$proj"
[[ $fail == 0 ]] && echo "all passed" || { echo "$fail failed"; exit 1; }
