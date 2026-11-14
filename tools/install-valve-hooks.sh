#!/usr/bin/env bash
#
# Installs the Valve-origin pre-commit hook in every git repository under a projects directory.
#
#   tools/install-valve-hooks.sh [--check] [PROJECTS_DIR]
#
# The guard is dot-cloud's tools/check_valve_files.py. Its --install-hook writes the hook, which
# runs `--git --staged` on every commit and refuses a staged .vpk, .vtf, .vmt, .mdl, .vvd, .vtx,
# .phy, .ani or textures/orig file. Nothing is copied here: the hook names the guard in the
# dot-cloud checkout beside the repositories, so updating dot-cloud updates the guard everywhere.
# That path is absolute, so run this again after moving the projects directory.
#
# DOT_CLOUD names the dot-cloud checkout holding the guard (default: dot-cloud inside PROJECTS_DIR).
#
# PROJECTS_DIR defaults to DOT_PROJECTS, else ./projects beside this script (bootstrap.sh's own
# default). Every immediate subdirectory with a .git (directory or worktree file) is a repository.
# A repository whose hook is already there is left alone; the install is idempotent.
#
# --check changes nothing: it lists each repository whose pre-commit hook does not name the guard.
#
# Exit 0 when every repository has the hook, 1 when one could not be set up (or, with --check,
# one is missing it), 2 on a setup error such as no dot-cloud checkout.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
projects="${1:-${DOT_PROJECTS:-$here/../projects}}"

[ -d "$projects" ] || { echo "install-valve-hooks: no projects directory at $projects (run bootstrap.sh first, or pass one)" >&2; exit 2; }
projects="$(cd "$projects" && pwd)"
cloud="${DOT_CLOUD:-$projects/dot-cloud}"
guard="$cloud/tools/check_valve_files.py"
[ -f "$guard" ] || { echo "install-valve-hooks: no guard at $guard (set DOT_CLOUD to a dot-cloud checkout, or clone it with: bootstrap.sh --only dot-cloud --no-deps)" >&2; exit 2; }

rc=0; total=0; have=0
for d in "$projects"/*/; do
    d="${d%/}"
    [ -e "$d/.git" ] || continue
    total=$((total + 1))
    name="$(basename "$d")"
    hp="$(git -C "$d" rev-parse --git-path hooks/pre-commit 2>/dev/null)"
    case "$hp" in ""|/*) ;; *) hp="$d/$hp" ;; esac
    if [ "$check" -eq 1 ]; then
        if [ -f "$hp" ] && grep -qF "$guard" "$hp"; then
            have=$((have + 1))
        else
            printf '%-28s %s\n' "$name" "no Valve-origin hook" >&2; rc=1
        fi
        continue
    fi
    if msg="$(python3 -I "$guard" --install-hook "$d" 2>&1 >/dev/null)"; then
        have=$((have + 1))
    else
        printf '%-28s %s\n' "$name" "hook NOT installed: $(printf '%s' "$msg" | tail -1)" >&2; rc=1
    fi
done

if [ "$total" -eq 0 ]; then
    echo "install-valve-hooks: no repositories under $projects" >&2; exit 2
fi
printf 'install-valve-hooks: %d of %d repositories have the hook (%s)\n' "$have" "$total" "$projects"
exit $rc
