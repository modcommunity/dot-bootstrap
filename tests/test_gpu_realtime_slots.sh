#!/usr/bin/env bash
# gpu.sh REMOTE_SUITE's real-time caps (RT_MAX / RT_BUSY, 2026-11-13): a box runs at most rt_max real-time suites, starts
# one only below rt_busy other jobs, and while one runs takes no other job past rt_busy. Runs the box snippet up to the
# workspace pick in a scratch $HOME, with held suite/rt locks standing in for running jobs. No boxes needed.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
home=$(mktemp -d); mkdir -p "$home/gpu"
snip=$home/snip.sh
{ echo 'person_here() { return 1; }'
  sed -n "/^read -r -d '' REMOTE_SUITE <<'EOF'/,/^EOF\$/p" "$here/tools/gpu.sh" | sed '1d;$d' | sed '/^wsid=$/,$d'
  echo 'echo "START slot=$slot rt=${got:-}"'; } > "$snip"
fail=0 holders=()
hold() { ( exec 3>>"$home/gpu/$1"; flock 3; exec sleep 300 ) & holders+=($!); sleep 0.2; }
release() { kill "${holders[@]}" 2>/dev/null; wait "${holders[@]}" 2>/dev/null; holders=(); }
trap release EXIT
check() { # want-prefix rt rt_max rt_busy
	local want=$1 got
	got=$(HOME=$home GPU_MIN_DISK_GB=0 bash "$snip" proj 8 1 6 me 0 600 game 0 1 "$2" "$3" "$4" true 2>&1)
	if [[ $got == "$want"* ]]; then echo "ok   [$got] rt=$2 max=$3 busy=$4"; else echo "FAIL want [$want] got [$got] rt=$2 max=$3 busy=$4"; fail=$((fail+1)); fi
}
check "START slot=1 rt=1" 1 2 5
check "START slot=1 rt=" 0 2 5
hold rt.1.lock; check "START slot=1 rt=2" 1 2 5; hold rt.2.lock
check "BUSY 2 real-time" 1 2 5
release
for n in 1 2 3 4 5; do hold suite.$n.lock; done
check "BUSY 5 jobs run here" 1 2 5
check "START slot=6 rt=" 0 2 5          # no real-time suite runs: the plain slots still fill
hold rt.1.lock; check "BUSY a real-time suite runs here" 0 2 5
release
for n in 1 2 3 4; do hold suite.$n.lock; done
check "START slot=5 rt=1" 1 2 5
release
[[ $fail == 0 ]] && echo "all passed" || { echo "$fail failed"; exit 1; }
