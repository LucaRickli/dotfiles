#!/usr/bin/env bash

set -euo pipefail

# ---
# Installs defined pacman packages
# ---

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR=$(realpath "$BASE_DIR/../packages/aur")

extract="$BASE_DIR/extract-packages.sh"
log="$BASE_DIR/log.sh"

pkgs=()

pkgs+=($($extract "$PKG_DIR/base.txt"))

for pkg in $($extract "$PKG_DIR/apps.txt"); do
  read -rp "Install application '$pkg'? [y/N] " _install
  if [[ "${_install,,}" == "y" ]]; then
    pkgs+=("$pkg")
  fi
done

$log info "Installing paru packages: ${pkgs[*]}"

paru -S --needed --noconfirm --removemake "${pkgs[@]}"
