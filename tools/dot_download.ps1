# The one downloader for bootstrap.ps1 and tools/fetch_lock.ps1 (dot-source it). Windows PowerShell 5.1 and pwsh 7.
#   Invoke-DotDownload <url> <file> [-Name n] [-Progress p] [-Resume]   stream <url> to <file> (256 KB buffer)
#   $p = New-DotProgress <name> [-Total bytes] [-Files n]; $p.File = i; Write-DotProgress $p [-Final]   one line for many files
# Its own progress, never PowerShell's: Invoke-WebRequest's progress bar slows a 5.1 download to a crawl, and with the
# bar silenced a 1.9 GB store fetch printed nothing for 45 minutes. A line every ~2 s ($env:DOT_PROGRESS_SECONDS), laid
# out like bootstrap.ps1's Say: name, [file i/n,] MB done / total, MB/s, ETA. A download that ends inside the first
# tick prints nothing. A connection that sends no byte for 60 s ($env:DOT_DOWNLOAD_STALL) fails instead of hanging;
# the callers keep their own retries and hash checks. -Resume continues an existing <file> with a Range request.
Add-Type -AssemblyName System.Net.Http
$script:DotHttp = $null

function Get-DotStallSeconds { $s = $env:DOT_DOWNLOAD_STALL -as [int]; if ($s -gt 0) { $s } else { 60 } }

function Get-DotHttp {
    if (-not $script:DotHttp) {
        # .NET Framework before 4.7 offers only TLS 1.0 by default; every host we fetch from wants 1.2.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        # No automatic decompression: fetch_lock hashes what it got and gunzips a gzip object itself, and a Range
        # resume needs the bytes as stored.
        $h = New-Object System.Net.Http.HttpClientHandler
        $c = New-Object System.Net.Http.HttpClient($h)
        $c.Timeout = [TimeSpan]::FromSeconds((Get-DotStallSeconds))  # until the response headers; the body has its own check
        # Cloudflare refuses some agents (error 1010) on dev.dotgames.org; the same agent as fetch_lock.sh.
        [void]$c.DefaultRequestHeaders.UserAgent.TryParseAdd('dot-bootstrap-fetch-lock/1')
        $script:DotHttp = $c
    }
    $script:DotHttp
}

function New-DotProgress([string]$Name, [long]$Total = -1, [int]$Files = 0) {
    $every = $env:DOT_PROGRESS_SECONDS -as [double]; if ($null -eq $every -or $every -lt 0) { $every = 2.0 }
    @{ Name = $Name; Total = $Total; Done = [long]0; Files = $Files; File = 0; Every = $every
       Watch = [Diagnostics.Stopwatch]::StartNew(); Next = $every; Shown = $false }
}

function Format-DotSize([double]$b) { '{0:N1}' -f ($b / 1MB) }

function Format-DotEta([double]$s) {
    if ($s -lt 0 -or [double]::IsInfinity($s) -or [double]::IsNaN($s)) { return '?' }
    $t = [TimeSpan]::FromSeconds([math]::Ceiling($s))
    if ($t.TotalHours -ge 1) { '{0}h{1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
    elseif ($t.TotalMinutes -ge 1) { '{0}m{1:00}s' -f $t.Minutes, $t.Seconds }
    else { '{0}s' -f $t.Seconds }
}

function Format-DotProgress($p) {
    $sec = $p.Watch.Elapsed.TotalSeconds
    $rate = if ($sec -gt 0) { $p.Done / $sec } else { 0 }
    $parts = @()
    if ($p.Files -gt 0) { $parts += 'file {0}/{1}' -f $p.File, $p.Files }
    if ($p.Total -gt 0) { $parts += '{0} / {1} MB' -f (Format-DotSize $p.Done), (Format-DotSize $p.Total) }
    else { $parts += '{0} MB' -f (Format-DotSize $p.Done) }
    $parts += '{0} MB/s' -f (Format-DotSize $rate)
    if ($p.Total -gt 0) { $parts += 'ETA ' + $(if ($rate -gt 0) { Format-DotEta (($p.Total - $p.Done) / $rate) } else { '?' }) }
    $parts -join '  '
}

# The same layout as bootstrap.ps1's Say: the name in 22 columns, then the message.
function Write-DotProgress($p, [switch]$Final) {
    $sec = $p.Watch.Elapsed.TotalSeconds
    if ($Final) { if (-not $p.Shown) { return } }
    elseif ($sec -lt $p.Next) { return }
    else { $p.Next = $sec + $p.Every }
    $p.Shown = $true
    $msg = if ($Final) { 'done {0} MB in {1}' -f (Format-DotSize $p.Done), (Format-DotEta $sec) } else { Format-DotProgress $p }
    Write-Host ("{0,-22} " -f $p.Name) -NoNewline
    Write-Host $msg -ForegroundColor DarkGray
}

# The innermost exception of a .NET call (a task wraps the real one in AggregateException and PowerShell in another).
function Get-DotError($e) { while ($e.InnerException) { $e = $e.InnerException }; $e.Message }

function Wait-DotTask($task, [int]$sec, [string]$what) {
    $ok = $false
    try { $ok = $task.Wait([TimeSpan]::FromSeconds($sec)) } catch { throw "$what failed: $(Get-DotError $_.Exception)" }
    if (-not $ok) { throw "$what stalled: nothing for $sec s" }
    $task.Result
}

function Invoke-DotDownload([string]$Uri, [string]$OutFile, [string]$Name = '', $Progress = $null, [switch]$Resume) {
    $own = $null -eq $Progress
    if (-not $Name) { $Name = @($Uri -split '[/?]' | Where-Object { $_ })[-1] }
    $OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $stall = Get-DotStallSeconds
    $have = if ($Resume -and (Test-Path -LiteralPath $OutFile)) { (Get-Item -LiteralPath $OutFile).Length } else { [long]0 }
    $start = if ($own) { [long]0 } else { $Progress.Done }
    $req = $null; $resp = $null; $in = $null; $out = $null
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Uri)
        if ($have -gt 0) { $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($have, $null) }
        $resp = Wait-DotTask ((Get-DotHttp).SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)) ($stall + 5) $Uri
        if ($have -gt 0 -and [int]$resp.StatusCode -eq 416) { return }  # already whole; the caller's hash check decides
        if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase) for $Uri" }
        if ([int]$resp.StatusCode -ne 206) { $have = [long]0 } elseif (-not $own) { $Progress.Done += $have }
        $len = $resp.Content.Headers.ContentLength
        $len = if ($null -ne $len) { [long]$len } else { [long]-1 }
        if ($own) { $Progress = New-DotProgress $Name $(if ($len -ge 0) { $len + $have } else { -1 }); $Progress.Done = $have }
        $in = Wait-DotTask ($resp.Content.ReadAsStreamAsync()) $stall $Uri
        $mode = if ($have -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $out = New-Object IO.FileStream($OutFile, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None, 262144)
        $buf = New-Object byte[] 262144
        $got = [long]0
        while ($true) {
            $n = Wait-DotTask ($in.ReadAsync($buf, 0, $buf.Length)) $stall $Uri
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $got += $n
            $Progress.Done += $n
            Write-DotProgress $Progress
        }
        if ($len -ge 0 -and $got -lt $len) { throw "$Uri ended after $got of $len bytes" }
    } catch {
        # Not counted twice when the caller retries; with -Resume the part is kept for the next try.
        if (-not $own) { $Progress.Done = $start }
        if ($out) { $out.Dispose(); $out = $null }
        if (-not $Resume) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
        if ($resp) { $resp.Dispose() }
        if ($req) { $req.Dispose() }
    }
    if ($own) { Write-DotProgress $Progress -Final }
}
