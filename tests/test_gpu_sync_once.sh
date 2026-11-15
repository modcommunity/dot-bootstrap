#!/usr/bin/env bash
# gpu.sh sync_ws (nightly heavy-queue-diag-1): a tree goes to a box once and every workspace of it is filled there from
# that copy, never from a stale or half-uploaded one. The box is a fake: a directory used as its $HOME, reached through a
# fake ssh that runs the command there, and an rsync stub that maps "h:<path>" onto it and counts uploads.
# Real code only: tree_hash, WS_FROM_SRC and sync_ws are cut out of tools/gpu.sh.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=${GPU_SRC:-$here/tools/gpu.sh}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

fns=$(sed -n '/^tree_hash() {/,/^}/p;/^read -r -d .. WS_FROM_SRC/,/^EOF$/p;/^box_lock() {/,/^}/p;/^box_unlock() {/,/^}/p;/^sync_tree() {/,/^}/p;/^sync_ws() {/p;/^sync_dir_once() {/,/^}/p;/^loop_links() {/,/^}/p;/^unresolved_links() {/,/^}/p;/^unresolved_except_loops() {/,/^}/p' "$src")
[[ $fns == *"tree_hash() {"* && $fns == *WS_FROM_SRC* && $fns == *"sync_ws() {"* && $fns == *"box_lock() {"* && $fns == *"sync_tree() {"* ]] || { echo "FAIL could not cut the sync code out of $src"; exit 1; }

box=$root/box
mkdir -p "$box/gpu" "$root/bin"
# ssh stand-in: runs its one command string in the fake box's home.
cat > "$root/bin/fakessh" <<EOF
#!/usr/bin/env bash
cd "$box" && HOME="$box" exec bash -c "\$*"
EOF
chmod +x "$root/bin/fakessh"

# The project: plain files, a sibling link the job excludes (/addons/sib), and a self-looping link (/maps/maps).
p=$root/proj
mkdir -p "$p/sub" "$p/maps" "$p/.godot" "$p/screenshots" "$root/sibrepo"
echo one > "$p/a.txt"; echo two > "$p/sub/b.txt"; echo cache > "$p/.godot/c"; echo shot > "$p/screenshots/s.png"
echo sib > "$root/sibrepo/s.gd"; mkdir -p "$p/addons"; ln -s "$root/sibrepo" "$p/addons/sib"
ln -s "$p/maps" "$p/maps/maps"
EXARGS=(--exclude /addons/sib --exclude /maps/maps)

# run_sync <wsid> [env...]: one job's sync_ws in its own bash, as offer_on calls it (under set -eE).
run_sync() {
	local ws=$1; shift
	env "$@" ROOTT="$root" BOX_HOME="$box" PROJ_DIR="$p" GPU_SYNC_LOCK_DIR="$root/locks" bash -c 'set -eE
project=proj BOX=fake HOST=h RSH=true
die() { echo "gpu.sh: $*" >&2; exit 2; }
SSH=("$ROOTT/bin/fakessh"); SSHQ=(timeout -k 5 25 "$ROOTT/bin/fakessh")
# rsync stub: h:<path> is <box>/<path>; -e and its value dropped; every upload (local -> h:) counted, with an optional
# delay (SLOW), a failure (FAILN: the first N uploads fail) or an edit of the tree during the upload (EDIT_ONCE).
rsync() {
	local a=() x skip=0 up=0
	for x in "$@"; do
		if (( skip )); then skip=0; continue; fi
		[[ $x == -e ]] && { skip=1; continue; }
		[[ $x == h:* ]] && { x=$BOX_HOME/${x#h:}; up=1; }
		a+=("$x")
	done
	if (( up )); then
		echo up >> "$ROOTT/uploads"
		sleep "${SLOW:-0}"
		if [[ -n ${FAILN:-} ]] && (( $(wc -l < "$ROOTT/uploads") <= FAILN )); then return 12; fi
		if [[ -n ${EDIT_ONCE:-} && ! -e $ROOTT/edited ]]; then : > "$ROOTT/edited"; command rsync "${a[@]}"; echo edited-during > "$PROJ_DIR/a.txt"; return; fi
	fi
	command rsync "${a[@]}"
}
'"$fns"'
case "${SYNC_FN:-}" in sync_tree) sync_tree "$PROJ_DIR" proj "$@" ;; sync_dir_once) REMOTE_ROOT=gpu/godot; sync_dir_once "$PROJ_DIR" proj die ;; *) sync_ws "$@" ;; esac' _ "$ws" "${EXARGS[@]}"
}
uploads() { cat "$root/uploads" 2>/dev/null | wc -l; }
same() { # same <wsid>: the workspace holds exactly the tree (less .godot/screenshots/excluded links)
	diff -r -x .godot -x screenshots -x sib -x maps "$p" "$box/gpu/ws/$1/proj" >/dev/null 2>&1 &&
		[[ $(cat "$box/gpu/ws/$1/proj/maps/../a.txt" 2>/dev/null) == "$(cat "$p/a.txt")" ]] &&
		[[ ! -e $box/gpu/ws/$1/proj/maps/maps && ! -e $box/gpu/ws/$1/proj/.godot/c && ! -e $box/gpu/ws/$1/proj/addons/sib ]]
}

# 1. first job uploads once; the workspace equals the tree
out=$(run_sync proj 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 1 ]] && same proj && ok "first job: one upload, workspace is the tree" || bad "first job: rc=$rc uploads=$(uploads) out=$out"
# 2. a second workspace of the same tree: no upload, filled on the box
mkdir -p "$box/gpu/ws/proj~2/proj/.godot"; echo keep > "$box/gpu/ws/proj~2/proj/.godot/imported"
out=$(run_sync 'proj~2' 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 1 && $out == *"no upload"* ]] && same 'proj~2' && ok "same tree: no upload, second workspace filled on the box" || bad "same tree: rc=$rc uploads=$(uploads) out=$out"
[[ $(cat "$box/gpu/ws/proj~2/proj/.godot/imported" 2>/dev/null) == keep ]] && ok "workspace .godot kept" || bad "workspace .godot lost"
# 3. an edit (new file, changed file, removed file) uploads again and reaches the workspace; deletions too
echo three-longer > "$p/a.txt"; echo new > "$p/sub/n.txt"; rm "$p/sub/b.txt"
out=$(run_sync 'proj~2' 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 2 ]] && same 'proj~2' && ok "edited tree: uploaded again, workspace updated (incl. deletion)" || bad "edited tree: rc=$rc uploads=$(uploads) out=$out"
# 3b. a same-size edit (only the mtime moves) is seen too
echo three-LONGER > "$p/a.txt"; touch -d '+1 sec' "$p/a.txt"
out=$(run_sync proj 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 3 ]] && same proj && ok "same-size edit: uploaded again" || bad "same-size edit: rc=$rc uploads=$(uploads) out=$out"
# 3c. a mode change (chmod +x) is seen too
chmod +x "$p/sub/n.txt"
out=$(run_sync proj 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 4 && -x $box/gpu/ws/proj/proj/sub/n.txt ]] && ok "mode change: uploaded again" || bad "mode change: rc=$rc uploads=$(uploads) out=$out"
# 4. a failed upload fails the job loudly, leaves no stamp, and the next job uploads again
echo four > "$p/a.txt"; rm -f "$root/uploads"
out=$(run_sync 'proj~3' FAILN=1 2>&1); rc=$?
[[ $rc != 0 && $out == *"failed"* && ! -e $box/gpu/ws/proj~src/.tree-hash ]] && ok "failed upload: job fails, no stamp left" || bad "failed upload: rc=$rc out=$out stamp=$(cat "$box/gpu/ws/proj~src/.tree-hash" 2>/dev/null)"
out=$(run_sync 'proj~3' 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 2 ]] && same 'proj~3' && ok "after a failed upload: next job uploads and runs" || bad "retry after failure: rc=$rc uploads=$(uploads) out=$out"
# 5. an edit during the upload: uploaded again, the workspace has the edit, the stamp is the final tree
rm -f "$root/uploads"; echo five > "$p/a.txt"
out=$(run_sync proj EDIT_ONCE=1 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 2 && $out == *"changed during"* && $(cat "$box/gpu/ws/proj/proj/a.txt") == edited-during ]] && same proj &&
	ok "edit during upload: uploaded again, workspace has the edit" || bad "edit during upload: rc=$rc uploads=$(uploads) out=$out"
# 6. four jobs of a fresh tree at once: one upload, the others wait for it; every workspace is right
echo six > "$p/a.txt"; rm -f "$root/uploads"
for w in proj 'proj~2' 'proj~3' 'proj~4'; do run_sync "$w" SLOW=1 > "$root/par.$w" 2>&1 & done
wait
n_ok=0; for w in proj 'proj~2' 'proj~3' 'proj~4'; do same "$w" && n_ok=$((n_ok + 1)); done
[[ $(uploads) == 1 && $n_ok == 4 ]] && ok "4 concurrent jobs: 1 upload, 4 correct workspaces" || bad "concurrent: uploads=$(uploads) correct=$n_ok $(cat "$root"/par.*)"
# 7. the box side refuses a copy whose stamp is not the tree asked for
out=$(cd "$box" && HOME=$box bash -c "$(sed -n '/^read -r -d .. WS_FROM_SRC/,/^EOF$/p' "$src" | sed '1d;$d')" _ 'proj~src' proj 'ws/proj~5/proj' deadbeef 2>&1); rc=$?
[[ $rc == 5 && ! -e $box/gpu/ws/proj~5/proj/a.txt ]] && ok "box: stale stamp refused, nothing copied" || bad "box stale stamp: rc=$rc out=$out"
# 8. a stamp removed on the box (janitor pruned the ~src copy): uploads again
rm -rf "$box/gpu/ws/proj~src"; rm -f "$root/uploads"
out=$(run_sync 'proj~2' 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 1 ]] && same 'proj~2' && ok "pruned ~src: uploaded again" || bad "pruned ~src: rc=$rc uploads=$(uploads) out=$out"
# 9. GPU_SYNC_ONCE=0: the old direct upload into the workspace, no ~src
rm -rf "$box/gpu/ws"; mkdir -p "$box/gpu/ws/proj"; rm -f "$root/uploads"; echo nine > "$p/a.txt"  # the box script makes ws/<wsid>
out=$(run_sync proj GPU_SYNC_ONCE=0 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 1 && ! -e $box/gpu/ws/proj~src ]] && same proj && ok "GPU_SYNC_ONCE=0: direct upload" || bad "GPU_SYNC_ONCE=0: rc=$rc out=$out"

# 10. sync_tree for the other two copy paths (sync_project -> godot/<name>, shot_on -> shot/<name>): one upload serves
# all of them, kept .godot survives, loop-link exclusions hold
rm -rf "$box/gpu"; mkdir -p "$box/gpu"; rm -f "$root/uploads"; echo ten > "$p/a.txt"
mkdir -p "$box/gpu/godot/proj/.godot" "$box/gpu/shot/proj/.godot"; echo imp > "$box/gpu/godot/proj/.godot/i"; echo imp > "$box/gpu/shot/proj/.godot/i"
out=$(run_sync 'godot/proj' SYNC_FN=sync_tree 2>&1); rc=$?
out2=$(run_sync 'shot/proj' SYNC_FN=sync_tree 2>&1); rc2=$?
dsame() { local d=$1; shift; diff -r "$@" -x .godot -x screenshots -x sib -x maps "$p" "$box/gpu/$d" >/dev/null 2>&1 && [[ ! -e $box/gpu/$d/maps/maps && ! -e $box/gpu/$d/addons/sib ]]; }
[[ $rc == 0 && $rc2 == 0 && $(uploads) == 1 ]] && dsame godot/proj && dsame shot/proj && [[ $(cat "$box/gpu/godot/proj/.godot/i") == imp && $(cat "$box/gpu/shot/proj/.godot/i") == imp ]] &&
	ok "sync_project/shot paths: one upload for both, .godot kept, exclusions held" || bad "project+shot: rc=$rc/$rc2 uploads=$(uploads) $out $out2"

# 11. jobs from different hosts (separate host-local lock dirs): the box lock still makes them share one upload
rm -rf "$box/gpu"; mkdir -p "$box/gpu"; rm -f "$root/uploads"; echo eleven > "$p/a.txt"
for w in proj 'proj~2' 'proj~3'; do run_sync "$w" SLOW=1 GPU_SYNC_LOCK_DIR="$root/locks.$w" > "$root/hp.$w" 2>&1 & done
wait
n_ok=0; for w in proj 'proj~2' 'proj~3'; do same "$w" && n_ok=$((n_ok + 1)); done
[[ $(uploads) == 1 && $n_ok == 3 ]] && ok "3 jobs from 3 hosts: 1 upload, 3 correct workspaces (box lock)" || bad "multi-host: uploads=$(uploads) correct=$n_ok $(cat "$root"/hp.*)"

# 12. a lock held on the box by something else: the job waits at most GPU_SYNC_LOCK_WAIT_S, then fails loudly, uploading nothing
rm -rf "$box/gpu"; mkdir -p "$box/gpu/.sync.d"; rm -f "$root/uploads"; echo twelve > "$p/a.txt"
( cd "$box" && flock -o gpu/.sync.d/proj.lk sleep 6 ) &
sleep 0.5
out=$(run_sync proj GPU_SYNC_LOCK_WAIT_S=2 2>&1); rc=$?
[[ $rc != 0 && $out == *"could not take the copy lock"* && $(uploads) == 0 ]] && ok "box lock held elsewhere: wait capped, fails loudly, no upload" || bad "box lock timeout: rc=$rc uploads=$(uploads) out=$out"
wait
out=$(run_sync proj 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 1 ]] && same proj && ok "box lock free again: job runs" || bad "after box lock: rc=$rc uploads=$(uploads) out=$out"

# 13. a dead holder (killed job: its ssh session gone) frees the box lock at once; a hung one lets go after GPU_SYNC_LOCK_STALE_S
rm -rf "$box/gpu"; mkdir -p "$box/gpu"; rm -f "$root/uploads"; echo thirteen > "$p/a.txt"
t0=$SECONDS
out=$(run_sync proj SLOW=3 2>&1 & sleep 1; wait) ; # a normal run ends and releases
out=$(run_sync 'proj~2' 2>&1); rc=$?
[[ $rc == 0 && $(( SECONDS - t0 )) -lt 15 && -z $(pgrep -f 'gpu/.sync.d/proj.lk' 2>/dev/null) ]] && ok "box lock released when the job ends (no leftover session)" || bad "box lock release: rc=$rc out=$out"
rm -rf "$box/gpu"; mkdir -p "$box/gpu/.sync.d"; echo fourteen > "$p/a.txt"
# a session that holds the lock and never closes: the holder's own stale timeout (here 3 s) frees it
( cd "$box" && exec flock -o gpu/.sync.d/proj.lk timeout 3 sleep 100 ) &
sleep 0.5; t0=$SECONDS
out=$(run_sync proj GPU_SYNC_LOCK_WAIT_S=20 2>&1); rc=$?
[[ $rc == 0 && $(( SECONDS - t0 )) -ge 2 ]] && same proj && ok "stale holder lets go on its timeout; job then runs" || bad "stale holder: rc=$rc t=$((SECONDS - t0)) out=$out"
wait


# 15. publish_cmd's sibling copy (sync_dir_once, godot/<name>): one upload for repeated publishes, a loop link left out with a warning, a dangling link a loud failure,
# GPU_SYNC_ONCE=0 the direct upload
# publish excludes only the loop link (the sibling link is followed, as before), so the check differs from dsame
psame() { diff -r -x .godot -x screenshots -x maps "$p" "$box/gpu/godot/proj" >/dev/null 2>&1 && [[ ! -e $box/gpu/godot/proj/maps/maps && -e $box/gpu/godot/proj/addons/sib/s.gd ]]; }
rm -rf "$box/gpu"; mkdir -p "$box/gpu"; rm -f "$root/uploads"; echo fifteen > "$p/a.txt"
mkdir -p "$p/__pycache__"; echo pyc > "$p/__pycache__/x.pyc"
out=$(run_sync x SYNC_FN=sync_dir_once 2>&1); rc=$?
out2=$(run_sync x SYNC_FN=sync_dir_once 2>&1); rc2=$?
[[ $rc == 0 && $rc2 == 0 && $(uploads) == 1 && $out == *WARNING* && $out2 == *"no upload"* ]] && psame && [[ -e $box/gpu/godot/proj/__pycache__/x.pyc ]] &&
	ok "publish copy: one upload for two publishes, loop link left out with a warning" || bad "publish copy: rc=$rc/$rc2 uploads=$(uploads) $out $out2"
ln -s /nonexistent-gsync "$p/dangling"
out=$(run_sync x SYNC_FN=sync_dir_once 2>&1); rc=$?
[[ $rc != 0 && $out == *"dangle or loop"* ]] && ok "publish copy: dangling link fails loudly" || bad "dangling: rc=$rc $out"
rm "$p/dangling"; rm -rf "$box/gpu"; mkdir -p "$box/gpu"; rm -f "$root/uploads"
out=$(run_sync x SYNC_FN=sync_dir_once GPU_SYNC_ONCE=0 2>&1); rc=$?
[[ $rc == 0 && $(uploads) == 1 && ! -e $box/gpu/ws/proj~src ]] && psame && ok "publish copy, GPU_SYNC_ONCE=0: direct upload" || bad "publish ONCE=0: rc=$rc $out"

exit $fail
