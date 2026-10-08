#!/usr/bin/env bash
#
# Builds what Fedora does not package: every base feature's build.sh, run by
# image/base.Containerfile's `builds` stage. That stage starts from the image's
# base, so what it builds links against the libraries the image ships and a
# base update rebuilds it, and it is thrown away, so no toolchain reaches the
# image. The builds run one after the other in that one system: a package one
# of them installs is there for the next.
#
# A build runs in a directory holding its build.sh and the files next to it
# (image/features.sh picks them) and leaves its results in $OUT: RPMs in
# $OUT/rpm, which image/packages.sh installs with the packages, and files in
# $OUT/root, which land on / like an overlay. Merged here into /out/rpm and
# /out/root; /out/root-paths.txt lists the files, for image/finalize.sh to
# check against the overlays.
#
set -euo pipefail
shopt -s nullglob

CTX=${CTX:-/ctx}
mkdir -p /out/rpm /out/root /tmp/builds

for build in "$CTX"/builds/*/build.sh; do
    dir=${build%/build.sh}
    feature=${dir##*/}
    echo "=== $feature/build.sh" >&2
    mkdir -p "/tmp/builds/$feature"
    if ! (cd "$dir" && OUT=/tmp/builds/$feature "$build"); then
        echo "$feature/build.sh failed" >&2
        exit 1
    fi
done

# Merged, and nothing made by two builds: the second would silently win.
# RPMs come out flat, wherever under $OUT/rpm a build put them (rpmbuild
# writes <arch>/ subdirectories).
cd /tmp/builds
root_paths=$(find . -path './*/root/*' \( -type f -o -type l \) -printf '%P\n' | sed 's|^[^/]*/root/||' | LC_ALL=C sort)
rpms=$(find . -path './*/rpm/*' -name '*.rpm' -printf '%f\n' | LC_ALL=C sort)
dupes=$(uniq -d <<<"$root_paths$(printf '\n%s' "$rpms")" | sed '/^$/d')
test -z "$dupes" || { printf 'made by more than one build:\n%s\n' "$dupes" >&2; exit 1; }
find . -path './*/rpm/*' -name '*.rpm' -exec cp -a -t /out/rpm/ {} +
for out in ./*/root; do cp -a "$out/." /out/root/; done
printf '%s\n' "$root_paths" | sed '/^$/d' >/out/root-paths.txt
ls -lR /out >&2
