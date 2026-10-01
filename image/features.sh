#!/usr/bin/env bash
#
# How the features fit together: checked here, for every build (the
# Containerfile's `features` stage), `just check` and CI.
#
#   features.sh SRC        only check SRC (a features/ directory)
#   features.sh SRC OUT    check, then sort SRC into what each build step reads
#
# Every feature has a pkg.yml:
#
#   packages: [...]         the RPMs it installs (required; [] for none)
#   exclude: [...]          RPMs kept out, such as weak dependencies that
#                           would only duplicate another
#   requires: [base, ...]   features this one needs in the same image
#   addon: true             not part of the base image, built on top of it
#                           for an image of its own (features/nvidia/)
#
# For each set, `base` (every feature that is not an add-on) and one per
# add-on, OUT gets:
#
#   OUT/<set>/packages/            install.txt and exclude.txt (one package per
#                                  line), and per feature its pre-/post-install.sh
#                                  and repo files: the package step, which then
#                                  stays cached when other files change
#   OUT/<set>/all/<feature>/       the whole feature, for finalize.sh
#   OUT/<set>/overlay/             the set's overlay/ trees, merged
#   OUT/<set>/builds/<feature>/    its build.sh and the files next to it (not
#                                  overlay/, pkg.yml or the other scripts), for
#                                  image/builds.sh
#   OUT/overlay-paths.txt          every feature's overlay paths, for
#                                  finalize.sh to check the builds against
#
set -euo pipefail
shopt -s nullglob

src=$1 out=${2:+$(realpath -m "$2")}
cd "$src"

# pkg.yml is read once per feature, as JSON; jq does the rest. yq comes in
# two kinds with different flags: Go (mikefarah) in the image and on GitHub's
# runners, Python (a jq wrapper, JSON by default) on some hosts.
if yq --version 2>&1 | grep -q mikefarah; then
    json() { yq -o=json '.' "$1"; }
else
    json() { yq '.' "$1"; }
fi

# Every feature as one JSON line: its name, its pkg.yml ("missing" when there
# is none) and whether it has a build.sh that can run.
doc=''
for dir in */; do
    feature=${dir%/}
    case $feature in
        *[!a-z0-9-]*) echo "feature names are lower-case letters, digits and -: $feature" >&2; exit 1 ;;
    esac
    pkg='"missing"'
    if [ -e "$feature/pkg.yml" ]; then pkg=$(json "$feature/pkg.yml"); fi   # fails on invalid YAML
    build=none
    if [ -e "$feature/build.sh" ]; then
        if [ -x "$feature/build.sh" ]; then build=yes; else build=not-executable; fi
    fi
    doc+="{\"name\": \"$feature\", \"build\": \"$build\", \"pkg\": ${pkg:-null}}"$'\n'
done
q() {
    jq -rs --arg s "${2:-}" '
        def addon: (.pkg | type) == "object" and .pkg.addon == true;
        def set: if addon then .name else "base" end;
        '"$1" <<<"$doc"
}

errors=$(q '
    (map({key: .name, value: .}) | from_entries) as $by
    | .[] | .name as $f | .pkg as $p
    | if $p == "missing" then "\($f) has no pkg.yml"
      elif ($p | type) != "object" then "\($f)/pkg.yml: needs at least `packages: []`"
      else
        ($p | keys[] | select(IN("packages", "exclude", "requires", "addon") | not)
            | "\($f)/pkg.yml: unknown key \(.)"),
        (select(($p.addon // false | type) != "boolean")
            | "\($f)/pkg.yml: addon must be true or false"),
        ("packages", "exclude", "requires" | . as $k
            | if ($p[$k] | type) == "array" or ($k != "packages" and $p[$k] == null) then
                  ($p[$k] // [])[] | select(type != "string") | "\($f)/pkg.yml: \($k) holds a non-name"
              else "\($f)/pkg.yml: \($k) must be a list" end),
        (($p.requires | arrays)[] | strings
            | if $by[.] == null then "\($f) requires \(.), which does not exist"
              elif ($by[.] | addon) then "\($f) requires \(.), an add-on, which nothing can require"
              else empty end),
        (select(.build == "not-executable") | "\($f)/build.sh is not executable"),
        (select(.build == "yes" and addon) | "\($f) is an add-on, which cannot have a build.sh")
      end')

# No two features ship the same file: the overlays are copied onto / one
# after the other, and the last would silently win.
overlay_paths() {
    find . -path './*/overlay/*' \( -type f -o -type l \) -printf '%P\n' | sed 's|^[^/]*/overlay/||' | LC_ALL=C sort
}
dupes=$(overlay_paths | uniq -d | sed 's/^/shipped by more than one feature: /')

if [ -n "$errors$dupes" ]; then
    printf '%s\n' "$errors" "$dupes" | sed '/^$/d' >&2
    exit 1
fi
[ -n "$out" ] || exit 0

mkdir -p "$out"
overlay_paths >"$out/overlay-paths.txt"
for set in $(q '[.[] | set] | unique[]'); do
    mkdir -p "$out/$set/packages" "$out/$set/all" "$out/$set/overlay" "$out/$set/builds"
    q '.[] | select(set == $s) | .pkg.packages[]' "$set" >"$out/$set/packages/install.txt"
    q '.[] | select(set == $s) | (.pkg.exclude // [])[]' "$set" >"$out/$set/packages/exclude.txt"
    for feature in $(q '.[] | select(set == $s) | .name' "$set"); do
        cp -a "$feature" "$out/$set/all/"
        for file in "$feature"/pre-install.sh "$feature"/post-install.sh "$feature"/overlay/etc/yum.repos.d; do
            if [ -e "$file" ]; then cp -a --parents "$file" "$out/$set/packages/"; fi
        done
        if [ -d "$feature/overlay" ]; then cp -a "$feature/overlay/." "$out/$set/overlay/"; fi
        # A build gets what it may use and nothing that would rerun it for no
        # reason: build.sh and the files next to it (a spec, a patch).
        if [ -e "$feature/build.sh" ]; then
            mkdir -p "$out/$set/builds/$feature"
            for file in "$feature"/*; do
                case ${file#*/} in
                    overlay|pkg.yml|pre-install.sh|post-install.sh|setup.sh) ;;
                    *) cp -a "$file" "$out/$set/builds/$feature/" ;;
                esac
            done
        fi
    done
done
