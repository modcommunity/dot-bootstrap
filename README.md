Some useful bootstrap scripts for TMC's [Dot assets](https://moddingcommunity.com/co/4-dot-assets).

Each Dot project is its own Git repository, deliberately — an addon is consumed by
copying its `addons/<name>/` folder, and nothing should be able to clone the whole
family as one unit. The cost of that rule is thirty-odd clones and a hundred-odd
addon symlinks per machine. These scripts are the one place that knowledge lives.

- [`./bootstrap.sh`](./bootstrap.sh) — Linux and macOS.
- [`./bootstrap.ps1`](./bootstrap.ps1) — Windows.
- [`./projects.tsv`](./projects.tsv) — every project and where it is cloned from.

## Getting everything

```bash
git clone git@github.com:gamemann/tmc-dot-bootstrap.git
cd tmc-dot-bootstrap
./bootstrap.sh
```

```powershell
git clone git@github.com:gamemann/tmc-dot-bootstrap.git
cd tmc-dot-bootstrap
.\bootstrap.ps1
```

Everything lands in `./projects`, beside the script, and that directory is
gitignored. Run it again any time to pull what has moved; a repository with
uncommitted work in it is reported and left alone.

If this repository is sitting at `godot/bootstrap` inside a `game-dev` tree, it
uses that `godot/` directory instead of making a second copy of everything.
Override either way with `DOT_PROJECTS`.

## Playing a game

```bash
./bootstrap.sh --list           # what there is
./bootstrap.sh --play arena     # or g2gfast, hungario, playground, simple-lobby
```

**No server, no CDN, no downloads.** Every game falls back to playing offline when
no dedicated server is attached: `arena` gives you three bots on `dm_atrium`,
`hungario` six, `g2gfast` and `playground` a map and a timer. You need Godot 4.7
on `PATH`, or `GODOT` pointing at it.

`game-arena` starts in warmup — WARMUP, COUNTDOWN, then LIVE — and nobody spawns
until LIVE, about thirteen seconds in.

## Everything else

| | |
| --- | --- |
| `--links` / `-Links` | only redo the addon links |
| `--status` / `-Status` | branch, dirty and unpushed, per repository |
| `--check` / `-Check` | does `projects.tsv` still agree with the disk? |

`DOT_GIT_BASE` clones from somewhere other than GitHub. `DOTHUB` adds a second
remote called `hub` — bare repositories on a dev box — when cloning.

## Why the scripts contain no lists

The version these replace carried a manifest of projects *and* of the addons each
one needs, in both files. All four copies went stale: they had drifted to **19 of
the 33 repositories**, having silently lost `game-playground`, `game-g2gfast` and
the whole movement and NPC half of the family. That is this family's most-repeated
bug and it has now happened four times in this codebase.

So neither list lives in the scripts:

- The projects come from **`projects.tsv`**, the one file both scripts read.
  `--check` fails if it disagrees with what is on the disk.
- The addons a project needs are read out of **that project's own `.gitignore`**,
  from its `/addons/<name>` lines. That is the one place that cannot go stale: the
  repository that gains a dependency is the repository that has to ignore the
  link, and Godot will not open without it.

## Windows uses junctions, not symlinks

A symlink on Windows needs Developer Mode or an elevated prompt, and Git for
Windows will not create one unless `core.symlinks` is true. When it cannot, it
checks the link out as a **text file containing the path** — so Godot finds a
30-byte file where an addon should be, every `class_name` in it fails to resolve,
and every script mentioning those names fails to parse too. The symptom is dozens
of unrelated parse errors in files you did not touch.

`bootstrap.ps1` uses directory junctions, which need no elevation and which Godot
follows transparently.
