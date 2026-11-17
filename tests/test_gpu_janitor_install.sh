#!/usr/bin/env bash
# gpu.sh janitor-install against a fake box (ssh runs the command locally with HOME in a temp dir and a fake crontab):
# the script lands as ~/gpu/janitor.sh (executable) and the cron entry is added once, however often it runs.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/heavy"
printf '#!/bin/sh\nfor last; do :; done\nexec env HOME=%s bash -c "$last"\n' "$tmp/home" > "$tmp/bin/ssh"
printf '#!/bin/sh\nf=%s/tab\nif [ "$1" = - ]; then cat > "$f"; else cat "$f" 2>/dev/null || exit 1; fi\n' "$tmp/home" > "$tmp/bin/crontab"
chmod +x "$tmp/bin/ssh" "$tmp/bin/crontab"
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
run() { PATH="$tmp/bin:$PATH" HEAVY_DIR=$tmp/heavy GPU_KEY=$tmp/nokey GPU_PROBE_TIMEOUT=10 "$here/tools/gpu.sh" janitor-install staging 2>&1; }
run >/dev/null; run >/dev/null
ck "janitor.sh installed and executable" '[ -x "$tmp/home/gpu/janitor.sh" ] && cmp -s "$tmp/home/gpu/janitor.sh" "$here/tools/janitor.sh"'
ck "exactly one cron entry" '[ "$(grep -c "gpu/janitor.sh" "$tmp/home/tab")" = 1 ]'
exit $((fail>0))
