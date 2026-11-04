#!/usr/bin/env bash
# lock_lists_stores: a content lock that pins only maps must not stop link_content from using DOT_STORES_FROM.
# Also checks bootstrap.ps1 carries the same condition, so the two scripts stay in step. Run: tests/test_lock_stores.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { if [ "$2" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
eval "$(sed -n '/^lock_lists_stores() {/,/^}/p' "$H/bootstrap.sh")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '{"items":[{"id":"a/m1","kind":"store","into":"maps/m1"}]}\n' > "$T/maps.lock.json"
printf '{"items":[{"id":"a/m1","into":"maps/m1"},{"id":"a/stores","kind":"store", "into" : ".stores"}]}\n' > "$T/both.lock.json"
lock_lists_stores "$T/maps.lock.json"; [ $? != 0 ]; ok "maps-only lock does not claim stores" $?
lock_lists_stores "$T/both.lock.json"; ok "lock with a .stores item claims stores" $?
lock_lists_stores "$T/missing.json"; [ $? != 0 ]; ok "no lock file" $?
grep -q 'into"\\s\*:\\s\*"\\.stores' "$H/bootstrap.ps1"; ok "bootstrap.ps1 has the same .stores condition" $?
grep -q 'lock_lists_stores "\$PROJECTS_DIR' "$H/bootstrap.sh"; ok "link_content uses it" $?
echo "test_lock_stores: $pass passed, $fail failed"; [ "$fail" = 0 ]
