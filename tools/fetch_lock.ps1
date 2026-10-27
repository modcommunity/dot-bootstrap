# THE one fetcher on Windows: fetch exactly what a repo's content.lock.json names, hash-checked, once (present files skipped).
#   .\tools\fetch_lock.ps1 <content.lock.json> [-Root DIR] [-From BASE] [-Cdn URL] [-Cfg DIR] [-Except a,b] [-Only a,b] [-Packs DIR] [-List]
# Same behaviour as fetch_lock.sh, which documents the lock, the item names (id, name half, into, kind, repo; globs) and the cfg/content
# rules. Where from, first set wins: -From, $env:DOT_PACKS_FROM ('none' fetches nothing), -Cdn / $env:DOT_CDN_URL, DOT_CDN_URL in
# dot-bootstrap\.env, the lock's origin and mirrors, https://dotgames.org. (-Skip is the older name of -Except.)
param([Parameter(Mandatory)][string]$Lock, [string]$Root, [string]$From, [string]$Cdn, [string]$Cfg, [string]$Packs,
      [Alias('Skip')][string[]]$Except = @(), [string[]]$Only = @(), [switch]$List)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Lock)) { Write-Host "fetch_lock: no $Lock, nothing pinned"; exit 0 }
$Lock = (Resolve-Path $Lock).Path
$lockDir = Split-Path -Parent $Lock
if (-not $Root) { $Root = $lockDir }
if (-not $From) { $From = $env:DOT_PACKS_FROM }
if (-not $Cdn) { $Cdn = $env:DOT_CDN_URL }
$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
$dotenv = @{}
if (Test-Path $envFile) { foreach ($l in Get-Content $envFile) { $l = $l.Trim(); if ($l -and -not $l.StartsWith('#') -and $l.Contains('=')) { $k, $v = $l.Split('=', 2); $dotenv[$k.Trim()] = $v.Trim().Trim('"', "'") } } }
if (-not $From -and -not $Cdn) { $Cdn = $dotenv['DOT_CDN_URL'] }
if (-not $From -and -not $Cdn) { $From = $dotenv['DOT_PACKS_FROM'] }
if ($Cdn -and -not $From) { $From = $Cdn.TrimEnd('/'); if ($From -match '^[a-z]+://' -and -not $From.EndsWith('/content')) { $From += '/content' } }
if ($From -eq 'none') { Write-Host 'fetch_lock: DOT_PACKS_FROM=none, nothing fetched'; exit 0 }
$doc = Get-Content -Raw $Lock | ConvertFrom-Json
if ($doc.format -ne 1) { throw 'fetch_lock: unsupported lock format' }
$repo = Split-Path -Leaf $lockDir
if ($Packs) { New-Item -ItemType Directory -Force -Path $Packs | Out-Null; $Packs = (Resolve-Path $Packs).Path }
$bases = if ($From) { @($From) } elseif ($doc.origin) { @($doc.origin) + @($doc.mirrors) } else { @('https://dotgames.org/content') }
$bases = @($bases | ForEach-Object { $_.TrimEnd('/') })

function Get-Sha([string]$p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }

function Fetch([string]$rel, [string]$dest, [string]$sha) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    $part = "$dest.part"
    for ($i = 0; $i -lt 4; $i++) {
        $b = $bases[$i % $bases.Count]
        try {
            if ($b -match '^[a-z]+://') { Invoke-WebRequest -Uri "$b/$rel" -OutFile $part -UseBasicParsing }
            else { Copy-Item -LiteralPath (Join-Path $b $rel) $part -Force }
            if ((Get-Sha $part) -eq $sha) { Move-Item -Force $part $dest; return }
            Remove-Item -Force $part
            throw "hash mismatch for $b/$rel"
        } catch { if ($i -eq 3) { throw }; Start-Sleep -Seconds ([math]::Pow(2, $i)) }
    }
}

# The download lists: remove: entries, and the pack: entries of a list without merge: true (what fetch_lock.sh reads the same way).
if (-not $Cfg -and (Test-Path (Join-Path $lockDir 'cfg'))) { $Cfg = Join-Path $lockDir 'cfg' }
$removed = @(); $named = $null
function Id([string]$v) { ($v.Trim().Trim('"', "'") -split '@')[0] }
if ($Cfg) {
    foreach ($kind in 'addons', 'games') { foreach ($layer in 'content', 'server/content') {
        $f = Join-Path $Cfg "$layer/$kind.yml"; if (-not (Test-Path $f)) { continue }
        $merge = $false; $pk = @(); $key = ''
        foreach ($ln in Get-Content $f) {
            $ln = ($ln -split ' #')[0].TrimEnd(); $t = $ln.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            if ($ln -notmatch '^[ -]' -and $t.Contains(':')) {
                $k, $v = $t.Split(':', 2); $key = $k.Trim(); $v = $v.Trim()
                if ($key -eq 'merge') { $merge = ($v -eq 'true') }
                elseif ($v.StartsWith('[')) { foreach ($x in $v.Trim('[', ']').Split(',')) { if ($x.Trim()) { if ($key -eq 'remove') { $removed += Id $x } elseif ($key -eq 'entries' -and $x.Contains('/')) { $pk += Id $x } } } }
                continue
            }
            $t = $t.TrimStart('-').Trim()
            if ($t.Contains(':')) { $k, $v = $t.Split(':', 2); if ($key -eq 'entries' -and $k.Trim() -eq 'pack') { $pk += Id $v } }
            elseif ($key -eq 'remove') { $removed += Id $t }
            elseif ($key -eq 'entries' -and $t.Contains('/')) { $pk += Id $t }
        }
        if (-not $merge -and $pk.Count) { $named = $pk } elseif ($merge -and $pk.Count -and $null -ne $named) { $named += $pk }
    } }
}
function Hit($p, $pats) {
    $n = @($p.id, ($p.id -split '/')[-1], $p.into, $(if ($p.kind) { $p.kind } else { 'pack' }), $repo) | Where-Object { $_ }
    foreach ($g in $pats) { foreach ($x in $n) { if ($x -clike $g) { return $true } } }
    $false
}
function Why($p) {
    $half = ($p.id -split '/')[-1]; $kind = if ($p.kind) { $p.kind } else { 'pack' }
    if ($Only.Count -and -not (Hit $p $Only)) { return 'not in -Only' }
    if (Hit $p $Except) { return '-Except' }
    if (Hit $p $removed) { return 'removed in cfg/content' }
    if ($Cfg -and (Test-Path (Join-Path $Cfg "content/$half/disabled"))) { return "cfg/content/$half/disabled" }
    if ($null -ne $named -and $kind -eq 'pack' -and -not ((Hit $p $named) -or ($named | Where-Object { $p.id -clike $_ }))) { return 'not named in cfg/content' }
    ''
}

$bad = 0
foreach ($p in $doc.packs) {
    $kind = if ($p.kind) { $p.kind } else { 'pack' }
    $why = Why $p
    if ($List) { Write-Host ("{0} {1} {2} {3}" -f $(if ($why) { 'skip ' } else { 'fetch' }), $p.id, $p.version, $why); continue }
    if ($kind -eq 'pack' -and -not $Packs) { continue }
    if ($kind -ne 'store' -and $kind -ne 'pack') { continue }
    if ($why) { Write-Host "skip $($p.id) ($why)"; continue }
    $pre = "$($p.id)/$($p.version)"; $want = "$($p.id) $($p.version) $($p.manifest_sha256)"
    $out = if ($kind -eq 'pack') { Join-Path $Packs $pre } else { Join-Path $Root $p.into }
    $stamp = Join-Path $out '.dot-pack'
    if ((Test-Path $stamp) -and ((Get-Content -Raw $stamp).Trim() -eq $want)) { Write-Host "have $($p.id) $($p.version)"; continue }
    try {
        $man = if ($kind -eq 'pack') { Join-Path $out 'manifest.json' } else { Join-Path $out '.manifest.json' }
        Fetch "$pre/manifest.json" $man $p.manifest_sha256
        $pad = (Get-Content -Raw $man | ConvertFrom-Json).payload.Replace('-', '+').Replace('_', '/')
        $pad += '=' * ((4 - $pad.Length % 4) % 4)
        $files = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pad)) | ConvertFrom-Json).files
        foreach ($f in $files) {
            if ($f.path.StartsWith('/') -or ($f.path -split '/') -contains '..') { throw "unsafe path $($f.path)" }
            $obj = "$pre/objects/$($f.sha256.Substring(0,2))/$($f.sha256)"
            if ($kind -eq 'pack') { $dest = Join-Path $out "objects/$($f.sha256.Substring(0,2))/$($f.sha256)"; if (Test-Path $dest) { continue } }
            else { $dest = Join-Path $out $f.path; if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $f.size)) { continue } }
            Fetch $obj $dest $f.sha256
        }
        Set-Content -NoNewline -Path $stamp -Value "$want`n"
        if ($kind -eq 'store') { Remove-Item -Force $man }
        Write-Host "fetched $($p.id) $($p.version) $($files.Count) files"
    } catch { Write-Host "FAILED $($p.id) $($p.version) $_" -ForegroundColor Red; $bad++ }
}
exit ([int]($bad -gt 0))
