#!/usr/bin/env bash
# Tests tools/install-valve-hooks.sh against the real dot-cloud guard.
#   GUARD_SRC=/path/to/dot-cloud/tools/check_valve_files.py tests/test_install_valve_hooks.sh
# Defaults to the sibling dot-cloud checkout. Fails loudly when the guard cannot be found.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
installer="$here/../tools/install-valve-hooks.sh"
guard_src="${GUARD_SRC:-$here/../../dot-cloud/tools/check_valve_files.py}"
[ -f "$guard_src" ] || { echo "FAIL: no guard at $guard_src (set GUARD_SRC)" >&2; exit 2; }
guard_src="$(cd "$(dirname "$guard_src")" && pwd)/$(basename "$guard_src")"

fails=0; passes=0
pass() { echo "ok   $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
P="$T/projects"; mkdir -p "$P/dot-cloud/tools" "$P/repo-a" "$P/repo-b" "$P/not-a-repo"
ln -s "$guard_src" "$P/dot-cloud/tools/check_valve_files.py"
for r in dot-cloud repo-a repo-b; do git -C "$P/$r" init -q; done

# 1. Install reports every repository and writes the hook.
out="$(bash "$installer" "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && pass "install exits 0" || fail "install exit $rc: $out"
echo "$out" | grep -q "3 of 3 repositories" && pass "summary counts three repositories" || fail "summary: $out"
hook="$P/repo-a/.git/hooks/pre-commit"
[ -x "$hook" ] && grep -qF "$P/dot-cloud/tools/check_valve_files.py" "$hook" && pass "hook is executable and names the guard" || fail "hook missing or wrong"
[ -e "$P/not-a-repo/.git" ] && fail "touched a non-repository" || pass "non-repository directory left alone"

# 2. Idempotent: a second run adds no second line.
bash "$installer" "$P" >/dev/null 2>&1
n="$(grep -cF "$P/dot-cloud/tools/check_valve_files.py" "$hook")"
[ "$n" -eq 1 ] && pass "second install does not duplicate the hook line" || fail "guard line count $n after two installs"

# 3. --check passes when all have it, fails when one does not.
bash "$installer" --check "$P" >/dev/null 2>&1 && pass "--check passes after install" || fail "--check failed after install"
mkdir -p "$P/repo-c" && git -C "$P/repo-c" init -q
bash "$installer" --check "$P" >/dev/null 2>&1; [ $? -eq 1 ] && pass "--check fails for a repository without the hook" || fail "--check passed with a missing hook"

# 4. The hook refuses a staged Valve file and lets an ordinary one through.
git -C "$P/repo-a" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
: > "$P/repo-a/model.vpk"; git -C "$P/repo-a" add model.vpk
if git -C "$P/repo-a" -c user.name=t -c user.email=t@example.invalid commit -q -m vpk 2>"$T/err"; then
    fail "commit of a .vpk was allowed"
else
    grep -q "model.vpk" "$T/err" && pass "commit of a staged .vpk is refused, naming the file" || fail "refusal did not name the file: $(cat "$T/err")"
fi
git -C "$P/repo-a" rm -q --cached -f model.vpk; rm -f "$P/repo-a/model.vpk"
echo hello > "$P/repo-a/readme.txt"; git -C "$P/repo-a" add readme.txt
git -C "$P/repo-a" -c user.name=t -c user.email=t@example.invalid commit -q -m ok && pass "ordinary commit passes the hook" || fail "ordinary commit was refused"

# 5. A missing projects directory or guard is a setup error (exit 2), never a silent pass.
bash "$installer" "$T/nowhere" >/dev/null 2>&1; [ $? -eq 2 ] && pass "missing projects directory exits 2" || fail "missing directory did not exit 2"
rm "$P/dot-cloud/tools/check_valve_files.py"
bash "$installer" "$P" >/dev/null 2>&1; [ $? -eq 2 ] && pass "missing guard exits 2" || fail "missing guard did not exit 2"

# 6. DOT_CLOUD points at a guard outside the projects directory; a bad one is exit 2.
mkdir -p "$T/elsewhere/tools"; cp "$guard_src" "$T/elsewhere/tools/check_valve_files.py"
DOT_CLOUD="$T/elsewhere" bash "$installer" "$P" >/dev/null 2>&1 && grep -qF "$T/elsewhere/tools/check_valve_files.py" "$P/repo-a/.git/hooks/pre-commit" && pass "DOT_CLOUD selects the guard" || fail "DOT_CLOUD ignored"
DOT_CLOUD="$T/missing" bash "$installer" "$P" >/dev/null 2>&1; [ $? -eq 2 ] && pass "bad DOT_CLOUD exits 2" || fail "bad DOT_CLOUD did not exit 2"

echo "test_install_valve_hooks: $passes passed, $fails failed"
[ $fails -eq 0 ]
