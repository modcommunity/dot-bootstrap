The first thing to run. It clones the projects of the [**GameSpice**](https://gamespice.net) family (games, addons, maps), links each addon into the projects that use it, and gets you to a running game. Part of the [GameSpice](https://github.com/gamespice-platform) family.

Each GameSpice project is its own Git repository on purpose: an addon is used by copying its `addons/<name>/` folder. These scripts are the one place that knows which repositories exist and which addons each one needs.

| File | Platform |
| --- | --- |
| [`bootstrap.sh`](bootstrap.sh) | Linux and macOS |
| [`bootstrap.ps1`](bootstrap.ps1) | Windows |
| [`projects.tsv`](projects.tsv) | The list of every project and where it is cloned from. |

## Get everything

The repositories are public, so you need no credentials to clone or pull. The scripts use HTTPS by default. Use `--ssh` (`-Ssh` on Windows) on a machine you push from.

```bash
git clone https://github.com/gamespice-platform/bootstrap.git
cd bootstrap
./bootstrap.sh
```

```powershell
git clone https://github.com/gamespice-platform/bootstrap.git
cd bootstrap
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser   # once, if PowerShell refuses
.\bootstrap.ps1
```

Everything goes into `./projects` next to the script (gitignored). Run it again at any time to pull updates. Uncommitted work is never overwritten. Set `GS_PROJECTS` (`-Projects` on Windows) to use another folder. The first line printed says where it decided to put things.

A plain run with no selection clones every repository in `projects.tsv`: all games, all map repositories and the optional weapon and monster packs.

## Get only some of it

Name what you want and it brings what that needs, and nothing else.

```bash
./bootstrap.sh --only wipeout                   # one game with its addons, weapons and maps
./bootstrap.sh --only fatal-contact,playlot     # short names; several at once
./bootstrap.sh --only 'mg-*'                    # a wildcard
./bootstrap.sh --only dot-weapon --no-deps      # just that repository
./bootstrap.sh mg-wipeout --min                 # no content packs
./bootstrap.sh --plan zees-games                # print what would happen, change nothing
```

| Option (Windows form in brackets) | What it does |
| --- | --- |
| `--only A,B` (`-Only`) | Select projects by name, short name or wildcard. Bare names work too. |
| `--games`, `--addons` (`-Games`, `-Addons`) | Select by kind. |
| `--no-deps` (`-NoDeps`) | Do not bring dependencies. |
| `--min` (`-Min`) | Base repository and addons only, no content packs. |
| `--plan` (`-Plan`) | Show what would be cloned and linked. |
| `--import` (`-Import`) | Import every selected game headless (the editor can crash on its own first import). |
| `--discard-generated` (`-DiscardGenerated`) | Restore editor-rewritten `.import` and `.uid` files so a blocked update can continue. |
| `--links` (`-Links`) | Only redo the addon links. |
| `--status` (`-Status`) | Branch, dirty and unpushed state for each repository. |
| `--check` (`-Check`) | Check that `projects.tsv` still matches the disk. |
| `--tools` (`-Tools`) | Install fastgmad (see below). |
| `--content-keys` (`-ContentKeys`) | Make a content signing key so this machine can publish packs. |
| `--no-stores` (`-NoStores`) | Skip the large art stores (maps then use low-detail art). |

Set `GS_GIT_BASE` to clone from somewhere other than GitHub.

## Play a game

```bash
./bootstrap.sh --list              # what there is
./bootstrap.sh --play fatal-contact   # or airdrift, playlot, hungario
```

You need no server and no downloads. Every game plays offline when no dedicated server is attached (Fatal Contact gives you bots on a map, other games a map and a timer). You need Godot 4.7 on `PATH`, `GODOT` pointing at it, or `./bootstrap.sh --get-godot` (`.\bootstrap.ps1 -GetGodot`), which downloads the latest stable release.

To make a release build, run `./bootstrap.sh --export fatal-contact` (`-Export` on Windows). It uses the game's `Linux x86_64` or `Windows x86_64` preset and writes to the game's `build/` folder. `--play-export <game>` starts that build, exporting first if needed.

### Maps you converted yourself

You can play a converted map folder or `.zip` without publishing it. Name it `<map>_orig` if it keeps its original textures; such packs are never published. Use one of:

- Put it in the game's user data `maps/` folder (Linux `~/.local/share/godot/app_userdata/<game>/maps`, Windows `%APPDATA%\Godot\app_userdata\<game>\maps`; `--play-export <game>` prints the exact folder).
- In a source checkout, put it in `res://addons/maps`.
- Drag it onto the window of a game that calls `DotMapLocalMaps.watch_drops` (Fatal Contact does).

It shows as `<title> (local)` and plays solo only. See [dot-map docs/content.md](https://github.com/gamespice-platform/map/blob/main/docs/content.md).

### Art for converted maps

Some games draw converted maps with shared textures and models that are in no repository. Without them the maps still play with low-detail stand-ins and the load screen says "Low-detail art". Players get the art as GameSpice Cloud slices from a server that publishes them. A developer stages it once (about 2 GB):

```bash
dot-map-convert/tools/stage_stores.sh zombie-zone-maps --from dev02:godot/zombie-zone-maps/.stores --game game-zombie-zone
```

This is not part of a plain sync because it is a large download. Details: [dot-map docs/content.md](https://github.com/gamespice-platform/map/blob/main/docs/content.md#without-the-slices).

## How the scripts know what to link

There are no hard-coded lists in the scripts, because lists in several places go stale.

| Source | What it gives |
| --- | --- |
| `projects.tsv` | The projects. `--check` fails if it disagrees with the disk. |
| A project's `.gitignore`, `/addons/<name>` lines | The addons that project needs. |
| `# bootstrap-link: <repo>/<path>` above an ignored path | A content folder from another repository. |
| `# bootstrap-optional` above an addon line | An optional pack. Linked by default, skipped with `--min`. |
| `# bootstrap-natives: <repo> <tag>` above an addon line | A native library. Bootstrap fetches that release and checks its `SHA256SUMS` before linking. |

`gs-workbench` is in `projects.tsv` and is linked into every game and `gs-game-template`.

## Windows copies, Linux links

`bootstrap.sh` makes relative symlinks. `bootstrap.ps1` copies each addon folder, because Godot 4.7 does not register `class_name` scripts through Windows junctions (`-Junction` opts back in; `--copy` on Linux copies). After a `git pull` on Windows, re-run `.\bootstrap.ps1 -Links`. If Git checks a symlink out as a plain file (`core.symlinks` false on Windows), `addons\dot_core` becomes a tiny text file and every `class_name` fails to resolve.

## Keeping stock Valve files out of commits

Stock Valve and Source assets (`.vpk`, `.vtf`, `.vmt`, `.mdl`, `.vvd`, `.vtx`, `.phy`, `.ani`, a `textures/orig` folder) never belong in a repository or a published pack. dot-cloud's `tools/check_valve_files.py` refuses them and CI runs it everywhere. To refuse them at commit time too:

```bash
tools/install-valve-hooks.sh                 # every repository in ./projects
tools/install-valve-hooks.sh /path/to/dir    # any directory of repositories
tools/install-valve-hooks.sh --check         # list repositories without the hook
```

`bootstrap.sh` runs this on every sync. The hook needs `dot-cloud` cloned next to the others; set `GS_CLOUD=/path` if it is elsewhere. Git worktrees share their repository's hooks.

## Fetching content

A repository with content on the CDN (art stores, packs) has a `content.lock.json` that lists what to fetch, pinned by hash. One fetcher reads it: `tools/fetch_lock.sh` (`tools/fetch_lock.ps1` on Windows).

```bash
../zombie-zone-maps/fetch-content.sh                 # one repository
tools/fetch_all.sh                                   # every lock file in the tree
tools/fetch_all.sh --only 'zombie-*'                 # only some
tools/fetch_all.sh --except zz-stores,mg-*-maps      # all but some
tools/fetch_lock.sh <repo>/content.lock.json --list  # what would be fetched
```

The CDN is the first of these that is set:

1. `--from` (a full origin URL or a folder).
2. `$GS_PACKS_FROM` (`none` fetches nothing).
3. `--cdn URL` or `$GS_CDN_URL`.
4. `GS_CDN_URL=` in `bootstrap/.env` (copy `.env.example`; gitignored).
5. The lock file's own `origin` and `mirrors`.
6. `https://content.gamespice.net`.

Download lists in `cfg/content/addons.yml` and `games.yml` (and `cfg/server/content/`) are respected. Packs are only mirrored when `--packs DIR` is given; otherwise `DotCloudClient` mounts them at run time. The raw art stores of `zombie-zone-maps` are fetched once and kept; set `GS_STORES_FROM=none` to skip them, or to a folder or `.tar` URL to use your own. On Windows the fetch scripts need PowerShell 7 (`pwsh`) or the Windows PowerShell 5.1 that ships with Windows 10 and later.

## Publishing from a fresh clone

dot-cloud refuses unsigned manifests, because a mounted pack can contain scripts. A fresh clone can consume the team's content but cannot publish its own, since private keys are never in a repository. Run:

```bash
./bootstrap.sh --content-keys     # or .\bootstrap.ps1 -ContentKeys
```

This gives the machine its own key and rewrites `dot-server-deploy/client/content.json` to trust it. That leaves the file locally modified, so do not commit it.

## Tools the importers use

`--tools` installs fastgmad, the extractor for `.gma` addon archives. dot-map-convert's BSP importer runs it. It is found through `DOTBSP_FASTGMAD`, then `PATH`, then `~/.local/bin/fastgmad`. It is opt-in so a plain sync needs only git.

| Tool | Author | Licence |
| --- | --- | --- |
| [fastgmad 0.2.1](https://github.com/WilliamVenner/fastgmad) | William Venner | Apache-2.0 |

The release zip is checked against a pinned SHA-256 before it is unpacked into `~/.local/share/fastgmad-0.2.1` (`GS_TOOLS_PREFIX` changes the prefix). Linux x86_64 and macOS are supported (macOS untested). On Windows it unpacks into `%LOCALAPPDATA%\fastgmad\0.2.1`, which you must put on `PATH` or point `DOTBSP_FASTGMAD` at (untested).

## Maintainer tools in `tools/`

These are for people working on the family itself.

| Tool | What it does |
| --- | --- |
| `shadowed_methods.py` | Finds public `func`s whose name a native Godot class already defines, which GDScript silently binds to the engine version. Run `--self-test` first. Needs `godot`. |
| `check_pushed_floors.sh` | Compares each game's published `requires.floor.json` with each addon's published API level, so a fresh clone parses. |
| `check_workbench_link.sh` | Checks that every game links GameSpice Workbench. |
| `install-valve-hooks.sh` | See above. |
| `fetch_all.sh`, `make_fetch_scripts.sh` | See "Fetching content". |
| `gpu.sh`, `heavy`, `realtime_suites.conf` | Run heavy jobs on the shared GPU and build boxes. The comments in each file explain the options. |

## Status

Built and maintained with Claude Code. The test suites pass, but little of this has been in front of real players yet. Please report rough edges by opening an issue.

## Licence

MIT. See [LICENSE](LICENSE).
