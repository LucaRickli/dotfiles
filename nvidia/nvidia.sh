#!/usr/bin/env bash
#
# NVIDIA variant: proprietary driver from RPM Fusion, kernel module built (akmods)
# and signed against the image's kernel at build time with the Secure Boot db key
# (the same key that signs systemd-boot and the UKI), kargs + modprobe options.
#
#   NVIDIA_KMOD=open   (default) NVIDIA open kernel modules: Turing (RTX 2000/GTX 16) and newer
#   NVIDIA_KMOD=closed           legacy proprietary modules: Maxwell/Pascal/Volta (GTX 900/1000)
#
set -euxo pipefail

CTX=${CTX:-/ctx}
NVIDIA_KMOD=${NVIDIA_KMOD:-open}
pkgs() { grep -hvE '^\s*(#|$)' "$@"; }

KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
REL=$(rpm -E %fedora)

# --- RPM Fusion free + nonfree ------------------------------------------------
dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${REL}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${REL}.noarch.rpm"

# --- Kernel headers for exactly the image's kernel ----------------------------
# fedora-bootc enables updates-archive, so this version stays installable after
# newer kernels hit the updates repo.
dnf -y install "kernel-devel-${KVER}" akmods

# Left to itself RPM Fusion's nvidia-kmod.spec picks open vs. closed by running
# lspci at build time (nvidia-kmod-noopen-checks), and that probe sees the BUILD
# HOST's GPU even inside a podman build, so the choice would depend on the machine
# doing the building. Pin it with the spec's own macros instead (build-time only,
# removed again in the cleanup below).
case "$NVIDIA_KMOD" in
    open)   echo '%_with_kmod_nvidia_open 1'      > /etc/rpm/macros.nvidia-kmod ;;
    closed) echo '%_without_kmod_nvidia_detect 1' > /etc/rpm/macros.nvidia-kmod ;;
    *)      echo "NVIDIA_KMOD must be 'open' or 'closed', got '$NVIDIA_KMOD'" >&2; exit 1 ;;
esac

# --- Secure Boot: sign the modules with the db key (podman secrets) -----------
# kmodtool signs automatically when both files exist at these paths. It wants the
# certificate as DER; the private key can be used as-is. akmods builds as the
# unprivileged 'akmods' user (created by the akmods package above), and kmodtool's
# sign step runs inside that build, so the key must be group-readable by it (this
# is what akmods' own kmodgenca does).
mkdir -p /etc/pki/akmods/certs
openssl x509 -in /run/secrets/secureboot_cert -outform DER -out /etc/pki/akmods/certs/public_key.der
chmod 644 /etc/pki/akmods/certs/public_key.der
install -Dm640 -o root -g akmods /run/secrets/secureboot_key /etc/pki/akmods/private/private_key.priv

# --- Driver ---------------------------------------------------------------------
dnf -y install $(pkgs "$CTX"/nvidia/packages.txt)
akmods --force --kernels "$KVER" --kmod nvidia

MOD="/usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz"
if ! modinfo "$MOD" >/dev/null 2>&1; then
    cat /var/cache/akmods/nvidia/*.failed.log 2>/dev/null || true
    echo "akmods did not produce $MOD" >&2; exit 1
fi
rpm -q "kmod-nvidia-${KVER}"
modinfo "$MOD" | grep -E '^(version|license|signer|sig_key)' || true
# The open modules are "Dual MIT/GPL", the closed ones are not, so fail loudly rather
# than shipping the flavour we did not ask for.
LICENSE=$(modinfo -F license "$MOD")
case "$NVIDIA_KMOD" in
    open)   [ "$LICENSE" = "Dual MIT/GPL" ] || { echo "asked for open modules, got license '$LICENSE'" >&2; exit 1; } ;;
    closed) [ "$LICENSE" != "Dual MIT/GPL" ] || { echo "asked for closed modules, got open ones (license '$LICENSE')" >&2; exit 1; } ;;
esac
if [ -z "$(modinfo -F signer "$MOD")" ]; then
    echo "module is not signed although a key was provided" >&2; exit 1
fi
rm -rf /etc/pki/akmods/private     # the private key must not end up in the image

# --- Kargs, modprobe options (nvidia/overlay/), early KMS ----------------------
cp -a "$CTX/nvidia/overlay/." /

# Early KMS: RPM Fusion ships omit_drivers for the nvidia modules; force them
# in. image/initramfs.sh rebuilds the initramfs after this script and
# verifies the modules made it in.
sed -i 's/omit_drivers/force_drivers/' /usr/lib/dracut/dracut.conf.d/99-nvidia-dracut.conf

# Suspend/resume services (xorg-x11-drv-nvidia-power's preset enables them; explicit).
systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service

# --- Cleanup -------------------------------------------------------------------
dnf -y clean all
rm -f /etc/rpm/macros.nvidia-kmod
rm -rf /var/cache/akmods /var/log/akmods /var/cache/libdnf5 /var/log/dnf5.log* /var/tmp/* /tmp/* /var/roothome/rpmbuild
