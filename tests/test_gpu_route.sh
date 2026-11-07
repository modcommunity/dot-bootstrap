#!/usr/bin/env bash
# gpu.sh route and pick_box without any box: which commands heavy hands to a GPU shot, and which box an exclusive job queues on.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
proj=$(mktemp -d); mkdir -p "$proj/game-x"; : > "$proj/game-x/project.godot"
fail=0
route() { # expect(shot|local), command...
	local want=$1; shift
	local got
	got=$(cd "$proj/game-x" && ROOT=$proj HEAVY_DIR=$proj/h HEAVY_PREFER_OFFLOAD=0 bash -c '
		eval "$(sed -n "/^unwrap() {/,/^}/p;/^route_cmd() {/,/^}/p" "$0")"
		shot_cmd() { echo shot; exit 0; }
		publish_cmd() { echo publish; exit 0; }
		( route_cmd "$@" ) 2>/dev/null; rc=$?; [ $rc = 75 ] && echo local' "$src" "$@")
	if [[ $got == "$want" ]]; then echo "ok   $want: $*"; else echo "FAIL want $want got '$got': $*"; fail=$((fail+1)); fi
}
route shot tools/screenshot.sh /tmp/a.png
route shot timeout 300 tools/screenshot_menus.sh
route shot env RENDERER=gl_compatibility tools/screenshot_hud.sh
route shot tools/render_weapons.sh
route shot tools/filmstrip_x.sh
route shot tools/menu_shot.sh
route shot tools/workshop_shots.sh
route shot tools/bsp_preview.sh
route shot tools/route_preview.sh surf_g2g_intro 3
route shot tools/solo_killview.sh /tmp/o final
route shot tools/killview_online.sh 1
route shot tools/verify_ui.sh trader
route shot tools/camera_check.sh
route shot ./game.sh shot
route local tools/visual_check.sh
route local tools/bake_lightmaps.sh
route local tools/audio_probe.sh
route local ./game.sh --no-parse test x
route publish tools/publish.sh --dev
# pick_box: the shortest wait wins, a tie keeps the earlier box, a dead box is skipped.
pick() { # expect, "box=score busy" ...
	local want=$1; shift
	local got
	got=$(bash -c '
		eval "$(sed -n "/^pick_box() {/,/^}/p" "$0")"
		die() { echo "$*" >&2; exit 2; }
		set_box() { BOX=$1; BOX_DESC=$1; }
		scores=("${@}")
		box_excl_score() { local e; for e in "${scores[@]}"; do [[ $e == "$BOX="* ]] && { v=${e#*=}; [[ $v == down ]] || echo "$v"; return 0; }; done; }
		unset GPU_BOX
		pick_box 2>/dev/null; echo "$BOX"' "$src" "$@")
	if [[ $got == "$want" ]]; then echo "ok   $want: $*"; else echo "FAIL want $want got '$got': $*"; fail=$((fail+1)); fi
}
pick staging "staging=0 0" "staging02=0 0"
pick staging02 "staging=3 3" "staging02=0 0"
pick staging "staging=2 2" "staging02=2 2"
pick staging "staging=1000 1" "staging02=down"
pick staging02 "staging=down" "staging02=4 4"
pick staging02 "staging=1000 0" "staging02=100 0"
pick staging02 "staging=2 2" "staging02=1 1"
rm -rf "$proj"
[[ $fail == 0 ]] && echo "all passed" || { echo "$fail failed"; exit 1; }
