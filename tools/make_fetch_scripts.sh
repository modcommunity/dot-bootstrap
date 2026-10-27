#!/bin/bash
# Give every repository that has a content.lock.json its fetch-content.sh / fetch-content.ps1 (copies of tools/templates).
#   tools/make_fetch_scripts.sh [--projects DIR] [--check]      --check lists repos missing a script and exits 1
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; PROJECTS="$(cd "$HERE/../.." && pwd)"; CHECK=0
while [ $# -gt 0 ]; do case $1 in --projects) PROJECTS="$(cd "${2:?}" && pwd)"; shift 2 ;; --check) CHECK=1; shift ;; *) echo "unknown argument $1" >&2; exit 2 ;; esac; done
miss=0
for lock in "$PROJECTS"/*/content.lock.json; do
    [ -f "$lock" ] || continue; d="$(dirname "$lock")"
    for f in fetch-content.sh fetch-content.ps1; do
        [ -f "$d/$f" ] && continue
        if [ "$CHECK" = 1 ]; then echo "missing: $(basename "$d")/$f"; miss=1
        else cp "$HERE/templates/$f" "$d/$f"; [ "$f" = fetch-content.sh ] && chmod +x "$d/$f"; echo "wrote $(basename "$d")/$f"; fi
    done
done
exit $miss
