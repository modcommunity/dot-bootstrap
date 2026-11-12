# Driven by test_download.sh ($env:T scratch, $env:H the repo, $env:U the fixture server).
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Check ($name, $cond) { if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $name" } }
. "$env:H/tools/dot_download.ps1"
$env:DOT_PROGRESS_SECONDS = '0'
$T = $env:T; $U = $env:U
$big = [IO.File]::ReadAllBytes("$T/cdn/big")
function Same($f) { $b = [IO.File]::ReadAllBytes($f); $b.Length -eq $big.Length -and [Linq.Enumerable]::SequenceEqual($b, $big) }

# A whole download prints its own lines (name, MB done / total, MB/s, ETA) and a done line.
$out = & { Invoke-DotDownload "$U/big" "$T/big1" } 6>&1 | Out-String
Check 'big downloaded whole' (Same "$T/big1")
Check 'progress line with name, total, rate, ETA' ($out -match 'big\s+[\d.]+ / 3\.0 MB  [\d.]+ MB/s  ETA ')
Check 'done line' ($out -match 'done 3\.0 MB in ')

# A 404 throws and leaves no file.
$e = $null; try { Invoke-DotDownload "$U/nothing" "$T/none" } catch { $e = "$_" }
Check '404 throws' ($e -match 'HTTP 404')
Check '404 leaves no file' (-not (Test-Path "$T/none"))

# A connection that goes quiet fails after DOT_DOWNLOAD_STALL instead of hanging.
$env:DOT_DOWNLOAD_STALL = '2'; $script:DotHttp = $null
$w = [Diagnostics.Stopwatch]::StartNew(); $e = $null
try { Invoke-DotDownload "$U/hang" "$T/hang" 6>$null } catch { $e = "$_" }
Check "stall throws ($e)" ($e -match 'stalled')
Check "stall fails fast ($([int]$w.Elapsed.TotalSeconds) s)" ($w.Elapsed.TotalSeconds -lt 15)
Remove-Item Env:DOT_DOWNLOAD_STALL; $script:DotHttp = $null

# -Resume continues a part with a Range request; a whole part gets 416 and is left alone.
[IO.File]::WriteAllBytes("$T/big2", $big[0..999999])
$p = New-DotProgress 'r' $big.Length
Invoke-DotDownload "$U/big" "$T/big2" -Progress $p -Resume 6>$null
Check 'resumed file whole' (Same "$T/big2")
Check 'resume counts the part as done' ($p.Done -eq $big.Length)
Invoke-DotDownload "$U/big" "$T/big2" -Resume 6>$null
Check '416 keeps the whole file' (Same "$T/big2")
$log = Get-Content -Raw "$T/server.log"
Check 'Range sent' ($log -match 'GET /big HTTP/1.1 bytes=1000000-')

# fetch_lock.ps1: file i/n progress, the wrong first copy of flaky.txt is retried, the store is stamped.
$out = & pwsh -NoProfile -NonInteractive -File "$env:H/tools/fetch_lock.ps1" "$T/repo/content.lock.json" -Cdn $U 2>&1 | Out-String
Check "fetch_lock exit 0 ($LASTEXITCODE)" ($LASTEXITCODE -eq 0)
Check 'header line' ($out -match 'fetching o/zz-alpha 1\.0\.0: 3 files, 0\.3 MB')
Check 'file i/n line' ($out -match 'o/zz-alpha\s+file [123]/3  [\d.]+ / 0\.3 MB')
Check 'hash mismatch retried' ($out -match 'retry .*hash mismatch')
Check 'files there' ((Get-Content -Raw "$T/repo/.alpha/flaky.txt") -eq 'flaky data' -and (Get-Item "$T/repo/.alpha/a.txt").Length -eq 300000 -and (Test-Path "$T/repo/.alpha/sub/b.txt"))
Check 'stamped, manifest gone' ((Test-Path "$T/repo/.alpha/.dot-pack") -and -not (Test-Path "$T/repo/.alpha/.manifest.json"))
Check 'no part left' (-not (Get-ChildItem -Recurse "$T/repo/.alpha" -Filter '*.part'))
$out2 = & pwsh -NoProfile -NonInteractive -File "$env:H/tools/fetch_lock.ps1" "$T/repo/content.lock.json" -Cdn $U 2>&1 | Out-String
Check 'second run has it' ($out2 -match 'have o/zz-alpha 1\.0\.0')
if ($fail) { Write-Host $out }
Write-Host "test_download: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
