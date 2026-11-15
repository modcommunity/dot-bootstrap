#!/usr/bin/env bash
# heavy: a GPU_BOX-pinned job the box can run never takes a slot on this VM (2026-11-15: pinned laptop runs waited, then ran
# whole on dev02 and game.sh's own --import aborted there). Unpinned, or HEAVY_PIN_LOCAL=1, or a job the box cannot run: local as before.
set -u
bin_override=${HEAVY_BIN:-}
for v in $(compgen -e | grep -E '^(HEAVY_|GPU_)'); do unset "$v"; done
here=$(cd "$(dirname "$0")/.." && pwd)
src=${bin_override:-$here/tools/heavy}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/dir" "$tmp/cg" "$tmp/proj"
printf '#!/bin/sh\necho "game.sh $*" >> "$LOG"\n' > "$tmp/proj/game.sh"; chmod +x "$tmp/proj/game.sh"
touch "$tmp/proj/project.godot"; mkdir -p "$tmp/proj/.godot"; touch "$tmp/proj/.godot/global_script_class_cache.cfg"
# Fake offload: route never takes; eligible follows $ELIG; offer takes ($TAKE=1, logs "box") or gives back (75).
cat > "$tmp/off" <<'EOF'
#!/bin/sh
case $1 in
 route) exit 75 ;;
 eligible) exit "${ELIG:-0}" ;;
 offer) [ "${TAKE:-0}" = 1 ] && { echo "box" >> "$LOG"; exit 0; }; exit 75 ;;
esac
exit 75
EOF
chmod +x "$tmp/off"
echo 0 > "$tmp/cg/memory.swap.current"; printf 'inactive_file 0\nactive_file 0\nslab_reclaimable 0\n' > "$tmp/cg/memory.stat"
echo $(( 4096 * 1048576 )) > "$tmp/cg/memory.max"; echo 1048576 > "$tmp/cg/memory.current"
run() { # "ENV=.. ENV=.." maxwait cmd...
	local e=$1 w=$2; shift 2
	( cd "$tmp/proj" && env $e LOG=$tmp/log HEAVY_DIR=$tmp/dir HEAVY_CGROUP=$tmp/cg HEAVY_JOB_MAX_GB=0 HEAVY_JOB_CPUS=1 \
	  HEAVY_OFFLOAD=$tmp/off HEAVY_OFFLOAD_EVERY=1 HEAVY_SLOTS_BUILD=2 HEAVY_MIN_AVAIL_GB=1 HEAVY_MAX_WAIT=$w HEAVY_GPU_LOCK=none \
	  timeout 60 "$src" -- "$@" >"$tmp/out" 2>&1 ); echo $?
}
fail=0 n=0
check() { n=$((n+1)); local have; have=$(tr '\n' '|' < "$tmp/log" 2>/dev/null)
	if [ "$3" = "$2" ] && [ "$have" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: rc=$3 log='$have' (want rc $2, '$4')"; head -5 "$tmp/out" | sed 's/^/    /'; fail=1; fi
	rm -f "$tmp/log"; }
check "pinned, box refuses: waits, never runs here (gives up 124)" 124 "$(run "GPU_BOX=staging" 5 ./game.sh test x)" ""
check "pinned, box takes it: runs on the box only" 0 "$(run "GPU_BOX=staging TAKE=1" 5 ./game.sh test x)" "box|"
check "pinned, but the box cannot run this job: local slot as before" 0 "$(run "GPU_BOX=staging ELIG=1" 5 ./game.sh test x)" "game.sh test x|"
check "pinned with HEAVY_PIN_LOCAL=1: local slot" 0 "$(run "GPU_BOX=staging HEAVY_PIN_LOCAL=1" 5 ./game.sh test x)" "game.sh test x|"
check "unpinned, box refuses: local slot as before" 0 "$(run "X=1" 5 ./game.sh test x)" "game.sh test x|"
[ "$fail" = 0 ] && echo "PASS $n of $n" || { echo "FAILED"; exit 1; }
