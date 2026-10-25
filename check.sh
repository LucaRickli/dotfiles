#!/usr/bin/env bash
#
# The dotfiles' syntax checks, the ones any machine can run (needs fish and
# jq): dotfiles.sh, every fish file and the JSON. CI runs it on every push to
# main and every pull request (.github/workflows/check.yml).
set -euo pipefail

cd "$(dirname "$0")"

sh -n dotfiles.sh
# `fish FILE...` parses only the first path (the rest land in $argv), so a batched
# -exec ... + would check config.fish and silently skip every other file.
find home/.config/fish -name '*.fish' -print0 | xargs -0 -r -n1 fish --no-execute
jq -e . home/.config/fastfetch/config.json >/dev/null
