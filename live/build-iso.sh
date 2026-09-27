#!/usr/bin/env bash
#
# Assemble the live install ISO. Runs INSIDE a Fedora container with the :live
# image mounted read-only at /rootfs and the destination at /output; `just iso`
# sets that up, so the host needs nothing but podman. UEFI only.
#
# The xorriso invocation and the appended-GPT ESP follow ublue-os/titanoboa's
# recipe (Apache-2.0).
set -euxo pipefail

LABEL=${LABEL:-fedora-bootc-live}
ROOTFS=/rootfs
WORK=/work

dnf install -y --setopt=install_weak_deps=False \
    squashfs-tools xorriso mtools dosfstools

mkdir -p "$WORK"/iso-root/boot/grub2 \
         "$WORK"/iso-root/images/pxeboot \
         "$WORK"/iso-root/LiveOS \
         "$WORK"/EFI

# The filesystem the live session runs from.
#
# `-comp xz` rather than zstd: about 10% smaller here (1.774 GiB vs 1.849 GiB),
# which keeps the ISO under GitHub's 2 GiB release-asset limit. The cost is
# slower decompression, in a session that lasts minutes.
#
# Order matters: mksquashfs treats everything after `-e` as an exclude
# pattern, so `-comp` must come first. The other way round silently drops the
# compressor and ships gzip.
mksquashfs "$ROOTFS" "$WORK"/iso-root/LiveOS/squashfs.img \
    -all-root -noappend -comp xz -e sysroot ostree

# Kernel and initramfs, which GRUB loads directly rather than from the squashfs.
cp -v "$ROOTFS"/usr/lib/modules/*/initramfs.img "$WORK"/iso-root/images/pxeboot/initrd.img
cp -v "$ROOTFS"/usr/lib/modules/*/vmlinuz       "$WORK"/iso-root/images/pxeboot/vmlinuz

# The EFI tree the live stage assembled: GRUB only, no shim, so this ISO does
# not boot with Secure Boot enabled. That is deliberate, see live/prepare-live.sh.
cp -aT "$ROOTFS"/boot/efi/EFI "$WORK"/EFI

# root=live:CDLABEL= is what dracut's dmsquash-live module looks for, so the
# volume label below and the one in the ISO have to agree. enforcing=0 because
# the live rootfs is an overlay without the policy the installed system gets.
#
# console=ttyS0 as well as tty0, for headless VM boots and panics. tty0 comes
# last on purpose: the last console= becomes /dev/console, so systemd's output
# stays on the display rather than going to a serial port nobody reads.
cat > "$WORK"/grub.cfg <<EOF
set timeout=10
set default=0
set menu_auto_hide=false
function load_video {
  insmod all_video
}
load_video
set gfxpayload=keep
insmod gzio
insmod part_gpt
insmod chain
search --no-floppy --set=root -l '${LABEL}'

menuentry 'Install Fedora bootc' --class fedora {
    linux /images/pxeboot/vmlinuz root=live:CDLABEL=${LABEL} rd.live.image enforcing=0 console=ttyS0,115200n8 console=tty0
    initrd /images/pxeboot/initrd.img
}
menuentry 'Install Fedora bootc (basic graphics)' --class fedora {
    linux /images/pxeboot/vmlinuz root=live:CDLABEL=${LABEL} rd.live.image enforcing=0 console=ttyS0,115200n8 console=tty0 nomodeset
    initrd /images/pxeboot/initrd.img
}
EOF
for d in "$WORK"/EFI/* "$WORK"/iso-root/boot/grub2; do
    [ -d "$d" ] && cp "$WORK"/grub.cfg "$d"/grub.cfg
done
cp -aT "$WORK"/EFI "$WORK"/iso-root/EFI

# A FAT image holding the EFI tree, appended to the ISO as a GPT partition of
# ESP type: UEFI boots from that, not from the ISO9660 filesystem.
#
# Sized to its contents (the tree is about 18 MiB): empty FAT would count
# against the 2 GiB asset limit too. The 48 MiB floor is because FAT32 needs
# at least 65525 clusters.
efi_mib=$(( $(du -sm "$WORK"/EFI | cut -f1) * 3 / 2 + 8 ))
[ "$efi_mib" -lt 48 ] && efi_mib=48
truncate -s "${efi_mib}M" "$WORK"/uefi.img
mkfs.fat -F32 "$WORK"/uefi.img
mcopy -i "$WORK"/uefi.img -s "$WORK"/EFI ::

cd "$WORK"
xorriso -as mkisofs \
    -R \
    -V "$LABEL" \
    -partition_offset 16 \
    -appended_part_as_gpt \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B ./uefi.img \
    -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
    -e --interval:appended_partition_2:all:: \
    -no-emul-boot \
    -iso-level 3 \
    -o "/output/${LABEL}.iso" \
    iso-root

ls -l "/output/${LABEL}.iso"
