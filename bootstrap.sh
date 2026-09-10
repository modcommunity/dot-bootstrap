#!/usr/bin/env bash
#
# Clone or update every project in the Dot family, wire the local-development
# addon links, and run any of the games.
#
#   ./bootstrap.sh                 clone what is missing, pull what is not, link
#   ./bootstrap.sh --links         only redo the links, touch no repository
#   ./bootstrap.sh --status        report each repository, change nothing
#   ./bootstrap.sh --check         verify the list against the disk, change nothing
#   ./bootstrap.sh --list          what can be played
#   ./bootstrap.sh --play arena    play one, offline, no server needed
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
# that rule is thirty-odd clones and a hundred-odd links to set up by hand on
# every machine, which is exactly the sort of thing nobody does correctly twice.
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
elif [ "$(basename "$(dirname "$REPO_DIR")")" = "godot" ]; then
    # This repository is itself a project directory: <tree>/godot/bootstrap.
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

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; DIM=$'\033[2m'; OFF=$'\033[0m'
fail=0

say()  { printf '%-22s %s\n' "$1" "$2"; }
warn() { printf '%-22s %s\n' "$1" "${YLW}$2${OFF}"; }
err()  { printf '%-22s %s\n' "$1" "${RED}$2${OFF}"; fail=1; }

[ -f "$LIST" ] || { echo "${RED}missing projects.tsv beside $REAL_SELF${OFF}" >&2; exit 2; }

# name<TAB>url, comments and blank lines dropped.
projects() { grep -v '^[[:space:]]*#' "$LIST" | grep -v '^[[:space:]]*$' | cut -f1; }
url_for()  { grep -v '^[[:space:]]*#' "$LIST" | awk -F'\t' -v p="$1" '$1==p{print $2; exit}'; }

# The addons a project needs linked in, read out of its own .gitignore. A
# project's own addon is never in there -- dot-net ignores dot_core and ships
# dot_net -- which is exactly the distinction wanted.
links_for() {
    local gi="$PROJECTS_DIR/$1/.gitignore"
    [ -f "$gi" ] || return 0
    # /addons/ on its own means "ignore the lot" (dot-server-setup-test vendors
    # its addons with setup.sh) and names nothing to link.
    grep -oE '^/addons/[a-z0-9_]+$' "$gi" 2>/dev/null | sed 's|^/addons/||'
}

# --- Repositories ----------------------------------------------------------

sync_repo() {
    local proj="$1"; local dir="$PROJECTS_DIR/$proj"; local url; url="$(url_for "$proj")"

    if [ ! -d "$dir/.git" ]; then
        if [ "$url" = "LOCAL" ]; then
            err "$proj" "has no remote -- it exists only on the machine that made it"
            return
        fi
        if git clone -q "$url" "$dir" 2>/dev/null; then
            # A repository created on GitHub and never pushed to clones fine and
            # has no HEAD, so rev-parse fails. Say so rather than leaking its
            # "fatal: Needed a single revision" to the terminal.
            local at; at="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
            say "$proj" "${GRN}cloned${OFF} ${at:-${YLW}empty — nothing pushed to it yet${OFF}}"
            [ -n "$HUB" ] && git -C "$dir" remote add hub "$HUB/$proj.git" 2>/dev/null
        else
            err "$proj" "clone failed from $url"
        fi
        return
    fi

    if [ "$url" = "LOCAL" ]; then
        warn "$proj" "no remote; nothing to pull. Push it or it stays on this machine."
        return
    fi

    # Never clobber work in progress. A dirty tree is reported and skipped,
    # because the whole point of several machines is that any one of them may
    # be holding the only copy of something.
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        warn "$proj" "dirty, left alone ($(git -C "$dir" status --porcelain | wc -l) file(s))"
        return
    fi

    local before; before=$(git -C "$dir" rev-parse --short HEAD)
    if git -C "$dir" pull -q --ff-only 2>/dev/null; then
        local after; after=$(git -C "$dir" rev-parse --short HEAD)
        [ "$before" = "$after" ] \
            && say "$proj" "${DIM}up to date${OFF} $after" \
            || say "$proj" "${GRN}updated${OFF} $before -> $after"
    else
        err "$proj" "pull refused - diverged, or no upstream. Resolve by hand."
    fi
}

# --- Links -----------------------------------------------------------------

link_addons() {
    local proj="$1"; local dir="$PROJECTS_DIR/$proj"
    [ -d "$dir" ] || return 0

    local addons; addons="$(links_for "$proj")"
    [ -n "$addons" ] || return 0

    mkdir -p "$dir/addons"
    local made=0 addon src
    while read -r addon; do
        [ -n "$addon" ] || continue
        # dot_user_avatar -> dot-user-avatar. True for every link in the family.
        src="${addon//_/-}"
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
        ln -s "../../$src/addons/$addon" "$dir/addons/$addon"
        made=$((made + 1))
    done <<< "$addons"
    say "$proj" "${DIM}linked $made addon(s)${OFF}"
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
    disk="$(cd "$PROJECTS_DIR" 2>/dev/null && for d in */; do
                d="${d%/}"
                [ "$PROJECTS_DIR/$d" = "$REPO_DIR" ] && continue
                [ -d "$d/.git" ] && echo "$d"
            done | sort)"

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

    # Directories that are not repositories: work in progress, or a clone that
    # failed halfway. Either way nothing else can obtain them.
    local d
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] || continue
        d="$(basename "${d%/}")"
        [ "$PROJECTS_DIR/$d" = "$REPO_DIR" ] && continue
        [ -d "$PROJECTS_DIR/$d/.git" ] && continue
        warn "$d" "a directory beside the projects that is not a git repository"
    done

    [ "$fail" -eq 0 ] && echo && say "" "${GRN}projects.tsv agrees with the disk${OFF}"
}

# --- Playing ---------------------------------------------------------------

find_godot() {
    local c
    for c in "${GODOT:-}" godot godot4 /usr/local/bin/godot "$HOME/.local/bin/godot"; do
        [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
    done
    return 1
}

# A game is a project whose directory begins with game-. Every one of them sets
# run/main_scene to something a person can sit down at, so there is no list of
# scenes here either.
games() { projects | grep '^game-'; }

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
    local proj="$want"
    [[ "$proj" == game-* ]] || proj="game-$proj"

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
        echo "${RED}Godot is not on PATH. Set GODOT=/path/to/godot.${OFF}" >&2; exit 3; }

    # --offline is what the clients that have a networked mode read to skip it;
    # the ones that do not have one ignore an unknown user argument. Either way
    # this needs no server, no dot-cloud and no downloads.
    echo "${CYN}$bin --path $PROJECTS_DIR/$proj -- --offline${OFF}"
    exec "$bin" --path "$PROJECTS_DIR/$proj" -- --offline "${@:2}"
}

# --- Modes -----------------------------------------------------------------

mode="${1:-sync}"

case "$mode" in
    --list|--play|--check|--status) : ;;   # must not create anything
    *) mkdir -p "$PROJECTS_DIR" ;;
esac

case "$mode" in
    --status)
        echo "projects: $PROJECTS_DIR"; echo
        while read -r p; do [ -n "$p" ] && status_repo "$p"; done <<< "$(projects)"
        ;;
    --check)
        check_list
        ;;
    --links)
        while read -r p; do [ -n "$p" ] && link_addons "$p"; done <<< "$(projects)"
        ;;
    --list)
        list_games; exit 0
        ;;
    --play)
        [ $# -ge 2 ] || { list_games; exit 2; }
        play_game "${@:2}"
        ;;
    sync|"")
        echo "projects: $PROJECTS_DIR"
        echo "base:     $GIT_BASE"; echo
        # Repositories first, all of them, then links -- a link can point into a
        # project that this same run is about to clone.
        while read -r p; do [ -n "$p" ] && sync_repo "$p"; done <<< "$(projects)"
        echo
        while read -r p; do [ -n "$p" ] && link_addons "$p"; done <<< "$(projects)"
        ;;
    -h|--help)
        sed -n '3,26p' "$REAL_SELF" | sed 's/^# \{0,1\}//'; exit 0
        ;;
    *)
        echo "usage: $0 [--links|--status|--check|--list|--play <game>]" >&2; exit 2
        ;;
esac

echo
[ "$fail" -eq 0 ] && echo "${GRN}ok${OFF}" || echo "${RED}finished with errors${OFF}"
exit "$fail"
