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
        .\bootstrap.ps1 -Export arena   build a RELEASE executable of any game into <game>\build\windows (a game with no export_presets gets a default preset; downloads the matching export template into .godot-bin, checksum-verified)
        .\bootstrap.ps1 -PlayExport arena [-PlayArgs '+bot_quota 16 --map dm_atrium']   start that build (exporting first when there is none): offline; FC also 8 players, profiler overlay, `profiler_record` in the console records 60 s (F10: 10 s); -PlayArgs go to the game and win; -Export with it rebuilds first
        .\bootstrap.ps1 -Links -Copy    copy the addons instead of linking them
        .\bootstrap.ps1 -Ssh            clone over SSH (to push from this machine); HTTPS is the default
        .\bootstrap.ps1 -Only arena,wipeout     only these, plus the addon and map repos they need
        .\bootstrap.ps1 -Only 'mg-*' -NoDeps    only these, and nothing they need
        .\bootstrap.ps1 -NoStores              do not fetch the raw art stores (about 1.6 GB, once, kept); maps draw low-detail art. Or $env:DOT_STORES_FROM = 'none'
        $env:DOT_NATIVES = 'none'               skip the native libraries a game pins (# bootstrap-natives: in its .gitignore); GDScript runs
        .\bootstrap.ps1 -Jobs N                repositories synced and games imported at most N at once (default: the CPU count; 1 = one at a time)
        .\bootstrap.ps1 -Import                 import every game headless (the editor can crash on a first import); -Only narrows it
        .\bootstrap.ps1 -GetGodot               download the latest stable Godot into .godot-bin beside this script, then carry on (sync, and -Import if given); every mode that runs Godot looks there
        .\bootstrap.ps1 -DiscardGenerated       when an update is blocked, restore every modified .import/.uid file and retry
        .\bootstrap.ps1 game-arena mg-wipeout  the same as -Only (names, short forms, wildcards)
        .\bootstrap.ps1 -Games arena,wipeout -Addons dot-core   games and/or addons by kind
        .\bootstrap.ps1 zees-games             every game, with the addons and content it needs
        .\bootstrap.ps1 -ZeesGamesMin          every game, base repository + addons only
        .\bootstrap.ps1 mg-wipeout -Min        -Min: no maps, weapon, monster or other content packs
        .\bootstrap.ps1 -Plan [selection]      print what would be cloned and linked, change nothing

    -Only works with every mode (sync, -Links, -Status). A name is a project
    from projects.tsv, or its short form (arena = game-arena, wipeout =
    mg-wipeout, core = dot-core), or another name projects.tsv lists for it
    (fatal-contact and final-contact = game-arena, airdrift = game-g2gfast,
    playlot = game-playground), or a wildcard. Set $env:DOT_ONLY to make a
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
    [int]$Jobs = [Environment]::ProcessorCount,
    [switch]$NoStores,
    [switch]$DiscardGenerated,
    [switch]$Import,
    [switch]$GetGodot,
    [switch]$Min,
    [switch]$ZeesGamesMin,
    [switch]$Plan,
    [string[]]$Games = @(),
    [string[]]$Addons = @(),
    [string]$Play,
    [string]$Export,
    [string]$PlayExport,
    [string]$PlayArgs = '',
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Names = @()
)
# Never PowerShell's progress bar: on 5.1 it slows Invoke-WebRequest (and Expand-Archive) to a crawl. Downloads go through
# tools\dot_download.ps1 (Invoke-DotDownload), which prints our own progress line: MB done / total, MB/s, ETA.
$ProgressPreference = 'SilentlyContinue'

$ErrorActionPreference = 'Continue'
$repoDir = $PSScriptRoot
$dotDownload = Join-Path $repoDir 'tools\dot_download.ps1'
. $dotDownload
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
# Every repository a sync could not bring up to date, with the reason or the fix it
# applied, listed again at the very end, so one line in 24 parallel jobs' output is not
# the only trace. Sync-Many's runspaces hand theirs back with their lines.
$script:stale = New-Object System.Collections.ArrayList
function Note-Stale ($n, $m)        { [void]$script:stale.Add(("{0,-22} {1}" -f $n, $m)) }
# A credential prompt in one of 24 parallel jobs is a hang nobody sees: a private or
# missing repository fails at once instead (Git Credential Manager still answers).
if (-not $env:GIT_TERMINAL_PROMPT) { $env:GIT_TERMINAL_PROMPT = '0' }

# --- The list --------------------------------------------------------------

# name<TAB>url, comments and blank lines dropped. One file, read by both scripts.
function Get-Projects {
    Get-Content $listFile |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' } |
        ForEach-Object {
            $parts = $_ -split "`t"
            $aka = if ($parts.Count -gt 2) { @($parts[2].Trim() -split ',' | Where-Object { $_ }) } else { @() }
            [pscustomobject]@{ Name = $parts[0].Trim(); Url = $parts[1].Trim(); Aliases = $aka }
        }
}

# The listed name an other name (third column) stands for: arena -> game-fatal-contact.
function Get-AliasTarget ($n) {
    $hit = Get-Projects | Where-Object { $_.Aliases -contains $n } | Select-Object -First 1
    if ($hit) { return $hit.Name }
    return $null
}

# The listed name for a name that may be an old one (arena-weapons -> fc-weapons); any
# other name comes back unchanged. Games' .gitignore lines still say the old names.
function Get-Canon ($n) {
    if (Get-Projects | Where-Object { $_.Name -eq $n }) { return $n }
    $a = Get-AliasTarget $n
    if ($a) { return $a }
    return $n
}

# The folder a name is on disk under: the listed name, unless only the old one is there
# (a checkout whose move Move-Renamed refused).
function Get-OnDisk ($n) {
    $c = Get-Canon $n
    if ($c -ne $n -and -not (Test-Path (Join-Path $projectsDir $c)) -and (Test-Path (Join-Path $projectsDir $n) -PathType Container)) { return $n }
    return $c
}

# The same for repo/path: g2gfast-maps/maps -> airdrift-maps/maps.
function Get-OnDiskPath ($p) {
    $parts = $p -split '/', 2
    $head = Get-OnDisk $parts[0]
    if ($parts.Count -gt 1) { return "$head/$($parts[1])" }
    return $head
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
    $there = Join-Path $env:DOT_PLAN_FROM "$proj\.gitignore"
    if (Test-Path $there) { return $there }
    # A tree whose checkouts still have their old names (game-arena for game-fatal-contact).
    $p = Get-Projects | Where-Object { $_.Name -eq $proj } | Select-Object -First 1
    if ($p) { foreach ($o in $p.Aliases) { $g = Join-Path $env:DOT_PLAN_FROM "$o\.gitignore"; if (Test-Path $g) { return $g } } }
    return $there
}

# Which repository an addon comes from. bootstrap.sh's addon_source has the reasoning:
# the name rule misses a game's own pack (zee_weapons is in zee-dot-weapons), so ask the
# checkouts for the project that has the folder and does not ignore it.
function Get-AddonSource ($addon) {
    $src = $addon -replace '_', '-'
    # The listed name first (arena_weapons is in fc-weapons), then the raw, old one.
    $c = Get-Canon $src
    if (Test-Path (Join-Path $projectsDir "$c\addons\$addon")) { return $c }
    if (Test-Path (Join-Path $projectsDir "$src\addons\$addon")) { return $src }
    foreach ($d in Get-ChildItem -Path $projectsDir -Directory -ErrorAction SilentlyContinue) {
        # An old-name junction left by a rename is not a second owner.
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
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
    $a = Get-AliasTarget $n
    if ($a) { return @($a) }
    return @()
}

# The listed repository an addon comes from, clone or no clone: the name rule, then a
# checkout that owns it, then the listed name it matches with every "dot-" taken out
# (zee_weapons is zee-dot-weapons; no two names in projects.tsv are equal that way).
function Get-AddonRepo ($addon) {
    $src = Get-Canon ($addon -replace '_', '-')
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
        if ($_ -match '^# bootstrap-link: ([^/\s]+)') { Get-Canon $Matches[1] }
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
        if ($Sync) { Sync-Many @(Get-Projects) }
        return @(Get-Projects | ForEach-Object { $_.Name })
    }
    # Dependencies are only known once a repository is on disk, so this goes in waves:
    # sync everything queued (at most -Jobs at once), read what each names, queue what is new.
    $seen = @{}
    $wave = @($script:selection)
    while ($wave.Count -gt 0) {
        $batch = @()
        foreach ($p in $wave) { if (-not $seen.ContainsKey($p)) { $seen[$p] = $true; $batch += $p } }
        if ($batch.Count -eq 0) { break }
        if ($Sync) { Sync-Many @($batch | ForEach-Object { $n = $_; Get-Projects | Where-Object { $_.Name -eq $n } }) }
        $wave = @()
        if ($NoDeps) { continue }
        foreach ($p in $batch) { foreach ($d in @(Get-Deps $p)) { $wave += $d } }
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

# Syncs the given projects (objects with Name and Url), at most $Jobs at once. Each
# repository's lines are printed whole when it finishes, so output never interleaves,
# and an error in any of them makes the run report one. A RunspacePool, because it
# exists in Windows PowerShell 5.1 too (ForEach-Object -Parallel is 7+ only).
# -Jobs 1 syncs one at a time, exactly as before.
$script:syncAnnounced = $false
function Sync-Many ($items) {
    $items = @($items)
    if (-not $script:syncAnnounced) {
        $script:syncAnnounced = $true
        $mode = if ($Jobs -le 1) { 'serial (-Jobs 1)' } else { "$Jobs parallel jobs" }
        Write-Host "syncing with $mode (PowerShell $($PSVersionTable.PSVersion))"
    }
    if ($Jobs -le 1 -or $items.Count -le 1) {
        foreach ($i in $items) { Sync-Repo $i.Name $i.Url }
        return
    }
    $defs = @{
        Sync = ${function:Sync-Repo}.ToString()
        Block = ${function:Resolve-BlockedPull}.ToString()
        Conv = ${function:ConvertTo-HttpsUrl}.ToString()
        Args = ${function:Get-HttpsArgs}.ToString()
        NetErr = ${function:Test-NetError}.ToString()
        Pull = ${function:Invoke-PullRetry}.ToString()
        Repair = ${function:Repair-Checkout}.ToString()
    }
    $shared = [hashtable]::Synchronized(@{ https = $script:useHttps })
    $ctx = @{ dir = $projectsDir; hub = $Hub; discard = [bool]$DiscardGenerated }
    $worker = {
        param($d, $c, $sh, $name, $url)
        $buf = New-Object 'System.Collections.Generic.List[object]'
        $state = @{ failed = $false; stale = New-Object 'System.Collections.Generic.List[string]' }
        function Say  ($n, $m, $col = 'Gray') { $buf.Add(@($n, $m, $col)) }
        function Warn ($n, $m)                { Say $n $m 'Yellow' }
        function Err  ($n, $m)                { Say $n $m 'Red'; $state.failed = $true }
        function Note-Https                   { $buf.Add(@('NOTE')) }
        function Note-Stale ($n, $m)          { $state.stale.Add(("{0,-22} {1}" -f $n, $m)) }
        ${function:ConvertTo-HttpsUrl} = [scriptblock]::Create($d.Conv)
        ${function:Get-HttpsArgs}      = [scriptblock]::Create($d.Args)
        ${function:Sync-Repo}          = [scriptblock]::Create($d.Sync)
        ${function:Resolve-BlockedPull} = [scriptblock]::Create($d.Block)
        ${function:Test-NetError}      = [scriptblock]::Create($d.NetErr)
        ${function:Invoke-PullRetry}   = [scriptblock]::Create($d.Pull)
        ${function:Repair-Checkout}    = [scriptblock]::Create($d.Repair)
        $projectsDir = $c.dir; $Hub = $c.hub; $DiscardGenerated = $c.discard
        $script:useHttps = $sh.https
        Sync-Repo $name $url
        if ($script:useHttps) { $sh.https = $true }
        [pscustomobject]@{ Lines = $buf.ToArray(); Failed = $state.failed; Stale = $state.stale.ToArray() }
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, $Jobs)
    $pool.Open()
    $pending = New-Object System.Collections.ArrayList
    foreach ($i in $items) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker.ToString()).AddArgument($defs).AddArgument($ctx).AddArgument($shared).AddArgument($i.Name).AddArgument($i.Url)
        [void]$pending.Add([pscustomobject]@{ Ps = $ps; Handle = $ps.BeginInvoke(); Name = $i.Name })
    }
    while ($pending.Count -gt 0) {
        foreach ($j in @($pending)) {
            if (-not $j.Handle.IsCompleted) { continue }
            $pending.Remove($j)
            $res = @($j.Ps.EndInvoke($j.Handle))
            if ($j.Ps.HadErrors -and $res.Count -eq 0) { Err $j.Name 'sync job crashed'; Note-Stale $j.Name 'sync job crashed; run again' }
            foreach ($r in $res) {
                foreach ($l in $r.Lines) {
                    if ($l[0] -eq 'NOTE') { Note-Https } else { Say $l[0] $l[1] $l[2] }
                }
                if ($r.Failed) { $script:failed = $true }
                foreach ($s in @($r.Stale)) { if ($s) { [void]$script:stale.Add($s) } }
            }
            $j.Ps.Dispose()
        }
        if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 40 }
    }
    $pool.Close(); $pool.Dispose()
    if ($shared.https) { $script:useHttps = $true }
}

# The pull was refused because tracked files are modified here. Whitespace/line-ending-only
# changes are discarded; real edits are stashed, the pull retried and the stash re-applied.
# Nothing with a real edit is ever reset: if it cannot be re-applied it stays in the stash.
# Returns $true when the pull went through; $false leaves the tree as it was found.
function Resolve-BlockedPull ($proj, $dir, $net, $pullErr) {
    $named = @($pullErr | Where-Object { $_ -match '^\s+\S' -and $_ -notmatch '^\s*(Please|Aborting|error)' } | ForEach-Object { $_.Trim() })
    $tracked = @()
    foreach ($f in $named) {
        git -C $dir ls-files --error-unmatch -- $f 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $tracked += $f }
    }
    if ($tracked.Count -eq 0) {
        $tracked = @(git -C $dir status --porcelain --untracked-files=no 2>$null | ForEach-Object { "$_".Substring(3).Trim('"') })
    }
    if ($tracked.Count -eq 0) { return $false }
    $real = @()
    foreach ($f in $tracked) {
        git -C $dir diff HEAD --ignore-space-at-eol --ignore-cr-at-eol --quiet -- $f 2>$null
        if ($LASTEXITCODE -eq 0) {
            git -C $dir restore --staged --worktree -- $f 2>$null | Out-Null
            Say $proj "${f}: line endings only, discarded" 'DarkGray'
        } else { $real += $f }
    }
    git @net -C $dir pull -q --no-rebase --ff-only 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($real.Count -eq 0) { return $false }
    git -C $dir stash push -q -m bootstrap-autostash -- @real 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    git @net -C $dir pull -q --no-rebase --ff-only 2>&1 | Out-Null
    $pulled = ($LASTEXITCODE -eq 0)
    git -C $dir stash pop -q 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if ($pulled) { Say $proj "stashed $($real.Count) file(s) ($($real -join ' ')), updated, reapplied" 'Green' }
        return $pulled
    }
    # Conflict: back to the pulled state; the stash stays saved.
    git -C $dir reset -q --merge 2>&1 | Out-Null
    Warn $proj "local edits to $($real -join ' ') conflict with the update and are kept in the stash 'bootstrap-autostash' (inspect: git -C `"$dir`" stash show -p)"
    return $pulled
}

# True when git's output says the network failed (no route, DNS, a connect timeout,
# a dropped connection), not the repository: a missing, private or refused one is
# never retried as if it were the network.
function Test-NetError ($text) {
    if ("$text" -match '(?i)repository not found|does not exist|returned error: 40\d|authentication failed|could not read username|permission denied') { return $false }
    return ("$text" -match '(?i)could not resolve (host|hostname)|failed to connect|couldn''t connect|connection (timed out|reset|refused|closed)|operation timed out|timed out after|network is unreachable|no route to host|name or service not known|temporary failure in name resolution|early eof|rpc failed|remote end hung up|unexpected disconnect|ssl_(read|connect|error)|schannel|gnutls|connect to host .* port \d+')
}

# `git pull --ff-only`, tried up to 3 times when it fails on the network (backoff 3 s,
# then 8 s), with a short SSH connect timeout and a stall limit on HTTPS so one dead
# route costs seconds, not minutes. Ok, Err (git's lines), Tries, Network.
function Invoke-PullRetry ($dir, $net) {
    $fast = @('-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=20')
    # Only when nobody chose an SSH command: GIT_SSH_COMMAND, core.sshCommand and
    # GIT_SSH (plink) all win over this.
    if (-not $env:GIT_SSH_COMMAND -and -not $env:GIT_SSH -and -not (git -C $dir config --get core.sshCommand 2>$null)) {
        $fast += @('-c', 'core.sshCommand=ssh -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3')
    }
    $out = @(); $code = 1; $tries = 0
    foreach ($wait in @(0, 3, 8)) {
        if ($wait) { Start-Sleep -Seconds $wait }
        $tries++
        $out = @(git @net @fast -C $dir pull -q --no-rebase --ff-only 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        if ($code -eq 0 -or -not (Test-NetError ($out -join "`n"))) { break }
    }
    [pscustomobject]@{ Ok = ($code -eq 0); Err = $out; Tries = $tries; Network = ($code -ne 0 -and (Test-NetError ($out -join "`n"))) }
}

# A pull that failed for a reason other than the network or local edits: diverged from
# its upstream, no upstream, an upstream branch deleted on origin, or a detached HEAD.
# Moves the checkout onto origin without losing anything: commits found on no origin
# branch go to a bootstrap-backup/<time> branch first, uncommitted edits to tracked files
# into a stash named bootstrap-backup-<time> (re-applied after; kept there on a conflict),
# untracked files are never overwritten (reset --keep and checkout refuse). A branch with
# no upstream that exists on origin gets that upstream; any other is left as it is and the
# checkout goes to origin's default branch. Returns $true when the checkout is on origin.
function Repair-Checkout ($proj, $dir, $net) {
    git @net -C $dir fetch -q --prune origin 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $def = "$(git -C $dir symbolic-ref --short -q refs/remotes/origin/HEAD 2>$null)".Trim()
    if (-not $def) {
        git @net -C $dir remote set-head origin -a 2>&1 | Out-Null
        $def = "$(git -C $dir symbolic-ref --short -q refs/remotes/origin/HEAD 2>$null)".Trim()
    }
    if (-not $def) {
        foreach ($b in 'main', 'master') {
            git -C $dir rev-parse -q --verify "refs/remotes/origin/$b" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $def = "origin/$b"; break }
        }
    }
    if (-not $def) { return $false }
    $defName = $def -replace '^origin/', ''
    $branch = "$(git -C $dir symbolic-ref --short -q HEAD 2>$null)".Trim()
    $up = "$(git -C $dir rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)".Trim()
    if ($up) { git -C $dir rev-parse -q --verify "$up" 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { $up = '' } }
    $onOrigin = $false
    if ($branch) { git -C $dir rev-parse -q --verify "refs/remotes/origin/$branch" 2>$null | Out-Null; $onOrigin = ($LASTEXITCODE -eq 0) }

    if (-not $branch)  { $why = 'detached HEAD'; $target = $def; $switch = $true }
    elseif ($up)       { $why = "diverged from $up"; $target = $up; $switch = $false }
    elseif ($onOrigin) { $why = 'no upstream'; $target = "origin/$branch"; $switch = $false }
    else               { $why = "local branch $branch has no upstream"; $target = $def; $switch = $true }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $notes = @()
    # Commits on no origin branch: on a branch that is about to move, or a detached HEAD
    # about to be left, they would only be in the reflog. Keep them on a branch.
    $keep = @('HEAD')
    if ($switch) {
        git -C $dir rev-parse -q --verify "refs/heads/$defName" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $keep += "refs/heads/$defName" }
        if ($branch) { $keep = @($keep | Where-Object { $_ -ne 'HEAD' }) }   # the branch itself keeps them
    }
    $backups = @()
    foreach ($ref in $keep) {
        $n = [int]"$(git -C $dir rev-list --count $ref --not --remotes=origin 2>$null)".Trim()
        if ($n -le 0) { continue }
        $name = if ($ref -eq 'HEAD') { "bootstrap-backup/$stamp" } else { "bootstrap-backup/$stamp-$defName" }
        git -C $dir branch -q $name $ref 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        $backups += $name
        $notes += "$n local commit(s) kept on branch $name"
    }
    $stash = ''
    if (@(git -C $dir status --porcelain --untracked-files=no 2>$null).Count -gt 0) {
        $stash = "bootstrap-backup-$stamp"
        git -C $dir stash push -q -m $stash 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { foreach ($b in $backups) { git -C $dir branch -q -D $b 2>&1 | Out-Null }; return $false }
    }
    if ($switch) {
        git -C $dir checkout -q -B $defName $def 2>&1 | Out-Null
        $moved = ($LASTEXITCODE -eq 0)
        if ($moved) { git -C $dir branch -q "--set-upstream-to=$def" $defName 2>&1 | Out-Null }
        if ($moved -and $branch) { $notes += "branch $branch left as it was" }
    } else {
        git -C $dir reset -q --keep $target 2>&1 | Out-Null
        $moved = ($LASTEXITCODE -eq 0)
        if ($moved -and -not $up) { git -C $dir branch -q "--set-upstream-to=$target" 2>&1 | Out-Null }
    }
    if ($stash) {
        git -C $dir stash pop -q 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            git -C $dir reset -q --merge 2>&1 | Out-Null
            $notes += "uncommitted edits conflict with it, kept in stash '$stash'"
        } elseif ($moved) { $notes += 'uncommitted edits re-applied' }
    }
    if (-not $moved) {
        foreach ($b in $backups) { git -C $dir branch -q -D $b 2>&1 | Out-Null }
        return $false
    }
    $tail = if ($notes) { "; $($notes -join '; ')" } else { '' }
    Warn $proj "${why}: moved to $target$tail"
    return $true
}

# --- Renamed checkouts -----------------------------------------------------
#
# bootstrap.sh's "Renamed checkouts" has the reasoning. A repository renamed on GitHub is
# listed under its new name and its checkout is moved there when that is safe: a real
# checkout of this project, the new name free, and Windows lets the folder move (it does
# not while a program has a file or its working directory in it). A dirty tree moves as
# it is. The old name is left as a junction to the new one, so junctions and paths that
# went through it still arrive. A refused move keeps the old folder and does NOT clone a
# second copy beside it. $env:DOT_NO_RENAME = '1' refuses every move.
$script:keptOld = @{}

function Move-Renamed {
    foreach ($p in Get-Projects) {
        foreach ($old in $p.Aliases) {
            $new = $p.Name
            if (-not $old -or $old -eq $new) { continue }
            $src = Join-Path $projectsDir $old
            $dst = Join-Path $projectsDir $new
            $item = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
            if (-not $item -or -not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $dstItem = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
            if ($dstItem) {
                if (-not ($dstItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    Warn $new "an old checkout is still at $old beside it; left alone (move anything you need out of it, then delete it)"
                }
                continue
            }
            if (-not (Test-Path (Join-Path $src '.git') -PathType Container)) { Warn $old "left alone: $old is not a main git checkout"; continue }
            $origin = (git -C $src remote get-url origin 2>$null | Out-String).Trim()
            $repoOf = { param($u) ($u -replace '^git@github\.com:', '' -replace '^https://github\.com/', '' -replace '\.git$', '') }
            $base = ((& $repoOf $origin) -split '/')[-1]
            if ((& $repoOf $origin) -ne (& $repoOf $p.Url) -and $base -ne $new -and (Get-AliasTarget $base) -ne $new) {
                Warn $old "left alone: $old's origin is $origin, not $new"; continue
            }
            if ($env:DOT_NO_RENAME -eq '1') {
                $script:keptOld[$new] = $old
                Warn $new "still at its old name $old, not renamed: DOT_NO_RENAME=1. Run again once that is fixed."
                continue
            }
            try {
                Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
            } catch {
                $script:keptOld[$new] = $old
                Err $new "could not move $old to $new (a program has it open?); it is still at $old"
                continue
            }
            git -C $dst worktree repair 2>$null | Out-Null
            New-Item -ItemType Junction -Path $src -Target $dst -ErrorAction SilentlyContinue | Out-Null
            $n = @(git -C $dst status --porcelain 2>$null).Count
            $dirty = if ($n -gt 0) { " (with its $n uncommitted file(s))" } else { '' }
            Ok $new "renamed from $old$dirty; $old is now a junction to it"
        }
    }
}

function Sync-Repo ($proj, $url) {
    $dir = Join-Path $projectsDir $proj

    if ($script:keptOld.ContainsKey($proj)) {
        Warn $proj "not cloned: the checkout is still at $($script:keptOld[$proj]) (see above)"
        return
    }

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

        $cloneErr = @(git clone -q $effective $dir 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -eq 0) {
            # A repository created on GitHub and never pushed to clones fine and
            # has no HEAD, so rev-parse fails. Say so rather than leaking its
            # "fatal: Needed a single revision" to the terminal.
            $at = git -C $dir rev-parse --short HEAD 2>$null
            if ($at) { Say $proj "cloned $at" 'Green' }
            else     { Warn $proj 'cloned, empty -- nothing pushed to it yet' }
            if ($Hub) { git -C $dir remote add hub "$Hub/$proj.git" 2>$null | Out-Null }
        } elseif (($cloneErr -join "`n") -match '(?i)repository not found|not found|does not exist') {
            # A repository GitHub does not have is a renamed or deleted one, never
            # a passing network fault: say so, and name the line to fix.
            Err $proj "REPOSITORY MISSING: $effective does not exist (renamed or deleted?). Fix its line in projects.tsv."
            Note-Stale $proj "not cloned: $effective missing (fix projects.tsv)"
        } else {
            $why = @($cloneErr | Where-Object { $_ -match '(?i)^fatal:' } | Select-Object -First 1) -join ''
            Err $proj "clone failed from $effective $why"
            $kind = if (Test-NetError ($cloneErr -join "`n")) { 'network' } else { 'error' }
            Note-Stale $proj "not cloned ($kind): $why"
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
    # A repository renamed on GitHub: the list names the new one, this checkout
    # still the old. GitHub's redirect is not to be relied on, so repoint it,
    # keeping the SSH or HTTPS form the checkout already uses. (Inline, not a
    # helper: Sync-Many would have to carry one into every runspace.)
    $strip = { param($u) "$u" -replace '^git@github\.com:', '' -replace '^https://github\.com/', '' -replace '\.git$', '' }
    if ($origin -and ((& $strip $origin) -ne (& $strip $url))) {
        $moved = if ("$origin" -like 'https://*') { ConvertTo-HttpsUrl $url } else { $url }
        git -C $dir remote set-url origin $moved 2>$null | Out-Null
        Say $proj "origin moved $(& $strip $origin) -> $(& $strip $url)" 'Yellow'
        $origin = $moved
    }
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

    $first   = Invoke-PullRetry $dir $net
    $pullErr = @($first.Err)
    $pullOk  = $first.Ok
    if (-not $pullOk -and -not $first.Network) {
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
                    if ($n -gt 0) { Warn $proj "diverged from upstream (local commits, or history rewritten there): moved to it; $n local commit(s) kept on branch $backup" }
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
    if (-not $pullOk -and (($pullErr -join "`n") -match 'would be overwritten|commit your changes or stash')) {
        if (Resolve-BlockedPull $proj $dir $net $pullErr) {
            $pullOk = $true
            $dirty = @(git -C $dir status --porcelain 2>$null).Count
        }
    }
    # Diverged, no upstream, upstream deleted, detached HEAD: never "resolve by hand".
    # Not for the network (nothing to repair) nor a missing repository.
    $errText = $pullErr -join "`n"
    if (-not $pullOk -and -not $first.Network -and -not (Test-NetError $errText) -and
        $errText -notmatch '(?i)repository not found|does not exist|does not appear to be a git repository|could not read username|would be overwritten|commit your changes or stash') {
        if (Repair-Checkout $proj $dir $net) {
            $pullOk = $true
            $dirty = @(git -C $dir status --porcelain 2>$null).Count
        }
    }
    if (-not $pullOk) {
        $alt = ConvertTo-HttpsUrl $origin
        $why = @($pullErr | Where-Object { $_ -match '(?i)^(fatal|error):' } | Select-Object -First 1)
        $why = if ($why) { "$($why[0])".Trim() } else { @($pullErr | Where-Object { $_ } | Select-Object -First 1) -join '' }
        if ($first.Network -or (Test-NetError $errText)) {
            # The checkout is whole, just behind: the next run catches up. Not an error.
            Warn $proj "network, retried $($first.Tries)x, not updated: $why"
            Note-Stale $proj "network failure after $($first.Tries) tries (checkout kept as it was; the next run catches up)"
        } elseif ($errText -match '(?i)repository not found|does not exist|does not appear to be a git repository|could not read username') {
            # Renamed, deleted or private: the checkout on disk still works, so one line, no failure.
            Warn $proj "skipped: $origin is missing or private on GitHub; the checkout here is kept as it is. Fix its line in projects.tsv."
            Note-Stale $proj "repository missing or private ($origin); fix projects.tsv"
        } elseif ($dirty -gt 0 -and ($pullErr -join "`n") -match 'would be overwritten|commit your changes or stash') {
            # The update touches files changed here. Name them, so the choice
            # between committing and discarding is made by somebody looking.
            $files = @($pullErr | Where-Object { $_ -match '^\s+\S' -and $_ -notmatch '^\s*(Please|Aborting)' } |
                       ForEach-Object { $_.Trim() } | Select-Object -First 5) -join ' '
            if (-not $files) { $files = 'see git status' }
            Warn $proj "dirty, not updated: the update changes files modified here ($files)"
            Say  ''    '  commit or discard them, then run this again (generated .import/.uid files: add -DiscardGenerated)'
            Note-Stale $proj "local edits block the update ($files)"
        } elseif ($alt -eq $origin -or $script:useHttps) {
            # Repair-Checkout could not move it either (its fetch failed, or git refused).
            Err $proj "pull failed and could not be repaired: $why"
            Note-Stale $proj "pull failed: $why"
        } else {
            Err  $proj 'pull failed. origin is SSH; if you have no key here, drop -Ssh, or run:'
            Say  ''    "  git -C `"$dir`" remote set-url origin $alt"
            Note-Stale $proj "SSH pull failed: $why"
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

# Deletes a file or directory tree, retrying with a short backoff (a running editor or an
# antivirus scan holds files for a moment). On persistent failure says so in ONE line and
# returns $false; the caller carries on with the next thing.
function Remove-Tree ($path, $proj) {
    for ($try = 1; $try -le 4; $try++) {
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.LinkType) { [System.IO.Directory]::Delete($item.FullName, $false) }
            else                { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
            return $true
        } catch {
            if (-not (Test-Path -LiteralPath $path)) { return $true }
            Start-Sleep -Milliseconds (300 * $try)
        }
    }
    Err $proj "cannot delete ${path}: files are held open, likely a running Godot editor/import or antivirus. Close Godot (Get-Process godot*) and run again."
    return $false
}

# Makes $dst a copy of $src. With robocopy (Windows) it is an incremental mirror and the
# destination is never deleted first, so one locked file fails only itself; elsewhere
# Copy-Item. $true when it worked.
function Copy-Tree ($src, $dst, $proj) {
    $rc = Get-Command robocopy -CommandType Application -ErrorAction SilentlyContinue
    if ($rc) {
        $mt = [Math]::Min(32, 2 * [Environment]::ProcessorCount)
        $out = & $rc.Source $src $dst /MIR "/MT:$mt" /R:2 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1
        if ($LASTEXITCODE -ge 8) {
            $why = @($out | Where-Object { "$_" -match '\S' } | Select-Object -Last 1) -join ''
            Err $proj "copy to $dst incomplete (robocopy exit $LASTEXITCODE): some files are held open, likely a running Godot editor/import or antivirus. $why"
            return $false
        }
        return $true
    }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
    return $true
}

# One warning when a Godot started from the projects folder is running: it holds files open.
$script:godotWarned = $false
function Warn-RunningGodot {
    if ($script:godotWarned) { return }
    $script:godotWarned = $true
    $busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'godot*' -and $_.Path -and $_.Path.StartsWith($projectsDir, [StringComparison]::OrdinalIgnoreCase) })
    if ($busy.Count -gt 0) { Warn '' "Godot is running from $projectsDir (pid $(($busy | ForEach-Object { $_.Id }) -join ', ')); it can hold files open and make copies fail. Close it first." }
}

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
        # In copy mode a real directory is mirrored over, never deleted first.
        if (Test-Path $link) {
            $item = Get-Item $link -Force
            if ($item.LinkType -or -not $useCopy -or -not $item.PSIsContainer) {
                if (-not (Remove-Tree $link $proj)) { continue }
            }
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
            if (Copy-Tree $target $link $proj) {
                # Not plugin.cfg: not every addon has one (library addons ship only .gd/.gdextension).
                if ((Test-Path $link -PathType Container) -and (Get-ChildItem -Path $link -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { $made++ } else { Err $proj "copy failed: $addon" }
            }
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

# A native library an addon can load ("# bootstrap-natives: dot-sim v0.1.0" above
# /addons/dot_sim in the game's .gitignore). bootstrap.sh's fetch_natives has the
# reasoning: the release's zip for this machine, checksum checked, unpacked at the addon
# repository's root before the links (so a copy carries it), a stamp to skip it next
# time, a local build kept, and a warning (GDScript runs) when there is none.
# $env:DOT_NATIVES = 'none' skips it; $env:DOT_NATIVES_BASE replaces the GitHub base.
# An optional third field is the library directory inside the addon (default bin):
# "# bootstrap-natives: dot-net v0.1.29 native/bin" for dot-net's runtime-loaded core.
function Get-NativesFor ($proj) {
    $gi = Get-GitignorePath $proj
    if (-not (Test-Path $gi)) { return }
    $pin = $null
    foreach ($line in Get-Content $gi) {
        if ($line -match '^# bootstrap-natives:\s+(\S+)\s+(\S+)(?:\s+(\S+))?') {
            $libDir = if ($Matches[3]) { $Matches[3].TrimEnd('/') } else { 'bin' }
            $pin = @($Matches[1], $Matches[2], $libDir); continue
        }
        if ($pin -and $line -match '^# bootstrap-') { continue }
        if ($pin -and $line -match '^/addons/([a-z0-9_]+)/?\s*$') { [pscustomobject]@{ Repo = $pin[0]; Tag = $pin[1]; Addon = $Matches[1]; LibDir = $pin[2] } }
        $pin = $null
    }
}

# True when $libDir already holds a library for $plat: a non-empty $plat folder (dot-sim)
# or a Godot-named file such as libx.windows.template_release.x86_64.dll (dot-net).
function Test-NativeBuiltHere ($libDir, $plat) {
    $platDir = Join-Path $libDir $plat
    if ((Test-Path $platDir) -and (Get-ChildItem $platDir -ErrorAction SilentlyContinue)) { return $true }
    $os, $arch = $plat -split '-', 2
    foreach ($f in @(Get-ChildItem $libDir -File -Filter "*.$os.*" -ErrorAction SilentlyContinue)) {
        if ($f.Name -like "*.$arch.*" -or $f.Name -like '*.universal.*') { return $true }
    }
    return $false
}

function Get-NativePlatform {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86_64' }
    if ($null -eq $IsWindows -or $IsWindows) { return "windows-$arch" }
    $m = (uname -m); $arch = if ($m -match 'arm64|aarch64') { 'arm64' } else { 'x86_64' }
    if ($IsMacOS) { return "macos-$arch" }
    return "linux-$arch"
}

function Fetch-Natives ($proj) {
    if ($env:DOT_NATIVES -eq 'none') { return }
    $plat = Get-NativePlatform
    $root = if ($env:DOT_NATIVES_BASE) { $env:DOT_NATIVES_BASE } else { 'https://github.com/modcommunity' }
    foreach ($n in @(Get-NativesFor $proj)) {
        $n.Repo = Get-OnDisk $n.Repo
        $dir = Join-Path $projectsDir $n.Repo
        $addonDir = Join-Path $dir "addons\$($n.Addon)"
        if (-not (Test-Path $addonDir)) { Warn $proj "natives: $($n.Repo)/addons/$($n.Addon) is not cloned"; continue }
        $libDir = Join-Path $addonDir $n.LibDir
        # One stamp per platform (.natives-<platform>): macos-arm64 and macos-x86_64 fetched
        # side by side must not overwrite one stamp. An old single .natives naming this
        # platform is adopted.
        $stamp = Join-Path $libDir ".natives-$plat"
        $old = Join-Path $libDir '.natives'
        if (-not (Test-Path $stamp) -and (Test-Path $old) -and (((Get-Content $old -Raw).Trim() -split ' ')[1] -eq $plat)) {
            Copy-Item $old $stamp
        }
        $want = "$($n.Tag) $plat"
        if ((Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $want)) { continue }
        $platDir = Join-Path $libDir $plat
        if (-not (Test-Path $stamp) -and (Test-NativeBuiltHere $libDir $plat)) {
            Say $proj "natives: keeps the $($n.Addon) library built here ($plat)" 'DarkGray'; continue
        }
        $base = "$root/$($n.Repo)/releases/download/$($n.Tag)"
        try { $sums = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/SHA256SUMS.natives").Content }
        catch { Warn $proj "natives: no $($n.Repo) $($n.Tag) release to fetch (GDScript runs, slower)"; continue }
        if ($sums -is [byte[]]) { $sums = [System.Text.Encoding]::UTF8.GetString($sums) }
        $hit = $null
        foreach ($l in ($sums -split "`n")) {
            $f = $l.Trim() -split '\s+'
            if ($f.Count -ge 2 -and $f[1].EndsWith("-$plat.zip")) { $hit = $f; break }
        }
        if (-not $hit) { Warn $proj "natives: $($n.Repo) $($n.Tag) has no $plat library (GDScript runs, slower)"; continue }
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) $hit[1]
        Say $proj "natives: downloading $($hit[1])" 'DarkGray'
        try { Invoke-DotDownload "$base/$($hit[1])" $zip -Name $proj }
        catch { Warn $proj "natives: could not download $($hit[1]): $($_.Exception.Message) (GDScript runs, slower)"; continue }
        if ((Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower() -ne $hit[0].ToLower()) {
            Remove-Item -Force $zip; Err $proj "natives: $($hit[1]) checksum mismatch, not installed"; continue
        }
        if (Test-Path $platDir) { Remove-Item -Recurse -Force $platDir }
        try { Expand-Archive -Force -Path $zip -DestinationPath $dir }
        catch { Remove-Item -Force $zip; Err $proj "natives: could not unpack $($hit[1])"; continue }
        Remove-Item -Force $zip
        New-Item -ItemType Directory -Force -Path $libDir | Out-Null
        Set-Content -Path $stamp -Value $want -NoNewline
        Ok $proj "natives: $($n.Repo) $($n.Tag) ($plat) installed into $($n.Repo)/addons/$($n.Addon)"
    }
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
        if ($line -match '^# bootstrap-link: (\S+)(\s+ci)?\s*$') { $src = Get-OnDiskPath $Matches[1]; continue }
        if ($src -and $line -match '^/(.+?)/?\s*$') {
            $path   = $Matches[1] -replace '/', '\'
            $target = Join-Path $projectsDir ($src -replace '/', '\')
            $link   = Join-Path $dir $path
            # The raw art stores (a maps repo's .stores) are in no repository. They are fetched once and kept, from the
            # maps repo's content.lock.json (tools/fetch_lock.ps1), or from $env:DOT_STORES_FROM (a folder or the URL of
            # a .tar) when that is set; -NoStores or DOT_STORES_FROM=none skips them and the maps draw low-detail art.
            # (The old published tar, dev.dotgames.org/stores/zombie-zone-maps/zz-stores-cc0.tar, is gone: 404.)
            $from = if ($env:DOT_STORES_FROM) { $env:DOT_STORES_FROM } else { 'none' }
            $lockFile = Join-Path $projectsDir (($src -split '/')[0] + '\content.lock.json')
            $fetcher = Join-Path $repoDir 'tools\fetch_lock.ps1'
            # A store the fetcher has finished has .dot-pack; one it was stopped in still has its .manifest.json and is
            # resumed (present files are skipped), not linked half-empty for good.
            if ((($src -split '/')[-1] -eq '.stores') -and -not $NoStores -and -not $env:DOT_STORES_FROM -and (Test-Path $lockFile) -and ((Get-Content $lockFile -Raw) -match '"into"\s*:\s*"\.stores"') -and (Test-Path $fetcher) `
                    -and (-not (Test-Path $target) -or (Test-Path (Join-Path $target '.dot-pack')) -or (Test-Path (Join-Path $target '.manifest.json')))) {
                & $fetcher $lockFile -Only '.stores'
                if ($LASTEXITCODE -ne 0) { Warn $proj "fetching $src from content.lock.json failed" }
                elseif (Test-Path $target) { New-Item -ItemType File -Force -Path (Join-Path $target '.gdignore') | Out-Null }
            } elseif (-not (Test-Path $target) -and (($src -split '/')[-1] -eq '.stores') -and -not $NoStores -and $from -ne 'none' `
                    -and (Test-Path (Join-Path $projectsDir ($src -split '/')[0]))) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                if ($from -match '^https?://') {
                    $tar = Join-Path ([IO.Path]::GetTempPath()) 'dot-stores.tar'
                    Say $proj "downloading the art stores (a .tar, once) from $from"
                    try { Invoke-DotDownload $from $tar -Name $proj; tar -xf $tar -C $target }
                    catch { Warn $proj "could not download the art stores from ${from}: $($_.Exception.Message)" }
                    Remove-Item $tar -Force -ErrorAction SilentlyContinue
                } elseif (Test-Path $from) {
                    Copy-Item -Path (Join-Path $from '*') -Destination $target -Recurse -Force -Exclude 'project', 'slices'
                }
                New-Item -ItemType File -Force -Path (Join-Path $target '.gdignore') | Out-Null
                if (-not (Test-Path (Join-Path $target 'pbr-library'))) {
                    Remove-Item $target -Recurse -Force
                    Warn $proj "staging $src from $from failed (no pbr-library in it)"
                }
            } elseif ((($src -split '/')[-1] -ne '.stores') -and $src.Contains('/') -and (Test-Path $lockFile) -and (Test-Path $fetcher)) {
                # Content kept out of git (arena-dm-maps' maps) is pinned in the repo's lock under the linked folder.
                & $fetcher $lockFile -Only (($src -split '/', 2)[1] + '/*')
                if ($LASTEXITCODE -ne 0) { Warn $proj "fetching $src from content.lock.json failed" }
            }
            if (-not (Test-Path $target)) {
                if (($src -split '/')[-1] -eq '.stores') {
                    Warn $proj "art stores missing: $src is in no repository, so maps draw low-detail art. Run bootstrap again without -NoStores, or set `$env:DOT_STORES_FROM (a folder or the URL of a .tar of pbr-library and model-library)"
                } else {
                    Warn $proj "content missing: $src (clone $(($src -split '/')[0]) for $path)"
                }
            } elseif ((Test-Path $link) -and -not (Get-Item $link -Force).LinkType -and -not $useCopy) {
                Warn $proj "$path is a real directory, left alone (link it to $src by hand)"
            } else {
                $ok = $true
                if (Test-Path $link) {
                    $item = Get-Item $link -Force
                    if ($item.LinkType -or -not $useCopy -or -not $item.PSIsContainer) { $ok = Remove-Tree $link $proj }
                }
                if ($ok) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $link) | Out-Null
                    if ($useCopy) { $ok = Copy-Tree $target $link $proj }
                    else          { New-Item -ItemType Junction -Path $link -Target $target | Out-Null }
                }
                if ($ok) {
                    $verb = if ($useCopy) { 'copied' } else { 'linked' }
                    Say $proj "$verb $path -> $src" 'DarkGray'
                }
            }
        }
        $src = $null
    }
}

# A project whose content needs the one-off art-store download must not race another
# project fetching the same store, so those are linked first, one at a time.
function Test-NeedsStores ($proj) {
    $gi = Get-GitignorePath $proj
    (Test-Path $gi) -and [bool](Select-String -Path $gi -Pattern '^# bootstrap-link: \S*\.stores' -Quiet)
}

# Link-Addons and Link-Content for each project, at most $Jobs projects at once, each
# project's lines printed whole when it finishes. Same RunspacePool as Sync-Many.
function Link-Many ($targets) {
    $targets = @($targets)
    Warn-RunningGodot
    if ($Jobs -le 1 -or $targets.Count -le 1) {
        foreach ($p in $targets) { Link-Addons $p; Link-Content $p }
        return
    }
    $serial = @($targets | Where-Object { Test-NeedsStores $_ })
    $par    = @($targets | Where-Object { $serial -notcontains $_ })
    foreach ($p in $serial) { Link-Addons $p; Link-Content $p }
    if ($par.Count -le 1) { foreach ($p in $par) { Link-Addons $p; Link-Content $p }; return }
    Write-Host "linking with $Jobs parallel jobs (PowerShell $($PSVersionTable.PSVersion))"

    $iss = [initialsessionstate]::CreateDefault()
    $me = $PSCommandPath
    foreach ($f in Get-ChildItem function:) {
        if (($f.ScriptBlock.File -eq $me -or $f.ScriptBlock.File -eq $dotDownload) -and $f.Name -notin @('Say', 'Warn', 'Err', 'Ok')) {
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($f.Name, $f.Definition)))
        }
    }
    $vars = @{
        projectsDir = $projectsDir; useCopy = $useCopy; listFile = $listFile; repoDir = $repoDir
        NoStores = $NoStores; NoDeps = $NoDeps; Hub = $Hub; Jobs = $Jobs; Junction = $Junction
        minMode = $script:minMode; selection = $script:selection; godotWarned = $true
        useHttps = $script:useHttps; failed = $false
        linksMade = 0; linkedProjects = 0; junctionFailures = 0
    }
    foreach ($k in $vars.Keys) { $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($k, $vars[$k], ''))) }
    $pre = 'function Say ($n, $m, $c = "Gray") { [void]$global:lines.Add(@($n, $m, $c)) }; function Warn ($n, $m) { Say $n $m "Yellow" }; function Ok ($n, $m) { Say $n $m "Green" }; function Err ($n, $m) { Say $n $m "Red"; $global:failed = $true }'
    $worker = [scriptblock]::Create('param($proj); ' + $pre + '; $global:lines = New-Object System.Collections.ArrayList; $global:failed = $false; $global:linksMade = 0; $global:linkedProjects = 0; $global:junctionFailures = 0; Link-Addons $proj; Link-Content $proj; [pscustomobject]@{ Done = $true; Lines = $global:lines.ToArray(); Failed = $global:failed; Made = $global:linksMade; Projs = $global:linkedProjects; JF = $global:junctionFailures }')

    $pool = [runspacefactory]::CreateRunspacePool(1, $Jobs, $iss, $Host)
    $pool.Open()
    $pending = New-Object System.Collections.ArrayList
    foreach ($p in $par) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker.ToString()).AddArgument($p)
        [void]$pending.Add([pscustomobject]@{ Ps = $ps; Handle = $ps.BeginInvoke(); Name = $p })
    }
    while ($pending.Count -gt 0) {
        foreach ($j in @($pending)) {
            if (-not $j.Handle.IsCompleted) { continue }
            $pending.Remove($j)
            $res = @($j.Ps.EndInvoke($j.Handle))
            if ($res.Count -eq 0 -or $j.Ps.HadErrors) { $crash = @($j.Ps.Streams.Error | Select-Object -First 1); Err $j.Name "link job failed: $crash" }
            foreach ($r in $res) {
                if (-not $r.PSObject.Properties['Done']) { continue }
                foreach ($l in $r.Lines) { Say $l[0] $l[1] $l[2] }
                if ($r.Failed) { $script:failed = $true }
                $script:linksMade += $r.Made; $script:linkedProjects += $r.Projs; $script:junctionFailures += $r.JF
            }
            $j.Ps.Dispose()
        }
        if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 40 }
    }
    $pool.Close(); $pool.Dispose()
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
    # A checkout still under a renamed repository's old name counts as that repository
    # (reported below: the next sync renames it); the junction a rename leaves at the old
    # name is no repository at all.
    $dirs  = @(Get-ChildItem -Directory $projectsDir |
               Where-Object { $_.FullName -ne $repoDir -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    $disk  = @($dirs | Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
               ForEach-Object {
                   $c = Get-AliasTarget $_.Name
                   if ($c -and $names -notcontains $_.Name -and -not (Test-Path (Join-Path $projectsDir "$c\.git"))) { $c } else { $_.Name }
               } | Sort-Object -Unique)
    foreach ($p in Get-Projects) {
        foreach ($old in $p.Aliases) {
            $o = Get-Item -LiteralPath (Join-Path $projectsDir $old) -Force -ErrorAction SilentlyContinue
            if (-not $o -or -not $o.PSIsContainer) { continue }
            $hasNew = Test-Path (Join-Path $projectsDir "$($p.Name)\.git")
            $oldGit = Test-Path (Join-Path $o.FullName '.git')
            if ($o.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Say $old "old name of $($p.Name), a junction to it; delete it once nothing uses the old path" 'DarkGray'
            } elseif ($hasNew) {
                if ($oldGit) { Warn $old "old checkout of $($p.Name), which is also here; move anything you need out of it, then delete it" }
            } elseif ($oldGit) {
                Warn $p.Name "checked out under its old name $old; the next sync renames it"
            }
        }
    }

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
    # What -GetGodot downloaded, newest version first; the editor build rather than the console one.
    $bin = Join-Path $repoDir '.godot-bin'
    if (Test-Path $bin) {
        $exe = Get-ChildItem $bin -Filter 'Godot*.exe' -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike '*_console*' } |
               Sort-Object FullName -Descending | Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
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

# Latest stable Godot from the engine's own build repository, checked against the
# SHA512-SUMS.txt published with the release, unpacked into .godot-bin\<version>.
function Get-GodotLatest {
    $root = Join-Path $repoDir '.godot-bin'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/godotengine/godot-builds/releases/latest'
        $tag = $rel.tag_name
        $dest = Join-Path $root $tag
        if (Get-ChildItem $dest -Filter 'Godot*.exe' -ErrorAction SilentlyContinue) { Ok 'godot' "$tag already in $dest"; return $true }
        $asset = "Godot_v$tag`_win64.exe.zip"
        $base = "https://github.com/godotengine/godot-builds/releases/download/$tag"
        $zip = Join-Path $tmp $asset
        Say 'godot' "downloading $asset (about 80 MB)..."
        Invoke-DotDownload "$base/$asset" $zip -Name 'godot'
        $sums = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/SHA512-SUMS.txt").Content
        # Served as application/octet-stream, so PowerShell hands back bytes, not text.
        if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
        $want = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($asset) + '\s*$' } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
        if (-not $want) { Err 'godot' "no checksum listed for $asset; nothing installed"; return $false }
        $got = (Get-FileHash -Algorithm SHA512 $zip).Hash.ToLower()
        if ($got -ne $want.ToLower()) { Err 'godot' "checksum mismatch (got $got); nothing installed"; return $false }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Expand-Archive -Force -Path $zip -DestinationPath $dest
        Ok 'godot' "$tag installed in $dest"
        return $true
    } catch { Err 'godot' $_.Exception.Message; return $false }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
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
    foreach ($c in @($want, "game-$want", "mg-$want", (Get-AliasTarget $want))) {
        if ($c -and (Get-Games | Where-Object { $_.Name -eq $c })) { $proj = $c; break }
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
        Write-Host 'Godot was not found. Run .\bootstrap.ps1 -GetGodot, or set $env:GODOT to the executable.' -ForegroundColor Red
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

# --- Release export ---------------------------------------------------------

# -Export <game> builds a RELEASE executable of a game (no editor, no debugger) and
# -PlayExport <game> starts it: what a player's machine runs, for measuring. The game
# carries the presets (export_presets.example.cfg, copied to export_presets.cfg when
# there is none); this script supplies the export template, which the editor download
# does not include. Only the Windows release template is kept (about 100 MB of the
# 1.2 GB archive), in .godot-bin\<version>\templates, and the preset is pointed at it
# (custom_template/release), so nothing is installed outside this folder.
$script:exportPreset = 'Windows x86_64'

function Resolve-Game ($want) {
    foreach ($c in @($want, "game-$want", "mg-$want", (Get-AliasTarget $want))) {
        if ($c -and (Get-Games | Where-Object { $_.Name -eq $c })) { return $c }
    }
    return $null
}

# The release tag a Godot executable was built from (4.7.2-stable): the templates must
# be the same version or the exported game refuses its own pck.
function Get-GodotTag ($bin) {
    $name = ($bin -split '[\\/]')[-1]
    if ($name -match '^Godot_v(\d+(?:\.\d+)+-[A-Za-z0-9]+)_') { return $Matches[1] }
    $v = ''
    try { $v = (& $bin --version 2>$null | Out-String).Trim() } catch { }
    if ($v -match '^(\d+(?:\.\d+)+)\.([a-z]+\d*)\.') { return "$($Matches[1])-$($Matches[2])" }
    return $null
}

# The official export templates for $tag, checked against the release's SHA512-SUMS.txt
# like the editor download. Returns the path of the Windows release template, or $null.
function Get-ExportTemplates ($tag) {
    $dest = Join-Path (Join-Path (Join-Path $repoDir '.godot-bin') $tag) 'templates'
    $main = 'windows_release_x86_64.exe'
    $mainPath = Join-Path $dest $main
    if (Test-Path $mainPath) { Ok 'templates' "$tag already in $dest"; return $mainPath }
    $asset = "Godot_v$tag`_export_templates.tpz"
    $root = if ($env:DOT_GODOT_BASE) { $env:DOT_GODOT_BASE } else { 'https://github.com/godotengine/godot-builds/releases/download' }
    $base = "$root/$tag"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    # Beside the destination, not in %TEMP%: the archive is 1.2 GB and %TEMP% is often the small drive.
    $tpz = Join-Path $dest "$asset.part"
    $zip = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Say 'templates' "downloading $asset (about 1.2 GB, once)..."
        Invoke-DotDownload "$base/$asset" $tpz -Name 'templates'
        $sums = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$base/SHA512-SUMS.txt").Content
        if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
        $want = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($asset) + '\s*$' } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
        if (-not $want) { Err 'templates' "no checksum listed for $asset; nothing installed"; return $null }
        $got = (Get-FileHash -Algorithm SHA512 $tpz).Hash.ToLower()
        if ($got -ne $want.ToLower()) { Err 'templates' "checksum mismatch (got $got); nothing installed"; return $null }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($tpz)
        # The release template last: its presence is what says the install is complete.
        foreach ($n in @('windows_release_x86_64_console.exe', $main)) {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq "templates/$n" } | Select-Object -First 1
            if ($entry) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $dest $n), $true) }
            elseif ($n -eq $main) { Err 'templates' "$asset has no templates/$n; nothing installed"; return $null }
        }
        Ok 'templates' "$tag installed in $dest"
        return $mainPath
    } catch { Err 'templates' $_.Exception.Message; return $null }
    finally {
        if ($zip) { $zip.Dispose() }
        Remove-Item -Force $tpz -ErrorAction SilentlyContinue
    }
}

# The preset -Export writes for a game that carries none (only FC tracks an
# export_presets.example.cfg): FC's preset with the game's name. The pck sits beside the
# executable (embed_pck=false; a large embedded pck starts slowly), every resource is
# exported, plus the non-resource files games read with FileAccess (map json and bin,
# yml, cfg, packs), and the test, tool and document folders are left out. Lines of a
# [preset.<idx>] and its options; nothing for a preset name it does not know.
function Get-DefaultExportPreset ($proj, $preset, $idx) {
    switch ($preset) {
        'Windows x86_64' {
            $platform = 'Windows Desktop'; $path = "build/windows/$proj.exe"
            $extra = @('codesign/enable=false', 'application/modify_resources=false',
                "application/product_name=`"$proj`"", "application/file_description=`"$proj client (release)`"")
        }
        'Linux x86_64' { $platform = 'Linux'; $path = "build/linux/$proj.x86_64"; $extra = @() }
        default { return }
    }
    @("[preset.$idx]", '', "name=`"$preset`"", "platform=`"$platform`"", 'runnable=true',
        'advanced_options=false', 'dedicated_server=false', 'custom_features=""',
        'export_filter="all_resources"',
        'include_filter="*.json, *.bin, *.yml, *.txt, *.tsv, *.conf, *.cfg, *.dot-pack"',
        'exclude_filter="examples/*, tests/*, tools/*, ci/*, docs/*, images/*, build/*, screenshots/*, lightbake_work/*, dot_cloud/*, web/build/*, export_presets*.cfg"',
        "export_path=`"$path`"", 'encryption_include_filters=""', 'encryption_exclude_filters=""',
        'seed=0', 'encrypt_pck=false', 'encrypt_directory=false', 'script_export_mode=2', '',
        "[preset.$idx.options]", '', 'custom_template/debug=""', 'custom_template/release=""',
        'debug/export_console_wrapper=0', 'binary_format/embed_pck=false', 'texture_format/s3tc_bptc=true',
        'texture_format/etc2_astc=false', 'binary_format/architecture="x86_64"') + $extra
}

# A generated export_presets.cfg is the editor's file and never the game's: when the
# game's .gitignore does not already ignore it, it goes in the clone's .git/info/exclude.
function Hide-ExportPresets ($dir) {
    git -C $dir check-ignore -q export_presets.cfg 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    git -C $dir ls-files --error-unmatch -- export_presets.cfg 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
    $ex = "$(git -C $dir rev-parse --git-path info/exclude 2>$null)".Trim()
    if (-not $ex) { return }
    if (-not [IO.Path]::IsPathRooted($ex)) { $ex = Join-Path $dir $ex }
    New-Item -ItemType Directory -Force -Path (Split-Path $ex -Parent) | Out-Null
    Add-Content -LiteralPath $ex -Value 'export_presets.cfg'
}

# export_presets.cfg for $dir with preset $preset using $template as its release
# template. The file is the game's export_presets.example.cfg when there is none yet
# (the editor rewrites export_presets.cfg, so games track only the example); a game with
# neither, or whose file has no such preset, gets the default one (Get-DefaultExportPreset).
function Set-ExportPreset ($dir, $preset, $template) {
    $cfg = Join-Path $dir 'export_presets.cfg'
    $src = $cfg
    if (-not (Test-Path $src)) { $src = Join-Path $dir 'export_presets.example.cfg' }
    $lines = if (Test-Path $src) { @(Get-Content -LiteralPath $src) } else { @() }
    $idx = $null; $sec = ''; $top = -1
    foreach ($l in $lines) {
        if ($l -match '^\[(.+)\]\s*$') { $sec = $Matches[1]; if ($sec -match '^preset\.(\d+)$' -and [int]$Matches[1] -gt $top) { $top = [int]$Matches[1] } }
        elseif ($l -eq "name=`"$preset`"" -and $sec -match '^preset\.(\d+)$') { $idx = $Matches[1] }
    }
    if ($null -eq $idx) {
        $proj = Split-Path $dir -Leaf
        $add = @(Get-DefaultExportPreset $proj $preset ($top + 1))
        if ($add.Count -eq 0) {
            if ($lines.Count -eq 0) { Err 'export' "no export_presets.cfg and no export_presets.example.cfg in $dir" }
            else { Err 'export' "$src has no preset named `"$preset`"" }
            return $false
        }
        $idx = "$($top + 1)"
        if ($lines.Count -gt 0 -and $lines[-1] -ne '') { $lines += '' }
        $lines += $add
        $what = if ($lines.Count -eq $add.Count) { 'it carries no export presets' } else { "$(Split-Path $src -Leaf) has no `"$preset`" preset" }
        Say 'export' "$proj`: $what, so the default `"$preset`" release preset is written to export_presets.cfg"
        Hide-ExportPresets $dir
    }
    # Godot reads forward slashes on every platform; a backslash would need escaping.
    $line = 'custom_template/release="' + ($template -replace '\\', '/') + '"'
    $out = New-Object System.Collections.Generic.List[string]
    $sec = ''; $done = $false
    foreach ($l in $lines) {
        if ($l -match '^\[(.+)\]\s*$') {
            # Left the options section without finding the key: it goes at the end of it.
            if ($sec -eq "preset.$idx.options" -and -not $done) { $out.Add($line); $out.Add(''); $done = $true }
            $sec = $Matches[1]
        }
        if ($sec -eq "preset.$idx.options" -and $l -like 'custom_template/release=*') { $out.Add($line); $done = $true }
        else { $out.Add($l) }
    }
    if (-not $done) {
        if ($sec -ne "preset.$idx.options") { $out.Add(''); $out.Add("[preset.$idx.options]"); $out.Add('') }
        $out.Add($line)
    }
    # Without a byte-order mark: Set-Content -Encoding UTF8 writes one on PowerShell 5.1.
    [IO.File]::WriteAllLines($cfg, [string[]]$out, (New-Object Text.UTF8Encoding $false))
    return $true
}

function Get-ExportPath ($proj) { Join-Path (Join-Path (Join-Path $projectsDir $proj) 'build\windows') "$proj.exe" }

# The file name of the library each .gdextension of <dir> loads on <os> x86_64 in a
# release build, as objects with Ext and Lib; Lib is empty when the extension lists
# none for this platform.
function Get-ExportNatives ($dir, $os) {
    $keys = @("$os.release.x86_64", "$os.x86_64", "$os.release", "$os")
    foreach ($ext in @(Get-ChildItem (Join-Path $dir 'addons') -Filter '*.gdextension' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $lib = ''
        foreach ($line in Get-Content $ext.FullName) {
            if ($lib -or $line -match '^\s*[#;]') { continue }
            $i = $line.IndexOf('=')
            if ($i -lt 1) { continue }
            if ($keys -contains $line.Substring(0, $i).Trim()) {
                if ($line.Substring($i + 1) -match '"([^"]*)"') { $lib = ($Matches[1] -split '[\\/]')[-1] }
            }
        }
        [pscustomobject]@{ Ext = $ext.Name; Lib = $lib }
    }
}

# A library an addon loads itself at run time from a .cfg (dot-net's snapshot core,
# addons\dot_net\native\dot_net_native.cfg). The export never carries it, so Export-Game
# copies the .cfg and its release library into <out>\<cfg name>\, where DotNetNative
# looks beside the executable. One object per addons\*\native\*.cfg holding an
# entry_symbol, with Cfg (full path) and Lib (relative to the cfg; empty when it names
# none for $os x86_64). Each addon folder is listed by path, so a linked addon counts.
function Get-RuntimeNatives ($dir, $os) {
    $keys = @("$os.release.x86_64", "$os.x86_64", "$os.release", "$os")
    foreach ($addon in @(Get-ChildItem (Join-Path $dir 'addons') -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        foreach ($cfg in @(Get-ChildItem (Join-Path $addon.FullName 'native') -File -Filter '*.cfg' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $text = @(Get-Content $cfg.FullName)
            if (-not ($text -match '^\s*entry_symbol')) { continue }
            $lib = ''
            foreach ($line in $text) {
                if ($lib -or $line -match '^\s*[#;]') { continue }
                $i = $line.IndexOf('=')
                if ($i -lt 1) { continue }
                if ($keys -contains $line.Substring(0, $i).Trim() -and $line.Substring($i + 1) -match '"([^"]*)"') { $lib = $Matches[1] }
            }
            [pscustomobject]@{ Cfg = $cfg.FullName; Lib = $lib }
        }
    }
}

# Copies each runtime-loaded library of $dir for $os into $outDir. Optional by design
# (the addon falls back to GDScript), so a missing one is a warning. $false on a failed copy.
function Copy-RuntimeNatives ($dir, $os, $outDir) {
    foreach ($n in @(Get-RuntimeNatives $dir $os)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($n.Cfg)
        $dest = Join-Path $outDir $name
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        $src = if ($n.Lib) { Join-Path (Split-Path $n.Cfg -Parent) $n.Lib } else { '' }
        if (-not $src -or -not (Test-Path $src) -or (Get-Item $src).Length -eq 0) {
            $what = if ($n.Lib) { "$os x86_64 library ($($n.Lib))" } else { "$os x86_64 library" }
            Warn $name "no $what in the project, so the build runs its GDScript fallback. Run .\bootstrap.ps1 to fetch it."
            continue
        }
        $to = Join-Path $dest $n.Lib
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
            Copy-Item -Force $n.Cfg $dest
            Copy-Item -Force $src $to
        } catch { Err 'export' "could not copy $name into $outDir"; return $false }
        if ((Test-Path $to) -and (Get-Item $to).Length -gt 0) { Ok 'native' "$name\$($n.Lib) bundled" }
        else { Err 'export' "$name\$($n.Lib) was not copied into $outDir"; return $false }
    }
    return $true
}

# What -PlayExport starts a game with: offline, a match's worth of bots, the profiler's
# overlay up and a minute per `profiler_record` (F10 stays profiler_capture_seconds). `+name value` is a console line the game
# runs once it knows the name; -PlayArgs comes after these, and a name given twice keeps
# its last value.
# Those console lines are FC's (game-fatal-contact, under any of its names); every other
# game gets --offline and -PlayArgs only.
function Get-ExportPlayArgs ($extra, $proj = 'game-fatal-contact') {
    $fc = $proj -eq 'game-fatal-contact' -or (Get-AliasTarget $proj) -eq 'game-fatal-contact'
    $base = if ($fc) { @('--', '--offline', '+bot_quota', '8', '+profiler_overlay', '1', '+profiler_record_seconds', '60') } else { @('--', '--offline') }
    $base + @("$extra" -split '\s+' | Where-Object { $_ })
}

# Export one game as a release build into <game>\build\windows. Returns $true or $false.
function Export-Game ($want) {
    $proj = Resolve-Game $want
    if (-not $proj) { Write-Host "no such game: $want" -ForegroundColor Red; List-Games; return $false }
    $dir = Join-Path $projectsDir $proj
    if (-not (Test-Path $dir)) { Write-Host "$proj is not cloned yet. Run .\bootstrap.ps1 first." -ForegroundColor Red; return $false }
    $bin = Find-Godot
    if (-not $bin) { Write-Host 'Godot was not found. Run .\bootstrap.ps1 -GetGodot, or set $env:GODOT to the executable.' -ForegroundColor Red; return $false }
    $tag = Get-GodotTag $bin
    if (-not $tag) { Err 'export' "could not read the version of $bin, so no matching export templates"; return $false }
    $template = Get-ExportTemplates $tag
    if (-not $template) { return $false }
    if (-not (Set-ExportPreset $dir $script:exportPreset $template)) { return $false }

    # A native library is exported only when it is in the project; without it the game
    # runs its GDScript twins, which is a different thing to measure.
    $natives = @(Get-ExportNatives $dir 'windows')
    $bare = @($natives | Where-Object { -not $_.Lib })
    foreach ($n in $bare) {
        Err 'export' "$($n.Ext) lists no Windows x86_64 library, so the build would run without it. Run .\bootstrap.ps1 $proj to fetch it (`$env:DOT_NATIVES = 'none' exports without)."
    }
    if ($bare.Count -gt 0 -and $env:DOT_NATIVES -ne 'none') { return $false }

    $exe = Get-ExportPath $proj
    $outDir = Split-Path $exe -Parent
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $log = Join-Path $outDir 'export.log'
    Write-Host "importing $proj" -ForegroundColor Cyan
    & $bin --headless --path $dir --import 2>&1 | Out-Null
    # The last build's files go first: a stale library beside a new executable would pass the check below.
    Remove-Item -Force $exe, ([IO.Path]::ChangeExtension($exe, '.pck')) -ErrorAction SilentlyContinue
    Get-ChildItem $outDir -File -Filter '*.dll' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "exporting $proj ($script:exportPreset, release) to $outDir; a first export takes several minutes" -ForegroundColor Cyan
    & $bin --headless --path $dir --export-release $script:exportPreset $exe 2>&1 | Out-File -FilePath $log -Encoding utf8
    # The file is the evidence: an export can print an error and still exit 0.
    if (-not (Test-Path $exe) -or (Get-Item $exe).Length -eq 0) {
        Err 'export' "no $exe was written; the end of $log follows"
        Get-Content $log -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
        return $false
    }
    # Godot puts each extension's library beside the executable; one that is not there
    # was not exported, and the game would start without it and say nothing.
    $lost = $false
    foreach ($n in @($natives | Where-Object { $_.Lib })) {
        $f = Join-Path $outDir $n.Lib
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { Ok 'native' "$($n.Lib) bundled" }
        else { Err 'export' "$($n.Lib) ($($n.Ext)) is not beside the executable; see $log"; $lost = $true }
    }
    if ($lost) { return $false }
    if (-not (Copy-RuntimeNatives $dir 'windows' $outDir)) { return $false }
    $mb = [math]::Round(((Get-ChildItem $outDir -File | Measure-Object Length -Sum).Sum) / 1MB)
    Ok 'export' "$exe ($mb MB in $outDir, log in export.log)"
    return $true
}

# Start the exported build, exporting it first when there is none. The profiler is in
# release builds too: F10 records, and the files land in the game's user folder.
function Play-Export ($want) {
    $proj = Resolve-Game $want
    if (-not $proj) { Write-Host "no such game: $want" -ForegroundColor Red; List-Games; exit 2 }
    $exe = Get-ExportPath $proj
    if (-not (Test-Path $exe)) {
        if (-not (Export-Game $want)) { exit 1 }
    } else {
        Write-Host "using the build of $((Get-Item $exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm')); .\bootstrap.ps1 -Export $want rebuilds it" -ForegroundColor DarkGray
    }
    $a = @(Get-ExportPlayArgs $PlayArgs $proj)
    Write-Host "$exe $($a -join ' ')" -ForegroundColor Cyan
    Write-Host "F10 records 10 s, profiler_record in the console 60 s; reports: $env:APPDATA\Godot\app_userdata\$proj\profiles" -ForegroundColor DarkGray
    & $exe @a
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
        else {
            Say 'fastgmad' "downloading fastgmad $ver..."
            Invoke-DotDownload "https://github.com/WilliamVenner/fastgmad/releases/download/v$ver/fastgmad_windows.zip" $zip -Name 'fastgmad'
        }
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
        Err 'content keys' 'Godot was not found. Run .\bootstrap.ps1 -GetGodot, or set $env:GODOT to the executable.'
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
            if ($line -match '^# bootstrap-link: (\S+)(\s+ci)?\s*$') { $src = Get-OnDiskPath $Matches[1]; continue }
            if ($src -and $line -match '^/(.+?)/?\s*$') { Write-Output "link $p content $($Matches[1]) -> $src" }
            $src = $null
        }
    }
}

# Import every selected game; run on its own, or after the sync when -GetGodot or -DiscardGenerated asks for one.
function Invoke-Import {
    Warn-RunningGodot
    $bin = Find-Godot
    if (-not $bin) { Write-Host 'Godot was not found. Run .\bootstrap.ps1 -GetGodot, or set $env:GODOT to the executable.' -ForegroundColor Red; exit 3 }
    # Games only, whatever else the selection holds; no selection means every game.
    $gameNames = @(Get-Games | ForEach-Object { $_.Name })
    $names = if ($script:selection.Count -gt 0) { @($script:selection | Where-Object { $gameNames -contains $_ }) } else { $gameNames }
    & (Join-Path $PSScriptRoot 'tools\import-all.ps1') -ProjectsDir $projectsDir -Godot $bin -Names $names -Jobs $Jobs
    if ($LASTEXITCODE -ne 0) { $script:failed = $true }
}

if ($Plan)        { Show-Plan; exit 0 }
# Runs first so the rest of this run, including -Import, finds it.
if ($GetGodot)    { if (-not (Get-GodotLatest)) { $script:failed = $true } }
if ($Play)        { Play-Game $Play; exit 0 }
if ($Export)      { if (-not (Export-Game $Export)) { exit 1 }; if (-not $PlayExport) { exit 0 } }
if ($PlayExport)  { Play-Export $PlayExport; exit 0 }
elseif ($List)    { List-Games; exit 0 }
elseif ($Check)   { Check-List }
elseif ($Status)  {
    Write-Host "projects: $projectsDir`n"
    foreach ($p in Get-Selected) { Status-Repo $p }
}
elseif ($Links)   {
    Move-Renamed
    $targets = @(Get-LinkTargets)
    foreach ($p in $targets) { Fetch-Natives $p }
    Link-Many $targets
}
elseif ($Import -and -not ($GetGodot -or $DiscardGenerated)) { Invoke-Import }
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
    Move-Renamed
    Get-Selected -Sync | Out-Null
    Write-Host ''
    $targets = @(Get-LinkTargets)
    foreach ($p in $targets) { Fetch-Natives $p }
    Link-Many $targets
    if ($Import) { Invoke-Import }
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

if ($script:stale.Count -gt 0) {
    Write-Host "not updated ($($script:stale.Count)):" -ForegroundColor Yellow
    foreach ($s in $script:stale) { Write-Host "  $s" -ForegroundColor Yellow }
    Write-Host ''
}

if ($script:failed) { Write-Host 'finished with errors' -ForegroundColor Red; exit 1 }
else                { Write-Host 'ok' -ForegroundColor Green; exit 0 }
