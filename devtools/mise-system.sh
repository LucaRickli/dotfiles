#!/bin/sh
#
# The system part of mise (tools.txt) in a PREFIX that install.sh filled:
# its settings (mise-config.toml) as ETC/config.toml, and the Go and Deno of
# tools.txt as mise's installs of their versions in PREFIX/share/mise, so a
# project that names those versions gets them offline, with no download,
# and `mise ls` lists them. AT is where PREFIX is when the image runs
# (default PREFIX; the Flatpak builds /app in a directory of its own). The
# dev container's dirs are mise's defaults (/etc/mise, /usr/local/share/mise);
# the Flatpak names its own (MISE_SYSTEM_*, flatpak/build.sh).
#
#   devtools/mise-system.sh PREFIX ETC [AT]
set -eu

usage='usage: mise-system.sh PREFIX ETC [AT]'
here=$(dirname "$0")
prefix=${1:?$usage}
etc=${2:?$usage}
at=${3:-$prefix}
data=$prefix/share/mise

install -Dm644 "$here/mise-config.toml" "$etc/config.toml"
# mise looks for this two levels above its binary: the image's copy changes
# with the image, never through `mise self-update`.
install -Dm644 /dev/null "$prefix/lib/mise/.disable-self-update"

# The version on a tools.txt line, without a leading "v".
version() { awk -v n="$1" '$1 == n { sub(/^v/, "", $2); print $2 }' "$here/tools.txt"; }
go=$(version go) deno=$(version deno)

# Relative links, right wherever PREFIX is. Go whole: mise sets GOROOT to the
# install. Deno as a bin of its own: mise puts the install's bin first on
# PATH, and PREFIX/bin would bring every tool along.
mkdir -p "$data/installs/go" "$data/installs/deno/$deno/bin" "$data/shims"
ln -s ../../../../go "$data/installs/go/$go"
ln -s ../../../../../../bin/deno "$data/installs/deno/$deno/bin/deno"

# What mise adds next to an install of its own, and checks on every `mise
# use`: a link for each shorter version (1.27 and 1 for 1.27.1) and latest,
# and a shim per executable, a link to mise as the image runs it. Made here
# because mise cannot change a read-only PREFIX (in a container it asks for
# sudo), so without them every `mise use` fails.
finish() {
    short=$2
    while [ "${short%.*}" != "$short" ]; do
        short=${short%.*}
        ln -s "./$2" "$data/installs/$1/$short"
    done
    ln -s "./$2" "$data/installs/$1/latest"
    for bin in "$data/installs/$1/$2/bin/"*; do
        ln -s "$at/bin/mise" "$data/shims/${bin##*/}"
    done
}
finish go "$go"
finish deno "$deno"
