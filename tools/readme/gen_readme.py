#!/usr/bin/env python3
"""Write the generated parts of a pack's README.md (dot-bootstrap tools/readme/, run by gen_readme.sh from the pack root).

Numbers come only from docs/readme/profiles.json, which the studio writes from the pack's own data (the adapter's
profile(): the effective defaults a server starts with). Words come from docs/readme/readme.yml:

  heading: The monsters            the section heading of the per-item block
  noun: Monster                    the summary table's name column
  columns: [Role, Health, Damage]  summary columns; Role is the words' `role`, the rest the profile's `summary`
  order: [id, ...]                 optional; the profile order otherwise
  items: {id: {role: .., blurb: .., poses: {bite: "caption"}}}
  summary_before: "## Using it"    where a missing block is inserted
  items_before: "## Credits"
  quality: "..."                   optional override of the 'Quality and ongoing improvement' section text (a default
                                   is emitted otherwise); quality_before: "## Credits" is where it is inserted

Two regions of README.md are replaced between their markers (added if missing):
  <!-- gen_readme:summary --> ... <!-- /gen_readme:summary -->   thumbnail, name and summary columns per item
  <!-- gen_readme:items -->   ... <!-- /gen_readme:items -->     per item: hero render, extra poses, description, defaults
Everything else (pitch, usage, credits) is left exactly as written. Image links are raw.githubusercontent.com URLs on
main for the origin remote, so the README renders on GitHub and in the GameSpice store alike.

  gen_readme.py [--check]     --check: exit 1 if README.md is out of date, write nothing
"""
import json
import os
import re
import subprocess
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stale_renders  # noqa: E402

ROOT = os.getcwd()
IMG_DIR = "docs/img"


def raw_base():
    url = subprocess.run(["git", "-C", ROOT, "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
    m = re.search(r"github\.com[:/]([^/]+)/(.+?)(?:\.git)?/?$", url)
    if not m:
        sys.exit("gen_readme: origin %r is not a GitHub remote" % url)
    return "https://raw.githubusercontent.com/%s/%s/main/" % (m.group(1), m.group(2))


def anchor(name):
    return re.sub(r"[^a-z0-9 -]", "", name.lower()).replace(" ", "-")


def splice(text, tag, content, before=None):
    start, end = "<!-- gen_readme:%s -->" % tag, "<!-- /gen_readme:%s -->" % tag
    block = "%s\n%s\n%s" % (start, content.rstrip("\n"), end)
    if start in text and end in text:
        return re.sub(re.escape(start) + r".*?" + re.escape(end), lambda _: block, text, flags=re.S)
    if before and before in text:
        i = text.index(before)
        return text[:i] + block + "\n\n" + text[i:]
    return text.rstrip("\n") + "\n\n" + block + "\n"


QUALITY_HEADING = "## Quality and ongoing improvement"
QUALITY_DEFAULT = (
    'The models, textures, animations, sounds and maps in this pack are improved automatically and recursively by AI agents. [Nightly](https://github.com/gamemann/nightly) keeps a board of improvement items. Agents pick up an item, make the change, render fresh frames and check them with a visual judge. Judge findings become new items, and the loop repeats until the result is production quality. Improvements ship as new pack versions, and the screenshots in this README are re-shot each time. Some assets are still low quality today.'
)


def quality_section(words):
    """readme.yml may override the text with a `quality:` key; every pack gets the section either way."""
    text = " ".join(str(words.get("quality") or QUALITY_DEFAULT).split())
    return QUALITY_HEADING + "\n\n" + text


def cell(v):
    return str(v).replace("|", "\\|") if v not in (None, "") else "-"


def render(words, data, base):
    ids = data["ids"]
    order = words.get("order") or []
    ids = [i for i in order if i in ids] + [i for i in ids if i not in order]
    items = data["items"]
    info = words.get("items") or {}
    cols = words.get("columns") or ["Role"]
    missing = [i for i in ids if not os.path.exists(os.path.join(ROOT, IMG_DIR, i + ".webp"))]
    if missing:
        print("gen_readme: no image yet for %s" % ", ".join(missing), file=sys.stderr)

    summary = ["| | %s | %s |" % (words.get("noun", "Item"), " | ".join(cols)),
               "| --- | --- | %s |" % " | ".join("---" for _ in cols)]
    for i in ids:
        p, w = items[i], info.get(i, {})
        name = p.get("name", i)
        vals = [w.get("role") if c == "Role" else (p.get("summary") or {}).get(c) for c in cols]
        summary.append('| <a href="#%s"><img src="%s%s/%s_thumb.webp" width="160" alt="%s"></a> | [%s](#%s) | %s |' % (
            anchor(name), base, IMG_DIR, i, name, name, anchor(name), " | ".join(cell(v) for v in vals)))

    body = ["## %s" % words.get("heading", "The items"), ""]
    for i in ids:
        p, w = items[i], info.get(i, {})
        name = p.get("name", i)
        body += ["### %s" % name, ""]
        body += ['<img src="%s%s/%s.webp" width="1280" alt="%s, studio render">' % (base, IMG_DIR, i, name), ""]
        captions = w.get("poses") or {}
        for pose in (p.get("poses") or [])[1:]:
            f = "%s_%s.webp" % (i, pose)
            if not os.path.exists(os.path.join(ROOT, IMG_DIR, f)):
                print("gen_readme: no image yet for %s" % f, file=sys.stderr)
            cap = captions.get(pose) or pose.replace("_", " ").capitalize()
            body += ['<img src="%s%s/%s" width="1280" alt="%s, %s">' % (base, IMG_DIR, f, name, cap.lower()), ""]
            body += ["*%s.*" % cap.rstrip("."), ""]
        desc = (w.get("blurb") or "").strip()
        role = w.get("role")
        body += [("**%s** `%s`" % (role, i) if role else "`%s`" % i) + ((". " + desc) if desc else ""), ""]
        body += ["| Default | |", "| --- | --- |"]
        for label, value in p.get("rows") or []:
            body.append("| %s | %s |" % (cell(label), cell(value)))
        body.append("")
    return "\n".join(summary) + "\n", "\n".join(body)


def main():
    check = "--check" in sys.argv
    wpath = os.path.join(ROOT, "docs/readme/readme.yml")
    words = yaml.safe_load(open(wpath, encoding="utf-8")) if os.path.exists(wpath) else {}
    dpath = os.path.join(ROOT, "docs/readme/profiles.json")
    if not os.path.exists(dpath):
        sys.exit("gen_readme: no docs/readme/profiles.json; run tools/gen_readme.sh --data first")
    data = json.load(open(dpath, encoding="utf-8"))
    summary, body = render(words, data, raw_base())
    path = os.path.join(ROOT, "README.md")
    old = open(path, encoding="utf-8").read()
    new = splice(old, "summary", summary, before=words.get("summary_before", "## Using it"))
    new = splice(new, "items", body, before=words.get("items_before", "## Credits"))
    if check and "<!-- gen_readme:quality -->" not in old:
        print("gen_readme: README.md has no '%s' section; run tools/gen_readme.sh --text" % QUALITY_HEADING, file=sys.stderr)
        sys.exit(1)
    new = splice(new, "quality", quality_section(words), before=words.get("quality_before", "## Credits"))
    # Owner rule: no repo-name H1 first line (GitHub already shows the name). Strip one if present.
    first = new.split("\n", 1)[0]
    if first.startswith("# "):
        new = new.split("\n", 1)[1].lstrip("\n")
        if check:
            print("gen_readme: README.md starts with an H1 (%s); remove it" % first, file=sys.stderr)
            sys.exit(1)
    if check:
        stale_renders.warn(ROOT)
        if new != old:
            print("gen_readme: README.md is out of date; run tools/gen_readme.sh --text", file=sys.stderr)
            sys.exit(1)
        return
    if new != old:
        open(path, "w", encoding="utf-8").write(new)
        print("gen_readme: wrote README.md")
    else:
        print("gen_readme: README.md already up to date")


if __name__ == "__main__":
    main()
