#!/usr/bin/env bash
# Driven by test_export.sh. Loads the export functions out of bootstrap.sh (the script
# itself cannot be sourced: it runs a sync) and checks them against a fake release.
set -u
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
bash -n "$H/bootstrap.sh"; check 'bootstrap.sh parses' "[ $? = 0 ]"
RED=''; YLW=''; CYN=''; DIM=''; GRN=''; OFF=''
SELF_DIR="$T/shboot"; PROJECTS_DIR="$T/proj"; mkdir -p "$SELF_DIR" "$PROJECTS_DIR"
games() { printf '%s\n' game-arena mg-pong game-arena-maps; }
ok() { :; }
alias_target() { [ "$1" = fatal-contact ] && echo game-arena; }
block="$(sed -n '/^# --- Release export /,/^# --- Modes /p' "$H/bootstrap.sh")"
check 'the export block is found' '[ -n "$block" ]'
eval "$block"
for f in resolve_game godot_tag get_export_templates set_export_preset export_natives export_runtime_natives bundle_runtime_natives export_game play_export; do
    check "function $f exists" "declare -F $f >/dev/null"
done
for flag in '--export|--play-export) ARGS' '--list|--play|--export|--play-export|' '    --export)' '    --play-export)'; do
    check "bootstrap.sh handles $flag" 'grep -qF -- "$flag" "$H/bootstrap.sh"'
done
check 'the help shows both modes' '[ "$(sed -n 3,48p "$H/bootstrap.sh" | grep -c -- "--export arena\|--play-export arena")" = 2 ]'

check 'game: short name' '[ "$(resolve_game arena)" = game-arena ]'
check 'game: another name from projects.tsv' '[ "$(resolve_game fatal-contact)" = game-arena ]'
check 'game: full name' '[ "$(resolve_game mg-pong)" = mg-pong ]'
check 'game: unknown is refused' '! resolve_game nothing >/dev/null'

check 'tag: from the file name' '[ "$(godot_tag /x/Godot_v4.7.2-stable_linux.x86_64)" = 4.7.2-stable ]'
check 'tag: a release candidate' '[ "$(godot_tag /x/Godot_v4.8-rc1_linux.x86_64)" = 4.8-rc1 ]'
printf '#!/bin/sh\necho 4.7.2.stable.official.ed1daf0bf\n' > "$T/godot"; chmod +x "$T/godot"
check 'tag: from --version' '[ "$(godot_tag "$T/godot")" = 4.7.2-stable ]'
printf '#!/bin/sh\necho nonsense\n' > "$T/notgodot"; chmod +x "$T/notgodot"
check 'tag: unreadable is refused' '! godot_tag "$T/notgodot" >/dev/null'

dest="$SELF_DIR/.godot-bin/$TAG/templates"
got="$(get_export_templates "$TAG" 2>"$T/err")"
check 'templates: returns the release template' '[ "$got" = "$dest/linux_release.x86_64" ]'
check 'templates: the template is the archive entry' '[ "$(cat "$dest/linux_release.x86_64" 2>/dev/null)" = big ]'
check 'templates: executable' '[ -x "$dest/linux_release.x86_64" ]'
check 'templates: only this platform is kept' '[ "$(ls "$dest" | wc -l)" = 1 ]'
got2="$(DOT_GODOT_BASE=http://127.0.0.1:1 get_export_templates "$TAG" 2>"$T/err")"
check 'templates: a second call downloads nothing' '[ "$got2" = "$got" ] && grep -q already "$T/err"'
# A wrong checksum installs nothing.
bad=8.8.8-stable; mkdir -p "$T/rel/$bad"
cp "$T/rel/$TAG/Godot_v${TAG}_export_templates.tpz" "$T/rel/$bad/Godot_v${bad}_export_templates.tpz"
echo "$(printf '0%.0s' $(seq 128))  Godot_v${bad}_export_templates.tpz" > "$T/rel/$bad/SHA512-SUMS.txt"
check 'templates: a checksum mismatch is refused' '! get_export_templates "$bad" >/dev/null 2>"$T/err" && grep -q "checksum mismatch" "$T/err"'
check 'templates: and leaves nothing behind' '[ -z "$(ls -A "$SELF_DIR/.godot-bin/$bad/templates" 2>/dev/null)" ]'
: > "$T/rel/$bad/SHA512-SUMS.txt"
check 'templates: an unlisted archive is refused' '! get_export_templates "$bad" >/dev/null 2>"$T/err" && grep -q "no checksum" "$T/err"'
check 'templates: a missing release is refused' '! get_export_templates 7.7.7-stable >/dev/null 2>"$T/err" && grep -q "could not download" "$T/err"'

g="$T/shgame"; mkdir -p "$g"; cp "$T/game/export_presets.example.cfg" "$g/"
cfg="$g/export_presets.cfg"
set_export_preset "$g" "Linux x86_64" "/t/linux_release.x86_64"
check 'preset: written from the example' '[ -f "$cfg" ]'
check 'preset: the Linux preset has the template' '[ "$(grep -c "^custom_template/release=\"/t/linux_release.x86_64\"$" "$cfg")" = 1 ]'
check 'preset: the Windows preset is untouched' '[ "$(grep -c "^custom_template/release=\"\"$" "$cfg")" = 1 ]'
check 'preset: same line count' '[ "$(wc -l < "$cfg")" = "$(wc -l < "$g/export_presets.example.cfg")" ]'
check 'preset: the example is untouched' 'cmp -s "$g/export_presets.example.cfg" "$T/game/export_presets.example.cfg"'
set_export_preset "$g" "Linux x86_64" "/other/t"
check 'preset: an existing file is updated, not replaced' '[ "$(grep -c "^custom_template/release=\"/other/t\"$" "$cfg")" = 1 ] && [ "$(grep -c "^custom_template/release=" "$cfg")" = 2 ]'
printf '[preset.0]\nname="Linux x86_64"\n\n[preset.0.options]\nbinary_format/embed_pck=false\n' > "$cfg"
set_export_preset "$g" "Linux x86_64" "/t"
check 'preset: a missing key is added' '[ "$(tail -n1 "$cfg")" = "custom_template/release=\"/t\"" ]'
check 'preset: an unknown preset is refused' '! set_export_preset "$g" macOS /t 2>/dev/null'
mkdir -p "$T/empty"
check 'preset: no file at all is refused' '! set_export_preset "$T/empty" "Linux x86_64" /t 2>/dev/null'

n="$T/shn"; mkdir -p "$n/addons/a" "$n/addons/b" "$n/addons/c"
printf '[libraries]\n; linux.x86_64 = "res://no.so"\nwindows.x86_64 = "res://addons/a/a.dll"\nlinux.x86_64 = "res://addons/a/bin/linux-x86_64/liba.so"\n' > "$n/addons/a/a.gdextension"
printf '[libraries]\nlinux.debug.x86_64 = "res://addons/b/libb_debug.so"\nlinux.release.x86_64 = "res://addons/b/libb_release.so"\n' > "$n/addons/b/b.gdextension"
printf '[libraries]\nwindows.x86_64 = "res://addons/c/c.dll"\n' > "$n/addons/c/c.gdextension"
out="$(export_natives "$n" linux)"
check 'natives: one line per extension' '[ "$(printf "%s\n" "$out" | wc -l)" = 3 ]'
check 'natives: a plain platform key is read, a commented one is not' '[ "$(printf "%s\n" "$out" | sed -n 1p)" = "a.gdextension	liba.so" ]'
check 'natives: the release key is read, the debug one is not' '[ "$(printf "%s\n" "$out" | sed -n 2p)" = "b.gdextension	libb_release.so" ]'
check 'natives: no library for this platform is empty' '[ "$(printf "%s\n" "$out" | sed -n 3p)" = "c.gdextension	" ]'
check 'natives: no addons folder is nothing' '[ -z "$(export_natives "$T/empty" linux)" ]'

# A library an addon loads itself from a .cfg (dot-net's) is copied beside the export by hand.
r="$T/shr"; mkdir -p "$r/addons/dot_net/native/bin" "$r/addons/other/native" "$r/addons/plain/native"
printf '[configuration]\nentry_symbol = "x_init"\n[libraries]\nlinux.debug.x86_64 = "bin/libn.linux.template_debug.x86_64.so"\nlinux.release.x86_64 = "bin/libn.linux.template_release.x86_64.so"\n' > "$r/addons/dot_net/native/dot_net_native.cfg"
echo rel > "$r/addons/dot_net/native/bin/libn.linux.template_release.x86_64.so"
printf '[configuration]\nentry_symbol = "o_init"\n[libraries]\nwindows.release.x86_64 = "bin/o.dll"\n' > "$r/addons/other/native/o.cfg"
printf '[plugin]\nname="plain"\n' > "$r/addons/plain/native/plugin.cfg"
out="$(export_runtime_natives "$r" linux)"
check 'runtime natives: only cfgs with an entry_symbol' '[ "$(printf "%s\n" "$out" | wc -l)" = 2 ]'
check 'runtime natives: the release library, path kept' '[ "$(printf "%s\n" "$out" | sed -n 1p)" = "$r/addons/dot_net/native/dot_net_native.cfg	bin/libn.linux.template_release.x86_64.so" ]'
check 'runtime natives: none for this platform is empty' '[ "$(printf "%s\n" "$out" | sed -n 2p)" = "$r/addons/other/native/o.cfg	" ]'
bo="$T/bout"; mkdir -p "$bo/o"; echo stale > "$bo/o/o.cfg"
bundle_runtime_natives "$r" linux "$bo" 2>"$T/err"
check 'runtime natives: the cfg goes into <out>/<cfg name>/' '[ -f "$bo/dot_net_native/dot_net_native.cfg" ]'
check 'runtime natives: the library beside it at the cfg path' '[ "$(cat "$bo/dot_net_native/bin/libn.linux.template_release.x86_64.so" 2>/dev/null)" = rel ]'
check 'runtime natives: the debug library is not copied' '[ ! -e "$bo/dot_net_native/bin/libn.linux.template_debug.x86_64.so" ]'
check 'runtime natives: a missing one warns and leaves nothing stale' '[ ! -e "$bo/o" ] && grep -q "o: no linux x86_64 library" "$T/err"'
check 'runtime natives: the export bundles them' 'grep -q "bundle_runtime_natives \"\$dir\" linux \"\$out\"" "$H/bootstrap.sh"'

# play_export: the build is started with the profiling arguments, the caller's last.
mkdir -p "$PROJECTS_DIR/game-arena/build/linux"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/ran"\n' "$T" > "$PROJECTS_DIR/game-arena/build/linux/game-arena.x86_64"
chmod +x "$PROJECTS_DIR/game-arena/build/linux/game-arena.x86_64"
(play_export arena +bot_quota 16 --map dm_atrium) >"$T/playout" 2>&1
check 'play: the build ran with the defaults, then the caller'"'"'s' '[ "$(tr "\n" " " < "$T/ran")" = "-- --offline +bot_quota 8 +profiler_overlay 1 +profiler_record_seconds 60 +bot_quota 16 --map dm_atrium " ]'
check 'play: says where the reports land' 'grep -q "app_userdata/game-arena/profiles" "$T/playout"'
(play_export nothing) >/dev/null 2>&1
check 'play: an unknown game exits 2' "[ $? = 2 ]"
(list_games() { :; }; find_godot() { return 1; }; export_game arena) >/dev/null 2>"$T/err"
check 'export: no Godot is refused' "[ $? = 3 ] && grep -q 'Godot not found' \"\$T/err\""

echo "test_export (sh): $pass passed, $fail failed"
[ "$fail" = 0 ]
