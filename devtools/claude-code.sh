#!/usr/bin/env bash
#
# Where to download Claude Code VERSION for linux-x64, and its sha256 and
# size, from the manifest Anthropic signs for each release. Prints
# "URL SHA256 SIZE". With --zst, the zstd-compressed file (about a third of
# the size). The VS Code Flatpak declares that as extra-data
# (devtools/flatpak/build.sh), the dev container bakes it into the pin its
# `claude` downloads by (devtools/claude); neither image carries Claude Code
# itself, which is not open source.
#
#   devtools/claude-code.sh [--zst] VERSION
#
# The signature is checked against the release key next to this file
# (claude-code.asc, from https://downloads.claude.ai/keys/claude-code.asc),
# and the key that made it against the fingerprint Anthropic's setup docs
# give, so a different key in that file fails too. Without that check the
# hashes would be only as good as TLS to downloads.claude.ai. Needs bash,
# curl, gpg, jq.
set -euo pipefail

fingerprint=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
file=claude manifest=manifest.json
if [ "${1:-}" = --zst ]; then
    file=claude.zst manifest=manifest.zst.json
    shift
fi
version=${1:?usage: claude-code.sh [--zst] VERSION}
base=https://downloads.claude.ai/claude-code-releases/$version

# A keyring of its own, thrown away after: nothing else is trusted.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$(dirname "$0")/claude-code.asc"
curl -fsSL --retry 5 -o "$work/manifest" "$base/$manifest"
curl -fsSL --retry 5 -o "$work/manifest.sig" "$base/$manifest.sig"
# VALIDSIG ends with the fingerprint of the signing key's primary key.
gpg --batch --status-fd 3 --verify "$work/manifest.sig" "$work/manifest" \
    3>"$work/status" 2>/dev/null || { echo "$manifest for $version: bad signature" >&2; exit 1; }
awk -v fpr="$fingerprint" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' \
    "$work/status" || { echo "$manifest for $version: not signed by $fingerprint" >&2; exit 1; }

# The manifest names its own version, so an older one, signed as well,
# cannot stand in for it.
jq -er --arg v "$version" --arg f "$file" --arg url "$base/linux-x64/$file" '
    select(.version == $v) | .platforms["linux-x64"]
    | select(.binary == $f and (.checksum | test("^[0-9a-f]{64}$")) and .size > 0)
    | "\($url) \(.checksum) \(.size)"' "$work/manifest" ||
    { echo "$manifest: no linux-x64 $file of $version in it" >&2; exit 1; }
