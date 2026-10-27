#!/bin/bash
# Local test of fetch_lock.sh / fetch_all.sh: CDN URL precedence and --only/--except, against python http.server fixtures.
# No network, nothing published. Run: tests/test_fetch.sh
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; PIDS=(); pass=0; fail=0
trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"' EXIT
ok() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

# Fixture CDN: content/<id>/<ver>/{manifest.json,objects/aa/sha} for two store packs.
python3 -I - "$T/cdn" <<'PY'
import base64, hashlib, json, os, sys
root = sys.argv[1]; lock = []
for pid, into, data in (("o/zz-alpha", ".alpha", b"alpha data"), ("o/zz-beta", ".beta", b"beta data")):
    sha = hashlib.sha256(data).hexdigest()
    d = os.path.join(root, "content", pid, "1.0.0"); os.makedirs(os.path.join(d, "objects", sha[:2]))
    open(os.path.join(d, "objects", sha[:2], sha), "wb").write(data)
    payload = base64.urlsafe_b64encode(json.dumps({"files": [{"path": "f.txt", "sha256": sha, "size": len(data)}]}).encode()).decode().rstrip("=")
    m = json.dumps({"payload": payload}).encode(); open(os.path.join(d, "manifest.json"), "wb").write(m)
    lock.append({"id": pid, "version": "1.0.0", "manifest_sha256": hashlib.sha256(m).hexdigest(), "into": into, "kind": "store"})
os.makedirs(os.path.join(root, "..", "repoA")); os.makedirs(os.path.join(root, "..", "repoB"))
for r in ("repoA", "repoB"):
    json.dump({"format": 1, "origin": "http://127.0.0.1:1/content", "packs": lock}, open(os.path.join(root, "..", r, "content.lock.json"), "w"))
PY
serve() { # port logfile
    (cd "$T/cdn" && exec python3 -m http.server "$1" --bind 127.0.0.1 >/dev/null 2>"$2") & PIDS+=($!)
}
for p in 18101 18102 18103; do serve $p "$T/log$p"; done
sleep 1
hits() { grep -c 'GET' "$T/log$1" 2>/dev/null || true; }
reset() { : > "$T/log18101"; : > "$T/log18102"; : > "$T/log18103"; rm -rf "$T/repoA/.alpha" "$T/repoA/.beta" "$T/repoB/.alpha" "$T/repoB/.beta"; }

# Copy the tools so dot-bootstrap/.env can be written beside them.
mkdir -p "$T/dot-bootstrap" && cp -r "$SRC/tools" "$T/dot-bootstrap/"
F="$T/dot-bootstrap/tools/fetch_lock.sh"; L="$T/repoA/content.lock.json"
unset DOT_CDN_URL DOT_PACKS_FROM

reset; echo "DOT_CDN_URL=http://127.0.0.1:18102" > "$T/dot-bootstrap/.env"
DOT_CDN_URL=http://127.0.0.1:18103 "$F" "$L" --cdn http://127.0.0.1:18101 >/dev/null 2>&1
[ "$(hits 18101)" -gt 0 ] && [ "$(hits 18102)" = 0 ] && [ "$(hits 18103)" = 0 ]; ok "arg beats env and .env" $?

reset; DOT_CDN_URL=http://127.0.0.1:18103 "$F" "$L" >/dev/null 2>&1
[ "$(hits 18103)" -gt 0 ] && [ "$(hits 18102)" = 0 ]; ok "env beats .env" $?

reset; "$F" "$L" >/dev/null 2>&1
[ "$(hits 18102)" -gt 0 ] && [ "$(hits 18101)" = 0 ] && [ -f "$T/repoA/.alpha/f.txt" ]; ok ".env beats lock origin and fetches" $?

reset; rm "$T/dot-bootstrap/.env"; "$F" "$L" >/dev/null 2>&1
[ ! -f "$T/repoA/.alpha/f.txt" ]; ok "no override: dead lock origin fetches nothing" $?

# --only / --except
reset; "$F" "$L" --cdn http://127.0.0.1:18101 --only 'zz-al*' >/dev/null 2>&1
[ -f "$T/repoA/.alpha/f.txt" ] && [ ! -e "$T/repoA/.beta" ]; ok "--only glob" $?
reset; "$F" "$L" --cdn http://127.0.0.1:18101 --except 'o/zz-alpha' >/dev/null 2>&1
[ ! -e "$T/repoA/.alpha" ] && [ -f "$T/repoA/.beta/f.txt" ]; ok "--except id" $?
reset; "$F" "$L" --cdn http://127.0.0.1:18101 --list --except '.beta' | grep -q '^skip  *o/zz-beta'; ok "--list reports skip" $?

# cfg/content lists
reset; mkdir -p "$T/repoA/cfg/content"; printf 'remove:\n  - o/zz-beta\n' > "$T/repoA/cfg/content/addons.yml"
"$F" "$L" --cdn http://127.0.0.1:18101 >/dev/null 2>&1
[ -f "$T/repoA/.alpha/f.txt" ] && [ ! -e "$T/repoA/.beta" ]; ok "cfg remove:" $?
rm -rf "$T/repoA/cfg"

# fetch_all over two repos
reset; "$T/dot-bootstrap/tools/fetch_all.sh" --projects "$T" --cdn http://127.0.0.1:18101 --only repoB --except zz-beta >/dev/null 2>&1
[ -f "$T/repoB/.alpha/f.txt" ] && [ ! -e "$T/repoB/.beta" ] && [ ! -e "$T/repoA/.alpha" ]; ok "fetch_all --only repo --except pack" $?

echo "test_fetch: $pass passed, $fail failed"; [ "$fail" = 0 ]
