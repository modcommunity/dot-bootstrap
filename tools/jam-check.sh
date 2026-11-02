#!/usr/bin/env bash
# Prints one line per jam condition, only when the set of conditions changes (loop with --watch).
# Jam: a dev02 build slot held over 40 min, a heavy waiter over 30 min, a GPU box with 0 free slots and no job listed,
# a free build slot while live tickets wait over 3 min, or live tickets with nothing running for 3 min.
# Gotcha: a waiting heavy reads /etc/heavy.conf once at start, so after a threshold change the old waiters keep
# the old value and block the FIFO; restart them (or kill the stale tickets) rather than expecting the new value.
once() {
	now=$(date +%s); st=$(timeout 90 heavy --status 2>&1)
	while read -r hhmmss; do
		t=$(date -d "$hhmmss" +%s 2>/dev/null) || continue; [ "$t" -gt "$now" ] && t=$((t-86400))
		[ $(( (now-t)/60 )) -gt 40 ] && echo "SLOT HELD $(( (now-t)/60 )) min since $hhmmss"
	done < <(grep -E '^busy +build' <<<"$st" | sed -E 's/.* since ([0-9:]{8}).*/\1/')
	held=$(cat /var/tmp/heavy/*.who 2>/dev/null | sed -n 's/.* pid \([0-9]*\) since.*/\1/p' | tr '\n' ' ')
	# a heavy whose job was offloaded to a GPU box shows as "running: who since T: [game: ]cmd" under the box; each such line
	# excuses one local waiter with the same command tail that started before T (two identical commands stay distinguished)
	off=$(mktemp); while read -r hhmmss cmd; do
		t=$(date -d "$hhmmss" +%s 2>/dev/null) || continue; [ "$t" -gt "$now" ] && t=$((t-86400)); printf '%s\t%s\n' "$t" "$cmd"
	done < <(sed -nE 's/^ +running: [^ ]+ since ([0-9:]{8}): (.*)$/\1 \2/p' <<<"$st") > "$off"
	ps -eo etimes,pid,cmd | awk -v held=" $held" -v now="$now" -v off="$off" 'BEGIN {while ((getline l < off) > 0) {split(l, a, "\t"); n++; ot[n]=a[1]; oc[n]=a[2]}}
		$3=="bash" && $4 ~ /heavy$/ && $5=="--" && $1>1800 && index(held, " " $2 " ")==0 {
			cmd=substr($0, index($0,$6)); sub(/^timeout [0-9]+ /, "", cmd); start=now-$1; for (i=1; i<=n; i++) if (!used[i] && ot[i]>=start-5 && index(oc[i], cmd)) {used[i]=1; next}
			printf "WAITER %d min: %s\n", $1/60, substr(cmd, 1, 90)}'
	rm -f "$off"
	# a full box with no listed job is normal while a GPU job runs; only report it once it has persisted 15 min
	seen=$HOME/.cache/jam-check-boxes; mkdir -p "$HOME/.cache"; touch "$seen"; keep=
	while read -r box line; do
		first=$(awk -v b="$box" '$1==b {print $2}' "$seen"); first=${first:-$now}; keep+="$box $first"$'\n'
		# a godot job running on the box (an offloaded suite not listed by heavy) is not a jam
		ssh -i ~/.ssh/gpu-laptop -o ConnectTimeout=8 -o BatchMode=yes "gamedev@$box.deacon.internal" 'pgrep -x godot >/dev/null' 2>/dev/null && continue
		[ $((now-first)) -gt 900 ] && echo "BOX $box has 0 free slots and no job listed for $(( (now-first)/60 )) min: $line"
	done < <(awk '/^  [a-z0-9]+ +0\/[0-9]+ suite slots free/ {box=$1; l=$0; getline nxt; if (nxt !~ /running:/) print box, l}' <<<"$st")
	printf '%s' "$keep" > "$seen"
	# local queue: tickets are queue.build.<ns>.<pid>; only live pids count
	cs=$HOME/.cache/jam-check-conds; touch "$cs"; ckeep=
	persist() { local f; f=$(awk -v k="$1" '$1==k {print $2}' "$cs"); f=${f:-$now}; ckeep+="$1 $f"$'\n'; echo $((now-f)); }
	tickets=0; for t in /var/tmp/heavy/queue.build.*; do [ -e "$t" ] && kill -0 "${t##*.}" 2>/dev/null && tickets=$((tickets+1)); done
	nbusy=$(grep -cE '^busy +build' <<<"$st"); nchk=$(grep -cE '^busy +check' <<<"$st")
	slots=$(sed -n 's/.*build slots 2-\([0-9]*\) need.*/\1/p' <<<"$st"); slots=${slots:-1}
	info=$(grep -E '^MemAvailable' <<<"$st")
	if [ "$tickets" -gt 0 ] && [ "$nbusy" -lt "$slots" ]; then
		age=$(persist freeslot); [ "$age" -gt 180 ] && echo "FREE SLOT, QUEUE WAITING $((age/60)) min: $nbusy/$slots build slots busy, $tickets live tickets; $info"
	fi
	if [ "$tickets" -gt 0 ] && [ "$nbusy" -eq 0 ] && [ "$nchk" -eq 0 ]; then
		age=$(persist idle); [ "$age" -gt 180 ] && echo "TICKETS, NOTHING RUNNING $((age/60)) min: $tickets live tickets; $info"
	fi
	printf '%s' "$ckeep" > "$cs"
}
last=
while :; do
	cur=$(once | sort); [ "$cur" != "$last" ] && { [ -n "$cur" ] && echo "$cur" || echo "JAMS CLEARED"; last=$cur; }
	[ "${1:-}" = --watch ] || exit 0; sleep 120
done
