#!/usr/bin/env bash

set -euo pipefail

# ---
# Installs defined pacman packages
# ---

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR=$(realpath "$BASE_DIR/../packages/pacman")
SYS_DIR=$(realpath "$BASE_DIR/../system")

extract="$BASE_DIR/extract-packages.sh"
log="$BASE_DIR/log.sh"

pkgs=()

pkgs+=($($extract "$PKG_DIR/base.txt"))

read -rp "Install NVIDIA packages? [y/N] " _nvidia
if [[ "${_nvidia,,}" == "y" ]]; then
  pkgs+=($($extract "$PKG_DIR/nvidia.txt"))
fi

read -rp "Install audio packages? [y/N] " _audio
if [[ "${_audio,,}" == "y" ]]; then
  pkgs+=($($extract "$PKG_DIR/audio.txt"))
fi

for pkg in $($extract "$PKG_DIR/apps.txt"); do
  read -rp "Install application '$pkg'? [y/N] " _install
  if [[ "${_install,,}" == "y" ]]; then
    pkgs+=("$pkg")
  fi
done

$log info "Installing pacman packages: ${pkgs[*]}"

sudo pacman -S --needed --noconfirm "${pkgs[@]}"

if [[ " ${pkgs[*]} " == *" tailscale "* ]]; then
  $log info "Enabling and starting Tailscale service..."
  sudo systemctl enable --now tailscaled
fi

if [[ "${_nvidia,,}" == "y" ]]; then
  $log info "Configuring system settings for NVIDIA drivers..."

  sudo install -Dm644 "$SYS_DIR/modprobe-nvidia.conf" /etc/modprobe.d/nvidia.conf
  sudo install -Dm644 "$SYS_DIR/mkinitcpio-nvidia.conf" /etc/mkinitcpio.conf.d/nvidia.conf

  $log info "Rebuilding initramfs (mkinitcpio -P)..."

  sudo mkinitcpio -P

  $log warn "NVIDIA kernel parameters still needed in your bootloader:"
  $log warn "nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
  $log warn "See README.md § NVIDIA Setup for per-bootloader instructions."
fi
