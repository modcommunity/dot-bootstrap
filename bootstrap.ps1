<#
    Clone or update every project in the Dot family, wire the local-development
    addon links, and run any of the games. The Windows counterpart of
    bootstrap.sh.

        .\bootstrap.ps1                 clone what is missing, pull what is not
        .\bootstrap.ps1 -Links          only redo the links, touch no repository
        .\bootstrap.ps1 -ContentKeys    make a content signing keypair, to publish packs
        .\bootstrap.ps1 -Tools         install fastgmad (.gma unpacker), checksum-verified
        .\bootstrap.ps1 -Status         report each repository, change nothing
        .\bootstrap.ps1 -Check          verify the list against the disk
        .\bootstrap.ps1 -List           what can be played
        .\bootstrap.ps1 -Play arena     play one, offline, no server needed
        .\bootstrap.ps1 -Links -Copy    copy the addons instead of linking them
        .\bootstrap.ps1 -Ssh            clone over SSH (to push from this machine); HTTPS is the default
        .\bootstrap.ps1 -Only arena,wipeout     only these, plus the addon and map repos they need
        .\bootstrap.ps1 -Only 'mg-*' -NoDeps    only these, and nothing they need
        .\bootstrap.ps1 -Import                 import every game headless (the editor can crash on a first import); -Only narrows it
        .\bootstrap.ps1 -DiscardGenerated       when an update is blocked, restore every modified .import/.uid file and retry
        .\bootstrap.ps1 game-arena mg-wipeout  the same as -Only (names, short forms, wildcards)
        .\bootstrap.ps1 -Games arena,wipeout -Addons dot-core   games and/or addons by kind
        .\bootstrap.ps1 zees-games             every game, with the addons and content it needs
        .\bootstrap.ps1 -ZeesGamesMin          every game, base repository + addons only
        .\bootstrap.ps1 mg-wipeout -Min        -Min: no maps, weapon, monster or other content packs
        .\bootstrap.ps1 -Plan [selection]      print what would be cloned and linked, change nothing

    -Only works with every mode (sync, -Links, -Status). A name is a project
    from projects.tsv, or its short form (arena = game-arena, wipeout =
    mg-wipeout, core = dot-core), or a wildcard. Set $env:DOT_ONLY to make a
    selection stick. Addons are copied (or linked) into the named projects only.
    Selecting a game also selects the addons it requires and the content it links
    (maps, courses, optional weapon and monster packs) unless -Min. With no
    selection at all, EVERYTHING is cloned and linked.

    WHERE IT PUTS THINGS

    A fresh clone of this repository on its own clones everything into
    .\projects, beside this script, and that directory is gitignored. Nothing
    else is needed: clone this, run it, play a game.

    It also recognises the layout it was born in, where this repository sits at
    godot\bootstrap inside the game-dev tree and its siblings are the projects.
    Then it uses that godot\ directory rather than making a second copy of
    everything. Override either with -Projects, or $env:DOT_PROJECTS.

    Clone from somewhere else:  -GitBase git@gitlab.example/mine
    Also add a second remote called `hub` (bare repos on a dev box):
        -Hub ssh://you@10.50.0.185/home/you/git

    WHY THIS IS NOT JUST bootstrap.sh UNDER GIT BASH

    The links. On Linux they are relative symlinks and cost nothing. On Windows
    a symlink (mklink /D, or New-Item -ItemType SymbolicLink) requires either
    Developer Mode or an elevated prompt, and Git for Windows will not create
    one at all unless core.symlinks is true.

    Directory junctions were the answer to that -- no elevation, no Developer
    Mode -- and MEASURED, Godot does not follow them. On Windows 11 with Godot
    4.7.2 the eight junctions in game-arena\addons existed and Explorer walked
    them, and Godot registered not one class_name from any of them. So this
    script COPIES the addon folders by default; -Junction opts back in. The cost
    is that a copy does not track its source, so -Links must be re-run after a
    pull.

    The failure this avoids is worth naming, because it does not look like a
    link problem. If Git checks a symlink out as a regular file -- which is what
    it does when core.symlinks is false -- then addons\dot_core is a ~30 byte
    text file containing "../../dot-core/addons/dot_core". Godot loads it, finds
    no scripts, and every class_name the addon defines fails to resolve. In
    GDScript a script that merely MENTIONS an unknown class_name fails to parse,
    and takes every script referencing it down too, so the symptom is dozens of
    unrelated parse errors in files you did not touch.

    WHY THERE ARE NO LISTS IN THIS FILE

    The version this replaces carried its own copy of the project manifest AND
    of the addons each project needs -- a second copy of what bootstrap.sh had,
    and both had gone stale at 19 of 33 projects. Now the projects come from
    projects.tsv, which both scripts read, and the addons come out of each
    project's own .gitignore. See bootstrap.sh for the longer version.
#>

[CmdletBinding()]
param(
    [string]$Projects = $(if ($env:DOT_PROJECTS) { $env:DOT_PROJECTS } else { '' }),
    [string]$GitBase  = $(if ($env:DOT_GIT_BASE) { $env:DOT_GIT_BASE } else { 'git@github.com:modcommunity' }),
    [string]$Hub      = $(if ($env:DOTHUB) { $env:DOTHUB } else { '' }),
    [switch]$Links,
    [switch]$ContentKeys,
    [switch]$Tools,
    [switch]$Status,
    [switch]$Check,
    [switch]$List,
    [switch]$Copy,
    [switch]$Junction,
    [switch]$Https,
    [switch]$Ssh,
    [string[]]$Only = $(if ($env:DOT_ONLY) { $env:DOT_ONLY -split '[,\s]+' } else { @() }),
    [switch]$NoDeps,
    [switch]$DiscardGenerated,
    [switch]$Import,
    [switch]$Min,
    [switch]$ZeesGamesMin,
    [switch]$Plan,
    [string[]]$Games = @(),
    [string[]]$Addons = @(),
    [string]$Play,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Names = @()
)

$ErrorActionPreference = 'Continue'
$repoDir = $PSScriptRoot
$script:failed = $false
$script:junctionFailures = 0
$script:linksMade = 0
$script:linkedProjects = 0

# Copy the addon folders rather than junctioning them, unless -Junction is asked
# for explicitly.
#
# Junctions were the original design and the reasoning was sound -- no elevation,
# no Developer Mode, and the filesystem resolves them before Godot sees them.
# Measured, the last clause is false. On Windows 11 with Godot 4.7.2 the eight
# junctions in game-arena\addons existed, Explorer walked them, and Godot
# registered not one class_name from any of them: every Dot* identifier came back
# "not declared in the current scope" and seventy-odd scripts failed to parse.
# Copying the same folders fixed it outright.
#
# A link that the engine will not follow is not a link, so the default is the one
# that works. It is also what this family's own documentation says a consumer
# does: "consumers copy the addon folders into their own project instead".
$useCopy = -not $Junction

# Whether to reach GitHub over HTTPS instead of SSH. HTTPS is the default: every
# repository in projects.tsv is public, so HTTPS reads them with no credentials on
# any machine, while SSH fails on every machine without a key -- which is most of
# the ones this script is run on.
#
# -Ssh restores SSH for a machine that pushes. It still falls back to HTTPS,
# latched, the first time an SSH clone fails and the HTTPS one works. -Https is
# the default and still accepted.
#
# An EXISTING clone keeps its origin either way. In HTTPS mode a pull from an SSH
# origin goes over HTTPS for that one command (url.<https>.insteadOf), so a
# keyless machine can update while a machine with a key can still push.
$script:useHttps  = -not $Ssh
$script:httpsNoted = $false

# git@host:path -> https://host/path, ssh://git@host/path -> https://host/path.
# Anything else comes back unchanged, so a local path or an existing https URL
# passes straight through.
function ConvertTo-HttpsUrl ($u) {
    if ($u -match '^ssh://(?:[^@/]+@)?(.+)$') { return "https://$($Matches[1])" }
    if ($u -match '^(?:[^@/]+@)([^:/]+):(.+)$') { return "https://$($Matches[1])/$($Matches[2])" }
    return $u
}

function Note-Https {
    if ($script:httpsNoted) { return }
    $script:httpsNoted = $true
    Write-Host ''
    Write-Host 'SSH to GitHub is not available here, so this is falling back to HTTPS.' -ForegroundColor Yellow
    Write-Host 'The Dot assets are public, so cloning and pulling need no credentials.' -ForegroundColor Yellow
    Write-Host 'Pushing does: these clones get an https:// origin, and a push over it' -ForegroundColor Yellow
    Write-Host 'wants a personal access token rather than your key. Add an SSH key to' -ForegroundColor Yellow
    Write-Host 'GitHub to get one you can push from.' -ForegroundColor Yellow
    Write-Host ''
}

# `git -c ...` arguments that send one command over HTTPS when origin is SSH.
# Empty when it is not, or when HTTPS mode is off.
function Get-HttpsArgs ($origin) {
    if (-not $script:useHttps) { return @() }
    if     ($origin -match '^(ssh://[^/]+/)') { $prefix = $Matches[1] }
    elseif ($origin -match '^([^@/]+@[^:/]+:)') { $prefix = $Matches[1] }
    else   { return @() }
    return @('-c', "url.$(ConvertTo-HttpsUrl $prefix).insteadOf=$prefix")
}

# The directory holding the project repositories, in order of preference.
if ($Projects) {
    $projectsDir = $Projects
}
elseif (Test-Path (Join-Path $repoDir 'godot')) {
    # Sitting at a game-dev tree root.
    $projectsDir = Join-Path $repoDir 'godot'
}
elseif ((Split-Path $repoDir -Leaf) -in @('dot-bootstrap', 'bootstrap') -and
        (Split-Path (Split-Path $repoDir -Parent) -Leaf) -eq 'godot' -and
        (Test-Path (Join-Path (Split-Path (Split-Path $repoDir -Parent) -Parent) 'CLAUDE.md'))) {
    # This repository is itself a project directory: <tree>\godot\dot-bootstrap.
    #
    # Both leaf names, because this repository was renamed from `bootstrap` and a
    # clone made before that is still a correct clone. A name test that only knows
    # today's name sends an existing checkout down the standalone branch, where it
    # clones the whole family a second time into .\projects.
    #
    # All THREE conditions, because the obvious one-condition version of this
    # test -- "is my parent called godot" -- silently ate a real setup. A clone
    # at F:\Godot\tmc-dot-bootstrap has a parent whose leaf is "Godot", and
    # PowerShell's -eq is case-INSENSITIVE, so it matched: everything was cloned
    # to F:\Godot as siblings of this repository instead of into .\projects, and
    # the only sign was one line of output nobody had a reason to read.
    #
    # Bash's = is case-sensitive, so bootstrap.sh would have taken the other
    # branch for the same path -- the same repository laying two machines out
    # differently depending on how a folder happened to be capitalised.
    $projectsDir = Split-Path $repoDir -Parent
}
else {
    # A standalone clone. Everything goes beside this script, and .gitignore
    # already has /projects/ so none of it is ever offered back to this repo.
    $projectsDir = Join-Path $repoDir 'projects'
}

$listFile = Join-Path $repoDir 'projects.tsv'
if (-not (Test-Path $listFile)) {
    Write-Host "missing projects.tsv beside $repoDir" -ForegroundColor Red; exit 2
}

function Say  ($n, $m, $c = 'Gray') { Write-Host ("{0,-22} " -f $n) -NoNewline; Write-Host $m -ForegroundColor $c }
function Ok   ($n, $m)              { Say $n $m 'Green' }
function Warn ($n, $m)              { Say $n $m 'Yellow' }
function Err  ($n, $m)              { Say $n $m 'Red'; $script:failed = $true }

# --- The list --------------------------------------------------------------

# name<TAB>url, comments and blank lines dropped. One file, read by both scripts.
function Get-Projects {
    Get-Content $listFile |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' } |
        ForEach-Object {
            $parts = $_ -split "`t"
            [pscustomobject]@{ Name = $parts[0].Trim(); Url = $parts[1].Trim() }
        }
}

# The addons a project needs linked in, read out of its own .gitignore. A
# project's own addon is never in there -- dot-net ignores dot_core and ships
# dot_net -- which is exactly the distinction wanted. A bare "/addons/" means
# "ignore the lot" (dot-server-deploy vendors its own with setup.sh) and
# names nothing to link.
function Get-LinksFor ($proj) {
    $gi = Get-GitignorePath $proj
    if (-not (Test-Path $gi)) { return @() }
    $skip = if ($script:minMode) { @(Get-OptionalFor $proj) } else { @() }
    Get-Content $gi |
        ForEach-Object { if ($_ -match '^/addons/([a-z0-9_]+)\s*$') { $Matches[1] } } |
        Where-Object { $skip -notcontains $_ }
}

# Addons a project marks optional (a weapon or monster pack it runs without): a
# "# bootstrap-optional" comment line directly above the /addons/<name> line.
function Get-OptionalFor ($proj) {
    $gi = Get-GitignorePath $proj
    if (-not (Test-Path $gi)) { return @() }
    $o = $false
    foreach ($line in Get-Content $gi) {
        if ($line -match '^# bootstrap-optional') { $o = $true; continue }
        if ($o -and $line -match '^/addons/([a-z0-9_]+)\s*$') { $Matches[1] }
        $o = $false
    }
}

# A project's .gitignore: its checkout, else (for -Plan) the one in $env:DOT_PLAN_FROM.
function Get-GitignorePath ($proj) {
    $here = Join-Path $projectsDir "$proj\.gitignore"
    if ((Test-Path $here) -or -not $env:DOT_PLAN_FROM) { return $here }
    return (Join-Path $env:DOT_PLAN_FROM "$proj\.gitignore")
}

# Which repository an addon comes from. bootstrap.sh's addon_source has the reasoning:
# the name rule misses a game's own pack (zee_weapons is in zee-dot-weapons), so ask the
# checkouts for the project that has the folder and does not ignore it.
function Get-AddonSource ($addon) {
    $src = $addon -replace '_', '-'
    if (Test-Path (Join-Path $projectsDir "$src\addons\$addon")) { return $src }
    foreach ($d in Get-ChildItem -Path $projectsDir -Directory -ErrorAction SilentlyContinue) {
        if (-not (Test-Path (Join-Path $d.FullName "addons\$addon")) -or -not (Test-Path (Join-Path $d.FullName '.git'))) { continue }
        # Git's own answer, not a line match: dot-server-deploy ignores /addons/ whole.
        git -C $d.FullName check-ignore -q "addons/$addon" 2>$null
        if ($LASTEXITCODE -eq 0) { continue }
        return $d.Name
    }
    return $src
}

# --- Selecting -------------------------------------------------------------
#
# bootstrap.sh's "Selecting" has the reasoning: what a project needs comes out of its
# .gitignore, so it is only known once the project is cloned, and a sync walks it as
# a queue -- clone, read, enqueue what it names.

function Test-Listed ($name) { [bool](Get-Projects | Where-Object { $_.Name -eq $name }) }

# A name as typed -> the projects it means, or nothing.
function Resolve-Name ($n) {
    if ($n -in @('zees-games', 'games')) { return @(Get-Games | ForEach-Object { $_.Name }) }
    if ($n -eq 'addons') { return @(Get-Projects | Where-Object { $_.Name -like 'dot-*' } | ForEach-Object { $_.Name }) }
    if ($n -match '[*?\[]') { return @(Get-Projects | Where-Object { $_.Name -like $n } | ForEach-Object { $_.Name }) }
    foreach ($p in @($n, "game-$n", "mg-$n", "dot-$n")) { if (Test-Listed $p) { return @($p) } }
    return @()
}

# The listed repository an addon comes from, clone or no clone: the name rule, then a
# checkout that owns it, then the listed name it matches with every "dot-" taken out
# (zee_weapons is zee-dot-weapons; no two names in projects.tsv are equal that way).
function Get-AddonRepo ($addon) {
    $src = $addon -replace '_', '-'
    if (Test-Listed $src) { return $src }
    $owner = Get-AddonSource $addon
    if ((Test-Listed $owner) -and (Test-Path (Join-Path $projectsDir "$owner\addons\$addon"))) { return $owner }
    $bare = $src -replace 'dot-', ''
    foreach ($p in Get-Projects) { if (($p.Name -replace 'dot-', '') -eq $bare) { return $p.Name } }
    return $null
}

# The repositories a project's "# bootstrap-link: repo/path" lines name.
function Get-ContentRepos ($proj) {
    if ($script:minMode) { return @() }
    $gi = Get-GitignorePath $proj
    if (-not (Test-Path $gi)) { return @() }
    Get-Content $gi | ForEach-Object {
        if ($_ -match '^# bootstrap-link: ([^/\s]+)') { $Matches[1] }
    }
}

function Get-Deps ($proj) {
    foreach ($a in @(Get-LinksFor $proj)) { $r = Get-AddonRepo $a; if ($r) { $r } }
    foreach ($r in @(Get-ContentRepos $proj)) { if (Test-Listed $r) { $r } }
}

# The selection plus (unless -NoDeps) what it needs, in projects.tsv order. With
# -Sync, each one is cloned or pulled as it is reached, so its needs can be read.
function Get-Selected ([switch]$Sync) {
    if ($script:selection.Count -eq 0) {
        if ($Sync) { foreach ($p in Get-Projects) { Sync-Repo $p.Name $p.Url } }
        return @(Get-Projects | ForEach-Object { $_.Name })
    }
    $seen  = @{}
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($p in $script:selection) { $queue.Enqueue($p) }
    while ($queue.Count -gt 0) {
        $p = $queue.Dequeue()
        if ($seen.ContainsKey($p)) { continue }
        $seen[$p] = $true
        if ($Sync) { Sync-Repo $p ((Get-Projects | Where-Object { $_.Name -eq $p }).Url) }
        if ($NoDeps) { continue }
        foreach ($d in @(Get-Deps $p)) { $queue.Enqueue($d) }
    }
    return @(Get-Projects | Where-Object { $seen.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
}

# Where links go. With a selection, only into what was NAMED: the repositories pulled
# in for it are sources to copy from, and filling their own addons folders too would
# be most of the work and most of the disk.
function Get-LinkTargets {
    if ($script:selection.Count -eq 0) { return @(Get-Projects | ForEach-Object { $_.Name }) }
    return $script:selection
}

# --- Repositories ----------------------------------------------------------

function Sync-Repo ($proj, $url) {
    $dir = Join-Path $projectsDir $proj

    if (-not (Test-Path (Join-Path $dir '.git'))) {
        if ($url -eq 'LOCAL') {
            Err $proj 'has no remote -- it exists only on the machine that made it'
            return
        }
        $effective = if ($script:useHttps) { ConvertTo-HttpsUrl $url } else { $url }

        # One probe, then latch it on for every remaining project, so this costs
        # one refused connection rather than thirty-six.
        if (-not $script:useHttps) {
            $alt = ConvertTo-HttpsUrl $url
            if ($alt -ne $url) {
                git ls-remote --exit-code -h $url 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    git ls-remote --exit-code -h $alt 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $script:useHttps = $true
                        Note-Https
                        $effective = $alt
                    }
                }
            }
        }

        git clone -q $effective $dir 2>$null
        if ($LASTEXITCODE -eq 0) {
            # A repository created on GitHub and never pushed to clones fine and
            # has no HEAD, so rev-parse fails. Say so rather than leaking its
            # "fatal: Needed a single revision" to the terminal.
            $at = git -C $dir rev-parse --short HEAD 2>$null
            if ($at) { Say $proj "cloned $at" 'Green' }
            else     { Warn $proj 'cloned, empty -- nothing pushed to it yet' }
            if ($Hub) { git -C $dir remote add hub "$Hub/$proj.git" 2>$null | Out-Null }
        } else {
            Err $proj "clone failed from $effective"
        }
        return
    }

    if ($url -eq 'LOCAL') {
        Warn $proj 'no remote; nothing to pull. Push it or it stays on that machine.'
        return
    }

    # Never clobber work in progress: any machine may hold the only copy. A
    # dirty tree is still pulled, because `pull --ff-only` without --autostash
    # is already safe: git refuses, touching nothing, when an incoming commit
    # changes a file that is modified here or would overwrite an untracked one.
    # Skipping every dirty tree left a project behind over a few
    # editor-rewritten .import files nobody meant to keep.
    $dirty = @(git -C $dir status --porcelain).Count

    $origin = git -C $dir remote get-url origin 2>$null
    $net    = @(Get-HttpsArgs $origin)

    # A clone of a repository that had nothing pushed to it yet has no HEAD, and
    # pulling into it fails with "no such ref was fetched" until somebody pushes.
    # That is not an error on this machine, so it is not reported as one -- and
    # it was, as "fatal: Needed a single revision" and then a pull failure that
    # blamed SSH.
    $before = git -C $dir rev-parse --short HEAD 2>$null
    if (-not $before) {
        $heads = git @net -C $dir ls-remote --heads origin 2>$null
        if (-not $heads) { Warn $proj 'empty -- nothing pushed to it yet'; return }
    }

    $pullErr = @(git @net -C $dir pull -q --no-rebase --ff-only 2>&1 | ForEach-Object { "$_" })
    $pullOk = ($LASTEXITCODE -eq 0)
    if (-not $pullOk) {
        $errText = $pullErr -join "`n"
        # Editor-regenerated files (.uid, .import) block an update whenever the
        # editor rewrote them. They are rebuilt on open, so restore them and retry.
        if ($errText -match 'would be overwritten') {
            $gen = @($pullErr | Where-Object { $_ -match '^\s+\S' -and $_ -notmatch '^\s*(Please|Aborting|error)' } | ForEach-Object { $_.Trim() })
            if ($gen.Count -gt 0 -and @($gen | Where-Object { $_ -notmatch '\.(uid|import)$' }).Count -eq 0) {
                foreach ($f in $gen) {
                    git -C $dir ls-files --error-unmatch -- $f 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { git -C $dir checkout -- $f 2>$null | Out-Null }
                    else { Remove-Item -LiteralPath (Join-Path $dir $f) -Force -ErrorAction SilentlyContinue }
                }
                $pullErr = @(git @net -C $dir pull -q --no-rebase --ff-only 2>&1 | ForEach-Object { "$_" })
                $errText = $pullErr -join "`n"
            }
        }
        # A tag moved upstream: git refuses to overwrite the local one.
        if ($errText -match 'would clobber existing tag|tag.*already exists') {
            git @net -C $dir fetch -q --tags --force 2>&1 | Out-Null
            $pullErr = @(git @net -C $dir pull -q --no-rebase --ff-only 2>&1 | ForEach-Object { "$_" })
            $errText = $pullErr -join "`n"
        }
        # Upstream history was rewritten (an amended commit): the local commits are
        # the old copies. Keep them on a backup branch, move to upstream, keep
        # uncommitted work (--keep refuses rather than overwrite it).
        $pullOk = ($LASTEXITCODE -eq 0)
        if (-not $pullOk -and $errText -match 'Not possible to fast-forward|divergent') {
            $up = git -C $dir rev-parse '@{u}' 2>$null
            if ($up) {
                $backup = "bootstrap-backup/$(Get-Date -Format yyyyMMdd-HHmmss)"
                git -C $dir branch $backup HEAD 2>$null | Out-Null
                git -C $dir reset -q --keep $up 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $pullOk = $true
                    $n = @(git -C $dir rev-list "$up..$backup").Count
                    if ($n -gt 0) { Warn $proj "history was rewritten upstream; $n local commit(s) kept on branch $backup" }
                } else {
                    git -C $dir branch -D $backup 2>$null | Out-Null
                }
            }
        }
    }
    # -DiscardGenerated: the automatic restore above only fires when git names
    # nothing but .import/.uid files. Here every modified one goes, whatever git named.
    if (-not $pullOk -and $DiscardGenerated -and (($pullErr -join "`n") -match 'would be overwritten|commit your changes or stash')) {
        foreach ($line in @(git -C $dir status --porcelain 2>$null)) {
            $f = "$line".Substring(3).Trim('"')
            if ($f -notmatch '\.(uid|import)$') { continue }
            git -C $dir ls-files --error-unmatch -- $f 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { git -C $dir restore --staged --worktree -- $f 2>$null | Out-Null }
            else { Remove-Item -LiteralPath (Join-Path $dir $f) -Force -ErrorAction SilentlyContinue }
        }
        $pullErr = @(git @net -C $dir pull -q --no-rebase --ff-only 2>&1 | ForEach-Object { "$_" })
        $pullOk = ($LASTEXITCODE -eq 0)
        $dirty = @(git -C $dir status --porcelain 2>$null).Count
    }
    if (-not $pullOk) {
        $alt = ConvertTo-HttpsUrl $origin
        if ($dirty -gt 0 -and ($pullErr -join "`n") -match 'would be overwritten|commit your changes or stash') {
            # The update touches files changed here. Name them, so the choice
            # between committing and discarding is made by somebody looking.
            $files = @($pullErr | Where-Object { $_ -match '^\s+\S' -and $_ -notmatch '^\s*(Please|Aborting)' } |
                       ForEach-Object { $_.Trim() } | Select-Object -First 5) -join ' '
            if (-not $files) { $files = 'see git status' }
            Warn $proj "dirty, not updated: the update changes files modified here ($files)"
            Say  ''    '  commit or discard them, then run this again (generated .import/.uid files: add -DiscardGenerated)'
        } elseif ($alt -eq $origin) {
            Err $proj 'pull refused - diverged, or no upstream. Resolve by hand.'
            $why = @($pullErr | Where-Object { $_ } | Select-Object -First 4) -join ' | '
            if ($why) { Say '' "  git said: $why" }
        } elseif ($script:useHttps) {
            Err $proj 'pull failed over HTTPS too - diverged, no upstream, or not reachable. Resolve by hand.'
        } else {
            Err  $proj 'pull failed. origin is SSH; if you have no key here, drop -Ssh, or run:'
            Say  ''    "  git -C `"$dir`" remote set-url origin $alt"
        }
        return
    }

    $after = git -C $dir rev-parse --short HEAD
    $kept  = if ($dirty -gt 0) { " (kept $dirty uncommitted file(s))" } else { '' }
    if (-not $before)           { Say $proj "first commits $after$kept" 'Green' }
    elseif ($before -eq $after) { Say $proj "up to date $after$kept" 'DarkGray' }
    else                        { Say $proj "updated $before -> $after$kept" 'Green' }
}

# --- Links -----------------------------------------------------------------

function Link-Addons ($proj) {
    # NOTHING here returns silently. The version this replaces began with
    # `if ($addons.Count -eq 0) { return }` before it had even looked at the
    # project, so a run in which not one link was made printed not one line and
    # then said "ok" -- and the first thing the user saw was seventy GDScript
    # parse errors. Silence must never be how success looks.
    $dir = Join-Path $projectsDir $proj
    if (-not (Test-Path $dir)) { Warn $proj 'not cloned, so nothing to link'; return }

    $gi = Join-Path $dir '.gitignore'
    if (-not (Test-Path $gi)) {
        Warn $proj 'no .gitignore, so no addon list -- cannot link anything'
        return
    }

    $addons = @(Get-LinksFor $proj)
    if ($addons.Count -eq 0) {
        Say $proj 'needs no addons' 'DarkGray'
        return
    }

    $addonDir = Join-Path $dir 'addons'
    New-Item -ItemType Directory -Force -Path $addonDir | Out-Null

    $made = 0
    foreach ($addon in $addons) {
        $src    = Get-AddonSource $addon
        $target = Join-Path $projectsDir "$src\addons\$addon"
        $link   = Join-Path $addonDir $addon

        if (-not (Test-Path $target)) { Err $proj "source missing: $src\addons\$addon"; continue }

        # Remove whatever is there. A stale junction, or -- the case that
        # actually bites -- a plain text file Git left behind in place of a
        # symlink. Remove-Item on a junction deletes the link, not the target,
        # but -Recurse on a directory link is ambiguous across PowerShell
        # versions, so use the directory-delete that is known not to follow it.
        if (Test-Path $link) {
            $item = Get-Item $link -Force
            if ($item.LinkType) { [System.IO.Directory]::Delete($item.FullName, $false) }
            else                { Remove-Item $link -Recurse -Force }
        }

        # -Copy makes real folders instead of links. It is the family's own
        # documented consumption model -- "consumers copy the addon folders into
        # their own project instead" -- and it is the answer whenever a link
        # cannot be made or cannot be followed: a wrong filesystem, a policy, or
        # a Godot that will not descend a reparse point out of the project.
        #
        # The cost is that a copy does not track its source, so -Links -Copy has
        # to be re-run after pulling. That is why it is a switch and not the
        # default.
        if ($useCopy) {
            Copy-Item -Path $target -Destination $link -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path (Join-Path $link 'plugin.cfg')) { $made++ }
            else { Err $proj "copy failed: $addon" }
            continue
        }

        # Capture WHY rather than swallowing it. -ErrorAction SilentlyContinue
        # said only "junction failed" and threw the reason away, which is the
        # wrong thing to do about a failure whose symptom is dozens of GDScript
        # parse errors in files nobody touched.
        #
        # A junction is an NTFS reparse point, so on exFAT or FAT32 -- which
        # plenty of second and external drives are -- it cannot be made at all.
        #
        # Note that a junction being MADE is not the same as Godot following it.
        # On the setup this was written for the eight junctions existed and were
        # traversable in Explorer, and Godot still registered no class_name from
        # any of them. That is what -Copy is for.
        $problem = $null
        New-Item -ItemType Junction -Path $link -Target $target -ErrorAction SilentlyContinue -ErrorVariable problem | Out-Null

        if (Test-Path $link) {
            $made++
        } else {
            $why = if ($problem) { $problem[0].Exception.Message } else { 'no error reported' }
            Err $proj "junction failed: $addon -- $why"
            $script:junctionFailures++
        }
    }
    $script:linksMade += $made
    $script:linkedProjects++
    $verb = if ($useCopy) { 'copied' } else { 'linked' }
    Say $proj "$verb $made addon(s)" 'DarkGray'
}

# A CONTENT directory from another repository, declared in the project's .gitignore as a
# comment line directly above the ignored path ("# bootstrap-link: g2gfast-maps/maps" over
# "/maps/imported"). bootstrap.sh's link_content has the reasoning. Copied by default and
# junctioned with -Junction, exactly like the addons.
function Link-Content ($proj) {
    if ($script:minMode) { return }
    $dir = Join-Path $projectsDir $proj
    $gi  = Join-Path $dir '.gitignore'
    if (-not (Test-Path $gi)) { return }
    $src = $null
    foreach ($line in Get-Content $gi) {
        if ($line -match '^# bootstrap-link: (\S+)(\s+ci)?\s*$') { $src = $Matches[1]; continue }
        if ($src -and $line -match '^/(.+?)/?\s*$') {
            $path   = $Matches[1] -replace '/', '\'
            $target = Join-Path $projectsDir ($src -replace '/', '\')
            $link   = Join-Path $dir $path
            # The raw art stores (a maps repo's .stores) are in no repository: $env:DOT_STORES_FROM,
            # a folder or the URL of a .tar of pbr-library and model-library, is where a checkout gets them.
            if (-not (Test-Path $target) -and (($src -split '/')[-1] -eq '.stores') -and $env:DOT_STORES_FROM `
                    -and (Test-Path (Join-Path $projectsDir ($src -split '/')[0]))) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                if ($env:DOT_STORES_FROM -match '^https?://') {
                    $tar = Join-Path $env:TEMP 'dot-stores.tar'
                    Invoke-WebRequest -Uri $env:DOT_STORES_FROM -OutFile $tar
                    tar -xf $tar -C $target
                    Remove-Item $tar -Force
                } elseif (Test-Path $env:DOT_STORES_FROM) {
                    Copy-Item -Path (Join-Path $env:DOT_STORES_FROM '*') -Destination $target -Recurse -Force -Exclude 'project', 'slices'
                }
                New-Item -ItemType File -Force -Path (Join-Path $target '.gdignore') | Out-Null
                if (-not (Test-Path (Join-Path $target 'pbr-library'))) {
                    Remove-Item $target -Recurse -Force
                    Warn $proj "staging $src from $env:DOT_STORES_FROM failed (no pbr-library in it)"
                }
            }
            if (-not (Test-Path $target)) {
                if (($src -split '/')[-1] -eq '.stores') {
                    Warn $proj "art stores missing: $src is in no repository, so maps draw low-detail art. Set `$env:DOT_STORES_FROM (a folder or the URL of a .tar of pbr-library and model-library) and run bootstrap again"
                } else {
                    Warn $proj "content missing: $src (clone $(($src -split '/')[0]) for $path)"
                }
            } elseif ((Test-Path $link) -and -not (Get-Item $link -Force).LinkType -and -not $useCopy) {
                Warn $proj "$path is a real directory, left alone (link it to $src by hand)"
            } else {
                if (Test-Path $link) {
                    $item = Get-Item $link -Force
                    if ($item.LinkType) { [System.IO.Directory]::Delete($item.FullName, $false) }
                    else                { Remove-Item $link -Recurse -Force }
                }
                New-Item -ItemType Directory -Force -Path (Split-Path $link) | Out-Null
                if ($useCopy) { Copy-Item -Path $target -Destination $link -Recurse -Force }
                else          { New-Item -ItemType Junction -Path $link -Target $target | Out-Null }
                $verb = if ($useCopy) { 'copied' } else { 'linked' }
                Say $proj "$verb $path -> $src" 'DarkGray'
            }
        }
        $src = $null
    }
}

# --- Reporting -------------------------------------------------------------

function Status-Repo ($proj) {
    $dir = Join-Path $projectsDir $proj
    if (-not (Test-Path (Join-Path $dir '.git'))) { Warn $proj 'not cloned'; return }
    $n     = @(git -C $dir status --porcelain).Count
    $br    = git -C $dir branch --show-current
    $ahead = git -C $dir rev-list --count '@{u}..HEAD' 2>$null
    $state = if ($n -eq 0) { 'clean' } else { "dirty($n)" }
    $push  = if ($ahead -eq '0') { 'pushed' } else { "$ahead unpushed" }
    Say $proj ("{0,-16} {1,-10} {2}" -f $br, $state, $push) $(if ($n -eq 0) { 'DarkGray' } else { 'Yellow' })
}

# The mechanical detector. A list that is not checked against reality is a list
# that is already wrong; this is the check.
function Check-List {
    if (-not (Test-Path $projectsDir)) { Warn '' "nothing cloned yet at $projectsDir"; return }

    $names = @(Get-Projects | ForEach-Object { $_.Name })
    # This repository is skipped when it is sitting among the projects it
    # manages: it is the thing doing the cloning, not a thing to be cloned.
    $dirs  = @(Get-ChildItem -Directory $projectsDir |
               Where-Object { $_.FullName -ne $repoDir })
    $disk  = @($dirs | Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
               ForEach-Object { $_.Name })

    foreach ($d in $disk) {
        if ($names -notcontains $d) { Err $d 'a repository on disk that projects.tsv does not list' }
    }
    foreach ($n in $names) {
        if ($disk -notcontains $n) { Warn $n 'listed in projects.tsv, not cloned here' }
    }
    foreach ($p in Get-Projects) {
        if ($p.Url -eq 'LOCAL') { Err $p.Name 'LOCAL: no remote, so a clone elsewhere cannot get it' }
    }
    # Directories that are not repositories: work in progress, or a clone that
    # failed halfway. Either way nothing else can obtain them.
    foreach ($d in $dirs) {
        if (-not (Test-Path (Join-Path $d.FullName '.git'))) {
            Warn $d.Name 'a directory beside the projects that is not a git repository'
        }
    }
    if (-not $script:failed) { Write-Host ''; Say '' 'projects.tsv agrees with the disk' 'Green' }
}

# --- Playing ---------------------------------------------------------------

function Find-Godot {
    if ($env:GODOT -and (Test-Path $env:GODOT)) { return $env:GODOT }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Where a Windows install usually lands. Newest first, so a 4.7 wins over a 4.4.
    $guesses = @(
        "$env:LOCALAPPDATA\Programs\Godot",
        "$env:ProgramFiles\Godot",
        "$env:USERPROFILE\scoop\apps\godot\current",
        'C:\Godot',
        # Next to this clone (F:\Godot\tmc-dot-bootstrap -> F:\Godot), and the usual download places.
        (Split-Path $repoDir -Parent),
        "$env:USERPROFILE\Downloads",
        "$env:USERPROFILE\Desktop"
    )
    foreach ($g in $guesses) {
        if ($g -and (Test-Path $g)) {
            # Two levels is enough for a release unzipped into its own folder, and keeps a big Downloads quick.
            # The console build is listed with the editor; either runs --headless.
            $exe = Get-ChildItem $g -Filter 'Godot*.exe' -Depth 2 -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

# A game is a project whose directory begins with game- or mg- (a maps repository is not one). Every one of them sets
# run/main_scene to something a person can sit down at, so there is no list of
# scenes here either.
function Get-Games { Get-Projects | Where-Object { ($_.Name -like 'game-*' -or $_.Name -like 'mg-*') -and $_.Name -notlike '*-maps' } }

function List-Games {
    $bin = Find-Godot
    Write-Host "projects: $projectsDir"
    if ($bin) { Write-Host "godot:    $bin" } else { Write-Host 'godot:    not found' -ForegroundColor Red }
    Write-Host ''
    foreach ($g in Get-Games) {
        $pg = Join-Path $projectsDir "$($g.Name)\project.godot"
        $scene = 'not cloned'
        if (Test-Path $pg) {
            $m = Select-String -Path $pg -Pattern 'run/main_scene="([^"]+)"' | Select-Object -First 1
            if ($m) { $scene = $m.Matches[0].Groups[1].Value }
        }
        Write-Host ("  {0,-20} " -f ($g.Name -replace '^game-','')) -NoNewline
        Write-Host $scene -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  .\bootstrap.ps1 -Play <name>'
}

function Play-Game ($want) {
    # game-<x> or mg-<x>; the short form tries each prefix.
    $proj = $want
    foreach ($c in @($want, "game-$want", "mg-$want")) {
        if (Get-Games | Where-Object { $_.Name -eq $c }) { $proj = $c; break }
    }

    if (-not (Get-Games | Where-Object { $_.Name -eq $proj })) {
        Write-Host "no such game: $want" -ForegroundColor Red
        List-Games
        exit 2
    }
    $dir = Join-Path $projectsDir $proj
    if (-not (Test-Path $dir)) {
        Write-Host "$proj is not cloned yet. Run .\bootstrap.ps1 first." -ForegroundColor Red
        exit 2
    }

    $bin = Find-Godot
    if (-not $bin) {
        Write-Host 'Godot was not found. Set $env:GODOT to the executable.' -ForegroundColor Red
        exit 3
    }

    # Import first. Godot imports a file only when the editor (or --import) scans it, so a
    # game started straight after a pull has the new models' .glb and .import files and no
    # imported scene: on 2026-10-13 every person in three games was a fallback capsule for
    # exactly that. A pass over an up-to-date cache takes seconds. Piping to Out-Null makes
    # PowerShell wait for the GUI-subsystem executable to exit.
    Write-Host "importing $proj" -ForegroundColor Cyan
    & $bin --headless --path $dir --import 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host 'the import pass failed; playing anyway' -ForegroundColor Yellow }

    # --offline is what the clients that have a networked mode read to skip it;
    # the ones that do not have one ignore an unknown user argument. Either way
    # this needs no server, no dot-cloud and no downloads.
    Write-Host "$bin --path $dir -- --offline" -ForegroundColor Cyan
    & $bin --path $dir -- --offline
}

# --- Content keys ----------------------------------------------------------

# A CONTENT SIGNING KEYPAIR, for a developer who wants to PUBLISH packs locally.
#
# dot-cloud refuses unsigned manifests, and it should: a mounted pack can contain
# scripts, so a client that mounts unsigned content runs whatever the server sent.
# That means publishing needs a private key, and a private key is the one thing a
# clone can never carry -- keys\ is gitignored in dot-server-deploy precisely so it
# cannot arrive in a commit.
#
# So a fresh clone can CONSUME the team's content (the public half is committed in
# client\content.json) and cannot PUBLISH any. This makes it able to, with its own
# identity, and rewrites content.json to trust that identity instead -- which will
# show as a local modification to a committed file. That is the honest trade and the
# reason this is opt-in rather than part of a plain sync: overwriting it silently
# would leave somebody wondering why their client rejects the team's packs.
# fastgmad, the community addon-archive (.gma) extractor that dot-map's BSP importer shells
# out to. Opt-in for the same reason as -ContentKeys: a plain sync needs git and nothing
# else. Pinned to one release and refused unless its SHA-256 matches. Installed under
# %LOCALAPPDATA%\fastgmad\<version> with the helper DLLs beside it; add that folder to PATH
# or set DOTBSP_FASTGMAD to the exe (dotbsp does not look there on its own).
function Install-Tools {
    $ver = '0.2.1'
    $sum = 'f093eebeffd0871513042a49ecda5a0d2902e278225679ac857a583cfb6e2d9f'
    $root = if ($env:DOT_TOOLS_PREFIX) { $env:DOT_TOOLS_PREFIX } else { Join-Path $env:LOCALAPPDATA 'fastgmad' }
    $dest = Join-Path $root $ver
    if (Test-Path (Join-Path $dest 'fastgmad.exe')) { Ok 'fastgmad' "already installed ($dest)"; return $true }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'fastgmad_windows.zip'
    try {
        if ($env:DOT_FASTGMAD_ZIP) { Copy-Item $env:DOT_FASTGMAD_ZIP $zip }
        else { Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/WilliamVenner/fastgmad/releases/download/v$ver/fastgmad_windows.zip" -OutFile $zip }
        $got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
        if ($got -ne $sum) { Err 'fastgmad' "checksum mismatch (got $got); nothing installed"; return $false }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Expand-Archive -Force -Path $zip -DestinationPath $dest
        Ok 'fastgmad' "$ver installed in $dest; put it on PATH or set DOTBSP_FASTGMAD"
        return $true
    } catch { Err 'fastgmad' $_.Exception.Message; return $false }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

function New-ContentKeys {
    $deploy = Join-Path $projectsDir 'dot-server-deploy'
    if (-not (Test-Path $deploy)) {
        Warn 'dot-server-deploy' 'not cloned yet; run a sync first'
        return $false
    }

    $godot = Find-Godot
    if (-not $godot) {
        Err 'content keys' 'Godot was not found. Set $env:GODOT to the executable.'
        return $false
    }

    $keyDir = Join-Path $deploy 'keys'
    $priv   = Join-Path $keyDir 'content.key'
    $pub    = Join-Path $keyDir 'content.pub'

    if (Test-Path $priv) {
        Ok 'content keys' "already present ($keyDir)"
    }
    else {
        New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
        Push-Location $deploy
        try {
            & $godot --headless --path . `
                --script addons/dot_cloud/publish/dot_cloud_cli.gd -- `
                keygen --private keys/content.key --public keys/content.pub 2>&1 | Out-Null
        }
        finally { Pop-Location }

        if (-not (Test-Path $priv)) {
            Err 'content keys' 'keygen failed'
            return $false
        }
        Ok 'content keys' "generated in $keyDir"
    }

    $pem = (Get-Content $pub -Raw).Trim()
    $cfg = Join-Path $deploy 'client\content.json'

    # Rebuilt rather than edited in place, and ordered, so require_signed_manifests
    # and trusted_keys land in the same order bootstrap.sh puts them in. The
    # indentation still differs from that script's -- ConvertTo-Json is not python's
    # json -- and that is fine, because this file is expected to be locally modified
    # and not committed: it now names THIS machine's key, which no other machine has.
    $doc = [ordered]@{}
    if (Test-Path $cfg) {
        $existing = Get-Content $cfg -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) { $doc[$prop.Name] = $prop.Value }
    }
    $doc['require_signed_manifests'] = $true
    $doc['trusted_keys'] = [ordered]@{ default = $pem }

    New-Item -ItemType Directory -Force -Path (Split-Path $cfg -Parent) | Out-Null
    # -Depth, because ConvertTo-Json defaults to 2 and would render trusted_keys as
    # the string "System.Collections.Specialized.OrderedDictionary".
    Set-Content -Path $cfg -Value (($doc | ConvertTo-Json -Depth 10) + "`n") -Encoding UTF8 -NoNewline
    Write-Host "  client\content.json now trusts this machine's key"
    return $true
}

# --- Modes -----------------------------------------------------------------

# A name that matches nothing is an error, not an empty selection: an empty one would
# quietly mean "everything", the opposite of what was asked.
$script:selection = @()
$script:minMode = [bool]($Min -or $ZeesGamesMin)
function Add-Selection ($flag, $kind, $list) {
    foreach ($n in @($list | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })) {
        $hit = @(Resolve-Name $n)
        if ($hit.Count -eq 0) { Write-Host "${flag}: no project or group called '$n' in projects.tsv (try -List for the games)" -ForegroundColor Red; exit 2 }
        $gameNames = @(Get-Games | ForEach-Object { $_.Name })
        foreach ($h in $hit) {
            if ($kind -eq 'game'  -and $gameNames -notcontains $h) { Write-Host "${flag}: '$h' is not a game" -ForegroundColor Red; exit 2 }
            if ($kind -eq 'addon' -and $gameNames -contains $h)    { Write-Host "${flag}: '$h' is a game, not an addon (use -Games)" -ForegroundColor Red; exit 2 }
        }
        $script:selection += $hit
    }
}
$namesAll = @($Names)
if ($ZeesGamesMin) { $namesAll += 'zees-games' }
Add-Selection '-Only' 'any' $Only
Add-Selection 'name' 'any' $namesAll
Add-Selection '-Games' 'game' $Games
Add-Selection '-Addons' 'addon' $Addons
# -Min on its own means every game, base only.
if ($script:minMode -and $script:selection.Count -eq 0) { Add-Selection '-Min' 'game' @('zees-games') }
$script:selection = @($script:selection | Select-Object -Unique)

# What a sync would clone and link for this selection, from .gitignore files alone. A
# project that is not cloned is read from $env:DOT_PLAN_FROM (default: the projects dir).
function Show-Plan {
    if (-not $env:DOT_PLAN_FROM) { $env:DOT_PLAN_FROM = $projectsDir }
    $sel = if ($script:selection.Count -gt 0) { $script:selection -join ' ' } else { 'everything' }
    $tag = "$(if ($script:minMode) { ' (min: no content packs)' })$(if ($NoDeps) { ' (no deps)' })"
    Write-Output "selection: $sel$tag"
    foreach ($p in Get-Selected) {
        if (Test-Path (Join-Path $projectsDir "$p\.git")) { Write-Output "have $p" } else { Write-Output "clone $p" }
    }
    foreach ($p in Get-LinkTargets) {
        foreach ($a in @(Get-LinksFor $p)) { Write-Output "link $p addon $a" }
        if ($script:minMode) { continue }
        $gi = Get-GitignorePath $p
        if (-not (Test-Path $gi)) { continue }
        $src = $null
        foreach ($line in Get-Content $gi) {
            if ($line -match '^# bootstrap-link: (\S+)(\s+ci)?\s*$') { $src = $Matches[1]; continue }
            if ($src -and $line -match '^/(.+?)/?\s*$') { Write-Output "link $p content $($Matches[1]) -> $src" }
            $src = $null
        }
    }
}

if ($Plan)        { Show-Plan; exit 0 }
if ($Play)        { Play-Game $Play; exit 0 }
elseif ($List)    { List-Games; exit 0 }
elseif ($Check)   { Check-List }
elseif ($Status)  {
    Write-Host "projects: $projectsDir`n"
    foreach ($p in Get-Selected) { Status-Repo $p }
}
elseif ($Links)   {
    foreach ($p in Get-LinkTargets) { Link-Addons $p; Link-Content $p }
}
elseif ($Import) {
    $bin = Find-Godot
    if (-not $bin) { Write-Host 'Godot was not found. Set $env:GODOT to the executable.' -ForegroundColor Red; exit 3 }
    # Games only, whatever else the selection holds; no selection means every game.
    $gameNames = @(Get-Games | ForEach-Object { $_.Name })
    $names = if ($script:selection.Count -gt 0) { @($script:selection | Where-Object { $gameNames -contains $_ }) } else { $gameNames }
    & (Join-Path $PSScriptRoot 'tools\import-all.ps1') -ProjectsDir $projectsDir -Godot $bin -Names $names
    if ($LASTEXITCODE -ne 0) { $script:failed = $true }
}
elseif ($Tools) {
    if (-not (Install-Tools)) { $script:failed = $true }
}
elseif ($ContentKeys) {
    if (-not (New-ContentKeys)) { $script:failed = $true }
}
else {
    New-Item -ItemType Directory -Force -Path $projectsDir | Out-Null
    Write-Host "projects: $projectsDir"
    Write-Host "base:     $GitBase`n"
    # Repositories first, all of them, then links -- a link can point into a
    # project this same run is about to clone.
    if ($script:selection.Count -gt 0) {
        $note = if ($NoDeps) { ' (no deps)' } else { '' }
        Write-Host "only:     $($script:selection -join ' ')$note`n"
    }
    Get-Selected -Sync | Out-Null
    Write-Host ''
    foreach ($p in Get-LinkTargets) { Link-Addons $p; Link-Content $p }
}

Write-Host ''

if ($script:linkedProjects -gt 0 -or $script:linksMade -gt 0) {
    $verb = if ($useCopy) { 'copied' } else { 'linked' }
    Write-Host "$script:linksMade addon(s) $verb across $script:linkedProjects project(s)."
}

# A junction is an NTFS reparse point. If every one of them failed, the drive is
# the reason far more often than anything in this script -- and the symptom is
# not "no addons", it is dozens of GDScript parse errors about class names that
# exist, in files nobody touched. Say so here rather than leaving it to be
# rediscovered in the Godot editor.
if ($script:junctionFailures -gt 0) {
    # NOT `$fs = try {...} catch {...}`: assigning from a try/catch statement is
    # PowerShell 7 only and is a PARSE error on the 5.1 that ships with Windows,
    # which would take this whole script down rather than report anything.
    $fs = 'unknown'
    try {
        $letter = (Split-Path $projectsDir -Qualifier).TrimEnd(':')
        $fs = (Get-Volume -DriveLetter $letter -ErrorAction Stop).FileSystemType
    } catch { }
    Write-Host "$script:junctionFailures addon link(s) could not be made. $projectsDir is $fs." -ForegroundColor Yellow
    if ($fs -and $fs -ne 'NTFS') {
        Write-Host "Junctions need NTFS. Put the projects on an NTFS drive, or pass -Projects <path on NTFS>." -ForegroundColor Yellow
    }
    Write-Host "Until they exist Godot cannot resolve any addon class_name, and every" -ForegroundColor Yellow
    Write-Host "script that mentions one fails to parse -- which looks like broken code." -ForegroundColor Yellow
    Write-Host ''
}

if ($script:failed) { Write-Host 'finished with errors' -ForegroundColor Red; exit 1 }
else                { Write-Host 'ok' -ForegroundColor Green; exit 0 }
