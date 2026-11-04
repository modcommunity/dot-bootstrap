#!/usr/bin/env bash
# Post one suite run to nightly's result store (page /suites on the nightly panel), from a suite's log.
#   suite_post.sh REPO SUITE LOGFILE EXIT_CODE [HOST]
# Parses "N sections, M passed, K failed", "X of Y sections ran to their last line" and "ran all N of its checks";
# the verdict is the first ERROR line (or the last summary line). Commit and branch come from ~/godot/REPO.
# Env: NIGHTLY_SSH (default dev01), GODOT_ROOT (default ~/godot), SUITE_HOST (default: this machine's name).
# Look results up with: ssh dev01 ~/stack/nightly/bin/nightly suite latest|history REPO [SUITE]
set -euo pipefail
[ $# -ge 4 ] || { sed -n 2,7p "$0"; exit 2; }
repo=$1 suite=$2 log=$3 code=$4 host=${5:-${SUITE_HOST:-$(hostname -s | sed 's/^x-tmc-//')}}
root=${GODOT_ROOT:-$HOME/godot}
commit=$(git -C "$root/$repo" rev-parse HEAD 2>/dev/null || true)
branch=$(git -C "$root/$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
python3 -I - "$repo" "$suite" "$log" "$code" "$host" "$commit" "$branch" <<'PY' | ssh "${NIGHTLY_SSH:-dev01}" '~/stack/nightly/bin/nightly suite post --json-in'
import json, re, sys
repo, suite, log, code, host, commit, branch = sys.argv[1:8]
txt = open(log, errors="replace").read()
p = dict(repo=repo, suite=suite, host=host, commit=commit, branch=branch, exit_code=int(code), log_path=log)
m = re.findall(r"(\d+) sections?, (\d+) passed, (\d+) failed", txt)
if m:
    p["sections_run"], p["passed"], p["failed"] = map(int, m[-1])
r = re.findall(r"(\d+) of (\d+) sections ran to their last line", txt)
if r:
    p["sections_run"], p["sections_expected"] = int(r[-1][0]), int(r[-1][1])
elif m:
    p["sections_expected"] = p["sections_run"]
a = re.findall(r"ran all (\d+) of its checks", txt)
if a and "passed" not in p:
    p["passed"] = int(a[-1])
err = re.findall(r"^ERROR: .*$", txt, re.M)
tail = [l for l in txt.splitlines() if re.search(r"sections|ran all", l)]
p["verdict"] = (err[0] if err else (tail[-1] if tail else ""))[:300]
if not m and not r and not a:
    p["verdict"] = p["verdict"] or "no summary line in log"
print(json.dumps(p))
PY
