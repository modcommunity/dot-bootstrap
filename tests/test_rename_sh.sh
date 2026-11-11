#!/usr/bin/env bash
# A renamed repository, in bootstrap.sh: another name from projects.tsv's third
# column selects it, an existing checkout of the old name is repointed to the new
# one, and a repository that does not exist fails the run in red by name.
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bs" "$T/remote" "$T/p"
cp "$H/bootstrap.sh" "$T/bs/"
for r in old-name new-name; do
    git init -q --bare "$T/remote/$r.git"
done
git clone -q "$T/remote/new-name.git" "$T/seed" 2>/dev/null
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git -C "$T/seed" push -q origin HEAD:main 2>/dev/null
git -C "$T/remote/new-name.git" symbolic-ref HEAD refs/heads/main
# The checkout made before the rename: same history, origin still the old repository.
git clone -q "$T/remote/new-name.git" "$T/p/renamed" 2>/dev/null
git -C "$T/p/renamed" remote set-url origin "$T/remote/old-name.git"
printf 'renamed\t%s\tnew-name,newer\ngone\t%s\n' "$T/remote/new-name.git" "$T/remote/no-such.git" > "$T/bs/projects.tsv"

out="$(cd "$T" && DOT_PROJECTS="$T/p" NO_COLOR=1 ./bs/bootstrap.sh --only newer,gone 2>&1)"; rc=$?
check 'an alias selects the listed name' 'printf "%s" "$out" | grep -q "^renamed "'
check 'the old origin is repointed'      '[ "$(git -C "$T/p/renamed" remote get-url origin)" = "$T/remote/new-name.git" ]'
check 'the repoint is said'              'printf "%s" "$out" | grep -q "origin moved"'
check 'a missing repository is named'    'printf "%s" "$out" | grep -q "REPOSITORY MISSING"'
check 'and fails the run'                '[ $rc -ne 0 ]'
[ $fail -eq 0 ] || printf '%s\n' "$out" | tail -20
echo "rename: $pass passed, $fail failed"
[ $fail -eq 0 ]
