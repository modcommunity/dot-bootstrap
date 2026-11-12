#!/bin/bash
# Local test of tools/dot_download.ps1 (Invoke-DotDownload: own progress lines, 404, stall timeout, Range resume) and
# fetch_lock.ps1 on top of it (file i/n progress, hash-mismatch retry), against a python fixture server. Needs pwsh
# (that half is skipped without it), and fetch_lock.sh's own progress and retry lines. No network. Run: tests/test_download.sh
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; PID=
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT

# Fixture: content/o/zz-alpha/1.0.0 with three files (one served wrong the first time); /big (Range aware),
# /hang (headers, 10 bytes, then nothing), /reset (flaky again); anything else missing is a 404.
python3 -I - "$T/cdn" <<'PY'
import base64, hashlib, json, os, sys
root = sys.argv[1]; files = []
d = os.path.join(root, "content", "o", "zz-alpha", "1.0.0")
for name, data in (("a.txt", b"a" * 300000), ("sub/b.txt", b"b" * 5000), ("flaky.txt", b"flaky data")):
    sha = hashlib.sha256(data).hexdigest(); os.makedirs(os.path.join(d, "objects", sha[:2]), exist_ok=True)
    open(os.path.join(d, "objects", sha[:2], sha), "wb").write(data)
    files.append({"path": name, "sha256": sha, "size": len(data)})
payload = base64.urlsafe_b64encode(json.dumps({"files": files}).encode()).decode().rstrip("=")
m = json.dumps({"payload": payload}).encode(); open(os.path.join(d, "manifest.json"), "wb").write(m)
open(os.path.join(root, "big"), "wb").write(bytes(range(256)) * 12288)  # 3 MB
os.makedirs(os.path.join(root, "..", "repo"))
json.dump({"format": 1, "origin": "http://127.0.0.1:1/content", "packs": [{"id": "o/zz-alpha", "version": "1.0.0",
    "manifest_sha256": hashlib.sha256(m).hexdigest(), "into": ".alpha", "kind": "store"}]},
    open(os.path.join(root, "..", "repo", "content.lock.json"), "w"))
open(os.path.join(root, "flaky"), "w").write(hashlib.sha256(b"flaky data").hexdigest())
PY
cat > "$T/serve.py" <<'PY'
import os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = sys.argv[2]; flaky = open(os.path.join(root, "flaky")).read(); seen = set()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): sys.stderr.write(self.requestline + " " + str(self.headers.get("Range")) + "\n")
    def do_GET(self):
        if self.path == "/reset": seen.clear(); self.send_response(204); self.end_headers(); return
        if self.path == "/hang":
            self.send_response(200); self.send_header("Content-Length", "100"); self.end_headers()
            self.wfile.write(b"x" * 10); self.wfile.flush(); time.sleep(30); return
        p = os.path.join(root, self.path.lstrip("/"))
        if not os.path.isfile(p): self.send_error(404); return
        data = open(p, "rb").read()
        if p.endswith(flaky) and p not in seen: seen.add(p); data = b"X" * len(data)
        rng = self.headers.get("Range")
        if rng:
            start = int(rng.split("=")[1].split("-")[0])
            if start >= len(data): self.send_response(416); self.send_header("Content-Length", "0"); self.end_headers(); return
            self.send_response(206); self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data))); data = data[start:]
        else: self.send_response(200)
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        for i in range(0, len(data), 65536):  # slow enough that a 0 s progress interval prints lines
            self.wfile.write(data[i:i + 65536]); time.sleep(0.005)
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 -I "$T/serve.py" 18131 "$T/cdn" 2>"$T/server.log" & PID=$!
sleep 1
pass=0; fail=0
ok() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

# fetch_lock.sh (a copy, so its .env lookup stays in $T): the same lines as the PowerShell side.
mkdir -p "$T/boot" && cp -r "$SRC/tools" "$T/boot/" && cp -r "$T/repo" "$T/repo-sh" && rm -rf "$T/repo-sh/.alpha"
out="$(DOT_PROGRESS_SECONDS=0 timeout 60 "$T/boot/tools/fetch_lock.sh" "$T/repo-sh/content.lock.json" --cdn http://127.0.0.1:18131 2>&1)"; rc=$?
ok "fetch_lock.sh exit 0 ($rc)" "$rc"
grep -q 'fetching o/zz-alpha 1.0.0: 3 files, 0.3 MB' <<<"$out"; ok "sh header line" $?
grep -Eq 'o/zz-alpha +file [123]/3  [0-9.]+ / 0\.3 MB  [0-9.]+ MB/s  ETA ' <<<"$out"; ok "sh file i/n line" $?
grep -q 'done 0.3 MB in' <<<"$out"; ok "sh done line" $?
grep -q 'retry .*hash mismatch' <<<"$out"; ok "sh hash mismatch retried" $?
[ "$(cat "$T/repo-sh/.alpha/flaky.txt" 2>/dev/null)" = "flaky data" ] && [ -f "$T/repo-sh/.alpha/.dot-pack" ]; ok "sh files there" $?
[ "$fail" = 0 ] || echo "$out"
echo "test_download (sh): $pass passed, $fail failed"

if ! command -v pwsh >/dev/null; then echo "test_download (ps1): no pwsh, skipped"; exit $((fail > 0)); fi
curl -fsS http://127.0.0.1:18131/reset  # flaky.txt is served wrong once more
T="$T" H="$SRC" U=http://127.0.0.1:18131 timeout 180 pwsh -NoProfile -NonInteractive -File "$SRC/tests/test_download.ps1" || fail=$((fail + 1))
exit $((fail > 0))
