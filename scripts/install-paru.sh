#!/usr/bin/env bash

set -euo pipefail

# ---
# This script installs paru, an AUR helper, if it's not already installed.
# ---

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log="$BASE_DIR/log.sh"

if command -v paru &>/dev/null; then
  $log info "Paru already installed, skipping."
  exit 0
fi

$log info "Installing Paru (AUR helper)..."

sudo pacman -S --needed --noconfirm git base-devel

tmpdir=$(mktemp -d)

git clone https://aur.archlinux.org/paru.git "$tmpdir/paru"

(cd "$tmpdir/paru" && makepkg -si --noconfirm)

rm -rf "$tmpdir"

$log info "Paru installed." 
