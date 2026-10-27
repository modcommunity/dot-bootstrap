#!/bin/bash
# Fetch exactly what a pack lock names, hash-checked, into each entry's target (resumable, present files skipped).
#   tools/fetch_lock.sh <content.lock.json> [--root DIR] [--from BASE] [--skip ID[,ID]] [--only ID[,ID]] [--packs DIR]
# --packs DIR also mirrors each kind "pack" entry to DIR/<id>/<version>/ (manifest.json + objects/), as a server serves them.
# Lock (content.lock.json, written by dot-cloud's `publish --upload --lock`): {format, origin, mirrors[], packs[{id, version,
# manifest_sha256, into, kind, optional}]}. Only kind "store" packs (files on disk at <root>/<into>) are fetched here; a "pack" is
# mounted by DotCloudClient. BASE (default: the lock's origin, then its mirrors) holds <id>/<version>/manifest.json and
# <id>/<version>/objects/<aa>/<sha256>; a folder or an https URL. --skip takes ids, `into` folders or the kind (`store`).
# $DOT_PACKS_FROM=none fetches nothing. A token file path in $DOT_PACKS_TOKEN_FILE (never the token itself) is sent as a bearer.
set -euo pipefail
LOCK="${1:?usage: fetch_lock.sh <content.lock.json> [--root DIR] [--from BASE] [--skip IDs] [--only IDs] [--packs DIR]}"; shift
ROOT="$(cd "$(dirname "$LOCK")" && pwd)"
FROM="${DOT_PACKS_FROM:-}"; SKIP=""; ONLY=""; PACKS=""
while [ $# -gt 0 ]; do
    case $1 in
        --root) ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
        --from) FROM="${2:?}"; shift 2 ;;
        --skip) SKIP="$SKIP,${2:?}"; shift 2 ;;
        --packs) PACKS="$(mkdir -p "${2:?}" && cd "$2" && pwd)"; shift 2 ;;
        --only) ONLY="$ONLY,${2:?}"; shift 2 ;;
        *) echo "fetch_lock: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ "${DOT_PACKS_FROM:-}" = none ] || [ "$FROM" = none ] && { echo "fetch_lock: DOT_PACKS_FROM=none, nothing fetched"; exit 0; }
command -v python3 >/dev/null || { echo "fetch_lock: python3 is needed" >&2; exit 2; }
exec python3 -I - "$LOCK" "$ROOT" "$FROM" "$SKIP" "$ONLY" "$PACKS" <<'PY'
import base64, hashlib, json, os, sys, time, urllib.request, urllib.error
lock, root, base, skip, only, packs = sys.argv[1:7]
skip = {s for s in skip.split(",") if s}; only = {s for s in only.split(",") if s}
doc = json.load(open(lock))
if doc.get("format") != 1: sys.exit("fetch_lock: unsupported lock format")
bases = [base] if base else [doc["origin"]] + list(doc.get("mirrors", []))
bases = [b.rstrip("/") if "://" in b else "file://" + os.path.abspath(b) for b in bases]
tok = ""
tf = os.environ.get("DOT_PACKS_TOKEN_FILE", "")
if tf: tok = open(tf).read().strip()

def get(url, start=0):
    h = {}
    if tok: h["Authorization"] = "Bearer " + tok
    if start: h["Range"] = "bytes=%d-" % start
    return urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=60)

def fetch(rel, dest, sha, retries=4):
    part = dest + ".part"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    for attempt in range(retries):
        try:
            have = os.path.getsize(part) if os.path.exists(part) else 0
            url = bases[attempt % len(bases)] + "/" + rel
            r = get(url, have)
            if have and getattr(r, "status", 200) != 206: have = 0
            with open(part, "ab" if have else "wb") as f:
                while True:
                    b = r.read(1 << 20)
                    if not b: break
                    f.write(b)
            h = hashlib.sha256()
            with open(part, "rb") as f:
                for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
            if h.hexdigest() == sha:
                os.replace(part, dest); return
            os.remove(part)
            raise IOError("hash mismatch for " + url)
        except (urllib.error.URLError, IOError, OSError) as e:
            if attempt == retries - 1: raise
            time.sleep(2 ** attempt)

bad = 0
for p in doc["packs"]:
    pid, ver, mh, into, kind = p["id"], p["version"], p["manifest_sha256"], p.get("into", ""), p.get("kind", "pack")
    if kind == "pack" and packs:
        # Mirror the origin's layout (manifest.json + objects/) so a server serves it as published.
        if skip & {pid, kind}: print("skip", pid); continue
        out = os.path.join(packs, pid, ver); stamp = os.path.join(out, ".dot-pack"); want = "%s %s %s" % (pid, ver, mh)
        if os.path.exists(stamp) and open(stamp).read().strip() == want: print("have", pid, ver); continue
        try:
            fetch("%s/%s/manifest.json" % (pid, ver), os.path.join(out, "manifest.json"), mh)
            pad = json.load(open(os.path.join(out, "manifest.json")))["payload"]; pad += "=" * (-len(pad) % 4)
            for f in json.loads(base64.urlsafe_b64decode(pad))["files"]:
                sha = f["sha256"]; dest = os.path.join(out, "objects", sha[:2], sha)
                if not os.path.exists(dest): fetch("%s/%s/objects/%s/%s" % (pid, ver, sha[:2], sha), dest, sha)
            open(stamp, "w").write(want + "\n"); print("mirrored", pid, ver)
        except Exception as e:
            print("FAILED", pid, ver, e, file=sys.stderr); bad += 1
        continue
    if kind != "store": continue
    if skip & {pid, into, kind} or (only and not only & {pid, into}): print("skip", pid); continue
    out = os.path.join(root, into); stamp = os.path.join(out, ".dot-pack")
    want = "%s %s %s" % (pid, ver, mh)
    if os.path.exists(stamp) and open(stamp).read().strip() == want:
        print("have", pid, ver); continue
    try:
        pre = "%s/%s" % (pid, ver)
        man = os.path.join(out, ".manifest.json")
        fetch(pre + "/manifest.json", man, mh)
        pad = json.load(open(man))["payload"]; pad += "=" * (-len(pad) % 4)
        files = json.loads(base64.urlsafe_b64decode(pad))["files"]
        n = 0
        for f in files:
            rel = f["path"]
            if rel.startswith("/") or ".." in rel.split("/"): raise IOError("unsafe path " + rel)
            dest = os.path.join(out, rel); sha = f["sha256"]
            if os.path.exists(dest) and os.path.getsize(dest) == f["size"]: n += 1; continue
            fetch("%s/objects/%s/%s" % (pre, sha[:2], sha), dest, sha); n += 1
        open(stamp, "w").write(want + "\n")
        os.remove(man)
        print("fetched", pid, ver, n, "files")
    except Exception as e:
        print("FAILED", pid, ver, e, file=sys.stderr); bad += 1
sys.exit(1 if bad else 0)
PY
