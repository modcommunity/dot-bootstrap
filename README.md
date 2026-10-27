This is the **bootstrap** tooling for TMC's **Dot** collection. It is what you run first: it clones every project, links each addon into the projects that consume it, and gets you to a game running without you having to know how many repositories that took.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This tool is what gets them onto your machine and wired together.

**This tool and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This tool, along with every asset it sets up, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** These scripts are how every machine here is set up, so they get run often, but very little of this family has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## One Clone Per Project, and One Place That Knows Them All

Each Dot project is its own Git repository, deliberately. An addon is consumed by copying its `addons/<name>/` folder, and nothing should be able to clone the whole family as one unit. The cost of that rule is fifty-odd clones and getting on for three hundred addon links per machine, and both numbers grow every time the family does. These scripts are the one place that knowledge lives.

- [`./bootstrap.sh`](./bootstrap.sh) for Linux and macOS.
- [`./bootstrap.ps1`](./bootstrap.ps1) for Windows.
- [`./projects.tsv`](./projects.tsv) lists every project and where it is cloned from.

## Getting everything

The assets are public, so **you need no credentials to clone or pull.** The scripts use HTTPS by default. On a machine you push from, `--ssh` / `-Ssh` clones over SSH instead, and still falls back to HTTPS if the key is missing. A clone that already has an SSH origin keeps it: in the default mode its pulls go over HTTPS for that one command, so a machine without a key can still update it, and a machine with one can still push. A repository that exists on GitHub with nothing pushed to it yet is reported as empty, not as a failure.


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

Everything lands in `./projects`, beside the script, and that directory is gitignored. Run it again any time to pull what has moved. Uncommitted work is never touched: a repository with some is still fast-forwarded when the update does not change those files, and when it does, nothing is pulled and the files are named.

The first line it prints is where it decided to put things. Read it.

It uses a tree's existing `godot/` directory instead, rather than making a second copy of everything, only when all three of these hold: this repository's folder is named `dot-bootstrap` (or `bootstrap`, which is what it was called before the rename), its parent is named `godot`, and there is a `CLAUDE.md` above that. Anything else is a standalone clone and gets `./projects`.

Override either way with `DOT_PROJECTS` (`-Projects` on Windows).

## Getting only some of it

You do not need all seventy-odd repositories to play one game. Name what you want and it brings what that needs (its addons, and any maps or courses it keeps in a repository of its own), and nothing else:

```bash
./bootstrap.sh --only wipeout              # mg-wipeout, its 28 addon repos, zee-dot-weapons, mg-wipeout-maps
./bootstrap.sh --only arena,playground     # short names: arena = game-arena, wipeout = mg-wipeout, core = dot-core
./bootstrap.sh --only 'mg-*'               # a wildcard
./bootstrap.sh --only dot-weapon --no-deps # just that repository, nothing it needs
./bootstrap.sh --import                    # import every game headless (the editor can crash on its own first import); --only narrows it
./bootstrap.sh --discard-generated         # an update blocked by editor-rewritten .import/.uid files: restore them and retry
./bootstrap.sh game-arena mg-wipeout       # bare names select, like --only
./bootstrap.sh --games arena,wipeout --addons dot-core   # by kind; --games refuses an addon, --addons a game
./bootstrap.sh zees-games                  # the group: every game, with its addons and content
./bootstrap.sh --zees-games-min            # every game, base repository + addons only
./bootstrap.sh mg-wipeout --min            # --min on any selection: no content packs
./bootstrap.sh --plan zees-games           # print what would be cloned and linked, change nothing
```

```powershell
.\bootstrap.ps1 game-arena mg-wipeout
.\bootstrap.ps1 -Games arena,wipeout -Addons dot-core
.\bootstrap.ps1 zees-games
.\bootstrap.ps1 -ZeesGamesMin
.\bootstrap.ps1 mg-wipeout -Min
.\bootstrap.ps1 -Plan zees-games
.\bootstrap.ps1 -Only wipeout
.\bootstrap.ps1 -Only arena,playground
.\bootstrap.ps1 -Only dot-weapon -NoDeps
.\bootstrap.ps1 -DiscardGenerated
.\bootstrap.ps1 -Import
```

The addons are copied (or linked) into the projects you named and nowhere else. The addon repositories it clones are only the sources for those copies, so their own `addons/` folders are left empty. **A plain `./bootstrap.sh` with no selection clones every repository in `projects.tsv` and links all of it**: every game, every maps repository, and the optional weapon and monster packs a game declares. **Content** is the maps, courses and worlds a game links with `# bootstrap-link:` and the packs it marks with `# bootstrap-optional`; a selection pulls it in with the game unless `--min` (`-Min`) is given, and `--min` alone means every game, base only (`--zees-games-min`). The group `zees-games` (alias `games`) is every `game-*` and `mg-*` project; `addons` is every `dot-*`. A name that matches no project or group stops the run with exit 2, because an empty selection would mean everything. `--plan` (`-Plan`) prints `clone`/`have` per repository and `link` per addon and content line without touching the disk (set `DOT_PLAN_FROM` to a checkout tree to read `.gitignore` files for repositories not cloned yet). `tools/check_content_links.sh` walks every game with it and fails if a link target is missing from `projects.tsv`, not cloned or not linked by default. A name that matches nothing stops the run, because an empty selection would mean everything. `--only` works with `--links` and `--status` too, and `DOT_ONLY=arena,wipeout` (`$env:DOT_ONLY` on Windows) makes a selection stick between runs. What a project needs is read from its `.gitignore` as it is cloned, so the selection holds no list either.

## Playing a game

```bash
./bootstrap.sh --list           # what there is
./bootstrap.sh --play arena     # or g2gfast, hungario, playground
```

**No server, no CDN, no downloads.** Every game falls back to playing offline when no dedicated server is attached: `arena` gives you three bots on `dm_atrium`, `hungario` six, `g2gfast` and `playground` a map and a timer. You need Godot 4.7 on `PATH`, `GODOT` pointing at it, or run `./bootstrap.sh --get-godot` (`.\bootstrap.ps1 -GetGodot` on Windows), which downloads the latest stable release, checks it against the published SHA-512, and unpacks it into `.godot-bin` beside the script; every mode that runs Godot looks there first.

`game-arena` starts in warmup, running WARMUP then COUNTDOWN then LIVE, and nobody spawns until LIVE, about thirteen seconds in.

### Converted maps need their art staged

A game that draws converted maps from a shared store (`zombie-zone` today) reads their library textures and models from shared art stores that are not in any repository. Without them the maps still play, drawn with low-detail stand-ins, and the load screen says "Low-detail art". Players get the art as dot-cloud slices from a server that publishes them; a developer stages it once (about 2 GB) with dot-map's script, from the team's dev box or any copy of the stores:

```bash
dot-map/tools/stage_stores.sh zombie-zone-maps --from dev02:godot/zombie-zone-maps/.stores --game game-zombie-zone
```

It is not part of a plain sync because it is a large download and needs access to a copy of the stores. Details: [dot-map docs/content.md](https://github.com/modcommunity/dot-map/blob/main/docs/content.md#without-the-slices).

## Everything else

| | |
| --- | --- |
| `--links` / `-Links` | only redo the addon links |
| `--status` / `-Status` | branch, dirty and unpushed, per repository |
| `--check` / `-Check` | does `projects.tsv` still agree with the disk? |
| `--tools` / `-Tools` | install fastgmad, the `.gma` unpacker the map importers use (below) |
| `--content-keys` / `-ContentKeys` | a content signing keypair, so this machine can publish packs |

`DOT_GIT_BASE` clones from somewhere other than GitHub. `DOTHUB` adds a second remote called `hub`, pointing at bare repositories on a dev box, when cloning.

## Tools the importers shell out to

`--tools` (`-Tools` on Windows) installs **fastgmad**, the community extractor for `.gma` addon archives. dot-map's BSP importer (`tools/bsp/dotbsp/gma.py`) runs `fastgmad extract` on a `.gma` rather than carrying a reader of its own, and finds it through the `DOTBSP_FASTGMAD` environment variable, then `PATH`, then `~/.local/bin/fastgmad`.

- **What**: fastgmad 0.2.1, by William Venner, Apache-2.0, https://github.com/WilliamVenner/fastgmad (release assets under `/releases/tag/v0.2.1`).
- **How**: the script downloads the release zip for this platform, refuses it unless its SHA-256 equals the value written in the script (the same digest GitHub shows for the asset), then unpacks it into `~/.local/share/fastgmad-0.2.1` and links the executable at `~/.local/bin/fastgmad`. The release ships helper libraries beside the executable, so the whole zip is kept together. `DOT_TOOLS_PREFIX` replaces `~/.local`; `DOT_FASTGMAD_ZIP` names a local copy of the zip for a machine without network access, and is held to the same checksum.
- **Platforms**: Linux x86_64 and macOS (the macOS binary is checksum-pinned but untested here). On Windows `-Tools` unpacks into `%LOCALAPPDATA%\fastgmad\0.2.1`; dotbsp does not look there, so put that folder on `PATH` or set `DOTBSP_FASTGMAD`. The Windows path is untested.
- **Why opt-in**: a plain sync needs git and nothing else. Making it part of the default path would add a network download of a binary to every bootstrap, and `--check` and `--status` must stay offline.

## Publishing content from a fresh clone

`dot-cloud` refuses an unsigned manifest, and it is right to: a mounted pack can contain scripts, so a client that mounts unsigned content runs whatever the server sent it. Publishing therefore needs a private key — and a private key is the one thing a clone can never carry. `dot-server-deploy/keys/` is gitignored precisely so one cannot arrive in a commit.

So a fresh clone can **consume** the team's content, whose public half is committed in `dot-server-deploy/client/content.json`, and can publish none of its own. `--content-keys` gives this machine an identity of its own and rewrites that file to trust it:

```bash
./bootstrap.sh --content-keys     # or .\bootstrap.ps1 -ContentKeys
```

It is opt-in rather than part of a plain sync because **it leaves `client/content.json` locally modified**, now naming a key no other machine has. That is the honest trade, and doing it silently would leave somebody wondering why their client had started rejecting the team's packs. Do not commit the result.

## Why the scripts contain no lists

The version these replace carried a manifest of projects *and* of the addons each one needs, in both files. All four copies went stale: they had drifted to **19 of the 33 repositories**, having silently lost `game-playground`, `game-g2gfast` and the whole movement and NPC half of the family. That is this family's most-repeated bug and it has now happened four times in this codebase.

So neither list lives in the scripts:

- The projects come from **`projects.tsv`**, the one file both scripts read. `--check` fails if it disagrees with what is on the disk.
- The addons a project needs are read out of **that project's own `.gitignore`**, from its `/addons/<name>` lines. That is the one place that cannot go stale: the repository that gains a dependency is the repository that has to ignore the link, and Godot will not open without it.
- A **content directory** from another repository is declared the same way: a `# bootstrap-link: <repo>/<path>` comment line directly above the ignored path. game-g2gfast's `.gitignore` has `# bootstrap-link: g2gfast-maps/maps` over `/maps/imported`, so a fresh clone of the game gets its imported maps (linked, or copied on Windows by default). A real directory already at that path is reported and never replaced, because it may be the only copy of something.
- An **optional pack** (a weapon or monster pack the game runs without, such as game-zombie-zone's zz-modern-weapons, zz-medieval-weapons and zz-historical-monsters) is an ordinary `/addons/<name>` line preceded by a `# bootstrap-optional` comment line. It is linked by default and skipped under `--min`.

## Windows copies the addons; Linux links them

`bootstrap.ps1` copies each addon folder into the project. `bootstrap.sh` makes relative symlinks, which Godot follows.

Junctions were the original Windows design and the reasoning was good: no elevation, no Developer Mode, and the filesystem resolves them before Godot ever sees them. **The last part turned out to be false.** Measured on Windows 11 with Godot 4.7.2: the eight junctions in `game-arena\addons` existed and Explorer walked them, and Godot registered not one `class_name` from any of them. Every `Dot*` identifier came back *"not declared in the current scope"* and seventy-odd scripts failed to parse. Copying the same folders fixed it outright.

A link the engine will not follow is not a link, so the default is the one that works, and copying is what this family's own documentation says a consumer does anyway. `-Junction` opts back in if you want to test it; `--copy` on Linux copies there too.

**The cost of copying is that it does not track its source**, so re-run `.\bootstrap.ps1 -Links` after a `git pull`. On Linux the symlinks need no such thing.

Related, and the reason the links matter at all: if Git checks a symlink out as a regular file, which is what it does on Windows when `core.symlinks` is false, then `addons\dot_core` is a ~30 byte text file containing a path. Godot finds no scripts, every `class_name` fails to resolve, and every script mentioning one fails to parse too. Same symptom, different cause.

## `tools/` — the checks that need every repository at once

Most of this family's mechanical detectors are a grep you run inside one project, and they are catalogued with the family's own documentation rather than here. A few cannot be: they have to resolve a `class_name` declared in one repository against an `extends` written in another, which means reading all of them together. Those live here, for the same reason `projects.tsv` does — this is the repository that owns the family as a whole.

```bash
tools/shadowed_methods.py --self-test
```

GDScript accepts a `func` whose name a native class already defines with **no warning and no parse error**, and the call then binds to the engine's implementation — so the method is present, reachable, called, and inert. No grep can find it: the name occurs more than once, it has callers, and the body reads correctly. The list of names to check against has to come from `ClassDB` rather than from memory, because `Resource` alone has 76 methods and `reset_state` is not one anybody would guess.

So this asks the engine, resolves every `extends` chain down to the native class it rests on, and reports every **public** `func` whose name is already on that chain. Names beginning with `_` are skipped: that is the engine's own override mechanism and the intended way to replace a virtual.

`--self-test` plants a known shadow first and fails if it is not reported. That is not decoration — **a detector that reports a clean tree and a detector that is broken produce exactly the same output**, and this family has shipped a check that was blind for months for precisely that reason.

It needs `godot` on `PATH` (or `GODOT=` set) and defaults to scanning the directory the projects are cloned into.

### dot-workbench comes with every game

`dot-workbench` is in `projects.tsv`, and every game and `dot-game-template` lists `/addons/dot_workbench` in its `.gitignore`, so a normal bootstrap clones it once and links (Windows: copies) it into each game, with no extra step. `tools/check_workbench_link.sh` proves it: every game carries the line, `--plan` clones and links it, and a real offline `bootstrap.sh --only workbench` run in a scratch directory links dot-workbench with its dot-core, dot-ui, dot-menu and dot-settings.

## Licence

MIT. See [LICENSE](LICENSE).

The raw art stores (`zombie-zone-maps/.stores`, about 1.6 GB of CC0 textures and models) are in no repository. Bootstrap downloads them once from `https://dev.dotgames.org/stores/zombie-zone-maps/zz-stores-cc0.tar` (SHA-256 checked) and keeps them, so later runs do not fetch again. Pass `-NoStores` (`--no-stores` in sh), or set `DOT_STORES_FROM=none`, to skip them (maps then draw low-detail art), or set `DOT_STORES_FROM` to a folder or another `.tar` URL to use your own. The Sketchfab models in the author's private store are not in the download.
