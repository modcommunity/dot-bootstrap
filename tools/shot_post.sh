#!/usr/bin/env bash
# Posts a screenshot and its motion to Nightly -> Review: the still, plus an mp4 made from "<still>.seq/NNN.png" (DotShotSeq).
#   shot_post.sh KEY ENTRY STILL.png [--title T] [--look "what to look for"] [--metrics '{"fps":60}'] [--fps N] [--variant before|after] [--label L]
# Env: QA_URL, QA_USER, QA_PASSWORD as for review-post.sh. Run tools/screenshot.sh with DOT_SHOT_FRAMES=16 DOT_SHOT_SECS=2 first.
set -euo pipefail
[ $# -ge 3 ] || { sed -n 2,5p "$0"; exit 2; }
key=$1; entry=$2; still=$3; shift 3
title=$entry; look=""; metrics=""; fps=""; variant=""; label=""
while [ $# -gt 0 ]; do
  case $1 in
    --title) title=$2 ;; --look) look=$2 ;; --metrics) metrics=$2 ;; --fps) fps=$2 ;; --variant) variant=$2 ;; --label) label=$2 ;;
    *) echo "shot_post: unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
[ -f "$still" ] || { echo "shot_post: no such file $still" >&2; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
poster=$work/review-post.sh
ssh -o BatchMode=yes dev01 'cat ~/stack/nightly/scripts/review-post.sh' > "$poster" && chmod +x "$poster" || { echo "shot_post: cannot fetch review-post.sh" >&2; exit 1; }
extra=(); [ -n "$variant" ] && extra+=(--variant "$variant"); [ -n "$look" ] && extra+=(--look "$look"); [ -n "$metrics" ] && extra+=(--metrics "$metrics")
[ -n "$label" ] || label=$(basename "$still" .png)
"$poster" new "$key" "$key" >/dev/null 2>&1 || true
"$poster" media "$key" "$entry" "$still" --slot screenshot --label "$label" --title "$title" ${extra[@]+"${extra[@]}"} >/dev/null
seq=${still%.png}.seq
if [ -d "$seq" ] && ls "$seq"/*.png >/dev/null 2>&1; then
  n=$(ls "$seq"/*.png | wc -l)
  rate=${fps:-$(awk -v n="$n" -v s="${DOT_SHOT_SECS:-2}" 'BEGIN{r=n/s; if (r<4) r=4; printf "%d", r+0.5}')}
  ffmpeg -v error -y -framerate "$rate" -i "$seq/%03d.png" -c:v libx264 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -movflags +faststart "$work/$label.mp4"
  "$poster" media "$key" "$entry" "$work/$label.mp4" --slot clip --label "$label" ${extra[@]+"${extra[@]}"} >/dev/null
  echo "shot_post: $label still + $n-frame mp4 -> $key/$entry"
else
  echo "shot_post: $label still only (no $seq)"
fi
