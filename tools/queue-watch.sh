#!/usr/bin/env bash
# Clears what jammed the GPU boxes: an orphaned Xvfb (parent init, over 2 h) holding the lock,
# and gate waiters older than 2 h whose caller is long gone. Logs every action to ~/.cache/queue-watch.log.
set -u
LOG=$HOME/.cache/queue-watch.log; mkdir -p "$(dirname "$LOG")"
for spec in "staging:$HOME/.ssh/gpu-laptop:gamedev@staging.deacon.internal" "staging02:$HOME/.ssh/gpu-laptop:gamedev@staging02.deacon.internal"; do
	name=${spec%%:*}; rest=${spec#*:}; key=${rest%%:*}; dest=${rest#*:}
	out=$(timeout 40 ssh -i "$key" -o ConnectTimeout=10 -o BatchMode=yes "$dest" '
		for p in $(pgrep -x Xvfb); do
			[ "$(ps -o ppid= -p $p | tr -d " ")" = 1 ] || continue
			[ "$(ps -o etimes= -p $p | tr -d " ")" -gt 7200 ] || continue
			ls -l /proc/$p/fd 2>/dev/null | grep -q "gpu/" && { kill $p; echo "killed orphan Xvfb $p"; }
		done
		for p in $(pgrep -f "gpu/.gate flock"); do
			[ "$(ps -o etimes= -p $p | tr -d " ")" -gt 7200 ] && { kill $p; echo "killed stale waiter $p"; }
		done; true' 2>&1) || out="ssh failed: $out"
	[ -n "$out" ] && printf '%s %s: %s\n' "$(date '+%F %T')" "$name" "$out" >> "$LOG"
done
