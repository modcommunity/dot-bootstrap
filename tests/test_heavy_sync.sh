#!/usr/bin/env bash
# tools/check_heavy_sync.sh: in sync when only comments / the GameSpice Bootstrap conf fallback differ, drift on any code change.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
chk=$here/tools/check_heavy_sync.sh; fail=0
t() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: rc=$3 want $2"; fail=1; fi; }
cp "$here/tools/heavy" "$tmp/ref"
"$chk" "$tmp/ref" >/dev/null; t "identical copy" 0 $?
sed -E 's/^( *# .*)$/\1 changed/; 1a # extra comment' "$tmp/ref" > "$tmp/ref2"
"$chk" "$tmp/ref2" >/dev/null; t "comment-only differences" 0 $?
sed -E 's#realtime_suites.conf"; do#realtime_suites.conf" "$HOME/godot/dot-bootstrap/tools/realtime_suites.conf"; do#' "$tmp/ref" > "$tmp/ref3"
grep -q "godot/dot-bootstrap" "$tmp/ref3" || { echo "FAIL test setup"; fail=1; }
"$chk" "$tmp/ref3" >/dev/null; t "private conf fallback path" 0 $?
{ cat "$tmp/ref"; echo 'echo drift'; } > "$tmp/ref4"
"$chk" "$tmp/ref4" >/dev/null; t "code drift detected" 1 $?
"$chk" "$tmp/missing" >/dev/null 2>&1; t "unreadable reference" 2 $?
exit $fail
