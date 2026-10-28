#!/bin/bash
# THE one fetcher: fetch exactly what a repo's content.lock.json names, hash-checked, once (resumable, present files skipped).
#   tools/fetch_lock.sh <content.lock.json> [--root DIR] [--from BASE|--cdn URL] [--cfg DIR] [--skip|--except ITEM[,ITEM]]
#                       [--only ITEM[,ITEM]] [--packs DIR] [--list]
# Lock (written by dot-cloud's `publish --upload --lock`, format in dot-cloud docs/cdn-publish.md): {format, origin, mirrors[],
# packs[{id, version, manifest_sha256, into, kind, optional}]}. kind "store" files are written to <root>/<into>; a kind "pack" is
# mirrored to --packs DIR/<id>/<version>/ (manifest.json + objects/) when given, else left for DotCloudClient to mount.
# WHERE FROM, first set wins: --from BASE (a folder or a full origin URL), $DOT_PACKS_FROM (`none` fetches nothing),
#   --cdn URL / $DOT_CDN_URL, DOT_CDN_URL in dot-bootstrap/.env (beside this tools/ folder; one edit for every repo), the lock's
#   own `origin` then its `mirrors`, https://dotgames.org. A CDN URL is the site root: "/content" is added unless it ends in it.
# WHAT: ITEM is a pack id, its name half, its `into` folder, its kind or the repo (the lock's folder name); globs allowed
#   (`gamemann/zz-*`). --only keeps matches, --skip/--except drops them. With --cfg DIR (default <lock folder>/cfg) the
#   download lists drop too: a `remove:` entry in cfg/content/{addons,games}.yml (or cfg/server/content/), a
#   cfg/content/<item>/disabled file, and, when a games.yml/addons.yml without `merge: true` names `pack:` entries, every
#   kind "pack" it does not name. Names a lock does not pin are not fetched here (./server install-games does those).
# A token file path in $DOT_PACKS_TOKEN_FILE (never the token itself) is sent as a bearer.
set -euo pipefail
LOCK="${1:?usage: fetch_lock.sh <content.lock.json> [--root DIR] [--from BASE|--cdn URL] [--cfg DIR] [--skip IDs] [--only IDs] [--packs DIR] [--list]}"; shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; CFG=""; CDN="${DOT_CDN_URL:-}"; LIST=0
[ -f "$LOCK" ] || { echo "fetch_lock: no $LOCK, nothing pinned"; exit 0; }
ROOT="$(cd "$(dirname "$LOCK")" && pwd)"
FROM="${DOT_PACKS_FROM:-}"; SKIP=""; ONLY=""; PACKS=""
while [ $# -gt 0 ]; do
    case $1 in
        --root) ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
        --from) FROM="${2:?}"; shift 2 ;;
        --skip|--except) SKIP="$SKIP,${2:?}"; shift 2 ;;
        --packs) PACKS="$(mkdir -p "${2:?}" && cd "$2" && pwd)"; shift 2 ;;
        --cdn) CDN="${2:?}"; shift 2 ;;
        --cfg) CFG="${2:?}"; shift 2 ;;
        --list) LIST=1; shift ;;
        --only) ONLY="$ONLY,${2:?}"; shift 2 ;;
        *) echo "fetch_lock: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ "${DOT_PACKS_FROM:-}" = none ] || [ "$FROM" = none ] && { echo "fetch_lock: DOT_PACKS_FROM=none, nothing fetched"; exit 0; }
command -v python3 >/dev/null || { echo "fetch_lock: python3 is needed" >&2; exit 2; }
exec python3 -I - "$LOCK" "$ROOT" "$FROM" "$SKIP" "$ONLY" "$PACKS" "$HERE" "$CFG" "$CDN" "$LIST" <<'PY'
import base64, fnmatch, hashlib, json, os, sys, time, urllib.request, urllib.error, zlib
lock, root, base, skip, only, packs, here, cfg, cdn, listing = sys.argv[1:11]
skip = {s for s in skip.split(",") if s}; only = {s for s in only.split(",") if s}
doc = json.load(open(lock))
if doc.get("format") != 1: sys.exit("fetch_lock: unsupported lock format")

def dotenv(path):
    out = {}
    if os.path.isfile(path):
        for ln in open(path):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1); out[k.strip()] = v.strip().strip("\"'")
    return out

env = dotenv(os.path.join(here, ".env"))
if not base and not cdn: cdn = env.get("DOT_CDN_URL", "")
if not base and not cdn: base = env.get("DOT_PACKS_FROM", "")
if cdn and not base:
    base = cdn.rstrip("/")
    if "://" in base and not base.endswith("/content"): base += "/content"
if base == "none": print("fetch_lock: DOT_PACKS_FROM=none, nothing fetched"); sys.exit(0)
bases = [base] if base else ([doc["origin"]] if doc.get("origin") else ["https://dotgames.org/content"]) + list(doc.get("mirrors", []))
bases = [b.rstrip("/") if "://" in b else "file://" + os.path.abspath(b) for b in bases]
repo = os.path.basename(os.path.dirname(os.path.abspath(lock)))

def read_list(path):
    # The subset of yml the download lists use: merge:, remove: and entries: (flow or block; bare, repo: or pack: items).
    merge, rem, ents, key = False, [], [], None
    def ident(v):
        v = v.strip().strip("\"'"); return v.split("@")[0]
    for ln in open(path):
        ln = ln.split(" #")[0].rstrip()
        t = ln.strip()
        if not t or t.startswith("#"): continue
        if not ln.startswith((" ", "-")) and ":" in t:
            k, v = [x.strip() for x in t.split(":", 1)]
            key = k
            if k == "merge": merge = v.lower() == "true"
            elif k in ("remove", "entries") and v.startswith("["):
                for x in v.strip("[]").split(","):
                    if x.strip(): (rem if k == "remove" else ents).append(("pack" if "/" in x else "repo", ident(x)))
            continue
        if t.startswith("- "): t = t[2:].strip()
        elif t.startswith("-"): t = t[1:].strip()
        if ":" in t:
            k, v = [x.strip() for x in t.split(":", 1)]
            if k in ("repo", "pack") and key == "entries": ents.append((k, ident(v)))
        elif key == "remove": rem.append(("pack" if "/" in t else "repo", ident(t)))
        elif key == "entries": ents.append(("pack" if "/" in t else "repo", ident(t)))
    return merge, rem, ents

if not cfg and os.path.isdir(os.path.join(os.path.dirname(os.path.abspath(lock)), "cfg")): cfg = os.path.join(os.path.dirname(os.path.abspath(lock)), "cfg")
removed, named = [], None
if cfg:
    for kind in ("addons", "games"):
        for layer in ("content", "server/content"):
            f = os.path.join(cfg, layer, kind + ".yml")
            if not os.path.isfile(f): continue
            merge, rem, ents = read_list(f)
            removed += [i for _, i in rem]
            pk = [i for k, i in ents if k == "pack"]
            if not merge and pk: named = pk
            elif merge and pk and named is not None: named += pk

def names(p):
    pid = p["id"]
    return {pid, pid.split("/")[-1], p.get("into", ""), p.get("kind", "pack"), repo} - {""}

def hit(p, pats): return any(fnmatch.fnmatchcase(n, g) for g in pats for n in names(p))

def wanted(p):
    # Returns "" when fetched, else why not.
    if only and not hit(p, only): return "not in --only"
    if hit(p, skip): return "--skip"
    if hit(p, removed): return "removed in cfg/content"
    if cfg and os.path.isdir(os.path.join(cfg, "content", p["id"].split("/")[-1])) and os.path.exists(os.path.join(cfg, "content", p["id"].split("/")[-1], "disabled")): return "cfg/content/%s/disabled" % p["id"].split("/")[-1]
    if named is not None and p.get("kind", "pack") == "pack" and not any(fnmatch.fnmatchcase(p["id"], g) or fnmatch.fnmatchcase(p["id"].split("/")[-1], g) for g in named): return "not named in cfg/content"
    return ""

if listing == "1":
    for p in doc["packs"]:
        w = wanted(p); print("%s %s %s %s" % ("skip " if w else "fetch", p["id"], p["version"], w))
    sys.exit(0)
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
            # The site stores some objects gzip-encoded and the CDN sends them so whatever was asked;
            # the sha256 names the decoded bytes, and a range of a gzip stream cannot be resumed.
            gz = r.headers.get("Content-Encoding", "").lower() == "gzip"
            if gz and have: r.close(); r = get(url); have = 0
            if have and getattr(r, "status", 200) != 206: have = 0
            z = zlib.decompressobj(31) if gz else None
            with open(part, "ab" if have else "wb") as f:
                while True:
                    b = r.read(1 << 20)
                    if not b: break
                    f.write(z.decompress(b) if z else b)
                if z: f.write(z.flush())
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
        w = wanted(p)
        if w: print("skip", pid, "(%s)" % w); continue
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
    w = wanted(p)
    if w: print("skip", pid, "(%s)" % w); continue
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
