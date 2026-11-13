#!/usr/bin/env bash
#
# Clone or update every project in the Dot family, wire the local-development
# addon links, and run any of the games.
#
#   ./bootstrap.sh                 clone what is missing, pull what is not, link
#   ./bootstrap.sh --links         only redo the links, touch no repository
#   ./bootstrap.sh --content-keys  make a content signing keypair, to publish packs
#   ./bootstrap.sh --tools         install fastgmad (.gma unpacker) into ~/.local/bin, checksum-verified
#   ./bootstrap.sh --status        report each repository, change nothing
#   ./bootstrap.sh --check         verify the list against the disk, change nothing
#   ./bootstrap.sh --list          what can be played
#   ./bootstrap.sh --play arena    play one, offline, no server needed
#   ./bootstrap.sh --export arena  build a RELEASE executable of any game into <game>/build/linux (a game with no export_presets gets a default preset; downloads the matching export template once, checksum-verified)
#   ./bootstrap.sh --play-export arena [args]  start that build (exporting first when there is none): offline; FC also 8 players, profiler overlay, `profiler_record` in the console records 60 s (F10: 10 s); args after the name go to the game and win (+bot_quota 16 --map dm_atrium)
#   ./bootstrap.sh --links --copy  copy the addons instead of linking them
#   DOT_NATIVES=none ./bootstrap.sh skip the native libraries a game pins (# bootstrap-natives:); GDScript runs
#   ./bootstrap.sh --ssh           clone over SSH (to push from this machine); HTTPS is the default
#   ./bootstrap.sh --only arena,wipeout   only these, plus the addon and map repos they need
#   ./bootstrap.sh --no-stores              skip the raw art stores (about 1.6 GB, fetched once and kept); maps draw low-detail art
#   ./bootstrap.sh --only 'mg-*' --no-deps  only these, and nothing they need
#   ./bootstrap.sh --jobs N              repositories synced and games imported at once (default: the CPU count; DOT_JOBS; 1 = one at a time)
#   ./bootstrap.sh --import              import every game headless (the editor can crash on a first import); --only narrows it
#   ./bootstrap.sh --get-godot          download the latest stable Godot into .godot-bin beside this script; with --import, a selection or --discard-generated it carries on (sync, link, then import)
#   ./bootstrap.sh --discard-generated   when an update is blocked, restore every modified .import/.uid file and retry
#   ./bootstrap.sh game-fatal-contact mg-wipeout    the same as --only (names, short forms, globs)
#   ./bootstrap.sh --games arena,wipeout --addons dot-core   games and/or addons by kind
#   ./bootstrap.sh zees-games               every game, with the addons and content it needs
#   ./bootstrap.sh --zees-games-min         every game, base repository + addons only
#   ./bootstrap.sh mg-wipeout --min         --min: no maps, weapon, monster or other content packs
#   ./bootstrap.sh --plan [selection]       print what would be cloned and linked, change nothing
#
# --only works with every mode (sync, --links, --status). A name is a project
# from projects.tsv, or its short form (fatal-contact = game-fatal-contact, wipeout =
# mg-wipeout, core = dot-core), or another name projects.tsv lists for it, old names
# included (arena and game-arena = game-fatal-contact, g2gfast = game-airdrift,
# playground = game-playlot, arena-weapons = fc-weapons), or a glob. A sync moves a
# checkout still under an old name to the new one (see "Renamed checkouts"). Set DOT_ONLY to make a selection stick. Addons
# are linked (or copied) into the named projects only. Selecting a game also selects
# the addons it requires and the content it links (maps, courses, optional weapon and
# monster packs) unless --min. With no selection at all, EVERYTHING is cloned and linked.
#
# WHERE IT PUTS THINGS
#
# A fresh clone of this repository on its own clones everything into
# ./projects, beside this script, and that directory is gitignored. Nothing
# else is needed: clone this, run it, play a game.
#
# It also recognises the layout it was born in, where this repository sits at
# godot/bootstrap inside the game-dev tree and its siblings are the projects.
# Then it uses that godot/ directory rather than making a second copy of
# everything. Override either with DOT_PROJECTS=/some/where.
#
# Clone from somewhere else:  DOT_GIT_BASE=git@gitlab.example/mine ./bootstrap.sh
# Also add a second remote called `hub` (bare repos on a dev box):
#   DOTHUB=ssh://you@10.50.0.185/home/you/git ./bootstrap.sh
#
# WHY THIS SCRIPT EXISTS AT ALL
#
# Each project is its own repository, deliberately: an addon is consumed by
# copying its addons/<name>/ folder, and nothing should be able to clone the
# whole family as one unit and take a dependency on that shape. The cost of
# that rule is fifty-odd clones and getting on for three hundred links to set up
# by hand on every machine, which is exactly the sort of thing nobody does
# correctly twice. Both numbers grow every time the family does, which is the
# other reason neither of them is written down anywhere a person maintains.
#
# WHY THERE ARE NO LISTS IN THIS FILE
#
# The version of this script that this one replaces carried its own manifest of
# projects AND of the addons each one needs. Both went stale: it listed 19 of
# the 33 repositories, and the fourteen it had lost included game-playground
# and game-g2gfast -- two of the five games -- and the whole movement and NPC
# half of the family. That is this family's most-repeated bug, and it has now
# happened to setup.sh, to tools/check.sh, to tools/package_check.sh and here.
#
# So neither list lives here:
#
#   * The projects come from projects.tsv, one file both this and bootstrap.ps1
#     read. `--check` fails if it disagrees with what is on the disk.
#   * The addons each project needs are read out of that project's OWN
#     .gitignore, from its /addons/<name> lines. That is the one place that
#     cannot go stale, because the repository that gains a dependency is the
#     repository that has to ignore the link, and Godot will not open without
#     it. There is no second copy to drift.

set -uo pipefail

# Where this was INVOKED from, symlink not resolved: game-dev's tree root keeps
# a bootstrap.sh -> godot/bootstrap/bootstrap.sh symlink for convenience, and
# running that one should mean the tree, not this repository.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the file actually lives, symlink resolved. projects.tsv sits beside it.
REAL_SELF="${BASH_SOURCE[0]}"
while [ -L "$REAL_SELF" ]; do
    _t="$(readlink "$REAL_SELF")"
    case "$_t" in
        /*) REAL_SELF="$_t" ;;
        *)  REAL_SELF="$(dirname "$REAL_SELF")/$_t" ;;
    esac
done
REPO_DIR="$(cd "$(dirname "$REAL_SELF")" && pwd)"

# The directory holding the project repositories, in order of preference.
if [ -n "${DOT_PROJECTS:-}" ]; then
    PROJECTS_DIR="$DOT_PROJECTS"
elif [ -d "$SELF_DIR/godot" ]; then
    # Invoked from a game-dev tree root, almost certainly through the symlink.
    PROJECTS_DIR="$SELF_DIR/godot"
elif { [ "$(basename "$REPO_DIR")" = "dot-bootstrap" ] \
       || [ "$(basename "$REPO_DIR")" = "bootstrap" ]; } \
     && [ "$(basename "$(dirname "$REPO_DIR")")" = "godot" ] \
     && [ -f "$(dirname "$(dirname "$REPO_DIR")")/CLAUDE.md" ]; then
    # This repository is itself a project directory: <tree>/godot/dot-bootstrap.
    #
    # Both leaf names, because this repository was renamed from `bootstrap` and a
    # clone made before that is still a correct clone. A name test that only knows
    # today's name sends an existing checkout down the standalone branch, where it
    # clones the whole family a second time into ./projects and says so in one line
    # nobody has a reason to read -- which is the failure the comment below is about,
    # reached by a rename instead of by a capital letter.
    #
    # All THREE conditions, because the obvious one-condition version of this
    # test -- "is my parent called godot" -- silently ate a real setup. A clone
    # at F:\Godot\tmc-dot-bootstrap has a parent whose leaf is "Godot", and
    # PowerShell's -eq is case-INSENSITIVE, so bootstrap.ps1 matched: everything
    # was cloned to F:\Godot as siblings of the repository instead of into
    # ./projects, and the only sign was one line of output nobody had a reason
    # to read.
    #
    # This `=` is case-sensitive and would NOT have matched the same path, which
    # is worse than either behaviour on its own: one repository laying two
    # machines out differently depending on how a folder happened to be
    # capitalised.
    PROJECTS_DIR="$(dirname "$REPO_DIR")"
else
    # A standalone clone. Everything goes beside this script, and .gitignore
    # already has /projects/ so none of it is ever offered back to this repo.
    PROJECTS_DIR="$REPO_DIR/projects"
fi

LIST="$REPO_DIR/projects.tsv"
[ -f "$LIST" ] || LIST="$SELF_DIR/projects.tsv"

GIT_BASE="${DOT_GIT_BASE:-git@github.com:modcommunity}"
HUB="${DOTHUB:-}"

# Whether to reach GitHub over HTTPS instead of SSH. HTTPS is the default: every
# repository in projects.tsv is public, so HTTPS reads them with no credentials
# on any machine, while SSH fails on every machine without a key -- which is
# most of the ones this script is run on.
#
# --ssh restores SSH for a machine that pushes. It still falls back to HTTPS,
# latched, the first time an SSH clone fails and the HTTPS one works.
#
# An EXISTING clone keeps its origin either way. In HTTPS mode a pull from an
# SSH origin goes over HTTPS for that one command (url.<https>.insteadOf), so a
# keyless machine can update while a machine with a key can still push.
USE_HTTPS=1
HTTPS_NOTED=0

# git@host:path  ->  https://host/path
# ssh://git@host/path -> https://host/path
# Anything else is returned unchanged, so a local path or an existing https URL
# passes straight through.
to_https() {
    local u="$1" host path
    case "$u" in
        ssh://*) u="${u#ssh://}"; printf 'https://%s\n' "${u#*@}" ;;
        *@*:*)   host="${u%%:*}"; host="${host#*@}"; path="${u#*:}"
                 printf 'https://%s/%s\n' "$host" "$path" ;;
        *)       printf '%s\n' "$u" ;;
    esac
}

note_https() {
    [ "$HTTPS_NOTED" = "1" ] && return 0
    HTTPS_NOTED=1
    echo
    echo "${YLW}SSH to GitHub is not available here, so this is falling back to HTTPS.${OFF}"
    echo "${YLW}The Dot assets are public, so cloning and pulling need no credentials.${OFF}"
    echo "${YLW}Pushing does: these clones get an https:// origin, and a push over it${OFF}"
    echo "${YLW}wants a personal access token rather than your key. Add an SSH key to${OFF}"
    echo "${YLW}GitHub to get one you can push from.${OFF}"
    echo
}

# `git -c ...` arguments that send one command over HTTPS when origin is SSH.
# Nothing is printed when it is not, or when HTTPS mode is off.
https_for() {
    [ "$USE_HTTPS" = "1" ] || return 0
    local origin="$1" prefix
    case "$origin" in
        ssh://*) prefix="${origin#ssh://}"; prefix="ssh://${prefix%%/*}/" ;;
        *@*:*)   prefix="${origin%%:*}:" ;;
        *)       return 0 ;;
    esac
    printf '%s\n' -c "url.$(to_https "$prefix").insteadOf=$prefix"
}

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; DIM=$'\033[2m'; OFF=$'\033[0m'
fail=0

say()  { printf '%-22s %s\n' "$1" "$2"; }
ok()   { printf '%-22s %s\n' "$1" "${GRN}$2${OFF}"; }
warn() { printf '%-22s %s\n' "$1" "${YLW}$2${OFF}"; }
err()  { printf '%-22s %s\n' "$1" "${RED}$2${OFF}"; fail=1; }
# Every repository a sync could not bring up to date, listed again at the very end, so one
# line among dozens of parallel jobs' output is not the only trace. Jobs run in subshells,
# so they append to a file.
STALE_FILE="$(mktemp 2>/dev/null || echo /tmp/dot-stale.$$)"; : > "$STALE_FILE"
trap 'rm -f "$STALE_FILE"' EXIT
note_stale() { printf '%-22s %s\n' "$1" "$2" >> "$STALE_FILE"; }
# A credential prompt in one of many parallel jobs is a hang nobody sees: a private or
# missing repository fails at once instead.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"

[ -f "$LIST" ] || { echo "${RED}missing projects.tsv beside $REAL_SELF${OFF}" >&2; exit 2; }

# name<TAB>url, comments and blank lines dropped.
projects() { grep -v '^[[:space:]]*#' "$LIST" | grep -v '^[[:space:]]*$' | cut -f1; }
url_for()  { grep -v '^[[:space:]]*#' "$LIST" | awk -F'\t' -v p="$1" '$1==p{print $2; exit}'; }
# The listed name an other name (third column) stands for: fatal-contact -> game-arena.
alias_target() {
    grep -v '^[[:space:]]*#' "$LIST" | awk -F'\t' -v a="$1" \
        '{ n = split($3, x, ","); for (i = 1; i <= n; i++) if (x[i] == a) { print $1; exit } }'
}
# Every listed name with each of its other names: "fc-weapons<TAB>arena-weapons".
alias_pairs() {
    grep -v '^[[:space:]]*#' "$LIST" | awk -F'\t' \
        '{ n = split($3, x, ","); for (i = 1; i <= n; i++) if (x[i] != "") print $1 "\t" x[i] }'
}
# The listed name for a name that may be an old one: arena-weapons -> fc-weapons. A name
# that is neither listed nor another name comes back unchanged. Games' .gitignore lines
# (/addons/arena_weapons, "# bootstrap-link: g2gfast-maps/maps") still say the old names,
# so the addon rule and the content links go through this.
canon() {
    projects | grep -qxF "$1" && { echo "$1"; return; }
    local p; p="$(alias_target "$1")"; echo "${p:-$1}"
}
# The folder a name is on disk under: the listed name, unless only the old one is there
# (a checkout whose move migrate_renamed refused, see below).
on_disk() {
    local c; c="$(canon "$1")"
    [ ! -e "$PROJECTS_DIR/$c" ] && [ "$c" != "$1" ] && [ -d "$PROJECTS_DIR/$1" ] && c="$1"
    echo "$c"
}
# The same for a path whose first part is a project: g2gfast-maps/maps -> airdrift-maps/maps.
canon_path() { local h="${1%%/*}"; printf '%s%s\n' "$(on_disk "$h")" "${1#"$h"}"; }
# owner/repo of a GitHub URL, SSH or HTTPS, so the two forms compare equal.
repo_path() { printf '%s' "$1" | sed -e 's#^git@github.com:##' -e 's#^https://github.com/##' -e 's#\.git$##'; }
# A repository GitHub does not have is a renamed or deleted one, never a passing
# network fault: say so in red, name the line to fix, and fail the run.
missing_repo() {
    err "$1" "REPOSITORY MISSING: $2 does not exist (renamed or deleted?). Fix its line in projects.tsv."
}

# The addons a project needs linked in, read out of its own .gitignore. A
# project's own addon is never in there -- dot-net ignores dot_core and ships
# dot_net -- which is exactly the distinction wanted.
links_for() {
    local gi; gi="$(gi_path "$1")"
    [ -f "$gi" ] || return 0
    # /addons/ on its own means "ignore the lot" (dot-server-deploy vendors
    # its addons with setup.sh) and names nothing to link.
    local all; all="$(grep -oE '^/addons/[a-z0-9_]+$' "$gi" 2>/dev/null | sed 's|^/addons/||')"
    if [ "$MIN" = "1" ]; then
        local opt; opt="$(optional_for "$1")"
        [ -n "$opt" ] && { grep -vxF "$opt" <<< "$all"; return 0; }
    fi
    [ -n "$all" ] && printf '%s\n' "$all"
    return 0
}

# A project's .gitignore: its checkout, else (for --plan) the one in PLAN_FROM.
gi_path() {
    if [ -f "$PROJECTS_DIR/$1/.gitignore" ]; then echo "$PROJECTS_DIR/$1/.gitignore"
    elif [ -n "$PLAN_FROM" ]; then
        # A tree whose checkouts still have their old names (dev02's game-arena).
        local o
        [ -f "$PLAN_FROM/$1/.gitignore" ] || while IFS=$'\t' read -r _ o; do
            [ -n "$o" ] && [ -f "$PLAN_FROM/$o/.gitignore" ] && { echo "$PLAN_FROM/$o/.gitignore"; return; }
        done <<< "$(alias_pairs | awk -F'\t' -v n="$1" '$1 == n')"
        echo "$PLAN_FROM/$1/.gitignore"
    else echo "$PROJECTS_DIR/$1/.gitignore"; fi
}

# Addons a project marks optional (a weapon or monster pack it runs without): a
# "# bootstrap-optional" comment line directly above the /addons/<name> line.
optional_for() {
    local gi; gi="$(gi_path "$1")"
    [ -f "$gi" ] || return 0
    awk '/^# bootstrap-optional/{o=1; next} o && /^\/addons\//{sub("^/addons/",""); print} {o=0}' "$gi"
}

# Which repository an addon comes from. dot_user_avatar -> dot-user-avatar covers every
# dot-* addon, but not a game's own pack: zee_weapons lives in zee-dot-weapons, and the
# name rule sent every game that used it looking for a zee-weapons nobody has. Rather
# than a table of exceptions, ask the checkouts: the owner is the project that HAS the
# folder and does not ignore it -- every consumer ignores it, linked or copied, and
# dot-server-deploy, which vendors a copy of everything, ignores /addons/ whole.
addon_source() {
    local addon="$1" src="${1//_/-}" d
    # The listed name first (arena_weapons is in fc-weapons), then the raw one: a machine
    # whose checkout has not been renamed yet still has it under arena-weapons.
    d="$(canon "$src")"
    if [ -d "$PROJECTS_DIR/$d/addons/$addon" ]; then echo "$d"; return 0; fi
    if [ -d "$PROJECTS_DIR/$src/addons/$addon" ]; then echo "$src"; return 0; fi
    for d in "$PROJECTS_DIR"/*/; do
        d="${d%/}"
        # An old-name link left by a rename (see migrate_renamed) is not a second owner.
        [ -L "$d" ] && continue
        [ -d "$d/addons/$addon" ] && [ -d "$d/.git" ] || continue
        # Git's own answer, not a line match: dot-server-deploy ignores /addons/ whole.
        git -C "$d" check-ignore -q "addons/$addon" && continue
        echo "${d##*/}"; return 0
    done
    echo "$src"
}

# --- Selecting -------------------------------------------------------------
#
# --only names projects; what each one NEEDS comes from the same place the links
# do -- its .gitignore -- so the selection holds no list either. That means the
# needs of a project are only known once it is cloned, which is why a sync walks
# them as a queue (clone, read, enqueue what it names) rather than working the set
# out first.

ONLY=()
NO_DEPS=0
# Repositories synced and games imported at once; --jobs N, DOT_JOBS, else the CPU count.
JOBS="${DOT_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
DISCARD_GEN=0
# --min: leave out content (maps, courses, worlds) and the optional packs a game marks
# with "# bootstrap-optional" above their /addons/ line.
MIN=0
PLAN=0
# --plan reads a project's .gitignore from here when it is not cloned yet.
PLAN_FROM="${DOT_PLAN_FROM:-}"

listed() { projects | grep -qxF "$1"; }

# A name as typed -> the projects it means, or nothing.
resolve_name() {
    local n="$1" p
    case "$n" in
        zees-games|games) games; return ;;
        addons)           projects | grep -E '^dot-'; return ;;
    esac
    case "$n" in
        *[*?[]*) projects | while read -r p; do [[ "$p" == $n ]] && echo "$p"; done; return ;;
    esac
    for p in "$n" "game-$n" "mg-$n" "dot-$n"; do listed "$p" && { echo "$p"; return; }; done
    p="$(alias_target "$n")"; [ -n "$p" ] && echo "$p"
}

# The listed repository an addon comes from, clone or no clone. The name rule first;
# then a checkout that owns it; then the listed name it matches with every "dot-"
# taken out -- zee_weapons is zee-dot-weapons -- which is unambiguous because no two
# names in projects.tsv are equal that way (`--check`'s neighbour, measured 10-07).
addon_repo() {
    local src p
    src="$(canon "${1//_/-}")"
    listed "$src" && { echo "$src"; return; }
    p="$(addon_source "$1")"; listed "$p" && [ -d "$PROJECTS_DIR/$p/addons/$1" ] && { echo "$p"; return; }
    projects | while read -r p; do [ "${p//dot-/}" = "${src//dot-/}" ] && { echo "$p"; break; }; done
}

# What a project needs on disk beside it: the repositories of its addons, and of any
# content directory its .gitignore names with "# bootstrap-link:".
deps_of() {
    local a src path
    while read -r a; do [ -n "$a" ] && addon_repo "$a"; done <<< "$(links_for "$1")"
    while IFS=$'\t' read -r path src; do
        [ -n "$src" ] && src="$(canon "${src%%/*}")" && listed "$src" && echo "$src"
    done <<< "$(content_links_for "$1")"
}

# Every project when nothing was selected; otherwise the selection, plus (unless
# --no-deps) everything it needs that is already on disk, in projects.tsv order.
# A sync calls sync_selected instead, which clones as it goes.
selected() {
    [ ${#ONLY[@]} -eq 0 ] && { projects; return; }
    local -A seen=(); local queue=("${ONLY[@]}") p d
    while [ ${#queue[@]} -gt 0 ]; do
        p="${queue[0]}"; queue=("${queue[@]:1}")
        [ -n "${seen[$p]:-}" ] && continue
        seen[$p]=1
        [ "$NO_DEPS" = "1" ] && continue
        while read -r d; do [ -n "$d" ] && queue+=("$d"); done <<< "$(deps_of "$p")"
    done
    projects | while read -r p; do [ -n "${seen[$p]:-}" ] && echo "$p"; done
}

# Where links go. With a selection, only into what was NAMED: the repositories pulled
# in for it are sources to copy from, and filling their own addons/ folders too would
# be most of the work and, under --copy, most of the disk.
link_targets() {
    [ ${#ONLY[@]} -eq 0 ] && { projects; return; }
    printf '%s\n' "${ONLY[@]}"
}

# Runs "$1 item" for every remaining argument, at most JOBS at once. Each job's output is
# printed in one piece when it ends, so lines from different repositories never interleave,
# and a job that reports an error makes the whole run report one.
par_each() {
    local fn="$1"; shift
    if [ "$JOBS" -le 1 ] || [ $# -le 1 ]; then local x; for x in "$@"; do "$fn" "$x"; done; return; fi
    local tmp; tmp="$(mktemp -d)"; local x i=0
    for x in "$@"; do
        i=$((i+1))
        while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
        # Into a file, not $(...): a command substitution is one more subshell, and the
        # fail=1 an err() sets in there never reached the marker, so a parallel sync
        # whose clone or pull failed still finished "ok".
        ( fail=0; "$fn" "$x" > "$tmp/$i.out" 2>&1; [ -s "$tmp/$i.out" ] && cat "$tmp/$i.out"; [ "$fail" = 0 ] || : > "$tmp/$i.failed" ) &
    done
    wait
    compgen -G "$tmp/*.failed" >/dev/null && fail=1
    rm -rf "$tmp"
}

sync_selected() {
    if [ ${#ONLY[@]} -eq 0 ]; then
        local all=(); mapfile -t all < <(projects)
        par_each sync_repo "${all[@]}"; return
    fi
    # Dependencies are only known once a project is on disk, so it goes in waves: sync
    # everything queued, read what each one names, queue what is new.
    local -A seen=(); local wave=("${ONLY[@]}") next p d
    while [ ${#wave[@]} -gt 0 ]; do
        local batch=()
        for p in "${wave[@]}"; do [ -n "${seen[$p]:-}" ] && continue; seen[$p]=1; batch+=("$p"); done
        [ ${#batch[@]} -eq 0 ] && break
        par_each sync_repo "${batch[@]}"
        next=()
        if [ "$NO_DEPS" != "1" ]; then
            for p in "${batch[@]}"; do
                while read -r d; do [ -n "$d" ] && next+=("$d"); done <<< "$(deps_of "$p")"
            done
        fi
        wave=("${next[@]+"${next[@]}"}")
    done
}

# --- Repositories ----------------------------------------------------------

# True when git's output says the network failed (no route, DNS, a connect timeout, a
# dropped connection), not the repository: a missing, private or refused one is never
# retried as if it were the network.
net_error() {
    printf '%s' "$1" | grep -qiE 'repository not found|does not exist|returned error: 40[0-9]|authentication failed|could not read username|permission denied' && return 1
    printf '%s' "$1" | grep -qiE 'could not resolve (host|hostname)|failed to connect|couldn.t connect|connection (timed out|reset|refused|closed)|operation timed out|timed out after|network is unreachable|no route to host|name or service not known|temporary failure in name resolution|early eof|rpc failed|remote end hung up|unexpected disconnect|ssl_(read|connect|error)|gnutls|connect to host .* port [0-9]+'
}

# `git pull --ff-only`, tried up to 3 times while it fails on the network (backoff 3 s,
# then 8 s), with a short SSH connect timeout and a stall limit on HTTPS so one dead route
# costs seconds, not minutes. Sets pull_err, pull_rc, pull_tries, pull_net (1 = network).
pull_retry() {
    local dir="$1"; shift
    local fast=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20)
    if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "${GIT_SSH:-}" ] && [ -z "$(git -C "$dir" config --get core.sshCommand 2>/dev/null)" ]; then
        fast+=(-c "core.sshCommand=ssh -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3")
    fi
    local wait_s
    pull_tries=0; pull_net=0
    for wait_s in 0 3 8; do
        [ "$wait_s" -gt 0 ] && sleep "${DOT_RETRY_SLEEP:-$wait_s}"
        pull_tries=$((pull_tries+1))
        pull_err="$(git "$@" "${fast[@]}" -C "$dir" pull -q --no-rebase --ff-only 2>&1 >/dev/null)"; pull_rc=$?
        [ $pull_rc -eq 0 ] && break
        net_error "$pull_err" || break
    done
    [ $pull_rc -ne 0 ] && net_error "$pull_err" && pull_net=1
    return 0
}

# A pull that failed for a reason other than the network or local edits: diverged from its
# upstream, no upstream, an upstream branch deleted on origin, or a detached HEAD. Moves
# the checkout onto origin without losing anything: commits found on no origin branch go
# to a bootstrap-backup/<time> branch first, uncommitted edits to tracked files into a
# stash named bootstrap-backup-<time> (re-applied after; kept there on a conflict),
# untracked files are never overwritten (reset --keep and checkout refuse). A branch with
# no upstream that exists on origin gets that upstream; any other is left as it is and the
# checkout goes to origin's default branch. Returns 0 when the checkout is on origin.
repair_checkout() {
    local proj="$1" dir="$2"; shift 2
    git "$@" -C "$dir" fetch -q --prune origin >/dev/null 2>&1 || return 1
    local def; def="$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)"
    if [ -z "$def" ]; then
        git "$@" -C "$dir" remote set-head origin -a >/dev/null 2>&1
        def="$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)"
    fi
    if [ -z "$def" ]; then
        local b; for b in main master; do
            git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 && { def="origin/$b"; break; }
        done
    fi
    [ -n "$def" ] || return 1
    local def_name="${def#origin/}"
    local branch; branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)"
    local up; up="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
    [ -n "$up" ] && ! git -C "$dir" rev-parse -q --verify "$up" >/dev/null 2>&1 && up=""
    local on_origin=0
    [ -n "$branch" ] && git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null 2>&1 && on_origin=1

    local why target switch=0
    if [ -z "$branch" ];     then why="detached HEAD"; target="$def"; switch=1
    elif [ -n "$up" ];       then why="diverged from $up"; target="$up"
    elif [ $on_origin = 1 ]; then why="no upstream"; target="origin/$branch"
    else why="local branch $branch has no upstream"; target="$def"; switch=1; fi

    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    local notes=() keep=(HEAD)
    if [ $switch = 1 ]; then
        git -C "$dir" rev-parse -q --verify "refs/heads/$def_name" >/dev/null 2>&1 && keep+=("refs/heads/$def_name")
        [ -n "$branch" ] && keep=("${keep[@]:1}")   # the branch itself keeps them
    fi
    local backups=() ref n name
    for ref in "${keep[@]}"; do
        n="$(git -C "$dir" rev-list --count "$ref" --not --remotes=origin 2>/dev/null)"
        [ "${n:-0}" -gt 0 ] || continue
        if [ "$ref" = HEAD ]; then name="bootstrap-backup/$stamp"; else name="bootstrap-backup/$stamp-$def_name"; fi
        git -C "$dir" branch -q "$name" "$ref" >/dev/null 2>&1 || return 1
        backups+=("$name"); notes+=("$n local commit(s) kept on branch $name")
    done
    local stash=""
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        stash="bootstrap-backup-$stamp"
        git -C "$dir" stash push -q -m "$stash" >/dev/null 2>&1 || { for n in "${backups[@]}"; do git -C "$dir" branch -q -D "$n" >/dev/null 2>&1; done; return 1; }
    fi
    local moved=0
    if [ $switch = 1 ]; then
        if git -C "$dir" checkout -q -B "$def_name" "$def" >/dev/null 2>&1; then
            moved=1; git -C "$dir" branch -q "--set-upstream-to=$def" "$def_name" >/dev/null 2>&1
            [ -n "$branch" ] && notes+=("branch $branch left as it was")
        fi
    elif git -C "$dir" reset -q --keep "$target" >/dev/null 2>&1; then
        moved=1; [ -z "$up" ] && git -C "$dir" branch -q "--set-upstream-to=$target" >/dev/null 2>&1
    fi
    if [ -n "$stash" ]; then
        if ! git -C "$dir" stash pop -q >/dev/null 2>&1; then
            git -C "$dir" reset -q --merge >/dev/null 2>&1
            notes+=("uncommitted edits conflict with it, kept in stash '$stash'")
        elif [ $moved = 1 ]; then notes+=("uncommitted edits re-applied"); fi
    fi
    if [ $moved = 0 ]; then
        for n in "${backups[@]}"; do git -C "$dir" branch -q -D "$n" >/dev/null 2>&1; done
        return 1
    fi
    local tail="" i
    for i in "${!notes[@]}"; do tail+="; ${notes[$i]}"; done
    warn "$proj" "${why}: moved to $target$tail"
    return 0
}

# The pull was refused because tracked files are modified here. Line-ending-only changes are
# discarded; real edits are stashed, the pull retried, the stash re-applied (it stays saved
# when that conflicts). Returns 0 when the pull went through.
resolve_blocked_pull() {
    local proj="$1" dir="$2" err="$3"; shift 3; local net=("$@")
    local tracked=() f
    while IFS= read -r f; do
        [ -n "$f" ] && git -C "$dir" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && tracked+=("$f")
    done < <(printf '%s\n' "$err" | sed -n 's/^[[:space:]]\{1,\}\([^[:space:]].*\)$/\1/p' | grep -v '^Please\|^Aborting\|^error')
    if [ ${#tracked[@]} -eq 0 ]; then
        while IFS= read -r f; do [ -n "$f" ] && tracked+=("$f"); done < <(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null | sed 's/^...//')
    fi
    [ ${#tracked[@]} -eq 0 ] && return 1
    local real=()
    for f in "${tracked[@]}"; do
        if git -C "$dir" diff HEAD --ignore-space-at-eol --ignore-cr-at-eol --quiet -- "$f" 2>/dev/null; then
            git -C "$dir" restore --staged --worktree -- "$f" 2>/dev/null
            say "$proj" "${DIM}$f: line endings only, discarded${OFF}"
        else real+=("$f"); fi
    done
    git "${net[@]}" -C "$dir" pull -q --no-rebase --ff-only >/dev/null 2>&1 && return 0
    [ ${#real[@]} -eq 0 ] && return 1
    git -C "$dir" stash push -q -m bootstrap-autostash -- "${real[@]}" >/dev/null 2>&1 || return 1
    local pulled=1
    git "${net[@]}" -C "$dir" pull -q --no-rebase --ff-only >/dev/null 2>&1 && pulled=0
    if git -C "$dir" stash pop -q >/dev/null 2>&1; then
        [ $pulled -eq 0 ] && say "$proj" "${GRN}stashed ${#real[@]} file(s) (${real[*]}), updated, reapplied${OFF}"
        return $pulled
    fi
    git -C "$dir" reset -q --merge >/dev/null 2>&1
    warn "$proj" "local edits to ${real[*]} conflict with the update and are kept in the stash 'bootstrap-autostash' (inspect: git -C '$dir' stash show -p)"
    return $pulled
}

# --- Renamed checkouts -----------------------------------------------------
#
# A repository renamed on GitHub is listed under its new name, and its checkout is
# moved to that name, so that what is on disk and what this prints are the names the
# repositories have (a laptop said "game-playground-maps cloned" for playlot-maps).
# The old names stay in projects.tsv's third column, so they keep selecting it.
#
# The move happens only when it is safe: the old directory is a real checkout (not a
# link, not a linked worktree) of this project, the new name is free, and no process
# is working in it. A dirty tree moves as it is -- a rename touches no file in it.
# Afterwards every link beside the projects that went through the old name (a game's
# addons/arena_weapons, maps/imported) is pointed at the new one, linked worktrees are
# repaired, and the old name is left as a link to the new one, so a path written
# somewhere this cannot see (another worktree's link, a script, an editor's project
# list) still arrives. Delete that link once nothing uses the old name.
#
# When the move is refused the checkout stays under its old name and the new one is
# NOT cloned beside it: a second copy is how work ends up in the wrong one. DOT_NO_RENAME=1
# refuses every move (a machine whose running jobs use the old paths).
declare -A KEPT_OLD=()

# A process whose working directory or command line is inside <dir>; prints its pid.
in_use_by() {
    local d="$1" phys p cwd
    [ -d /proc/self ] || return 1
    phys="$(cd "$d" 2>/dev/null && pwd -P)" || phys="$d"
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        cwd="$(readlink "$p/cwd" 2>/dev/null)" || cwd=""
        case "$cwd/" in "$d"/*|"$phys"/*) echo "${p#/proc/}"; return 0 ;; esac
        [ -r "$p/cmdline" ] || continue
        if tr '\0' '\n' < "$p/cmdline" 2>/dev/null | awk -v a="$d" -v b="$phys" '
                { for (k = 1; k <= 2; k++) { x = (k == 1 ? a : b)
                    if ($0 == x || index($0, x "/") || substr($0, length($0) - length(x)) == "=" x) f = 1 } }
                END { exit !f }'; then
            echo "${p#/proc/}"; return 0
        fi
    done
    return 1
}

# Every link under the projects (to a few levels: addons/x, maps/imported, content/x/y)
# that the move of <old> left pointing nowhere is pointed through <new> instead -- only
# when the new target is really there, so nothing that was fine is touched.
relink_moved() {
    local old="$1" new="$2" l t nt
    while IFS= read -r -d '' l; do
        [ -e "$l" ] && continue
        t="$(readlink "$l")" || continue
        case "/$t/" in */"$old"/*) ;; *) continue ;; esac
        nt="$(printf '%s' "$t" | awk -v o="$old" -v n="$new" '{
            m = split($0, x, "/"); s = ""; done = 0
            for (i = 1; i <= m; i++) { if (!done && x[i] == o) { x[i] = n; done = 1 } s = s (i > 1 ? "/" : "") x[i] }
            print s }')"
        case "$nt" in /*) [ -e "$nt" ] ;; *) [ -e "$(dirname "$l")/$nt" ] ;; esac || continue
        ln -sfn "$nt" "$l" && say "${l#"$PROJECTS_DIR"/}" "${DIM}relinked -> $nt${OFF}"
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 5 \( -name .git -o -name .godot -o -name node_modules \) -prune -o -type l -print0 2>/dev/null)
}

migrate_renamed() {
    local new old src dst url origin pid why n
    while IFS=$'\t' read -r new old; do
        [ -n "$old" ] && [ "$old" != "$new" ] || continue
        src="$PROJECTS_DIR/$old"; dst="$PROJECTS_DIR/$new"
        # Only a real directory; an alias like "fc" or "playlot" is never one here.
        [ -d "$src" ] && [ ! -L "$src" ] || continue
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            [ -L "$dst" ] || warn "$new" "an old checkout is still at $old beside it; left alone (move anything you need out of it, then delete it)"
            continue
        fi
        why=""
        if [ ! -d "$src/.git" ]; then
            why="$old is not a main git checkout"
        else
            url="$(url_for "$new")"; origin="$(git -C "$src" remote get-url origin 2>/dev/null)"
            # This project's checkout: origin is the new repository, or one of its old names.
            n="$(basename "$(repo_path "$origin")")"
            if [ "$(repo_path "$origin")" != "$(repo_path "$url")" ] && [ "$n" != "$new" ] && [ "$(alias_target "$n")" != "$new" ]; then
                why="$old's origin is $origin, not $new"
            elif [ "${DOT_NO_RENAME:-}" = 1 ]; then
                why="DOT_NO_RENAME=1"
            elif pid="$(in_use_by "$src")"; then
                why="in use by process $pid ($(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-60))"
            fi
        fi
        if [ -n "$why" ]; then
            # Something else under the old name: not this checkout, so the new one is cloned.
            case "$why" in *"not a main git checkout"|*"'s origin is "*) warn "$old" "left alone: $why"; continue ;; esac
            KEPT_OLD[$new]="$old"
            warn "$new" "still at its old name $old, not renamed: $why. Run again once that is fixed."
            continue
        fi
        mv -n "$src" "$dst" 2>/dev/null
        if [ ! -d "$dst" ] || { [ -e "$src" ] && [ ! -L "$src" ]; }; then
            KEPT_OLD[$new]="$old"
            err "$new" "could not move $old to $new; it is still at $old"
            continue
        fi
        git -C "$dst" worktree repair >/dev/null 2>&1 || true
        relink_moved "$old" "$new"
        ln -s "$new" "$src" 2>/dev/null || true
        n=$(git -C "$dst" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        ok "$new" "renamed from $old$([ "$n" -gt 0 ] && echo " (with its $n uncommitted file(s))"); $old is now a link to it"
    done <<< "$(alias_pairs)"
}

sync_repo() {
    local proj="$1"; local dir="$PROJECTS_DIR/$proj"; local url; url="$(url_for "$proj")"

    if [ -n "${KEPT_OLD[$proj]:-}" ]; then
        warn "$proj" "not cloned: the checkout is still at ${KEPT_OLD[$proj]} (see above)"
        return
    fi

    if [ ! -d "$dir/.git" ]; then
        if [ "$url" = "LOCAL" ]; then
            err "$proj" "has no remote -- it exists only on the machine that made it"
            return
        fi
        local effective="$url"
        [ "$USE_HTTPS" = "1" ] && effective="$(to_https "$url")"

        # One retry over HTTPS, then latch it on for every remaining project so
        # this costs one failed connection rather than thirty-six.
        if [ "$USE_HTTPS" != "1" ]; then
            local alt; alt="$(to_https "$url")"
            if [ "$alt" != "$url" ] && ! git ls-remote --exit-code -h "$url" >/dev/null 2>&1 \
               && git ls-remote --exit-code -h "$alt" >/dev/null 2>&1; then
                USE_HTTPS=1
                note_https
                effective="$alt"
            fi
        fi

        local clone_err
        if clone_err="$(git clone -q "$effective" "$dir" 2>&1 >/dev/null)"; then
            # A repository created on GitHub and never pushed to clones fine and
            # has no HEAD, so rev-parse fails. Say so rather than leaking its
            # "fatal: Needed a single revision" to the terminal.
            local at; at="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
            say "$proj" "${GRN}cloned${OFF} ${at:-${YLW}empty — nothing pushed to it yet${OFF}}"
            [ -n "$HUB" ] && git -C "$dir" remote add hub "$HUB/$proj.git" 2>/dev/null
        elif printf '%s' "$clone_err" | grep -qiE 'repository not found|not found|does not exist'; then
            missing_repo "$proj" "$effective"
        else
            err "$proj" "clone failed from $effective"
        fi
        return
    fi

    if [ "$url" = "LOCAL" ]; then
        warn "$proj" "no remote; nothing to pull. Push it or it stays on this machine."
        return
    fi

    # Never clobber work in progress: any machine may hold the only copy. A
    # dirty tree is still pulled, because `pull --ff-only` without --autostash
    # is already safe: git refuses, touching nothing, when an incoming commit
    # changes a file that is modified here or would overwrite an untracked one.
    # Skipping every dirty tree left a project behind over a few
    # editor-rewritten .import files nobody meant to keep.
    local dirty; dirty=$(git -C "$dir" status --porcelain | wc -l)
    local origin; origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"
    # A repository renamed on GitHub: the list names the new one, this checkout
    # still the old. GitHub's redirect is not to be relied on, so repoint it,
    # keeping the SSH or HTTPS form the checkout already uses.
    if [ -n "$origin" ] && [ "$(repo_path "$origin")" != "$(repo_path "$url")" ]; then
        local moved="$url"
        case "$origin" in https://*) moved="$(to_https "$url")" ;; esac
        git -C "$dir" remote set-url origin "$moved"
        say "$proj" "${YLW}origin moved${OFF} $(repo_path "$origin") -> $(repo_path "$url")"
        origin="$moved"
    fi
    local net=(); mapfile -t net < <(https_for "$origin")

    # A clone of a repository that had nothing pushed to it yet has no HEAD, and
    # pulling into it fails with "no such ref was fetched" until somebody pushes.
    # That is not an error on this machine, so it is not reported as one.
    local before; before=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    if [ -z "$before" ] && [ -z "$(git "${net[@]}" -C "$dir" ls-remote --heads origin 2>/dev/null)" ]; then
        warn "$proj" "empty — nothing pushed to it yet"
        return
    fi

    local pull_err pull_rc pull_tries pull_net
    pull_retry "$dir" "${net[@]}"
    # Editor-regenerated files (.uid, .import) block an update whenever the editor
    # rewrote them. They are rebuilt on open, so restore them and retry.
    if [ $pull_rc -ne 0 ] && printf '%s' "$pull_err" | grep -q 'would be overwritten'; then
        local gen; gen="$(printf '%s\n' "$pull_err" | sed -n 's/^[[:space:]]\{1,\}\([^[:space:]].*\)$/\1/p' | grep -v '^Please\|^Aborting\|^error')"
        if [ -n "$gen" ] && ! printf '%s\n' "$gen" | grep -qvE '\.(uid|import)$'; then
            printf '%s\n' "$gen" | while IFS= read -r f; do if git -C "$dir" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then git -C "$dir" checkout -- "$f" 2>/dev/null; else rm -f "$dir/$f"; fi; done
            pull_err="$(git "${net[@]}" -C "$dir" pull -q --no-rebase --ff-only 2>&1 >/dev/null)"; pull_rc=$?
        fi
    fi
    # A tag moved upstream: git refuses to overwrite the local one.
    if [ $pull_rc -ne 0 ] && printf '%s' "$pull_err" | grep -qE 'would clobber existing tag|already exists'; then
        git "${net[@]}" -C "$dir" fetch -q --tags --force >/dev/null 2>&1
        pull_err="$(git "${net[@]}" -C "$dir" pull -q --no-rebase --ff-only 2>&1 >/dev/null)"; pull_rc=$?
    fi
    # Upstream history was rewritten (an amended commit): the local commits are the
    # old copies. Keep them on a backup branch, move to upstream, keep uncommitted
    # work (--keep refuses rather than overwrite it).
    if [ $pull_rc -ne 0 ] && printf '%s' "$pull_err" | grep -qE 'Not possible to fast-forward|divergent'; then
        local up; up=$(git -C "$dir" rev-parse '@{u}' 2>/dev/null)
        if [ -n "$up" ]; then
            local backup="bootstrap-backup/$(date +%Y%m%d-%H%M%S)"
            git -C "$dir" branch "$backup" HEAD 2>/dev/null
            if git -C "$dir" reset -q --keep "$up" 2>/dev/null; then
                pull_rc=0
                local n; n=$(git -C "$dir" rev-list --count "$up..$backup")
                [ "$n" -gt 0 ] && warn "$proj" "diverged from upstream (local commits, or history rewritten there): moved to it; $n local commit(s) kept on branch $backup"
            else
                git -C "$dir" branch -D "$backup" >/dev/null 2>&1
            fi
        fi
    fi
    # --discard-generated: the automatic restore above only fires when git names
    # nothing but .import/.uid files. Here every modified one goes, whatever git named.
    if [ $pull_rc -ne 0 ] && [ "$DISCARD_GEN" = "1" ] && printf '%s' "$pull_err" | grep -qE 'would be overwritten|commit your changes or stash'; then
        git -C "$dir" status --porcelain 2>/dev/null | sed -n 's/^.. //p' | grep -E '\.(uid|import)$' | while IFS= read -r f; do
            if git -C "$dir" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then git -C "$dir" restore --staged --worktree -- "$f" 2>/dev/null; else rm -f "$dir/$f"; fi
        done
        pull_err="$(git "${net[@]}" -C "$dir" pull -q --no-rebase --ff-only 2>&1 >/dev/null)"; pull_rc=$?
        dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [ $pull_rc -ne 0 ] && printf '%s' "$pull_err" | grep -qE 'would be overwritten|commit your changes or stash'; then
        if resolve_blocked_pull "$proj" "$dir" "$pull_err" "${net[@]}"; then
            pull_rc=0; dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        fi
    fi
    # Diverged, no upstream, upstream deleted, detached HEAD: never "resolve by hand".
    # Not for the network (nothing to repair) nor a missing repository.
    if [ $pull_rc -ne 0 ] && [ "$pull_net" = 0 ] && ! net_error "$pull_err" \
       && ! printf '%s' "$pull_err" | grep -qiE 'repository not found|does not exist|does not appear to be a git repository|could not read username|would be overwritten|commit your changes or stash'; then
        if repair_checkout "$proj" "$dir" "${net[@]}"; then
            pull_rc=0; dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        fi
    fi
    if [ $pull_rc -eq 0 ]; then
        local after; after=$(git -C "$dir" rev-parse --short HEAD)
        local kept=""; [ "$dirty" -gt 0 ] && kept=" ${YLW}(kept $dirty uncommitted file(s))${OFF}"
        if [ -z "$before" ]; then say "$proj" "${GRN}first commits${OFF} $after$kept"
        elif [ "$before" = "$after" ]; then say "$proj" "${DIM}up to date${OFF} $after$kept"
        else say "$proj" "${GRN}updated${OFF} $before -> $after$kept"; fi
        return
    fi
    local why; why="$(printf '%s\n' "$pull_err" | grep -iE '^(fatal|error):' | head -1)"
    [ -n "$why" ] || why="$(printf '%s\n' "$pull_err" | grep . | head -1)"
    if [ "$pull_net" = 1 ] || net_error "$pull_err"; then
        # The checkout is whole, just behind: the next run catches up. Not an error.
        warn "$proj" "network, retried ${pull_tries}x, not updated: $why"
        note_stale "$proj" "network failure after $pull_tries tries (checkout kept as it was; the next run catches up)"
    elif printf '%s' "$pull_err" | grep -qiE 'repository not found|does not exist|does not appear to be a git repository|could not read username'; then
        # Renamed, deleted or private: the checkout on disk still works, so one line, no failure.
        warn "$proj" "skipped: $origin is missing or private on GitHub; the checkout here is kept as it is. Fix its line in projects.tsv."
        note_stale "$proj" "repository missing or private ($origin); fix projects.tsv"
    elif [ "$dirty" -gt 0 ] && printf '%s' "$pull_err" | grep -qE 'would be overwritten|commit your changes or stash'; then
        # The update touches files changed here. Name them, so the choice
        # between committing and discarding is made by somebody looking.
        local files; files="$(printf '%s\n' "$pull_err" | sed -n 's/^[[:space:]]\{1,\}\([^[:space:]].*\)$/\1/p' | grep -v '^Please\|^Aborting' | head -5 | paste -sd' ' -)"
        warn "$proj" "dirty, not updated: the update changes files modified here (${files:-see git status})"
        say  ""      "  commit or discard them, then run this again (generated .import/.uid files: add --discard-generated)"
        note_stale "$proj" "local edits block the update (${files:-see git status})"
    else
        case "$origin" in
            *@*:*|ssh://*)
                if [ "$USE_HTTPS" != "1" ]; then
                    err "$proj" "pull failed. origin is SSH; if you have no key here, drop --ssh, or run:"
                    say ""       "  git -C '$dir' remote set-url origin $(to_https "$origin")"
                    note_stale "$proj" "SSH pull failed: $why"
                    return
                fi ;;
        esac
        # repair_checkout could not move it either (its fetch failed, or git refused).
        err "$proj" "pull failed and could not be repaired: $why"
        note_stale "$proj" "pull failed: $why"
    fi
}

# --- Links -----------------------------------------------------------------

# Copy the addon folders instead of linking them. This is the family's own
# documented consumption model -- "consumers copy the addon folders into their
# own project instead" -- and it is the answer whenever a link cannot be made or
# cannot be followed. The cost is that a copy does not track its source, so
# `--links --copy` has to be re-run after pulling; that is why it is not the
# default.
COPY_ADDONS=0
LINKS_MADE=0
LINKED_PROJECTS=0

link_addons() {
    local proj="$1"; local dir="$PROJECTS_DIR/$proj"
    [ -d "$dir" ] || { warn "$proj" "not cloned, so nothing to link"; return 0; }

    # NOTHING here returns silently. The version this replaces bailed out before
    # printing anything when a project yielded no addons, so a run in which not
    # one link was made printed not one line and then said "ok" -- and the first
    # thing the user saw was seventy GDScript parse errors. Silence must never be
    # how success looks.
    if [ ! -f "$dir/.gitignore" ]; then
        warn "$proj" "no .gitignore, so no addon list -- cannot link anything"
        return 0
    fi

    local addons; addons="$(links_for "$proj")"
    if [ -z "$addons" ]; then
        say "$proj" "${DIM}needs no addons${OFF}"
        return 0
    fi

    mkdir -p "$dir/addons"
    local made=0 addon src
    while read -r addon; do
        [ -n "$addon" ] || continue
        src="$(addon_source "$addon")"
        if [ ! -d "$PROJECTS_DIR/$src/addons/$addon" ]; then
            err "$proj" "source missing: $src/addons/$addon"
            continue
        fi
        # Replace unconditionally: a stale link, or a regular file left by a Git
        # checkout on a machine without symlink support, both have to go. That
        # second one is the nastiest failure here -- Godot sees a 30-byte file
        # where an addon should be, every class_name in it fails to resolve, and
        # every script mentioning those names goes down with it as a cascade of
        # apparently unrelated parse errors.
        rm -rf "$dir/addons/$addon"
        if [ "$COPY_ADDONS" = "1" ]; then
            cp -r "$PROJECTS_DIR/$src/addons/$addon" "$dir/addons/$addon"
        else
            ln -s "../../$src/addons/$addon" "$dir/addons/$addon"
        fi
        made=$((made + 1))
    done <<< "$addons"
    LINKS_MADE=$((LINKS_MADE + made))
    LINKED_PROJECTS=$((LINKED_PROJECTS + 1))
    say "$proj" "${DIM}$([ "$COPY_ADDONS" = "1" ] && echo copied || echo linked) $made addon(s)${OFF}"
}

# A native library an addon can load (a GDExtension; dot-sim's Rust motor, snapshot
# codec and bot sight scan). It is built, never committed, so a clone has only the
# GDScript twins -- correct, and slower. The game pins the release whose library it
# wants, in its .gitignore, as a comment line above the addon (above any
# bootstrap-optional line):
#
#     # bootstrap-natives: dot-sim v0.1.0
#     /addons/dot_sim
#
# and this fetches that release's zip for this machine (SHA256SUMS.natives, checked)
# and unpacks it at the addon repository's root, which is where ci/install.sh puts a
# local build: addons/<addon>/bin/<platform>/ and the .gdextension. It runs before the
# links, so --copy carries the library too. A stamp per platform (bin/.natives-<platform>, so a
# mac with arm64 and x86_64 fetched side by side does not flip one stamp) skips the download
# next time (an old single bin/.natives naming this platform is adopted); a library built locally (bin without a stamp) is kept. No release for
# this platform, or offline: a warning, and the GDScript twins run. DOT_NATIVES=none
# skips the lot; DOT_NATIVES_BASE replaces https://github.com/modcommunity.
#
# An optional third field names the library directory inside the addon when it is not
# bin/ -- dot-net's runtime-loaded snapshot core keeps its flat, Godot-named files in
# native/bin/ ("# bootstrap-natives: dot-net v0.1.29 native/bin"). The stamp goes there,
# and a library for this platform already in it (committed, or built here) is kept.
# Prints "<repo>\t<tag>\t<addon>\t<libdir>" per pin.
natives_for() {
    local gi; gi="$(gi_path "$1")"
    [ -f "$gi" ] || return 0
    awk '/^# bootstrap-natives: /{r=$3; t=$4; l=($5=="" ? "bin" : $5); sub("/$","",l); next}
         r!="" && /^# bootstrap-/{next}
         r!="" && /^\/addons\//{a=$0; sub("^/addons/","",a); sub("/$","",a); print r "\t" t "\t" a "\t" l}
         {r=""}' "$gi"
}

# True when <libdir> already holds a library for <platform>: a non-empty <platform>/
# directory (dot-sim's layout) or a Godot-named file such as
# libx.linux.template_release.x86_64.so or libx.macos.template_debug.universal.dylib.
native_built_here() {
    local lib="$1" plat="$2" os="${2%-*}" arch="${2#*-}" f
    [ -n "$(ls -A "$lib/$plat" 2>/dev/null)" ] && return 0
    for f in "$lib"/*."$os".*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in *."$arch".*|*.universal.*) return 0 ;; esac
    done
    return 1
}

native_platform() {
    local os arch
    case "$(uname -s)" in
        Linux) os=linux ;; Darwin) os=macos ;; MINGW*|MSYS*|CYGWIN*) os=windows ;; *) return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;;
    esac
    echo "$os-$arch"
}

fetch_natives() {
    local proj="$1" repo tag addon libdir lib plat dir stamp base tmp sums file want got
    [ "${DOT_NATIVES:-}" = none ] && return 0
    plat="$(native_platform)" || return 0
    while IFS=$'\t' read -r repo tag addon libdir; do
        [ -n "$repo" ] && [ -n "$tag" ] || continue
        repo="$(on_disk "$repo")"
        dir="$PROJECTS_DIR/$repo"
        [ -d "$dir/addons/$addon" ] || { warn "$proj" "natives: $repo/addons/$addon is not cloned"; continue; }
        lib="$dir/addons/$addon/${libdir:-bin}"
        stamp="$lib/.natives-$plat"
        # The single-stamp layout ("<tag> <platform>" in .natives): adopted when it names
        # this platform, so the next platform fetched cannot overwrite it.
        if [ ! -f "$stamp" ] && [ -f "$lib/.natives" ] && [ "$(cut -d' ' -f2 "$lib/.natives")" = "$plat" ]; then
            cp "$lib/.natives" "$stamp"
        fi
        [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$tag $plat" ] && continue
        if [ ! -f "$stamp" ] && native_built_here "$lib" "$plat"; then
            say "$proj" "${DIM}natives: keeps the $addon library built here ($plat)${OFF}"; continue
        fi
        base="${DOT_NATIVES_BASE:-https://github.com/modcommunity}/$repo/releases/download/$tag"
        tmp="$(mktemp -d)"
        if ! sums="$(curl -fsSL "$base/SHA256SUMS.natives" 2>/dev/null)"; then
            warn "$proj" "natives: no $repo $tag release to fetch (GDScript runs, slower)"; rm -rf "$tmp"; continue
        fi
        read -r want file <<< "$(awk -v p="-$plat.zip" 'substr($2, length($2)-length(p)+1)==p {print $1, $2; exit}' <<< "$sums")"
        if [ -z "$file" ]; then
            warn "$proj" "natives: $repo $tag has no $plat library (GDScript runs, slower)"; rm -rf "$tmp"; continue
        fi
        if ! curl -fsSL -o "$tmp/$file" "$base/$file"; then
            warn "$proj" "natives: could not download $file (GDScript runs, slower)"; rm -rf "$tmp"; continue
        fi
        got="$( (sha256sum "$tmp/$file" 2>/dev/null || shasum -a 256 "$tmp/$file") | cut -d' ' -f1)"
        if [ "$got" != "$want" ]; then
            err "$proj" "natives: $file checksum mismatch, not installed"; rm -rf "$tmp"; continue
        fi
        rm -rf "${lib:?}/$plat"
        if command -v unzip >/dev/null 2>&1; then unzip -qo "$tmp/$file" -d "$dir"
        else python3 -m zipfile -e "$tmp/$file" "$dir"; fi \
            || { err "$proj" "natives: could not unpack $file"; rm -rf "$tmp"; continue; }
        chmod +x "$lib/$plat/"* 2>/dev/null
        mkdir -p "$lib" && echo "$tag $plat" > "$stamp"
        rm -rf "$tmp"
        ok "$proj" "natives: $repo $tag ($plat) installed into $repo/addons/$addon"
    done <<< "$(natives_for "$proj")"
}

# A project may also need a CONTENT directory from another repository: game-g2gfast's
# maps/imported is g2gfast-maps/maps. Same rule as the addons, so bootstrap still holds
# no list: the project's .gitignore says it, as a comment line directly above the
# ignored path,
#
#     # bootstrap-link: g2gfast-maps/maps
#     /maps/imported
#
# Without this a fresh clone of the game had only its three built-in maps, and nothing
# said why: the imported ones are optional content, so the catalogue just found none.
content_links_for() {
    [ "$MIN" = "1" ] && return 0
    local gi; gi="$(gi_path "$1")"
    [ -f "$gi" ] || return 0
    local path src
    # The source through canon: games still name g2gfast-maps/maps, which is airdrift-maps.
    while IFS=$'\t' read -r path src; do
        [ -n "$path" ] && printf '%s\t%s\n' "$path" "$(canon_path "$src")"
    done < <(awk '/^# bootstrap-link: /{src=$3; next} src!="" && /^\//{print $0 "\t" src} {src=""}' "$gi")
}

# A maps repo's lock pins its art stores only when an item goes `into` ".stores"; a lock that pins just the maps
# (arena-dm-maps) must fall through to $DOT_STORES_FROM instead of fetching nothing.
lock_lists_stores() {
    [ -f "$1" ] && grep -Eq '"into"[[:space:]]*:[[:space:]]*"\.stores"' "$1"
}

link_content() {
    local proj="$1"; local dir="$PROJECTS_DIR/$proj" path src rel up
    [ -d "$dir" ] || return 0
    while IFS=$'\t' read -r path src; do
        [ -n "$path" ] || continue
        path="${path#/}"; path="${path%/}"
        # The raw art stores (a maps repo's .stores) are in no repository: $DOT_STORES_FROM (an
        # rsync source, a folder or the URL of a .tar) is where a checkout gets them.
        # A store the fetcher finished has .dot-pack; one it was stopped in still has .manifest.json and is resumed.
        if { [ ! -d "$PROJECTS_DIR/$src" ] || [ -f "$PROJECTS_DIR/$src/.dot-pack" ] || [ -f "$PROJECTS_DIR/$src/.manifest.json" ]; } && [ "${src##*/}" = ".stores" ] && [ -z "$STORES_USER_SET" ] && [ "$DOT_STORES_FROM" != none ] \
                && lock_lists_stores "$PROJECTS_DIR/${src%%/*}/content.lock.json" && [ -x "$REPO_DIR/tools/fetch_lock.sh" ]; then
            "$REPO_DIR/tools/fetch_lock.sh" "$PROJECTS_DIR/${src%%/*}/content.lock.json" --only .stores \
                && touch "$PROJECTS_DIR/$src/.gdignore" || warn "$proj" "fetching $src from content.lock.json failed"
        elif [ ! -d "$PROJECTS_DIR/$src" ] && [ "${src##*/}" = ".stores" ] && [ -d "$PROJECTS_DIR/${src%%/*}" ] \
                && [ -n "${DOT_STORES_FROM:-}" ] && [ "$DOT_STORES_FROM" != none ] && [ -x "$PROJECTS_DIR/dot-map-convert/tools/stage_stores.sh" ]; then
            "$PROJECTS_DIR/dot-map-convert/tools/stage_stores.sh" "$PROJECTS_DIR/${src%%/*}" || warn "$proj" "staging $src from $DOT_STORES_FROM failed"
        elif [ "${src##*/}" != ".stores" ] && [ "$src" != "${src%%/*}" ] && [ -f "$PROJECTS_DIR/${src%%/*}/content.lock.json" ] \
                && [ -x "$REPO_DIR/tools/fetch_lock.sh" ]; then
            # Content kept out of git (arena-dm-maps' maps) is pinned in the repo's lock under the linked folder.
            "$REPO_DIR/tools/fetch_lock.sh" "$PROJECTS_DIR/${src%%/*}/content.lock.json" --only "${src#*/}/*" \
                || warn "$proj" "fetching $src from content.lock.json failed"
        fi
        if [ ! -d "$PROJECTS_DIR/$src" ]; then
            if [ "${src##*/}" = ".stores" ]; then
                warn "$proj" "art stores missing: $src is in no repository, so maps draw low-detail art. Run again without --no-stores, or set DOT_STORES_FROM (rsync source, folder or .tar URL of the pbr-library and model-library) and run bootstrap again, or run dot-map-convert/tools/stage_stores.sh ${src%%/*} --from <src> --game $proj"
            else
                warn "$proj" "content missing: $src (clone ${src%%/*} for $path)"
            fi
            continue
        fi
        # A real directory there may be the only copy of something; never delete it.
        if [ -e "$dir/$path" ] && [ ! -L "$dir/$path" ]; then
            warn "$proj" "$path is a real directory, left alone (link it to $src by hand)"
            continue
        fi
        rm -f "$dir/$path"
        mkdir -p "$(dirname "$dir/$path")"
        if [ "$COPY_ADDONS" = "1" ]; then
            cp -r "$PROJECTS_DIR/$src" "$dir/$path"
        else
            # Relative, so the two checkouts can move together: one ../ per level of
            # path, plus one out of the project itself.
            up="$(printf '%s' "$path" | awk -F/ '{for(i=1;i<NF;i++) printf "../"}')"
            ln -s "../$up$src" "$dir/$path"
        fi
        say "$proj" "${DIM}$([ "$COPY_ADDONS" = "1" ] && echo copied || echo linked) $path -> $src${OFF}"
    done <<< "$(content_links_for "$proj")"
}

# --- Reporting -------------------------------------------------------------

status_repo() {
    local proj="$1"; local dir="$PROJECTS_DIR/$proj"
    [ -d "$dir/.git" ] || { warn "$proj" "not cloned"; return; }
    local n br ahead
    n=$(git -C "$dir" status --porcelain | wc -l)
    br=$(git -C "$dir" branch --show-current)
    ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')
    printf '%-22s %-16s %s  %s\n' "$proj" "$br" \
        "$([ "$n" -eq 0 ] && echo "${DIM}clean${OFF}     " || echo "${YLW}dirty($n)${OFF}")" \
        "$([ "$ahead" = "0" ] && echo "${DIM}pushed${OFF}" || echo "${YLW}$ahead unpushed${OFF}")"
}

# The mechanical detector. A list that is not checked against reality is a list
# that is already wrong; this is the check.
check_list() {
    local listed disk
    listed="$(projects | sort)"
    # This repository is skipped when it is sitting among the projects it
    # manages: it is the thing doing the cloning, not a thing to be cloned.
    # A checkout still under a renamed repository's old name counts as that repository
    # (reported below: the next sync renames it); the link a rename leaves at the old
    # name is no repository at all.
    local d c
    disk="$(cd "$PROJECTS_DIR" 2>/dev/null && for d in */; do
                d="${d%/}"
                [ "$PROJECTS_DIR/$d" = "$REPO_DIR" ] && continue
                [ -L "$d" ] && continue
                [ -d "$d/.git" ] || continue
                c="$(alias_target "$d")"
                if [ -n "$c" ] && ! listed "$d" && [ ! -d "$c/.git" ]; then echo "$c"; else echo "$d"; fi
            done | sort -u)"
    while IFS=$'\t' read -r c d; do
        [ -n "$d" ] && [ -d "$PROJECTS_DIR/$d" ] || continue
        if [ -L "$PROJECTS_DIR/$d" ]; then
            say "$d" "${DIM}old name of $c, a link to it; delete it once nothing uses the old path${OFF}"
        elif [ -d "$PROJECTS_DIR/$c/.git" ]; then
            [ -d "$PROJECTS_DIR/$d/.git" ] && warn "$d" "old checkout of $c, which is also here; move anything you need out of it, then delete it"
        elif [ -d "$PROJECTS_DIR/$d/.git" ]; then
            warn "$c" "checked out under its old name $d; the next sync renames it"
        fi
    done <<< "$(alias_pairs)"

    local missing extra
    missing="$(comm -13 <(echo "$listed") <(echo "$disk"))"
    extra="$(comm -23 <(echo "$listed") <(echo "$disk"))"

    if [ -n "$missing" ]; then
        while read -r p; do
            [ -n "$p" ] && err "$p" "a repository on disk that projects.tsv does not list"
        done <<< "$missing"
    fi
    if [ -n "$extra" ]; then
        while read -r p; do
            [ -n "$p" ] && warn "$p" "listed in projects.tsv, not cloned here"
        done <<< "$extra"
    fi

    # Projects with no remote cannot reach another machine at all.
    local p
    while read -r p; do
        [ "$(url_for "$p")" = "LOCAL" ] \
            && err "$p" "LOCAL: no remote, so a clone elsewhere cannot get it"
    done <<< "$(projects)"

    # An addon a project links must come from a project the list names, or a sync
    # prints "source missing" and ends with errors (dot-mobile was copied into two
    # games but never listed, so it was never cloned).
    local gp ad src
    while read -r gp; do
        [ -n "$gp" ] && [ -f "$(gi_path "$gp")" ] || continue
        while read -r ad; do
            [ -n "$ad" ] || continue
            src="$(addon_source "$ad")"
            listed "$(canon "$src")" || err "$gp" "addon $ad comes from $src, which projects.tsv does not list"
        done <<< "$(links_for "$gp")"
    done <<< "$(projects)"

    # Directories that are not repositories: work in progress, or a clone that
    # failed halfway. Either way nothing else can obtain them.
    local d
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] || continue
        d="$(basename "${d%/}")"
        [ "$PROJECTS_DIR/$d" = "$REPO_DIR" ] && continue
        [ -L "$PROJECTS_DIR/$d" ] && [ -n "$(alias_target "$d")" ] && continue
        [ -d "$PROJECTS_DIR/$d/.git" ] && continue
        warn "$d" "a directory beside the projects that is not a git repository"
    done

    [ "$fail" -eq 0 ] && echo && say "" "${GRN}projects.tsv agrees with the disk${OFF}"
}

# --- Playing ---------------------------------------------------------------

find_godot() {
    local c e
    # What --get-godot downloaded, newest version first.
    e="$(ls -d "$SELF_DIR"/.godot-bin/*/Godot* 2>/dev/null | grep -v '\.\(zip\|tmp\)$' | sort -r | head -n1)"
    [ -n "${GODOT:-}" ] || { [ -n "$e" ] && [ -x "$e" ] && { echo "$e"; return 0; }; }
    for c in "${GODOT:-}" godot godot4 /usr/local/bin/godot "$HOME/.local/bin/godot"; do
        [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
    done
    return 1
}

# Latest stable Godot from the engine's own build repository, checked against the
# SHA512-SUMS.txt published with the release, unpacked into .godot-bin/<version>.
get_godot() {
    local os arch asset tag base tmp want got dest api
    case "$(uname -s)" in
        Linux)  os=linux ;;
        Darwin) os=macos ;;
        *) echo "${RED}--get-godot supports Linux and macOS; on Windows use bootstrap.ps1 -GetGodot${OFF}" >&2; return 1 ;;
    esac
    api="$(curl -fsSL https://api.github.com/repos/godotengine/godot-builds/releases/latest)" || { echo "${RED}could not read the Godot release list${OFF}" >&2; return 1; }
    tag="$(printf '%s' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
    [ -n "$tag" ] || { echo "${RED}no release tag found${OFF}" >&2; return 1; }
    if [ "$os" = macos ]; then asset="Godot_v${tag}_macos.universal.zip"
    else
        case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; i?86) arch=x86_32 ;; *) arch=x86_64 ;; esac
        asset="Godot_v${tag}_linux.${arch}.zip"
    fi
    dest="$SELF_DIR/.godot-bin/$tag"
    if ls "$dest"/Godot* >/dev/null 2>&1; then echo "godot $tag already in $dest"; return 0; fi
    base="https://github.com/godotengine/godot-builds/releases/download/$tag"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    echo "downloading $asset..."
    curl -fSL -o "$tmp/$asset" "$base/$asset" || return 1
    want="$(curl -fsSL "$base/SHA512-SUMS.txt" | awk -v a="$asset" '$2==a {print $1}')"
    [ -n "$want" ] || { echo "${RED}no checksum listed for $asset; nothing installed${OFF}" >&2; return 1; }
    got="$( (sha512sum "$tmp/$asset" 2>/dev/null || shasum -a 512 "$tmp/$asset") | cut -d' ' -f1)"
    [ "$got" = "$want" ] || { echo "${RED}checksum mismatch (got $got); nothing installed${OFF}" >&2; return 1; }
    mkdir -p "$dest" && unzip -q -o "$tmp/$asset" -d "$dest" || return 1
    chmod +x "$dest"/Godot* 2>/dev/null || true
    echo "godot $tag installed in $dest"
}

# A game is a project whose directory begins with game-. Every one of them sets
# run/main_scene to something a person can sit down at, so there is no list of
# scenes here either.
# game-<x> and mg-<x> (the minigames); a maps repository is not a game.
games() { projects | grep -E '^(game|mg)-' | grep -v -- '-maps$'; }

list_games() {
    local g bin
    bin="$(find_godot || true)"
    echo "projects: $PROJECTS_DIR"
    echo "godot:    ${bin:-${RED}not found on PATH${OFF}}"
    echo
    while read -r g; do
        [ -n "$g" ] || continue
        local scene; scene=$(grep -oP 'run/main_scene="\K[^"]+' "$PROJECTS_DIR/$g/project.godot" 2>/dev/null)
        printf '  %-20s %s\n' "${g#game-}" "${DIM}${scene:-not cloned}${OFF}"
    done <<< "$(games)"
    echo
    echo "  ./bootstrap.sh --play <name>"
}

play_game() {
    local want="$1"
    # A game is game-<x> or mg-<x> (the minigames); the short form tries each prefix.
    local proj="$want" c
    for c in "$want" "game-$want" "mg-$want" "$(alias_target "$want")"; do
        [ -n "$c" ] && games | grep -qx "$c" && { proj="$c"; break; }
    done

    if ! games | grep -qx "$proj"; then
        echo "${RED}no such game: $want${OFF}" >&2
        list_games >&2
        exit 2
    fi
    if [ ! -d "$PROJECTS_DIR/$proj" ]; then
        echo "${RED}$proj is not cloned yet. Run ./bootstrap.sh first.${OFF}" >&2
        exit 2
    fi

    local bin; bin="$(find_godot)" || {
        echo "${RED}Godot not found. Run ./bootstrap.sh --get-godot, or set GODOT=/path/to/godot.${OFF}" >&2; exit 3; }

    # Import first. Godot imports a file only when the editor (or --import) scans it, so a
    # game started straight after a pull has the new models' .glb and .import files and no
    # imported scene: on 2026-10-13 every person in three games was a fallback capsule for
    # exactly that. A pass over an up-to-date cache takes seconds.
    echo "${CYN}importing $proj${OFF}"
    local cap=(); command -v timeout >/dev/null && cap=(timeout 900)
    ${cap[@]+"${cap[@]}"} "$bin" --headless --path "$PROJECTS_DIR/$proj" --import >/dev/null 2>&1 \
        || echo "${YLW}the import pass failed; playing anyway${OFF}" >&2

    # --offline is what the clients that have a networked mode read to skip it;
    # the ones that do not have one ignore an unknown user argument. Either way
    # this needs no server, no dot-cloud and no downloads.
    echo "${CYN}$bin --path $PROJECTS_DIR/$proj -- --offline${OFF}"
    exec "$bin" --path "$PROJECTS_DIR/$proj" -- --offline "${@:2}"
}

# --- Release export ---------------------------------------------------------

# --export <game> builds a RELEASE executable of a game (no editor, no debugger) and
# --play-export <game> starts it: what a player's machine runs, for measuring. The game
# carries the presets (export_presets.example.cfg, copied to export_presets.cfg when
# there is none); this script supplies the export template, which the editor download
# does not include. Only this platform's release template is kept (about 70 MB of the
# 1.2 GB archive), in .godot-bin/<version>/templates, and the preset is pointed at it
# (custom_template/release), so nothing is installed outside this folder.
EXPORT_PRESET="Linux x86_64"
# What --play-export starts a game with: offline, a match's worth of bots, the profiler's
# overlay up and a minute per `profiler_record` (F10 stays profiler_capture_seconds). `+name value` is a console line the game
# runs once it knows the name; whatever follows the game's name on the command line comes
# after these, and a name given twice keeps its last value.
# Those console lines are FC's (game-fatal-contact, under any of its names); every other
# game gets --offline and the arguments given.
EXPORT_PLAY_ARGS=(--offline +bot_quota 8 +profiler_overlay 1 +profiler_record_seconds 60)
export_play_args() {
    if [ "$1" = game-fatal-contact ] || [ "$(alias_target "$1")" = game-fatal-contact ]; then
        printf '%s\n' "${EXPORT_PLAY_ARGS[@]}"
    else echo --offline; fi
}

# game-<x> or mg-<x> for a name or its short form; nothing when there is no such game.
resolve_game() {
    local c
    for c in "$1" "game-$1" "mg-$1" "$(alias_target "$1")"; do
        [ -n "$c" ] && games | grep -qx "$c" && { echo "$c"; return 0; }
    done
    return 1
}

# The release tag a Godot executable was built from (4.7.2-stable): the templates must
# be the same version or the exported game refuses its own pck.
godot_tag() {
    local name v
    name="$(basename "$1")"
    v="$(printf '%s' "$name" | sed -n 's/^Godot_v\([0-9][0-9.]*-[A-Za-z0-9]*\)_.*/\1/p')"
    [ -n "$v" ] && { echo "$v"; return 0; }
    v="$("$1" --version 2>/dev/null | head -n1 | sed -n 's/^\([0-9][0-9.]*[0-9]\)\.\([a-z][a-z]*[0-9]*\)\..*/\1-\2/p')"
    [ -n "$v" ] && { echo "$v"; return 0; }
    return 1
}

# The official export templates for <tag>, checked against the release's SHA512-SUMS.txt
# like the editor download. Prints the path of this platform's release template.
get_export_templates() {
    local tag="$1" dest main asset base tpz unpack want got
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64|Linux-amd64) main=linux_release.x86_64 ;;
        *) echo "${RED}--export builds on Linux x86_64 here; on Windows use bootstrap.ps1 -Export${OFF}" >&2; return 1 ;;
    esac
    dest="$SELF_DIR/.godot-bin/$tag/templates"
    if [ -s "$dest/$main" ]; then echo "templates $tag already in $dest" >&2; echo "$dest/$main"; return 0; fi
    asset="Godot_v${tag}_export_templates.tpz"
    base="${DOT_GODOT_BASE:-https://github.com/godotengine/godot-builds/releases/download}/$tag"
    mkdir -p "$dest" || return 1
    # Beside the destination, not in /tmp: the archive is 1.2 GB and /tmp is often memory.
    tpz="$dest/$asset.part"; unpack="$dest/unpack.part"
    echo "downloading $asset (about 1.2 GB, once)..." >&2
    curl -fSL -o "$tpz" "$base/$asset" || { rm -f "${tpz:?}"; echo "${RED}could not download $base/$asset${OFF}" >&2; return 1; }
    want="$(curl -fsSL "$base/SHA512-SUMS.txt" | awk -v a="$asset" '$2==a {print $1}')"
    [ -n "$want" ] || { rm -f "${tpz:?}"; echo "${RED}no checksum listed for $asset; nothing installed${OFF}" >&2; return 1; }
    got="$( (sha512sum "$tpz" 2>/dev/null || shasum -a 512 "$tpz") | cut -d' ' -f1)"
    [ "$got" = "$want" ] || { rm -f "${tpz:?}"; echo "${RED}checksum mismatch (got $got); nothing installed${OFF}" >&2; return 1; }
    # Under another name first: the template's presence is what says the install is complete.
    mkdir -p "$unpack" && unzip -q -o -j "$tpz" "templates/$main" -d "$unpack" 2>/dev/null
    rm -f "${tpz:?}"
    if [ ! -s "$unpack/$main" ]; then
        rm -f "${unpack:?}/${main:?}"; rmdir "$unpack" 2>/dev/null
        echo "${RED}$asset has no templates/$main; nothing installed${OFF}" >&2; return 1
    fi
    chmod +x "$unpack/$main" && mv -f "$unpack/$main" "$dest/$main" && rmdir "$unpack"
    echo "templates $tag installed in $dest" >&2
    echo "$dest/$main"
}

# The preset --export writes for a game that carries none (only FC tracks an
# export_presets.example.cfg): FC's preset with the game's name, the same lines as
# bootstrap.ps1's Get-DefaultExportPreset. The pck sits beside the executable
# (embed_pck=false; a large embedded pck starts slowly), every resource is exported, plus
# the non-resource files games read with FileAccess (map json and bin, yml, cfg, packs),
# and the test, tool and document folders are left out. Fails for a preset it does not know.
default_export_preset() {
    local proj="$1" preset="$2" idx="$3" platform path
    case "$preset" in
        "Windows x86_64") platform="Windows Desktop"; path="build/windows/$proj.exe" ;;
        "Linux x86_64") platform="Linux"; path="build/linux/$proj.x86_64" ;;
        *) return 1 ;;
    esac
    cat <<CFG
[preset.$idx]

name="$preset"
platform="$platform"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="*.json, *.bin, *.yml, *.txt, *.tsv, *.conf, *.cfg, *.dot-pack"
exclude_filter="examples/*, tests/*, tools/*, ci/*, docs/*, images/*, build/*, screenshots/*, lightbake_work/*, dot_cloud/*, web/build/*, export_presets*.cfg"
export_path="$path"
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.$idx.options]

custom_template/debug=""
custom_template/release=""
debug/export_console_wrapper=0
binary_format/embed_pck=false
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false
binary_format/architecture="x86_64"
CFG
    if [ "$preset" = "Windows x86_64" ]; then
        printf '%s\n' 'codesign/enable=false' 'application/modify_resources=false' \
            "application/product_name=\"$proj\"" "application/file_description=\"$proj client (release)\""
    fi
}

# A generated export_presets.cfg is the editor's file and never the game's: when the
# game's .gitignore does not already ignore it, it goes in the clone's .git/info/exclude.
hide_export_presets() {
    local dir="$1" ex
    git -C "$dir" check-ignore -q export_presets.cfg 2>/dev/null && return 0
    git -C "$dir" ls-files --error-unmatch -- export_presets.cfg >/dev/null 2>&1 && return 0
    ex="$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null)" && [ -n "$ex" ] || return 0
    case "$ex" in /*) ;; *) ex="$dir/$ex" ;; esac
    mkdir -p "$(dirname "$ex")" && echo 'export_presets.cfg' >> "$ex"
}

# export_presets.cfg for <dir> with preset <name> using <template> as its release
# template. The file is the game's export_presets.example.cfg when there is none yet
# (the editor rewrites export_presets.cfg, so games track only the example); a game with
# neither, or whose file has no such preset, gets the default one (default_export_preset).
set_export_preset() {
    local dir="$1" preset="$2" template="$3" cfg src idx tmp top gen what made=""
    cfg="$dir/export_presets.cfg"; src="$cfg"
    [ -f "$src" ] || src="$dir/export_presets.example.cfg"
    [ -f "$src" ] || src=""
    idx=""; top=-1
    if [ -n "$src" ]; then
        idx="$(awk -v want="name=\"$preset\"" '
            /^\[.+\][[:space:]]*$/ { sec=$0; sub(/^\[/,"",sec); sub(/\][[:space:]]*$/,"",sec); next }
            $0==want && sec ~ /^preset\.[0-9]+$/ { sub(/^preset\./,"",sec); print sec; exit }' "$src")"
        top="$(awk '/^\[preset\.[0-9]+\][[:space:]]*$/ { n=$0; gsub(/[^0-9]/,"",n); if (n+0>max) max=n+0; seen=1 }
            END { print (seen ? max : -1) }' "$src")"
    fi
    if [ -z "$idx" ]; then
        idx=$((top + 1))
        gen="$(default_export_preset "$(basename "$dir")" "$preset" "$idx")" || {
            if [ -z "$src" ]; then echo "${RED}no export_presets.cfg and no export_presets.example.cfg in $dir${OFF}" >&2
            else echo "${RED}$src has no preset named \"$preset\"${OFF}" >&2; fi
            return 1; }
        made="$cfg.src.$$"
        if [ -n "$src" ]; then
            awk '1' "$src" > "$made"
            [ -z "$(tail -n1 "$made")" ] || echo >> "$made"
            what="$(basename "$src") has no \"$preset\" preset"
        else : > "$made"; what="it carries no export presets"; fi
        printf '%s\n' "$gen" >> "$made"
        src="$made"
        echo "$(basename "$dir"): $what, so the default \"$preset\" release preset is written to export_presets.cfg"
        hide_export_presets "$dir"
    fi
    tmp="$cfg.tmp.$$"
    awk -v opts="preset.$idx.options" -v line="custom_template/release=\"$template\"" '
        /^\[.+\][[:space:]]*$/ {
            # Left the options section without finding the key: it goes at the end of it.
            if (sec==opts && !done) { print line; print ""; done=1 }
            sec=$0; sub(/^\[/,"",sec); sub(/\][[:space:]]*$/,"",sec)
        }
        sec==opts && index($0,"custom_template/release=")==1 { print line; done=1; next }
        { print }
        END { if (!done) { if (sec!=opts) { print ""; print "[" opts "]"; print "" } print line } }' "$src" > "$tmp" \
        && mv -f "$tmp" "$cfg"
    local rc=$?
    [ -z "$made" ] || rm -f "$made"
    return $rc
}

export_path() { echo "$PROJECTS_DIR/$1/build/linux/$1.x86_64"; }

# The file name of the library each .gdextension of <dir> loads on <os> x86_64 in a
# release build, one per line as "<extension>\t<library>"; the library is empty when
# the extension lists none for this platform.
export_natives() {
    local dir="$1" os="$2" ext
    [ -d "$dir/addons" ] || return 0
    while read -r ext; do
        [ -n "$ext" ] || continue
        awk -F= -v os="$os" -v ext="$(basename "$ext")" '
            /^[[:space:]]*[#;]/ { next }
            { k=$1; gsub(/[[:space:]]/,"",k) }
            (k==os ".release.x86_64" || k==os ".x86_64" || k==os ".release" || k==os) && !lib {
                lib=$0; sub(/^[^"]*"/,"",lib); sub(/".*$/,"",lib); sub(/^.*\//,"",lib) }
            END { print ext "\t" lib }' "$ext"
    done <<< "$(find -L "$dir/addons" -maxdepth 3 -name '*.gdextension' 2>/dev/null | sort)"
}

# A library an addon loads itself at run time from a .cfg (dot-net's snapshot core:
# addons/dot_net/native/dot_net_native.cfg, see its docs/native.md). The export never
# carries it, so export_game copies the .cfg and its release library into
# <out>/<cfg name>/, the place DotNetNative looks beside the executable. One line per
# addons/*/native/*.cfg holding an entry_symbol: "<cfg>\t<library path relative to the
# cfg>"; the path is empty when it names none for <os> x86_64. Optional by design (the
# addon falls back to GDScript), so a missing one is a warning, not a failed export.
export_runtime_natives() {
    local dir="$1" os="$2" cfg
    for cfg in "$dir"/addons/*/native/*.cfg; do
        [ -f "$cfg" ] && grep -q '^[[:space:]]*entry_symbol' "$cfg" || continue
        awk -F= -v os="$os" -v cfg="$cfg" '
            /^[[:space:]]*[#;]/ { next }
            { k=$1; gsub(/[[:space:]]/,"",k) }
            (k==os ".release.x86_64" || k==os ".x86_64" || k==os ".release" || k==os) && !lib {
                lib=$0; sub(/^[^"]*"/,"",lib); sub(/".*$/,"",lib) }
            END { print cfg "\t" lib }' "$cfg"
    done
}

# Copies each runtime-loaded library of <dir> for <os> into <out>; prints what it bundled.
bundle_runtime_natives() {
    local dir="$1" os="$2" out="$3" cfg lib name dest
    while IFS=$'\t' read -r cfg lib; do
        [ -n "$cfg" ] || continue
        name="$(basename "$cfg" .cfg)"; dest="$out/$name"
        rm -rf "${dest:?}"
        if [ -z "$lib" ] || [ ! -s "$(dirname "$cfg")/$lib" ]; then
            echo "${YLW}$name: no ${os} x86_64 library${lib:+ ($lib)} in the project, so the build runs its GDScript fallback. Run ./bootstrap.sh to fetch it.${OFF}" >&2
            continue
        fi
        mkdir -p "$dest/$(dirname "$lib")" && cp "$cfg" "$dest/" && cp "$(dirname "$cfg")/$lib" "$dest/$lib" || return 1
        [ -s "$dest/$lib" ] && ok "native" "$name/$lib bundled"
    done <<< "$(export_runtime_natives "$dir" "$os")"
}

# Export one game as a release build into <game>/build/linux.
export_game() {
    local want="$1" proj dir bin tag template exe out log ext lib f missing=0 cap=()
    proj="$(resolve_game "$want")" || { echo "${RED}no such game: $want${OFF}" >&2; list_games >&2; return 2; }
    dir="$PROJECTS_DIR/$proj"
    [ -d "$dir" ] || { echo "${RED}$proj is not cloned yet. Run ./bootstrap.sh first.${OFF}" >&2; return 2; }
    bin="$(find_godot)" || { echo "${RED}Godot not found. Run ./bootstrap.sh --get-godot, or set GODOT=/path/to/godot.${OFF}" >&2; return 3; }
    tag="$(godot_tag "$bin")" || { echo "${RED}could not read the version of $bin, so no matching export templates${OFF}" >&2; return 1; }
    template="$(get_export_templates "$tag")" || return 1
    set_export_preset "$dir" "$EXPORT_PRESET" "$template" || return 1

    # A native library is exported only when it is in the project; without it the game
    # runs its GDScript twins, which is a different thing to measure.
    while IFS=$'\t' read -r ext lib; do
        [ -n "$ext" ] || continue
        [ -n "$lib" ] || { echo "${RED}$ext lists no Linux x86_64 library, so the build would run without it. Run ./bootstrap.sh $proj to fetch it (DOT_NATIVES=none exports without).${OFF}" >&2; missing=1; }
    done <<< "$(export_natives "$dir" linux)"
    [ "$missing" = 0 ] || [ "${DOT_NATIVES:-}" = none ] || return 1

    exe="$(export_path "$proj")"; out="$(dirname "$exe")"; log="$out/export.log"
    mkdir -p "$out" || return 1
    command -v timeout >/dev/null && cap=(timeout 3600)
    echo "${CYN}importing $proj${OFF}"
    ${cap[@]+"${cap[@]}"} "$bin" --headless --path "$dir" --import >/dev/null 2>&1 \
        || echo "${YLW}the import pass failed; exporting anyway${OFF}" >&2
    # The last build's files go first: a stale library beside a new executable would pass the check below.
    rm -f -- "${exe:?}" "${out:?}/${proj:?}.pck" "${out:?}"/*.so
    echo "${CYN}exporting $proj ($EXPORT_PRESET, release) to $out; a first export takes several minutes${OFF}"
    ${cap[@]+"${cap[@]}"} "$bin" --headless --path "$dir" --export-release "$EXPORT_PRESET" "$exe" > "$log" 2>&1 || true
    # The file is the evidence: an export can print an error and still exit 0.
    if [ ! -s "$exe" ]; then
        echo "${RED}no $exe was written; the end of $log follows${OFF}" >&2
        tail -n 15 "$log" | sed 's/^/    /' >&2
        return 1
    fi
    chmod +x "$exe"
    # Godot puts each extension's library beside the executable; one that is not there
    # was not exported, and the game would start without it and say nothing.
    missing=0
    while IFS=$'\t' read -r ext lib; do
        [ -n "$lib" ] || continue
        if [ -s "$out/$lib" ]; then ok "native" "$lib bundled"
        else echo "${RED}$lib ($ext) is not beside the executable; see $log${OFF}" >&2; missing=1; fi
    done <<< "$(export_natives "$dir" linux)"
    [ "$missing" = 0 ] || return 1
    bundle_runtime_natives "$dir" linux "$out" || { echo "${RED}could not copy the runtime-loaded native libraries into $out${OFF}" >&2; return 1; }
    ok "export" "$exe ($(du -sm "$out" | cut -f1) MB in $out, log in export.log)"
}

# Start the exported build, exporting it first when there is none. The profiler is in
# release builds too: F10 records, and the files land in the game's user folder.
play_export() {
    local want="$1" proj exe
    proj="$(resolve_game "$want")" || { echo "${RED}no such game: $want${OFF}" >&2; list_games >&2; exit 2; }
    exe="$(export_path "$proj")"
    if [ ! -x "$exe" ]; then export_game "$want" || exit 1
    else echo "${DIM}using the build of $(date -r "$exe" '+%Y-%m-%d %H:%M'); ./bootstrap.sh --export $want rebuilds it${OFF}"; fi
    local args=(); mapfile -t args < <(export_play_args "$proj")
    echo "${CYN}$exe -- ${args[*]} ${*:2}${OFF}"
    echo "${DIM}F10 records 10 s, profiler_record in the console 60 s; reports: ${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/$proj/profiles${OFF}"
    exec "$exe" -- "${args[@]}" "${@:2}"
}

# --- Modes -----------------------------------------------------------------

# --copy, --ssh, --https, --only and --no-deps may accompany any mode; strip them before
# the mode is read.
ARGS=()
GET_GODOT=0; DO_IMPORT=0
only_raw="${DOT_ONLY:-}"
games_raw=""; addons_raw=""; positional=""
# The raw art stores are fetched once from the maps repo's content.lock.json (tools/fetch_lock.sh) unless DOT_STORES_FROM
# says otherwise (a folder, rsync source or .tar URL) or it is "none" (--no-stores); a finished .stores is never refetched.
# (The old published tar, dev.dotgames.org/stores/zombie-zone-maps/zz-stores-cc0.tar, is gone: 404.)
STORES_USER_SET="${DOT_STORES_FROM+set}"
DOT_STORES_FROM="${DOT_STORES_FROM-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --copy)    COPY_ADDONS=1 ;;
        --ssh)     USE_HTTPS=0 ;;
        --https)   USE_HTTPS=1 ;;   # the default; still accepted
        --no-deps) NO_DEPS=1 ;;
        --jobs|-j) [ $# -ge 2 ] || { echo "${RED}$1 needs a number${OFF}" >&2; exit 2; }; JOBS="$2"; shift ;;
        --jobs=*)  JOBS="${1#--jobs=}" ;;
        --no-stores) DOT_STORES_FROM=none ;;
        --discard-generated) DISCARD_GEN=1 ;;
        --get-godot) GET_GODOT=1 ;;
        --import)  DO_IMPORT=1 ;;
        --min)     MIN=1 ;;
        --zees-games-min) MIN=1; positional="$positional,zees-games" ;;
        --plan|--dry-run) PLAN=1 ;;
        --only|--games|--addons)
                   [ $# -ge 2 ] || { echo "${RED}$1 needs a name${OFF}" >&2; exit 2; }
                   case "$1" in --only) only_raw="$only_raw,$2" ;; --games) games_raw="$games_raw,$2" ;; *) addons_raw="$addons_raw,$2" ;; esac
                   shift ;;
        --only=*)   only_raw="$only_raw,${1#--only=}" ;;
        --games=*)  games_raw="$games_raw,${1#--games=}" ;;
        --addons=*) addons_raw="$addons_raw,${1#--addons=}" ;;
        --play)    ARGS+=("$@"); break ;;   # its argument is a game, not a selection
        --export|--play-export) ARGS+=("$@"); break ;;   # a game, then (for --play-export) the game's own arguments
        -*)        ARGS+=("$1") ;;
        sync)      ARGS+=("$1") ;;
        *)         positional="$positional,$1" ;;   # a bare name selects, like --only
    esac
    shift
done
case "$JOBS" in ''|*[!0-9]*|0) echo "${RED}--jobs needs a positive number, got '$JOBS'${OFF}" >&2; exit 2 ;; esac
set -- "${ARGS[@]+"${ARGS[@]}"}"
only_raw="$only_raw$positional"

# A name that matches nothing is an error, not an empty selection: an empty one
# would quietly mean "everything", which is the opposite of what was asked.
select_names() {   # <flag> <kind: any|game|addon> <comma list>
    local flag="$1" kind="$2" n hit p
    IFS=', ' read -ra _names <<< "$3"
    for n in "${_names[@]+"${_names[@]}"}"; do
        [ -n "$n" ] || continue
        hit="$(resolve_name "$n")"
        [ -n "$hit" ] || { echo "${RED}$flag: no project or group called '$n' in projects.tsv (try --list for the games)${OFF}" >&2; exit 2; }
        while read -r p; do
            case "$kind" in
                game)  games | grep -qxF "$p" || { echo "${RED}$flag: '$p' is not a game${OFF}" >&2; exit 2; } ;;
                addon) ! games | grep -qxF "$p" || { echo "${RED}$flag: '$p' is a game, not an addon (use --games)${OFF}" >&2; exit 2; } ;;
            esac
            ONLY+=("$p")
        done <<< "$hit"
    done
}
select_names --only any "$only_raw"
select_names --games game "$games_raw"
select_names --addons addon "$addons_raw"
# --min on its own means every game, base only.
[ "$MIN" = "1" ] && [ ${#ONLY[@]} -eq 0 ] && select_names --min game "zees-games"
# De-duplicate, keeping order.
if [ ${#ONLY[@]} -gt 0 ]; then mapfile -t ONLY < <(printf '%s\n' "${ONLY[@]}" | awk '!s[$0]++'); fi

mode="${1:-sync}"
# --get-godot and --import alone keep their own mode. With each other, --discard-generated or
# a selection they carry on: download Godot, sync and link, then import (as bootstrap.ps1 does).
if [ $# -eq 0 ]; then
    if [ "$DO_IMPORT" = "1" ] && [ "$GET_GODOT" = "0" ] && [ "$DISCARD_GEN" = "0" ]; then mode=--import
    elif [ "$GET_GODOT" = "1" ] && [ "$DO_IMPORT" = "0" ] && [ "$DISCARD_GEN" = "0" ]; then mode=--get-godot
    fi
fi

content_keys() {
    # A CONTENT SIGNING KEYPAIR, for a developer who wants to PUBLISH packs locally.
    #
    # dot-cloud refuses unsigned manifests, and it should: a mounted pack can contain
    # scripts, so a client that mounts unsigned content runs whatever the server sent.
    # That means publishing needs a private key, and a private key is the one thing a
    # clone can never carry -- `keys/` is gitignored in dot-server-deploy precisely so
    # it cannot arrive in a commit.
    #
    # So a fresh clone can CONSUME the team's content (the public half is committed in
    # client/content.json) and cannot PUBLISH any. This makes it able to, with its own
    # identity, and rewrites content.json to trust that identity instead -- which will
    # show as a local modification to a committed file. That is the honest trade and the
    # reason this is opt-in rather than part of a plain sync: overwriting it silently
    # would leave somebody wondering why their client rejects the team's packs.
    local deploy="$PROJECTS_DIR/dot-server-deploy"

    [ -d "$deploy" ] || { warn "dot-server-deploy" "not cloned yet; run a sync first"; return 1; }

    # The rewrite of client/content.json below is Python, because editing JSON in
    # sed is how a config file gets corrupted. Check for it up front: without this
    # the heredoc fails after the key has already been written, which leaves a
    # keypair on disk that nothing trusts.
    command -v python3 >/dev/null 2>&1 \
        || { err "content keys" "python3 is needed to rewrite client/content.json"; return 1; }

    local godot; godot="$(find_godot)" || return 1

    if [ -f "$deploy/keys/content.key" ]; then
        ok "content keys" "already present ($deploy/keys)"
    else
        mkdir -p "$deploy/keys"
        ( cd "$deploy" && "$godot" --headless --path . \
            --script addons/dot_cloud/publish/dot_cloud_cli.gd -- \
            keygen --private keys/content.key --public keys/content.pub >/dev/null 2>&1 ) \
            || { warn "content keys" "keygen failed"; return 1; }
        # The generator warns it lands with default permissions, and it is right to.
        chmod 600 "$deploy/keys/content.key" 2>/dev/null
        ok "content keys" "generated in $deploy/keys"
    fi

    python3 - "$deploy" <<'PY'
import io, json, sys, collections, os
deploy = sys.argv[1]
pem = io.open(os.path.join(deploy, 'keys', 'content.pub'), encoding='utf-8').read().strip()
cfg = os.path.join(deploy, 'client', 'content.json')
doc = collections.OrderedDict()
if os.path.exists(cfg):
    doc = json.load(io.open(cfg, encoding='utf-8'), object_pairs_hook=collections.OrderedDict)
doc['require_signed_manifests'] = True
doc['trusted_keys'] = {'default': pem}
io.open(cfg, 'w', encoding='utf-8').write(json.dumps(doc, indent=4) + '\n')
print('  client/content.json now trusts this machine\'s key')
PY
}


FASTGMAD_VERSION="0.2.1"
install_tools() {
    # fastgmad, the community addon-archive (.gma) extractor that dot-map-convert's BSP importer
    # (dotbsp/gma.py in dot-map-convert) shells out to. Opt-in rather than part of a plain sync,
    # because a plain sync needs git and nothing else, and this is a download of a binary.
    # Pinned to one release and refused unless its SHA-256 matches the value below, which
    # was checked against the release's own digest: the importer runs this on archives
    # from the internet, so the binary itself must not be whatever a mirror served.
    # The release ships helper libraries beside the executable, so all of it is installed
    # into one directory and only the executable is linked into the bin directory.
    local prefix="${DOT_TOOLS_PREFIX:-$HOME/.local}" os arch asset sum
    os="$(uname -s)"; arch="$(uname -m)"
    case "$os-$arch" in
        Linux-x86_64)  asset=fastgmad_linux.zip;
                       sum=eaf617664a2c534b7e9a0238a94156e692313334ff92d2695b6c5445d49b9d04 ;;
        Darwin-*)      asset=fastgmad_macos.zip;
                       sum=5a22a4e8fd1356bf02369108726f759938322c97b434a0a60c10fcf77307fbd8 ;;
        *) err "fastgmad" "no release binary for $os $arch"; return 1 ;;
    esac
    command -v unzip >/dev/null 2>&1 || { err "fastgmad" "unzip is needed"; return 1; }
    local dest="$prefix/share/fastgmad-$FASTGMAD_VERSION" tmp
    if [ -x "$dest/fastgmad" ] && [ -L "$prefix/bin/fastgmad" ]; then
        ok "fastgmad" "already installed ($dest)"; return 0
    fi
    tmp="$(mktemp -d)" || return 1
    # DOT_FASTGMAD_ZIP names a local copy of the release zip (an offline machine). It is
    # held to the same checksum.
    if [ -n "${DOT_FASTGMAD_ZIP:-}" ]; then
        cp "$DOT_FASTGMAD_ZIP" "$tmp/$asset" || { rm -rf "$tmp"; return 1; }
    else
        curl -fsSL -o "$tmp/$asset" \
            "https://github.com/WilliamVenner/fastgmad/releases/download/v$FASTGMAD_VERSION/$asset" \
            || { err "fastgmad" "download failed"; rm -rf "$tmp"; return 1; }
    fi
    local got; got="$( (sha256sum "$tmp/$asset" 2>/dev/null || shasum -a 256 "$tmp/$asset") | cut -d' ' -f1)"
    if [ "$got" != "$sum" ]; then
        err "fastgmad" "checksum mismatch (got $got, want $sum); nothing installed"
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$dest" "$prefix/bin"
    unzip -qo "$tmp/$asset" -d "$dest" || { err "fastgmad" "unzip failed"; rm -rf "$tmp"; return 1; }
    chmod +x "$dest/fastgmad"
    ln -sfn "$dest/fastgmad" "$prefix/bin/fastgmad"
    rm -rf "$tmp"
    ok "fastgmad" "$FASTGMAD_VERSION installed, linked at $prefix/bin/fastgmad"
}

# What a sync would clone and link for this selection, from .gitignore files alone. A
# project that is not cloned is read from DOT_PLAN_FROM (default: the projects dir).
plan() {
    local p a path src
    [ -n "$PLAN_FROM" ] || PLAN_FROM="$PROJECTS_DIR"
    echo "selection: ${ONLY[*]:-everything}$([ "$MIN" = "1" ] && echo " (min: no content packs)")$([ "$NO_DEPS" = "1" ] && echo " (no deps)")"
    while read -r p; do
        [ -n "$p" ] || continue
        if [ -d "$PROJECTS_DIR/$p/.git" ]; then echo "have $p"; else echo "clone $p"; fi
    done <<< "$(selected)"
    while read -r p; do
        [ -n "$p" ] || continue
        while read -r a; do [ -n "$a" ] && echo "link $p addon $a"; done <<< "$(links_for "$p")"
        while IFS=$'\t' read -r path src; do
            [ -n "$src" ] && echo "link $p content ${path#/} -> $src"
        done <<< "$(content_links_for "$p")"
    done <<< "$(link_targets)"
}

[ "$PLAN" = "1" ] && { plan; exit 0; }

case "$mode" in
    --list|--play|--export|--play-export|--check|--status|--tools|--import|--get-godot) : ;;   # must not create anything
    *) mkdir -p "$PROJECTS_DIR" ;;
esac

run_import() {
    # Games only, whatever else the selection holds; no selection means every game.
    local bin; bin="$(find_godot)" || { echo "${RED}Godot not found. Run ./bootstrap.sh --get-godot, or set GODOT=/path/to/godot.${OFF}" >&2; exit 3; }
    mapfile -t _g < <(if [ ${#ONLY[@]} -gt 0 ]; then printf '%s\n' "${ONLY[@]}" | grep -xFf <(games); else games; fi)
    "$SELF_DIR/tools/import-all.sh" -j "$JOBS" "$PROJECTS_DIR" "$bin" "${_g[@]}" || fail=1
}

# Runs first so the rest of this run, including --import, finds it.
[ "$GET_GODOT" = "1" ] && { get_godot || fail=1; }

case "$mode" in
    --status)
        echo "projects: $PROJECTS_DIR"; echo
        while read -r p; do [ -n "$p" ] && status_repo "$p"; done <<< "$(selected)"
        ;;
    --check)
        check_list
        ;;
    --links)
        migrate_renamed
        targets="$(link_targets)"
        while read -r p; do [ -n "$p" ] && fetch_natives "$p"; done <<< "$targets"
        while read -r p; do [ -n "$p" ] && { link_addons "$p"; link_content "$p"; }; done <<< "$targets"
        ;;
    --tools)
        install_tools || fail=1
        ;;
    --content-keys)
        content_keys || fail=1
        ;;
    --get-godot)
        # Already downloaded above when it is the only thing asked for.
        ;;
    --import)
        run_import
        ;;
    --list)
        list_games; exit 0
        ;;
    --play)
        [ $# -ge 2 ] || { list_games; exit 2; }
        play_game "${@:2}"
        ;;
    --export)
        [ $# -ge 2 ] || { list_games; exit 2; }
        export_game "$2" || exit $?
        exit 0
        ;;
    --play-export)
        [ $# -ge 2 ] || { list_games; exit 2; }
        play_export "${@:2}"
        ;;
    sync|"")
        echo "projects: $PROJECTS_DIR"
        echo "base:     $GIT_BASE"; echo
        # Repositories first, all of them, then links -- a link can point into a
        # project that this same run is about to clone.
        [ ${#ONLY[@]} -gt 0 ] && echo "only:     ${ONLY[*]}$([ "$NO_DEPS" = "1" ] && echo " (no deps)")" && echo
        # Before anything is cloned: a checkout under an old name is this run's copy.
        migrate_renamed
        sync_selected
        echo
        targets="$(link_targets)"
        while read -r p; do [ -n "$p" ] && fetch_natives "$p"; done <<< "$targets"
        while read -r p; do [ -n "$p" ] && { link_addons "$p"; link_content "$p"; }; done <<< "$targets"
        [ "$DO_IMPORT" = "1" ] && run_import
        ;;
    -h|--help)
        sed -n '3,48p' "$REAL_SELF" | sed 's/^# \{0,1\}//'; exit 0
        ;;
    *)
        echo "usage: $0 [names...|zees-games] [--games a,b] [--addons x,y] [--min|--zees-games-min] [--plan] [--links|--status|--check|--list|--play <game>|--export <game>|--play-export <game> [args]]" >&2; exit 2
        ;;
esac

echo
if [ -s "$STALE_FILE" ]; then
    echo "${YLW}not updated ($(wc -l < "$STALE_FILE" | tr -d ' ')):${OFF}"
    sed "s/^/  /" "$STALE_FILE"
    echo
fi
[ "$LINKED_PROJECTS" -gt 0 ] && echo "$LINKS_MADE addon(s) $([ "$COPY_ADDONS" = "1" ] && echo copied || echo linked) across $LINKED_PROJECTS project(s)."
[ "$fail" -eq 0 ] && echo "${GRN}ok${OFF}" || echo "${RED}finished with errors${OFF}"
exit "$fail"
