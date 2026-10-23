#!/usr/bin/env bash
# Both scripts must link a content directory whose bootstrap-link line carries dot-ci's
# trailing "ci" opt-in (mg-wipeout's courses): the .ps1 regex once rejected it, silently.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/mg-wipeout/addons" "$tmp/mg-wipeout-maps/courses"
printf '# bootstrap-link: mg-wipeout-maps/courses ci\n/courses\n' > "$tmp/mg-wipeout/.gitignore"
git -C "$tmp/mg-wipeout" init -q
fail=0
DOT_PROJECTS="$tmp" "$here/bootstrap.sh" --links --only mg-wipeout --no-deps >/dev/null 2>&1
[ -L "$tmp/mg-wipeout/courses" ] && [ -d "$tmp/mg-wipeout/courses" ] || { echo "FAIL bootstrap.sh did not link a 'ci' content line"; fail=1; }
line='# bootstrap-link: mg-wipeout-maps/courses ci'
if command -v pwsh >/dev/null; then
    pwsh -NoProfile -Command "if ('$line' -notmatch '^# bootstrap-link: (\S+)(\s+ci)?\s*\$') { exit 1 }" \
        || { echo "FAIL bootstrap.ps1 pattern rejects a 'ci' line"; fail=1; }
fi
grep -qF "(\\S+)(\\s+ci)?" "$here/bootstrap.ps1" || { echo "FAIL bootstrap.ps1 Link-Content pattern lacks the ci form"; fail=1; }
[ $fail = 0 ] && echo "content links: ok"
exit $fail
