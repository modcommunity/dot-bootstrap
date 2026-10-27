# Fetch every repository's content.lock.json in the tree (the all-in-one run); the same as fetch_all.sh.
#   .\tools\fetch_all.ps1 [-Projects DIR] [-Only a,b] [-Except a,b] [-Cdn URL] [-List]
param([string]$Projects, [string[]]$Only = @(), [string[]]$Except = @(), [string]$Cdn, [switch]$List)
$ErrorActionPreference = 'Stop'
if (-not $Projects) { $Projects = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$bad = 0; $n = 0
foreach ($lock in Get-ChildItem -Path $Projects -Directory | ForEach-Object { Join-Path $_.FullName 'content.lock.json' } | Where-Object { Test-Path $_ }) {
    $dir = Split-Path -Parent $lock
    $a = @{}
    if ($Only.Count) { $a.Only = $Only }
    if ($Except.Count) { $a.Except = $Except }
    if ($Cdn) { $a.Cdn = $Cdn }
    if ($List) { $a.List = $true }
    $deploy = Join-Path $Projects 'dot-server-deploy'
    if (Test-Path $deploy) { $a.Packs = Join-Path $deploy 'content\packs' }
    if ((Test-Path (Join-Path $deploy 'cfg')) -and -not (Test-Path (Join-Path $dir 'cfg'))) { $a.Cfg = Join-Path $deploy 'cfg' }
    Write-Host "== $(Split-Path -Leaf $dir)"; $n++
    & (Join-Path $PSScriptRoot 'fetch_lock.ps1') $lock @a
    if ($LASTEXITCODE) { $bad++ }
}
if (-not $n) { Write-Host "fetch_all: no content.lock.json under $Projects" }
Write-Host "fetch_all: $n lock files, $bad failed"
exit ([int]($bad -gt 0))
