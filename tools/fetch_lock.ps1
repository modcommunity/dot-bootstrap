# Fetch exactly what a pack lock names, hash-checked, into each store entry's folder (present files skipped, bad downloads retried).
#   .\tools\fetch_lock.ps1 <content.lock.json> [-Root DIR] [-From BASE] [-Skip id,into,kind] [-Only id,into]
# Lock format and layout: see fetch_lock.sh. $env:DOT_PACKS_FROM = 'none' fetches nothing.
param([Parameter(Mandatory)][string]$Lock, [string]$Root, [string]$From, [string[]]$Skip = @(), [string[]]$Only = @())
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Resolve-Path $Lock) }
if (-not $From) { $From = $env:DOT_PACKS_FROM }
if ($From -eq 'none') { Write-Host 'fetch_lock: DOT_PACKS_FROM=none, nothing fetched'; exit 0 }
$doc = Get-Content -Raw $Lock | ConvertFrom-Json
if ($doc.format -ne 1) { throw 'fetch_lock: unsupported lock format' }
$bases = if ($From) { @($From) } else { @($doc.origin) + @($doc.mirrors) }
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

$bad = 0
foreach ($p in $doc.packs) {
    if ($p.kind -ne 'store') { continue }
    if (($Skip -contains $p.id) -or ($Skip -contains $p.into) -or ($Skip -contains $p.kind) -or ($Only.Count -and -not (($Only -contains $p.id) -or ($Only -contains $p.into)))) { Write-Host "skip $($p.id)"; continue }
    $out = Join-Path $Root $p.into; $stamp = Join-Path $out '.dot-pack'; $want = "$($p.id) $($p.version) $($p.manifest_sha256)"
    if ((Test-Path $stamp) -and ((Get-Content -Raw $stamp).Trim() -eq $want)) { Write-Host "have $($p.id) $($p.version)"; continue }
    try {
        $pre = "$($p.id)/$($p.version)"
        $man = Join-Path $out '.manifest.json'
        Fetch "$pre/manifest.json" $man $p.manifest_sha256
        $pad = (Get-Content -Raw $man | ConvertFrom-Json).payload.Replace('-', '+').Replace('_', '/')
        $pad += '=' * ((4 - $pad.Length % 4) % 4)
        $files = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pad)) | ConvertFrom-Json).files
        foreach ($f in $files) {
            if ($f.path.StartsWith('/') -or ($f.path -split '/') -contains '..') { throw "unsafe path $($f.path)" }
            $dest = Join-Path $out $f.path
            if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $f.size)) { continue }
            Fetch "$pre/objects/$($f.sha256.Substring(0,2))/$($f.sha256)" $dest $f.sha256
        }
        Set-Content -NoNewline -Path $stamp -Value "$want`n"
        Remove-Item -Force $man
        Write-Host "fetched $($p.id) $($p.version) $($files.Count) files"
    } catch { Write-Host "FAILED $($p.id) $($p.version) $_" -ForegroundColor Red; $bad++ }
}
exit ([int]($bad -gt 0))
