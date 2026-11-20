#!/usr/bin/env bash
# GameSpice Bootstrap tools/readme/gen_readme.sh: regenerate a pack's README gallery. A pack's tools/gen_readme.sh execs this
# from the pack root.
#
#   tools/gen_readme.sh                  capture every item on a GPU box, refresh the data, convert, rewrite README.md
#   tools/gen_readme.sh --ids a,b        recapture only these
#   tools/gen_readme.sh --data           no capture: refresh docs/readme/profiles.json from the pack, rewrite README.md
#   tools/gen_readme.sh --text           no Godot at all: rewrite README.md from docs/readme/profiles.json
#   tools/gen_readme.sh --check          exit 1 if README.md is out of date with profiles.json (CI)
#
# Pack files: tools/readme.cfg (studio settings, poses), tools/readme_adapter.gd (ids, models, poses, profile rows),
# docs/readme/readme.yml (roles, blurbs, headings), tools/readme_shot.sh (calls ../dot-bootstrap/tools/readme/shot.sh).
# Each PNG becomes docs/img/<name>.webp (1280 px) and, for the hero, docs/img/<id>_thumb.webp (320 px). Images live
# under docs/img/ (with a .gdignore) so they never ship in the pack. Look at every image before committing.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f project.godot ]] || { echo "gen_readme: run from the pack root" >&2; exit 2; }

mode=all
ids=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--text) mode=text ;;
		--data) mode=data ;;
		--check) exec python3 "$here/gen_readme.py" --check ;;
		--ids) ids=$2; shift ;;
		*) echo "gen_readme: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done

run_shot() {  # args for tools/readme_shot.sh; prints its output
	# The box gets this pack's tree only, so the studio travels inside it (git-ignored).
	mkdir -p tools/readme_studio
	cp "$here/readme_studio.gd" "$here/readme_studio.tscn" "$here/shot.sh" tools/readme_studio/
	if command -v heavy >/dev/null; then heavy -- tools/readme_shot.sh "$@"; else
		echo "gen_readme: no heavy here; running locally (shots need a real GPU)" >&2
		tools/readme_shot.sh "$@"
	fi
}

save_data() {  # the READMEDATA line from stdin into docs/readme/profiles.json
	mkdir -p docs/readme
	python3 -c '
import json, sys
for line in sys.stdin:
    if line.startswith("READMEDATA "):
        d = json.loads(line[len("READMEDATA "):])
        json.dump(d, open("docs/readme/profiles.json", "w"), indent=1, sort_keys=False)
        open("docs/readme/profiles.json", "a").write("\n")
        print("gen_readme: %d profile(s) in docs/readme/profiles.json" % len(d["ids"]))
        sys.exit(0)
sys.exit("gen_readme: the run printed no READMEDATA line")'
}

log=$(mktemp)
trap 'rm -f "$log"' EXIT
if [[ $mode == data ]]; then
	run_shot --data | tee "$log"
	save_data < "$log"
elif [[ $mode == all ]]; then
	command -v magick >/dev/null || { echo "gen_readme: needs ImageMagick 7 (magick) with WebP" >&2; exit 2; }
	rm -f screenshots/readme/*.png
	args=()
	[[ -n $ids ]] && args=(--ids "$ids")
	run_shot "${args[@]}" | tee "$log"
	save_data < "$log"
	mkdir -p docs/img
	[[ -e docs/img/.gdignore ]] || : > docs/img/.gdignore
	n=0
	for png in screenshots/readme/*.png; do
		[[ -e $png ]] || continue
		name=$(basename "$png" .png)
		magick "$png" -strip -resize '1280x>' -quality 82 -define webp:method=6 "docs/img/$name.webp"
		# A thumbnail for the hero (the first pose) only: <id>.png, never <id>_<pose>.png.
		if python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(open("docs/readme/profiles.json"))["items"] else 1)' "$name"; then
			magick "$png" -strip -resize 320x -quality 80 -define webp:method=6 "docs/img/${name}_thumb.webp"
		fi
		n=$((n + 1))
	done
	[[ $n -gt 0 ]] || { echo "gen_readme: the capture produced no images" >&2; exit 1; }
	echo "gen_readme: $n image(s) in docs/img"
fi
python3 "$here/gen_readme.py"
