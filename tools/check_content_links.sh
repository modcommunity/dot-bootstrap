#!/usr/bin/env bash
# Content-link and selector checks for bootstrap.sh and bootstrap.ps1. Run it from anywhere;
# it changes nothing outside a temp directory and clones nothing (it uses --plan).
#
# 1. Every game in projects.tsv, from its sibling checkout's .gitignore: each
#    "# bootstrap-link: <repo>/<dir>" target is listed in projects.tsv, exists in that repo's
#    checkout, is cloned AND linked by a default plan, and survives bootstrap.ps1's regex.
#    Every "# bootstrap-optional" pack line is linked by default and dropped under --min.
# 2. Every *-maps repository and every weapon or monster pack is linked by some game.
# 3. The selectors: default, one game, a group, --zees-games-min, --min, --addons and an
#    unknown name (a clear error, exit 2).
# 4. The 'ci' form of a link line is linked by both scripts (the .ps1 regex once rejected it).
#
# The sibling checkouts are read only for their .gitignore and directory names. If pwsh is
# installed its -Plan output is compared line for line with bootstrap.sh's.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
sib="$(cd "$here/.." && pwd)"
tsv="$here/projects.tsv"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
bad() { echo "FAIL $*"; fail=1; }

plan() { DOT_PROJECTS="$tmp/empty" DOT_PLAN_FROM="$sib" "$here/bootstrap.sh" --plan "$@" 2>&1; }
mkdir -p "$tmp/empty"

listed() { grep -v '^[[:space:]]*#' "$tsv" | cut -f1 | grep -qxF "$1"; }
games=$(grep -v '^[[:space:]]*#' "$tsv" | cut -f1 | grep -E '^(game|mg)-' | grep -v -- '-maps$')
[ "$(echo "$games" | wc -l)" -ge 14 ] || bad "fewer than 14 games found in projects.tsv"

default_plan="$(plan)"
ps_regex_ok() { # the exact pattern bootstrap.ps1 uses for a link line
    grep -qF "'^# bootstrap-link: (\\S+)(\\s+ci)?\\s*\$'" "$here/bootstrap.ps1"
}
ps_regex_ok || bad "bootstrap.ps1 Link-Content pattern lacks the ci form"
have_pwsh=0; command -v pwsh >/dev/null && have_pwsh=1
if [ $have_pwsh = 1 ]; then
    ps_plan="$(DOT_PROJECTS="$tmp/empty" DOT_PLAN_FROM="$sib" pwsh -NoProfile -File "$here/bootstrap.ps1" -Plan 2>&1)"
    [ "$ps_plan" = "$default_plan" ] || { bad "bootstrap.ps1 -Plan differs from bootstrap.sh --plan"; diff <(echo "$default_plan") <(echo "$ps_plan") | head -10; }
fi

printf '%-22s %-40s %-8s %-8s %s\n' game "content repos" ".sh" ".ps1" status
linked_repos=""
for g in $games; do
    gi="$sib/$g/.gitignore"
    if [ ! -f "$gi" ]; then bad "$g: no checkout beside dot-bootstrap, cannot audit"; continue; fi
    repos=""; shline=ok; psline=ok; st=ok
    while read -r line; do
        spec="$(awk '{print $3}' <<< "$line")"; repo="${spec%%/*}"; dir="${spec#*/}"
        repos="$repos $repo"; linked_repos="$linked_repos $repo"
        listed "$repo" || { bad "$g: link target $repo is not in projects.tsv"; st=FAIL; }
        [ -d "$sib/$repo/$dir" ] || { bad "$g: $spec does not exist in the $repo checkout"; st=FAIL; }
        grep -qx "clone $repo\|have $repo" <<< "$default_plan" || { bad "$g: $repo is not cloned by default"; st=FAIL; shline=MISSING; }
        # the linked path is the .gitignore line below the comment, not necessarily $dir
        path="$(awk -v s="$spec" '$0 ~ "^# bootstrap-link: "s"( |$)"{f=1;next} f&&/^\//{sub("^/","");sub("/$","");print;exit} {f=0}' "$gi")"
        want="link $g content $path -> $spec"
        grep -qxF "$want" <<< "$default_plan" || { bad "$g: bootstrap.sh does not link '$want'"; st=FAIL; shline=MISSING; }
        printf '%s\n' "# bootstrap-link: $spec" | grep -qE '^# bootstrap-link: (\S+)(\s+ci)?\s*$' || { bad "$g: ps1 pattern rejects $spec"; psline=NO; st=FAIL; }
    done < <(grep '^# bootstrap-link: ' "$gi")
    while read -r a; do
        [ -n "$a" ] || continue
        grep -qxF "link $g addon $a" <<< "$default_plan" || { bad "$g: optional pack $a is not linked by default"; st=FAIL; }
        min="$(plan "$g" --min)"
        grep -qxF "link $g addon $a" <<< "$min" && { bad "$g: --min still links optional pack $a"; st=FAIL; }
        repos="$repos $(grep -qx "clone ${a//_/-}\|have ${a//_/-}" <<< "$default_plan" && echo "${a//_/-}")"
        linked_repos="$linked_repos ${a//_/-}"
    done < <(awk '/^# bootstrap-optional/{o=1;next} o&&/^\/addons\//{sub("^/addons/","");print} {o=0}' "$gi")
    # --min must drop every content line
    plan "$g" --min | grep -q "^link $g content " && { bad "$g: --min still links content"; st=FAIL; }
    printf '%-22s %-40s %-8s %-8s %s\n' "$g" "$(echo ${repos:-none} | tr " " "\n" | awk '!s[$0]++' | paste -sd" ")" "$shline" "$psline" "$st"
done

# Every maps repository and weapon/monster pack must be linked by some game.
for r in $(grep -v '^[[:space:]]*#' "$tsv" | cut -f1 | grep -E -- '-maps$|^zz-|^z[a-z]+-dot-weapons$'); do
    case " $linked_repos " in *" $r "*) ;; *)
        # zee/zed weapons are addons (/addons/zee_weapons): linked when any plan names them.
        grep -q "addon ${r/-dot-/_}$" <<< "$default_plan" || bad "$r is never linked by any game's .gitignore" ;;
    esac
done

# --- selectors ---
out="$(plan)"
[ "$(grep -c '^clone ' <<< "$out")" -eq "$(grep -v '^[[:space:]]*#' "$tsv" | grep -c .)" ] || bad "default plan does not clone every project in projects.tsv"
out="$(plan game-arena)"
grep -qx 'clone game-arena' <<< "$out" && grep -qx 'clone arena-surf-dm-maps' <<< "$out" && grep -qx 'clone dot-core' <<< "$out" \
    && ! grep -qx 'clone mg-wipeout' <<< "$out" || bad "one game: want game-arena, its maps and addons, no other game"
out="$(plan arena --games wipeout)"
grep -qx 'clone mg-wipeout-maps' <<< "$out" && grep -qx 'clone arena-surf-dm-maps' <<< "$out" || bad "short names / --games selection"
out="$(plan zees-games)"
for g in $games; do grep -qx "clone $g" <<< "$out" || bad "group zees-games lacks $g"; done
grep -qx 'clone zz-modern-weapons' <<< "$out" || bad "group zees-games did not pull zz-modern-weapons"
out="$(plan --zees-games-min)"
for g in $games; do grep -qx "clone $g" <<< "$out" || bad "--zees-games-min lacks $g"; done
grep -E '^clone .*(-maps|^zz-)|^link .* content' <<< "$out" | grep -q . && bad "--zees-games-min cloned or linked content"
grep -qE '^clone zz-' <<< "$out" && bad "--zees-games-min cloned a zz pack"
grep -qx 'clone dot-core' <<< "$out" || bad "--zees-games-min lacks the addons"
out="$(plan mg-wipeout --min)"
grep -qx 'clone mg-wipeout-maps' <<< "$out" && bad "--min cloned maps"
out="$(plan --addons dot-core,weapon)"
grep -qx 'clone dot-weapon' <<< "$out" && grep -qx 'clone dot-core' <<< "$out" && ! grep -q '^clone game-' <<< "$out" || bad "--addons selection"
out="$("$here/bootstrap.sh" --plan no-such-game 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q "no project or group called 'no-such-game'" <<< "$out" || bad "unknown name: want exit 2 and a clear error, got $rc: $out"
"$here/bootstrap.sh" --plan --games dot-core >/dev/null 2>&1; [ $? = 2 ] || bad "--games dot-core (an addon) should be refused"

# --- the 'ci' form really links under both scripts' rules ---
mkdir -p "$tmp/mg-wipeout/addons" "$tmp/mg-wipeout-maps/courses"
printf '# bootstrap-link: mg-wipeout-maps/courses ci\n/courses\n' > "$tmp/mg-wipeout/.gitignore"
git -C "$tmp/mg-wipeout" init -q
DOT_PROJECTS="$tmp" "$here/bootstrap.sh" --links --only mg-wipeout --no-deps >/dev/null 2>&1
[ -L "$tmp/mg-wipeout/courses" ] && [ -d "$tmp/mg-wipeout/courses" ] || bad "bootstrap.sh did not link a 'ci' content line"
rm "$tmp/mg-wipeout/courses"
DOT_PROJECTS="$tmp" "$here/bootstrap.sh" --links --min --only mg-wipeout --no-deps >/dev/null 2>&1
[ -e "$tmp/mg-wipeout/courses" ] && bad "--links --min linked content"
if [ $have_pwsh = 1 ]; then
    pwsh -NoProfile -Command "if ('# bootstrap-link: mg-wipeout-maps/courses ci' -notmatch '^# bootstrap-link: (\S+)(\s+ci)?\s*\$') { exit 1 }" \
        || bad "bootstrap.ps1 pattern rejects a 'ci' line"
else
    echo "note: pwsh not installed; bootstrap.ps1 checked by pattern text only"
fi

[ $fail = 0 ] && echo "content links: ok"
exit $fail
