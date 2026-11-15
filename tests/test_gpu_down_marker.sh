#!/usr/bin/env bash
# gpu.sh down markers ($HEAVY_DIR/gpu-down.<box>) and offer_boxes, the real functions cut out of tools/gpu.sh and run under
# set -euo pipefail. Regressions (2026-11-14): `[[ -e $down ]]` then `stat -c %Y` lost the race to a job removing the marker
# and the arithmetic on stat's empty output aborted the offer with rc 1 (gpu-down-toctou-1); one slow handshake marked PH
# down for every job and GPU_BOX=ph jobs exited 69 while the next reply cleared it again (fc-sim-host-1). No boxes needed.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
h=$(mktemp -d)
trap 'rm -rf "$h"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
fns=
for f in down_file down_read box_down mark_down offer_boxes; do
	# A one-line function is just its line; otherwise up to the closing brace.
	c=$(awk -v f="$f() {" 'index($0, f) == 1 { on = 1; if ($0 ~ /}$/) { print; exit } } on { print } on && /^}$/ { exit }' "$src")
	[[ -n $c ]] || { echo "FAIL could not cut $f out of $src"; exit 1; }
	fns+=$c$'\n'
done
run() { HEAVY_DIR=$h bash -c 'set -euo pipefail
'"$fns"'
'"$1"; }
now=$(date +%s)
m=$h/gpu-down.ph

# 1. no marker, empty (older format), garbage, and a marker removed between the existence check and the read
rm -f "$m"; out=$(run 'box_down "$(down_file ph)" && echo DOWN || echo UP' 2>&1)
[[ $out == UP ]] && ok "no marker: up" || bad "no marker: $out"
: >"$m"; out=$(run 'box_down "$(down_file ph)" && echo DOWN || echo UP' 2>&1)
[[ $out == DOWN ]] && ok "empty (older) marker: down" || bad "empty marker: $out"
echo junk >"$m"; out=$(run 'box_down "$(down_file ph)" && echo DOWN || echo UP' 2>&1)
[[ $out == DOWN ]] && ok "garbage marker: read as an older marker, down" || bad "garbage marker: $out"
out=$(run 'for i in $(seq 300); do echo "1 '"$now"' 3" >"$(down_file ph)"; rm -f "$(down_file ph)" & box_down "$(down_file ph)" || true; wait; done; echo survived' 2>&1)
[[ $out == survived ]] && ok "marker removed during the read: no abort (300 races)" || bad "marker race aborted: $out"
rm -f "$m"; out=$(run 'down_read "$(down_file ph)" && echo READ || echo NONE' 2>&1)
[[ $out == NONE ]] && ok "down_read on a missing marker returns 1 quietly" || bad "down_read missing: $out"

# 2. hysteresis: one miss is not down, two are; a stale run starts over
rm -f "$m"; out=$(run 'mark_down "$(down_file ph)"; box_down "$(down_file ph)" && echo DOWN || echo UP' 2>&1)
[[ $out == $'1\nUP' ]] && ok "one miss: still up" || bad "one miss: $out"
out=$(run 'mark_down "$(down_file ph)"; box_down "$(down_file ph)" && echo DOWN || echo UP' 2>&1)
[[ $out == $'2\nDOWN' ]] && ok "two misses in a row: down" || bad "two misses: $out"
echo "$((now - 9000)) $((now - 900)) 7" >"$m"; out=$(run 'box_down "$(down_file ph)" && echo DOWN || echo UP; mark_down "$(down_file ph)"' 2>&1)
[[ $out == $'UP\n1' ]] && ok "a run older than GPU_DOWN_S: up, the next miss starts at 1" || bad "stale run: $out"
[[ $(cut -d' ' -f1 "$m") -ge $now ]] && ok "the new run's first miss is now" || bad "first miss kept: $(cat "$m")"
ls "$h"/gpu-down.ph.tmp.* >/dev/null 2>&1 && bad "temp marker left behind" || ok "marker written through a renamed temp file"

# 3. offer_boxes: unpinned skips down boxes; pinned and down probes the box
stubs='suite_boxes() { echo ${BOXES:-ph staging02}; }
set_box() { BOX=$1; }
box_capacity() { [[ " ${ANSWER:-} " == *" $BOX "* ]] && echo "30 30 0 idle" || echo "0 0 0 down"; }
'
echo "$now $now 2" >"$m"; rm -f "$h/gpu-down.staging02"
out=$(run "$stubs"'offer_boxes' 2>&1); rc=$?
[[ $rc == 0 && $out == staging02 ]] && ok "unpinned: a down box is skipped" || bad "unpinned: rc=$rc out=$out"
echo "$now $now 2" >"$m"
out=$(GPU_BOX=ph BOXES=ph ANSWER=ph run "$stubs"'offer_boxes' 2>&1); rc=$?
[[ $rc == 0 && $out == *"marked down but answers"* && ${out##*$'\n'} == ph && ! -e $m ]] && ok "pinned, marked down but answers: marker cleared, box offered" || bad "pinned answers: rc=$rc out=$out"
echo "$now $now 2" >"$m"
out=$(GPU_BOX=ph BOXES=ph run "$stubs"'offer_boxes' 2>&1); rc=$?
[[ $rc == 75 ]] && ok "pinned, down for seconds: 75 (heavy keeps it), not 69" || bad "pinned young down: rc=$rc out=$out"
echo "$((now - 700)) $now 9" >"$m"
out=$(GPU_BOX=ph BOXES=ph run "$stubs"'offer_boxes' 2>&1); rc=$?
[[ $rc == 69 && $out == *"down 600+ s"* ]] && ok "pinned, down 600+ s: 69 with a reason" || bad "pinned old down: rc=$rc out=$out"
echo "$((now - 700)) $now 9" >"$m"
out=$(GPU_PIN_DOWN_S=0 GPU_BOX=ph BOXES=ph run "$stubs"'offer_boxes' 2>&1); rc=$?
[[ $rc == 75 ]] && ok "GPU_PIN_DOWN_S=0: a pinned job never gives up" || bad "pin 0: rc=$rc out=$out"
echo "$now $now 2" >"$m"; echo "$((now - 700)) $now 9" >"$h/gpu-down.staging02"
out=$(GPU_BOX=ph BOXES="ph staging02" run "$stubs"'offer_boxes' 2>&1); rc=$?
[[ $rc == 75 ]] && ok "pinned to two boxes, one down only briefly: 75" || bad "two pinned: rc=$rc out=$out"
# 4. no reader left that checks the marker and then stats it
grep -n 'stat -c %Y "\$down"' "$src" && bad "a check-then-stat of the marker is back" || ok "every marker read goes through down_read"
exit $fail
