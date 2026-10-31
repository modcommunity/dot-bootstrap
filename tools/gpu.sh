#!/usr/bin/env bash
#
# gpu.sh — run Godot on a real GPU: Christian's always-on laptop "staging"
# (GTX 1660 Ti, Linux Mint) or desktop "staging02" (RTX 2070, Debian), reached
# from dev02 over SSH. GPU_BOX=staging02 picks the desktop; see set_box below.
#
# dev02 has no GPU, so everything it renders goes through llvmpipe: a lightmap
# bake there takes forever and a frame time there says nothing about a player's
# machine. The 1660 Ti is roughly a typical player's card, so this is where bakes,
# real-GPU screenshots and frame timings run.
#
#   ./gpu.sh status                          GPU, load and who holds the lock, on each box
#   ./gpu.sh sync <project>                  copy godot/<project> to the laptop
#   ./gpu.sh run  <project> [godot args...]  sync, then run Godot there on the 1660 Ti
#   ./gpu.sh exec <command...>               any shell command there, under the lock
#   ./gpu.sh pull <project> <path> [dir]     copy a file or folder back into dir (default: its folder here)
#   ./gpu.sh browser-shot <url> <out.png>    load a page in the laptop's Chrome (WebGL2 on the 1660 Ti), save a frame
#   ./gpu.sh cdp [port]                      Chrome there with its DevTools port tunnelled to localhost:<port>
#                                            (default 9222); Playwright here: chromium.connectOverCDP("http://127.0.0.1:9222")
#                                            GPU_CDP_SERVE=8000 also tunnels the laptop's 127.0.0.1:8000 back to this machine's :8000,
#                                            so a page served here (python3 -m http.server 8000) loads in that Chrome
#   ./gpu.sh shot [--stage DIR]... [--pull DIR]... <project> <tools/x.sh | game.sh shot | xvfb-run ... godot ...>
#                                            run a screenshot tool on whichever box is free, Forward+ on Vulkan on the
#                                            NVIDIA card (godot/xvfb-run shims add the flags; the card is found by name),
#                                            and copy every new *.png back to the same path. --stage/--pull copy extra
#                                            directories over/back (same absolute path). No box: one WARN line, runs here.
#                                            GPU_OFFLOAD=0 stays local. heavy calls `route` for tools/screenshot*.sh, tools/camera_check*.sh,
#                                            tools/shot*.sh and game.sh shot before it takes a local slot.
#   ./gpu.sh blender [--stage DIR] [--pull DIR] -- <blender args>   Blender 4.3 on staging02's RTX 2070 (shared lock)
#   ./gpu.sh py [--stage DIR]... [--pull DIR]... -- python3 <script> [args]
#                                            a memory-hungry Python job (the BSP converters, route planners, nav
#                                            emulation) on staging02's 31 GB, the laptop when the desktop is off,
#                                            and here under `heavy` when neither answers. The current git repo is
#                                            staged and pulled back by default; see py_cmd.
#   ./gpu.sh offer ./game.sh [opts] test [suites...]
#   ./gpu.sh offer godot --headless --path . res://examples/x.tscn
#                                            heavy's offload hook: run a waiting suite or plain headless run on a box's
#                                            CPU (the one with most free slots), or exit 75. Sibling repositories the
#                                            project reads by ../name are staged once into ~/gpu/sib (see stage_sibling)
#   ./gpu.sh capacity                        free suite slots, free GB and the running jobs on each box (heavy --status)
#   ./gpu.sh route <command...>              heavy's hook before it queues anything: shots go to a GPU first; suites too
#                                            when HEAVY_PREFER_OFFLOAD=1 or /var/tmp/heavy/prefer-offload is fresh (the
#                                            nightly runner sets both); `timeout N` / `env K=V` wrappers are looked through
#
# Examples:
#   ./gpu.sh run game-zombie-zone --import
#   ./gpu.sh run game-zombie-zone --script res://tools/shot.gd -- --map=mall
#   ./gpu.sh pull game-zombie-zone screenshots
#
# Three things this does that a bare `ssh laptop godot ...` gets wrong:
#
#  1. It never touches Christian's desktop. His session is display :0 on that
#     machine, with an external monitor showing dashboards 24/7. Every run gets
#     its own Xvfb display (xvfb-run -a); NVIDIA's Vulkan driver renders on the
#     GPU and presents into it, so there is no second X server and no VT switch.
#  2. It pins the NVIDIA card. The laptop also has an AMD iGPU, and Vulkan lists
#     llvmpipe too; Godot's default pick is not guaranteed to be the 1660 Ti.
#     Device 0 is the 1660 Ti (checked 2026-10-18); `status` prints the list.
#  3. One job at a time (flock on the laptop). Two bakes at once halve each
#     other's speed and can run out of its 6 GB of video memory, and a frame time
#     measured beside a bake is worthless.
#
# Clearing a stuck lock (a leaked Xvfb holding ~/gpu/.lock or .gate): on the box,
#   ls -l /proc/<pid>/fd | grep gpu/    # which process holds it (lsof ~/gpu/.lock also works)
#   ps -o pid,etime,args -p <pid>       # confirm it is an Xvfb with no job above it, then
#   kill <pid>                          # an admin's call; this script never kills one
# Every `flock FILE cmd` here uses -o so the command (and anything it leaves running) does
# not inherit the lock fd; the lock then ends with the flock process, not with its children.
#
# Both boxes are also suite lanes, for their CPUs rather than their GPUs: their
# threads and memory sit idle while dev02 (6 vCPUs, ~11 GB) queues suites two at a
# time. Each of their cores is slower than dev02's, so a suite goes there only when
# heavy would otherwise make it wait: heavy calls `offer` from its wait loop, and
# exit 75 means "not taken, keep waiting here". Christian allows using either box
# at any time without asking (2026-10-18, 2026-10-19). Suites take ~/gpu/.lock shared
# and GPU jobs take it exclusive, so a bake or frame time never shares the machine
# with a suite; a GPU job first holds ~/gpu/.gate, which stops new suites from
# being offered while it waits, so a stream of suites cannot starve it.
#
# The project goes over with links resolved (--copy-links), because each game's
# addons/ are relative symlinks into sibling repositories that do not exist on
# the laptop. The laptop keeps its own .godot/ import cache between runs, so only
# the first --import is slow. Nothing on the laptop is a repository: commit here,
# after pulling the results back.
#
# The Compatibility renderer (what the browser uses) does NOT reach the GPU from a
# native Godot under Xvfb: OpenGL there is Mesa's software path. The browser does:
# headless Chrome with CHROME_GPU_FLAGS draws WebGL2 through ANGLE on the 1660 Ti,
# with no display at all (checked 2026-10-18). Without those flags it silently
# falls back to SwiftShader, a CPU rasteriser, and every number it gives is wrong;
# a page can check with WEBGL_debug_renderer_info.

set -euo pipefail

KEY="${GPU_KEY:-$HOME/.ssh/gpu-laptop}"
GPU_INDEX="${GPU_INDEX:-0}"
ROOT="${GODOT_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
REMOTE_ROOT="gpu/godot"
# Absolute, because remote_locked quotes every argument and a quoted $HOME stays literal.
REMOTE_HOME="${GPU_REMOTE_HOME:-/home/gamedev}"
# ANGLE over the NVIDIA OpenGL ES driver; --use-angle=vulkan also reaches the card.
CHROME_GPU_FLAGS="${CHROME_GPU_FLAGS:---use-angle=gl-egl --use-gl=angle --ignore-gpu-blocklist --enable-gpu-rasterization}"
CHROME_COMMON="--headless=new --no-first-run --no-default-browser-check --window-size=1280,720"

die() { echo "gpu.sh: $*" >&2; exit 2; }

# Two boxes, picked with GPU_BOX (default the laptop). Both have user gamedev, the same
# ~/gpu layout and the same key. Each may be used at any time without asking.
#   staging    laptop: GTX 1660 Ti, Ryzen 7 4800H (16 threads), 15 GB, ~40 MB/s WiFi. Always on;
#              its own desktop session is the 24/7 stats screen, so it is never "in use".
#   staging02  desktop: RTX 2070, i7-8700K (12 threads), 31 GB, ~10 MB/s WiFi with 800 ms
#              spikes. Somebody uses it at weekends, so it may be off, or have a person at
#              it (a local, active login), and then it takes no suites (DESKTOP_GUARD).
# Suite slots: the free memory and threads each can spare beside its own desktop.
set_box() {
	BOX=$1
	case $BOX in
		staging)   HOST=gamedev@staging.deacon.internal;   BOX_DESC="the laptop (staging)"
		           SUITE_SLOTS=${GPU_SUITE_SLOTS:-3} SUITE_MAX_GB=${GPU_SUITE_MAX_GB:-6} DESKTOP_GUARD=0 ;;
		staging02) HOST=gamedev@staging02.deacon.internal; BOX_DESC="the desktop (staging02)"
		           SUITE_SLOTS=${GPU_SUITE_SLOTS:-5} SUITE_MAX_GB=${GPU_SUITE_MAX_GB:-7} DESKTOP_GUARD=1 ;;
		*) die "unknown GPU_BOX '$BOX' (staging or staging02)" ;;
	esac
	HOST=${GPU_HOST:-$HOST}
	SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "$HOST")
}
set_box "${GPU_BOX:-staging}"

project_dir() {
	[[ -n "${1:-}" ]] || die "which project? (a directory under $ROOT)"
	[[ -f "$ROOT/$1/project.godot" ]] || die "$ROOT/$1 is not a Godot project"
}

sync_project() {
	project_dir "$1"
	"${SSH[@]}" "mkdir -p ~/$REMOTE_ROOT/$1"
	rsync -az --delete --copy-links \
		--exclude '.godot/' --exclude '.git/' --exclude 'screenshots/' \
		-e "ssh -i $KEY -o BatchMode=yes" \
		"$ROOT/$1/" "$HOST:$REMOTE_ROOT/$1/"
}

# Runs a command on the laptop under the one-job lock. printf %q keeps arguments
# with spaces or quotes intact across the ssh hop.
remote_locked() {
	local cmd
	cmd=$(printf '%q ' "$@")
	"${SSH[@]}" "flock -o ~/gpu/.gate flock -o ~/gpu/.lock bash -lc $(printf '%q' "$cmd")"
}

# The free memory a suite needs to start (slots and ceiling are per box, in set_box).
# Suites peak at 3.5 GB worst case on dev02 (heavy's numbers).
SUITE_MIN_GB="${GPU_SUITE_MIN_GB:-3}"

# A person at the machine: a local, active login that owns a seat (a graphical or console
# session). Our own ssh logins are Remote=yes, and the systemd "manager" session an ssh
# login leaves behind is Remote=no but Class=manager with no seat; neither counts. Without
# the Seat test, any Remote=no user session of ours (su, machinectl, a cron-style scope)
# would lock the desktop out for good. Prints "BUSY ..." and returns 0 when somebody is there.
read -r -d '' GUARD_FN <<'EOF' || true
person_here() {
	local s p
	for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
		p=$(loginctl show-session "$s" -p Remote -p Active -p Class -p Seat -p IdleHint -p IdleSinceHint 2>/dev/null)
		# idle for 2 hours or more (a console left on a stats screen) is nobody at the desk
		if grep -qx IdleHint=yes <<<"$p"; then
			local since; since=$(sed -n 's/^IdleSinceHint=//p' <<<"$p")
			[[ $since =~ ^[0-9]+$ && $since -gt 0 && $(( $(date +%s) - since / 1000000 )) -ge 7200 ]] && continue
		fi
		if grep -qx Remote=no <<<"$p" && grep -qx Active=yes <<<"$p" && grep -qx Class=user <<<"$p" && grep -q '^Seat=.' <<<"$p"; then
			echo "BUSY somebody is using it"; return 0
		fi
	done
	return 1
}
EOF

# Peels `timeout [opts] DUR` and `env K=V...` off the front of a command, the way callers
# write `heavy -- timeout 1400 ./game.sh test`. The 10-19 nightly run queued for over an
# hour because the offer only recognised a bare ./game.sh as the first word. Sets UW_LIMIT
# (seconds, or empty), UW_ENV (K=V words) and UW_REST (the command underneath).
unwrap() {
	UW_LIMIT= UW_ENV=()
	while [[ $# -gt 0 ]]; do
		case $1 in
			timeout)
				shift
				while [[ ${1:-} == -* ]]; do case $1 in -k|-s|--kill-after|--signal) shift 2 ;; *) shift ;; esac; done
				if [[ ${1:-} =~ ^([0-9]+)([smhd]?)$ ]]; then
					case ${BASH_REMATCH[2]} in
						m) UW_LIMIT=$((BASH_REMATCH[1] * 60)) ;; h) UW_LIMIT=$((BASH_REMATCH[1] * 3600)) ;;
						d) UW_LIMIT=$((BASH_REMATCH[1] * 86400)) ;; *) UW_LIMIT=${BASH_REMATCH[1]} ;;
					esac
				fi
				shift ;;
			env) shift; while [[ ${1:-} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do UW_ENV+=("$1"); shift; done ;;
			*) break ;;
		esac
	done
	UW_REST=("$@")
}

# Exit 1 unless the command is one a box can run from a copy of the project:
#   [timeout N] ./game.sh [--no-parse] [--timeout N] test [suite...]        (UW_KIND=game)
#   [timeout N] godot --headless --path . [--quit-after N] res://x.tscn [-- args]   (UW_KIND=godot)
# run from a project's own directory. Anything else may depend on dev02 (dot-server-deploy's
# data, the dev01 tunnels, a --godot binary that only exists here) or write results back into
# the project (--import, --script tools, exports), so it stays in the local queue. On success
# the command under the wrappers is in UW_REST, its limit in UW_LIMIT and its kind in UW_KIND.
offer_eligible() {
	[[ "${GPU_OFFLOAD:-1}" != 0 ]] || return 1
	project="${PWD#"$ROOT"/}"
	[[ "$PWD" == "$ROOT/$project" && "$project" != */* && -f "$PWD/project.godot" ]] || return 1
	unwrap "$@"
	set -- "${UW_REST[@]}"
	[[ ${#UW_ENV[@]} == 0 ]] || return 1
	if [[ "${1:-}" == godot ]]; then
		shift
		local headless=0 path=0 scene=0 tail=0 a
		while [[ $# -gt 0 ]]; do
			a=$1; shift
			if [[ $tail == 1 ]]; then [[ $a =~ ^[A-Za-z0-9_./=:,+-]+$ ]] || return 1; continue; fi
			case $a in
				--headless) headless=1 ;;
				--path) [[ "${1:-}" == . || "${1:-}" == "$PWD" ]] || return 1; path=1; shift ;;
				--path=.|--path="$PWD") path=1 ;;
				--quit-after|--fixed-fps|--max-fps) [[ ${1:-} =~ ^[0-9]+$ ]] || return 1; shift ;;
				--verbose|--disable-render-loop|--no-header) ;;
				--) tail=1 ;;
				res://*.tscn) [[ $scene == 0 && $a =~ ^res://[A-Za-z0-9_./-]+$ && $a != *..* ]] || return 1; scene=1 ;;
				*) return 1 ;;
			esac
		done
		[[ $headless == 1 && $path == 1 && $scene == 1 ]] || return 1
		UW_KIND=godot
		return 0
	fi
	[[ -x "$PWD/game.sh" ]] || return 1
	[[ "${1:-}" == ./game.sh || "${1:-}" == game.sh ]] || return 1
	shift
	local seen_test=0 s
	while [[ $# -gt 0 && $seen_test == 0 ]]; do
		case $1 in
			--no-parse|--timeout=*) shift ;;
			--timeout) [[ $# -ge 2 ]] || return 1; shift 2 ;;
			test) seen_test=1; shift ;;
			*) return 1 ;;
		esac
	done
	[[ $seen_test == 1 ]] || return 1
	for s in "$@"; do [[ $s =~ ^[A-Za-z0-9_]+(\.tscn)?$ ]] || return 1; done
	UW_REST=(./game.sh "${UW_REST[@]:1}")
	UW_KIND=game
}

# The sibling repositories a project reads by a path outside itself (res://../dot-server-deploy/...,
# $ROOT/../dot-ci): its addons/ links resolve inside the copy (--copy-links), but a path that
# climbs out of the project needs the sibling next to it. Found by grepping the project's own
# sources for ../<existing sibling>, plus names in <project>/.gpu-siblings and $GPU_SIBLINGS.
# Only git repositories count (godot/tools and inspirations/ are not). Prints one name per line.
needed_siblings() {
	local p=$1 n
	{
		( cd "$ROOT/$p" && { git ls-files -z -- '*.gd' '*.sh' '*.tscn' '*.yml' '*.cfg' '*.json' '*.py' 2>/dev/null ||
			find . -type f \( -name '*.gd' -o -name '*.sh' -o -name '*.tscn' \) -not -path './.godot/*' -print0; } |
			xargs -0 -r grep -hoE '\.\./[A-Za-z0-9_][A-Za-z0-9_.-]*' 2>/dev/null | sed 's|^\.\./||' | sort -u )
		[[ -f $ROOT/$p/.gpu-siblings ]] && sed 's/#.*//' "$ROOT/$p/.gpu-siblings"
		printf '%s\n' ${GPU_SIBLINGS:-}
	} | while read -r n; do
		[[ -n $n && $n != "$p" && $n != . && $n != .. && -e $ROOT/$n/.git && $n =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] && echo "$n"
	done | sort -u
}

# Stages one sibling into the box's content-addressed store, ~/gpu/sib/<name>/<fingerprint>/,
# and prints "<name>=<fingerprint>". The fingerprint is a hash of the sibling's tracked and
# untracked-unignored files (path, size, mtime), so an unchanged sibling costs one ssh round
# trip and no copy; a changed one is copied with hard links to the previous version for every
# file that did not change. Only source files go (git ls-files -co), never build/ or data/
# output, which is why a 4 GB sibling is 40 MB over. A version is immutable once
# renamed into place, so a job reading it is never disturbed by the next stage.
stage_sibling() {
	local name=$1 src="$ROOT/$1" fp list
	list=$(mktemp)
	if git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
		# A tracked file deleted in the working tree is still listed, and rsync fails the whole stage on it.
		( cd "$src" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done ) >"$list"
	else
		( cd "$src" && find . -type f -not -path './.godot/*' -not -path './.git/*' -printf '%P\0' ) >"$list"
	fi
	fp=$( { cat "$list"; ( cd "$src" && xargs -0 -r stat -L -c '%s %Y' -- <"$list" 2>/dev/null ); } | sha1sum | cut -c1-16 )
	local rs=(-e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10")
	if ! "${SSH[@]}" "[ -f ~/gpu/sib/$name/$fp/.complete ] && touch ~/gpu/sib/$name/$fp/.complete"; then
		"${SSH[@]}" "mkdir -p ~/gpu/sib/$name" || { rm -f "$list"; return 1; }
		local tmp="gpu/sib/$name/.tmp.$fp.$$"
		rsync -a --copy-links --from0 --files-from="$list" "${rs[@]}" \
			--link-dest="\$HOME/gpu/sib/$name/latest/" "$src/" "$HOST:$tmp/" || { rm -f "$list"; return 1; }
		"${SSH[@]}" "cd ~/gpu/sib/$name && touch .tmp.$fp.$$/.complete && { mv -T .tmp.$fp.$$ $fp 2>/dev/null || rm -rf .tmp.$fp.$$; } && ln -sfn $fp latest" || { rm -f "$list"; return 1; }
	fi
	rm -f "$list"
	echo "$name=$fp"
}

# Runs on the laptop, as one ssh session that holds every lock for the whole job: it
# answers OK or BUSY, waits for "go" (sent once the copy is there), runs the suite and
# ends with its exit code. If dev02's side dies first, the read gets EOF and the locks
# go with the shell. The lock fds are closed for the suite itself, so a Godot left
# running cannot hold a slot.
read -r -d '' REMOTE_SUITE <<'EOF' || true
set -u
project=$1 slots=$2 min_gb=$3 max_gb=$4 who=$5 guard=$6 limit=$7 kind=$8; shift 8
cd ~/gpu || exit 3
# A person at the machine gets it to themselves (person_here, from GUARD_FN).
[ "$guard" = 1 ] && person_here && exit 0
mkdir -p suite/.shim ws
flock -n .gate true || { echo "BUSY a GPU job is running or waiting"; exit 0; }
exec 9>>.lock
flock -n -s 9 || { echo "BUSY a GPU job is running"; exit 0; }
slot=
for n in $(seq 1 "$slots"); do
	exec {f}>>"suite.$n.lock"
	if flock -n "$f"; then slot=$n; break; fi
	exec {f}>&-
done
[ -n "$slot" ] || { echo "BUSY all $slots suite slots"; exit 0; }
exec 7>>"suite/$project.lock"
flock -n 7 || { echo "BUSY $project is already running here"; exit 0; }
avail=$(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo)
[ "$avail" -ge "$min_gb" ] || { echo "BUSY only $avail GB free"; exit 0; }
printf '%s\n' "$who" > "suite.$slot.who"
trap ': > ~/gpu/suite.'"$slot"'.who' EXIT
# game.sh's parse pass lists scripts with `git ls-files`, which leaves out untracked
# files. The copy has no .git, so dev02 sends its list and this answers with it;
# without it game.sh would fall back to find and parse untracked scratch scripts too.
cat > suite/.shim/git <<'SHIM'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = ls-files ] && [ "$2" = '*.gd' ] && [ -f "${GPU_LS_FILES:-}" ]; then exec cat "$GPU_LS_FILES"; fi
exec /usr/bin/git "$@"
SHIM
chmod +x suite/.shim/git
echo OK
read -r go mode sibs || exit 0
[ "$go" = go ] || exit 0
list="$HOME/gpu/suite/$project.ls-files"
rm -f "$list"
if [ "$mode" = git ]; then cat > "$list"; else cat >/dev/null; fi
# The project lives at ws/<project>/<project> with its sibling repositories beside it
# (symlinks into the content-addressed store), so res://../<sibling> resolves as on dev02.
ws=$HOME/gpu/ws/$project
find "$ws" -maxdepth 1 -type l -delete 2>/dev/null
for kv in ${sibs//,/ }; do
	[[ $kv == *=* ]] || continue
	n=${kv%%=*} v=${kv#*=}
	[ -d "$HOME/gpu/sib/$n/$v" ] && ln -sfn "$HOME/gpu/sib/$n/$v" "$ws/$n"
done
# Versions nobody asked for in a day go, always keeping the newest three.
for d in "$HOME"/gpu/sib/*/; do
	[ -d "$d" ] || continue
	find "$d" -mindepth 1 -maxdepth 1 -type d -name '[0-9a-f]*' -printf '%T@ %p\n' | sort -rn | tail -n +4 | cut -d' ' -f2- |
		while read -r old; do [ -n "$(find "$old/.complete" -mtime -1 2>/dev/null)" ] || rm -rf "$old"; done
done
cd "$ws/$project" || exit 3
export XDG_RUNTIME_DIR=/run/user/$(id -u) GODOT=$HOME/gpu/bin/godot GPU_LS_FILES=$list
export PATH=$HOME/gpu/suite/.shim:$PATH
# The class cache stays here between runs; a stale one reads as "Identifier not declared".
nice -n 5 timeout 1800 "$GODOT" --headless --path . --import >/dev/null 2>&1 </dev/null 7>&- 9>&- {f}>&-
if [ "$kind" = godot ]; then set -- "$GODOT" "$@"; else set -- ./game.sh "$@"; fi
nice -n 5 timeout "$limit" systemd-run --user --scope --quiet --collect -p MemoryMax="${max_gb}G" -p MemorySwapMax=0 -- \
	"$@" </dev/null 7>&- 9>&- {f}>&-
echo "__GPU_SUITE_RC=$?"
EOF

# What the current box (set_box) can take right now, as one line: "<free> <total> <free GB> <state>".
# state is ok, gpu (an exclusive GPU job holds it), gate (one is waiting), person (the desktop
# guard), or full. Used to send a job to the box with the most room, and by `capacity`/`status`.
box_capacity() {
	"${SSH[@]}" "bash -c $(printf '%q' "$GUARD_FN"$'\n''cd ~/gpu 2>/dev/null || { echo "0 0 0 nodir"; exit 0; }
slots=$1 guard=$2; free=0; state=ok
for n in $(seq 1 "$slots"); do exec {f}>>"suite.$n.lock"; flock -n "$f" && free=$((free+1)); exec {f}>&-; done
avail=$(awk '"'"'/MemAvailable/ {print int($2/1048576)}'"'"' /proc/meminfo)
exec 9>>.lock; flock -n -s 9 || state=gpu
[ $state = ok ] && ! flock -n .gate true && state=gate
[ $state = ok ] && [ "$guard" = 1 ] && person_here && state=person
[ $state = ok ] && [ "$free" = 0 ] && state=full
[ $state = ok ] || free=0
echo "$free $slots $avail $state"') _ $SUITE_SLOTS $DESKTOP_GUARD" 2>/dev/null || echo "0 0 0 down"
}

# One offer to the current box (set_box); runs in a subshell, so `exit` ends just this try.
offer_on() {
	local down=$1; shift
	who="$(whoami)@$(hostname -s) since $(date +%H:%M:%S): $project: $*"
	trap '' PIPE  # a box that vanishes mid-handshake is a 75, not a SIGPIPE death
	coproc LANE { "${SSH[@]}" "bash -c $(printf '%q' "$GUARD_FN"$'\n'"$REMOTE_SUITE") _ $(printf '%q ' \
		"$project" "$SUITE_SLOTS" "$SUITE_MIN_GB" "$SUITE_MAX_GB" "$who" "$DESKTOP_GUARD" "${UW_LIMIT:-5400}" "${UW_KIND:-game}" "${@:2}")"; }
	lane_out=${LANE[0]} lane_in=${LANE[1]} lane_pid=$LANE_PID
	back_to_queue() {
		[[ -n "${1:-}" ]] && echo "gpu.sh: $1; back to the local queue" >&2
		exec {lane_in}>&- 2>/dev/null || true
		kill "$lane_pid" 2>/dev/null || true
		wait "$lane_pid" 2>/dev/null || true
		exit 75
	}
	reply=
	read -r -t 30 -u "$lane_out" reply || true
	if [[ -z $reply ]]; then mkdir -p "$(dirname "$down")"; touch "$down"; else rm -f "$down"; fi
	# GPU_OFFER_VERBOSE=1 says why a box said no (heavy offers every 15 s, so it is quiet by default).
	[[ $reply == OK ]] || back_to_queue "$([[ ${GPU_OFFER_VERBOSE:-0} == 1 ]] && echo "$BOX: ${reply:-no answer}")"
	echo "heavy: $BOX_DESC took this suite: $project: $*" >&2
	local sibs=() n kv
	for n in $(needed_siblings "$project"); do
		kv=$(stage_sibling "$n") || back_to_queue "staging $n on $BOX failed"
		sibs+=("$kv")
	done
	"${SSH[@]}" "mkdir -p ~/gpu/ws/$project/$project" || back_to_queue "cannot make the workspace on $BOX"
	rsync -az --delete --copy-links --exclude '.godot/' --exclude '.git/' --exclude 'screenshots/' \
		-e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10" \
		"$ROOT/$project/" "$HOST:gpu/ws/$project/$project/" || back_to_queue "copying $project to $BOX failed"
	local sibarg; sibarg=$(IFS=,; echo "${sibs[*]}"); : "${sibarg:=-}"
	[[ $sibarg == - ]] && sibarg=
	if [[ ${UW_KIND:-game} == game ]] && list=$(git -C "$ROOT/$project" ls-files '*.gd' 2>/dev/null); then
		{ printf 'go git %s\n%s\n' "${sibarg:-,}" "$list" >&"$lane_in"; } 2>/dev/null || true
	else
		{ printf 'go none %s\n' "${sibarg:-,}" >&"$lane_in"; } 2>/dev/null || true
	fi
	exec {lane_in}>&-
	rc=
	while IFS= read -r line <&"$lane_out"; do
		if [[ $line == __GPU_SUITE_RC=* ]]; then rc=${line#*=}; else printf '%s\n' "$line"; fi
	done
	wait "$lane_pid" 2>/dev/null || true
	# No exit code means the connection went mid-run: run it again here rather than
	# report a result nobody saw.
	[[ -n $rc ]] || { lane_pid=; back_to_queue "lost $BOX mid-run"; }
	if [[ ${UW_KIND:-game} == game ]]; then
		mkdir -p "$ROOT/$project/.godot/test-logs"
		rsync -az -e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10" \
			"$HOST:gpu/ws/$project/$project/.godot/test-logs/" "$ROOT/$project/.godot/test-logs/" ||
			echo "gpu.sh: could not copy the suite logs back from $BOX" >&2
	fi
	exit "$rc"
}

# ---- shot: a screenshot tool on a real GPU --------------------------------------------------
#
# Runs on a box, as one ssh session: `probe` answers OK or BUSY, `run` takes the locks and
# runs the tool. Shots take ~/gpu/.lock SHARED (a suite does too, so a shot is not stuck
# behind a 90-minute suite; a bake or frame timing, which holds it exclusive, still keeps
# them out) and one of two shot slots. The tool sees `godot` and `xvfb-run` through shims
# that add --rendering-method forward_plus --rendering-driver vulkan --gpu-index <the NVIDIA
# card, found by name, not assumed to be 0>; a tool that asks for gl_compatibility
# (RENDERER=gl_compatibility, what the browser shell draws) or runs --headless is passed
# through untouched.
read -r -d '' REMOTE_SHOT <<'EOF' || true
set -u
mode=$1 project=$2 guard=$3 waits=$4 limit=$5; shift 5
cd ~/gpu || exit 3
if [ "$guard" = 1 ] && person_here; then exit 75; fi
flock -n .gate true || { echo "BUSY a GPU job is waiting"; exit 75; }
exec 9>>.lock
flock -s -w "$waits" 9 || { echo "BUSY a GPU job is running"; exit 75; }
slot=
for n in 1 2; do
	exec {f}>>"shot.$n.lock"
	if flock -n "$f"; then slot=$n; break; fi
	exec {f}>&-
done
[ -n "$slot" ] || { echo "BUSY both shot slots"; exit 75; }
if [ "$mode" = probe ]; then
	# A box without xvfb-run cannot give a tool its display: every frame would be missing or
	# black, so it is not offered the job (exit 75 sends it elsewhere or runs it locally).
	command -v xvfb-run >/dev/null && command -v Xvfb >/dev/null || { echo "BUSY no xvfb-run/Xvfb installed (sudo apt install xvfb)"; exit 75; }
	# The sheet tools tile their frames with ffmpeg; without it the run ends with no image.
	command -v ffmpeg >/dev/null || { echo "BUSY no ffmpeg installed (sudo apt install ffmpeg)"; exit 75; }
	echo OK; exit 0
fi
mkdir -p shot shot-shim
exec 8>>"shot/$project.lock"
flock -w "$waits" 8 || { echo "BUSY $project is already being shot here"; exit 75; }
idx=$(vulkaninfo --summary 2>/dev/null | awk '/^GPU[0-9]+:/ {g=substr($1,4)+0} /deviceName.*NVIDIA/ {print g; exit}')
idx=${idx:-0}
cat > shot-shim/godot <<'SHIM'
#!/bin/sh
real=$HOME/gpu/bin/godot
m= d= g= c= o=
for a in "$@"; do
	case $a in
		--headless) exec "$real" "$@" ;;
		--rendering-method|--rendering-method=*) m=1 ;;
		--rendering-driver|--rendering-driver=*) d=1 ;;
		--gpu-index|--gpu-index=*) g=1 ;;
		gl_compatibility) c=1 ;;
		opengl3|opengl3_es|--rendering-driver=opengl3*) o=1 ;;
	esac
done
# An OpenGL driver only pairs with gl_compatibility; a tool that pins one without a method
# must not be given forward_plus, which Godot rejects with it.
if [ -n "$o" ] && [ -z "$m" ]; then exec "$real" --rendering-method gl_compatibility "$@"; fi
[ -n "$c" ] && exec "$real" "$@"
[ -z "$m" ] && set -- --rendering-method forward_plus "$@"
[ -z "$d" ] && set -- --rendering-driver vulkan "$@"
[ -z "$g" ] && set -- --gpu-index "$SHOT_GPU_INDEX" "$@"
exec "$real" "$@"
SHIM
cat > shot-shim/xvfb-run <<'XSHIM'
#!/bin/sh
# Starts its own Xvfb and stops exactly that pid on exit, so a job killed by timeout leaves no
# server holding the lock fds. Skips xvfb-run's option parsing: tools call it as `xvfb-run -a cmd`.
while [ "${1#-}" != "$1" ]; do case $1 in -s|--server-args|-n|--server-num|-f|--auth-file|-e|--error-file) shift 2 ;; *) shift ;; esac; done
df=$(mktemp) || exit 3
Xvfb -displayfd 3 -screen 0 3840x2160x24 -nolisten tcp 3>"$df" >/dev/null 2>&1 &
xpid=$!
trap 'kill "$xpid" 2>/dev/null; rm -f "$df"' EXIT
trap 'exit 143' INT TERM HUP
n=0
while [ ! -s "$df" ]; do
	kill -0 "$xpid" 2>/dev/null || { echo "xvfb-run shim: Xvfb died" >&2; exit 3; }
	n=$((n+1)); [ $n -gt 100 ] && { echo "xvfb-run shim: Xvfb never gave a display" >&2; exit 3; }
	sleep 0.1
done
DISPLAY=":$(tr -d '\n' < "$df")" "$@"
XSHIM
chmod +x shot-shim/godot shot-shim/xvfb-run
export XDG_RUNTIME_DIR=/run/user/$(id -u) SHOT_GPU_INDEX=$idx PATH=$HOME/gpu/shot-shim:$PATH
cd "shot/$project" || exit 3
# The class cache lives here between runs; a stale one reads as "Identifier not declared".
nice -n 5 timeout 900 "$HOME/gpu/bin/godot" --headless --path . --import >/dev/null 2>&1 </dev/null 8>&- 9>&- {f}>&-
touch ../"$project".stamp
sleep 1
timeout -k 15 "$limit" "$@" </dev/null 8>&- 9>&- {f}>&-
rc=$?
find . -newer ../"$project".stamp -name '*.png' -not -path './.godot/*' > ../"$project".files
echo "__GPU_SHOT_RC=$rc"
EOF

# A frame under 2 KB, or with no pixel brighter than 8 of 255, is a failed render.
check_frame() {
	local f=$1 size
	[[ -f $f ]] || return 0
	size=$(stat -c %s "$f")
	if (( size < 2048 )); then echo "gpu.sh: ERROR $f is only $size bytes: the render failed" >&2; return 1; fi
	python3 -I - "$f" <<'PY' 2>/dev/null || { echo "gpu.sh: ERROR $f is all black: the render failed" >&2; return 1; }
import sys
try:
    from PIL import Image
except ImportError:
    sys.exit(0)  # no PIL: cannot judge, so do not reject
hi = Image.open(sys.argv[1]).convert("L").getextrema()[1]
sys.exit(0 if hi > 8 else 1)
PY
}

# One try on the current box (set_box), in a subshell: exit 75 = not taken, 76 = did not
# answer, else the tool's own exit code. SHOT_STAGE / SHOT_PULL are directories (the same
# absolute path on both sides): staged ones are copied over first, pulled ones copied back.
shot_on() {
	local down=$1 limit=$2; shift 2
	local reply rc= line d
	trap '' PIPE
	reply=$("${SSH[@]}" "bash -c $(printf '%q' "$GUARD_FN"$'\n'"$REMOTE_SHOT") _ probe $(printf '%q ' \
		"$project" "$DESKTOP_GUARD" 5 "$limit")" 2>/dev/null | tail -1) || true
	if [[ -z $reply ]]; then mkdir -p "$(dirname "$down")"; touch "$down"; exit 76; else rm -f "$down"; fi
	[[ $reply == OK ]] || { [[ ${GPU_OFFER_VERBOSE:-0} == 1 ]] && echo "gpu.sh: $BOX: $reply" >&2; exit 75; }
	local rs=(-e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10")
	"${SSH[@]}" "mkdir -p ~/gpu/shot/$project" && \
	rsync -az --delete --copy-links --exclude '.godot/' --exclude '.git/' --exclude 'screenshots/' \
		"${rs[@]}" "$ROOT/$project/" "$HOST:gpu/shot/$project/" || { echo "gpu.sh: copying $project to $BOX failed" >&2; exit 75; }
	for d in "${SHOT_STAGE[@]}"; do
		"${SSH[@]}" "mkdir -p $(printf '%q' "$d")" && rsync -az "${rs[@]}" "$d/" "$HOST:$d/" || exit 75
	done
	echo "gpu.sh: $BOX_DESC takes this frame: $project: $*" >&2
	while IFS= read -r line; do
		if [[ $line == __GPU_SHOT_RC=* ]]; then rc=${line#*=}; else printf '%s\n' "$line"; fi
	done < <("${SSH[@]}" "bash -c $(printf '%q' "$GUARD_FN"$'\n'"$REMOTE_SHOT") _ run $(printf '%q ' \
		"$project" "$DESKTOP_GUARD" 20 "$limit" "$@")" 2>&1)
	# No exit code: the box refused after the probe (a lock was taken meanwhile) or the link
	# went. Run it somewhere else rather than report a result nobody saw.
	[[ -n $rc ]] || { echo "gpu.sh: $BOX gave no result" >&2; exit 75; }
	rsync -az "${rs[@]}" --files-from=":gpu/shot/$project.files" "$HOST:gpu/shot/$project/" "$ROOT/$project/" ||
		echo "gpu.sh: could not copy the frames back from $BOX" >&2
	for d in "${SHOT_PULL[@]}"; do
		mkdir -p "$d"; rsync -az "${rs[@]}" "$HOST:$d/" "$d/" || echo "gpu.sh: could not copy $d back from $BOX" >&2
	done
	# A black or tiny PNG looks like a result; fail loudly instead (rc 1 if the tool said 0).
	local f bad=0
	while IFS= read -r f; do
		[[ -n $f ]] || continue
		check_frame "$ROOT/$project/$f" || bad=1
	done < <("${SSH[@]}" "cat ~/gpu/shot/$project.files" 2>/dev/null)
	# 77 = blank: shot_cmd stops offloading and renders here, with a visible message.
	if [[ $bad == 1 && $rc == 0 ]]; then
		echo "gpu.sh: WARN $BOX returned a blank frame (see above); discarding it" >&2
		while IFS= read -r f; do [[ -n $f ]] && rm -f "$ROOT/$project/$f"; done < <("${SSH[@]}" "cat ~/gpu/shot/$project.files" 2>/dev/null)
		exit 77
	fi
	exit "$rc"
}

# gpu.sh shot [--route] [--stage DIR]... [--pull DIR]... [--timeout SEC] <project> <command...>
# The command runs in the project's folder on a box, and is `tools/*.sh`, `xvfb-run ...` or
# `godot ...`. Every new or changed *.png under the project comes back to the same path.
# Neither box taking it (down, busy for GPU_SHOT_WAIT seconds, a person at the desktop)
# runs it here with one WARN line; with --route (heavy's hook) that is exit 75 instead, so
# heavy queues it locally as it always did.
shot_cmd() {
	local route=0 limit=${GPU_SHOT_TIMEOUT:-900} b rc deadline lf warn=
	SHOT_STAGE=() SHOT_PULL=()
	while [[ $# -gt 0 ]]; do
		case $1 in
			--route) route=1; shift ;;
			--stage) SHOT_STAGE+=("${2:?--stage needs a directory}"); shift 2 ;;
			--pull) SHOT_PULL+=("${2:?--pull needs a directory}"); shift 2 ;;
			--timeout) limit=${2:?--timeout needs seconds}; shift 2 ;;
			*) break ;;
		esac
	done
	project=${1:-}; shift || true
	project_dir "$project"
	[[ $# -gt 0 ]] || die "shot $project: which command?"
	unwrap "$@"
	case ${UW_REST[0]} in tools/*.sh|./tools/*.sh|xvfb-run|godot) ;;
		./game.sh|game.sh) [[ ${UW_REST[1]:-} == shot ]] || die "only ./game.sh shot runs on a box" ;; *) die "shot runs tools/*.sh, xvfb-run or godot, not '${UW_REST[0]}'" ;; esac
	[[ ${UW_REST[0]} != *..* ]] || die "no .. in the command"
	# RENDERER, RESOLUTION and SHOT_* are what the screenshot tools read; carry them across.
	local envs=() v
	for v in RENDERER RESOLUTION; do [[ -n ${!v:-} ]] && envs+=("$v=${!v}"); done
	for v in ${!SHOT_@}; do [[ $v == SHOT_STAGE || $v == SHOT_PULL ]] || envs+=("$v=${!v}"); done
	[[ ${#envs[@]} == 0 ]] || set -- env "${envs[@]}" "$@"
	if [[ "${GPU_OFFLOAD:-1}" != 0 ]]; then
		mkdir -p "${HEAVY_DIR:-/var/tmp/heavy}"
		exec {lf}>>"${HEAVY_DIR:-/var/tmp/heavy}/gpu-shot.$project.lock"
		flock "$lf"   # two shots of one project would rsync over each other's copy
		deadline=$(( $(date +%s) + ${GPU_SHOT_WAIT:-90} ))
		while :; do
			local answered=0
			for b in ${GPU_SHOT_BOXES:-staging staging02}; do
				down="${HEAVY_DIR:-/var/tmp/heavy}/gpu-down.$b"
				[[ -e $down && $(( $(date +%s) - $(stat -c %Y "$down") )) -lt 300 ]] && continue
				set +e
				( set -e; set_box "$b"; shot_on "$down" "$limit" "$@" )
				rc=$?
				set -e
				[[ $rc != 76 ]] && answered=1
				if [[ $rc == 77 ]]; then warn="$b returned a blank frame"; answered=0; break 2; fi
				[[ $rc == 75 || $rc == 76 ]] || exit "$rc"
			done
			[[ $answered == 1 && $(date +%s) -lt $deadline ]] || break
			sleep 10
		done
		warn=${warn:-no GPU box took the frame (down, busy or in use)}
		exec {lf}>&-
	fi
	if [[ $route == 1 ]]; then
		[[ -z $warn ]] || echo "gpu.sh: WARN $warn; rendering on dev02's CPU (llvmpipe), not a real GPU" >&2
		exit 75
	fi
	echo "gpu.sh: WARN ${warn:-GPU_OFFLOAD=0}; rendering here on the CPU (llvmpipe), not a real GPU" >&2
	cd "$ROOT/$project"
	if [[ -z ${HEAVY_HELD:-} ]] && command -v heavy >/dev/null; then exec heavy --lane check -- "$@"; fi
	exec "$@"
}

# heavy's hook for every job it is about to queue (before it takes a slot): exit 75 = not
# ours, queue it here. Screenshot tools go to a real GPU first, always; a game suite goes to
# the boxes' CPUs first only for HEAVY_PREFER_OFFLOAD=1 (the nightly runner), otherwise only
# once it has had to wait (`offer`).
route_cmd() {
	[[ "${GPU_OFFLOAD:-1}" != 0 ]] || exit 75
	project="${PWD#"$ROOT"/}"
	[[ "$PWD" == "$ROOT/$project" && "$project" != */* && -f "$PWD/project.godot" ]] || exit 75
	unwrap "$@"
	case "${UW_REST[0]:-}" in
		tools/screenshot*.sh|./tools/screenshot*.sh|tools/shot*.sh|./tools/shot*.sh|tools/camera_check*.sh|./tools/camera_check*.sh|./game.sh|game.sh)
			[[ ${UW_REST[0]} != *game.sh || ${UW_REST[1]:-} == shot ]] || exit 75
			local pre=() cmd=("${UW_REST[@]}")
			[[ -z $UW_LIMIT ]] || pre=(--timeout "$UW_LIMIT")
			[[ ${#UW_ENV[@]} == 0 ]] || cmd=(env "${UW_ENV[@]}" "${cmd[@]}")
			shot_cmd --route "${pre[@]}" "$project" "${cmd[@]}" ;;
	esac
	local sentinel="${HEAVY_DIR:-/var/tmp/heavy}/prefer-offload"
	if [[ ${HEAVY_PREFER_OFFLOAD:-0} == 1 ]] || [[ -e $sentinel && $(( $(date +%s) - $(stat -c %Y "$sentinel") )) -lt 43200 ]]; then exec "${BASH_SOURCE[0]}" offer "$@"; fi
	exit 75
}

# Python jobs that hold a whole map in memory (BSP converters, route planners, nav emulation)
# pegged dev02's ~11 GB beside two suites (2026-10-20), and they never went through heavy.
# They run on staging02 (31 GB) instead, the laptop when the desktop is off (weekends), and
# under heavy here only when neither answers.
#
# The box's user is gamedev and cannot write /home/christian, so every staged directory is
# mirrored under $PY_ROOT at its own absolute path, the command runs from the mirror of $PWD
# with HOME pointed at the mirror of ~ (so ~/mapsrc resolves), and an argument naming a
# path under ~ is rewritten. Scratch scripts that hard-code /home/christian/godot/dot-map/
# tools/bsp still import it: the mirror of that directory is staged always and put on
# PYTHONPATH. Dependencies (numpy, matplotlib, pillow) live in a venv on the box, made on
# first use. Results come back by rsync without --delete, over the same directories.
py_cmd() {
	local stage=() pull=() d
	while [[ $# -gt 0 ]]; do
		case $1 in
			--stage) stage+=("$(realpath "${2:?--stage needs a directory}")"); shift 2 ;;
			--pull) pull+=("$(realpath "${2:?--pull needs a directory}")"); shift 2 ;;
			--) shift; break ;;
			*) break ;;
		esac
	done
	[[ $# -gt 0 ]] || die "py: which command? (gpu.sh py [--stage DIR] -- python3 script.py ...)"
	local top
	top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	[[ ${#stage[@]} -gt 0 ]] || stage=("$top")
	[[ ${#pull[@]} -gt 0 ]] || pull=("$top")
	stage+=("$ROOT/dot-map/tools/bsp")

	local box=
	if [[ ${GPU_OFFLOAD:-1} != 0 ]]; then
		for b in ${GPU_BOX:-staging02 staging}; do
			set_box "$b"
			if "${SSH[@]}" true 2>/dev/null; then box=$b; break; fi
		done
	fi
	if [[ -z $box ]]; then
		echo "gpu.sh py: no box answers; running here under heavy" >&2
		exec heavy -- "$@"
	fi
	local PY_ROOT="$REMOTE_HOME/gpu/py/root" PY_VENV="$REMOTE_HOME/gpu/py/venv"
	echo "gpu.sh py: on $BOX_DESC: $*" >&2
	"${SSH[@]}" "[ -x $PY_VENV/bin/python3 ] || { python3 -m venv $PY_VENV && $PY_VENV/bin/pip -q install numpy matplotlib pillow || { rm -rf $PY_VENV; false; }; }" >&2 ||
		die "py: could not make the venv on $BOX"
	local rs=(-e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10")
	for d in "${stage[@]}"; do
		[[ -d $d ]] || continue
		"${SSH[@]}" "mkdir -p $(printf '%q' "$PY_ROOT$d")"
		rsync -az --delete --copy-links --exclude '.git/' --exclude '.godot/' "${rs[@]}" "$d/" "$HOST:$PY_ROOT$d/" ||
			die "py: copying $d to $BOX failed"
	done
	local args=() a
	for a in "$@"; do
		[[ $a == "$HOME"/* || $a == "$HOME" ]] && a="$PY_ROOT$a"
		[[ $a == python || $a == python3 ]] && a="$PY_VENV/bin/python3"
		args+=("$a")
	done
	local cmd
	cmd="mkdir -p $(printf '%q' "$PY_ROOT$PWD") && cd $(printf '%q' "$PY_ROOT$PWD") && HOME=$(printf '%q' "$PY_ROOT$HOME") PYTHONPATH=$(printf '%q' "$PY_ROOT$ROOT/dot-map/tools/bsp")\${PYTHONPATH:+:\$PYTHONPATH} MPLBACKEND=Agg flock -o -s ~/gpu/.lock timeout ${GPU_TIMEOUT:-3600} $(printf '%q ' "${args[@]}")"
	local rc=0
	"${SSH[@]}" "bash -lc $(printf '%q' "$cmd")" || rc=$?
	for d in "${pull[@]}"; do
		mkdir -p "$d"
		rsync -az --update --exclude '.git/' --exclude '.godot/' "${rs[@]}" "$HOST:$PY_ROOT$d/" "$d/" ||
			echo "gpu.sh py: could not copy $d back from $BOX" >&2
	done
	return "$rc"
}

case "${1:-}" in
	status)
		for b in ${GPU_BOX:-staging staging02}; do
		set_box "$b"
		echo "== $BOX_DESC"
		"${SSH[@]}" 'nvidia-smi --query-gpu=name,driver_version,utilization.gpu,memory.used,memory.total --format=csv,noheader;
			uptime;
			if flock -n ~/gpu/.lock true 2>/dev/null; then echo "lock: free"; else echo "lock: HELD"; fi;
			for w in ~/gpu/suite.*.who; do [ -e "$w" ] || continue; flock -n "${w%.who}.lock" true 2>/dev/null ||
				echo "$(basename "${w%.who}"): $(cat "$w")"; done;
			vulkaninfo --summary 2>/dev/null | grep -E "^GPU[0-9]|deviceName" | paste - - | sed "s/ \+/ /g"' || echo "(unreachable)"
		done
		;;
	capacity)
		# One line per box: the slots heavy can still hand it. heavy --status prints this.
		for b in ${GPU_SUITE_BOXES:-staging staging02}; do
			set_box "$b"
			read -r free total gb state < <(box_capacity)
			printf '%-10s %s/%s suite slots free, %s GB free, %s\n' "$BOX" "$free" "$total" "$gb" "$state"
			"${SSH[@]}" 'for w in ~/gpu/suite.*.who; do [ -e "$w" ] || continue; flock -n "${w%.who}.lock" true 2>/dev/null ||
				echo "           running: $(cat "$w")"; done' 2>/dev/null || true
		done
		;;
	shot)
		shift
		shot_cmd "$@"
		;;
	route)
		shift
		route_cmd "$@"
		;;
	blender)
		# Blender 4.3 on the desktop's RTX 2070 (Cycles: pass `--cycles-device OPTIX` after the
		# script/scene, or set it in the script). Directories named --stage are copied over and
		# --pull ones copied back, at the same absolute path: put the .blend and the output there.
		#   ./gpu.sh blender --stage ~/work/scene --pull ~/work/scene/out -- -b ~/work/scene/a.blend -o ~/work/scene/out/f_#### -f 1
		shift
		set_box "${GPU_BOX:-staging02}"
		SHOT_STAGE=() SHOT_PULL=()
		while [[ $# -gt 0 ]]; do
			case $1 in
				--stage) SHOT_STAGE+=("${2:?--stage needs a directory}"); shift 2 ;;
				--pull) SHOT_PULL+=("${2:?--pull needs a directory}"); shift 2 ;;
				--) shift; break ;;
				*) break ;;
			esac
		done
		rs=(-e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10")
		for d in "${SHOT_STAGE[@]}"; do "${SSH[@]}" "mkdir -p $(printf '%q' "$d")" && rsync -az "${rs[@]}" "$d/" "$HOST:$d/"; done
		# Shared lock, like a suite or a shot: a render does not need the box to itself and must not wait out a suite.
		rc=0; "${SSH[@]}" "flock -o -s ~/gpu/.lock timeout ${GPU_TIMEOUT:-1800} $REMOTE_HOME/gpu/blender/blender $(printf '%q ' "$@")" || rc=$?
		for d in "${SHOT_PULL[@]}"; do mkdir -p "$d"; rsync -az "${rs[@]}" "$HOST:$d/" "$d/" || true; done
		exit "$rc"
		;;
	py)
		shift
		py_cmd "$@"
		;;
	sync)
		sync_project "${2:-}"
		;;
	run)
		project="${2:-}"
		sync_project "$project"
		shift 2
		# A project directory the box has not seen has no .godot (sync leaves it out), and a
		# non-editor run of that never finishes: it spun for 24 minutes holding the lock. Import
		# first, headless, whenever the class cache is missing or a source is newer than it (new glbs left
		# "Cannot open file .godot/imported/...scn" on a box that had imported before).
		remote_locked bash -c "cd $(printf '%q' "$REMOTE_HOME/$REMOTE_ROOT/$project") && { [ -f .godot/global_script_class_cache.cfg ] && [ -z \"\$(find . -path ./.godot -prune -o \\( -name \"*.import\" -o -name \"*.glb\" -o -name \"*.gd\" \\) -newer .godot/global_script_class_cache.cfg -print -quit)\" ] || timeout 900 $REMOTE_HOME/gpu/bin/godot --headless --path . --import >/dev/null 2>&1 </dev/null; }; true"
		remote_locked timeout -k 15 "${GPU_TIMEOUT:-1800}" xvfb-run -a -s "-screen 0 1920x1080x24" \
			"$REMOTE_HOME/gpu/bin/godot" --path "$REMOTE_HOME/$REMOTE_ROOT/$project" \
			--rendering-driver vulkan --gpu-index "$GPU_INDEX" "$@"
		;;
	exec)
		shift
		[[ $# -gt 0 ]] || die "exec what?"
		remote_locked "$@"
		;;
	pull)
		project_dir "${2:-}"
		[[ -n "${3:-}" ]] || die "pull which path inside $2?"
		# dest is a directory the path lands IN (rsync semantics), by default its own folder here.
		dest="${4:-$ROOT/$2/$(dirname "$3")}"
		mkdir -p "$dest"
		rsync -az -e "ssh -i $KEY -o BatchMode=yes" "$HOST:$REMOTE_ROOT/$2/$3" "$dest/"
		;;
	browser-shot)
		url="${2:-}"; out="${3:-}"
		[[ -n "$url" && -n "$out" ]] || die "browser-shot <url> <out.png>"
		# --virtual-time-budget lets a page that loads for a while get there before the frame.
		remote_locked bash -c "rm -rf /tmp/gpu-chrome && timeout 180 google-chrome $CHROME_COMMON $CHROME_GPU_FLAGS \
			--user-data-dir=/tmp/gpu-chrome --virtual-time-budget=${GPU_PAGE_MS:-30000} \
			--screenshot=/tmp/gpu-browser-shot.png $(printf '%q' "$url") >/dev/null 2>&1; ls /tmp/gpu-browser-shot.png"
		mkdir -p "$(dirname "$out")"
		scp -q -i "$KEY" "$HOST:/tmp/gpu-browser-shot.png" "$out"
		echo "$out"
		;;
	cdp)
		port="${2:-9222}"
		# Holds the lock for as long as the tunnel is up: a frame timing taken while a
		# bake runs is worthless. It refuses at once when the lock is taken (flock -n)
		# rather than queueing: a tunnel that waits looks exactly like a dead one, and
		# the queued process outlives the ssh that asked for it. Chrome is tied to this ssh's stdin, not to the ssh
		# itself: a dropped ssh does not kill a remote process, and an orphaned Chrome
		# held the lock (2026-10-18). When the tunnel ends, cat sees EOF and Chrome goes.
		echo "Chrome on $BOX_DESC, DevTools at http://127.0.0.1:$port (stop: kill this command)"
		# The trap kills both halves of the pipeline: killing this script alone left
		# tail and ssh running, so the tunnel (and the lock) outlived it.
		trap 'pkill -P $$ 2>/dev/null' EXIT INT TERM
		tail -f /dev/null | ssh -i "$KEY" -o BatchMode=yes -o ExitOnForwardFailure=yes -L "$port:127.0.0.1:$port" ${GPU_CDP_SERVE:+-R "$GPU_CDP_SERVE:127.0.0.1:$GPU_CDP_SERVE"} "$HOST" \
			"flock -n -o ~/gpu/.gate flock -n -o ~/gpu/.lock bash -c 'rm -rf /tmp/gpu-chrome-cdp; google-chrome $CHROME_COMMON $CHROME_GPU_FLAGS \
			--user-data-dir=/tmp/gpu-chrome-cdp --remote-debugging-address=127.0.0.1 --remote-debugging-port=$port about:blank \
			>/dev/null 2>&1 & c=\$!; cat >/dev/null; kill \$c; wait \$c' || echo 'gpu.sh: $BOX_DESC is busy (lock held); ./gpu.sh status' >&2" &
		wait
		;;
	offer)
		# Called by heavy while a build-lane job waits. 75 (EX_TEMPFAIL) is "not taken":
		# heavy keeps waiting here and offers again later. Any other code is the suite's.
		# The laptop first: its link is four times faster, so the copy costs less.
		shift
		offer_eligible "$@" || { [[ ${GPU_OFFER_VERBOSE:-0} == 1 ]] && echo "gpu.sh: not a suite these boxes can run" >&2; exit 75; }
		# Most free slots first (the laptop first on a tie: its link is faster).
		order=$(for b in ${GPU_SUITE_BOXES:-staging staging02}; do
			down="${HEAVY_DIR:-/var/tmp/heavy}/gpu-down.$b"
			[[ -e $down && $(( $(date +%s) - $(stat -c %Y "$down") )) -lt 300 ]] && continue
			cap=$( set_box "$b"; box_capacity )
			echo "${cap%% *} $b"
		done | sort -s -k1,1nr | awk '{print $2}')
		for b in $order; do
			# A box that did not answer is skipped for 5 minutes: heavy offers every 15 s,
			# and a 10 s connect timeout each time would be most of the wait.
			down="${HEAVY_DIR:-/var/tmp/heavy}/gpu-down.$b"
			[[ -e $down && $(( $(date +%s) - $(stat -c %Y "$down") )) -lt 300 ]] && continue
			set +e
			( set -e; set_box "$b"; offer_on "$down" "${UW_REST[@]}" )
			rc=$?
			set -e
			[[ $rc == 75 ]] || exit "$rc"
		done
		exit 75
		;;
	*)
		sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 2
		;;
esac
