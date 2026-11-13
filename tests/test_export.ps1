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
$wanted = 'Get-GodotTag', 'Get-ExportTemplates', 'Set-ExportPreset', 'Get-DefaultExportPreset', 'Hide-ExportPresets', 'Get-ExportNatives', 'Get-RuntimeNatives', 'Copy-RuntimeNatives', 'Get-NativesFor', 'Test-NativeBuiltHere', 'Get-ExportPlayArgs'
$funcs = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($w in $wanted) {
    $f = $funcs | Where-Object { $_.Name -eq $w } | Select-Object -First 1
    Check "function $w exists" ([bool]$f)
    if ($f) { Invoke-Expression $f.Extent.Text }
}
$script:said = @()
. "$env:H/tools/dot_download.ps1"  # Invoke-DotDownload, as bootstrap.ps1 loads it
function Say ($n, $m, $c) { }
function Ok ($n, $m) { }
function Warn ($n, $m) { $script:warned += $m }
function Err ($n, $m) { $script:said += $m }
function Get-AliasTarget ($n) { if ($n -eq 'game-arena') { 'game-fatal-contact' } }
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
Check 'preset: no file and an unknown preset is refused' (-not (Set-ExportPreset (Join-Path $env:T 'boot') 'macOS' '/t.exe') -and -not (Test-Path (Join-Path $env:T 'boot/export_presets.cfg')))

# A game with no presets at all (every game but FC) gets the default one, kept out of git.
$pg = Join-Path $env:T 'game-plainps'; New-Item -ItemType Directory -Force -Path $pg | Out-Null; git -C $pg init -q
$cfg = Join-Path $pg 'export_presets.cfg'
Check 'default: written for a game with no presets' ((Set-ExportPreset $pg 'Windows x86_64' 'C:\t\win.exe') -and (Test-Path $cfg))
$text = @(Get-Content $cfg)
Check 'default: one preset, the one asked for, at index 0' (@($text | Where-Object { $_ -match '^\[preset\.\d+\]$' }).Count -eq 1 -and $text[0] -eq '[preset.0]' -and $text[2] -eq 'name="Windows x86_64"')
Check 'default: export path names the game' ($text -contains 'export_path="build/windows/game-plainps.exe"')
Check 'default: the template is set once' (@($text | Where-Object { $_ -like 'custom_template/release=*' }).Count -eq 1 -and $text -contains 'custom_template/release="C:/t/win.exe"')
Check 'default: pck beside the exe, all resources' ($text -contains 'binary_format/embed_pck=false' -and $text -contains 'export_filter="all_resources"')
git -C $pg check-ignore -q export_presets.cfg
Check 'default: kept out of git by info/exclude' ($LASTEXITCODE -eq 0 -and -not (git -C $pg status --porcelain))
$null = Set-ExportPreset $pg 'Windows x86_64' '/t2.exe'
Check 'default: a second export updates it, adds nothing' (@(Get-Content $cfg | Where-Object { $_ -match '^\[preset\.' }).Count -eq 2 -and @(Get-Content (Join-Path $pg '.git/info/exclude') | Where-Object { $_ -eq 'export_presets.cfg' }).Count -eq 1)
$wg = Join-Path $env:T 'game-webps'; New-Item -ItemType Directory -Force -Path $wg | Out-Null
Set-Content -Path (Join-Path $wg 'export_presets.cfg') -Value "[preset.0]`n`nname=`"Web`"`n`n[preset.0.options]`n`ncustom_template/release=`"`"`nhtml/export_icon=true"
Check 'default: appended after another preset as preset.1' ((Set-ExportPreset $wg 'Windows x86_64' '/t.exe') -and (Get-Content (Join-Path $wg 'export_presets.cfg')) -contains '[preset.1]')
$text = @(Get-Content (Join-Path $wg 'export_presets.cfg'))
Check 'default: the other preset is untouched' ($text[6] -eq 'custom_template/release=""' -and $text -contains 'html/export_icon=true' -and $text[-5] -ne '')
Check 'default: an unknown preset gives nothing' (@(Get-DefaultExportPreset 'g' 'macOS' 0).Count -eq 0)
$shWin = Join-Path $env:T 'default_windows.cfg'
if (Test-Path $shWin) { Check 'default: the same lines as bootstrap.sh' ((@(Get-DefaultExportPreset 'game-x' 'Windows x86_64' 0) -join "`n") -eq ((Get-Content $shWin) -join "`n")) }

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

# A library an addon loads itself from a .cfg (dot-net's) is copied beside the export by hand.
$rg = Join-Path $env:T 'rgame'
New-Item -ItemType Directory -Force -Path (Join-Path $rg 'addons/dot_net/native/bin'), (Join-Path $rg 'addons/other/native'), (Join-Path $rg 'addons/plain/native') | Out-Null
Set-Content -Path (Join-Path $rg 'addons/dot_net/native/dot_net_native.cfg') -Value "[configuration]`nentry_symbol = `"x_init`"`n[libraries]`nwindows.debug.x86_64 = `"bin/libn.windows.template_debug.x86_64.dll`"`nwindows.release.x86_64 = `"bin/libn.windows.template_release.x86_64.dll`""
Set-Content -Path (Join-Path $rg 'addons/dot_net/native/bin/libn.windows.template_release.x86_64.dll') -Value 'rel'
Set-Content -Path (Join-Path $rg 'addons/other/native/o.cfg') -Value "[configuration]`nentry_symbol = `"o_init`"`n[libraries]`nlinux.release.x86_64 = `"bin/libo.so`""
Set-Content -Path (Join-Path $rg 'addons/plain/native/plugin.cfg') -Value "[plugin]`nname=`"plain`""
$rn = @(Get-RuntimeNatives $rg 'windows')
Check 'runtime natives: only cfgs with an entry_symbol' ($rn.Count -eq 2)
Check 'runtime natives: the release library, path kept' ($rn[0].Lib -eq 'bin/libn.windows.template_release.x86_64.dll' -and $rn[0].Cfg -like '*dot_net_native.cfg')
Check 'runtime natives: none for this platform is empty' ($rn[1].Lib -eq '')
$bo = Join-Path $env:T 'rout'; New-Item -ItemType Directory -Force -Path (Join-Path $bo 'o') | Out-Null
$script:warned = @(); $script:said = @()
Check 'runtime natives: copied' (Copy-RuntimeNatives $rg 'windows' $bo)
Check 'runtime natives: the cfg goes into <out>/<cfg name>/' (Test-Path (Join-Path $bo 'dot_net_native/dot_net_native.cfg'))
Check 'runtime natives: the library beside it at the cfg path' ((Get-Content (Join-Path $bo 'dot_net_native/bin/libn.windows.template_release.x86_64.dll') -ErrorAction SilentlyContinue) -eq 'rel')
Check 'runtime natives: the debug library is not copied' (-not (Test-Path (Join-Path $bo 'dot_net_native/bin/libn.windows.template_debug.x86_64.dll')))
Check 'runtime natives: a missing one warns and leaves nothing stale' (-not (Test-Path (Join-Path $bo 'o')) -and $script:warned.Count -eq 1 -and $script:said.Count -eq 0)

# Pins: the optional third field is the library directory; a Godot-named file counts as built.
$gi = Join-Path $env:T 'pins.gitignore'
Set-Content -Path $gi -Value "# bootstrap-natives: dot-sim v1.0.0`n# bootstrap-optional`n/addons/dot_sim`n# bootstrap-natives: dot-net v1.2.3 native/bin/`n/addons/dot_net"
function Get-GitignorePath ($p) { $gi }
$pins = @(Get-NativesFor 'x')
Check 'pins: both read' ($pins.Count -eq 2)
Check 'pins: bin by default' ($pins[0].Addon -eq 'dot_sim' -and $pins[0].LibDir -eq 'bin')
Check 'pins: the third field, trailing slash dropped' ($pins[1].Addon -eq 'dot_net' -and $pins[1].Tag -eq 'v1.2.3' -and $pins[1].LibDir -eq 'native/bin')
$lb = Join-Path $env:T 'libdir'; New-Item -ItemType Directory -Force -Path $lb | Out-Null
Check 'built here: an empty folder is not' (-not (Test-NativeBuiltHere $lb 'windows-x86_64'))
Set-Content -Path (Join-Path $lb 'libn.linux.template_release.x86_64.so') -Value 'x'
Check 'built here: another platform does not count' (-not (Test-NativeBuiltHere $lb 'windows-x86_64'))
Set-Content -Path (Join-Path $lb 'libn.windows.template_release.x86_64.dll') -Value 'x'
Check 'built here: a Godot-named library for the platform' (Test-NativeBuiltHere $lb 'windows-x86_64')
Set-Content -Path (Join-Path $lb 'libn.macos.template_release.universal.dylib') -Value 'x'
Check 'built here: universal serves every arch' (Test-NativeBuiltHere $lb 'macos-arm64')
New-Item -ItemType Directory -Force -Path (Join-Path $lb 'linux-arm64') | Out-Null; Set-Content -Path (Join-Path $lb 'linux-arm64/l.so') -Value 'x'
Check 'built here: a platform folder (dot-sim)' (Test-NativeBuiltHere $lb 'linux-arm64')

# What the exported game is started with.
$d = @(Get-ExportPlayArgs '')
Check 'play args: the defaults' (($d -join ' ') -eq '-- --offline +bot_quota 8 +profiler_overlay 1 +profiler_record_seconds 60')
$d = @(Get-ExportPlayArgs '+bot_quota 16  --map dm_atrium')
Check 'play args: the given ones come last' (($d[-4..-1] -join ' ') -eq '+bot_quota 16 --map dm_atrium' -and $d[0] -eq '--' -and $d.Count -eq 12)
Check 'play args: FC under its old name' ((@(Get-ExportPlayArgs '' 'game-arena') -join ' ') -eq '-- --offline +bot_quota 8 +profiler_overlay 1 +profiler_record_seconds 60')
Check 'play args: any other game only --offline and the given ones' ((@(Get-ExportPlayArgs '--map x' 'game-playlot') -join ' ') -eq '-- --offline --map x')

Write-Host "test_export: $pass passed, $fail failed"
if ($fail -ne 0) { exit 1 }
