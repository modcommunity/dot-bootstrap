#!/usr/bin/env bash
# Cron wrapper for sync_checkouts.sh, run as christian (who can reach the board): */15 * * * * <this file>
# Reads the live board claims into a file, runs the sync as gamedev (the checkouts' owner) with it, and posts any
# DRIFT lines to the board as agent checkout-sync, once per change (identical text is not re-posted).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; chmod 755 "$tmp"
nightly agent board 2>/dev/null | sed '/^STALE CLAIMS/,$d' | grep -o 'godot/[A-Za-z0-9_.-]*' | sed 's|godot/||' | sort -u > "$tmp/held"; chmod 644 "$tmp/held"
sudo -n -u gamedev env SYNC_HELD_FILE="$tmp/held" "$here/sync_checkouts.sh" --apply --quiet > "$tmp/out" 2>&1
grep -E '^(ff|DRIFT) ' "$tmp/out" >> "$HOME/.cache/sync-checkouts.log" 2>/dev/null
grep '^DRIFT ' "$tmp/out" | sed 's/^DRIFT //' | sort > "$tmp/drift"
[ -s "$tmp/drift" ] || exit 0
state="$HOME/.cache/sync-checkouts.last"
cmp -s "$tmp/drift" "$state" && exit 0
cp "$tmp/drift" "$state"
nightly agent join checkout-sync --task "fast-forwards shared checkouts, reports drift" >/dev/null 2>&1
{ echo "checkout drift (tools/sync_checkouts_cron.sh); fix the checkout or finish the claim:"; cat "$tmp/drift"; } | nightly agent say checkout-sync >/dev/null 2>&1
