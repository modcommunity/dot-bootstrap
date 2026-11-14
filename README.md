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

## Keeping stock Valve files out of your commits

Stock Valve and Source assets (`.vpk`, `.vtf`, `.vmt`, `.mdl`, `.vvd`, `.vtx`, `.phy`, `.ani`, a `textures/orig` folder) are local-only and never belong in a repository or a published pack. The check that refuses them lives in dot-cloud (`tools/check_valve_files.py`), and CI runs it on every project. To refuse them at commit time too, install its pre-commit hook in every repository you have cloned:

```bash
tools/install-valve-hooks.sh                 # every repository in ./projects (or DOT_PROJECTS)
tools/install-valve-hooks.sh /path/to/dir    # any directory of repositories
tools/install-valve-hooks.sh --check         # list the repositories without it, change nothing
```

bootstrap.sh runs this on every sync. `DOT_CLOUD=/path` names the dot-cloud checkout that holds the guard (default: dot-cloud beside the repositories); a missing guard is an error, not a skip.

The hook names dot-cloud's checkout by absolute path, so it needs `dot-cloud` cloned alongside the others (`./bootstrap.sh --only dot-cloud --no-deps`), and it must be run again if the directory moves. Worktrees share their repository's hooks, so one install covers them. A commit the hook refuses names every offending file.

## Getting only some of it

You do not need all seventy-odd repositories to play one game. Name what you want and it brings what that needs (its addons, and any maps or courses it keeps in a repository of its own), and nothing else:

```bash
./bootstrap.sh --only wipeout              # mg-wipeout, its 28 addon repos, zee-dot-weapons, mg-wipeout-maps
./bootstrap.sh --only fatal-contact,playlot     # short names: fatal-contact = game-fatal-contact, wipeout = mg-wipeout, core = dot-core; old names still work: arena, g2gfast, playground
./bootstrap.sh --only 'mg-*'               # a wildcard
./bootstrap.sh --only dot-weapon --no-deps # just that repository, nothing it needs
./bootstrap.sh --import                    # import every game headless (the editor can crash on its own first import); --only narrows it
./bootstrap.sh --discard-generated         # an update blocked by editor-rewritten .import/.uid files: restore them and retry
./bootstrap.sh game-fatal-contact mg-wipeout       # bare names select, like --only
./bootstrap.sh --games arena,wipeout --addons dot-core   # by kind; --games refuses an addon, --addons a game
./bootstrap.sh zees-games                  # the group: every game, with its addons and content
./bootstrap.sh --zees-games-min            # every game, base repository + addons only
./bootstrap.sh mg-wipeout --min            # --min on any selection: no content packs
./bootstrap.sh --plan zees-games           # print what would be cloned and linked, change nothing
```

```powershell
.\bootstrap.ps1 game-fatal-contact mg-wipeout
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

The addons are copied (or linked) into the projects you named and nowhere else. The addon repositories it clones are only the sources for those copies, so their own `addons/` folders are left empty. **A plain `./bootstrap.sh` with no selection clones every repository in `projects.tsv` and links all of it**: every game, every maps repository, and the optional weapon and monster packs a game declares. **Content** is the maps, courses and worlds a game links with `# bootstrap-link:` and the packs it marks with `# bootstrap-optional`; a selection pulls it in with the game unless `--min` (`-Min`) is given, and `--min` alone means every game, base only (`--zees-games-min`). The group `zees-games` (alias `games`) is every `game-*` and `mg-*` project; `addons` is every `dot-*`. A name that matches no project or group stops the run with exit 2, because an empty selection would mean everything. `--plan` (`-Plan`) prints `clone`/`have` per repository and `link` per addon and content line without touching the disk (set `DOT_PLAN_FROM` to a checkout tree to read `.gitignore` files for repositories not cloned yet). `tools/check_content_links.sh` walks every game with it and fails if a link target is missing from `projects.tsv`, not cloned or not linked by default. A name that matches nothing stops the run, because an empty selection would mean everything. **A renamed repository is cloned under its new name.** Fatal Contact (formerly Arena), Airdrift (formerly G2G Fast) and Playlot (formerly Playground) are `game-fatal-contact`, `fc-weapons`, `fc-dm-maps`, `fc-surf-dm-maps`, `game-airdrift`, `airdrift-maps`, `game-playlot` and `playlot-maps`, and `mg-deathrun`/`mg-prop-hunt` are `game-deathrun`/`game-prop-hunt`; `projects.tsv` lists the new names and keeps the old ones in its third column, so selections, `--play` and `--export` accept both, and games' `# bootstrap-link:` lines and `/addons/arena_weapons` lines that still say an old name resolve to the new folder. **A checkout still under an old name is moved** on the next sync (or `--links`): `mv` to the new name only when that name does not exist, dirty tree and all (it says how many files were uncommitted), `git worktree repair`, every link in the family that went through the old name repointed, and the old name left as a link (a junction on Windows) to the new one. It is refused, and no second copy is cloned, when a process has its working directory or an argument in that folder, or with `DOT_NO_RENAME=1`; then the old folder keeps being used. When both names exist neither is touched and the old one is reported; a different repository under an old name is left alone and the listed one cloned beside it. `--check` names a checkout still under its old name. A checkout whose `origin` still names the old repository is repointed on its next sync (`origin moved old -> new`), since GitHub's redirect is not to be relied on. A repository GitHub does not have fails the run in red as `REPOSITORY MISSING` with its URL. `--only` works with `--links` and `--status` too, and `DOT_ONLY=arena,wipeout` (`$env:DOT_ONLY` on Windows) makes a selection stick between runs. What a project needs is read from its `.gitignore` as it is cloned, so the selection holds no list either.

## Playing a game

```bash
./bootstrap.sh --list           # what there is
./bootstrap.sh --play arena     # or fatal-contact (= arena), airdrift (= g2gfast), playlot (= playground), hungario
```

**No server, no CDN, no downloads.** Every game falls back to playing offline when no dedicated server is attached: `arena` gives you three bots on `dm_atrium`, `hungario` six, `g2gfast` and `playground` a map and a timer. You need Godot 4.7 on `PATH`, `GODOT` pointing at it, or run `./bootstrap.sh --get-godot` (`.\bootstrap.ps1 -GetGodot` on Windows), which downloads the latest stable release, checks it against the published SHA-512, and unpacks it into `.godot-bin` beside the script; every mode that runs Godot looks there first.

**A release build.** `./bootstrap.sh --export arena` (Windows: `.\bootstrap.ps1 -Export arena`) exports the game with its `Linux x86_64` (`Windows x86_64`) preset into `game-fatal-contact/build/linux` (`build\windows`): executable, pck and native libraries. `./bootstrap.sh --play-export arena` (`.\bootstrap.ps1 -PlayExport arena`) starts that build, exporting first when there is none, as `-- --offline +bot_quota 8 +profiler_overlay 1 +profiler_record_seconds 60` for FC and `-- --offline` for every other game; arguments after the name (`-PlayArgs "+bot_quota 16 --map dm_atrium"` on Windows) go to the game last and win. It is what a player runs (no editor, no debugger), so it is the build to measure with: the profiler is in it, F10 records, reports land in the game's user folder. The matching official export templates are downloaded once (1.2 GB, SHA-512 checked against the release's `SHA512-SUMS.txt`), only this platform's release template is kept in `.godot-bin/<version>/templates`, and the game's `export_presets.cfg` (copied from its `export_presets.example.cfg` when there is none) is pointed at it. The export is refused when an extension lists no library for the platform (run a sync to fetch the natives; `DOT_NATIVES=none` exports without) and fails when a library is not beside the executable afterwards. A library an addon loads itself at run time from `addons/<name>/native/<lib>.cfg` (dot-net's snapshot core) is copied by hand with its `.cfg` into `<lib>/` beside the executable; a missing one only warns, since the addon falls back to GDScript. Linux x86_64 and Windows x86_64 only. Any game exports: one with neither `export_presets.cfg` nor `export_presets.example.cfg` (every game but FC so far), or whose file lacks the preset, gets FC's preset with its own name written into `export_presets.cfg` (pck beside the executable, all resources, export path `build/<platform>/<game>`), and the file goes in the clone's `.git/info/exclude` unless the game's `.gitignore` already ignores it. A game that wants different settings tracks its own `export_presets.example.cfg`; `tests/test_export.sh` covers both scripts against a fake release.

`game-arena` starts in warmup, running WARMUP then COUNTDOWN then LIVE, and nobody spawns until LIVE, about thirteen seconds in.

### Converted maps need their art staged

A game that draws converted maps from a shared store (`zombie-zone` today) reads their library textures and models from shared art stores that are not in any repository. Without them the maps still play, drawn with low-detail stand-ins, and the load screen says "Low-detail art". Players get the art as dot-cloud slices from a server that publishes them; a developer stages it once (about 2 GB) with dot-map's script, from the team's dev box or any copy of the stores:

```bash
dot-map-convert/tools/stage_stores.sh zombie-zone-maps --from dev02:godot/zombie-zone-maps/.stores --game game-zombie-zone
```

It is not part of a plain sync because it is a large download and needs access to a copy of the stores. Details: [dot-map docs/content.md](https://github.com/modcommunity/dot-map/blob/main/docs/content.md#without-the-slices).

### Playing a map you converted yourself

You can play a converted map folder or its `.zip` without publishing it. Name it `<map>_orig` if it keeps its original textures; such packs are never published. To add it, do one of these:

- Put it in the game's user data `maps/` folder. Fatal Contact: `~/.local/share/game-fatal-contact/maps` on Linux, `%APPDATA%\game-fatal-contact\maps` on Windows (its first run copies an older `godot/app_userdata/game-arena` folder in). Other games: `~/.local/share/godot/app_userdata/<game>/maps` on Linux, `%APPDATA%\Godot\app_userdata\<game>\maps` on Windows. `--play-export <game>` prints the folder.
- In a source checkout, put it in `res://addons/maps`.
- Drag it onto the window of a game that calls `DotMapLocalMaps.watch_drops` (Fatal Contact does).

It shows as `<title> (local)` and plays solo only. See [dot-map docs/content.md "Zips and drag-and-drop"](https://github.com/modcommunity/dot-map/blob/main/docs/content.md) (dot-map ec75600).

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

`--tools` (`-Tools` on Windows) installs **fastgmad**, the community extractor for `.gma` addon archives. dot-map-convert's BSP importer (`dotbsp/gma.py` in dot-map-convert) runs `fastgmad extract` on a `.gma` rather than carrying a reader of its own, and finds it through the `DOTBSP_FASTGMAD` environment variable, then `PATH`, then `~/.local/bin/fastgmad`.

- **What**: fastgmad 0.2.1, by William Venner, Apache-2.0, https://github.com/WilliamVenner/fastgmad (release assets under `/releases/tag/v0.2.1`).
- **How**: the script downloads the release zip for this platform, refuses it unless its SHA-256 equals the value written in the script (the same digest GitHub shows for the asset), then unpacks it into `~/.local/share/fastgmad-0.2.1` and links the executable at `~/.local/bin/fastgmad`. The release ships helper libraries beside the executable, so the whole zip is kept together. `DOT_TOOLS_PREFIX` replaces `~/.local`; `DOT_FASTGMAD_ZIP` names a local copy of the zip for a machine without network access, and is held to the same checksum.
- **Platforms**: Linux x86_64 and macOS (the macOS binary is checksum-pinned but untested here). On Windows `-Tools` unpacks into `%LOCALAPPDATA%\fastgmad\0.2.1`; dotbsp does not look there, so put that folder on `PATH` or set `DOTBSP_FASTGMAD`. The Windows path is untested.
- **Why opt-in**: a plain sync needs git and nothing else. Making it part of the default path would add a network download of a binary to every bootstrap, and `--check` and `--status` must stay offline.

## Fetching content from the CDN

**PowerShell.** `fetch_lock.ps1`, `fetch_all.ps1` and `dot-server-deploy/fetch-content.ps1` need PowerShell 7 (`pwsh`) on Linux and macOS, or the Windows PowerShell 5.1 that ships with Windows 10+. They were run on Linux under `pwsh` 7.6 against a local HTTP CDN and a folder (`-From`), and print the same fetched/skipped lines and write the same tree as `fetch_lock.sh`. Install on Debian: unpack the `powershell-<v>-linux-x64.tar.gz` release from github.com/PowerShell/PowerShell into `~/.local/powershell` and link `pwsh` into `~/.local/bin`.

A repository that has content on the CDN (raw art stores, packs) carries a `content.lock.json` at its root: the one file that says what to fetch, pinned by hash (format: dot-cloud `docs/cdn-publish.md`). **One fetcher reads it**, `tools/fetch_lock.sh` (`tools/fetch_lock.ps1` on Windows); every repository's `fetch-content.sh` / `fetch-content.ps1` is a few lines that call it (macOS uses the `.sh`), and `./server fetch-lock` and `bootstrap` call it too. Every file is hash-checked, resumable, and fetched once: a present, stamped pack is "have".

```bash
../zombie-zone-maps/fetch-content.sh                 # one repository: everything its lock names
tools/fetch_all.sh                                   # every lock file in the tree (games, addons, map repos, packs)
tools/fetch_all.sh --only 'zombie-*'                 # only X: a repository, pack id, name half, `into` folder or kind; globs
tools/fetch_all.sh --except zz-stores,mg-*-maps      # everything but X
tools/fetch_lock.sh <repo>/content.lock.json --list  # what would be fetched, and why each other item is skipped
.\tools\fetch_all.ps1 -Only zombie-zone-maps -Except zz-stores   # Windows
```

**Which CDN.** First one set wins: `--from` / `-From` (a full origin URL or a folder), `$DOT_PACKS_FROM` (`none` fetches nothing), `--cdn URL` or `$DOT_CDN_URL` (per run or per repository), `DOT_CDN_URL=` in **`dot-bootstrap/.env`** (one edit for every game and addon; copy `.env.example`, it is gitignored), then the lock's own `origin` and `mirrors`, then `https://dotgames.org`. A URL given this way is the site root and `/content` is added. The lock's origin comes before the default on purpose: a pin published to the dev bucket would not verify against production anyway (another signing key), so the lock decides unless somebody overrides it.

**The download lists are respected.** With `cfg/content/addons.yml` / `games.yml` (and the `cfg/server/content/` layer; `tools/fetch_all.sh` borrows `dot-server-deploy/cfg` for repositories without a `cfg/`) a lock entry is dropped when a `remove:` entry names it (id, name half or glob), when `cfg/content/<name>/disabled` exists, or, when a list without `merge: true` names `pack:` entries, when it is a pack the list does not name. Packs named in the lists that the lock pins are fetched, so custom packs (models, weapons) come with their game. A name the lock does not pin is not fetched here: `./server install-games` fetches those from the origin by id.

**A `# bootstrap-link:` folder kept out of git is filled from its repository's lock.** When the linked repository has a `content.lock.json`, bootstrap runs `fetch_lock` with `--only <linked folder>/*` before linking, so entries whose `into` sits under that folder land there (fc-dm-maps pins each map as kind `store` with `into: maps/<id>`, which fills `game-fatal-contact/maps/imported_dm`).

Packs (kind `pack`) are only mirrored when `--packs DIR` is given (`fetch_all.sh` and dot-server-deploy's wrapper pass `content/packs`); otherwise `DotCloudClient` mounts them at run time. To give a new repository the same, run `tools/make_fetch_scripts.sh` (copies `tools/templates/fetch-content.*` into every repository that has a `content.lock.json`; `--check` lists the ones missing). `tests/test_fetch.sh` checks the URL precedence, `--only`/`--except` and the cfg lists against local `http.server` fixtures (no network). `tests/test_download.sh` checks the downloader both fetchers share on Windows (`tools/dot_download.ps1`: progress lines, 404, a stalled connection failing after `DOT_DOWNLOAD_STALL` seconds, Range resume) and both fetch_lock scripts' file i/n progress and hash-mismatch retry; its PowerShell half needs `pwsh` on PATH and is skipped without it. Windows PowerShell 5.1 itself is not run by any test.

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
- A **content directory** from another repository is declared the same way: a `# bootstrap-link: <repo>/<path>` comment line directly above the ignored path. game-airdrift's `.gitignore` has `# bootstrap-link: g2gfast-maps/maps` (the old name, which resolves to `airdrift-maps`) over `/maps/imported`, so a fresh clone of the game gets its imported maps (linked, or copied on Windows by default). A real directory already at that path is reported and never replaced, because it may be the only copy of something.
- An **optional pack** (a weapon or monster pack the game runs without, such as game-zombie-zone's zz-modern-weapons, zz-medieval-weapons and zz-historical-monsters) is an ordinary `/addons/<name>` line preceded by a `# bootstrap-optional` comment line. It is linked by default and skipped under `--min`.
- A **native library** an addon can load (a GDExtension, such as dot-sim's Rust motor, snapshot codec and bot sight scan) is pinned with a `# bootstrap-natives: <repo> <tag>` comment line above the `/addons/<name>` line (above any `# bootstrap-optional`). game-fatal-contact has `# bootstrap-natives: dot-sim v0.1.0` over `/addons/dot_sim`. Before linking, bootstrap fetches that release's `SHA256SUMS.natives`, downloads the zip for this machine (`linux-x86_64`, `windows-x86_64`, ...), checks it, and unpacks it at the addon repository's root (`addons/<name>/bin/<platform>/` and the `.gdextension`, where `ci/install.sh` puts a local build), then stamps `bin/.natives` so the next run skips it. A library built locally (no stamp) is kept. No release for the platform, or offline: a warning, and the GDScript twins run (correct, slower). `DOT_NATIVES=none` (`$env:DOT_NATIVES`) skips the step; `DOT_NATIVES_BASE` replaces `https://github.com/modcommunity`. Run `--import` (or open the editor once) afterwards so Godot registers the extension. An optional third field names the library directory inside the addon when it is not `bin`: `# bootstrap-natives: dot-net v0.1.29 native/bin` over `/addons/dot_net` unpacks dot-net's Godot-named libraries into `native/bin/` and stamps `native/bin/.natives` there; a library already in that directory for this platform (dot-net commits its Linux x86_64 ones) is kept.

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

### tools/check_pushed_floors.sh: what a fresh clone will find

A game pushed while an addon it needs is only merged locally parses on every machine here (the links see the local addon) and on no fresh clone: the editor reports the last script of an `extends` chain, not the missing class. This compares what is published: each game's `origin/main` `requires.floor.json` against each addon's `origin/main` `<addon>_api.gd` `LEVEL` (exit 1 when a floor is above it), and lists every project whose `main` is ahead of `origin/main`. `--fetch` refreshes the refs first. Run it after pushing a game; `tests/test_pushed_floors.sh` covers it.

### dot-workbench comes with every game

`dot-workbench` is in `projects.tsv`, and every game and `dot-game-template` lists `/addons/dot_workbench` in its `.gitignore`, so a normal bootstrap clones it once and links (Windows: copies) it into each game, with no extra step. `tools/check_workbench_link.sh` proves it: every game carries the line, `--plan` clones and links it, and a real offline `bootstrap.sh --only workbench` run in a scratch directory links dot-workbench with its dot-core, dot-ui, dot-menu and dot-settings.

### tools/gpu.sh: the GPU-box runner

`tools/gpu.sh` (`~/godot/gpu.sh` is a wrapper that execs it, so every game's `tools/*.sh` keeps calling `../gpu.sh`) runs bakes, screenshots, frame timings and whole `game.sh` suites on the always-on GPU boxes (`staging` laptop, `staging02` desktop) over SSH, because dev02 has no GPU. Each box has a `~/gpu/.gate` (one job admitted at a time) and `~/gpu/.lock` (the GPU itself, shared `-s` by read-only users), always taken with `flock -o` so a child that outlives the job cannot inherit and hold them; a busy or unreachable box answers 75/76 and the caller falls back to the next box or to dev02. Shot runs use a shim `xvfb-run` that starts its own Xvfb and stops exactly that pid on exit. A leaked Xvfb that still holds a lock is cleared by the admin on the box (find the holder in `/proc/<pid>/fd`, confirm it is an Xvfb with no job above it, `kill` it): the user runs that kill, never an agent, and the script never kills a process it did not start.

#### Real-time suites: never on ph, never on a full box

Windowed runs (`perf_bench.sh` without `--headless`) draw on a headless Xorg `:90` that `ensure_xorg` starts as the `gpu-xorg` unit from `tools/xorg-headless.conf`. The conf's `BusID` is rewritten on every start to the box's NVIDIA card (`lspci -d 10de:`, hex bus turned into Xorg's decimal `PCI:b:d:f`), because the boxes differ (`staging` 01:00.0, `staging02` 02:00.0) and a BusID naming the other box's card makes Xorg exit with "No devices detected". A unit that failed is `reset-failed` before the start; when it still will not come up, `/tmp/xorg90.log` on the box says why.

Some suites measure the netcode against wall time (ENet and the relay keep wall time while the game ticks), so they only mean something on a box that holds the tick rate. The build VM `ph` runs one thread about 4 times slower than dev02 (game-arena `headless_lossy` paced 43 to 88% of real time there and stops with `NOT A MEASUREMENT`), so `gpu.sh offer` never hands these to `ph`: they go to `staging02`, and when that is busy or down they wait for a dev02 slot.

The list is `tools/realtime_suites.conf` (shell patterns on the suite or scene name, one per line), read by both `gpu.sh` and `heavy`:

| pattern | suites |
|---|---|
| `headless_lossy` | game-arena `headless_lossy` (and its shards, `headless_lossy.windows`) |
| `headless_lossy_*` | game-arena `headless_lossy_22`, `_33`, `_66` |
| `headless_latency` | game-arena `headless_latency` |
| `headless_feel` | game-arena `headless_feel` |

Add a suite there (and a row here) when it fails its pace check on `ph` or stalls on a full box. `GPU_REALTIME_SUITES` (gpu.sh) and `HEAVY_REALTIME_SUITES` (heavy) replace the list, `GPU_REALTIME_CONF` / `HEAVY_REALTIME_CONF` the file, and `GPU_REALTIME_BOXES` (default `staging02`) the boxes, for one run. A job that names one real-time suite is real-time as a whole. A bare `game.sh test` (no suite names) is not caught, because it is one job for every suite: use `hv <worktree> shard`, which makes one job per suite. `tests/test_gpu_realtime.sh` checks the table.

They also failed about 2 runs in 7 when their runner stalled 90-165 ms on a loaded machine (2026-11-13): on dev02 under heavy's 2560 MB floor with 2-3 GB free (the gamedev slice past its `MemoryHigh`, so every process in it is throttled), and on `staging02` with all 8 suite slots busy. So:

- On a box (`gpu.sh` `REMOTE_SUITE`), at most `RT_MAX` real-time suites run at once (`~/gpu/rt.N.lock`), one starts only while fewer than `RT_BUSY` other jobs run there, and while one runs the box takes no other job past `RT_BUSY` (staging02 2 and 5, staging 1 and 3, ph 2 and 20; `GPU_RT_MAX` / `GPU_RT_BUSY` override). A box over the cap answers BUSY and the job waits for dev02 as before. GPU benches already never share a box with a suite (`.lock`/`.gate`). `tests/test_gpu_realtime_slots.sh` checks it.
- On dev02 (`heavy`), a real-time job needs `HEAVY_RT_MIN_MB` (5632) free and gets at least that ceiling (every dev02 run with 5.5 GB passed), at most `HEAVY_RT_MAX` (2) run at once, it runs at normal CPU/IO weight instead of the other jobs' 20 and nice 10, and while one runs every other job needs `HEAVY_RT_GUARD_MB` (2048) more free than its own need to start. A real-time job at the head of the queue that waits for the cap lets the others backfill past it. `tests/test_heavy_realtime.sh` checks it.
- `heavy` also runs one `godot --import` per project directory at a time (`import.<hash>.lock`): five imports of one worktree once held five check slots for an hour.

Imports go where the job runs (2026-11-13). `hv` used to queue a local `heavy -- godot --import` before every scene in a fresh worktree, even when a box took the scene and imported there itself, and `hv import` was local-only: imports were 10 of 21 waiters in dev02's queue. Now:

- A headless `godot` job that runs on dev02 in a project with no `.godot/global_script_class_cache.cfg` imports first in its own slot and cgroup (`HEAVY_NO_PREIMPORT=1` skips that). A box imports before every job (`gpu.sh`), and `game.sh` imports itself.
- `hv <worktree> scene` no longer imports first. `hv <worktree> import` does nothing while an offload script is configured. `HV_IMPORT_LOCAL=1` imports on dev02 for a local tool that reads `.godot`.
- A waiter whose directory was removed while it queued (its worktree was pruned) exits 66 and runs nothing.

`tests/test_heavy_preimport.sh` checks this.

Native addon builds go to PH (2026-11-13). `hv <worktree> local addons/<addon>/native/build.sh [debug|release|all] [scons args]` is offered like a tool script, but only when `addons/<addon>` is the worktree's own directory, not a link into another repo. PH builds in its own `~/.cache/dot-net-native` (godot-cpp and objects). Only `addons/<addon>/native/bin/*` comes back, and only with `--update`, so a newer local file is kept. `tests/test_gpu_offer_eligible.sh` checks which commands are offered.

## Licence

MIT. See [LICENSE](LICENSE).

The raw art stores (`zombie-zone-maps/.stores`, about 1.6 GB of CC0 textures and models) are in no repository. Bootstrap fetches them once from `zombie-zone-maps/content.lock.json` (`tools/fetch_lock.ps1` / `fetch_lock.sh`, every file SHA-256 checked, about 1.9 GB in 4355 files) and keeps them, so later runs do not fetch again; a fetch that was stopped is resumed on the next run. It prints its own progress line every ~2 s (file i/n, MB done / total, MB/s, ETA; PowerShell's progress bar is off because it slows Windows PowerShell 5.1 to a crawl). Pass `-NoStores` (`--no-stores` in sh), or set `DOT_STORES_FROM=none`, to skip them (maps then draw low-detail art), or set `DOT_STORES_FROM` to a folder or a `.tar` URL to use your own. The Sketchfab models in the author's private store are not in the download.
