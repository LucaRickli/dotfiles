#!/usr/bin/env bash
#
# The nvidia add-on at build time, run by image/finalize.sh once its packages
# and overlay/ are in place on top of the base: early KMS, then its checks
# (the marked section at the end).
#
set -euxo pipefail

# open or closed modules: the add-on build's ADDON_FLAVOR (pre-install.sh)
NVIDIA_KMOD=${ADDON_FLAVOR:-open}

# --- Early KMS ----------------------------------------------------------------
# RPM Fusion ships omit_drivers for the nvidia modules; force them in.
# image/initramfs.sh rebuilds the initramfs after this and verifies the
# modules made it in.
sed -i 's/omit_drivers/force_drivers/' /usr/lib/dracut/dracut.conf.d/99-nvidia-dracut.conf

# --- Checks -----------------------------------------------------------------
# The module post-install.sh built: for the image's kernel, packaged, signed
# (with the db key, the only one the build has), and the flavour asked for.
# The open modules are "Dual MIT/GPL", the closed ones are not.
KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
info=$(modinfo "/usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz")
rpm -q "kmod-nvidia-${KVER}" >/dev/null
grep -q '^signer: *[^ ]' <<<"$info"
case "$NVIDIA_KMOD" in
    open)   grep -qx 'license: *Dual MIT/GPL' <<<"$info" ;;
    closed) test -z "$(grep '^license: *Dual MIT/GPL' <<<"$info")" ;;
esac
# Build-time only, so gone: the signing key and the open/closed pin.
test ! -e /etc/pki/akmods/private
test ! -e /etc/rpm/macros.nvidia-kmod
# Early KMS (above), and what overlay/ adds: the kargs, whose blacklist
# string RPM Fusion's nvidia-fallback.service matches verbatim, and the
# module options Wayland needs.
grep -q 'force_drivers' /usr/lib/dracut/dracut.conf.d/99-nvidia-dracut.conf
test -z "$(grep omit_drivers /usr/lib/dracut/dracut.conf.d/99-nvidia-dracut.conf)"
grep -qF '"rd.driver.blacklist=nouveau,nova_core",' /usr/lib/bootc/kargs.d/10-nvidia.toml
grep -qx 'options nvidia_drm modeset=1 fbdev=1' /usr/lib/modprobe.d/nvidia.conf
