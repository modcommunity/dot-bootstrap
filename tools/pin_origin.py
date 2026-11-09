#!/usr/bin/env python3
"""Pin the manifest hash a CDN serves into a lock, next to the (prod) default.
  tools/pin_origin.py content.lock.json [--cdn https://dev.dotgames.org] [--only ID]...
Adds "manifest_sha256_by_origin": {"<cdn>/content": "<sha>"} to each entry whose manifest that CDN serves and whose hash differs
from manifest_sha256 (or removes a stale mapping when they are equal). manifest_sha256 itself is never changed. Entries the CDN
does not serve are listed and left alone. Exit 1 if any entry is missing."""
import argparse, hashlib, json, sys, urllib.request, urllib.error
a = argparse.ArgumentParser()
a.add_argument("lock"); a.add_argument("--cdn", default="https://dev.dotgames.org"); a.add_argument("--only", action="append", default=[])
o = a.parse_args()
base = o.cdn.rstrip("/")
if not base.endswith("/content"): base += "/content"
d = json.load(open(o.lock)); miss = 0
for p in d["packs"]:
    if o.only and p["id"] not in o.only: continue
    try:
        r = urllib.request.urlopen(urllib.request.Request(f"{base}/{p['id']}/{p['version']}/manifest.json", headers={"User-Agent": "pin_origin/1"}), timeout=30).read()
    except urllib.error.HTTPError as e:
        print(f"missing {p['id']}@{p['version']} ({e.code})", file=sys.stderr); miss += 1; continue
    h = hashlib.sha256(r).hexdigest(); m = p.get("manifest_sha256_by_origin") or {}
    if h == p["manifest_sha256"]: m.pop(base, None)
    else: m[base] = h
    if m: p["manifest_sha256_by_origin"] = m
    else: p.pop("manifest_sha256_by_origin", None)
open(o.lock, "w").write(json.dumps(d, indent="\t", sort_keys=True) + "\n")
sys.exit(1 if miss else 0)
