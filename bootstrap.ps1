<#
    Clone or update every project in the Dot family, wire the local-development
    addon links, and run any of the games. The Windows counterpart of
    bootstrap.sh.

        .\bootstrap.ps1                 clone what is missing, pull what is not
        .\bootstrap.ps1 -Links          only redo the links, touch no repository
        .\bootstrap.ps1 -Status         report each repository, change nothing
        .\bootstrap.ps1 -Check          verify the list against the disk
        .\bootstrap.ps1 -List           what can be played
        .\bootstrap.ps1 -Play arena     play one, offline, no server needed
        .\bootstrap.ps1 -Links -Copy    copy the addons instead of linking them

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

    This script uses directory junctions instead. A junction needs no elevation
    and no Developer Mode, and Godot follows one transparently because the
    filesystem resolves it before Godot ever sees it. The one cost is that a
    junction stores an ABSOLUTE target, so it cannot be committed and has to be
    recreated if the tree moves -- which is fine, since these links are
    gitignored on both platforms anyway and this script is how they are made.

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
    [switch]$Status,
    [switch]$Check,
    [switch]$List,
    [switch]$Copy,
    [string]$Play
)

$ErrorActionPreference = 'Continue'
$repoDir = $PSScriptRoot
$script:failed = $false
$script:junctionFailures = 0

# The directory holding the project repositories, in order of preference.
if ($Projects) {
    $projectsDir = $Projects
}
elseif (Test-Path (Join-Path $repoDir 'godot')) {
    # Sitting at a game-dev tree root.
    $projectsDir = Join-Path $repoDir 'godot'
}
elseif ((Split-Path $repoDir -Leaf) -eq 'bootstrap' -and
        (Split-Path (Split-Path $repoDir -Parent) -Leaf) -eq 'godot' -and
        (Test-Path (Join-Path (Split-Path (Split-Path $repoDir -Parent) -Parent) 'CLAUDE.md'))) {
    # This repository is itself a project directory: <tree>\godot\bootstrap.
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
# "ignore the lot" (dot-server-setup-test vendors its own with setup.sh) and
# names nothing to link.
function Get-LinksFor ($proj) {
    $gi = Join-Path $projectsDir "$proj\.gitignore"
    if (-not (Test-Path $gi)) { return @() }
    Get-Content $gi |
        ForEach-Object { if ($_ -match '^/addons/([a-z0-9_]+)\s*$') { $Matches[1] } }
}

# --- Repositories ----------------------------------------------------------

function Sync-Repo ($proj, $url) {
    $dir = Join-Path $projectsDir $proj

    if (-not (Test-Path (Join-Path $dir '.git'))) {
        if ($url -eq 'LOCAL') {
            Err $proj 'has no remote -- it exists only on the machine that made it'
            return
        }
        git clone -q $url $dir 2>$null
        if ($LASTEXITCODE -eq 0) {
            Say $proj "cloned $(git -C $dir rev-parse --short HEAD 2>$null)" 'Green'
            if ($Hub) { git -C $dir remote add hub "$Hub/$proj.git" 2>$null | Out-Null }
        } else {
            Err $proj "clone failed from $url"
        }
        return
    }

    if ($url -eq 'LOCAL') {
        Warn $proj 'no remote; nothing to pull. Push it or it stays on that machine.'
        return
    }

    # Never clobber work in progress: any machine may hold the only copy.
    $dirty = @(git -C $dir status --porcelain)
    if ($dirty.Count -gt 0) { Warn $proj "dirty, left alone ($($dirty.Count) file(s))"; return }

    $before = git -C $dir rev-parse --short HEAD
    git -C $dir pull -q --ff-only 2>$null
    if ($LASTEXITCODE -ne 0) { Err $proj 'pull refused - diverged, or no upstream. Resolve by hand.'; return }

    $after = git -C $dir rev-parse --short HEAD
    if ($before -eq $after) { Say $proj "up to date $after" 'DarkGray' }
    else                    { Say $proj "updated $before -> $after" 'Green' }
}

# --- Links -----------------------------------------------------------------

function Link-Addons ($proj) {
    $addons = @(Get-LinksFor $proj)
    if ($addons.Count -eq 0) { return }

    $dir = Join-Path $projectsDir $proj
    if (-not (Test-Path $dir)) { return }

    $addonDir = Join-Path $dir 'addons'
    New-Item -ItemType Directory -Force -Path $addonDir | Out-Null

    $made = 0
    foreach ($addon in $addons) {
        # dot_user_avatar -> dot-user-avatar. True for every link in the family.
        $src    = $addon -replace '_', '-'
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
        if ($Copy) {
            Copy-Item -Path $target -Destination $link -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path (Join-Path $link 'plugin.cfg')) { $made++ }
            else { Err $proj "copy failed: $addon" }
            continue
        }

        # Capture WHY rather than swallowing it. -ErrorAction SilentlyContinue
        # here cost a debugging session: every junction on an F: drive failed,
        # the script said only "junction failed", and the symptom the user saw
        # was 37 GDScript parse errors in files that were perfectly fine.
        #
        # The most likely reason is the filesystem. A junction is an NTFS
        # reparse point: on exFAT or FAT32 -- which plenty of secondary and
        # external drives are -- it cannot be created at all.
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
    Say $proj "linked $made addon(s)" 'DarkGray'
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
        'C:\Godot'
    )
    foreach ($g in $guesses) {
        if (Test-Path $g) {
            $exe = Get-ChildItem $g -Filter 'Godot*.exe' -Recurse -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

# A game is a project whose directory begins with game-. Every one of them sets
# run/main_scene to something a person can sit down at, so there is no list of
# scenes here either.
function Get-Games { Get-Projects | Where-Object { $_.Name -like 'game-*' } }

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
    $proj = $want
    if ($proj -notlike 'game-*') { $proj = "game-$proj" }

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

    # --offline is what the clients that have a networked mode read to skip it;
    # the ones that do not have one ignore an unknown user argument. Either way
    # this needs no server, no dot-cloud and no downloads.
    Write-Host "$bin --path $dir -- --offline" -ForegroundColor Cyan
    & $bin --path $dir -- --offline
}

# --- Modes -----------------------------------------------------------------

if ($Play)        { Play-Game $Play; exit 0 }
elseif ($List)    { List-Games; exit 0 }
elseif ($Check)   { Check-List }
elseif ($Status)  {
    Write-Host "projects: $projectsDir`n"
    foreach ($p in Get-Projects) { Status-Repo $p.Name }
}
elseif ($Links)   {
    foreach ($p in Get-Projects) { Link-Addons $p.Name }
}
else {
    New-Item -ItemType Directory -Force -Path $projectsDir | Out-Null
    Write-Host "projects: $projectsDir"
    Write-Host "base:     $GitBase`n"
    # Repositories first, all of them, then links -- a link can point into a
    # project this same run is about to clone.
    foreach ($p in Get-Projects) { Sync-Repo $p.Name $p.Url }
    Write-Host ''
    foreach ($p in Get-Projects) { Link-Addons $p.Name }
}

Write-Host ''

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
