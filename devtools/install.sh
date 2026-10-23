#!/usr/bin/env bash
#
# Install the tools pinned in tools.txt (the format is described there) into
# a prefix: executables in PREFIX/bin, Go in PREFIX/go, Rust in PREFIX/rustup
# and PREFIX/cargo, each tool's license texts in PREFIX/share/licenses/NAME.
# With NAMEs, only those lines. --list reads another file in the same format
# instead (extensions.txt, the VS Code extensions).
#
#   devtools/install.sh [--list FILE] PREFIX [NAME...]
#
# Nothing is installed unverified: a download must match upstream's sha256
# (or the pinned one, as a license text fetched by URL must), go install
# checks sum.golang.org, rustup checks the channel manifest. Needs bash,
# curl, sha256sum, tar with gzip and xz, unzip, and openssl for minisign
# signatures.
set -euo pipefail

pins=$(dirname "$0")/tools.txt
list=
if [ "${1:-}" = --list ]; then
    pins=${2:?usage: install.sh [--list FILE] PREFIX [NAME...]}
    list=1
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

# Whether file $1 carries the minisign signature of public key $2 (base64,
# as minisign prints it) in $1.minisig, checked as `minisign -V` does but
# with openssl: Ed25519 over the file's BLAKE2b-512 (minisign's default
# "ED"; the unhashed legacy kind fails), by the key's id, and over the
# signature plus the trusted comment.
minisig() {
    local t=$1.check
    mkdir -p "$t"
    base64 -d <<<"$2" >"$t/key" &&
        sed -n 2p "$1.minisig" | base64 -d >"$t/sig" &&
        sed -n 4p "$1.minisig" | base64 -d >"$t/global" || return 1
    # "Ed" and "ED", each followed by the same 8-byte key id.
    [ "$(head -c 2 "$t/key")" = Ed ] && [ "$(head -c 2 "$t/sig")" = ED ] &&
        [ "$(head -c 10 "$t/key" | tail -c 8 | base64)" = "$(head -c 10 "$t/sig" | tail -c 8 | base64)" ] ||
        return 1
    # The key's last 32 bytes, behind the DER header of an Ed25519 key.
    { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; tail -c 32 "$t/key"; } >"$t/key.der"
    tail -c 64 "$t/sig" >"$t/sig.raw"
    openssl dgst -blake2b512 -binary "$1" >"$t/hash"
    { cat "$t/sig.raw"; sed -n 's/^trusted comment: //p' "$1.minisig" | tr -d '\n'; } >"$t/comment"
    openssl pkeyutl -verify -pubin -keyform DER -inkey "$t/key.der" -rawin \
        -in "$t/hash" -sigfile "$t/sig.raw" >/dev/null &&
        openssl pkeyutl -verify -pubin -keyform DER -inkey "$t/key.der" -rawin \
            -in "$t/comment" -sigfile "$t/global" >/dev/null
}

# The license texts the line names, into PREFIX/share/licenses/NAME: paths
# under $1 (the unpacked release, the Go module, the Rust toolchain; a
# directory's files) or URLs of upstream's files at the tag, each with the
# sha256 pinned after "#": no release publishes one, and a text that changes
# (a new copyright year, a new notice) fails the version bump until someone
# has read it and pinned it. A copyleft license also wants the way to the
# source next to the binary: SOURCES.
notices() {
    local dir=$prefix/share/licenses/$name files l url hash
    [ "$license" != - ] || return 0
    mkdir -p "$dir"
    IFS=, read -ra files <<<"$license"
    for l in "${files[@]}"; do
        case $l in
        https://*)
            url=${l%%#*} hash=${l#"$url"}
            [[ $hash =~ ^#sha256:[0-9a-f]{64}$ ]] || { echo "$name: no #sha256:<hex> after $url" >&2; exit 1; }
            fetch "$url" "$dir/${url##*/}"
            echo "${hash#\#sha256:}  $dir/${url##*/}" | sha256sum -c --quiet - || {
                echo "$name: $url differs from the sha256 on the line; read it, then pin its sha256sum" >&2
                exit 1
            }
            ;;
        */) cp -R "$1/$l." "$dir" ;;
        *) install -m0644 "$1/$l" -t "$dir" ;;
        esac
    done
    if [ -n "$source" ]; then
        # Checked, so that a pointer to nothing fails the build.
        curl -fsSIL --retry 5 --retry-all-errors -o /dev/null "$source"
        printf '%s %s is built from the source at\n%s\n' "$name" "$ver" "$source" >"$dir/SOURCES"
    elif grep -rqiE 'GNU (General|Lesser|Library|Affero) Public License|Mozilla Public License' "$dir"; then
        echo "$name: a copyleft license, but no source on the line" >&2
        exit 1
    fi
    echo "$name $ver: $dir"
}

# fd 3: nothing in the loop body can read the list by accident.
while read -r name ver asset sum members license source <&3; do
    case $name in '' | '#'*) continue ;; esac
    [ "$only" = "  " ] || [[ $only == *" $name "* ]] || continue
    # - only in a --list file: a .vsix carries its own.
    [[ -n $license && ($license != - || -n $list) ]] || { echo "$name: no license on the line" >&2; exit 1; }
    n=${ver#v}
    sub() { local s=${1//\{v\}/$ver}; printf '%s' "${s//\{n\}/$n}"; }
    asset=$(sub "$asset") sum=$(sub "$sum") members=$(sub "$members")
    license=$(sub "$license") source=$(sub "$source")
    d=$work/$name
    mkdir -p "$d/x"

    case $asset in
    go:*)
        # Static, so the binaries run on any glibc (the Flatpak runtime's
        # too); dlv only loses its eBPF tracing backend.
        GOBIN=$d/x CGO_ENABLED=0 go install "${asset#go:}@$ver"
        # The license is in the module's source, which go just downloaded:
        # the main module a binary records (a package path is not one).
        bins=("$d"/x/*)
        from=$(go list -m -f '{{.Dir}}' \
            "$(go version -m "${bins[0]}" | awk '$1 == "mod" { print $2 "@" $3 }')")
        ;;
    rustup)
        # System-wide like the official rust image: toolchains in
        # PREFIX/rustup, the rustup proxies (cargo, rustc, ...) in
        # PREFIX/cargo/bin.
        RUSTUP_HOME=$prefix/rustup CARGO_HOME=$prefix/cargo "$prefix/bin/rustup-init" -y \
            --no-modify-path --profile minimal --default-toolchain "$ver" --component "$members"
        rm "$prefix/bin/rustup-init"
        echo "$name $ver: $prefix/rustup, $prefix/cargo"
        notices "$prefix/rustup/toolchains/$ver-x86_64-unknown-linux-gnu"
        rm -rf "$d"
        continue
        ;;
    *)
        from=$d/x
        f=$d/${asset##*/}
        fetch "$asset" "$f"
        key=
        if [[ $sum == *,minisign:* ]]; then key=${sum#*,minisign:} sum=${sum%%,*}; fi
        case $sum in
        sha256:*) want=${sum#sha256:} ;;
        http*) fetch "$sum" "$d/sums" && want=$(pick "${f##*/}" <"$d/sums") ;;
        .*) fetch "$asset$sum" "$d/sums" && want=$(pick "${f##*/}" <"$d/sums") ;;
        *) echo "$name: no checksum for $asset" >&2; exit 1 ;;
        esac || { echo "$name: no sha256 for ${f##*/} in $sum" >&2; exit 1; }
        if [ -n "$key" ]; then
            fetch "$sum.minisig" "$d/sums.minisig"
            minisig "$d/sums" "$key" || { echo "$name: $sum is not signed by the key on the line" >&2; exit 1; }
        fi
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
    notices "$from"
    rm -rf "$d"
done 3<"$pins"
