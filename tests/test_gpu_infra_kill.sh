#!/usr/bin/env bash
# gpu.sh infrastructure kills and silent failures, the real code cut out of tools/gpu.sh and run under set -euo pipefail.
# Regressions (laptop-oom-suites-1, 2026-11-14): the laptop's memory cap killed suites (rc 143, no suite output) and agents
# read that as a real failure; other offers ended rc 1 with not a word (an unchecked failure under set -e). Now an rc 137/143
# or an OOM kill in the job's scope is called an INFRA KILL and given back (75) to run on another box, at most
# GPU_INFRA_RETRIES times; an rc without output says so; an aborted offer names the failing command. No boxes needed.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
h=$(mktemp -d); mkdir "$h/p"
trap 'rm -rf "$h"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cut_fn() { awk -v f="$1() {" 'index($0, f) == 1 { on = 1; if ($0 ~ /}$/) { print; exit } } on { print } on && /^}$/ { exit }' "$src"; }
fns=
for f in job_hash infra_file infra_count infra_reset infra_kill offer_try; do
	c=$(cut_fn "$f"); [[ -n $c ]] || { echo "FAIL could not cut $f out of $src"; exit 1; }
	fns+=$c$'\n'
done
run() { HEAVY_DIR=$h PROJ_DIR=$h/p bash -c 'set -euo pipefail
'"$fns"'
'"$1" 2>&1; }

# 1. which rcs are infra kills
for c in "143 0 yes" "137 0 yes" "1 3 yes" "1 0 no" "0 0 no" "124 0 no" "75 0 no"; do
	set -- $c
	out=$(run 'BOX=staging; infra_kill '"$1 $2"' ./game.sh test a && echo RETRY || echo STANDS; infra_reset ./game.sh test a')
	if [[ $3 == yes ]]; then [[ $out == *"INFRA KILL on staging"*RETRY ]] && ok "rc $1 oom $2: infra kill, retried" || bad "rc $1 oom $2: $out"
	else [[ $out == STANDS && $out != *INFRA* ]] && ok "rc $1 oom $2: the job's own result" || bad "rc $1 oom $2: $out"; fi
done
out=$(run 'BOX=staging; infra_kill 1 2 ./game.sh test a || true; infra_reset ./game.sh test a')
[[ $out == *"2 process(es) OOM-killed"* ]] && ok "an OOM kill is named" || bad "OOM not named: $out"

# 2. the retry limit counts kills on any box; then the rc stands and the count starts over
out=$(run 'for b in staging staging02 ph; do BOX=$b; infra_kill 143 0 ./game.sh test a && echo RETRY || echo STANDS; done
infra_count "*" ./game.sh test a')
[[ $out == *RETRY*RETRY*"rc 143 stands"*STANDS* && ${out##*$'\n'} == 0 ]] && ok "GPU_INFRA_RETRIES=2: third kill stands, count reset" || bad "retry limit: $out"
out=$(GPU_INFRA_RETRIES=0 run 'BOX=staging; for i in 1 2 3 4 5; do infra_kill 143 0 ./game.sh test a || echo STOPPED; done; infra_reset ./game.sh test a')
[[ $out != *STOPPED* ]] && ok "GPU_INFRA_RETRIES=0: no limit" || bad "retries 0: $out"

# 3. the box that killed it is counted per box and per job, so `offer` passes it over for that job only
out=$(run 'BOX=staging; infra_kill 143 0 ./game.sh test a; echo "$(infra_count staging ./game.sh test a) $(infra_count ph ./game.sh test a) $(infra_count staging ./game.sh test b)"; infra_reset ./game.sh test a')
[[ ${out##*$'\n'} == "1 0 0" ]] && ok "the kill counts against staging for this job only" || bad "per-box count: $out"
out=$(GPU_INFRA_FORGET_S=10 run 'echo $(( $(date +%s) - 3600 )) >"$(infra_file staging ./game.sh test a)"; infra_count staging ./game.sh test a')
[[ $out == 0 ]] && ok "an old kill is forgotten" || bad "old kill: $out"
grep -q 'infra_count "\$b" "\$@"' "$src" && ok "offer skips boxes with an infra kill for this job" || bad "offer does not consult infra_count"
grep -q 'infra_kill "\$rc" "\$oom" "\${JOB_ARGS\[@\]}" && { lane_pid=; back_to_queue' "$src" && ok "offer_on gives an infra kill back (75)" || bad "offer_on does not act on infra_kill"
grep -q 'oom_kill=\${ok:-0}' "$src" && ok "the box reports its scope's oom_kill count" || bad "no oom_kill in __GPU_STATS"

# 4. the no-output line, as written in offer_on
tail_=$(sed -n '/if \[\[ \$rc != 0 && \$nout == 0 \]\]; then/,/^\tfi$/p' "$src")
[[ -n $tail_ ]] || { echo "FAIL could not cut the no-output check out of $src"; exit 1; }
out=$(run 'BOX=staging; wsid=p; rc=1; nout=0
'"$tail_")
[[ $out == *"exited 1 without printing anything"* ]] && ok "rc 1 with no output: one-line reason" || bad "silent rc 1: $out"
out=$(run 'BOX=staging; wsid=p; rc=1; nout=4
'"$tail_")
[[ -z $out ]] && ok "rc 1 with output: no extra line" || bad "rc 1 with output: $out"

# 5. an offer that aborts under set -e names the command; a checked failure inside $(...) does not
out=$(run 'set_box() { BOX=$1; }; UW_KIND=game UW_ENV=() UW_REST=(./game.sh test a)
offer_on() { x=$(false || echo fine); [[ -n $x ]]; cp /nonexistent/x /tmp/ 2>/dev/null; echo NOTREACHED; }
set +e; ( offer_try staging /dev/null ); echo "rc=$?"')  # as `offer` calls it
[[ $out == *"offer to staging stopped (rc 1) at gpu.sh line"*"cp /nonexistent/x"* && $out != *NOTREACHED* && ${out##*$'\n'} == rc=1 ]] && ok "aborted offer names the failing command" || bad "aborted offer: $out"
[[ $(grep -c 'stopped' <<<"$out") == 1 ]] && ok "one line, not one per subshell" || bad "trap repeated: $out"
exit $fail
