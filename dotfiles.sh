#!/bin/sh
#
# Link the dotfiles into place: each ~/.config/<app> becomes a symlink to
# <this repo>/home/.config/<app>.
#
# GNU Stow does the linking; this wrapper handles the parts it does not.
# Because the app directories are symlinks, editing a config in ~/.config IS
# editing the repo checkout. Re-run after pulling changes that add or rename
# entries.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
src="$repo/home/.config"
target="$HOME/.config"

command -v stow >/dev/null 2>&1 || { echo "error: GNU Stow is not installed" >&2; exit 1; }
[ -d "$src" ] || { echo "error: $src not found" >&2; exit 1; }

# A real ~/.config must exist before stow runs, or stow would "fold" it into
# one symlink pointing at the whole repo directory.
mkdir -p "$target"

# Never clobber silently: anything already at a target that is not already a
# link into this repo is a question, and a refusal becomes a stow --ignore rule
# so the remaining entries still get linked.
ignore=""
for path in "$src"/* "$src"/.[!.]*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name=${path##*/}
    dest="$target/$name"
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$path")" ]; then
        continue                     # already linked to this repo
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        printf '%s exists and is not linked to this repo. Remove it? [y/N] ' "$dest"
        read -r answer
        case $answer in
            [yY]|[yY][eE][sS]) rm -rf "$dest" ;;
            *) echo "keeping $dest (skipped)"
               ignore="$ignore --ignore=^$name\$" ;;
        esac
    fi
done

# --restow first unstows, so renamed/removed entries get cleaned up on re-runs.
# shellcheck disable=SC2086  # $ignore is a list of flags on purpose
stow --dir "$repo/home" --target "$target" --restow $ignore .config

echo "[done] ~/.config entries now link into $src"
