#!/bin/bash

set -e
set -o pipefail

v() { [ -n "$VERBOSE" ] && echo "$@" ; }

if command -v hunspell > /dev/null; then
    check_words() { hunspell -l; }
elif command -v aspell > /dev/null; then
    check_words() { aspell | grep '^[#&]' | cut -d' ' -f2; }
else
    echo "${0##*/}: No spell checker installed. Need hunspell or aspell." >&2
    exit 1
fi

extract_words() {
    pandoc -tjson "$@" | jq -r '
    # will be builtin in a future version of jq. is already in master
    # Apply f to composite entities recursively, and to atoms
    def walk(f):
      . as $in
      | if type == "object" then
          reduce keys[] as $key
            ( {}; . + { ($key):  ($in[$key] | walk(f)) } ) | f
      elif type == "array" then map( walk(f) ) | f
      else f
      end;

    # strip code
    walk (
      if (type == "object") then
        if (.t == "CodeBlock" or .t == "Code") then
          empty
        else
          .
        end
      else
        .
      end
    ) |

    # extract raw string nodes
    .. | select(type=="object" and has("t") and .t=="Str") | .c
    '
}

find_suspects() {
    local workdir=$1
    local outdir=$2
    mkdir -p "$outdir"
    v "Parsing $outdir..."
    find "$workdir" -mindepth 1 -type d -printf '%P\0' \
      | ( cd "$outdir" && xargs -0 mkdir -p ) >&2
    find "$workdir" -type f -name '*.html' -printf '%P\0' \
      | while read -d '' f; do
        extract_words "${workdir}/${f}" | check_words | sort -u \
          > "${outdir}/${f}.wrong"
    done
}

check_one() {
    local ref=$1
    local checkout="${d}/${ref}.checkout"
    [ -d "$checkout" ] && { v "Using cached $ref"; return; }
    local tree="${d}/${ref}.suspects.tree"
    local flat="${d}/${ref}.suspects.flat"
    v "Checking out $ref..."
    mkdir -p "$checkout"
    git --work-tree="$checkout" checkout "$ref" -- .
    v "Building $ref..."
    ( cd "$checkout" && make > /dev/null )
    find_suspects "$checkout/_site" "$tree"
    find "$tree" -type f -exec cat {} + | sort -u > "$flat"
}

diff_two() {
    local old=$1
    local new=$2
    local cmp="${d}/${old}..${new}"
    check_one "$old"
    check_one "$new"
    [ -e "${cmp}.plusminus" ] && { v "Using cached diff"; return; }
    diff -urd "$d"/{"${old}","${new}"}.suspects.tree > "${cmp}.diff.tree" || :
    diff -ur  "$d"/{"${old}","${new}"}.suspects.flat > "${cmp}.diff.flat" || :
    grep -v '^\( \|@\|+++\|---\)' < "${cmp}.diff.flat" | LC_ALL=C sort \
      > "${cmp}.plusminus" || :
    grep '^+' < "${cmp}.plusminus" > "${cmp}.plus" || :
    grep '^-' < "${cmp}.plusminus" > "${cmp}.minus" || :
}

show() {
    local ref=$1
    while read -d $'\n' suspect; do
        ( cd "$d/${ref}.checkout" && \
          find -type f -exec grep --color=always -rHnwF "$suspect" {} + )
    done
}


if [ -n "$SPELL_CHECK_CACHE" ]; then
    d=$SPELL_CHECK_CACHE
    mkdir -p "$d"
    echo "Using spell check cache dir: $d"
else
    d=$(mktemp -d)
    trap 'rm -rf "$d"' EXIT
fi

case $# in
0)
    old=$(git rev-parse HEAD)
    new=$(git rev-parse refs/remotes/origin/master)
    ;;
1)
    old=$(git rev-parse "$1"^)
    new=$(git rev-parse "$1")
    ;;
2)
    old=$(git rev-parse "$1")
    new=$(git rev-parse "$2")
    ;;
*)
    echo "Usage: ${0##*/} [[old-ref] new-ref]" >&2
    exit 2
esac

diff_two "$old" "$new"

ansi() { cc=$1; shift; printf "\x1b[${cc}m%s\x1b[0m\n" "$*" ; }
red() { ansi 31 "$@" ; }
green() { ansi 32 "$@" ; }

plus=${d}/${old}..${new}.plus
minus=${d}/${old}..${new}.minus

echo "Spelling report for ${old:0:8}..${new:0:8}:"
echo
if [ -s "$plus" ]; then
    red 'The following new unknown spellings were introduced:'
    sed 's/^/	/' < "$plus"
else
    green 'No new unique misspellings were introduced.'
fi
if [ -s "$minus" ]; then
    echo
    echo 'In addition, the following suspicious spellings were eliminated:'
    sed 's/^/	/' < "$minus"
fi

# exit 0 if no new unknown unique spellings were introduced, 1 otherwise
test -s "$plus"