#!/usr/bin/env bash
# tools/sync_checkouts.sh keeps stale local state instead of destroying it: a moved tag is re-pointed with the old
# target kept, a checkout whose local commit is already upstream (plus mode-only edits) is reset, one with new local
# content is only reported with a salvage branch. Local bare repos stand in for GitHub.
# Run: tests/test_sync_checkouts.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
g() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
mkdir -p "$T/root/dot-bootstrap/tools" "$T/o" "$T/w"; cp "$H/tools/sync_checkouts.sh" "$T/root/dot-bootstrap/tools/"
for n in stale newcontent moved; do
    git init -q --bare -b main "$T/o/$n.git"; git clone -q "$T/o/$n.git" "$T/w/$n" 2>/dev/null
    echo a > "$T/w/$n/f"; echo '#!/bin/sh' > "$T/w/$n/s.sh"; g "$T/w/$n" add .; g "$T/w/$n" commit -qm one; g "$T/w/$n" push -q origin HEAD:main
    git clone -q "$T/o/$n.git" "$T/root/$n"
done
# stale: local commit, then origin gets the same change under another commit (cherry-pick) plus more
g "$T/root/stale" checkout -q -b tmp; echo b >> "$T/root/stale/f"; g "$T/root/stale" commit -qam pin; g "$T/root/stale" checkout -q main; g "$T/root/stale" reset -q --hard tmp; g "$T/root/stale" branch -qD tmp
echo b >> "$T/w/stale/f"; g "$T/w/stale" commit -qam pin2; echo c >> "$T/w/stale/f"; g "$T/w/stale" commit -qam more; g "$T/w/stale" push -q origin HEAD:main
chmod +x "$T/root/stale/f"   # mode-only edit (dirty would block a plain ff)
# newcontent: local commit with content origin lacks
echo local >> "$T/root/newcontent/f"; g "$T/root/newcontent" commit -qam localonly
echo up >> "$T/w/newcontent/g"; g "$T/w/newcontent" add g; g "$T/w/newcontent" commit -qm up; g "$T/w/newcontent" push -q origin HEAD:main
# moved: tag created locally pointing at an old commit, origin has it elsewhere
g "$T/w/moved" tag v1; g "$T/w/moved" push -q origin v1; git -C "$T/root/moved" fetch -q --tags
echo n >> "$T/w/moved/f"; g "$T/w/moved" commit -qam two; g "$T/w/moved" push -q origin HEAD:main; g "$T/w/moved" tag -f v1 >/dev/null; g "$T/w/moved" push -q -f origin v1
old="$(git -C "$T/root/moved" rev-parse v1)"; new="$(git -C "$T/w/moved" rev-parse v1)"
newcontent_head="$(git -C "$T/root/newcontent" rev-parse HEAD)"

out="$(SYNC_ROOT="$T/root" SYNC_HELD_FILE=/dev/null bash "$T/root/dot-bootstrap/tools/sync_checkouts.sh")"
check "report mode leaves stale untouched" '[ "$(git -C "$T/root/stale" rev-list --count HEAD..origin/main)" = 2 ]'
check "report mode names the stale checkout" 'grep -q "stale: .*stale" <<< "$out"'
check "report mode leaves tag" '[ "$(git -C "$T/root/moved" rev-parse v1)" = "$old" ]'
out="$(SYNC_ROOT="$T/root" SYNC_HELD_FILE=/dev/null bash "$T/root/dot-bootstrap/tools/sync_checkouts.sh" --apply)"
check "stale reset to origin/main" '[ "$(git -C "$T/root/stale" rev-parse HEAD)" = "$(git -C "$T/root/stale" rev-parse origin/main)" ]'
check "stale local commit kept on salvage branch" '[ -n "$(git -C "$T/root/stale" branch --list "salvage/*")" ]'
check "new content not reset" '[ "$(git -C "$T/root/newcontent" rev-parse HEAD)" = "$newcontent_head" ]'
check "new content saved on salvage branch" '[ -n "$(git -C "$T/root/newcontent" branch --list "salvage/*")" ]'
check "new content reported with reset hint" 'grep -q "newcontent: .*saved as salvage/.*reset --hard" <<< "$out"'
check "moved tag follows origin" '[ "$(git -C "$T/root/moved" rev-parse v1)" = "$new" ]'
check "old tag target kept" '[ "$(git -C "$T/root/moved" rev-parse "refs/salvage/tags/v1-${old:0:9}")" = "$old" ]'
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
