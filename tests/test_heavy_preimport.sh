#!/usr/bin/env bash
# heavy (2026-11-13): a headless godot job that runs here in a never-imported project (no class cache) imports first in
# its own slot, so hv no longer queues a separate local --import that the box taking the job would make useless; an
# imported project, an --import job and a game.sh job get no extra import. A waiter whose directory was removed exits 66.
# A fake godot logs its arguments; nothing real runs or is queued.
set -u
bin_override=${HEAVY_BIN:-}
for v in $(compgen -e | grep -E '^(HEAVY_|GPU_)'); do unset "$v"; done
here=$(cd "$(dirname "$0")/.." && pwd)
src=${bin_override:-$here/tools/heavy}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/dir" "$tmp/cg" "$tmp/bin" "$tmp/proj"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/sudo"; chmod +x "$tmp/bin/sudo"
printf '#!/bin/sh\necho "godot $*" >> "$LOG"\n' > "$tmp/bin/godot"; chmod +x "$tmp/bin/godot"
printf '#!/bin/sh\necho "game.sh $*" >> "$LOG"\n' > "$tmp/proj/game.sh"; chmod +x "$tmp/proj/game.sh"
touch "$tmp/proj/project.godot"
echo 0 > "$tmp/cg/memory.swap.current"; printf 'inactive_file 0\nactive_file 0\nslab_reclaimable 0\n' > "$tmp/cg/memory.stat"
echo $(( 4096 * 1048576 )) > "$tmp/cg/memory.max"; echo 1048576 > "$tmp/cg/memory.current"
run() { # dir maxwait cmd...
	local d=$1 w=$2; shift 2
	( cd "$d" && LOG=$tmp/log PATH="$tmp/bin:$PATH" HEAVY_DIR=$tmp/dir HEAVY_CGROUP=$tmp/cg HEAVY_JOB_MAX_GB=0 HEAVY_JOB_CPUS=1 \
	  HEAVY_OFFLOAD= GPU_OFFLOAD=0 HEAVY_SLOTS_BUILD=2 HEAVY_SLOTS_CHECK=2 HEAVY_MIN_AVAIL_GB=1 HEAVY_MAX_WAIT=$w \
	  timeout 60 "$src" -- "$@" >"$tmp/out" 2>&1 ); echo $?
}
fail=0 n=0
check() { # name want-rc rc want-log
	n=$((n+1)); local have; have=$(cat "$tmp/log" 2>/dev/null | tr '\n' '|')
	if [ "$3" = "$2" ] && [ "$have" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: rc=$3 log='$have' (want rc $2, log '$4')"; sed 's/^/    /' "$tmp/out" | head -4; fail=1; fi
	rm -f "$tmp/log"
}
check "fresh project: scene imports first, then runs" 0 "$(run "$tmp/proj" 5 timeout 60 godot --headless --path . res://x.tscn)" \
	"godot --headless --path . --import|godot --headless --path . res://x.tscn|"
check "fresh project: an --import job runs once" 0 "$(run "$tmp/proj" 5 godot --headless --path . --import)" "godot --headless --path . --import|"
check "fresh project: game.sh imports itself, no extra import" 0 "$(run "$tmp/proj" 5 ./game.sh test x)" "game.sh test x|"
mkdir -p "$tmp/proj/.godot"; touch "$tmp/proj/.godot/global_script_class_cache.cfg"
check "imported project: scene runs alone" 0 "$(run "$tmp/proj" 5 godot --headless --path . res://x.tscn)" "godot --headless --path . res://x.tscn|"
# A removed directory: the only build slot is held, so the job waits; its directory goes away under it.
mkdir -p "$tmp/gone"
( exec 3>>"$tmp/dir/build.1.lock"; flock 3; exec sleep 20 ) & holder=$!
sleep 0.3
( sleep 2; rm -rf "$tmp/gone" ) &
rc=$( ( cd "$tmp/gone" && LOG=$tmp/log PATH="$tmp/bin:$PATH" HEAVY_DIR=$tmp/dir HEAVY_CGROUP=$tmp/cg HEAVY_JOB_MAX_GB=0 HEAVY_JOB_CPUS=1 \
	HEAVY_OFFLOAD= GPU_OFFLOAD=0 HEAVY_SLOTS_BUILD=1 HEAVY_MIN_AVAIL_GB=1 HEAVY_MAX_WAIT=15 \
	timeout 30 "$src" -- ./game.sh test y >"$tmp/out" 2>&1 ); echo $? )
kill "$holder" 2>/dev/null; wait 2>/dev/null
check "a waiter whose directory was removed exits 66 without running" 66 "$rc" ""
[ "$fail" = 0 ] && echo "PASS $n of $n" || { echo "FAILED"; exit 1; }
