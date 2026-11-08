#!/usr/bin/env bash
# fetch_natives: a game's "# bootstrap-natives: <repo> <tag>" line fetches that release's
# platform zip (checksum checked) into the addon repository, once; a local build is kept.
# Also checks bootstrap.ps1 has the same step. Run: tests/test_natives.sh
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok_() { if [ "$2" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
for f in gi_path natives_for native_platform fetch_natives; do eval "$(sed -n "/^$f() {/,/^}/p" "$H/bootstrap.sh")"; done
say() { :; }; ok() { :; }; warn() { WARNED="$2"; }; err() { ERRED="$2"; fail_=1; }
DIM=; OFF=; PLAN_FROM=
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PROJECTS_DIR="$T/p"; mkdir -p "$PROJECTS_DIR/game-x" "$PROJECTS_DIR/dot-sim/addons/dot_sim"
printf '# a comment\n/addons/dot_core\n# bootstrap-natives: dot-sim v9.9.9\n# bootstrap-optional\n/addons/dot_sim\n/addons/dot_bot\n' > "$PROJECTS_DIR/game-x/.gitignore"
[ "$(natives_for game-x)" = "$(printf 'dot-sim\tv9.9.9\tdot_sim')" ]; ok_ "natives_for reads the pin through a bootstrap-optional line" $?
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
grep -q 'function Fetch-Natives' "$H/bootstrap.ps1"; ok_ "bootstrap.ps1 has Fetch-Natives" $?
[ "$(grep -c 'fetch_natives "\$p"' "$H/bootstrap.sh")" = 2 ]; ok_ "sync and --links both fetch natives" $?
echo "test_natives: $pass passed, $fail failed"; [ "$fail" = 0 ]
