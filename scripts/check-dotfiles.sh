#!/usr/bin/env bash
#
# Validate the dotfiles (home/.config, the stow package). One list, two
# callers, `just check` on the host and `just check-image` / CI check.yml
# inside the built image, so the two checks cannot drift apart.
#
#   check-dotfiles.sh home/.config               on the host (needs niri, noctalia,
#                                                ghostty, fish and jq installed)
#   just check-image                             same, inside the image (has them all)
set -euo pipefail

cfg=$(cd "${1:?usage: check-dotfiles.sh <config-root>}" && pwd)

niri validate -c "$cfg/niri/config.kdl"
noctalia config validate "$cfg/noctalia/settings.toml"
XDG_CONFIG_HOME="$cfg" ghostty +validate-config --config-file="$cfg/ghostty/config.ghostty"
# `fish FILE...` parses only the first path (the rest land in $argv), so a batched
# -exec ... + would check config.fish and silently skip every other file.
find "$cfg/fish" -name '*.fish' -print0 | xargs -0 -r -n1 fish --no-execute
jq -e . "$cfg/fastfetch/config.json" >/dev/null
