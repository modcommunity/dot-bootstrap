# Driven by test_export.sh. Loads the export functions out of bootstrap.ps1 by name (the
# script itself cannot be dot-sourced: it runs a sync) and checks them against a fake release.
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Check ($name, $cond) { if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $name" } }

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$env:H/bootstrap.ps1", [ref]$tokens, [ref]$errors)
Check 'bootstrap.ps1 parses' ($errors.Count -eq 0)
foreach ($e in $errors) { Write-Host "  $($e.Extent.StartLineNumber): $($e.Message)" }
foreach ($p in 'Export', 'PlayExport', 'PlayArgs') {
    Check "param -$p exists" ([bool]($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $p }))
}
$wanted = 'Get-GodotTag', 'Get-ExportTemplates', 'Set-ExportPreset', 'Get-ExportNatives', 'Get-ExportPlayArgs'
$funcs = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($w in $wanted) {
    $f = $funcs | Where-Object { $_.Name -eq $w } | Select-Object -First 1
    Check "function $w exists" ([bool]$f)
    if ($f) { Invoke-Expression $f.Extent.Text }
}
$script:said = @()
function Ok ($n, $m) { }
function Warn ($n, $m) { }
function Err ($n, $m) { $script:said += $m }
$repoDir = Join-Path $env:T 'boot'; New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
$tag = $env:TAG

Check 'tag from the download name' ((Get-GodotTag 'C:\x\Godot_v4.7.2-stable_win64.exe') -eq '4.7.2-stable')
Check 'tag from an rc name' ((Get-GodotTag '/x/Godot_v4.8-rc1_win64_console.exe') -eq '4.8-rc1')
$fake = Join-Path $env:T 'godot'; Set-Content -Path $fake -Value "#!/bin/sh`necho 4.7.2.stable.official.ed1daf0bf"; chmod +x $fake
Check 'tag from --version' ((Get-GodotTag $fake) -eq '4.7.2-stable')
Check 'no tag from a thing that is not Godot' ($null -eq (Get-GodotTag (Join-Path $env:T 'nothing-here')))

$dest = Join-Path $repoDir ".godot-bin/$tag/templates"
$got = Get-ExportTemplates $tag
Check 'templates: returns the release template' ($got -eq (Join-Path $dest 'windows_release_x86_64.exe'))
Check 'templates: release template unpacked' ((Get-Content (Join-Path $dest 'windows_release_x86_64.exe') -ErrorAction SilentlyContinue) -eq 'release')
Check 'templates: console wrapper unpacked' (Test-Path (Join-Path $dest 'windows_release_x86_64_console.exe'))
Check 'templates: nothing else kept' (@(Get-ChildItem $dest).Count -eq 2)
Check 'templates: no error said' ($script:said.Count -eq 0)
Remove-Item -Recurse -Force "$env:T/rel/$tag"
Check 'templates: a second call downloads nothing' ((Get-ExportTemplates $tag) -eq $got)

# A release whose archive does not match its published sum installs nothing.
$bad = '9.9.8-stable'; $r = Join-Path $env:T "rel/$bad"; New-Item -ItemType Directory -Force -Path $r | Out-Null
Set-Content -Path (Join-Path $r "Godot_v$bad`_export_templates.tpz") -Value 'not the archive'
Set-Content -Path (Join-Path $r 'SHA512-SUMS.txt') -Value ("0" * 128 + "  Godot_v$bad`_export_templates.tpz")
$script:said = @()
Check 'bad sum: returns nothing' ($null -eq (Get-ExportTemplates $bad))
Check 'bad sum: says so' (($script:said -join ' ') -match 'checksum mismatch')
Check 'bad sum: nothing left behind' (@(Get-ChildItem (Join-Path $repoDir ".godot-bin/$bad/templates") -ErrorAction SilentlyContinue).Count -eq 0)
$script:said = @()
Check 'no such release: returns nothing' ($null -eq (Get-ExportTemplates '1.2.3-stable'))
Check 'no such release: says so' ($script:said.Count -eq 1)

$game = Join-Path $env:T 'game'; $cfg = Join-Path $game 'export_presets.cfg'
Check 'preset: made from the example' ((Set-ExportPreset $game 'Windows x86_64' 'C:\boot\.godot-bin\t\windows_release_x86_64.exe') -and (Test-Path $cfg))
$text = Get-Content $cfg
Check 'preset: one line changed, forward slashes' (@($text | Where-Object { $_ -eq 'custom_template/release="C:/boot/.godot-bin/t/windows_release_x86_64.exe"' }).Count -eq 1)
Check 'preset: the Linux preset is untouched' (@($text | Where-Object { $_ -eq 'custom_template/release=""' }).Count -eq 1)
Check 'preset: same line count' ($text.Count -eq @(Get-Content (Join-Path $game 'export_presets.example.cfg')).Count)
Check 'preset: no byte-order mark' ([IO.File]::ReadAllBytes($cfg)[0] -ne 0xEF)
Check 'preset: an existing file is updated, not replaced' ((Set-ExportPreset $game 'Windows x86_64' '/other/t.exe') -and @(Get-Content $cfg | Where-Object { $_ -eq 'custom_template/release="/other/t.exe"' }).Count -eq 1)
Set-Content -Path $cfg -Value "[preset.0]`nname=`"Windows x86_64`"`n`n[preset.0.options]`nbinary_format/embed_pck=false"
Check 'preset: a missing key is added' ((Set-ExportPreset $game 'Windows x86_64' '/t.exe') -and (Get-Content $cfg)[-1] -eq 'custom_template/release="/t.exe"')
$script:said = @()
Check 'preset: an unknown preset is refused' (-not (Set-ExportPreset $game 'macOS' '/t.exe') -and $script:said.Count -eq 1)
Check 'preset: no file at all is refused' (-not (Set-ExportPreset (Join-Path $env:T 'boot') 'Windows x86_64' '/t.exe'))

# Natives: the library each extension loads on this platform, by the keys Godot accepts.
$ng = Join-Path $env:T 'ngame'
New-Item -ItemType Directory -Force -Path (Join-Path $ng 'addons/a/bin'), (Join-Path $ng 'addons/b'), (Join-Path $ng 'addons/c') | Out-Null
Set-Content -Path (Join-Path $ng 'addons/a/a.gdextension') -Value "[libraries]`n; windows.x86_64 = `"res://no.dll`"`nlinux.x86_64 = `"res://addons/a/bin/liba.so`"`nwindows.x86_64 = `"res://addons/a/bin/win/a.dll`""
Set-Content -Path (Join-Path $ng 'addons/b/b.gdextension') -Value "[libraries]`nwindows.debug.x86_64 = `"res://addons/b/b_debug.dll`"`nwindows.release.x86_64 = `"res://addons/b/b_release.dll`""
Set-Content -Path (Join-Path $ng 'addons/c/c.gdextension') -Value "[libraries]`nlinux.x86_64 = `"res://addons/c/libc.so`""
$n = @(Get-ExportNatives $ng 'windows')
Check 'natives: one entry per extension' ($n.Count -eq 3)
Check 'natives: a plain platform key is read, a commented one is not' ($n[0].Ext -eq 'a.gdextension' -and $n[0].Lib -eq 'a.dll')
Check 'natives: the release key is read, the debug one is not' ($n[1].Lib -eq 'b_release.dll')
Check 'natives: no library for this platform is empty' ($n[2].Ext -eq 'c.gdextension' -and $n[2].Lib -eq '')
Check 'natives: the other platform reads its own' ((@(Get-ExportNatives $ng 'linux')[0]).Lib -eq 'liba.so')

# What the exported game is started with.
$d = @(Get-ExportPlayArgs '')
Check 'play args: the defaults' (($d -join ' ') -eq '-- --offline +bot_quota 8 +profiler_overlay 1 +profiler_record_seconds 60')
$d = @(Get-ExportPlayArgs '+bot_quota 16  --map dm_atrium')
Check 'play args: the given ones come last' (($d[-4..-1] -join ' ') -eq '+bot_quota 16 --map dm_atrium' -and $d[0] -eq '--' -and $d.Count -eq 12)

Write-Host "test_export: $pass passed, $fail failed"
if ($fail -ne 0) { exit 1 }
