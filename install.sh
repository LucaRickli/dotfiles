#!/usr/bin/env bash

# ---
# Entrypoint for fresh system installation
# ---

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"

log="$SCRIPTS_DIR/log.sh"
setup_secureboot="$SCRIPTS_DIR/setup-secureboot.sh"
install_paru="$SCRIPTS_DIR/install-paru.sh"
install_config="$SCRIPTS_DIR/install-config.sh"
update_pacman="$SCRIPTS_DIR/update-pacman.sh"
update_paru="$SCRIPTS_DIR/update-paru.sh"
update_binary="$SCRIPTS_DIR/update-binary.sh"

$log info "========================================================="
$log info "Arch Linux Dotfiles Installer"
$log info "========================================================="
echo

read -rp "Set up Secure Boot? [y/N] " _secureboot
if [[ "${_secureboot,,}" == "y" ]]; then  
  echo
  $log info "========================================================="
  $log info "Setting up Secure Boot..."
  $log info "========================================================="
  echo

  $setup_secureboot
fi

echo
$log info "========================================================="
$log info "Installing paru (AUR helper)..."
$log info "========================================================="
echo

$install_paru

echo
$log info "========================================================="
$log info "Installing pacman packages..."
$log info "========================================================="
echo

$update_pacman

echo
$log info "========================================================="
$log info "Installing AUR packages with paru..."
$log info "========================================================="
echo

$update_paru

echo
$log info "========================================================="
$log info "Installing binary releases..."
$log info "========================================================="
echo

$update_binary

echo
$log info "========================================================="
$log info "Deploying configuration files..."
$log info "========================================================="
echo

$install_config

echo
$log info "========================================================="
$log info "Installation complete! Reboot to apply changes"
$log info "========================================================="
echo

read -rp "Reboot now? [y/N] " _reboot
if [[ "${_reboot,,}" == "y" ]]; then
  sudo reboot now
fi
