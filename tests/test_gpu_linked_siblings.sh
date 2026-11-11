#!/usr/bin/env bash
# gpu.sh linked_siblings: which links of a project are relinked to a staged sibling on the box instead of copied.
# A link one level down is relinked only when it names a WHOLE sibling repo (games/zz -> ../../zz-maps); a link to a
# folder inside one (maps/imported_dm -> ../../dm-maps/maps, whose content is git-ignored and so never staged, or
# addons/dot_x -> ../../dot-x/addons/dot_x) stays a --copy-links copy. Regression: 2026-11-10 crackhouse and
# dm-morpheus were "not found" on ph because maps/imported_dm was relinked to a staged arena-dm-maps with no maps/.
# No boxes needed. Leaves its small scratch tree in $TMPDIR.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
root=$(mktemp -d)
for r in game-x dm-maps zz-maps dot-x; do mkdir -p "$root/$r" && git -C "$root/$r" init -q; done
mkdir -p "$root/dm-maps/maps/crackhouse" "$root/dm-maps/worlds" "$root/dot-x/addons/dot_x"
printf '/maps/*\n' > "$root/dm-maps/.gitignore"
: > "$root/dm-maps/maps/crackhouse/crackhouse.json"
p=$root/game-x
mkdir -p "$p/maps" "$p/games" "$p/addons"
ln -s ../dm-maps/worlds "$p/worlds_dm"
ln -s ../../dm-maps/maps "$p/maps/imported_dm"
ln -s ../../zz-maps "$p/games/zz-maps"
ln -s ../../dot-x/addons/dot_x "$p/addons/dot_x"
ln -s "$root/zz-maps/" "$p/games/zz-abs"

got=$(ROOT=$root bash -c 'eval "$(sed -n "/^linked_siblings() {/,/^}/p" "$0")"; linked_siblings "$1"' "$src" "$p" | sort)
want=$(printf '%s\n' \
	"dm-maps	worlds_dm	../dm-maps/worlds" \
	"zz-maps	games/zz-abs	../../zz-maps/" \
	"zz-maps	games/zz-maps	../../zz-maps" | sort)
fail=0
if [[ $got == "$want" ]]; then echo "ok   linked_siblings relinks whole-repo links and top-level folder links only"
else echo "FAIL linked_siblings"; echo "  want:"; sed 's/^/    /' <<<"$want"; echo "  got:"; sed 's/^/    /' <<<"$got"; fail=1; fi
for l in maps/imported_dm addons/dot_x; do
	if grep -q "	$l	" <<<"$got"; then echo "FAIL $l would be relinked (its git-ignored content never reaches the box)"; fail=1
	else echo "ok   $l stays a --copy-links copy"; fi
done
[[ $fail == 0 ]] && echo "all passed" || { echo "failed"; exit 1; }
