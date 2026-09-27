#!/usr/bin/env bash
#
# GRUB out, systemd-boot in. Runs after build.sh, before the overlay is copied
# (the install/kargs/dracut config that goes with this lives in overlay/usr/lib/).
# The systemd-boot loader binary is signed in place with the Secure Boot db key
# (podman secrets); `bootc install` copies it from /usr/lib/systemd/boot/efi/
# into the ESP, so the signature must exist here, before the composefs digest
# is computed over /usr.
#
# Pattern from travier/fedora-atomic-desktops-sealed (prepare-rootfs.sh) and
# https://bootc.dev/bootc/experimental-composefs.html
#
set -euxo pipefail

# The composefs/UKI subcommands (`bootc container split-kernel-and-rootfs`,
# `bootc container ukify`) are new, so take bootc from updates-testing.
dnf -y upgrade --enablerepo=updates-testing --refresh bootc

# rpm-ostree cannot manage a composefs-backend system, and client-side kargs /
# package layering do not apply to a sealed UKI anyway.
if rpm -q --quiet rpm-ostree; then
    dnf -y remove rpm-ostree rpm-ostree-libs
fi

# bootupd has no systemd-boot support; bootc's own bootloader install is used.
if rpm -q --quiet bootupd; then
    rpm -e bootupd
fi
rm -rf /usr/lib/bootupd /usr/lib/ostree-boot

# Remove GRUB2. shim-x64 stays: it is inert without Secure Boot, and it is the
# MOK path for the NVIDIA variant (docs/secureboot-tpm2.md).
grub_packages=()
for p in grub2-common grub2-efi-x64 grub2-efi-ia32 grub2-pc grub2-pc-modules grub2-tools grub2-tools-minimal; do
    rpm -q --quiet "$p" && grub_packages+=("$p")
done
[ "${#grub_packages[@]}" -eq 0 ] || rpm -e --nodeps "${grub_packages[@]}"

dnf -y install systemd-boot-unsigned sbsigntools fsverity-utils

# Sign the loader with our db key (keys/ in the repo, mounted as build secrets).
sbsign --key /run/secrets/secureboot_key --cert /run/secrets/secureboot_cert \
    --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
    /usr/lib/systemd/boot/efi/systemd-bootx64.efi
sbverify --cert /run/secrets/secureboot_cert /usr/lib/systemd/boot/efi/systemd-bootx64.efi

# Where the final stage drops the sealed UKI.
mkdir -p /boot/EFI/Linux

dnf -y clean all
rm -rf /var/cache/libdnf5 /var/log/dnf5.log*
