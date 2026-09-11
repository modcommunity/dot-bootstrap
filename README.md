Some useful bootstrap scripts for TMC's [Dot assets](https://moddingcommunity.com/co/4-dot-assets).

Each Dot project is its own Git repository, deliberately — an addon is consumed by copying its `addons/<name>/` folder, and nothing should be able to clone the whole family as one unit. The cost of that rule is thirty-odd clones and a hundred-odd addon symlinks per machine. These scripts are the one place that knowledge lives.

- [`./bootstrap.sh`](./bootstrap.sh) — Linux and macOS.
- [`./bootstrap.ps1`](./bootstrap.ps1) — Windows.
- [`./projects.tsv`](./projects.tsv) — every project and where it is cloned from.

## Getting everything

The assets are public, so **you need no credentials to clone or pull.** The scripts try SSH first — that is what a machine with a key can push from — and if SSH is unavailable they fall back to HTTPS automatically, warn once, and carry on. `--https` / `-Https` skips straight to HTTPS.


```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
```

```powershell
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser   # once, if PowerShell refuses
.\bootstrap.ps1
```

Everything lands in `./projects`, beside the script, and that directory is gitignored. Run it again any time to pull what has moved; a repository with uncommitted work in it is reported and left alone.

The first line it prints is where it decided to put things. Read it.

It uses a tree's existing `godot/` directory instead, rather than making a second copy of everything, only when all three of these hold: this repository's folder is named `dot-bootstrap` (or `bootstrap`, which is what it was called before the rename), its parent is named `godot`, and there is a `CLAUDE.md` above that. Anything else is a standalone clone and gets `./projects`.

Override either way with `DOT_PROJECTS` (`-Projects` on Windows).

## Playing a game

```bash
./bootstrap.sh --list           # what there is
./bootstrap.sh --play arena     # or g2gfast, hungario, playground, simple-lobby
```

**No server, no CDN, no downloads.** Every game falls back to playing offline when no dedicated server is attached: `arena` gives you three bots on `dm_atrium`, `hungario` six, `g2gfast` and `playground` a map and a timer. You need Godot 4.7 on `PATH`, or `GODOT` pointing at it.

`game-arena` starts in warmup — WARMUP, COUNTDOWN, then LIVE — and nobody spawns until LIVE, about thirteen seconds in.

## Everything else

| | |
| --- | --- |
| `--links` / `-Links` | only redo the addon links |
| `--status` / `-Status` | branch, dirty and unpushed, per repository |
| `--check` / `-Check` | does `projects.tsv` still agree with the disk? |

`DOT_GIT_BASE` clones from somewhere other than GitHub. `DOTHUB` adds a second remote called `hub` — bare repositories on a dev box — when cloning.

## Why the scripts contain no lists

The version these replace carried a manifest of projects *and* of the addons each one needs, in both files. All four copies went stale: they had drifted to **19 of the 33 repositories**, having silently lost `game-playground`, `game-g2gfast` and the whole movement and NPC half of the family. That is this family's most-repeated bug and it has now happened four times in this codebase.

So neither list lives in the scripts:

- The projects come from **`projects.tsv`**, the one file both scripts read. `--check` fails if it disagrees with what is on the disk.
- The addons a project needs are read out of **that project's own `.gitignore`**, from its `/addons/<name>` lines. That is the one place that cannot go stale: the repository that gains a dependency is the repository that has to ignore the link, and Godot will not open without it.

## Windows copies the addons; Linux links them

`bootstrap.ps1` copies each addon folder into the project. `bootstrap.sh` makes relative symlinks, which Godot follows.

Junctions were the original Windows design and the reasoning was good — no elevation, no Developer Mode, and the filesystem resolves them before Godot ever sees them. **The last part turned out to be false.** Measured on Windows 11 with Godot 4.7.2: the eight junctions in `game-arena\addons` existed and Explorer walked them, and Godot registered not one `class_name` from any of them. Every `Dot*` identifier came back *"not declared in the current scope"* and seventy-odd scripts failed to parse. Copying the same folders fixed it outright.

A link the engine will not follow is not a link, so the default is the one that works — and copying is what this family's own documentation says a consumer does anyway. `-Junction` opts back in if you want to test it; `--copy` on Linux copies there too.

**The cost of copying is that it does not track its source**, so re-run `.\bootstrap.ps1 -Links` after a `git pull`. On Linux the symlinks need no such thing.

Related, and the reason the links matter at all: if Git checks a symlink out as a regular file — which is what it does on Windows when `core.symlinks` is false — then `addons\dot_core` is a ~30 byte text file containing a path. Godot finds no scripts, every `class_name` fails to resolve, and every script mentioning one fails to parse too. Same symptom, different cause.
