#!/usr/bin/env bash
#
# Build and sign the sealed UKI. Runs in the `uki` tools stage of the
# Containerfile with the split rootfs bind-mounted read-only at /target and the
# kernel + initramfs (moved out by `bootc container split-kernel-and-rootfs`)
# at $KERNEL_DIR/<kver>/, which the Containerfile points at the copy on the
# host so that this stage does not depend on the rootfs stages. Defaults to
# /kernel for a direct run.
#
# `bootc container ukify` computes the composefs digest of /target, reads the
# kernel arguments from /target/usr/lib/bootc/kargs.d, and hands everything to
# systemd's `ukify`, with the digest sealed into the command line
# (`composefs=<digest>`); everything after `--` is passed to ukify unchanged.
# https://bootc.dev/bootc/experimental-composefs.html
#
set -euxo pipefail

KERNEL_DIR=${KERNEL_DIR:-/kernel}
kver=$(cd "$KERNEL_DIR" && echo *)
mkdir -p /out

bootc container ukify \
    --rootfs /target \
    --kernel-dir "${KERNEL_DIR}/${kver}" \
    -- \
    --output "/out/${kver}.efi" \
    --signtool sbsign \
    --secureboot-private-key /run/secrets/secureboot_key \
    --secureboot-certificate /run/secrets/secureboot_cert

# Fallback if `bootc container ukify` grows or loses flags (it is experimental):
# the manual flow from travier/fedora-atomic-desktops-sealed. It does not read
# kargs.d, so --cmdline must list every karg in /target/usr/lib/bootc/kargs.d
# (plus nvidia/overlay's for the NVIDIA variant):
#   digest="$(bootc container compute-composefs-digest /target)"
#   ukify build --linux "${KERNEL_DIR}/${kver}/vmlinuz" --initrd "${KERNEL_DIR}/${kver}/initramfs.img" \
#       --uname "${kver}" --os-release "@/target/usr/lib/os-release" \
#       --cmdline "composefs=${digest} rw rootflags=compress=zstd:1 rd.luks.options=tpm2-device=auto rhgb quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0" \
#       --signtool sbsign --secureboot-private-key /run/secrets/secureboot_key \
#       --secureboot-certificate /run/secrets/secureboot_cert \
#       --output "/out/${kver}.efi"

sbverify --cert /run/secrets/secureboot_cert "/out/${kver}.efi"
