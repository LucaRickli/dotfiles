#!/usr/bin/env bash

set -euo pipefail

# ---
# Installs configuration files and sets some system settings.
# ---

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR=$(realpath "$BASE_DIR/../config")

log="$BASE_DIR/log.sh"

if ! command -v stow &>/dev/null; then
  $log error "GNU Stow is required to deploy configs. Please install it and run this script again."
fi

# Check for existing config
for cfg in $(find "$CONFIG_DIR/.config" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;); do
  target="$HOME/.config/$cfg"

  if [[ -L "$target" ]]; then
    # Symlink found
    $log info "Existing symlink found: '$target', removing."
    rm "$target"
  elif [[ -e "$target" ]]; then
    # File or directory found
    read -rp "Existing file/directory found: '$target'. Remove? [y/N] " _remove
    if [[ "${_remove,,}" == "y" ]]; then
      $log info "Removing '$target'..."
      rm -rf "$target"
    else
      $log error "Please review and remove/backup '$target' before running this script again."
    fi
  fi
done

$log info "Deploying configs from '$CONFIG_DIR' to '$HOME' ..."

(cd "$CONFIG_DIR" && stow -t "$HOME" .)

read -rp "Change default shell to fish? [Y/n] " _change_shell
if [[ ! "${_change_shell,,}" == "n" ]]; then
  chsh -s "$(command -v fish)"
  $log info "Default shell changed to fish. Please log out and log back in for the change to take effect."
fi

read -rp "Set GDM as the default display manager? [Y/n] " _set_gdm
if [[ ! "${_set_gdm,,}" == "n" ]]; then
  sudo systemctl enable gdm.service
  $log info "GDM set as the default display manager. Please reboot for the change to take effect."
fi

read -rp "Set firefox as the default web browser? [Y/n] " _set_firefox
if [[ ! "${_set_firefox,,}" == "n" ]]; then
  xdg-settings set default-web-browser firefox.desktop
  $log info "Firefox set as the default web browser."
fi
