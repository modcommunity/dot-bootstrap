# Import every game project headless, so the editor never has to do the first import.
# The editor crashes on a first import of some projects; -headless does not.
#   tools\import-all.ps1 -ProjectsDir <dir> -Godot <exe> [-Names a,b]
# With no names, every game-*, mg-* directory (not *-maps) that has a project.godot.
# -Jobs N imports N projects at once (default: the CPU count).
# A project that fails is imported once more (the first pass registers class_name globals).
param([Parameter(Mandatory)][string]$ProjectsDir, [Parameter(Mandatory)][string]$Godot, [string[]]$Names = @(), [int]$Jobs = [Environment]::ProcessorCount)
if ($Names.Count -eq 0) {
    $Names = @(Get-ChildItem $ProjectsDir -Directory |
        Where-Object { ($_.Name -like 'game-*' -or $_.Name -like 'mg-*') -and $_.Name -notlike '*-maps' -and (Test-Path (Join-Path $_.FullName 'project.godot')) } |
        ForEach-Object { $_.Name })
}
$bad = $false
$work = {
    param($Godot, $d, $p)
    $log = Join-Path $d 'import-run.txt'
    $ok = $false
    foreach ($pass in 1, 2) {
        # Piping makes PowerShell wait for the GUI-subsystem executable to exit. The output is held in memory so a log another process has open (a stale Godot, antivirus) cannot fail the import.
        $out = & $Godot --headless --path $d --import 2>&1
        $code = $LASTEXITCODE
        try { $out | Out-File -Encoding utf8 $log -ErrorAction Stop }
        catch { $log = Join-Path $d ("import-run-{0}.txt" -f [Guid]::NewGuid().ToString('N').Substring(0, 8)); $out | Out-File -Encoding utf8 $log -ErrorAction SilentlyContinue }
        if ($code -eq 0) { $ok = $true; break }
    }
    if ($ok) { Remove-Item $log -ErrorAction SilentlyContinue; "ok|imported  $p" }
    else { "bad|FAILED twice: $p, output in $log" }
}
$running = @()
function Receive-Done ($j) {
    foreach ($line in (Receive-Job $j -Wait)) {
        $kind, $msg = $line -split '\|', 2
        if ($kind -eq 'bad') { Write-Host $msg -ForegroundColor Red; $script:bad = $true } else { Write-Host $msg -ForegroundColor Cyan }
    }
    Remove-Job $j
}
foreach ($p in $Names) {
    $d = Join-Path $ProjectsDir $p
    if (-not (Test-Path (Join-Path $d 'project.godot'))) { Write-Host "skip $p (not a project here)"; continue }
    while (@($running | Where-Object { $_.State -eq 'Running' }).Count -ge [Math]::Max(1, $Jobs)) { Start-Sleep -Milliseconds 300 }
    $done = @($running | Where-Object { $_.State -ne 'Running' }); foreach ($j in $done) { Receive-Done $j }
    $running = @($running | Where-Object { $_.State -eq 'Running' })
    $running += Start-Job -ScriptBlock $work -ArgumentList $Godot, $d, $p
}
foreach ($j in $running) { Receive-Done $j }
if ($bad) { exit 1 }
