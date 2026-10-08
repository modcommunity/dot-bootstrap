#!/usr/bin/env bash
#
# Clone or update every project in the Dot family, wire the local-development
# addon links, and run any of the games.
#
#   ./bootstrap.sh                 clone what is missing, pull what is not, link
#   ./bootstrap.sh --links         only redo the links, touch no repository
#   ./bootstrap.sh --content-keys  make a content signing keypair, to publish packs
#   ./bootstrap.sh --status        report each repository, change nothing
#   ./bootstrap.sh --check         verify the list against the disk, change nothing
#   ./bootstrap.sh --list          what can be played
#   ./bootstrap.sh --play arena    play one, offline, no server needed
#   ./bootstrap.sh --links --copy  copy the addons instead of linking them
#   ./bootstrap.sh --ssh           clone over SSH (to push from this machine); HTTPS is the default
#   ./bootstrap.sh --only arena,wipeout   only these, plus the addon and map repos they need
#   ./bootstrap.sh --only 'mg-*' --no-deps  only these, and nothing they need
#
# --only works with every mode (sync, --links, --status). A name is a project
# from projects.tsv, or its short form (arena = game-arena, wipeout = mg-wipeout,
# core = dot-core), or a glob. Set DOT_ONLY to make a selection stick. Addons
# are linked (or copied) into the named projects only.
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
    # /addons/ on its own means "ignore the lot" (dot-server-deploy vendors
    # its addons with setup.sh) and names nothing to link.
    grep -oE '^/addons/[a-z0-9_]+$' "$gi" 2>/dev/null | sed 's|^/addons/||'
}

# Which repository an addon comes from. dot_user_avatar -> dot-user-avatar covers every
# dot-* addon, but not a game's own pack: zee_weapons lives in zee-dot-weapons, and the
# name rule sent every game that used it looking for a zee-weapons nobody has. Rather
# than a table of exceptions, ask the checkouts: the owner is the project that HAS the
# folder and does not ignore it -- every consumer ignores it, linked or copied, and
# dot-server-deploy, which vendors a copy of everything, ignores /addons/ whole.
addon_source() {
    local addon="$1" src="${1//_/-}" d
    if [ -d "$PROJECTS_DIR/$src/addons/$addon" ]; then echo "$src"; return 0; fi
    for d in "$PROJECTS_DIR"/*/; do
        d="${d%/}"
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

listed() { projects | grep -qxF "$1"; }

# A name as typed -> the projects it means, or nothing.
resolve_name() {
    local n="$1" p
    case "$n" in
        *[*?[]*) projects | while read -r p; do [[ "$p" == $n ]] && echo "$p"; done; return ;;
    esac
    for p in "$n" "game-$n" "mg-$n" "dot-$n"; do listed "$p" && { echo "$p"; return; }; done
}

# The listed repository an addon comes from, clone or no clone. The name rule first;
# then a checkout that owns it; then the listed name it matches with every "dot-"
# taken out -- zee_weapons is zee-dot-weapons -- which is unambiguous because no two
# names in projects.tsv are equal that way (`--check`'s neighbour, measured 10-07).
addon_repo() {
    local src="${1//_/-}" p
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
        [ -n "$src" ] && listed "${src%%/*}" && echo "${src%%/*}"
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

sync_selected() {
    [ ${#ONLY[@]} -eq 0 ] && { while read -r p; do [ -n "$p" ] && sync_repo "$p"; done <<< "$(projects)"; return; }
    local -A seen=(); local queue=("${ONLY[@]}") p d
    while [ ${#queue[@]} -gt 0 ]; do
        p="${queue[0]}"; queue=("${queue[@]:1}")
        [ -n "${seen[$p]:-}" ] && continue
        seen[$p]=1
        sync_repo "$p"
        [ "$NO_DEPS" = "1" ] && continue
        while read -r d; do [ -n "$d" ] && queue+=("$d"); done <<< "$(deps_of "$p")"
    done
}

# --- Repositories ----------------------------------------------------------

sync_repo() {
    local proj="$1"; local dir="$PROJECTS_DIR/$proj"; local url; url="$(url_for "$proj")"

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

        if git clone -q "$effective" "$dir" 2>/dev/null; then
            # A repository created on GitHub and never pushed to clones fine and
            # has no HEAD, so rev-parse fails. Say so rather than leaking its
            # "fatal: Needed a single revision" to the terminal.
            local at; at="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
            say "$proj" "${GRN}cloned${OFF} ${at:-${YLW}empty — nothing pushed to it yet${OFF}}"
            [ -n "$HUB" ] && git -C "$dir" remote add hub "$HUB/$proj.git" 2>/dev/null
        else
            err "$proj" "clone failed from $effective"
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

    local origin; origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"
    local net=(); mapfile -t net < <(https_for "$origin")

    # A clone of a repository that had nothing pushed to it yet has no HEAD, and
    # pulling into it fails with "no such ref was fetched" until somebody pushes.
    # That is not an error on this machine, so it is not reported as one.
    local before; before=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    if [ -z "$before" ] && [ -z "$(git "${net[@]}" -C "$dir" ls-remote --heads origin 2>/dev/null)" ]; then
        warn "$proj" "empty — nothing pushed to it yet"
        return
    fi

    if git "${net[@]}" -C "$dir" pull -q --ff-only 2>/dev/null; then
        local after; after=$(git -C "$dir" rev-parse --short HEAD)
        if [ -z "$before" ]; then say "$proj" "${GRN}first commits${OFF} $after"
        elif [ "$before" = "$after" ]; then say "$proj" "${DIM}up to date${OFF} $after"
        else say "$proj" "${GRN}updated${OFF} $before -> $after"; fi
    else
        case "$origin" in
            *@*:*|ssh://*)
                if [ "$USE_HTTPS" = "1" ]; then
                    err "$proj" "pull failed over HTTPS too - diverged, no upstream, or not reachable. Resolve by hand."
                else
                    err "$proj" "pull failed. origin is SSH; if you have no key here, drop --ssh, or run:"
                    say ""       "  git -C '$dir' remote set-url origin $(to_https "$origin")"
                fi ;;
            *)  err "$proj" "pull refused - diverged, or no upstream. Resolve by hand." ;;
        esac
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
    local gi="$PROJECTS_DIR/$1/.gitignore"
    [ -f "$gi" ] || return 0
    awk '/^# bootstrap-link: /{src=$3; next} src!="" && /^\//{print $0 "\t" src} {src=""}' "$gi"
}

link_content() {
    local proj="$1"; local dir="$PROJECTS_DIR/$proj" path src rel up
    [ -d "$dir" ] || return 0
    while IFS=$'\t' read -r path src; do
        [ -n "$path" ] || continue
        path="${path#/}"; path="${path%/}"
        if [ ! -d "$PROJECTS_DIR/$src" ]; then
            warn "$proj" "content missing: $src (clone ${src%%/*} for $path)"
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

# --copy, --ssh, --https, --only and --no-deps may accompany any mode; strip them before
# the mode is read.
ARGS=()
only_raw="${DOT_ONLY:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --copy)    COPY_ADDONS=1 ;;
        --ssh)     USE_HTTPS=0 ;;
        --https)   USE_HTTPS=1 ;;   # the default; still accepted
        --no-deps) NO_DEPS=1 ;;
        --only)    [ $# -ge 2 ] || { echo "${RED}--only needs a name${OFF}" >&2; exit 2; }
                   only_raw="$only_raw,$2"; shift ;;
        --only=*)  only_raw="$only_raw,${1#--only=}" ;;
        *)         ARGS+=("$1") ;;
    esac
    shift
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# A name that matches nothing is an error, not an empty selection: an empty one
# would quietly mean "everything", which is the opposite of what was asked.
IFS=', ' read -ra _names <<< "$only_raw"
for n in "${_names[@]+"${_names[@]}"}"; do
    [ -n "$n" ] || continue
    _hit="$(resolve_name "$n")"
    [ -n "$_hit" ] || { echo "${RED}--only: no project called $n in projects.tsv${OFF}" >&2; exit 2; }
    while read -r p; do ONLY+=("$p"); done <<< "$_hit"
done

mode="${1:-sync}"

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


case "$mode" in
    --list|--play|--check|--status) : ;;   # must not create anything
    *) mkdir -p "$PROJECTS_DIR" ;;
esac

case "$mode" in
    --status)
        echo "projects: $PROJECTS_DIR"; echo
        while read -r p; do [ -n "$p" ] && status_repo "$p"; done <<< "$(selected)"
        ;;
    --check)
        check_list
        ;;
    --links)
        while read -r p; do [ -n "$p" ] && { link_addons "$p"; link_content "$p"; }; done <<< "$(link_targets)"
        ;;
    --content-keys)
        content_keys || fail=1
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
        [ ${#ONLY[@]} -gt 0 ] && echo "only:     ${ONLY[*]}$([ "$NO_DEPS" = "1" ] && echo " (no deps)")" && echo
        sync_selected
        echo
        while read -r p; do [ -n "$p" ] && { link_addons "$p"; link_content "$p"; }; done <<< "$(link_targets)"
        ;;
    -h|--help)
        sed -n '3,32p' "$REAL_SELF" | sed 's/^# \{0,1\}//'; exit 0
        ;;
    *)
        echo "usage: $0 [--links|--status|--check|--list|--play <game>]" >&2; exit 2
        ;;
esac

echo
[ "$LINKED_PROJECTS" -gt 0 ] && echo "$LINKS_MADE addon(s) $([ "$COPY_ADDONS" = "1" ] && echo copied || echo linked) across $LINKED_PROJECTS project(s)."
[ "$fail" -eq 0 ] && echo "${GRN}ok${OFF}" || echo "${RED}finished with errors${OFF}"
exit "$fail"
