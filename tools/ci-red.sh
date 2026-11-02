#!/usr/bin/env bash
# Latest completed CI run on each default branch for every repo in projects.tsv; prints red and cancelled ones.
# Uses ssh dev01 when gh is missing or logged out here (dev02). Ignores the Images workflow (SHARED_PACKAGES_TOKEN).
set -uo pipefail
if ! gh auth status >/dev/null 2>&1; then
    tsv="${PROJECTS_TSV:-$(cd "$(dirname "$0")/.." && pwd)/projects.tsv}"
    exec ssh -o BatchMode=yes dev01 "CI_RED_TSV=$(base64 -w0 "$tsv") bash -s" < "$0" 2>&1
fi
if [ -n "${CI_RED_TSV:-}" ]; then tsv="$(mktemp)"; base64 -d <<<"$CI_RED_TSV" > "$tsv"
else tsv="${PROJECTS_TSV:-$(cd "$(dirname "$0")/.." && pwd)/projects.tsv}"; fi
red=0; cancelled=()
while IFS=$'\t' read -r name url _; do
    slug="$(sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##' <<<"$url")"
    br="$(gh api "repos/$slug" --jq .default_branch 2>/dev/null)" || { echo "unknown: $name (no repo $slug)"; continue; }
    run="$(gh api "repos/$slug/actions/runs?branch=$br&status=completed&per_page=20" \
        --jq '[.workflow_runs[]|select(.name|test("images";"i")|not)][0]|select(.)|[.id,.conclusion,.name]|@tsv' 2>/dev/null)"
    [ -n "$run" ] || continue
    IFS=$'\t' read -r id concl wf <<<"$run"
    case "$concl" in
        success|skipped|neutral) ;;
        cancelled) cancelled+=("$name") ;;
        *)
            jobs="$(gh api "repos/$slug/actions/runs/$id/jobs?per_page=50" \
                --jq '[.jobs[]|select(.conclusion=="failure")|.name]|join(", ")' 2>/dev/null | cut -c1-60)"
            echo "red: $name  $wf: ${jobs:-?}  https://github.com/$slug/actions/runs/$id"
            red=$((red+1)) ;;
    esac
done < <(grep -v '^#' "$tsv" | awk -F'\t' 'NF>=2')
echo "cancelled: ${cancelled[*]:-none}"
echo "red: $red"
[ "$red" -eq 0 ]
