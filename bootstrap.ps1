<#
    Clone or update every project in the Dot family, wire the local-development
    addon links, and run any of the games. The Windows counterpart of
    bootstrap.sh.

        .\bootstrap.ps1                 clone what is missing, pull what is not
        .\bootstrap.ps1 -Links          only redo the links, touch no repository
        .\bootstrap.ps1 -ContentKeys    make a content signing keypair, to publish packs
        .\bootstrap.ps1 -Status         report each repository, change nothing
        .\bootstrap.ps1 -Check          verify the list against the disk
        .\bootstrap.ps1 -List           what can be played
        .\bootstrap.ps1 -Play arena     play one, offline, no server needed
        .\bootstrap.ps1 -Links -Copy    copy the addons instead of linking them
        .\bootstrap.ps1 -Https          reach GitHub over HTTPS rather than SSH

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
    [switch]$Status,
    [switch]$Check,
    [switch]$List,
    [switch]$Copy,
    [switch]$Junction,
    [switch]$Https,
    [string]$Play
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

# Whether to reach GitHub over HTTPS instead of SSH. Set by -Https, or latched on
# automatically the first time an SSH clone fails and the HTTPS one works.
#
# SSH is still tried first, deliberately: a machine with a key can PUSH, and
# rewriting everything to HTTPS would quietly take that away. The fallback is for
# the read-only case -- a laptop, a fresh Windows box, anywhere the key is not --
# and the assets are public, so HTTPS needs no credentials to read.
$script:useHttps  = [bool]$Https
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
    Write-Host 'GitHub and re-run without -Https to get one you can push from.' -ForegroundColor Yellow
    Write-Host ''
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
            Say $proj "cloned $(git -C $dir rev-parse --short HEAD 2>$null)" 'Green'
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

    # Never clobber work in progress: any machine may hold the only copy.
    $dirty = @(git -C $dir status --porcelain)
    if ($dirty.Count -gt 0) { Warn $proj "dirty, left alone ($($dirty.Count) file(s))"; return }

    $before = git -C $dir rev-parse --short HEAD
    git -C $dir pull -q --ff-only 2>$null
    if ($LASTEXITCODE -ne 0) {
        $origin = git -C $dir remote get-url origin 2>$null
        $alt    = ConvertTo-HttpsUrl $origin
        if ($alt -ne $origin) {
            Err  $proj 'pull failed. origin is SSH; if you have no key here, run:'
            Say  ''    "  git -C `"$dir`" remote set-url origin $alt"
        } else {
            Err $proj 'pull refused - diverged, or no upstream. Resolve by hand.'
        }
        return
    }

    $after = git -C $dir rev-parse --short HEAD
    if ($before -eq $after) { Say $proj "up to date $after" 'DarkGray' }
    else                    { Say $proj "updated $before -> $after" 'Green' }
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
elseif ($ContentKeys) {
    if (-not (New-ContentKeys)) { $script:failed = $true }
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
