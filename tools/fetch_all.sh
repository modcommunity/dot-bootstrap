#!/bin/bash
# Fetch every repository's content.lock.json in the tree (games, addons, map repos, packs): the all-in-one run.
#   tools/fetch_all.sh [--projects DIR] [--only ITEM[,ITEM]] [--except ITEM[,ITEM]] [--cdn URL] [--list]
# ITEM matches a repository name, a pack id, its name half, its `into` folder or its kind; globs allowed
# (`--only 'zombie-*'`, `--except zombie-zone-maps,zz-stores`). Everything else (cfg/content lists, .env URL, hashes) is fetch_lock.sh's.
# Packs are mirrored into dot-server-deploy/content/packs when that folder's repository is present.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS="$(cd "$HERE/../.." && pwd)"; ARGS=()
while [ $# -gt 0 ]; do
    case $1 in
        --projects) PROJECTS="$(cd "${2:?}" && pwd)"; shift 2 ;;
        --only|--except|--skip|--cdn) ARGS+=("$1" "${2:?}"); shift 2 ;;
        --list) ARGS+=(--list); shift ;;
        *) echo "fetch_all: unknown argument $1" >&2; exit 2 ;;
    esac
done
bad=0; n=0
for lock in "$PROJECTS"/*/content.lock.json; do
    [ -f "$lock" ] || continue
    dir="$(dirname "$lock")"; extra=()
    [ -d "$PROJECTS/dot-server-deploy" ] && extra+=(--packs "$PROJECTS/dot-server-deploy/content/packs")
    [ -d "$PROJECTS/dot-server-deploy/cfg" ] && [ ! -d "$dir/cfg" ] && extra+=(--cfg "$PROJECTS/dot-server-deploy/cfg")
    echo "== $(basename "$dir")"; n=$((n + 1))
    "$HERE/fetch_lock.sh" "$lock" ${extra[@]+"${extra[@]}"} ${ARGS[@]+"${ARGS[@]}"} || bad=$((bad + 1))
done
[ "$n" -gt 0 ] || echo "fetch_all: no content.lock.json under $PROJECTS"
echo "fetch_all: $n lock files, $bad failed"; exit $((bad > 0))
