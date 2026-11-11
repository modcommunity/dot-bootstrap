#!/usr/bin/env bash
# Regression (2026-11-11): gpu.sh's rsync wrapper must queue FIFO. ~40 jobs polled 2 flock slots in no order, so
# a job could wait 20+ minutes while others overtook it. Checks: start order == arrival order, never more than
# GPU_RSYNC_SLOTS at once, a dead waiter's ticket does not block the queue, the wait is announced on stderr.
set -u
src=$(cd "$(dirname "$0")/.." && pwd)/tools/gpu.sh
fail=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/rsync" <<'F'
#!/usr/bin/env bash
echo "S ${@: -1}" >> "$LOG"; sleep 1.5; echo "E ${@: -1}" >> "$LOG"
F
chmod +x "$tmp/bin/rsync"
fn=$(sed -n '/^rsync() {$/,/^}$/p' "$src")
[ -n "$fn" ] || { echo "FAIL rsync function not found"; exit 1; }
export LOG=$tmp/log GPU_RSYNC_DIR=$tmp/q GPU_RSYNC_SLOTS=2 GPU_RSYNC_NOTE_S=1 PATH=$tmp/bin:$PATH
: > "$LOG"
# A ticket of a dead pid, older than all others: must be pruned, not block.
mkdir -p "$tmp/q"; ( exit 0 ) & dead=$!; wait $dead; echo "$dead" > "$tmp/q/0.$dead"
for n in 1 2 3 4 5 6; do
	bash -c "$fn"$'\n'"rsync $n" 2>"$tmp/err.$n" & sleep 0.15
done
wait
order=$(grep '^S' "$LOG" | awk '{printf "%s", $2}')
ck "slots taken in arrival order ($order)" '[ "$order" = 123456 ]'
maxc=$(awk '/^S/{c++; if(c>m)m=c} /^E/{c--} END{print m}' "$LOG")
ck "never more than 2 at once (max $maxc)" '[ "$maxc" -le 2 ]'
ck "all six ran" '[ "$(grep -c "^E" "$LOG")" = 6 ]'
ck "dead ticket pruned" '[ ! -e "$tmp/q/0.$dead" ]'
ck "queue dir empty afterwards" '[ -z "$(ls "$tmp/q" | grep -v lock)" ]'
ck "late waiter announced its wait" 'grep -q "waiting for an rsync slot" "$tmp/err.6"'
exit $((fail>0))
