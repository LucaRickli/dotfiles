#!/usr/bin/env bash
#
# Rebuild the initramfs as the last change to the rootfs, in the `split`
# stage of image/seal.Containerfile, for whichever image is being sealed (the
# OS or an add-on image): it must contain the bootc/composefs dracut module
# (features/boot/overlay/usr/lib/dracut/dracut.conf.d/) and, on the nvidia
# add-on, the nvidia modules for early KMS (features/nvidia/setup.sh flips
# RPM Fusion's omit_drivers to force_drivers before this runs).
# `bootc container split-kernel-and-rootfs` then lifts kernel + initramfs out
# of the rootfs and into the UKI.
#
set -euxo pipefail

kver=$(cd /usr/lib/modules && echo *)

# DRACUT_NO_XATTR + the bootc module come from dracut.conf.d (sourced by dracut).
# /etc/passwd + /etc/group: same fix as install_items in 59-altfiles.conf.
dracut --no-hostonly --reproducible --kver "$kver" \
    --install "/etc/passwd /etc/group" \
    -f "/usr/lib/modules/${kver}/initramfs.img"
chmod 0600 "/usr/lib/modules/${kver}/initramfs.img"

# (no `| grep -q` on lsinitrd: with pipefail, grep exiting early makes
# lsinitrd fail with SIGPIPE)
lsinitrd "/usr/lib/modules/${kver}/initramfs.img" > /tmp/initramfs.lst

# The boot splash (kargs.d/30-quiet-boot.toml) needs plymouthd and its theme in
# the initramfs. Without them a quiet boot is a black screen, and the LUKS
# passphrase prompt is plain console text instead of the graphical one.
grep -c 'usr/sbin/plymouthd\|usr/bin/plymouthd' /tmp/initramfs.lst
grep -c "usr/share/plymouth/themes/$(plymouth-set-default-theme)/" /tmp/initramfs.lst

# Early KMS check, on an image with the nvidia modules (the nvidia add-on).
if [ -e "/usr/lib/modules/${kver}/extra/nvidia/nvidia.ko.xz" ]; then
    grep -c 'extra/nvidia/nvidia.*\.ko' /tmp/initramfs.lst || { echo "nvidia modules missing from initramfs" >&2; exit 1; }
fi
rm -f /tmp/initramfs.lst
