#!/usr/bin/env bash
# GameSpice Bootstrap tools/readme/shot.sh: the README studio run, called by a pack's tools/readme_shot.sh from the pack root.
#
#   ../dot-bootstrap/tools/readme/shot.sh [--ids a,b]    studio PNGs into screenshots/readme/, and the READMEDATA line
#   ../dot-bootstrap/tools/readme/shot.sh --data         only the READMEDATA line (headless, no GPU needed)
#
# gen_readme.sh copies this script and readme_studio.{gd,tscn} into <pack>/tools/readme_studio/ (git-ignored) before
# the run, because a GPU box gets the pack's tree and no sibling repositories; run from dot-bootstrap it copies them
# itself. It then imports the project and runs the studio. Shots need a real GPU: the pack's tools/readme_shot.sh matches gpu.sh's tools/*_shot.sh rule, so
# `heavy -- tools/readme_shot.sh` renders on staging02/staging (Vulkan, Forward+), never llvmpipe or --headless.
# README_RENDERER (default forward_plus) picks the renderer for the stills; the pack's own setting is not used.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f project.godot ]] || { echo "readme shot: run from the pack root" >&2; exit 2; }
mkdir -p tools/readme_studio
[[ $here -ef tools/readme_studio ]] || cp "$here/readme_studio.gd" "$here/readme_studio.tscn" "$here/shot.sh" tools/readme_studio/
data=0
args=()
for a in "$@"; do
	if [[ $a == --data ]]; then data=1; else args+=("$a"); fi
done
timeout 900 godot --headless --path . --import >/dev/null 2>&1 || true
timeout 300 godot --headless --path . res://tools/readme_studio/readme_studio.tscn -- --data 2>&1 | grep -E '^READMEDATA |ERROR' | head -40
[[ $data == 1 ]] && exit 0
out=screenshots/readme
mkdir -p "$out"; touch screenshots/.gdignore
rm -f "$out"/*.png
xvfb-run -a -s "-screen 0 1280x720x24" timeout 1200 godot --path . --rendering-method "${README_RENDERER:-forward_plus}" \
	--resolution 1280x720 res://tools/readme_studio/readme_studio.tscn -- --out "$PWD/$out" "${args[@]}" 2>&1 \
	| grep -E 'READMESHOT|ERROR|SCRIPT ERROR' | head -120
n=$(ls "$out"/*.png 2>/dev/null | wc -l)
if [[ $n -gt 0 ]]; then echo "readme shot: $n shot(s) in $out"; else echo "readme shot: no shots" >&2; exit 1; fi
