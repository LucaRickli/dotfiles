#!/usr/bin/env bash
#
# Install the tools pinned in tools.txt (the format is described there) into
# a prefix: executables in PREFIX/bin, Go in PREFIX/go, Rust in PREFIX/rustup
# and PREFIX/cargo. With NAMEs, only those lines. --list reads another file
# in the same format instead (extensions.txt, the VS Code extensions).
#
#   devtools/install.sh [--list FILE] PREFIX [NAME...]
#
# Nothing is installed unverified: a download must match upstream's sha256
# (or the pinned one), go install checks sum.golang.org, rustup checks the
# channel manifest. Needs bash, curl, sha256sum, tar with gzip and xz, unzip.
set -euo pipefail

pins=$(dirname "$0")/tools.txt
if [ "${1:-}" = --list ]; then
    pins=${2:?usage: install.sh [--list FILE] PREFIX [NAME...]}
    shift 2
fi
prefix=${1:?usage: install.sh [--list FILE] PREFIX [NAME...]}
shift
only=" $* "
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Tools build with the Go this file installs, not whatever else is on PATH.
# -modcacherw keeps the module cache deletable (go writes it read-only).
export PATH="$prefix/go/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-modcacherw \
    GOPATH="$work/gopath" GOCACHE="$work/gocache"
mkdir -p "$prefix/bin"

# GitHub resets release downloads often enough to matter.
fetch() { curl -fsSL --retry 5 --retry-all-errors -o "$2" "$1"; }

# The sha256 for file $1 from the checksum file on stdin: a bare hash (kubectl
# and go publish one without a trailing newline), or its "hash  name" or
# "hash *name" line (rustup writes *./name) in a file that lists every asset
# of the release.
pick() {
    local h f
    while read -r h f _ || [ -n "$h" ]; do
        f=${f#\*} f=${f#./}
        if [[ $h =~ ^[0-9a-f]{64}$ ]] && { [ -z "$f" ] || [ "$f" = "$1" ]; }; then
            echo "$h"
            return 0
        fi
    done
    return 1
}

# fd 3: nothing in the loop body can read the list by accident.
while read -r name ver asset sum members <&3; do
    case $name in '' | '#'*) continue ;; esac
    [ "$only" = "  " ] || [[ $only == *" $name "* ]] || continue
    n=${ver#v}
    sub() { local s=${1//\{v\}/$ver}; printf '%s' "${s//\{n\}/$n}"; }
    asset=$(sub "$asset") sum=$(sub "$sum") members=$(sub "$members")
    d=$work/$name
    mkdir -p "$d/x"

    case $asset in
    go:*)
        # Static, so the binaries run on any glibc (the Flatpak runtime's
        # too); dlv only loses its eBPF tracing backend.
        GOBIN=$d/x CGO_ENABLED=0 go install "${asset#go:}@$ver"
        ;;
    rustup)
        # System-wide like the official rust image: toolchains in
        # PREFIX/rustup, the rustup proxies (cargo, rustc, ...) in
        # PREFIX/cargo/bin.
        RUSTUP_HOME=$prefix/rustup CARGO_HOME=$prefix/cargo "$prefix/bin/rustup-init" -y \
            --no-modify-path --profile minimal --default-toolchain "$ver" --component "$members"
        rm "$prefix/bin/rustup-init"
        echo "$name $ver: $prefix/rustup, $prefix/cargo"
        rm -rf "$d"
        continue
        ;;
    *)
        f=$d/${asset##*/}
        fetch "$asset" "$f"
        case $sum in
        sha256:*) want=${sum#sha256:} ;;
        http*) fetch "$sum" "$d/sums" && want=$(pick "${f##*/}" <"$d/sums") ;;
        .*) fetch "$asset$sum" "$d/sums" && want=$(pick "${f##*/}" <"$d/sums") ;;
        *) echo "$name: no checksum for $asset" >&2; exit 1 ;;
        esac || { echo "$name: no sha256 for ${f##*/} in $sum" >&2; exit 1; }
        echo "$want  $f" | sha256sum -c --quiet - || { echo "$name: sha256 mismatch" >&2; exit 1; }
        case $f in
        *.tar.gz) tar -xzf "$f" -C "$d/x" ;;
        *.tar.xz) tar -xJf "$f" -C "$d/x" ;;
        *.zip) unzip -q "$f" -d "$d/x" ;;
        *) mv "$f" "$d/x/" ;;
        esac
        ;;
    esac

    IFS=, read -ra ms <<<"$members"
    for m in "${ms[@]}"; do
        if [[ $m == *:* ]]; then src=${m%%:*} dst=${m#*:}; else src=$m dst=${m##*/}; fi
        case $dst in
        */)
            # Merged into what is there: include/ is shared with others.
            mkdir -p "$prefix/$dst"
            cp -a "$d/x/$src." "$prefix/$dst"
            echo "$name $ver: $prefix/$dst"
            ;;
        */*)
            install -Dm0644 "$d/x/$src" "$prefix/$dst"
            echo "$name $ver: $prefix/$dst"
            ;;
        *)
            install -Dm0755 "$d/x/$src" "$prefix/bin/$dst"
            echo "$name $ver: $prefix/bin/$dst"
            ;;
        esac
    done
    rm -rf "$d"
done 3<"$pins"
