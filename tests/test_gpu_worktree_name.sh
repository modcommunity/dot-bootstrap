#!/usr/bin/env bash
# gpu.sh proj_name/proj_src/project_dir: worktree names and absolute paths resolve without a per-call GODOT_ROOT.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/tools/gpu.sh
t=$(mktemp -d); mkdir -p "$t/root/game-a" "$t/wt/game-a-task" "$t/wt/nogodot"
: > "$t/root/game-a/project.godot"; : > "$t/wt/game-a-task/project.godot"
fail=0
chk() { # want, label, got
	if [[ $1 == "$3" ]]; then echo "ok   $2"; else echo "FAIL $2: want '$1' got '$3'"; fail=$((fail+1)); fi
}
run() { ROOT=$t/root WT_ROOT=$t/wt bash -c '
	die() { echo "die: $*"; exit 1; }
	eval "$(sed -n "/^proj_name() {/,/^}/p;/^proj_src() {/,/^}/p;/^project_dir() {/,/^}/p" "$0")"
	"$@"' "$src" "$@" 2>&1; }
chk "$t/root/game-a" "root name" "$(run proj_src game-a)"
chk "$t/wt/game-a-task" "worktree name" "$(run proj_src game-a-task)"
chk "$t/wt/game-a-task" "absolute worktree path" "$(run proj_src "$t/wt/game-a-task")"
chk "$t/root/game-a" "absolute root path" "$(run proj_src "$t/root/game-a")"
chk "game-a-task" "name of absolute path" "$(run proj_name "$t/wt/game-a-task/")"
chk "" "project_dir worktree ok" "$(run project_dir game-a-task)"
chk "die: $t/root/nogodot is not a Godot project" "project_dir rejects non-project" "$(run project_dir nogodot)"
rm -rf "$t"; exit $((fail>0))
