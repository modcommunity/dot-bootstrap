#!/usr/bin/env bash
# One source for `heavy`: nightly-env bin/heavy (installed as /usr/local/bin/heavy). tools/heavy here is the scrubbed
# public copy (the same file as nightly's scripts/heavy/heavy). This checks that tools/heavy has the same CODE as a
# reference copy; full-line comments (the scrubbed ones) and the private-only dot-bootstrap conf fallback path are
# ignored. Read-only: it never writes to any installed file.
#   check_heavy_sync.sh [REFERENCE...]   default: $HEAVY_REFERENCE, else /usr/local/bin/heavy
# Exit 0 in sync, 1 drift (diff shown), 2 reference unreadable. To fix drift: copy the public nightly copy over tools/heavy.
here=$(cd "$(dirname "$0")" && pwd)
mine=${HEAVY_COPY:-$here/heavy}
norm() { grep -vE '^[[:space:]]*#' "$1" | sed -E 's#[[:space:]]+"\$HOME/godot/dot-bootstrap/tools/realtime_suites.conf"##; s/[[:space:]]+$//'; }
[ $# -gt 0 ] || set -- "${HEAVY_REFERENCE:-/usr/local/bin/heavy}"
rc=0; tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
for ref in "$@"; do
  [ -r "$ref" ] || { echo "check_heavy_sync: cannot read $ref" >&2; rc=2; continue; }
  if diff <(norm "$ref") <(norm "$mine") >"$tmp" 2>&1; then echo "in sync with $ref"
  else echo "DRIFT vs $ref:"; head -40 "$tmp"; [ $rc = 2 ] || rc=1; fi
done
exit $rc
