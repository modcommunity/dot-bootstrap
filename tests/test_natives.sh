#!/usr/bin/env bash
# fetch_natives: a game's "# bootstrap-natives: <repo> <tag>" line fetches that release's
# platform zip (checksum checked) into the addon repository, once; a local build is kept.
# A third field ("dot-net v1 native/bin") moves the library directory and the stamp.
# Also checks bootstrap.ps1 has the same step. Run: tests/test_natives.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok_() { if [ "$2" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
for f in gi_path natives_for native_platform native_built_here fetch_natives; do eval "$(sed -n "/^$f() {/,/^}/p" "$H/bootstrap.sh")"; done
say() { :; }; ok() { :; }; warn() { WARNED="$2"; }; err() { ERRED="$2"; fail_=1; }
on_disk() { echo "$1"; }   # no renamed repositories here
DIM=; OFF=; PLAN_FROM=
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PROJECTS_DIR="$T/p"; mkdir -p "$PROJECTS_DIR/game-x" "$PROJECTS_DIR/dot-sim/addons/dot_sim"
printf '# a comment\n/addons/dot_core\n# bootstrap-natives: dot-sim v9.9.9\n# bootstrap-optional\n/addons/dot_sim\n/addons/dot_bot\n' > "$PROJECTS_DIR/game-x/.gitignore"
[ "$(natives_for game-x)" = "$(printf 'dot-sim\tv9.9.9\tdot_sim\tbin')" ]; ok_ "natives_for reads the pin through a bootstrap-optional line" $?
plat="$(native_platform)"; ok_ "native_platform knows this machine" $?
# A fake release: the zip unpacks at the repository root, like ci/package.sh's.
R="$T/rel/dot-sim/releases/download/v9.9.9"; mkdir -p "$R" "$T/z/addons/dot_sim/bin/$plat"
echo lib > "$T/z/addons/dot_sim/bin/$plat/libdot_sim.so"; echo ext > "$T/z/addons/dot_sim/dot_sim.gdextension"
(cd "$T/z" && python3 -m zipfile -c "$R/dot_sim-9.9.9-$plat.zip" addons)
(cd "$R" && sha256sum "dot_sim-9.9.9-$plat.zip" > SHA256SUMS.natives)
export DOT_NATIVES_BASE="file://$T/rel"
WARNED=; ERRED=; fetch_natives game-x
[ -f "$PROJECTS_DIR/dot-sim/addons/dot_sim/bin/$plat/libdot_sim.so" ] && [ -f "$PROJECTS_DIR/dot-sim/addons/dot_sim/dot_sim.gdextension" ]; ok_ "installs the library and .gdextension" $?
[ "$(cat "$PROJECTS_DIR/dot-sim/addons/dot_sim/bin/.natives")" = "v9.9.9 $plat" ]; ok_ "writes the stamp" $?
rm "$R/dot_sim-9.9.9-$plat.zip"; fetch_natives game-x; [ -z "$ERRED$WARNED" ]; ok_ "a matching stamp skips the download" $?
rm "$PROJECTS_DIR/dot-sim/addons/dot_sim/bin/.natives"; WARNED=; fetch_natives game-x; [ -z "$WARNED$ERRED" ]; ok_ "a local build (no stamp) is kept" $?
rm -rf "$PROJECTS_DIR/dot-sim/addons/dot_sim/bin"; echo bad > "$R/dot_sim-9.9.9-$plat.zip"; ERRED=; fetch_natives game-x
[ -n "$ERRED" ] && [ ! -e "$PROJECTS_DIR/dot-sim/addons/dot_sim/bin/$plat" ]; ok_ "a checksum mismatch installs nothing" $?
WARNED=; DOT_NATIVES_BASE="file://$T/none" fetch_natives game-x; [ -n "$WARNED" ]; ok_ "no release: a warning, not an error" $?
WARNED=; ERRED=; DOT_NATIVES=none fetch_natives game-x; [ -z "$WARNED$ERRED" ]; ok_ "DOT_NATIVES=none skips" $?
# dot-net: a flat, Godot-named library directory given as the pin's third field.
mkdir -p "$PROJECTS_DIR/game-y" "$PROJECTS_DIR/dot-net/addons/dot_net/native"
printf '# bootstrap-natives: dot-net v1.2.3 native/bin/\n/addons/dot_net\n' > "$PROJECTS_DIR/game-y/.gitignore"
[ "$(natives_for game-y)" = "$(printf 'dot-net\tv1.2.3\tdot_net\tnative/bin')" ]; ok_ "natives_for reads the library directory" $?
os="${plat%-*}"; arch="${plat#*-}"; NB="$PROJECTS_DIR/dot-net/addons/dot_net/native/bin"
mkdir -p "$T/b"; echo x > "$T/b/libn.$os.template_release.$arch.so"
native_built_here "$T/b" "$plat"; ok_ "a Godot-named library for this platform counts as built here" $?
rm "$T/b"/*; echo x > "$T/b/libn.windows.template_release.$arch.dll"; echo x > "$T/b/libn.$os.template_release.other.so"
! native_built_here "$T/b" "$plat"; ok_ "another platform's library does not" $?
echo x > "$T/b/libn.macos.template_debug.universal.dylib"; native_built_here "$T/b" macos-arm64; ok_ "a universal library serves every arch" $?
R2="$T/rel/dot-net/releases/download/v1.2.3"; mkdir -p "$R2" "$T/z2/addons/dot_net/native/bin"
echo lib > "$T/z2/addons/dot_net/native/bin/libdot_net_native.$os.template_release.$arch.so"
(cd "$T/z2" && python3 -m zipfile -c "$R2/dot_net_native-1.2.3-$plat.zip" addons)
(cd "$R2" && sha256sum "dot_net_native-1.2.3-$plat.zip" > SHA256SUMS.natives)
WARNED=; ERRED=; fetch_natives game-y
[ -f "$NB/libdot_net_native.$os.template_release.$arch.so" ] && [ "$(cat "$NB/.natives")" = "v1.2.3 $plat" ] && [ -z "$WARNED$ERRED" ]; ok_ "installs into the library directory and stamps it there" $?
rm -rf "$NB"; mkdir -p "$NB"; echo committed > "$NB/libdot_net_native.$os.template_debug.$arch.so"
WARNED=; ERRED=; fetch_natives game-y
[ ! -f "$NB/.natives" ] && [ "$(cat "$NB/libdot_net_native.$os.template_debug.$arch.so")" = committed ]; ok_ "a committed library for this platform is kept" $?
grep -q 'function Fetch-Natives' "$H/bootstrap.ps1"; ok_ "bootstrap.ps1 has Fetch-Natives" $?
grep -q 'LibDir' "$H/bootstrap.ps1" && grep -q 'function Test-NativeBuiltHere' "$H/bootstrap.ps1"; ok_ "bootstrap.ps1 reads the library directory too" $?
[ "$(grep -c 'fetch_natives "\$p"' "$H/bootstrap.sh")" = 2 ]; ok_ "sync and --links both fetch natives" $?
echo "test_natives: $pass passed, $fail failed"; [ "$fail" = 0 ]
