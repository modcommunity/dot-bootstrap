#!/usr/bin/env bash
# bootstrap.sh --export / --play-export and bootstrap.ps1 -Export / -PlayExport: the template
# download checks its SHA-512 and keeps only this platform's release template, the preset is
# pointed at it, each extension's library is named, and the game is started with the
# profiling arguments. The release is a fake one served from localhost; the PowerShell half
# needs pwsh (skipped without it). Run: tests/test_export.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
tag=9.9.9-stable; R="$T/rel/$tag"; mkdir -p "$R" "$T/z/templates" "$T/game"
echo release > "$T/z/templates/windows_release_x86_64.exe"; echo console > "$T/z/templates/windows_release_x86_64_console.exe"
echo big > "$T/z/templates/linux_release.x86_64"
(cd "$T/z" && python3 -m zipfile -c "$R/Godot_v${tag}_export_templates.tpz" templates)
(cd "$R" && sha512sum "Godot_v${tag}_export_templates.tpz" > SHA512-SUMS.txt)
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
(cd "$T/rel" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & SRV=$!
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done
cat > "$T/game/export_presets.example.cfg" <<'CFG'
; a comment
[preset.0]

name="Linux x86_64"
platform="Linux"

[preset.0.options]

custom_template/release=""

[preset.1]

name="Windows x86_64"
platform="Windows Desktop"

[preset.1.options]

custom_template/debug=""
custom_template/release=""
binary_format/embed_pck=false
CFG
rc=0
DOT_GODOT_BASE="http://127.0.0.1:$port" T="$T" H="$H" TAG="$tag" bash "$H/tests/test_export_sh.sh" || rc=1
if command -v pwsh >/dev/null 2>&1; then
    DOT_GODOT_BASE="http://127.0.0.1:$port" T="$T" H="$H" TAG="$tag" pwsh -NoProfile -NonInteractive -File "$H/tests/test_export.ps1" || rc=1
else echo "test_export (ps1): skipped (no pwsh)"; fi
exit $rc
