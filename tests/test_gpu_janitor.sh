#!/usr/bin/env bash
# tools/janitor.sh against a fake ~/gpu (GPU_DIR, FAKE_USED): idle old workspaces go oldest first; a workspace whose lock is
# held, that was touched recently, or that a process references survives even a HARD prune; sib versions in use survive.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
g=$tmp/gpu; mkdir -p "$g/suite" "$g/ws"/{idle-old,idle-older,locked,fresh,proc} "$g/sib/lib"/{aaa1,bbb2,ccc3}
for w in idle-old idle-older locked fresh proc; do mkdir -p "$g/ws/$w/$w"; echo x > "$g/ws/$w/$w/f"; done
old() { find "$1" -exec touch -d "$2" {} +; }
old "$g/ws/idle-old" "3 days ago"; old "$g/ws/idle-older" "5 days ago"; old "$g/ws/locked" "4 days ago"; old "$g/ws/proc" "4 days ago"
touch -d "4 days ago" "$g/ws/fresh" "$g/ws/fresh/fresh"   # recent file deep inside, dir mtimes old
old "$g/sib/lib/aaa1" "9 days ago"; old "$g/sib/lib/bbb2" "8 days ago"; old "$g/sib/lib/ccc3" "7 days ago"
ln -s "$g/sib/lib/aaa1" "$g/ws/locked/lib"; ln -s ccc3 "$g/sib/lib/latest"
touch -h -d "4 days ago" "$g/ws/locked" "$g/ws/locked/lib"
: > "$g/suite/locked.lock"
echo 90 > "$tmp/used"
( exec 9>>"$g/suite/locked.lock"; flock -n 9; sleep 30 ) & sleep 1
( cd "$g/ws/proc/proc" && exec sleep 30 ) & sleep 0.5
env GPU_DIR=$g FAKE_USED=$tmp/used HOME=$tmp "$here/tools/janitor.sh"
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
cat "$g/janitor.log"
ck "idle old workspaces removed" '[ ! -d "$g/ws/idle-old" ] && [ ! -d "$g/ws/idle-older" ]'
ck "locked workspace kept" '[ -d "$g/ws/locked" ] && grep -q "keep ws/locked (job holds" "$g/janitor.log"'
ck "recently touched workspace kept" '[ -d "$g/ws/fresh" ]'
ck "workspace with a process cwd kept" '[ -d "$g/ws/proc" ]'
ck "sib version linked from a workspace kept" '[ -d "$g/sib/lib/aaa1" ]'
ck "sib latest kept" '[ -d "$g/sib/lib/ccc3" ]'
ck "unused sib version removed" '[ ! -d "$g/sib/lib/bbb2" ]'
ck "removals logged" 'grep -q "rm ws/idle-older" "$g/janitor.log" && grep -q "rm sib/lib/bbb2" "$g/janitor.log"'
ck "keeps logged" 'grep -q "keep ws/proc" "$g/janitor.log"'
exit $((fail>0))
