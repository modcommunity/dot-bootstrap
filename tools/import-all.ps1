# Import every game project headless, so the editor never has to do the first import.
# The editor crashes on a first import of some projects; -headless does not.
#   tools\import-all.ps1 -ProjectsDir <dir> -Godot <exe> [-Names a,b]
# With no names, every game-*, mg-* directory (not *-maps) that has a project.godot.
# A project that fails is imported once more (the first pass registers class_name globals).
param([Parameter(Mandatory)][string]$ProjectsDir, [Parameter(Mandatory)][string]$Godot, [string[]]$Names = @())
if ($Names.Count -eq 0) {
    $Names = @(Get-ChildItem $ProjectsDir -Directory |
        Where-Object { ($_.Name -like 'game-*' -or $_.Name -like 'mg-*') -and $_.Name -notlike '*-maps' -and (Test-Path (Join-Path $_.FullName 'project.godot')) } |
        ForEach-Object { $_.Name })
}
$bad = $false
foreach ($p in $Names) {
    $d = Join-Path $ProjectsDir $p
    if (-not (Test-Path (Join-Path $d 'project.godot'))) { Write-Host "skip $p (not a project here)"; continue }
    Write-Host "importing $p" -ForegroundColor Cyan
    $log = Join-Path $d 'import-run.txt'
    $ok = $false
    foreach ($pass in 1, 2) {
        # Piping makes PowerShell wait for the GUI-subsystem executable to exit.
        & $Godot --headless --path $d --import 2>&1 | Out-File -Encoding utf8 $log
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    }
    if ($ok) { Remove-Item $log -ErrorAction SilentlyContinue }
    else { Write-Host "  FAILED twice, output in $log" -ForegroundColor Red; $bad = $true }
}
if ($bad) { exit 1 }
