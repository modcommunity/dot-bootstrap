#!/usr/bin/env bash
# gpu.sh publish helpers without any box: .gpu-siblings / GPU_SIBLINGS are copied as siblings, and a
# --host-addons publish whose addon links are named by repo (not folder) stays local.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/game-x/addons" "$root/dot-core/addons/dot_core" "$root/zee-dot-weapons/addons/zee_weapons"
ln -s ../../dot-core/addons/dot_core "$root/game-x/addons/dot_core"
fns() { eval "$(sed -n '/^publish_extra_siblings() {/,/^}/p;/^publish_host_addons_resolves() {/,/^}/p' "$src")"; }
fail=0
chk() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
printf 'dot-ci  # CI\n\nmaps-repo\n' > "$root/game-x/.gpu-siblings"
got=$(fns; GPU_SIBLINGS="extra-a extra-b" publish_extra_siblings "$root/game-x" | tr '\n' ' ')
chk "extra siblings from file and env: $got" '[[ $got == "dot-ci maps-repo extra-a extra-b " ]]'
got=$(fns; GPU_SIBLINGS= publish_extra_siblings "$root/dot-core" | wc -l)
chk "no .gpu-siblings gives none" '[[ $got == 0 ]]'
chk "link whose repo matches its folder resolves" '(fns; publish_host_addons_resolves "$root/game-x")'
ln -s ../../zee-dot-weapons/addons/zee_weapons "$root/game-x/addons/zee_weapons"
chk "zee_weapons linked from zee-dot-weapons stays local" '! (fns; publish_host_addons_resolves "$root/game-x")'
rm "$root/game-x/addons/zee_weapons"; chk "back to matching links resolves" '(fns; publish_host_addons_resolves "$root/game-x")'
exit $((fail>0))
