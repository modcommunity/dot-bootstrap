#!/usr/bin/env bash
# gpu.sh box_unlock under `set -u`: bash unsets SYNCLK_PID when the coproc is reaped, so a holder that already exited
# (ssh dropped, stale timeout, finished) made "$SYNCLK_PID" an unbound variable ("SYNCLK_PID: unbound variable") and
# failed single-suite runs on an already-synced tree. box_unlock must tolerate every state and release the holder.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=${GPU_SRC:-$here/tools/gpu.sh}
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
fns=$(sed -n '/^box_lock() {/,/^}/p;/^box_unlock() {/,/^}/p' "$src")
[[ $fns == *"box_lock() {"* && $fns == *"box_unlock() {"* ]] || { echo "FAIL could not cut box_lock out of $src"; exit 1; }
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
# fake ssh: MODE=hold keeps the lock until stdin closes; MODE=exit says LOCKED and ends at once (holder gone before unlock)
cat > "$root/fakessh" <<'EOS'
#!/usr/bin/env bash
echo LOCKED
[[ ${MODE:-hold} == exit ]] && exit 0
exec head -c1 >/dev/null
EOS
chmod +x "$root/fakessh"
run() { # run <mode> <body>: box_lock, then body, under set -eu like gpu.sh
	MODE=$1 BODY=$2 FNS=$fns ROOTT=$root bash -c 'set -euE; BOX=fake; SSH=("$ROOTT/fakessh"); eval "$FNS"; eval "$BODY"; echo done'
}
alive() { [[ -z $(pgrep -f "$root/fakessh" 2>/dev/null) ]]; }

out=$(run hold 'box_lock x; box_unlock' 2>&1); [[ $out == done ]] && alive && ok "lock then unlock: holder released" || bad "hold: $out"
out=$(run exit 'box_lock x; sleep 1; box_unlock' 2>&1); [[ $out == done ]] && ok "holder already exited: no unbound variable" || bad "exited holder: $out"
out=$(run hold 'box_unlock' 2>&1); [[ $out == done ]] && ok "unlock without a lock (early path): quiet no-op" || bad "no lock: $out"
out=$(run hold 'box_lock x; box_unlock; box_unlock' 2>&1); [[ $out == done ]] && alive && ok "double unlock" || bad "double: $out"
out=$(run exit 'box_lock x; box_unlock; box_unlock' 2>&1); [[ $out == done ]] && ok "exited holder, double unlock" || bad "exit double: $out"
exit $fail
