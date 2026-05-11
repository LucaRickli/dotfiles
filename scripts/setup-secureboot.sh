#!/usr/bin/env bash

set -euo pipefail

# ---
# This script sets up Secure Boot on the system by enrolling
# the necessary keys and configuring the bootloader.
# ---

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYS_DIR=$(realpath "$BASE_DIR/../system")

log="$BASE_DIR/log.sh"

$log info "Installing Secure Boot dependencies..."
sudo pacman -S --needed --noconfirm sbctl efitools binutils

$log info "Creating sbctl keys..."
sudo sbctl create-keys

sbctlEnrollParams=""
read -rp "Include Microsoft secure boot keys for dual-boot? [y/N] " _include_ms_keys
if [[ "${_include_ms_keys,,}" == "y" ]]; then
  sbctlEnrollParams="--microsoft"
fi

$log info "Enrolling keys with sbctl..."
sudo sbctl enroll-keys $sbctlEnrollParams

$log info "Signing bootloader and kernel with sbctl..."
sbctl sign -s /boot/EFI/Linux/arch-linux.efi
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI

$log info "Configuring kernel cmdline..."
echo "rd.luks.name=$(sudo blkid /dev/nvme1n1p2 -o json | jq -r ".blkid[].uuid" | tr -d '\n\'"')=cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ quiet splash" >> /etc/kernel/cmdline

$log info "Configuring initramfs for Secure Boot..."
cp "$SYS_DIR/mkinitcpio.conf" /etc/mkinitcpio.conf
cp "$SYS_DIR/linux.preset" /etc/mkinitcpio.d/linux.preset

$log info "Rebuilding initramfs..."
sudo mkinitcpio -P
